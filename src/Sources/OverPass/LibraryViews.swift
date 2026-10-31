import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library (main view)

struct LibraryView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    /// A store launcher whose games to show; nil shows every app.
    var launcher: GameProfile? = nil
    /// Shows only the titles marked as favorites.
    var favoritesOnly = false
    /// Shows only the titles in this user category.
    var categoryID: String? = nil
    /// Shows the titles in this built-in category (Mac, Other).
    var builtIn: BuiltInCategory? = nil
    let showHome: () -> Void
    @AppStorage(ViewOptions.layoutKey) private var layout: LibraryLayout = .grid
    @AppStorage(LibraryLayout.grid.sizeKey) private var gridSize = LibraryLayout.grid.defaultSize
    @AppStorage(LibraryLayout.list.sizeKey) private var listSize = LibraryLayout.list.defaultSize
    @AppStorage(LibraryLayout.rows.sizeKey) private var rowSize = LibraryLayout.rows.defaultSize
    @AppStorage(LibraryLayout.covers.sizeKey) private var coverSize = LibraryLayout.covers.defaultSize
    @Environment(\.searchText) private var searchText
    @AppStorage(ViewOptions.favoritesKey) private var favorites = ""
    @AppStorage(ViewOptions.categoriesKey) private var categories = ""
    @AppStorage(ViewOptions.hiddenKey) private var hidden = ""
    @AppStorage(ViewOptions.showHiddenKey) private var showHidden = false
    @State private var launchError: String?
    /// A title with an anti-cheat, waiting for the person to confirm the first start.
    @State private var antiCheatItem: LibraryItem?
    @AppStorage(LibrarySort.key) private var sortKey: LibrarySort = .name
    @AppStorage(LibrarySort.ascendingKey) private var sortAscending = true
    /// GOG and Epic: only the installed games, without the rest of the account's library.
    @AppStorage(ViewOptions.installedOnlyKey) private var installedOnly = false
    /// The selected app in any layout; its actions show in the middle of the toolbar.
    @State private var selection: LibraryEntry.ID?
    @State private var itemSheet: ItemSheet?
    @Environment(\.storeActions) private var storeActions

    /// A built-in library's store, when this is its category: its owned games show beside the installed ones.
    private var store: (any StoreLibrary)? { launcher.flatMap { BuiltInLibrary.store(for: $0.bottle.group) } }

    private var allItems: [LibraryItem] {
        if favoritesOnly {
            let ids = Favorites.ids(favorites)
            return manager.library.filter { ids.contains($0.id) }
        }
        if let category {
            let ids = Set(category.items)
            return manager.library.filter { ids.contains($0.id) }
        }
        if let builtIn { return manager.titles(in: builtIn) }
        return launcher.map { manager.games(of: $0) } ?? manager.library
    }
    private var category: UserCategory? {
        categoryID.flatMap { id in UserCategories.list(categories).first { $0.id == id } }
    }
    private var items: [LibraryItem] {
        let search = searchText.trimmingCharacters(in: .whitespaces)
        let shown = Hidden.visible(allItems, hidden: hidden, showing: showHidden)
        let found = search.isEmpty ? shown : shown.filter { $0.app.name.localizedStandardContains(search) }
        return found.map(LibraryEntry.title).sorted(using: sortOrder.wrappedValue).compactMap(\.item)
    }

    /// The sort, for the toolbar's menu and the list's column headers alike.
    private var sortOrder: Binding<[KeyPathComparator<LibraryEntry>]> {
        Binding {
            sortKey.comparators(ascending: sortAscending)
        } set: {
            if let (key, ascending) = LibrarySort.from($0) { sortKey = key; sortAscending = ascending }
        }
    }

    /// The store's owned games that aren't installed, after the installed titles.
    private var storeGames: [LibraryGame] {
        guard let store, store.account != nil, !installedOnly else { return [] }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        let hiddenIDs = showHidden ? [] : Hidden.ids(hidden)
        return store.games.filter { game in
            !store.isInstalled(game) && !hiddenIDs.contains(LibraryEntry.store(game).id)
                && (search.isEmpty || game.title.localizedStandardContains(search))
        }
        .map(LibraryEntry.store).sorted(using: sortOrder.wrappedValue)
        .compactMap { if case .store(let game) = $0 { game } else { nil } }
    }

    private var entries: [LibraryEntry] { items.map(LibraryEntry.title) + storeGames.map(LibraryEntry.store) }

    /// "Steam · 2 titles", counting games as the sidebar does (without the client); "3 found" while searching.
    private var status: String {
        let name = launcher?.name ?? category?.name ?? builtIn?.name ?? (favoritesOnly ? "Favorites" : "All Titles")
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return "\(name) · \(entries.count) found" }
        let counted = launcher.map { manager.games(of: $0, includeClient: false) } ?? allItems
        let installed = "\(name) · " + titleCount(Hidden.visible(counted, hidden: hidden, showing: showHidden).count)
        let withStore = storeGames.isEmpty ? installed : installed + " · \(storeGames.count) more to install"
        let hiddenHere = hiddenCount
        return hiddenHere == 0 || showHidden ? withStore : withStore + " · \(hiddenHere) hidden"
    }

    /// Hidden titles and store games of this page, for the status bar.
    private var hiddenCount: Int {
        let ids = Hidden.ids(hidden)
        guard !ids.isEmpty else { return 0 }
        let titles = allItems.filter { ids.contains($0.id) }.count
        let games = store.map { store in
            store.account == nil || installedOnly ? 0
                : store.games.filter { !store.isInstalled($0) && ids.contains(LibraryEntry.store($0).id) }.count
        } ?? 0
        return titles + games
    }

    /// Dims an entry that's hidden while View › Show Hidden Items shows it.
    private func isHidden(_ id: String) -> Bool { Hidden.ids(hidden).contains(id) }
    private var selectedEntry: LibraryEntry? { entries.first { $0.id == selection } }
    private var selectedItem: LibraryItem? { selectedEntry?.item }

    var body: some View {
        Group {
            if let store, store.account == nil {
                // Signed out (or not set up yet): the installed games stay, with the way back in on top.
                if items.isEmpty { signedOut(store) } else { layouts.safeAreaInset(edge: .top) { signedOutBar(store) } }
            } else if let store, entries.isEmpty, store.loading {
                VStack(spacing: 6) {
                    ProgressView("Loading your games…")
                    Text("This can take a couple of minutes for a large library.").font(.callout).foregroundStyle(.secondary)
                }
            } else if entries.isEmpty && !(allItems.isEmpty && (store?.games.isEmpty ?? true)) {
                ContentUnavailableView.search(text: searchText)
            } else if entries.isEmpty {
                ContentUnavailableView {
                    if favoritesOnly {
                        Label("No Favorites", systemImage: "star")
                    } else if let category {
                        Label("\(category.name) Is Empty", systemImage: "folder")
                    } else if builtIn == .mac {
                        Label("No Mac Apps", systemImage: BuiltInCategory.mac.symbol)
                    } else {
                        Label("No Games Yet", systemImage: "square.grid.2x2")
                    }
                } description: {
                    if favoritesOnly {
                        Text("Right-click a title and choose Add to Favorites.")
                    } else if category != nil {
                        Text("Right-click a title in All Titles and choose Add to Category.")
                    } else if builtIn == .mac {
                        Text("Add Mac games and apps to start them from OverPass, or drag them here from Finder.")
                    } else if let launcher {
                        Text("Games you install with \(launcher.name) appear here.")
                    } else {
                        Text("Games and apps you install appear here.")
                    }
                } actions: {
                    if builtIn == .mac {
                        Button("Add Mac App…") { manager.addMacApps(MacApps.choose()) }
                            .buttonStyle(.borderedProminent)
                    } else if launcher == nil && !favoritesOnly && category == nil {
                        Button("Install a Game", action: showHome)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                layouts.safeAreaInset(edge: .top) { storeErrorBar }
            }
        }
        .task(id: store?.account) { if let store, store.account != nil,
                                             Date.now.timeIntervalSince(store.refreshed ?? .distantPast) > SavedLibrary.freshFor {
            await store.refresh()
        } }
        .statusText(status)
        .toolbar {
            // This page's own controls sit in the middle and stay there, greyed out while nothing is
            // selected; the window's buttons stay on the right.
            ToolbarItemGroup(placement: .principal) {
                let item = selectedItem
                let opening = item.map { manager.isOpening($0.app, in: $0.bottle) } ?? false
                if case .store(let game) = selectedEntry, let store {
                    Button { store.install(game, using: manager) } label: {
                        Label("Install \(game.title)", systemImage: "arrow.down.circle")
                    }
                    .help("Install \(game.title)")
                    .disabled(game.unavailable != nil || store.progress[game.id] != nil || store.queue.contains(game.id))
                } else {
                    Button { if let item { launch(item) } } label: {
                        Label(item.map { "\($0.app.runLabel) \($0.app.name)" } ?? "Run", systemImage: "play.fill")
                    }
                    .help(item.map { "\($0.app.runLabel) \($0.app.name)" } ?? "Select an app to run it")
                    .disabled(item == nil || opening)
                }
                Button {
                    if let item {
                        if item.bottle.isMac { NSWorkspace.shared.selectFile(item.app.executable, inFileViewerRootedAtPath: "") }
                        else if let folder = item.installFolder { NSWorkspace.shared.open(folder) }
                        else { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.bottle.path.path) }
                    }
                } label: { Label("Show in Finder", systemImage: "folder") }
                .help(item.map { "Show where \($0.app.name) is installed" } ?? "Select an app to show it in Finder")
                .disabled(item == nil)
                Button { if let item { itemSheet = .editProfile(item) } } label: {
                    Label("Edit Profile", systemImage: "slider.horizontal.3")
                }
                .help(item.map { "Change how \($0.app.name) runs" } ?? "Select an app to edit its profile")
                .disabled(item == nil || item?.bottle.isMac == true)
            }
            ToolbarItemGroup(placement: .principal) {
                WindowActionButtons()
            }
            // How the titles show: layout, order and, in a store's category, only the installed games.
            ToolbarItem(placement: .principal) {
                ViewControls {
                    LayoutMenu(layout: $layout, coverStyles: true)
                    SortMenu(key: $sortKey, ascending: $sortAscending)
                    if store != nil {
                        Toggle(isOn: $installedOnly) {
                            Label("Installed Only", systemImage: installedOnly ? "line.3.horizontal.decrease.circle.fill"
                                                                               : "line.3.horizontal.decrease.circle")
                        }
                        .foregroundStyle(installedOnly ? Color.accentColor : .primary)
                        .help(installedOnly ? "Show the whole library" : "Show only installed games")
                    }
                }
            }
        }
        .alert("Couldn't Run", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") {}
        } message: {
            Text(launchError ?? "")
        }
        .alert("This Game Uses an Anti-Cheat", isPresented: Binding(get: { antiCheatItem != nil }, set: { if !$0 { antiCheatItem = nil } }),
               presenting: antiCheatItem) { item in
            Button(item.app.runLabel) { start(item) }
            Button("\(item.app.runLabel), and Don't Ask Again for It") {
                AntiCheat.acknowledge(item)
                start(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(AntiCheat.info(for: item).map { AntiCheat.warning($0, for: item.app.name) } ?? "")
        }
        .focusedSceneValue(\.uninstallSelection, selectedItem.map { item in
            UninstallSelection(name: item.app.name) { itemSheet = .uninstall(item) }
        })
        .itemSheets($itemSheet)
        // Mac apps dragged in from Finder join the library.
        .dropDestination(for: URL.self) { urls, _ in
            let apps = urls.filter { $0.pathExtension == "app" }
            manager.addMacApps(apps)
            return !apps.isEmpty
        }
    }

    @ViewBuilder private var layouts: some View {
        switch layout {
        case .grid: grid
        case .list: table
        case .rows: rows
        case .covers: covers
        }
    }

    private func signedOut(_ store: any StoreLibrary) -> some View {
        let name = type(of: store).storeName
        return ContentUnavailableView {
            Label("Sign In to \(name)", systemImage: "person.crop.circle")
        } description: {
            Text("Your \(name) games appear here once you sign in.")
        } actions: {
            Button("Sign In…") { connect() }.buttonStyle(.borderedProminent)
        }
    }

    private func signedOutBar(_ store: any StoreLibrary) -> some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.secondary)
            Text("Sign in to \(type(of: store).storeName) to see the rest of your games.").font(.callout)
            Spacer()
            Button("Sign In…") { connect() }
        }
        .padding(10)
        .background(.bar)
    }

    private func connect() {
        if let group = launcher?.bottle.group { storeActions.connect(group) }
    }

    @ViewBuilder private var storeErrorBar: some View {
        if let store, let error = store.error {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.callout)
                Spacer()
                Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridSize + 56), spacing: 20)], spacing: 20) {
                ForEach(items) { item in
                    AppTile(item: item, iconSize: gridSize, selected: selection == item.id, playButton: store != nil,
                            select: { selection = item.id }) { launch(item) }
                        .dimmedWhenHidden(isHidden(item.id))
                }
                if let store {
                    ForEach(storeGames) { game in
                        let id = LibraryEntry.store(game).id
                        StoreGameTile(game: game, store: store, iconSize: gridSize, selected: selection == id,
                                      select: { selection = id })
                            .dimmedWhenHidden(isHidden(id))
                    }
                }
            }
            .padding(24)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
    }

    private var covers: some View {
        let clients = manager.installedClients(from: profiles)
        let stores = profiles.profiles.filter { $0.category == "Game Launcher" }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize), spacing: 20)], spacing: 24) {
                ForEach(items) { item in
                    CoverTile(item: item, width: coverSize, selected: selection == item.id, playButton: store != nil,
                              select: { selection = item.id },
                              platform: casePlatform(item, clients: clients, stores: stores, manager: manager),
                              captionIcon: launcher == nil && builtIn == nil) {
                        launch(item)
                    }
                    .dimmedWhenHidden(isHidden(item.id))
                }
                if let store {
                    ForEach(storeGames) { game in
                        let id = LibraryEntry.store(game).id
                        StoreGameCover(game: game, store: store, width: coverSize, selected: selection == id,
                                       platform: casePlatform(store: type(of: store).storeName, stores: stores),
                                       select: { selection = id })
                            .dimmedWhenHidden(isHidden(id))
                    }
                }
            }
            .padding(24)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    AppRow(item: item, iconSize: rowSize, selected: selection == item.id,
                           select: { selection = item.id }) { launch(item) }
                        .dimmedWhenHidden(isHidden(item.id))
                    Divider().padding(.leading, rowSize + 36)
                }
                if let store {
                    ForEach(storeGames) { game in
                        let id = LibraryEntry.store(game).id
                        StoreGameRow(game: game, store: store, iconSize: rowSize, selected: selection == id,
                                     select: { selection = id })
                            .dimmedWhenHidden(isHidden(id))
                        Divider().padding(.leading, rowSize + 36)
                    }
                }
            }
            .padding(.vertical, 8)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
    }

    private var table: some View {
        // Installed titles first, then the store's games to install, each group sorted on its own.
        Table(entries, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                // Rows re-made while the sort changes can miss the window's environment; hand it on.
                nameCell(entry).environment(manager).environment(profiles)
            }
            TableColumn("Container", value: \.bottleName, comparator: .localizedStandard) { Text($0.bottleName) }
                .width(min: 70, ideal: 130)
            TableColumn("Engine", value: \.engineName, comparator: .localizedStandard) { Text($0.engineName) }
                .width(min: 70, ideal: 110)
            TableColumn("Graphics", value: \.graphicsName, comparator: .localizedStandard) { Text($0.graphicsName) }
                .width(min: 70, ideal: 150)
        }
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            Group {
                switch entries.first(where: { ids.contains($0.id) }) {
                case .title(let item): LibraryItemMenu(item: item) { launch(item) }
                case .store(let game): if let store { StoreGameMenu(game: game, store: store) }
                case nil: EmptyView()
                }
            }
            .environment(manager)
            .environment(profiles)
        } primaryAction: { ids in
            switch entries.first(where: { ids.contains($0.id) }) {
            case .title(let item): launch(item)
            case .store(let game): if game.unavailable == nil { store?.install(game, using: manager) }
            case nil: break
            }
        }
    }

    @ViewBuilder private func nameCell(_ entry: LibraryEntry) -> some View {
        switch entry {
        case .title(let item):
            HStack(spacing: 8) {
                AppIcon(item: item, size: listSize)
                Text(item.app.name)
            }
            .dimmedWhenHidden(isHidden(item.id))
        case .store(let game):
            HStack(spacing: 8) {
                StoreGameArt(game: game).frame(width: listSize, height: listSize)
                    .clipShape(RoundedRectangle(cornerRadius: listSize * 0.18)).opacity(0.55)
                Text(game.title).foregroundStyle(.secondary)
                Spacer()
                if let store { StoreGameAction(game: game, store: store, compact: true) }
            }
            .dimmedWhenHidden(isHidden(LibraryEntry.store(game).id))
        }
    }

    private func launch(_ item: LibraryItem) {
        if AntiCheat.info(for: item) != nil && !AntiCheat.isAcknowledged(item) {
            antiCheatItem = item
        } else {
            start(item)
        }
    }

    private func start(_ item: LibraryItem) {
        do {
            try manager.launchApp(item.app, in: item.bottle)
        } catch {
            launchError = error.localizedDescription
        }
    }
}

