import SwiftUI
import WebKit

/// A game in a built-in store library, owned by the signed-in account.
struct LibraryGame: Identifiable, Hashable, Codable {
    let id: String              // the store's own ID (Legendary's app_name, GOG's product ID)
    /// The store's folder in the media cache ("GOG", "Epic").
    var service = ""
    let title: String
    let cover: URL?
    /// A square icon, for the Icons, List and Rows layouts; the cover stands in when there's none.
    var icon: URL? = nil
    /// Why OverPass can't install it ("Needs the Origin launcher"), if it can't.
    var unavailable: String? = nil
}

/// The last library list a store showed, in its config folder (games.json), so its category opens with it at
/// once while a refresh asks the store only what changed.
enum SavedLibrary {
    /// How old a saved list can be before opening the category refreshes it.
    static let freshFor: TimeInterval = 30 * 60

    nonisolated static func load(_ folder: URL) -> (games: [LibraryGame], saved: Date?) {
        let file = folder.appendingPathComponent("games.json")
        guard let data = try? Data(contentsOf: file),
              let games = try? JSONDecoder().decode([LibraryGame].self, from: data) else { return ([], nil) }
        return (games, (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)
    }

    nonisolated static func save(_ games: [LibraryGame], to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(games).write(to: folder.appendingPathComponent("games.json"), options: .atomic)
    }

    nonisolated static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("games.json"))
    }
}

struct StoreProgress {
    var percent: Double = 0
    var downloaded: String?
    var total: String?
    var eta: String?
    /// After the download: what's being set up in the bottle ("Visual C++ 2019").
    var step: String?
}

/// A store whose games OverPass lists, installs and starts itself (EpicStore, GOGStore). Once signed in it is a
/// category in the sidebar (LibraryView with the store's launcher) listing the owned games beside the installed ones.
@MainActor
protocol StoreLibrary: AnyObject, Observable {
    static var storeName: String { get }
    /// Shown with a Beta badge: works in principle but hasn't been tested end to end.
    static var beta: Bool { get }
    static var component: ComponentID { get }
    /// The setup screen's text: what the component is and does.
    static var about: String { get }
    static var loginURL: URL { get }
    static var userAgent: String? { get }
    /// The sign-in code, once the login page has ended on the page that holds it.
    static func code(in webView: WKWebView, at url: URL) async -> String?

    var account: String? { get }
    var games: [LibraryGame] { get }
    var loading: Bool { get }
    /// When the list was last fetched from the store; nil when it never was.
    var refreshed: Date? { get }
    var error: String? { get set }
    var progress: [String: StoreProgress] { get }
    var queue: [String] { get }

    func signIn(code: String) async
    func signOut() async
    func refresh() async
    func isInstalled(_ game: LibraryGame) -> Bool
    func install(_ game: LibraryGame, using manager: BottleManager)
    func cancel(_ game: LibraryGame)
    func uninstall(_ id: String, using manager: BottleManager) async
    /// The installed game in the library, to run it.
    func item(_ game: LibraryGame, in manager: BottleManager) -> LibraryItem?
    /// The sign-in page; `done` gets the sign-in code, or nil when cancelled.
    func signInView(done: @escaping (String?) -> Void) -> AnyView
}

extension StoreLibrary {
    static var beta: Bool { false }
    func signInView(done: @escaping (String?) -> Void) -> AnyView { AnyView(StoreSignInSheet<Self>(done: done)) }
}

/// A store's own sign-in, then the store's category in the sidebar: what Home's library entry and a signed-out
/// category page open. Sets up the store's component first when it isn't installed yet.
struct StoreConnectSheet: View {
    @Environment(ComponentManager.self) private var components
    let store: any StoreLibrary
    /// Called with whether the account is now signed in.
    let done: (Bool) -> Void
    @State private var signingIn = false

    var body: some View {
        let kind = type(of: store)
        Group {
            if components.isInstalled(kind.component) && !signingIn && store.account == nil {
                // The component is there: straight to the store's login page.
                store.signInView { code in
                    guard let code else { return done(false) }
                    signingIn = true
                    Task {
                        await store.signIn(code: code)
                        signingIn = false
                        done(store.account != nil)
                    }
                }
            } else {
                VStack(spacing: 14) {
                    HStack {
                        Label("\(kind.storeName) Library", systemImage: "square.stack.3d.up").font(.title2.bold())
                        if kind.beta { BetaBadge() }
                    }
                    Text(kind.about).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if signingIn || components.busy == kind.component {
                        ProgressView().controlSize(.small)
                    }
                    if signingIn {
                        // Signing in also fetches the whole library, which takes a while for a large one.
                        Text("Signing in and loading your games. Please wait, this can take a couple of minutes.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let error = components.lastError ?? store.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                        Button("Set Up") { Task { await components.install(kind.component) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(components.busy != nil || signingIn)
                    }
                }
                .padding(24)
                .frame(width: 420)
            }
        }
    }
}

/// An owned game that isn't installed, in a store's category: its art dimmed, with an Install button or the
/// download's progress. One view per library layout, drawn like the installed titles beside it.
struct StoreGameArt: View {
    let game: LibraryGame
    /// The square icon (Icons, List, Rows) or the 2:3 cover (Covers).
    var cover = false

