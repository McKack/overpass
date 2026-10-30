import SwiftUI
import AppKit

// Submit Profile… in the profile editor: sends a profile to OverPass's issues through the report relay, for review. A
// profile only goes out after a test run here: OverPass starts the title with it, its window has to stay up for
// `requiredSeconds`, and a screenshot goes along. What's sent is the text that was tested, without the person's own
// artwork. The details block's `kind: profile` tells the report check and the relay what it is.

@MainActor @Observable
final class ProfileSubmission {
    enum Test: Equatable {
        case notRun, starting, running
        case passed(seconds: Int)
        case failed(String)
    }

    static let requiredSeconds = 30
    /// How long a title has to show a window; a launcher can have updates to fetch first.
    private static let startLimit: TimeInterval = 180
    /// How long no window counts as still running: a launcher handing over to its game.
    private static let handover: TimeInterval = 6

    let item: LibraryItem
    let profileID: String
    var note = ""
    var test = Test.notRun
    var screenshot: NSImage?
    /// The profile as it goes out: taken when a test starts, so a later edit isn't sent untested.
    private(set) var text: String
    /// Set by BottleManager when Wine's crash handler starts during the test.
    var crashed = false
    private var run: Task<Void, Never>?

    init(item: LibraryItem, profileID: String, profiles: ProfileStore) {
        self.item = item
        self.profileID = profileID
        text = Self.shareable(profileID, in: profiles)
    }

    /// The profile without what's only of use on this Mac: the person's own pictures and the note of its origin.
    private static func shareable(_ id: String, in profiles: ProfileStore) -> String {
        var profile = ProfileText(text: profiles.text(of: id) ?? "")
        let original = profiles.bundledText(of: id).map(ProfileText.init(text:))
        for key in ["icon", "cover"] where original?.first(key, in: "app") != profile.first(key, in: "app") {
            profile.set(key, nil, in: "app")
        }
        for key in ["cover-style", "icon-style"] { profile.set(key, nil, in: "app") }
        let body = profile.text.components(separatedBy: "\n").drop { $0.hasPrefix(UserProfiles.basedOnPrefix) }
        return LogCollector.scrub(body.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts the title on its own, as a recorded run does, and brings the window back when it has quit.
    func start(_ manager: BottleManager, profiles: ProfileStore) {
        text = Self.shareable(profileID, in: profiles)
        test = .starting
        screenshot = nil
        crashed = false
        manager.profileTest = self
        run = Task {
            if !manager.runningPrograms(in: item.bottle).isEmpty { await manager.quitEverything(in: item.bottle) }
            do {
                try manager.launchApp(item.app, in: item.bottle)
                await watch(manager)
            } catch {
                test = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            manager.profileTest = nil
            ReportCenter.shared.showProfileSubmission(self)
        }
    }

    func cancel(_ manager: BottleManager) {
        run?.cancel()
        manager.profileTest = nil
        test = .notRun
    }

    private func watch(_ manager: BottleManager) async {
        let name = item.app.name
        let started = Date.now
        var firstSeen: Date?, lastSeen = started
        var announced = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let seconds = firstSeen.map { Int(lastSeen.timeIntervalSince($0)) } ?? 0
            if crashed && seconds < Self.requiredSeconds {
                test = .failed("\(name) crashed. Change the profile or Report Issue… on \(name), then try again.")
                return
            }
            if let pid = manager.windowedPrograms(of: item).first {
                if firstSeen == nil {
                    firstSeen = .now
                    test = .running
                    ReportCenter.shared.closePanel()
                }
                lastSeen = .now
                guard seconds >= Self.requiredSeconds else { continue }
                if screenshot == nil && CGPreflightScreenCaptureAccess() {
                    screenshot = await ReportHotKey.capture(pid: pid)
                }
                if !announced {
                    announced = true
                    NSSound(named: "Glass")?.play()
                }
            } else if firstSeen != nil {
                guard Date.now.timeIntervalSince(lastSeen) > Self.handover else { continue }
                test = seconds >= Self.requiredSeconds ? .passed(seconds: seconds)
                    : .failed("\(name) closed after \(seconds) seconds; it has to stay open for \(Self.requiredSeconds).")
                return
            } else if Date.now.timeIntervalSince(started) > Self.startLimit {
                test = .failed("\(name) showed no window within \(Int(Self.startLimit / 60)) minutes.")
                return
            }
        }
    }
}

extension BottleManager {
    /// The title's programs with a window on screen, largest window first: by its program's name or a working folder
    /// inside its install, which also finds a game its launcher started. A Steam game's program isn't known; the
    /// client's own windows don't count for it.
    func windowedPrograms(of item: LibraryItem) -> [pid_t] {
        let program = item.app.programName.map { ($0 as NSString).deletingPathExtension.lowercased() }
        let folder = item.installFolder?.resolvingSymlinksInPath().path
        let steamGame = program == nil && item.app.launcher == "Steam" && item.app.storeID != nil
        let programs = runningPrograms(in: item.bottle).filter { process in
            let name = process.displayName.lowercased()
            if steamGame { return !name.hasPrefix("steam") }
            guard program != nil || folder != nil else { return true }
            let location = URL(fileURLWithPath: process.location).resolvingSymlinksInPath().path
            return name == program || folder.map { location == $0 || location.hasPrefix($0 + "/") } == true
        }
        let pids = Set(programs.map(\.pid))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let sized = windows.compactMap { window -> (pid: pid_t, area: CGFloat)? in
            guard let pid = window[kCGWindowOwnerPID] as? pid_t, pids.contains(pid), window[kCGWindowLayer] as? Int == 0,
                  let bounds = window[kCGWindowBounds].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
                  bounds.width > 64, bounds.height > 64 else { return nil }
            return (pid, bounds.width * bounds.height)
        }
        return sized.sorted { $0.area > $1.area }.map(\.pid)
    }
}

struct ProfileSubmitView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Bindable var submission: ProfileSubmission
    let close: () -> Void
    @State private var sending = false
    @State private var error: String?

    private var item: LibraryItem { submission.item }
    private var name: String { item.app.name }
    private var seconds: Int? {
        if case .passed(let seconds) = submission.test { seconds } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIcon(item: item, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submit Profile for \(name)").font(.title3.bold())
                    Text("It goes to OverPass's public issues. Once reviewed, it can ship with OverPass for everyone.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ReportStep(number: 1, title: "What does it do?", isLast: false) {
                    ReportTextEditor(text: $submission.note, placeholder: "What did you change, and what does it fix or improve in \(name)?", height: 64)
                }
                ReportStep(number: 2, title: "Test run", isLast: false) { testRun }
                ReportStep(number: 3, title: "What's sent", isLast: true) { sent }
            }
            ReportPrivacyNote()
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Sending…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") {
                    if submission.test == .starting { submission.cancel(manager) }
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Submit Profile", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || seconds == nil || submission.screenshot == nil
                              || submission.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 540)
    }