/// A row in a library page: an installed title, or a store game owned but not installed (in a store's category).
extension View {
    /// A hidden title shown by View › Show Hidden Items: veiled in the window's colour. Not with opacity, which
    /// left the title without its menu, so it couldn't be unhidden.
    func dimmedWhenHidden(_ hidden: Bool) -> some View {
        overlay {
            if hidden { Color(nsColor: .windowBackgroundColor).opacity(0.6).allowsHitTesting(false) }
        }
    }
}

enum LibraryEntry: Identifiable {
    case title(LibraryItem)
    case store(LibraryGame)

    var id: String {
        switch self {
        case .title(let item): item.id
        case .store(let game): "store:" + game.id
        }
    }
    var item: LibraryItem? { if case .title(let item) = self { item } else { nil } }
    var name: String {
        switch self {
        case .title(let item): item.app.name
        case .store(let game): game.title
        }
    }
    var bottleName: String { item?.bottle.name ?? "Not installed" }
    var graphicsName: String { item?.graphicsName ?? "" }
    var engineName: String { item?.engineName ?? "" }
}

extension LibraryItem {
    /// The folder the app's program is installed in, when it's known and there.
    var installFolder: URL? {
        app.target.flatMap { WindowsIcons.hostPath($0, bottlePath: bottle.path) }?.deletingLastPathComponent()
    }

