import AppKit

// OverPass has no use for the Edit and Window menus, a second Settings… item or for window tabs. The menus are hidden from the
// menu bar, but text fields still need their shortcuts, which normally live in the Edit menu, so those
// keys are sent to the first responder here instead.
@MainActor
enum MenuTrim {
    private static let removedTitles: Set<String> = ["Edit", "Window"]

    private static let shortcuts: [(key: String, modifiers: NSEvent.ModifierFlags, action: Selector)] = [
        ("x", [.command], #selector(NSText.cut(_:))),
        ("c", [.command], #selector(NSText.copy(_:))),
        ("v", [.command], #selector(NSText.paste(_:))),
        ("a", [.command], #selector(NSText.selectAll(_:))),
        ("z", [.command], Selector(("undo:"))),
        ("z", [.command, .shift], Selector(("redo:"))),
        ("m", [.command], #selector(NSWindow.performMiniaturize(_:))),
    ]

    static func install() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // SwiftUI rebuilds the menu bar whenever the commands change, so trim it every time.
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let menu = note.object as? NSMenu, menu == NSApp.mainMenu || menu == NSApp.mainMenu?.items.first?.submenu {
                    trim()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { trim() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard let key = event.charactersIgnoringModifiers?.lowercased(),
                  let match = shortcuts.first(where: { $0.key == key && $0.modifiers == modifiers })
            else { return event }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return nil }
            return NSApp.sendAction(match.action, to: nil, from: nil) ? nil : event
        }
    }

    private static func trim() {
        guard let menu = NSApp.mainMenu else { return }
        // Hidden rather than removed: SwiftUI keeps inserting by index while it builds the menu bar.
        for item in menu.items where removedTitles.contains(item.title) && !item.isHidden {
            item.isHidden = true
        }
        // The Settings scene adds its own Settings… near the end of the app menu; ours sits at the top, under
        // About, so the later one is hidden.
        let settings = menu.items.first?.submenu?.items.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command } ?? []
        for item in settings.dropFirst() where !item.isHidden { item.isHidden = true }
    }
}
