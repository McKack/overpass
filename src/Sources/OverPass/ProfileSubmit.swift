import SwiftUI
import AppKit

// Submit Rating & Profile in the profile editor: a rating of how the title runs and the profile it ran with go to
// OverPass's issues through the report relay, for review. The title has to have been started first (it may have
// failed: that's what Borked is for). What's sent is the profile without the person's own artwork, the frame rate
// overpass-runtime measured, and an optional comment. The details block's `kind: profile` tells the report check
// and the relay what it is.

/// Titles started from OverPass or their Mac app wrapper. Kept for good: one start allows a rating, however long ago.
enum StartedTitles {
    private static let key = "startedTitles"

    static func add(_ id: String) {
        let ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !ids.contains(id) { UserDefaults.standard.set(ids + [id], forKey: key) }
    }

    static func contains(_ id: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: key)?.contains(id) == true
    }
}

/// What overpass-runtime measured for a program's last run: one file per program, rewritten every few seconds.
struct FrameStats {
    private static let shortestRun: Double = 5

    let fps, low, milliseconds, worst, jitter, seconds: Double

    /// One line for the details block.
    var summary: String {
        String(format: "%.1f fps, 1%% low %.1f, %.1f ms, p99 %.1f ms, jitter %.1f ms, %.0f s", fps, low, milliseconds, worst, jitter, seconds)
    }

    /// The title's own file, or the newest in the container when its program isn't known (a Steam game).
    static func latest(for item: LibraryItem) -> FrameStats? {
        let folder = item.bottle.path.appendingPathComponent("drive_c/users/Public/OverPass/Frames")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
        let program = item.app.programName.map { ($0 as NSString).deletingPathExtension.lowercased() }
        let file = files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == program }
            ?? files.max { LogCollector.modified($0) < LogCollector.modified($1) }
        return file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(parse)
    }

    /// "fps=58.2 low=41.0 ms=17.2 p99=24.4 jitter=1.3 seconds=612"; nil for a run too short to say anything.
    static func parse(_ text: String) -> FrameStats? {
        var values: [String: Double] = [:]
        for pair in text.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let value = Double(parts[1]) { values[String(parts[0])] = value }
        }
        guard let fps = values["fps"], let low = values["low"], let ms = values["ms"], let worst = values["p99"],
              let jitter = values["jitter"], let seconds = values["seconds"], seconds >= shortestRun else { return nil }
        return FrameStats(fps: fps, low: low, milliseconds: ms, worst: worst, jitter: jitter, seconds: seconds)
    }
}

extension BottleManager {
    /// Whether the title has been started at all: through OverPass, or from its store's client while it still runs.
    func hasStarted(_ item: LibraryItem) -> Bool {
        StartedTitles.contains(item.id) || !LogCollector.lastRunLogs(for: item).isEmpty || !windowedPrograms(of: item).isEmpty
    }

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

/// What Submit Rating & Profile asks last: an optional comment.
struct ProfileSubmitSheet: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    let profileID: String
    /// The profile as it goes out, for a title that has none saved.
    let builtProfile: String
    let rating: GameProfile.Rating.Tier
    @State private var comment = ""
    @State private var sending = false
    @State private var error: String?

    private var trimmed: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Want to add a comment with this submission?").font(.headline)
            ReportTextEditor(text: $comment, placeholder: "Optional", height: 84)
            Text("Goes to OverPass's public issues with your rating (\(rating.title)), the profile, the frame rate of the last "
                 + "run, your OverPass, Wine and Runtime versions and your Mac's model and macOS version.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Sending…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(trimmed.isEmpty ? "Just send" : "Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// The profile without what's only of use on this Mac: the person's own pictures and the note of its origin.
    private var shareable: String {
        var profile = ProfileText(text: profiles.text(of: profileID) ?? builtProfile)
        let original = profiles.bundledText(of: profileID).map(ProfileText.init(text:))
        for key in ["icon", "cover"] where original?.first(key, in: "app") != profile.first(key, in: "app") {
            profile.set(key, nil, in: "app")
        }
        for key in ["cover-style", "icon-style"] { profile.set(key, nil, in: "app") }
        let body = profile.text.components(separatedBy: "\n").drop { $0.hasPrefix(UserProfiles.basedOnPrefix) }
        return LogCollector.scrub(body.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                let block = manager.reportBlock(for: item, recording: nil, profile: profiles.reportTag(of: profileID),
                                                rating: rating.rawValue, frames: FrameStats.latest(for: item)?.summary)
                NSWorkspace.shared.open(try await ReportRelay.send(title: "Profile: \(item.app.name) + \(rating.title)",
                                                                   what: LogCollector.scrub(trimmed), block: block, zip: nil,
                                                                   screenshot: nil, profile: shareable))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