    var graphicsName: String { bottle.isMac ? "Native" : bottle.graphics.displayName }
    /// The engine the profile names, or the one the game's files tell; "Unknown" otherwise.
    var engineName: String {
        app.engine ?? Detection.result(for: self)?.engines.first.map(Detection.displayName) ?? "Unknown"
    }
}

extension BottleManager {
    /// "Witcher 3 — GOG": the title and its client, and its container when other titles share it.
    func tooltip(for item: LibraryItem) -> String {
        let shared = library.contains { $0.bottle.path == item.bottle.path && $0.id != item.id }
        return ([item.app.name, item.app.launcher, shared ? item.bottle.name : nil] as [String?])
            .compactMap { $0 }.joined(separator: " — ")
    }
}

/// An app's Windows icon, dimmed with a spinner while the program is starting.
struct AppIcon: View {
    @Environment(BottleManager.self) private var manager
    let item: LibraryItem
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        let opening = manager.isOpening(item.app, in: item.bottle)
        Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: item.app.executable))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(opening ? 0.4 : 1)
            .overlay { if opening { ProgressView().controlSize(.small) } }
            .task(id: item.id + (item.app.icon ?? "")) {
                let (app, bottle) = (item.app, item.bottle)
                let file = await Task.detached(priority: .utility) { WindowsIcons.icoFile(for: app, in: bottle) }.value
                icon = file.flatMap(NSImage.init(contentsOf:))
            }
    }
}

