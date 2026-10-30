import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

// The report hotkey, ⌃⌘R: while a Windows program is frontmost, it takes a screenshot of that program's window and
// opens the report window over it (ReportCenter.swift), for the title or, for a program that isn't one, for OverPass.
// It only works while OverPass is open. The key is only claimed while a Windows program is in front,
// so other Mac apps keep it. The screenshot needs Screen Recording permission, which macOS asks for the first time.
@MainActor
final class ReportHotKey {
    static let shared = ReportHotKey()
    static let display = "⌃⌘R"
    weak var manager: BottleManager?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func start(_ manager: BottleManager) {
        self.manager = manager
        // Each new main window starts this again.
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in await ReportHotKey.shared.pressed() }
            return noErr
        }, 1, &spec, nil, &handler)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ReportHotKey.shared.frontmostChanged(app) }
        }
        frontmostChanged(NSWorkspace.shared.frontmostApplication)
    }

    private func frontmostChanged(_ app: NSRunningApplication?) {
        // By its executable: a list of Wine's windows can lack a program that came to the front just now.
        let isWine = app.map { manager?.runsWine($0) ?? false } ?? false
        if isWine && hotKey == nil {
            let id = EventHotKeyID(signature: OSType(0x4F505250), id: 1) // "OPRP"
            RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
        } else if !isWine, let key = hotKey {
            UnregisterEventHotKey(key)
            hotKey = nil
        }
    }

    private func pressed() async {
        guard let manager, let app = NSWorkspace.shared.frontmostApplication else { return }
        let item = manager.reportItem(forProcess: app.processIdentifier)
        let screenshot = await Self.capture(pid: app.processIdentifier)
        if let item {
            ReportCenter.shared.show(ReportContext(item: item, mode: .inGame, screenshot: screenshot))
        } else {
            ReportCenter.shared.showAppReport(.issue, screenshot: screenshot, overGame: true)
        }
    }

    /// The program's largest window on screen, at full resolution; nil without Screen Recording permission, which
    /// macOS asks for the first time.
    static func capture(pid: pid_t) async -> NSImage? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.frame.width > 64 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                     configuration: configuration) else { return nil }
        let picture = NSImage(size: window.frame.size)
        picture.addRepresentation(NSBitmapImageRep(cgImage: image))
        return picture
    }
}
