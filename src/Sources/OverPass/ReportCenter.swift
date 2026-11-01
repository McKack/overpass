import SwiftUI
import AppKit

// The report windows for a title: the report hotkey while a game runs (with a screenshot of it attached) and a crash
// Wine caught get ReportView; a title's How Did It Run?… and the end of a run recorded for it get RunReportView
// (RunReport.swift). Reports on OverPass itself have windows of their own (AppCrash.swift, AppReport.swift). They float
// over the game, also in full screen, and send through the relay (ReportRelay.swift) or, without one, as a prefilled
// GitHub issue with the zip on the Desktop.

enum ReportMode {
    /// How Did It Run?… on a title.
    case title
    /// The report hotkey while the title runs.
    case inGame
    /// Wine's crash handler came up.
    case crash
    /// A run with extra debugging has ended.
    case afterRun
}

struct ReportContext: Identifiable {
    let id = UUID()
    let item: LibraryItem
    let mode: ReportMode
    var screenshot: NSImage? = nil
    /// The recorded run's log (afterRun, or a crash during one).
    var recording: LogRecording? = nil
    var description = ""
    /// The profile editor's profile, instead of the stored one.
    var profileText: String? = nil
    /// What the person chose before a recorded run, for the window afterwards.
    var rating: GameProfile.Rating.Tier? = nil
    var sharesSettings: Bool? = nil
}

@MainActor
final class ReportCenter: NSObject, NSWindowDelegate {
    static let shared = ReportCenter()
    weak var manager: BottleManager?
    weak var profiles: ProfileStore?
    private var panel: NSPanel?

    /// A panel that takes key focus for typing even while another app's full-screen window is in front.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func show(_ context: ReportContext) {
        guard let manager, let profiles else { return }
        panel?.close()
        let close: () -> Void = { [weak self] in self?.panel?.close() }
        switch context.mode {
        case .title:
            present(RunReportView(context: context, close: close).environment(manager).environment(profiles), level: .floating)
        case .afterRun:
            present(RunReportView(context: context, close: close).environment(manager).environment(profiles), level: .screenSaver)
        case .inGame, .crash:
            present(ReportView(context: context, close: close).environment(manager).environment(profiles), level: .screenSaver)
        }
    }

    /// The report window for OverPass's own crash last time.
    func showAppCrash(_ report: URL, summary: AppCrash.Summary) {
        panel?.close()
        present(AppCrashView(report: report, summary: summary) { [weak self] in self?.panel?.close() }, level: .floating)
    }

    /// The Help menu's report on OverPass or feature request; also the hotkey's, over a program that's no title.
    func showAppReport(_ kind: AppReportKind, screenshot: NSImage? = nil, overGame: Bool = false) {
        panel?.close()
        present(AppReportView(kind: kind, screenshot: screenshot, overGame: overGame) { [weak self] in self?.panel?.close() },
                level: overGame ? .screenSaver : .floating)
    }

    func closePanel() { panel?.close() }

    private func present(_ view: some View, level: NSWindow.Level) {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.contentViewController = NSHostingController(rootView: view)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Over a game in full screen too: in its Space, above its window.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = level
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel { panel = nil }
    }
}

