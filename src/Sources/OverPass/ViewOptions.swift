import SwiftUI

// How the main window shows things, set from the View menu and Settings.
enum ViewOptions {
    static let showBottlesKey = "showBottlesInSidebar"
    static let showClientIconsKey = "showClientIconsInSidebar"
    static let showClientInCategoryKey = "showClientInCategory"
    static let layoutKey = "libraryLayout"
    static let coverStyleKey = "coverStyle"
    static let installedOnlyKey = "storeInstalledOnly"
    static let favoritesKey = "favorites"
    static let categoriesKey = "userCategories"
}

/// Titles marked as favorites, by library item ID, one per line (AppStorage can't hold a set).
enum Favorites {
    static func ids(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    static func toggled(_ id: String, in stored: String) -> String {
        var ids = ids(stored)
        if ids.remove(id) == nil { ids.insert(id) }
        return ids.sorted().joined(separator: "\n")
    }
}

/// Categories OverPass keeps by itself, after the game clients in the sidebar while they have titles.
enum BuiltInCategory: String, CaseIterable, Identifiable {
    /// Mac apps added to the library.
    case mac
    /// Windows titles no game client installed: apps from Home's Utilities and programs installed on their own.
    case other

    var id: String { rawValue }
    var name: String { self == .mac ? "Mac" : "Other" }
    var symbol: String { self == .mac ? "apple.logo" : "square.stack.fill" }
}

/// A category the user made, like a Steam collection: a name and the library item IDs in it.
struct UserCategory: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var items: [String] = []
}

/// The user's categories, kept in sidebar order as JSON in one string (AppStorage can't hold an array).
enum UserCategories {
    static func list(_ stored: String) -> [UserCategory] {
        (try? JSONDecoder().decode([UserCategory].self, from: Data(stored.utf8))) ?? []
    }

    static func encoded(_ list: [UserCategory]) -> String {
        (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Adds a category, optionally with a first title, and returns its ID.
    static func added(_ name: String, with item: String? = nil, in stored: inout String) -> String {
        let category = UserCategory(name: name, items: item.map { [$0] } ?? [])
        stored = encoded(list(stored) + [category])
        return category.id
    }

    static func toggled(_ item: String, in categoryID: String, stored: inout String) {
        var all = list(stored)
        guard let index = all.firstIndex(where: { $0.id == categoryID }) else { return }
        if let at = all[index].items.firstIndex(of: item) { all[index].items.remove(at: at) }
        else { all[index].items.append(item) }
        stored = encoded(all)
    }

    static func renamed(_ categoryID: String, to name: String, stored: inout String) {
        var all = list(stored)
        guard let index = all.firstIndex(where: { $0.id == categoryID }) else { return }
        all[index].name = name
        stored = encoded(all)
    }

    static func removed(_ categoryID: String, stored: inout String) {
        stored = encoded(list(stored).filter { $0.id != categoryID })
    }

    /// Asks for a category name; nil when cancelled or left empty.
    @MainActor static func askName(title: String, button: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Group titles any way you like. A title can be in several categories."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.placeholderString = "Category name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// How the Covers layout draws each title: the bare cover, or in a game case with the store's band on top (flat, or
/// tilting toward the pointer).
enum CoverStyle: String, CaseIterable, Identifiable {
    case clean, gameCase, tiltingCase
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "Clean Cover"
        case .gameCase: "Case"
        case .tiltingCase: "3D Case"
        }
    }

    var isCase: Bool { self == .gameCase || self == .tiltingCase }
}

/// A sort the toolbar's Sort By menu offers; the list's column headers set the same one.
protocol SortKey: CaseIterable, Identifiable, Hashable, RawRepresentable where RawValue == String {
    associatedtype Row
    var title: String { get }
    var keyPath: KeyPath<Row, String> { get }
}

extension SortKey {
    var id: String { rawValue }

    func comparators(ascending: Bool) -> [KeyPathComparator<Row>] {
        [KeyPathComparator(keyPath, comparator: .localizedStandard, order: ascending ? .forward : .reverse)]
    }

    /// The sort a table's header click chose, as a key and an order.
    static func from(_ comparators: [KeyPathComparator<Row>]) -> (Self, Bool)? {
        guard let first = comparators.first,
              let key = allCases.first(where: { ($0.keyPath as PartialKeyPath<Row>) == first.keyPath }) else { return nil }
        return (key, first.order == .forward)
    }
}

/// What titles are sorted by, in every layout.
enum LibrarySort: String, SortKey {
    case name, container, engine, graphics
    static let key = "librarySort", ascendingKey = "librarySortAscending"

    var title: String {
        switch self {
        case .name: "Name"
        case .container: "Container"
        case .engine: "Engine"
        case .graphics: "Graphics"
        }
    }

    var keyPath: KeyPath<LibraryEntry, String> {
        switch self {
        case .name: \.name
        case .container: \.bottleName
        case .engine: \.engineName
        case .graphics: \.graphicsName
        }
    }
}

/// What containers are sorted by, in every layout.
enum ContainerSort: String, SortKey {
    case name, windows, graphics
    static let key = "containerSort", ascendingKey = "containerSortAscending"

    var title: String {
        switch self {
        case .name: "Name"
        case .windows: "Windows"
        case .graphics: "Graphics"
        }
    }

    var keyPath: KeyPath<Bottle, String> {
        switch self {
        case .name: \.name
        case .windows: \.template.displayName
        case .graphics: \.graphics.displayName
        }
    }
}

/// The toolbar's view options side by side in one toolbar item, so they share one pill.
struct ViewControls<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            // The size of the toolbar's other icons.
            .font(.system(size: 15))
            .padding(.horizontal, 8)
            .fixedSize()
    }
}