struct LibraryItemMenu: View {
    @Environment(BottleManager.self) private var manager
    @Environment(\.openItemSheet) private var openItemSheet
    @AppStorage(ViewOptions.favoritesKey) private var favorites = ""
    @AppStorage(ViewOptions.hiddenKey) private var hidden = ""
    @AppStorage(ViewOptions.categoriesKey) private var categories = ""
    let item: LibraryItem
    let launch: () -> Void

    var body: some View {
        let opening = manager.isOpening(item.app, in: item.bottle)
        Button(opening ? "Starting…" : item.app.runLabel) { launch() }.disabled(opening)
        Button(Favorites.ids(favorites).contains(item.id) ? "Remove from Favorites" : "Add to Favorites") {
            favorites = Favorites.toggled(item.id, in: favorites)
        }
        Menu("Add to Category") {
            ForEach(UserCategories.list(categories)) { category in
                Toggle(category.name, isOn: Binding(
                    get: { category.items.contains(item.id) },
                    set: { _ in UserCategories.toggled(item.id, in: category.id, stored: &categories) }))
            }
            if !UserCategories.list(categories).isEmpty { Divider() }
            Button("New Category…") {
                if let name = UserCategories.askName(title: "New Category", button: "Create") {
                    _ = UserCategories.added(name, with: item.id, in: &categories)
                }
            }
        }
        Button(Hidden.ids(hidden).contains(item.id) ? "Unhide" : "Hide") { hidden = Hidden.toggled(item.id, in: hidden) }
        Divider()
        if item.bottle.isMac {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(item.app.executable, inFileViewerRootedAtPath: "") }
            Button("Remove from Library") { manager.removeMacApp(item) }
            Divider()
            Button("Uninstall…") { openItemSheet(.uninstall(item)) }
        } else {
            windowsItems
        }
    }

    @ViewBuilder private var windowsItems: some View {
        Button("Edit Profile…") { openItemSheet(.editProfile(item)) }
        Button("Report Issue…") { openItemSheet(.reportIssue(item)) }
        Divider()
        Button("Uninstall…") { openItemSheet(.uninstall(item)) }
        Divider()
        if let folder = item.installFolder {
            Button("Show Install in Finder") { NSWorkspace.shared.open(folder) }
        }
        Button("Show Container in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.bottle.path.path)
        }
        Text("Container: \(item.bottle.name)")
    }
}

