import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--launch" {
            MainActor.assumeIsolated { WrapperLaunch.run(bottlePath: args[2], program: args[3], arguments: Array(args.dropFirst(4))) }
        }
        OverPassApp.main()
    }
}

struct OverPassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var manager = BottleManager()
    @State private var profiles = ProfileStore()
    @State private var components: ComponentManager

    init() {
        AppUpdate.moveOldSettings()
        MediaCache.migrate()
        let components = ComponentManager()
        _components = State(initialValue: components)
        MenuTrim.install()
        // Runs for the app's lifetime, whichever windows are open.
        Task { await UpdateCheck.run(components) }
    }
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedSetup {
                    ContentView()
                } else {
                    SetupWizardView {
                        hasCompletedSetup = true
                    }
                }
            }
            .environment(manager)
            .environment(profiles)
            .environment(components)
            .task {
                delegate.manager = manager
                delegate.profiles = profiles
                ReportCenter.shared.manager = manager
                ReportCenter.shared.profiles = profiles
                ReportHotKey.shared.start(manager)
                if let report = AppCrash.unseen(), let summary = AppCrash.summary(of: report) {
                    ReportCenter.shared.showAppCrash(report, summary: summary)
                }
                delegate.components = components
                manager.profiles = profiles
                // Wrappers made before the profiles loaded lack their names and backgrounds.
                manager.loadBottles()
            }
            // Programs opened from Finder go to the open window, not a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 980, height: 640)
        .commands { OverPassCommands() }

        WindowGroup("Profile", id: ProfileWindow.id, for: String.self) { $itemID in
            ProfileWindow(itemID: itemID)
                .environment(manager)
                .environment(profiles)
                .environment(components)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Window("About OverPass", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Credits", id: "credits") {
            CreditsView()
        }
        .defaultSize(width: 600, height: 640)

        Settings {
            SettingsView()
                .environment(manager)
                .environment(components)
        }
    }
}

// MARK: - Main window

enum SidebarItem: Hashable {
    case home
    case library
    case favorites
    case launcher(String)
    /// A category the user made, by its ID.
    case category(String)
    case builtIn(BuiltInCategory)
    case bottles
    case bottle(URL)
}

