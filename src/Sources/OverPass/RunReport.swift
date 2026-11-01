import SwiftUI
import AppKit

// "How did it run?": the one window for telling OverPass how a title ran, from the title's menus and the profile
// editor. It gathers the facts, the logs and the settings to share and uploads them to the report relay as a draft, then
// opens the site's page for it, where the person sets the medal and writes the comment and sends it. Sending logs also
// files an issue, and sharing settings sends the profile for review; the title has to have been started first (it may
// have failed: that's what Borked is for). The details block's `kind` and `rating` tell the report check and the relay
// what it is.

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

/// Where the logs of a run come from.
enum RunLogSource: Hashable {
    case lastRun, debugRun
}

struct RunReportView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    let context: ReportContext
    let close: () -> Void
    @State private var rating: GameProfile.Rating.Tier?
    @State private var sendLogs = false
    /// The person set Send logs themselves, so the medal no longer decides it.
    @State private var logsChosen = false
    @State private var logSource = RunLogSource.lastRun
    @State private var channels = LogCollector.defaultChannels
    @State private var share = false
    @State private var screenshot: NSImage?
    @State private var excerpt: String?
    @State private var started = false
    /// Kept between tries: making the zip uses up a recording.
    @State private var zip: URL?
    @State private var sending = false
    @State private var error: String?

    private var item: LibraryItem { context.item }
    private var name: String { item.app.name }
    private var profile: GameProfile? { profiles.profile(for: item) }
    private var profileTag: String? { profile.map { profiles.reportTag(of: $0.id) } }
    private var lastRun: Date? { LogCollector.lastRunLogs(for: item).first.map(LogCollector.modified) }

    private var low: Bool { rating == .bronze || rating == .borked }
    /// Whether confirming starts the title with Wine's log on, rather than sending.
    private var runsFirst: Bool { sendLogs && logSource == .debugRun && context.recording == nil }
    private var canSend: Bool { rating != nil && (started || context.recording != nil) }

    private var changed: Bool { profile.map { profiles.edited.contains($0.id) || profiles.custom.contains($0.id) } == true }
    /// A title with neither a program nor a Steam ID can't keep settings, so it has none to share.
    private var canShare: Bool {
        (item.app.programName != nil || (item.app.launcher == "Steam" && item.app.storeID != nil)) && (changed || profile == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppIcon(item: item, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How did \(name) run?").font(.title3.bold())
                    Text("Your rating goes on the game's page, to help others playing it on a Mac. You finish it in your browser.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            MedalPicker(selection: $rating)
            if !started && context.recording == nil {
                Text("Run \(name) once first, even if it doesn't start: a rating needs a run.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            logs
            if canShare {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Share my settings", isOn: $share)
                    Text(changed ? "Your changes to this title's profile go to OverPass for review, so others can get them."
                         : "This title has no profile yet. Sends what OverPass knows about it for review.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Shown with your rating: the frame rate of the last run, your OverPass, Wine and Runtime versions, your Mac's chip "
                 + "and macOS version. A random ID for this install, never shown, lets a new rating replace your last one.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ReportPrivacyNote()
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Uploading…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(runsFirst ? "Run \(name)" : "Continue in Browser", action: runsFirst ? runWithDebugging : send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || !(runsFirst || canSend))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 540)
        .onAppear {
            rating = context.rating
            screenshot = context.screenshot
            started = manager.hasStarted(item)
            share = context.sharesSettings ?? changed
            if context.recording != nil { sendLogs = true; logsChosen = true } else { sendLogs = low }
            if lastRun == nil { logSource = .debugRun }
        }
        .onChange(of: rating) { if !logsChosen { sendLogs = low } }
        .task(id: "\(sendLogs) \(logSource)") { excerpt = await loadExcerpt() }
    }

    @ViewBuilder private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Send logs, so this can be looked into", isOn: Binding(get: { sendLogs }, set: { sendLogs = $0; logsChosen = true }))
            if sendLogs {
                if context.recording == nil {
                    Picker("Logs:", selection: $logSource) {
                        Text(lastRun.map { "The last run (\($0.formatted(.relative(presentation: .named))))" } ?? "The last run (none found)")
                            .tag(RunLogSource.lastRun)
                            .selectionDisabled(lastRun == nil)
                        Text("Run \(name) with extra debugging").tag(RunLogSource.debugRun)
                    }
                    .fixedSize()
                }
                if runsFirst {
                    TextField("Debug channels:", text: $channels)
                        .font(.body.monospaced())
                    Text("\(name) runs with Wine's log on. Do what causes the problem, then quit it; this window comes back with "
                         + "the log." + (manager.runningPrograms(in: item.bottle).isEmpty ? "" : " Programs running in its "
                         + "container are quit first."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    if let excerpt {
                        ScrollView {
                            Text(excerpt).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 72)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack(spacing: 10) {
                        if let screenshot {
                            Image(nsImage: screenshot).resizable().scaledToFit()
                                .frame(height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                            Button("Remove") { self.screenshot = nil }
                        } else {
                            Button("Attach Screenshot…") { screenshot = ReportView.chooseScreenshot() ?? screenshot }
                        }
                    }
                }
                Text("Files a public issue on GitHub with Wine's log, your Mac's and the container's details and the game engine's own logs.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ReportHotKeyHint()
            }
        }
    }

    private var profileText: String? {
        context.profileText ?? profile.flatMap { profiles.text(of: $0.id) }
    }

    /// The profile without what's only of use on this Mac: the person's own pictures and the note of its origin.
    private var shareable: String {
        var text = ProfileText(text: profileText ?? item.newProfileText)
        let original = profile.flatMap { profiles.bundledText(of: $0.id) }.map(ProfileText.init(text:))
        for key in ["icon", "cover"] where original?.first(key, in: "app") != text.first(key, in: "app") {
            text.set(key, nil, in: "app")
        }
        for key in ["cover-style", "icon-style"] { text.set(key, nil, in: "app") }
        let body = text.text.components(separatedBy: "\n").drop { $0.hasPrefix(UserProfiles.basedOnPrefix) }
        return LogCollector.scrub(body.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runWithDebugging() {
        Task {
            if !manager.runningPrograms(in: item.bottle).isEmpty { await manager.quitEverything(in: item.bottle) }
            do {
                try manager.startLogging(item, profile: profileTag, profileText: profileText, channels: channels,
                                         description: context.description, rating: rating, sharesSettings: share)
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func send() {
        guard let rating else { return }
        sending = true
        error = nil
        Task {
            do {
                var recording = context.recording
                if sendLogs && recording == nil {
                    recording = try await manager.lastLogs(item, profile: profileTag, profileText: profileText)
                }
                if !sendLogs, let unused = recording {
                    try? FileManager.default.removeItem(at: unused.folder)
                    recording = nil
                }
                let jpeg = sendLogs ? screenshot.flatMap(ReportView.jpeg) : nil
                let sharing = canShare && share
                let block = manager.reportBlock(for: item, recording: recording, profile: profileTag, rating: rating.rawValue,
                                                sendsProfile: sharing, frames: FrameStats.latest(for: item)?.summary)
                if let recording, zip == nil {
                    zip = await manager.makeZip(recording, screenshot: jpeg,
                                                in: FileManager.default.temporaryDirectory.appendingPathComponent("OverPass Reports"))
                }
                let page = try await ReportRelay.send(endpoint: "draft", title: "", what: LogCollector.scrub(context.description), block: block,
                                                      zip: sendLogs ? zip : nil, screenshot: jpeg,
                                                      profile: sharing ? shareable : nil, install: InstallID.value)
                if let zip { try? FileManager.default.removeItem(at: zip) }
                NSWorkspace.shared.open(page)
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    /// The end of the log that would go out.
    private func loadExcerpt() async -> String? {
        guard sendLogs, !runsFirst, let url = context.recording?.logURL ?? LogCollector.lastRunLogs(for: item).first else { return nil }
        return await ReportView.excerpt(of: url, crash: false)
    }
}

/// The five medals in a row, with what the chosen one means under them.
struct MedalPicker: View {
    @Binding var selection: GameProfile.Rating.Tier?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(GameProfile.Rating.Tier.allCases.filter { $0 != .untested }, id: \.self) { tier in
                    Button { selection = tier } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "medal.fill").font(.title2).foregroundStyle(tier.color)
                            Text(tier.title).font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(selection == tier ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == tier ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(tier.summary)
                }
            }
            Text(selection?.summary ?? "Choose a medal.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