struct AppTile: View {
    @Environment(BottleManager.self) private var manager
    let item: LibraryItem
    var iconSize: CGFloat = 64
    var selected = false
    /// A Play button under the name, where a store's games that aren't installed show Install.
    var playButton = false
    var select: () -> Void = {}
    let launch: () -> Void

    var body: some View {
        let opening = manager.isOpening(item.app, in: item.bottle)
        VStack(spacing: 8) {
            AppIcon(item: item, size: iconSize)
                .overlay(alignment: .topTrailing) { AntiCheatBadge(item: item, size: iconSize * 0.3) }
            Text(item.app.name)
                .font(.callout)
                .lineLimit(playButton ? 1 : 2)
                .multilineTextAlignment(.center)
            if playButton { OpenButton(opening: opening, label: item.app.runLabel, action: launch)
                .buttonStyle(.borderedProminent).controlSize(.small) }
        }
        .frame(width: iconSize + 56, height: iconSize + (playButton ? 84 : 56))
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        // A click selects, a double click opens, as in Finder.
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !opening { launch() } })
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(manager.tooltip(for: item))
        .contextMenu { LibraryItemMenu(item: item, launch: launch) }
    }
}

/// A roomy row: icon, name, where it came from, and an Open button.
struct AppRow: View {
    @Environment(BottleManager.self) private var manager
    let item: LibraryItem
    let iconSize: CGFloat
    var selected = false
    var select: () -> Void = {}
    let launch: () -> Void