struct ContentView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.openSettings) private var openSettings
    @State private var selection: SidebarItem? = .home
    @AppStorage(ViewOptions.favoritesKey) private var favorites = ""
    private var favoriteIDs: Set<String> { Favorites.ids(favorites) }
    @AppStorage(ViewOptions.categoriesKey) private var categories = ""
    @State private var installRequest: InstallRequest?
    @State private var itemSheet: ItemSheet?
    @State private var showRunCommand = false
    @State private var statusText = ""
    @State private var searchText = ""
    /// The store being signed in to, by its bottle group.
    @State private var connecting: StoreConnection?
    @State private var detailWidth: CGFloat = 1000
    @State private var columns = NavigationSplitViewVisibility.all
    /// Pages visited, for Back and Forward; `historyIndex` is the one showing.
    @State private var history: [SidebarItem] = [.home]
    @State private var historyIndex = 0
    @State private var movingInHistory = false

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    private func go(_ step: Int) {
        let index = historyIndex + step
        guard history.indices.contains(index) else { return }
        historyIndex = index
        movingInHistory = true
        selection = history[index]
    }

    /// Records a page picked in the sidebar or the Go menu; it drops whatever was ahead of the current one.
    private func visited(_ item: SidebarItem?) {
        guard let item else { return }
        if movingInHistory { movingInHistory = false; return }
        guard history[historyIndex] != item else { return }
        history = Array(history.prefix(historyIndex + 1)) + [item]
        historyIndex = history.count - 1
    }

    private var pageTitle: String {
        switch selection {
        case .library: "All Titles"
        case .favorites: "Favorites"
        case .launcher(let id): profiles.profiles.first { $0.id == id }?.name ?? "Game Client"
        case .category(let id): UserCategories.list(categories).first { $0.id == id }?.name ?? "Category"
        case .builtIn(let category): category.name
        case .bottles: "Containers"
        case .bottle(let path): manager.bottles.first { $0.path == path }?.name ?? "Container"
        default: "Home"
        }
    }

    private var showsLayouts: Bool {
        switch selection {
        case .library, .favorites, .launcher, .category, .builtIn, .bottles: true
        default: false
        }
    }

    /// The window's own buttons. They hang off an overlay after the page so they come after the page's
    /// items in toolbar order and stay on the right, while a page puts its controls in the middle.
    private var windowToolbar: some View {
        Color.clear
            .allowsHitTesting(false)
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }
                // A store category's account, hugging the search field.
                if case .launcher(let id) = selection,
                   let group = profiles.profiles.first(where: { $0.id == id })?.bottle.group,
                   let store = BuiltInLibrary.store(for: group), let account = store.account {
                    ToolbarItem(placement: .automatic) { StoreAccountMenu(store: store, account: account) }
                }
                // Search shrinks to a button when the window is narrow.
                ToolbarItem(placement: .automatic) {
                    ToolbarSearch(text: $searchText, compact: detailWidth < 720,
                                  prompt: showsLayouts ? "Search \(pageTitle)" : "Search")
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed)
                }
                // Pages put Install and Quick Run in the middle; a container's page has no toolbar of its own.
                if case .bottle = selection {
                    ToolbarItemGroup(placement: .automatic) { WindowActionButtons() }
                }
            }
    }

    /// A store's category in the sidebar, by the store's bottle group.
    private func showStore(_ group: String) {
        if let profile = profiles.profiles.first(where: { $0.category == "Game Launcher" && $0.bottle.group == group }) {
            selection = .launcher(profile.id)
        }
    }

    /// Adds a profile file someone shared.
    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .plainText]
        panel.message = "Choose an OverPass profile (.ini) to add. One with the same file name as an existing profile replaces it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profiles.importProfile(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Import the Profile"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Adds a container someone exported (ContainerArchive.swift) and opens it when it's ready.
    private func importContainer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gzip, .archive]
        panel.message = "Choose an exported container (.tar.gz). It's added to \(ContainerLocations.displayName(of: ContainerLocations.favorite)) under a name of its own."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let bottle = await manager.importBottle(from: url) { selection = .bottle(bottle.path) }
        }
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .bottle(let path):
            if let bottle = manager.bottles.first(where: { $0.path == path }) {
                BottleSettings(bottle: bottle, page: true)
                    .id(path)
            } else {
                LibraryView { selection = .home }
            }
        case .library:
            LibraryView { selection = .home }
        case .favorites:
            LibraryView(favoritesOnly: true) { selection = .home }
        case .bottles:
            BottlesView(importContainer: importContainer) { selection = .bottle($0.path) }
        case .launcher(let id):
            LibraryView(launcher: profiles.profiles.first { $0.id == id }) { selection = .home }
                .id(id)
        case .category(let id):
            LibraryView(categoryID: id) { selection = .home }
                .id(id)
        case .builtIn(let category):
            LibraryView(builtIn: category) { selection = .home }
                .id(category)
        default:
            HomeView(installRequest: $installRequest)
        }
    }

    var body: some View {
        // The status bar is its own row under the split view, so it pushes the sidebar and content up
        // instead of covering their last rows.
        VStack(spacing: 0) {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                page
                    .overlay { windowToolbar }
                    .frame(maxHeight: .infinity)
                StatusBar(text: statusText, showsSize: showsLayouts)
            }
            .onPreferenceChange(StatusTextKey.self) { statusText = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
            .environment(\.searchText, searchText)
            .environment(\.windowActions, WindowActions(install: { installRequest = InstallRequest() },
                                                        quickRun: { showRunCommand = true },
                                                        canQuickRun: !manager.bottles.isEmpty))
        }
        .environment(\.storeActions, StoreActions(connect: { connecting = StoreConnection(group: $0) }, show: showStore))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { go(-1) } label: { Label("Back", systemImage: "chevron.left") }
                    .help("See the page you were on before")
                    .disabled(!canGoBack)
                Button { go(1) } label: { Label("Forward", systemImage: "chevron.right") }
                    .help("See the next page")
                    .disabled(!canGoForward)
            }
            // The page's name is a menu of the sidebar's pages: always with the sidebar hidden, and beside
            // it too while the window has room.
            if columns == .detailOnly || detailWidth >= 940 {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        let clients = manager.installedClients(from: profiles)
                        Button("Home") { selection = .home }
                        Button("All Titles") { selection = .library }
                        if manager.library.contains(where: { favoriteIDs.contains($0.id) }) {
                            Button("Favorites") { selection = .favorites }
                        }
                        let userCategories = UserCategories.list(categories)
                        let builtIn = BuiltInCategory.allCases.filter { !manager.titles(in: $0).isEmpty }
                        if !clients.isEmpty || !builtIn.isEmpty || !userCategories.isEmpty {
                            Section("Categories") {
                                ForEach(clients) { client in Button(client.name) { selection = .launcher(client.id) } }
                                ForEach(builtIn) { category in Button(category.name) { selection = .builtIn(category) } }
                                ForEach(userCategories) { category in
                                    Button(category.name) { selection = .category(category.id) }
                                }
                            }
                        }
                        if !manager.bottles.isEmpty {
                            Divider()
                            Button("Containers") { selection = .bottles }
                        }
                    } label: {
                        Text(pageTitle)
                    }
                    .help("Go to another page")
                }
            }
        }
        // The page says where you are in the status bar; the window title stays for the Window menu and Mission Control.
        .toolbar(removing: .title)
        // Uninstall and the profile sheets for the sidebar and the pages that don't present their own.
        .itemSheets($itemSheet)
        .onChange(of: selection) { _, item in visited(item) }
        // A deleted category leaves its page, and Back and Forward skip it.
        .onChange(of: categories) {
            let ids = Set(UserCategories.list(categories).map(\.id))
            func gone(_ item: SidebarItem) -> Bool {
                if case .category(let id) = item { return !ids.contains(id) }
                return false
            }
            guard history.contains(where: gone) else { return }
            let before = history.prefix(historyIndex).filter { !gone($0) }
            if gone(history[historyIndex]) {
                // Its page was showing: go to All Titles, dropping the pages ahead.
                history = before + [.library]
                historyIndex = history.count - 1
                movingInHistory = true
                selection = .library
            } else {
                historyIndex = before.count
                history = history.filter { !gone($0) }
            }
        }
            if !manager.launches.isEmpty || !manager.recipeTasks.isEmpty || !manager.logRecordings.isEmpty {
                LaunchStatusBar()
            }
        }
        .navigationTitle("OverPass")
        .task { UpdateCheck.openComponents = { SettingsTab.open(.components, with: openSettings) } }
        .sheet(item: $connecting) { connection in
            if let store = BuiltInLibrary.store(for: connection.group) {
                StoreConnectSheet(store: store) { signedIn in
                    connecting = nil
                    if signedIn { showStore(connection.group) }
                }
            }
        }
        .sheet(item: $installRequest) { request in
            InstallSheet(initialProfile: request.profile, initialFile: request.file)
        }
        .sheet(isPresented: $showRunCommand) {
            RunCommandSheet(preselected: {
                if case .bottle(let path) = selection { return path }
                return nil
            }())
        }
        .focusedSceneValue(\.mainWindow, MainWindowActions(
            install: { installRequest = InstallRequest() },
            importProfile: importProfile,
            importContainer: importContainer,
            addMacApps: { manager.addMacApps(MacApps.choose()) },
            runProgram: manager.bottles.isEmpty ? nil : { showRunCommand = true },
            selection: $selection,
            clients: manager.installedClients(from: profiles),
            builtInCategories: BuiltInCategory.allCases.filter { !manager.titles(in: $0).isEmpty },
            back: canGoBack ? { go(-1) } : nil,
            forward: canGoForward ? { go(1) } : nil))
        .frame(minWidth: 760, minHeight: 440)
        .task { await AntiCheat.refresh() }
        .onAppear {
            try? FileManager.default.createDirectory(at: Bottle.bottlesDirectory(), withIntermediateDirectories: true)
            manager.detectWine()
            manager.loadBottles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockInstall)) { _ in installRequest = InstallRequest() }
        // A .exe or .msi opened from Finder, also one that started OverPass.
        .onOpenURL { url in
            if url.isFileURL, ["exe", "msi"].contains(url.pathExtension.lowercased()) {
                installRequest = InstallRequest(file: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockQuickLaunch)) { _ in
            if !manager.bottles.isEmpty { showRunCommand = true }
        }
        // Games installed through Steam or Epic while OverPass was in the background show up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.loadBottles()
        }
    }
}