struct ReportView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    let context: ReportContext
    let close: () -> Void
    @State private var description = ""
    @State private var includeLog = true
    @State private var screenshot: NSImage?
    @State private var excerpt: String?
    @State private var sending = false
    @State private var error: String?

    private var item: LibraryItem { context.item }
    private var name: String { item.app.name }
    private var lastRun: Date? { LogCollector.lastRunLogs(for: item).first.map(LogCollector.modified) }

    private var profileTag: String? { profiles.profile(for: item).map { profiles.reportTag(of: $0.id) } }

    /// Whether a log goes with the report.
    private var hasLog: Bool { context.recording != nil || lastRun != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ReportStep(number: 1, title: "What happened?", isLast: false) { whatHappened }
                ReportStep(number: 2, title: "Attachments", isLast: true) { attachments }
            }
            ReportPrivacyNote()
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Sending…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Send Report", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 540)
        .onAppear {
            description = context.description
            screenshot = context.screenshot
        }
        .task { excerpt = await loadExcerpt() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(item: item, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.mode == .crash ? "\(name) Crashed" : "Report an Issue with \(name)").font(.title3.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        if context.mode == .crash { return "Wine caught a crash. A report with the log helps get it fixed." }
        return context.screenshot == nil ? "Tell us what went wrong in \(name)."
            : "A screenshot of \(name) is attached. Tell us what went wrong."
    }

    // MARK: Steps

    private var whatHappened: some View {
        ReportTextEditor(text: $description, placeholder: "Explain the issue you encountered with \(name). Are you able to make it happen again, and if so, how?")
    }

    @ViewBuilder private var attachments: some View {
        if hasLog {
            VStack(alignment: .leading, spacing: 6) {
                if let excerpt {
                    ScrollView {
                        Text(excerpt).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 84)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                Toggle("Include the log and details", isOn: $includeLog)
                Text("Wine's log, your Mac's and the container's details and the game engine's own logs help find the cause.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 10) {
            if let screenshot {
                Image(nsImage: screenshot).resizable().scaledToFit()
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                Button("Remove") { self.screenshot = nil }
            } else {
                Button("Attach Screenshot…") { screenshot = Self.chooseScreenshot() ?? screenshot }
            }
        }
        if context.mode == .inGame && context.screenshot == nil && !CGPreflightScreenCaptureAccess() {
            HStack(spacing: 6) {
                Text("To attach a screenshot of the game by itself, allow OverPass to record the screen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private var profileText: String? {
        profiles.profile(for: item).flatMap { profiles.text(of: $0.id) }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                var recording = context.recording
                if includeLog && hasLog && recording == nil {
                    recording = try await manager.lastLogs(item, profile: profileTag, profileText: profileText)
                }
                if !includeLog, let unused = recording {
                    try? FileManager.default.removeItem(at: unused.folder)
                    recording = nil
                }
                let jpeg = screenshot.flatMap(Self.jpeg)
                let block = manager.reportBlock(for: item, recording: recording, profile: profileTag)
                let firstLine = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? "problem report"
                let title = "\(name): " + String(firstLine.prefix(80))
                if ReportRelay.url != nil {
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("OverPass Reports")
                    let zip = await recording.asyncMap { await manager.makeZip($0, screenshot: jpeg, in: temp) }
                    let issue = try await ReportRelay.send(title: title, what: description, block: block, zip: zip, screenshot: jpeg)
                    if let zip { try? FileManager.default.removeItem(at: zip) }
                    NSWorkspace.shared.open(issue)
                } else {
                    let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    if let recording {
                        NSWorkspace.shared.activateFileViewerSelecting([await manager.makeZip(recording, screenshot: jpeg, in: desktop)])
                    } else if let jpeg {
                        let file = desktop.appendingPathComponent("OverPass Screenshot – \(name).jpg")
                        try? jpeg.write(to: file)
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    if let url = LogCollector.issueURL(title: title, what: description, block: block) { NSWorkspace.shared.open(url) }
                }
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    /// A JPG or PNG the person picks, which is what GitHub takes when it's added to the issue by hand.
    static func chooseScreenshot() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = "Choose a screenshot."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return NSImage(contentsOf: url)
    }

    private func loadExcerpt() async -> String? {
        guard hasLog, let url = context.recording?.logURL ?? LogCollector.lastRunLogs(for: item).first else { return nil }
        return await Self.excerpt(of: url, crash: context.mode == .crash)
    }

    /// The end of a log that goes with a report; for a crash, from Wine's first crash line.
    static func excerpt(of url: URL, crash: Bool) async -> String? {
        return await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if crash, let start = lines.lastIndex(where: { $0.contains("Unhandled") || $0.contains("Backtrace") || $0.contains("page fault") }) {
                lines = Array(lines[start...])
                return lines.prefix(30).joined(separator: "\n")
            }
            return lines.suffix(14).joined(separator: "\n").nilIfEmpty ?? "The log is empty."
        }.value
    }

    /// The screenshot as it's sent: at most 1080 pixels high (an ultrawide keeps its width to height), 90% JPEG.
    nonisolated static func jpeg(_ image: NSImage) -> Data? {
        // The bitmap's own pixels: an image's cgImage(forProposedRect:) can come back at its size in points.
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
        guard let cg = bitmap?.cgImage ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1080 / Double(cg.height))
        let width = Int((Double(cg.width) * scale).rounded()), height = Int((Double(cg.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

/// The field a report's text goes in.
struct ReportTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 90

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct ReportPrivacyNote: View {
    var body: some View {
        Label("No personal information is included: your name, home folder, computer name and e-mail addresses are "
              + "taken out of everything that's sent.", systemImage: "lock.shield")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ReportHotKeyHint: View {
    var body: some View {
        Label("While a game runs and OverPass is open, press \(ReportHotKey.display) to report from inside the game, "
              + "with a screenshot of it.", systemImage: "keyboard")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One step of the report window: a numbered circle, a line down to the next step, the title and its content.
struct ReportStep<Content: View>: View {
    let number: Int
    let title: String
    let isLast: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text("\(number)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                if !isLast {
                    Rectangle().fill(.separator).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).frame(height: 26)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 0 : 20)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
