import AppKit

/// The titles started from OverPass most recently, newest first, by library ID.
enum RecentTitles {
    static let key = "recentTitles"

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ id: String) {
        UserDefaults.standard.set(Array(([id] + ids.filter { $0 != id }).prefix(10)), forKey: key)
    }
}

/// The Dock icon's menu, and its badge: how many Windows titles are running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: BottleManager?
    var profiles: ProfileStore?
    var components: ComponentManager?
    private var badgeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdate.showUpdateFailure()
        badgeTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let manager = self.manager {
                    let count = self.running(in: manager).count
                    NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let manager else { return nil }
        let menu = NSMenu()
        let library = manager.library

        // Running titles: bring OverPass forward with them, or end one that hangs.
        let running = running(in: manager)
        if !running.isEmpty {
            menu.addItem(.sectionHeader(title: "Running"))
            for (item, processes) in running {
                let entry = NSMenuItem(title: item.app.name, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.addItem(action("Force Quit") {
                    for p in processes { kill(p.pid, SIGKILL) }
                })
                sub.addItem(action("Quit Everything in “\(item.bottle.name)”") {
                    Task { await manager.quitEverything(in: item.bottle) }
                })
                entry.submenu = sub
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }

        let recent = RecentTitles.ids.compactMap { id in library.first { $0.id == id } }.prefix(3)
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: "Recent"))
            for item in recent { menu.addItem(launchItem(item, manager: manager)) }
            menu.addItem(.separator())
        }

        if let profiles {
            let clients = manager.installedClients(from: profiles).compactMap { launcher in
                manager.games(of: launcher).first { manager.isClient($0, of: launcher) }
            }
            if !clients.isEmpty {
                menu.addItem(.sectionHeader(title: "Game Clients"))
                for item in clients { menu.addItem(launchItem(item, manager: manager)) }
                menu.addItem(.separator())
            }
        }

        let favoriteIDs = Favorites.ids(UserDefaults.standard.string(forKey: ViewOptions.favoritesKey) ?? "")
        let favorites = library.filter { favoriteIDs.contains($0.id) }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        if !favorites.isEmpty {
            let entry = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for item in favorites { sub.addItem(launchItem(item, manager: manager)) }
            entry.submenu = sub
            menu.addItem(entry)
        }

        menu.addItem(action("Install a Game or App…") { Self.perform(.dockInstall) })
        if !manager.bottles.isEmpty {
            menu.addItem(action("Quick Run…") { Self.perform(.dockQuickLaunch) })
            menu.addItem(.separator())
            menu.addItem(action("Stop All Windows Programs") {
                Task { for bottle in manager.bottles where !bottle.isMac { await manager.quitEverything(in: bottle) } }
            })
        }
        if let components, !components.updates.isEmpty {
            menu.addItem(.separator())
            menu.addItem(action("Updates Available…") {
                NSApp.activate()
                UpdateCheck.openComponents?()
            })
        }
        return menu
    }

    /// Each library title with a program running in its bottle, matched by the program's name.
    private func running(in manager: BottleManager) -> [(LibraryItem, [WineProcess])] {
        var found: [(LibraryItem, [WineProcess])] = []
        for bottle in manager.bottles where !bottle.isMac {
            let processes = manager.runningPrograms(in: bottle)
            guard !processes.isEmpty else { continue }
            for item in manager.library where item.bottle.path == bottle.path {
                guard let target = item.app.target else { continue }
                let name = URL(fileURLWithPath: target.replacingOccurrences(of: "\\", with: "/"))
                    .deletingPathExtension().lastPathComponent.lowercased()
                let mine = processes.filter { $0.displayName.lowercased() == name }
                if !mine.isEmpty { found.append((item, mine)) }
            }
        }
        return found
    }

    private func launchItem(_ item: LibraryItem, manager: BottleManager) -> NSMenuItem {
        action(item.app.name) { try? manager.launchApp(item.app, in: item.bottle) }
    }

    private func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        .action(title, run)
    }

    /// Asks the main window to open one of its sheets, bringing OverPass forward first.
    private static func perform(_ name: Notification.Name) {
        NSApp.activate()
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: name, object: nil)
    }
}

extension Notification.Name {
    static let dockInstall = Notification.Name("OverPassDockInstall")
    static let dockQuickLaunch = Notification.Name("OverPassDockQuickLaunch")
}

extension NSMenuItem {
    /// A menu item that runs a closure.
    static func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(DockAction.run), keyEquivalent: "")
        let target = DockAction(run)
        item.target = target
        item.representedObject = target   // the menu item keeps its target alive
        return item
    }
}

private final class DockAction: NSObject {
    let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @MainActor @objc func run() { body() }
}