struct StoreConnection: Identifiable {
    let group: String
    var id: String { group }
}

struct InstallRequest: Identifiable {
    let id = UUID()
    var profile: GameProfile?
    /// An installer opened from Finder.
    var file: URL?
}

struct SidebarView: View {
    /// Titles counted in the sidebar: without the hidden ones unless View shows them.
    private func visible(_ items: [LibraryItem]) -> [LibraryItem] { Hidden.visible(items, hidden: hidden, showing: showHidden) }

    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Binding var selection: SidebarItem?
    @AppStorage(ViewOptions.showBottlesKey) private var showBottles = false
    @AppStorage(ViewOptions.showClientIconsKey) private var showClientIcons = false
    @AppStorage(ViewOptions.favoritesKey) private var favorites = ""
    @AppStorage(ViewOptions.categoriesKey) private var categories = ""
    @AppStorage(ViewOptions.hiddenKey) private var hidden = ""
    @AppStorage(ViewOptions.showHiddenKey) private var showHidden = false
    @State private var runningLaunchers: Set<String> = []
    @Environment(\.openItemSheet) private var openItemSheet

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house.fill")
                    .tag(SidebarItem.home)
                Label {
                    HStack {
                        Text("All Titles")
                        Spacer()
                        Text("\(visible(manager.library).count)").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.grid.2x2.fill")
                }
                .tag(SidebarItem.library)
                // Only once something is marked, from a title's context menu.
                let favoriteCount = manager.library.filter { Favorites.ids(favorites).contains($0.id) }.count
                if favoriteCount > 0 {
                    Label {
                        HStack {
                            Text("Favorites")
                            Spacer()
                            Text("\(favoriteCount)").foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "star.fill")
                    }
                    .tag(SidebarItem.favorites)
                }
                // Bottles are an implementation detail most people never need; View › Categories shows them.
                if showBottles {
                    Label {
                        HStack {
                            Text("Containers")
                            Spacer()
                            Text("\(manager.bottles.count)").foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: BottleIcon.symbol)
                    }
                    .tag(SidebarItem.bottles)
                }
            }