    var body: some View {
        let icon = !cover && game.icon != nil
        CachedImage(url: icon ? game.icon : game.cover, service: game.service.isEmpty ? "Stores" : game.service,
                    kind: icon ? .icons : .covers, id: game.id) {
            Rectangle().fill(.quaternary).overlay {
                if cover { Text(game.title).font(.caption).multilineTextAlignment(.center).padding(8) }
            }
        }
    }
}

/// What a store game shows instead of Run: its progress while installing, Waiting in the queue, or Install.
struct StoreGameAction: View {
    @Environment(BottleManager.self) private var manager
    let game: LibraryGame
    let store: any StoreLibrary
    var compact = false

    var body: some View {
        if let progress = store.progress[game.id] {
            HStack(spacing: 6) {
                if progress.step != nil {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: progress.percent, total: 100).controlSize(.small)
                        .frame(maxWidth: compact ? 70 : 120)
                }
                Button { store.cancel(game) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Stop; installing again resumes")
                    .disabled(progress.step != nil)
            }
            .help(StoreGameAction.detail(progress))
        } else if store.queue.contains(game.id) {
            HStack(spacing: 6) {
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                Button { store.cancel(game) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
        } else if let reason = game.unavailable {
            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(reason)
        } else {
            Button("Install") { store.install(game, using: manager) }.controlSize(.small)
        }
    }

    /// "1.2 GB of 4 GB · 3:10 left", or the setup step after the download.
    static func detail(_ progress: StoreProgress) -> String {
        progress.step ?? [progress.downloaded.map { $0 + (progress.total.map { " of \($0)" } ?? "") },
                          progress.eta.map { "\($0) left" }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct StoreGameMenu: View {
    @Environment(BottleManager.self) private var manager
    @AppStorage(ViewOptions.hiddenKey) private var hidden = ""
    let game: LibraryGame
    let store: any StoreLibrary

    var body: some View {
        if store.progress[game.id] != nil || store.queue.contains(game.id) {
            Button("Stop Installing") { store.cancel(game) }
        } else {
            Button("Install") { store.install(game, using: manager) }.disabled(game.unavailable != nil)
        }
        let id = LibraryEntry.store(game).id
        Button(Hidden.ids(hidden).contains(id) ? "Unhide" : "Hide") { hidden = Hidden.toggled(id, in: hidden) }
    }
}

extension View {
    /// A click selects, a double click installs, as a title runs; the store game's menu on right-click.
    func storeGameItem(_ game: LibraryGame, store: any StoreLibrary, manager: BottleManager,
                       selected: Bool, select: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: select)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if game.unavailable == nil, store.progress[game.id] == nil { store.install(game, using: manager) }
            })
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help("\(game.title): not installed")
            .contextMenu { StoreGameMenu(game: game, store: store) }
    }
}

struct StoreGameTile: View {
    @Environment(BottleManager.self) private var manager
    let game: LibraryGame
    let store: any StoreLibrary
    let iconSize: CGFloat
    var selected = false
    var select: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            StoreGameArt(game: game)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.18))
                .opacity(0.55)
            Text(game.title).font(.callout).lineLimit(1).foregroundStyle(.secondary)
            StoreGameAction(game: game, store: store, compact: true)
        }
        .frame(width: iconSize + 56, height: iconSize + 84)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .storeGameItem(game, store: store, manager: manager, selected: selected, select: select)
    }
}

struct StoreGameCover: View {
    @Environment(BottleManager.self) private var manager
    let game: LibraryGame
    let store: any StoreLibrary
    let width: CGFloat
    var selected = false
    var platform: CasePlatform? = nil
    var select: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            StyledCover(platform: platform, width: width, selected: selected, dimmed: true) { corner in
                StoreGameArt(game: game, cover: true)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
            }
            CoverCaption(title: game.title, platform: platform, width: width, dimmed: true, icon: false)
            StoreGameAction(game: game, store: store, compact: true)
        }
        .storeGameItem(game, store: store, manager: manager, selected: selected, select: select)
    }
}

struct StoreGameRow: View {
    @Environment(BottleManager.self) private var manager
    let game: LibraryGame
    let store: any StoreLibrary
    let iconSize: CGFloat
    var selected = false
    var select: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            StoreGameArt(game: game)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.18))
                .opacity(0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline).foregroundStyle(.secondary)
                Text(store.progress[game.id].map(StoreGameAction.detail).flatMap { $0.isEmpty ? nil : $0 }
                     ?? "\(type(of: store).storeName) · Not installed")
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
            Spacer()
            StoreGameAction(game: game, store: store)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .storeGameItem(game, store: store, manager: manager, selected: selected, select: select)
    }
}

// MARK: - Sign-in