    @ViewBuilder private var testRun: some View {
        switch submission.test {
        case .notRun, .running:
            Text("\(name) runs with this profile. Keep it open until you hear a sound (\(ProfileSubmission.requiredSeconds) "
                 + "seconds), then quit it; this window comes back and a screenshot is attached."
                 + (manager.runningPrograms(in: item.bottle).isEmpty ? "" : " Programs running in its container are quit first."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Run \(name)") { submission.start(manager, profiles: profiles) }
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(name) to open…").font(.callout).foregroundStyle(.secondary)
            }
        case .passed(let seconds):
            Label("\(name) ran for \(seconds) seconds.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            screenshotRow
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Run \(name) Again") { submission.start(manager, profiles: profiles) }
        }
    }

    @ViewBuilder private var screenshotRow: some View {
        HStack(spacing: 10) {
            if let screenshot = submission.screenshot {
                Image(nsImage: screenshot).resizable().scaledToFit()
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            }
            Button(submission.screenshot == nil ? "Attach Screenshot…" : "Use Another…") {
                submission.screenshot = ReportView.chooseScreenshot() ?? submission.screenshot
            }
            Button("Run Again") { submission.start(manager, profiles: profiles) }
        }
        if submission.screenshot == nil {
            Text(CGPreflightScreenCaptureAccess() ? "OverPass couldn't take a screenshot of \(name). Attach one of it running."
                 : "OverPass isn't allowed to record the screen, so attach a screenshot of \(name) running.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(submission.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 84)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("The profile, the screenshot, your OverPass, Wine and Runtime versions and your Mac's model and macOS version.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send() {
        guard let seconds else { return }
        sending = true
        error = nil
        Task {
            do {
                let what = LogCollector.scrub(submission.note.trimmingCharacters(in: .whitespacesAndNewlines))
                let block = manager.reportBlock(for: item, recording: nil, profile: profiles.reportTag(of: submission.profileID),
                                                submission: "ran \(seconds) s")
                let jpeg = submission.screenshot.flatMap(ReportView.jpeg)
                NSWorkspace.shared.open(try await ReportRelay.send(title: "Profile: \(name)", what: what, block: block, zip: nil,
                                                                   screenshot: jpeg, profile: submission.text))
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