            // Each installed game client gets its own list of the games installed through it.
            let launchers = manager.installedClients(from: profiles)
            // The user's own categories follow, like Steam's collections.
            // Then Mac apps and Windows titles no client installed, while there are any.
            let builtIn = BuiltInCategory.allCases.map { ($0, visible(manager.titles(in: $0)).count) }.filter { $0.1 > 0 }
            let userCategories = UserCategories.list(categories)
            if !launchers.isEmpty || !builtIn.isEmpty || !userCategories.isEmpty {
                Section("Categories") {
                    ForEach(launchers) { launcher in
                        LauncherRow(launcher: launcher, showIcon: showClientIcons,
                                    running: runningLaunchers.contains(launcher.id))
                        .tag(SidebarItem.launcher(launcher.id))
                        .contextMenu {
                            if let client = manager.games(of: launcher).first(where: { manager.isClient($0, of: launcher) }) {
                                Button("Uninstall \(launcher.name)…") { openItemSheet(.uninstall(client)) }
                            } else if let bottle = manager.bottle(for: launcher) {
                                Button("Uninstall \(launcher.name)…") { openItemSheet(.uninstallBottle(bottle)) }
                            }
                            if let store = BuiltInLibrary.store(for: launcher.bottle.group), store.account != nil {
                                Button("Sign Out of \(launcher.name)") { Task { await store.signOut() } }
                            }
                            Divider()
                            newCategoryButton
                        }
                    }
                    ForEach(builtIn, id: \.0) { category, count in
                        Label {
                            HStack {
                                Text(category.name)
                                Spacer()
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: category.symbol)
                        }
                        .tag(SidebarItem.builtIn(category))
                        .contextMenu {
                            if category == .mac {
                                Button("Add Mac App to Library…") { manager.addMacApps(MacApps.choose()) }
                                Divider()
                            }
                            newCategoryButton
                        }
                    }
                    ForEach(userCategories) { category in
                        let ids = Set(category.items)
                        Label {
                            HStack {
                                Text(category.name)
                                Spacer()
                                Text("\(visible(manager.library).filter { ids.contains($0.id) }.count)").foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder.fill")
                        }
                        .tag(SidebarItem.category(category.id))
                        .contextMenu {
                            Button("Rename…") {
                                if let name = UserCategories.askName(title: "Rename Category", button: "Rename",
                                                                     initial: category.name) {
                                    UserCategories.renamed(category.id, to: name, stored: &categories)
                                }
                            }
                            Button("Delete Category") { delete(category) }
                            Divider()
                            newCategoryButton
                        }
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .contextMenu { newCategoryButton }
        .bottomFade()
        // Which clients have something running, so their play buttons can't start a second copy.
        .task {
            while !Task.isCancelled {
                runningLaunchers = Set(manager.installedClients(from: profiles).compactMap { launcher in
                    manager.bottle(for: launcher).flatMap { manager.runningPrograms(in: $0).isEmpty ? nil : launcher.id }
                })
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

extension SidebarView {
    private var newCategoryButton: some View {
        Button("New Category…") {
            if let name = UserCategories.askName(title: "New Category", button: "Create") {
                selection = .category(UserCategories.added(name, in: &categories))
            }
        }
    }

    /// Deletes a category after asking; its titles stay in the library.
    private func delete(_ category: UserCategory) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(category.name)”?"
        alert.informativeText = "Its titles stay in your library and in any other category."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserCategories.removed(category.id, stored: &categories)
    }
}

/// A game client's sidebar row. A play button starts the client: in place of its logo while hovering, or always
/// in front of the name when logos are off. It turns into a spinner while the client starts and is disabled
/// while anything runs in the client's bottle.
private struct LauncherRow: View {
    @Environment(BottleManager.self) private var manager
    @AppStorage(ViewOptions.hiddenKey) private var hidden = ""
    @AppStorage(ViewOptions.showHiddenKey) private var showHidden = false
    let launcher: GameProfile
    let showIcon: Bool
    let running: Bool
    @State private var hovering = false
    @State private var launchError: String?

    var body: some View {
        let client = manager.games(of: launcher).first { manager.isClient($0, of: launcher) }
        let opening = client.map { manager.isOpening(in: $0.bottle, program: $0.app.executable) } ?? false
        let logo = showIcon ? StoreIcon.logo(for: launcher.id) : nil
        Label {
            HStack {
                Text(launcher.name)
                Spacer()
                Text("\(Hidden.visible(manager.games(of: launcher, includeClient: false), hidden: hidden, showing: showHidden).count)")
                    .foregroundStyle(.secondary)
            }
        } icon: {
            // A hidden square symbol gives the icon the size every other sidebar icon has.
            Image(systemName: "square.fill").hidden().overlay {
                if opening {
                    ProgressView().controlSize(.mini)
                } else if let client, logo == nil || hovering {
                    Button {
                        do { try manager.launchApp(client.app, in: client.bottle) }
                        catch { launchError = error.localizedDescription }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(running)
                    .help(running ? "\(launcher.name) is running" : "Run \(launcher.name)")
                } else if let logo {
                    Image(nsImage: logo).resizable().scaledToFit()
                } else {
                    Image(systemName: "gamecontroller.fill")
                }
            }
        }
        .onHover { hovering = $0 }
        .alert("Couldn't open \(launcher.name)", isPresented: .constant(launchError != nil)) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }
}

// MARK: - Settings

/// The Settings window's tabs; the selection is remembered, and an update notice opens the Components tab.
enum SettingsTab: String {
    case general, games, components, advanced
    static let key = "settingsTab"

    @MainActor static func open(_ tab: SettingsTab, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
        openSettings()
        NSApp.activate()
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
                GameSettings().tabItem { Label("Games", systemImage: "gamecontroller") }.tag(SettingsTab.games)
                ComponentsView().tabItem { Label("Components", systemImage: "puzzlepiece.extension") }.tag(SettingsTab.components)
                AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
            }
            Divider()
            HStack {
                Text(Self.about(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                // For every tab: plain names and descriptions, or the technical ones.
                DetailSwitch()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 620, height: 600)
    }

    /// OverPass's version and the Mac it runs on; Technical adds the build, memory and Wine.
    private static func about(_ detail: SettingsDetail) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        let chip = LogCollector.sysctl("machdep.cpu.brand_string") ?? "Mac"
        guard detail == .technical else { return "OverPass \(version) · \(macOS) · \(chip)" }
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let memory = "\(ProcessInfo.processInfo.physicalMemory >> 30) GB"
        return (["OverPass \(version) (\(build))", macOS, chip, memory]
                + [WineInstaller.displayVersion.map { "Wine \($0)" }].compactMap { $0 }).joined(separator: " · ")
    }
}

private struct GeneralSettings: View {
    @Environment(BottleManager.self) private var manager
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false
    @AppStorage(ViewOptions.showBottlesKey) private var showBottles = false
    @AppStorage(ViewOptions.showClientIconsKey) private var showClientIcons = false
    @AppStorage(AppWrappers.enabledKey) private var createWrappers = true
    @Environment(\.openSettings) private var openSettings
    @AppStorage(UpdateCheck.componentsKey) private var checkForWineUpdates = true
    @AppStorage(UpdateCheck.appKey) private var checkForAppUpdates = true
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple

    var body: some View {
        Form {
            Section("OverPass") {
                LabeledContent("Version", value: AppUpdate.currentVersion)
                Toggle("Check for OverPass updates", isOn: $checkForAppUpdates)
                Button("Check Now") { UpdateCheck.checkNow(with: openSettings) }
            }
            Section(detail == .simple ? "Windows Support" : "Wine") {
                if let root = manager.wineRoot {
                    if detail == .technical {
                        LabeledContent("Path", value: root.path)
                    }
                    if let version = WineInstaller.displayVersion {
                        LabeledContent("Version", value: version)
                    }
                } else {
                    Label("No Wine installation detected", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Toggle("Check for component updates", isOn: $checkForWineUpdates)
                DetailCaption("Checks OverPass Wine, OverPass Runtime and the extras once a day while OverPass is open and notifies you when a new release is out.",
                              technical: "Asks GitHub for the latest release of each component every 24 hours while OverPass runs, and posts one notification per new version. Updates install from Settings › Components.")
                Button("Run Setup Wizard Again…") { hasCompletedSetup = false }
            }
            Section("Library") {
                Toggle("Add games to the Applications folder", isOn: $createWrappers)
                    .onChange(of: createWrappers) { manager.loadBottles() }
                DetailCaption("Puts each game in ~/Applications/OverPass so it appears in Launchpad, Spotlight and the Dock.",
                              technical: "Writes a small .app per library title to ~/Applications/OverPass: a shell script that runs OverPass --launch with the container and program, the title's icon as ICNS, and OverPass's privacy usage strings (macOS asks each wrapper for permissions on its own). Rewritten when OverPass starts.")
                Toggle("Show game client icons", isOn: $showClientIcons)
                DetailCaption("Uses each client's own logo in the sidebar instead of a plain game controller symbol.",
                              technical: "Draws the client logos bundled with OverPass (Logos/*.svg) in the sidebar instead of SF Symbols.")
                Toggle("Show containers in the sidebar", isOn: $showBottles)
            }
        }
        .formStyle(.grouped)
        .edgeFade()
    }
}

private struct GameSettings: View {
    @AppStorage(MaxResolution.key) private var maxResolution = MaxResolution.desktop
    @AppStorage(BottleManager.reportCrashesKey) private var reportCrashes = true
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple

    var body: some View {
        Form {
            Section {
                MaxResolutionPicker(value: $maxResolution)
            } header: {
                Text("Display")
            } footer: {
                Text(detail == .simple
                     ? "The largest resolution games can pick. Sizes above the desktop are scaled down to fit; a "
                       + "custom size can be larger than the display, to render sharper. A game's profile can set its own."
                     : "Sets OVERPASS_MAX_RESOLUTION for every launch (desktop, display or <width>x<height>); OverPass "
                       + "Wine's display driver lists only modes up to that size, and modes above the desktop are "
                       + "scaled to fit. A profile's own value replaces it for that game.")
            }
            Section {
                Toggle("Open a report when a program crashes", isOn: $reportCrashes)
            } header: {
                Text("Problem Reports")
            } footer: {
                Text(detail == .simple
                     ? "While a game runs, press \(ReportHotKey.display) to report a problem with a screenshot of it. "
                       + "When a program crashes, the report window opens with the crash already in it."
                     : "\(ReportHotKey.display) is claimed only while a Windows program is frontmost; the screenshot "
                       + "needs Screen Recording permission. Crashes are noticed when Wine's crash handler (winedbg) "
                       + "starts in any container.")
            }
            Section {
                LabeledContent("Game Mode", value: "Automatic")
            } footer: {
                Text(detail == .simple
                     ? "macOS turns on Game Mode when a game covers the screen and is in front: games get the CPU "
                       + "and GPU first, and wireless controllers and headphones respond faster."
                     : "Each program runs through a Wine loader inside a minimal app bundle in the games category "
                       + "(OverPass Wine), so macOS identifies it as a game. Game Mode then turns on while its window "
                       + "covers the screen and is frontmost: CPU and GPU priority, doubled Bluetooth polling.")
            }
        }
        .formStyle(.grouped)
        .edgeFade()
    }
}

private struct AdvancedSettings: View {
    @Environment(ComponentManager.self) private var components
    @State private var permissions = PermissionsManager()
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple
    @AppStorage(XboxOptIn.key) private var xboxEnabled = false
    @AppStorage(ViewOptions.legacyClientsKey) private var legacyClients = false
    @AppStorage(ViewOptions.otherAppsKey) private var otherApps = false
    @State private var enablingXbox = false

    var body: some View {
        Form {
            Section("Containers") {
                ContainerLocationList()
                DetailCaption("Each game client and program gets its own container: a separate Windows setup with its own settings and files. Add a folder on another disk to keep containers there; new ones go to the favorite (★), and a container's Container tab can move it.",
                              technical: "Each container is a Wine prefix (WINEPREFIX): drive_c, the registry hives and OverPass's container settings. Programs in one container share a wineserver. Added locations are scanned for folders with a container.conf; container names stay unique across locations. Templates stay in the default location, so a container on another disk is a copy of one rather than an APFS clone.")
            }
            Section("Permissions") {
                PermissionsList(permissions: permissions)
            }
            Section("Home") {
                Toggle("Legacy game clients", isOn: $legacyClients)
                DetailCaption("OverPass has Epic Games and GOG built in: Install signs you in and lists your games. Turn this on to also offer the stores' own Windows apps (Epic Games Launcher, GOG Galaxy) when you install them from Home. Clients you already installed keep working either way.",
                              technical: "Off: Home's Install for a store with a built-in library (Legendary, gogdl) opens its sign-in directly. On: a menu with the built-in library (Recommended) and the store's client profile (Legacy option). Installed client containers are unaffected.")
                Toggle("Other recommended apps", isOn: $otherApps)
                DetailCaption("Home shows the gaming services. Turn this on to also show the other apps OverPass has profiles for, such as utilities and music players. Apps you already installed stay in your library either way.",
                              technical: "Off: Home lists only featured profiles in the Game Launcher category, without a section title. On: every featured category, each under its title.")
            }
            Section("Xbox") {
                // Turning it on goes through the risks sheet; turning it off signs out and removes Xodus.
                Toggle(isOn: Binding(get: { xboxEnabled }, set: { on in
                    if on { enablingXbox = true } else { Task { await XboxOptIn.disable(components) } }
                })) { HStack(spacing: 6) { Text("Xbox Library"); BetaBadge() } }
                DetailCaption("Your Xbox PC and Game Pass games in OverPass, through Xodus, an open-source Xbox client. Off by default: Microsoft's terms may not allow it. Turning it off signs you out and removes Xodus; installed games stay.",
                              technical: "Opt-in component: xodus-cli and xodus-service (GPL-3.0) in Tools/xodus. Off signs out (xodus-cli logout), deletes Tools/xodus and greys the Xbox tile; game folders in the Xbox container stay.")
            }
        }
        .formStyle(.grouped)
        .edgeFade()
        .sheet(isPresented: $enablingXbox) { XboxEnableSheet() }
    }
}


/// The container locations: the default one, which can't move, and the folders added besides it.
private struct ContainerLocationList: View {
    @Environment(BottleManager.self) private var manager
    @AppStorage(ContainerLocations.key) private var stored = ""
    @AppStorage(ContainerLocations.favoriteKey) private var favorite = ""
    @State private var problem: String?

    var body: some View {
        let locations = [Bottle.bottlesDirectory()] + ContainerLocations.urls(stored)
        ForEach(locations, id: \.self) { url in
            let isDefault = ContainerLocations.isDefault(url)
            let connected = FileManager.default.fileExists(atPath: url.path)
            let count = manager.bottles.filter { ContainerLocations.location(of: $0).standardizedFileURL == url.standardizedFileURL }.count
            HStack {
                Button {
                    favorite = isDefault ? "" : url.path
                } label: {
                    Image(systemName: isFavorite(url) ? "star.fill" : "star")
                        .foregroundStyle(isFavorite(url) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!connected || locations.count == 1)
                .help("New containers go here")
                VStack(alignment: .leading, spacing: 2) {
                    Text(ContainerLocations.displayName(of: url))
                    Text("\(url.path) · \(count == 1 ? "1 container" : "\(count) containers") · \(ContainerLocations.freeSpaceText(at: url))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(url) }
                    .disabled(!connected)
                if !isDefault {
                    Button("Remove") {
                        ContainerLocations.remove(url)
                        manager.loadBottles()
                    }
                    .disabled(count > 0)
                    .help(count > 0 ? "Move its containers elsewhere first" : "Stop using this folder")
                }
            }
        }
        HStack {
            Button("Add Location…", action: add)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func isFavorite(_ url: URL) -> Bool {
        ContainerLocations.favorite.standardizedFileURL == url.standardizedFileURL
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose a folder to keep containers in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = ContainerLocations.problem(adding: url)
        guard problem == nil else { return }
        ContainerLocations.add(url)
        manager.loadBottles()
    }
}

/// "Run" ("Play" for a store game), or a spinner with "Starting…" (and disabled) while the program starts.
struct OpenButton: View {
    let opening: Bool
    var label = "Run"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if opening {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Starting…")
                }
            } else {
                Text(label)
            }
        }
        .disabled(opening)
    }
}

/// Programs that are starting: Wine can take a while before the first window, and a crash during start
/// otherwise only shows up when Wine's own dialog appears.
struct LaunchStatusBar: View {
    @Environment(BottleManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ForEach(manager.recipeTasks) { task in
                HStack(spacing: 10) {
                    if let failed = task.failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failed)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(task.message)
                    }
                    Spacer()
                    if task.failed != nil {
                        Button {
                            manager.recipeTasks.removeAll { $0.id == task.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Hide")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            ForEach(manager.logRecordings) { recording in
                HStack(spacing: 10) {
                    if recording.saving {
                        ProgressView().controlSize(.small)
                        Text("Saving the log for \(recording.name)…")
                    } else {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                        Text("Logging \(recording.name). Quit it when you're done, and the log is saved to your Desktop.")
                        Spacer()
                        Button("Finish Now") { Task { await manager.finishLogging(recording.id) } }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            ForEach(manager.launches) { launch in
                HStack(spacing: 10) {
                    switch launch.state {
                    case .starting:
                        ProgressView().controlSize(.small)
                        Text("Starting \(launch.name)…")
                    case .slow:
                        ProgressView().controlSize(.small)
                        Text("\(launch.name) is taking a while to start. It may still open.")
                    case .crashed:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(launch.name) crashed while starting. Wine is preparing a crash report.")
                    }
                    Spacer()
                    Button {
                        manager.dismissLaunch(launch.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Hide")
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(.bar)
    }
}

/// Install and Quick Run belong to the window; each page shows them in the middle of the toolbar, in a group of
/// their own between its actions and its view options.
struct WindowActions {
    var install: () -> Void = {}
    var quickRun: () -> Void = {}
    var canQuickRun = false
}

private struct WindowActionsKey: EnvironmentKey {
    static let defaultValue = WindowActions()
}

extension EnvironmentValues {
    var windowActions: WindowActions {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

struct WindowActionButtons: View {
    @Environment(\.windowActions) private var actions

    var body: some View {
        Button(action: actions.install) {
            Label("Install", systemImage: "plus.circle.fill")
        }
        .help("Install a Windows game or app")
        Button(action: actions.quickRun) {
            Label("Quick Run", systemImage: "bolt.fill")
        }
        .help("Quick Run: run any Windows program in a container")
        .disabled(!actions.canQuickRun)
    }
}