    var body: some View {
        let opening = manager.isOpening(item.app, in: item.bottle)
        HStack(spacing: 14) {
            AppIcon(item: item, size: iconSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.app.name).font(.headline)
                Text(item.bottle.isMac ? "Mac app"
                        : ([item.app.launcher, item.bottle.name == item.app.launcher ? nil : item.bottle.name,
                            item.graphicsName] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(opening ? "Starting…" : item.app.runLabel, action: launch)
                .disabled(opening)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !opening { launch() } })
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { LibraryItemMenu(item: item, launch: launch) }
    }
}

// MARK: - Bottle detail (advanced)

// MARK: - Quick Run

struct RunCommandSheet: View {
    @Environment(BottleManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    let preselected: URL?
    @State private var exePath = ""
    @State private var bottlePath: URL?
    @State private var error: String?

    var body: some View {
        Form {
            Picker("Container", selection: $bottlePath) {
                ForEach(manager.bottles) { Text($0.name).tag(Optional($0.path)) }
            }
            HStack {
                TextField("Program", text: $exePath, prompt: Text(".exe, .msi, .bat or .lnk"))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.exe] + ["msi", "bat", "lnk"].compactMap { UTType(filenameExtension: $0) }
                    if panel.runModal() == .OK, let url = panel.url { exePath = url.path }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Run") {
                    guard let bottle = manager.bottles.first(where: { $0.path == bottlePath }) else { return }
                    do {
                        try manager.runExe(exePath, in: bottle)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(exePath.isEmpty || bottlePath == nil)
            }
        }
        .onAppear { bottlePath = preselected ?? manager.bottles.first?.path }
    }
}

// MARK: - Bottles

/// Every bottle, drawn like the library's titles in whichever layout and size the library uses, each with the
/// sidebar's box icon. A double click opens the bottle's settings.
struct BottlesView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(\.openItemSheet) private var openItemSheet
    @Environment(\.searchText) private var searchText
    let importContainer: () -> Void
    let open: (Bottle) -> Void
    @AppStorage(ViewOptions.layoutKey) private var layout: LibraryLayout = .grid
    @AppStorage(LibraryLayout.grid.sizeKey) private var gridSize = LibraryLayout.grid.defaultSize
    @AppStorage(LibraryLayout.list.sizeKey) private var listSize = LibraryLayout.list.defaultSize
    @AppStorage(LibraryLayout.rows.sizeKey) private var rowSize = LibraryLayout.rows.defaultSize
    @AppStorage(LibraryLayout.covers.sizeKey) private var coverSize = LibraryLayout.covers.defaultSize
    @State private var selection: Bottle.ID?
    @AppStorage(ContainerSort.key) private var sortKey: ContainerSort = .name
    @AppStorage(ContainerSort.ascendingKey) private var sortAscending = true
    /// Each bottle's size on disk, counted in the background when the page opens.
    @State private var sizes: [URL: Int64] = [:]