/// The toolbar's Sort By menu, like Finder's: the keys, then the order.
struct SortMenu<Key: SortKey>: View {
    @Binding var key: Key
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            Picker("Sort By", selection: $key) {
                ForEach(Array(Key.allCases)) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .help("Sorted by \(key.title.lowercased()), \(ascending ? "ascending" : "descending")")
    }
}

/// The toolbar's layout menu, like Finder's in a narrow window: the current layout's icon, the layouts in a menu,
/// and the cover styles while showing covers.
struct LayoutMenu: View {
    @Binding var layout: LibraryLayout
    var coverStyles = false
    var noun = "titles"
    @AppStorage(ViewOptions.coverStyleKey) private var coverStyle: CoverStyle = .gameCase

    var body: some View {
        Menu {
            Picker("Show As", selection: $layout) {
                ForEach(LibraryLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            if coverStyles && layout == .covers {
                Picker("Cover View", selection: $coverStyle) {
                    ForEach(CoverStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(layout.title, systemImage: layout.symbol)
        }
        .help("Show \(noun) as icons, a list, rows or covers")
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid, list, rows, covers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: "Icons"
        case .list: "List"
        case .rows: "Rows"
        case .covers: "Covers"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .rows: "rectangle.grid.1x2"
        case .covers: "rectangle.portrait.on.rectangle.portrait"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .grid: "1"
        case .list: "2"
        case .rows: "3"
        case .covers: "4"
        }
    }
}

extension LibraryLayout {
    /// Each layout keeps its own size, set with the status bar's slider: the icon edge, or a cover's width
    /// (covers are 2:3 like Steam's library capsules).
    var sizeKey: String { "librarySize." + rawValue }

    var sizeRange: ClosedRange<Double> {
        switch self {
        case .grid: 32...128
        case .list: 16...32
        case .rows: 24...80
        case .covers: 90...260
        }
    }

    var defaultSize: Double {
        switch self {
        case .grid: 64
        case .list: 20
        case .rows: 48
        case .covers: 150
        }
    }
}

/// What the menu bar needs from the main window that has focus.
struct MainWindowActions {
    var install: () -> Void
    var importProfile: () -> Void
    var importContainer: () -> Void
    var addMacApps: () -> Void
    var runProgram: (() -> Void)?
    var selection: Binding<SidebarItem?>
    var clients: [GameProfile]
    /// The built-in categories that have titles.
    var builtInCategories: [BuiltInCategory]
    var back: (() -> Void)?
    var forward: (() -> Void)?
}

private struct MainWindowKey: FocusedValueKey {
    typealias Value = MainWindowActions
}

extension FocusedValues {
    var mainWindow: MainWindowActions? {
        get { self[MainWindowKey.self] }
        set { self[MainWindowKey.self] = newValue }
    }
    /// What File › Uninstall acts on: the selected title, client or bottle of the page in front.
    var uninstallSelection: UninstallSelection? {
        get { self[UninstallSelectionKey.self] }
        set { self[UninstallSelectionKey.self] = newValue }
    }
}

struct UninstallSelection {
    let name: String
    let open: () -> Void
}

private struct UninstallSelectionKey: FocusedValueKey {
    typealias Value = UninstallSelection
}

struct OverPassCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.mainWindow) private var main
    @FocusedValue(\.uninstallSelection) private var uninstallSelection
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false
    @AppStorage(ViewOptions.showBottlesKey) private var showBottles = false
    @AppStorage(ViewOptions.showClientIconsKey) private var showClientIcons = false
    @AppStorage(ViewOptions.showClientInCategoryKey) private var showClientInCategory = true
    @AppStorage(ViewOptions.layoutKey) private var layout: LibraryLayout = .grid
    @AppStorage(ViewOptions.coverStyleKey) private var coverStyle: CoverStyle = .gameCase
    @AppStorage(ViewOptions.categoriesKey) private var categories = ""

    var body: some Commands {
        // About opens OverPass's own window, with the credits and a way to support the project.
        CommandGroup(replacing: .appInfo) {
            Button("About OverPass") { openWindow(id: "about") }
        }

        // Settings… comes first under About; the setup wizard last, just above Services.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Run Setup Wizard Again…") { hasCompletedSetup = false }
        }

        CommandGroup(replacing: .newItem) {
            Button("Install a Game or App…") { main?.install() }
                .keyboardShortcut("n")
                .disabled(main == nil)
            Button("Quick Run…") { main?.runProgram?() }
                .keyboardShortcut("r")
                .disabled(main?.runProgram == nil)
            Button("Add Mac App to Library…") { main?.addMacApps() }
                .disabled(main == nil)
            Button("Import Profile…") { main?.importProfile() }
                .disabled(main == nil)
            Button("Import Container…") { main?.importContainer() }
                .disabled(main == nil)
            Divider()
            Button(uninstallSelection.map { "Uninstall \($0.name)…" } ?? "Uninstall…") { uninstallSelection?.open() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(uninstallSelection == nil)
            Divider()
            Button("Show Containers in Finder") {
                NSWorkspace.shared.open(Bottle.bottlesDirectory())
            }
        }

        CommandGroup(before: .toolbar) {
            Picker("Show Titles As", selection: $layout) {
                ForEach(LibraryLayout.allCases) { option in
                    Text(option.title).tag(option)
                        .keyboardShortcut(option.shortcut)
                }
            }
            .pickerStyle(.inline)
            Picker("Cover View", selection: $coverStyle) {
                ForEach(CoverStyle.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Menu("Categories") {
                Toggle("Show Category Icons", isOn: $showClientIcons)
                Toggle("Show Category Clients", isOn: $showClientInCategory)
                Toggle("Show Containers", isOn: $showBottles)
            }
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { main?.back?() }
                .keyboardShortcut("[")
                .disabled(main?.back == nil)
            Button("Forward") { main?.forward?() }
                .keyboardShortcut("]")
                .disabled(main?.forward == nil)
            Divider()
            Button("Home") { main?.selection.wrappedValue = .home }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(main == nil)
            Button("All Titles") { main?.selection.wrappedValue = .library }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(main == nil)
            Button("Favorites") { main?.selection.wrappedValue = .favorites }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(main == nil)
            if let clients = main?.clients, !clients.isEmpty {
                Divider()
                ForEach(clients) { client in
                    Button(client.name) { main?.selection.wrappedValue = .launcher(client.id) }
                }
            }
            if let builtIn = main?.builtInCategories, !builtIn.isEmpty {
                if main?.clients.isEmpty != false { Divider() }
                ForEach(builtIn) { category in
                    Button(category.name) { main?.selection.wrappedValue = .builtIn(category) }
                }
            }
            let userCategories = UserCategories.list(categories)
            if !userCategories.isEmpty {
                Divider()
                ForEach(userCategories) { category in
                    Button(category.name) { main?.selection.wrappedValue = .category(category.id) }
                        .disabled(main == nil)
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Check for Updates…") { UpdateCheck.checkNow(with: openSettings) }
            Divider()
            Link("OverPass Releases", destination: URL(string: "https://github.com/McKack/overpass/releases")!)
            Link("OverPass Wine Releases", destination: URL(string: "https://github.com/McKack/overpass-wine/releases")!)
            Link("OverPass Runtime Releases", destination: URL(string: "https://github.com/McKack/overpass-runtime/releases")!)
            Divider()
            Button("Credits") { openWindow(id: "credits") }
        }
    }
}

/// Fades the edges of a scroll view while more content is past them, and only then: the bottom always, the top
/// too where no toolbar glass already covers it (Settings, the profile window).
struct EdgeFade: ViewModifier {
    let top: Bool
    @State private var moreAbove = false
    @State private var moreBelow = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                [geometry.contentOffset.y > -geometry.contentInsets.top + 1,
                 geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1]
            } action: { _, more in
                withAnimation(.easeOut(duration: 0.15)) {
                    moreAbove = top && more[0]
                    moreBelow = more[1]
                }
            }
            .mask {
                VStack(spacing: 0) {
                    if top {
                        LinearGradient(colors: [.black.opacity(moreAbove ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 24)
                    }
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 36)
                }
                // Cover the area under the toolbar too: content scrolled there is what its glass blurs. With a top
                // fade the mask keeps to the safe area, so the fade sits where it can be seen.
                .ignoresSafeArea(edges: top ? .bottom : .all)
            }
    }
}

extension View {
    func bottomFade() -> some View { modifier(EdgeFade(top: false)) }
    /// Both edges fade while there is more to scroll to.
    func edgeFade() -> some View { modifier(EdgeFade(top: true)) }
}

/// How Settings names and explains things: plain words by default, or how they work underneath.
enum SettingsDetail: String, CaseIterable, Identifiable {
    case simple, technical
    static let key = "settingsDetail"
    var id: String { rawValue }
    var title: String { self == .simple ? "Simple" : "Technical" }
}

/// A Settings caption that follows the Simple / Technical switch.
struct DetailCaption: View {
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple
    let simple: String
    let technical: String

    init(_ simple: String, technical: String) {
        self.simple = simple
        self.technical = technical
    }

    var body: some View {
        Text(detail == .simple ? simple : technical)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Simple / Technical switch, as at the bottom of Settings and the profile window.
struct DetailSwitch: View {
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple

    var body: some View {
        HStack(spacing: 6) {
            Text("Advanced view").font(.callout)
            Toggle("Advanced view", isOn: Binding(get: { detail == .technical },
                                               set: { detail = $0 ? .technical : .simple }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .help("Off: plain names and short descriptions. On: what each part is and how it works.")
    }
}

/// Tabs drawn like the Settings window's toolbar: an icon over a label, the chosen one tinted on a rounded plate.
struct IconTabBar<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let title: String
        let symbol: String
        var id: Tab { tab }
    }
    let items: [Item]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let chosen = item.tab == selection
                Button { selection = item.tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 19)).frame(height: 22)
                        Text(item.title).font(.system(size: 11))
                    }
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(minWidth: 64)
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6))
                            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.quaternary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