/// The store's own login page. When it reaches the page holding the sign-in code, the code goes to the store's
/// client; nothing is copied by hand. "Sign in with Google/Steam/…" opens its page beside the login (the sheet
/// widens to make room) instead of in a window of its own, and the sheet narrows again when that page closes.
struct StoreSignInSheet<Store: StoreLibrary>: View {
    let done: (String?) -> Void
    @State private var session = SignInSession(loginURL: Store.loginURL, userAgent: Store.userAgent,
                                               code: Store.code(in:at:))

    private static var loginWidth: CGFloat { 560 }
    /// With a pop-up open the login keeps a third of the width, up to what fits on the screen.
    private var width: CGFloat {
        guard session.popup != nil else { return Self.loginWidth }
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        return min(Self.loginWidth * 3, screen - 80)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // While a sign-in page is open beside it, the login steps back: faded, not clickable, with
                // a way back to its other choices.
                WebViewHost(view: session.main)
                    .opacity(session.popup == nil ? 1 : 0.3)
                    .allowsHitTesting(session.popup == nil)
                    .overlay {
                        if session.popup != nil {
                            // Solid, with a window's soft shadow, so it reads clearly over the faded page.
                            Button { session.closePopup() } label: {
                                Label("Choose Another Way", systemImage: "chevron.left")
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                                    .overlay(Capsule().strokeBorder(.separator))
                                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    .frame(width: session.popup == nil ? nil : width / 3)
                if let popup = session.popup {
                    Divider()
                    VStack(spacing: 0) {
                        HStack {
                            Button { session.closePopup() } label: { Label("Back", systemImage: "chevron.left") }
                                .buttonStyle(.borderless).help("Back to the \(Store.storeName) log in")
                            Spacer()
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            Text(session.popupHost ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        Divider()
                        WebViewHost(view: popup)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            Divider()
            HStack {
                Text("Signing in to \(Store.storeName). OverPass keeps the sign-in, not your password.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: width, height: 640)
        .animation(.smooth(duration: 0.35), value: session.popup != nil)
        .onAppear { session.done = done }
    }
}

/// The login web view and the pop-up a sign-in button opens from it, in one fresh, non-persistent session:
/// the sign-in is the store client's to keep.
@MainActor
@Observable
final class SignInSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let main: WKWebView
    private(set) var popup: WKWebView?
    private(set) var popupHost: String?
    @ObservationIgnored var done: ((String?) -> Void)?
    @ObservationIgnored private let code: (WKWebView, URL) async -> String?
    @ObservationIgnored private var finished = false

    init(loginURL: URL, userAgent: String?, code: @escaping (WKWebView, URL) async -> String?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        main = WKWebView(frame: .zero, configuration: config)
        main.customUserAgent = userAgent
        self.code = code
        super.init()
        main.navigationDelegate = self
        main.uiDelegate = self
        main.load(URLRequest(url: loginURL))
    }

    func closePopup() {
        popup?.stopLoading()
        popup = nil
        popupHost = nil
    }

    // A sign-in button's window.open: the page shows beside the login, sharing its session and opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = main.customUserAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        popup = view
        popupHost = navigationAction.request.url?.host
        return view
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popup { closePopup() }
    }

    // A redirect to localhost carries the code and never loads (nothing listens there), so take it on the way.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, url.host == "localhost" else { return .allow }
        if !finished, let code = await code(webView, url) {
            finished = true
            done?(code)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === popup { popupHost = webView.url?.host ?? popupHost }
        guard !finished, let url = webView.url else { return }
        Task {
            guard !finished, let code = await code(webView, url) else { return }
            finished = true
            done?(code)
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The built-in libraries, by the bottle group of the store whose own client they stand in for. Home's install
/// menu offers the library first and the client second.
@MainActor
enum BuiltInLibrary {
    struct Entry {
        let name: String      // "GOG Library"
        let client: String?   // "GOG Galaxy"; nil when the library is the only way (Xbox)
    }

    static func entry(for group: String?) -> Entry? {
        switch group {
        case EpicStore.group: Entry(name: "\(EpicStore.storeName) Library", client: EpicStore.clientName)
        case GOGStore.group: Entry(name: "\(GOGStore.storeName) Library", client: GOGStore.clientName)
        case XboxStore.group where XboxOptIn.enabled: Entry(name: "\(XboxStore.storeName) Library", client: nil)
        default: nil
        }
    }

    static func store(for group: String?) -> (any StoreLibrary)? {
        switch group {
        case EpicStore.group: EpicStore.shared
        case GOGStore.group: GOGStore.shared
        case XboxStore.group where XboxOptIn.enabled: XboxStore.shared
        default: nil
        }
    }

    /// Whether the store's account is signed in, which makes it a category even before a game is installed.
    static func signedIn(_ group: String?) -> Bool { store(for: group)?.account != nil }
}

/// Sign in to a store (by its bottle group) and show its category (by the store's profile ID), from any page.
struct StoreActions {
    var connect: (String) -> Void = { _ in }
    var show: (String) -> Void = { _ in }
}

private struct StoreActionsKey: EnvironmentKey {
    static let defaultValue = StoreActions()
}

extension EnvironmentValues {
    var storeActions: StoreActions {
        get { self[StoreActionsKey.self] }
        set { self[StoreActionsKey.self] = newValue }
    }
}