    private func titles(in bottle: Bottle) -> [LibraryItem] {
        manager.library.filter { $0.bottle.path == bottle.path }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    /// "3 titles · 12.4 GB": what's in the bottle, and its size once counted.
    private func summary(_ bottle: Bottle) -> String {
        let count = titles(in: bottle).count
        return ([count == 1 ? "1 title" : "\(count) titles"] + [sizes[bottle.path].map(FolderSize.text)].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var bottles: [Bottle] {
        let search = searchText.trimmingCharacters(in: .whitespaces)
        return manager.bottles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            .sorted(using: sortOrder.wrappedValue)
    }

    private var sortOrder: Binding<[KeyPathComparator<Bottle>]> {
        Binding {
            sortKey.comparators(ascending: sortAscending)
        } set: {
            if let (key, ascending) = ContainerSort.from($0) { sortKey = key; sortAscending = ascending }
        }
    }
    private var selected: Bottle? { bottles.first { $0.id == selection } }

    private var status: String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return "Containers · \(bottles.count) found" }
        return "Containers · " + (manager.bottles.count == 1 ? "1 container" : "\(manager.bottles.count) containers")
    }

    var body: some View {
        Group {
            if manager.bottles.isEmpty {
                ContentUnavailableView("No Containers Yet", systemImage: BottleIcon.symbol,
                                       description: Text("Each game or app you install gets a container: its own Windows."))
            } else if bottles.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                switch layout {
                case .grid: grid
                case .list: table
                case .rows: rows
                case .covers: covers
                }
            }
        }
        .statusText(status)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                let bottle = selected
                Button { if let bottle { open(bottle) } } label: {
                    Label("Container Settings", systemImage: "slider.horizontal.3")
                }
                .help(bottle.map { "Change \($0.name)'s settings" } ?? "Select a container to change its settings")
                .disabled(bottle == nil)
                Button { if let bottle { showInFinder(bottle) } } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help(bottle.map { "Show \($0.name) in Finder" } ?? "Select a container to show it in Finder")
                .disabled(bottle == nil)
                Button { if let bottle { openItemSheet(.uninstallBottle(bottle)) } } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .help(bottle.map { "Uninstall \($0.name)…" } ?? "Select a container to uninstall it")
                .disabled(bottle == nil)
                Button(action: importContainer) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a container someone exported")
            }
            ToolbarItemGroup(placement: .principal) {
                WindowActionButtons()
            }
            ToolbarItem(placement: .principal) {
                ViewControls {
                    LayoutMenu(layout: $layout, noun: "containers")
                    SortMenu(key: $sortKey, ascending: $sortAscending)
                }
            }
        }
        .focusedSceneValue(\.uninstallSelection, selected.map { bottle in
            UninstallSelection(name: bottle.name) { openItemSheet(.uninstallBottle(bottle)) }
        })
        .task(id: manager.bottles.map(\.path)) {
            for bottle in manager.bottles {
                let path = bottle.path
                sizes[path] = await Task.detached(priority: .utility) { FolderSize.of(path) }.value
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridSize + 56), spacing: 20)], spacing: 20) {
                ForEach(bottles) { bottle in
                    VStack(spacing: 4) {
                        BottleIcon(size: gridSize)
                        Text(bottle.name).font(.callout).lineLimit(1).multilineTextAlignment(.center)
                        Text(summary(bottle)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: gridSize + 56, height: gridSize + 72)
                    .background(selection == bottle.id ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .bottleItem(bottle, select: { selection = bottle.id }, open: open)
                }
            }
            .padding(24)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
    }

    /// A plain cover with the box on it, the same 2:3 shape as the library's covers.
    private var covers: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize), spacing: 20)], spacing: 24) {
                ForEach(bottles) { bottle in
                    let shape = RoundedRectangle(cornerRadius: 8)
                    VStack(spacing: 8) {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            VStack(spacing: coverSize * 0.08) {
                                BottleIcon(size: coverSize * (titles(in: bottle).count > 1 ? 0.36 : 0.5))
                                // With more than one title, the first four icons show what's inside.
                                let inside = titles(in: bottle)
                                if inside.count > 1 {
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(coverSize * 0.3), spacing: coverSize * 0.06),
                                                             count: 2), spacing: coverSize * 0.06) {
                                        ForEach(inside.prefix(4)) { AppIcon(item: $0, size: coverSize * 0.3) }
                                    }
                                }
                            }
                        }
                        .frame(width: coverSize, height: coverSize * 1.5)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 3).opacity(selection == bottle.id ? 1 : 0) }
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        VStack(spacing: 1) {
                            Text(bottle.name).font(.callout).lineLimit(1)
                            Text(summary(bottle)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: coverSize)
                    }
                    .bottleItem(bottle, select: { selection = bottle.id }, open: open)
                }
            }
            .padding(24)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(bottles) { bottle in
                    HStack(spacing: 14) {
                        BottleIcon(size: rowSize)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bottle.name).font(.headline)
                            Text([summary(bottle), bottle.template.displayName, bottle.graphics.displayName]
                                    .joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            let inside = titles(in: bottle)
                            if inside.count > 1 {
                                Text(inside.map(\.app.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Settings") { open(bottle) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(selection == bottle.id ? Color.accentColor.opacity(0.18) : .clear)
                    .bottleItem(bottle, select: { selection = bottle.id }, open: open)
                    Divider().padding(.leading, rowSize + 36)
                }
            }
            .padding(.vertical, 8)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
    }

    private var table: some View {
        Table(bottles, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { bottle in
                HStack(spacing: 8) {
                    BottleIcon(size: listSize)
                    Text(bottle.name)
                }
            }
            TableColumn("Titles") { bottle in
                let inside = titles(in: bottle)
                Text("\(inside.count)").help(inside.map(\.app.name).joined(separator: ", "))
            }
            .width(min: 40, ideal: 50)
            TableColumn("Size") { Text(sizes[$0.path].map(FolderSize.text) ?? "…") }
                .width(min: 60, ideal: 80)
            TableColumn("Windows", value: \.template.displayName, comparator: .localizedStandard) {
                Text($0.template.displayName)
            }
            .width(min: 70, ideal: 150)
            TableColumn("Graphics", value: \.graphics.displayName, comparator: .localizedStandard) {
                Text($0.graphics.displayName)
            }
            .width(min: 70, ideal: 150)
        }
        .contextMenu(forSelectionType: Bottle.ID.self) { ids in
            if let bottle = bottles.first(where: { ids.contains($0.id) }) {
                BottleMenu(bottle: bottle, open: open).environment(manager)
            }
        } primaryAction: { ids in
            if let bottle = bottles.first(where: { ids.contains($0.id) }) { open(bottle) }
        }
    }
}

/// A container's icon, the same everywhere a container is shown (the puzzle piece is Components').
struct BottleIcon: View {
    static let symbol = "cube.fill"
    let size: CGFloat

    var body: some View {
        Image(systemName: Self.symbol)
            .resizable()
            .scaledToFit()
            .padding(size * 0.1)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

private struct BottleMenu: View {
    @Environment(\.openItemSheet) private var openItemSheet
    let bottle: Bottle
    let open: (Bottle) -> Void

    var body: some View {
        Button("Container Settings") { open(bottle) }
        Button("Show in Finder") { showInFinder(bottle) }
        Divider()
        Button("Uninstall…") { openItemSheet(.uninstallBottle(bottle)) }
    }
}

private func showInFinder(_ bottle: Bottle) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bottle.path.path)
}

private extension View {
    /// A click selects, a double click opens the bottle's settings, as titles do in the library.
    func bottleItem(_ bottle: Bottle, select: @escaping () -> Void, open: @escaping (Bottle) -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: select)
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(bottle) })
            .help(bottle.path.path)
            .contextMenu { BottleMenu(bottle: bottle, open: open) }
    }
}

/// A shield on a title's tile when it uses an anti-cheat (AntiCheat.swift); red when it can't run on a Mac.
struct AntiCheatBadge: View {
    let item: LibraryItem
    let size: CGFloat

    var body: some View {
        if let info = AntiCheat.info(for: item) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: size))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, info.blocked ? .red : .orange)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .help(AntiCheat.warning(info, for: item.app.name))
        }
    }
}

/// A built-in library's account: who is signed in, Refresh Library and Sign Out. Beside the search field.
struct StoreAccountMenu: View {
    let store: any StoreLibrary
    let account: String

    var body: some View {
        Menu {
            Text("Signed in as \(account)")
            Button("Refresh Library") { Task { await store.refresh() } }.disabled(store.loading)
            Divider()
            Button("Sign Out") { Task { await store.signOut() } }
        } label: {
            Label(account, systemImage: "person.crop.circle")
        }
        .help("\(type(of: store).storeName) account")
    }
}
