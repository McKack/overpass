import SwiftUI
import Foundation
import WebKit

// Xbox PC and Game Pass games through Xodus (GPL-3; xodus-cli and xodus-service, separate programs OverPass
// downloads only after the user turns the Xbox Library on). Xodus keeps the Microsoft sign-in (tokens in the
// Keychain), lists the account's entitlements, streams and decrypts the game packages and starts them through our
// Wine; xodus-service answers the game's Xbox runtime over a Unix socket while it runs. OverPass hosts the sign-in
// page, lists the library with titles and art from Microsoft's public catalogue, and shows progress.
// Opt-in: see XboxOptIn. Research notes: ~/Dev/OverPass-reference/stores/xbox.md.

@MainActor
@Observable
final class XboxStore: StoreLibrary {
    static let shared = XboxStore()

    static let storeName = "Xbox"
    static let beta = true
    static let component = ComponentID.xodus
    static let about = "Play your Xbox PC and Game Pass games. OverPass downloads Xodus, an open-source Xbox client, "
        + "to sign in to your Microsoft account and download games."
    // Xodus drives the sign-in page itself (XboxSignInSheet); these are unused.
    static let loginURL = URL(string: "https://login.live.com")!
    static let userAgent: String? = nil
    static func code(in webView: WKWebView, at url: URL) async -> String? { nil }

    private(set) var account: String?
    private(set) var games: [LibraryGame] = []
    private(set) var refreshed: Date?
    private(set) var loading = false
    var error: String?
    private(set) var progress: [String: StoreProgress] = [:]
    private(set) var queue: [String] = []
    private var running: Process?
    private var cancelled: Set<String> = []

    nonisolated static let group = "xbox"
    nonisolated static let launcherName = "Xbox"
    /// The Store market for catalogue lookups and downloads.
    nonisolated static let market = "US"

    nonisolated static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/Stores/Xbox")
    }
    nonisolated private static var userFile: URL { configDir.appendingPathComponent("user.json") }

    init() {
        account = Self.storedAccount()
        if account != nil { (games, refreshed) = SavedLibrary.load(Self.configDir) }
    }

    func signInView(done: @escaping (String?) -> Void) -> AnyView { AnyView(XboxSignInSheet(done: done)) }

    // MARK: Account

    /// The name OverPass last saw for the account Xodus keeps; Xodus itself is asked on sign-in and refresh.
    nonisolated static func storedAccount() -> String? {
        guard let data = try? Data(contentsOf: userFile),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return user["name"] as? String
    }

    /// The sign-in sheet ends once Xodus has the tokens: read back who signed in.
    func signIn(code: String) async {
        error = nil
        do {
            guard let name = try await currentAccount() else {
                error = "Xbox didn't finish the sign-in. Try again."
                return
            }
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["name": name]).write(to: Self.userFile)
            account = name
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The gamertag, or the Microsoft account name; nil when Xodus has no account stored.
    private func currentAccount() async throws -> String? {
        let result = try await Self.run(["account", "--json"])
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              json["stored"] as? Bool == true else { return nil }
        let profile = try? await Self.run(["profile", "--json"])
        let gamertag = profile.flatMap { try? JSONSerialization.jsonObject(with: $0.stdout) as? [String: Any] }?["gamertag"] as? String
        return gamertag ?? json["username"] as? String ?? "Xbox"
    }

    func signOut() async {
        _ = try? await Self.run(["logout"])
        try? FileManager.default.removeItem(at: Self.userFile)
        account = nil
        games = []
        refreshed = nil
        SavedLibrary.remove(Self.configDir)
    }

    // MARK: Library

    /// What the catalogue says about a product, kept in catalog.json so only new entitlements are looked up.
    private struct Product: Codable {
        let title: String
        let cover: String?
        let icon: String?
        /// A Windows PC package Xodus can stream (MSIXVC).
        let pc: Bool
        let isGame: Bool
    }

    /// The account's PC games: its entitlements from Xodus (owned and Game Pass), then each product's title, art
    /// and packages from Microsoft's public catalogue.
    func refresh() async {
        guard account != nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await Self.run(["library", "--json", "--market", Self.market])
            guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                  let entitlements = json["entitlements"] as? [[String: Any]] else {
                if (try? await currentAccount()) == nil {
                    await signOut()
                    throw StoreHelper.Failure.message("The Xbox sign-in has expired. Sign in again.")
                }
                throw StoreHelper.Failure.message(Self.failure(result, or: "Couldn't get your Xbox library."))
            }
            let now = Date.now
            let ids = entitlements.compactMap { e -> String? in
                guard e["status"] as? String == "Active", e["isTrial"] as? Bool == false, e["special"] as? Bool != true,
                      let end = (e["endDate"] as? String).flatMap(Self.date), end > now else { return nil }
                return e["productId"] as? String
            }

            let cacheFile = Self.configDir.appendingPathComponent("catalog.json")
            var products = (try? JSONDecoder().decode([String: Product].self, from: Data(contentsOf: cacheFile))) ?? [:]
            let missing = Array(Set(ids).filter { products[$0] == nil })
            for start in stride(from: 0, to: missing.count, by: 20) {
                let found = await Self.products(Array(missing[start..<min(start + 20, missing.count)]))
                products.merge(found) { $1 }
            }
            try? JSONEncoder().encode(products).write(to: cacheFile)
            games = Set(ids).compactMap { id in
                guard let p = products[id], p.isGame, p.pc else { return nil }
                return LibraryGame(id: id, service: "Xbox", title: p.title, cover: p.cover.flatMap(URL.init(string:)),
                                   icon: p.icon.flatMap(URL.init(string:)))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            refreshed = .now
            SavedLibrary.save(games, to: Self.configDir)
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Up to 20 products from the display catalogue in one request.
    nonisolated private static func products(_ ids: [String]) async -> [String: Product] {
        var url = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")!
        url.queryItems = [URLQueryItem(name: "bigIds", value: ids.joined(separator: ",")),
                          URLQueryItem(name: "market", value: market),
                          URLQueryItem(name: "languages", value: "en-us,neutral")]
        guard let (data, response) = try? await URLSession.shared.data(from: url.url!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var found: [String: Product] = [:]
        for product in json["Products"] as? [[String: Any]] ?? [] {
            guard let id = product["ProductId"] as? String else { continue }
            let localized = (product["LocalizedProperties"] as? [[String: Any]])?.first ?? [:]
            let images = localized["Images"] as? [[String: Any]] ?? []
            func image(_ purpose: String) -> String? {
                guard let uri = images.first(where: { $0["ImagePurpose"] as? String == purpose })?["Uri"] as? String else { return nil }
                return uri.hasPrefix("//") ? "https:" + uri : uri
            }
            let packages = (product["DisplaySkuAvailabilities"] as? [[String: Any]] ?? []).flatMap {
                (($0["Sku"] as? [String: Any])?["Properties"] as? [String: Any])?["Packages"] as? [[String: Any]] ?? []
            }
            let pc = packages.contains { package in
                (package["PackageFormat"] as? String)?.lowercased() == "msixvc"
                    && (package["PlatformDependencies"] as? [[String: Any]] ?? []).contains { $0["PlatformName"] as? String == "Windows.Desktop" }
            }
            found[id] = Product(title: localized["ProductTitle"] as? String ?? id,
                                cover: image("Poster") ?? image("BoxArt"), icon: image("BoxArt"),
                                pc: pc, isGame: product["ProductType"] as? String == "Game")
        }
        return found
    }

    struct Installed: Codable {
        let title: String
        let path: String
        /// The game's program, relative to its folder, from MicrosoftGame.config.
        let executable: String
    }

    nonisolated private static var installedFile: URL { configDir.appendingPathComponent("installed.json") }

    /// The games OverPass installed through Xodus, by product ID.
    nonisolated static func installed() -> [String: Installed] {
        (try? JSONDecoder().decode([String: Installed].self, from: Data(contentsOf: installedFile))) ?? [:]
    }

    nonisolated private static func saveInstalled(_ all: [String: Installed]) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: installedFile)
    }

    func isInstalled(_ game: LibraryGame) -> Bool {
        _ = progress
        return Self.installed()[game.id] != nil
    }

    func item(_ game: LibraryGame, in manager: BottleManager) -> LibraryItem? {
        manager.library.first { $0.app.backend == .xodus && $0.app.storeID == game.id }
    }

    // MARK: Install

    /// The bottle Xbox games go into, made with the Xbox profile's settings the first time.
    private func bottle(using manager: BottleManager) async throws -> Bottle {
        if let existing = manager.bottles.first(where: { $0.group == Self.group }) { return existing }
        let profile = manager.profiles?.profiles.first { $0.bottle.group == Self.group }
        let bottle = try await manager.createBottle(name: manager.freeBottleName(Self.launcherName),
                                                    template: profile?.bottle.template ?? .windows10,
                                                    group: Self.group, profileID: profile?.id)
        for runtime in (profile?.runtimes ?? []).compactMap(Runtime.init(rawValue:)) {
            try await runtime.install(in: bottle, using: manager) { _ in }
        }
        return bottle
    }

    func install(_ game: LibraryGame, using manager: BottleManager) {
        guard progress[game.id] == nil, !queue.contains(game.id) else { return }
        queue.append(game.id)
        if queue.count == 1 { Task { await drain(manager) } }
    }

    private func drain(_ manager: BottleManager) async {
        while let id = queue.first {
            progress[id] = StoreProgress()
            await runInstall(id, using: manager)
            progress[id] = nil
            queue.removeFirst()
        }
        manager.loadBottles()
    }

    private func runInstall(_ id: String, using manager: BottleManager) async {
        error = nil
        do {
            // Which package of the Store offer to download: Xodus picks it when there's only one PC game in it.
            let plan = try await Self.run(["resolve-package", id, "--json", "--market", Self.market])
            guard let json = try? JSONSerialization.jsonObject(with: plan.stdout) as? [String: Any] else {
                error = Self.failure(plan, or: "Couldn't get \(title(id)) from Xbox.")
                return
            }
            let choices = (json["choices"] as? [[String: Any]] ?? []).filter { $0["supported"] as? Bool == true }
            var selected: [String] = []
            switch json["status"] as? String {
            case "ready": break
            case "choice":
                // Several packages (a bundle): the game itself, the one with the root product's ID if there is one.
                guard let choice = choices.first(where: { $0["productId"] as? String == id && $0["kind"] as? String == "Game" })
                        ?? choices.first(where: { $0["kind"] as? String == "Game" }),
                      let content = choice["contentId"] as? String else { fallthrough }
                selected = ["--selected-content-id", content]
            default:
                error = "\(title(id)) has no PC package OverPass can install."
                return
            }

            let bottle = try await bottle(using: manager)
            let path = bottle.driveC.appendingPathComponent("XboxGames").appendingPathComponent(Self.folderName(title(id)))
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let result = try await Self.run(["streaming", id, path.path, "--progress-json", "--market", Self.market] + selected,
                                            started: { [weak self] in self?.running = $0 },
                                            stdoutLine: { [weak self] in self?.parseProgress($0, for: id) })
            running = nil
            if cancelled.remove(id) != nil { return }
            guard result.status == 0, let exe = Self.executable(in: path) else {
                error = Self.failure(result, or: "Couldn't install \(title(id)).")
                return
            }
            var all = Self.installed()
            all[id] = Installed(title: title(id), path: path.path, executable: exe)
            Self.saveInstalled(all)
        } catch {
            running = nil
            self.error = error.localizedDescription
        }
    }

    /// The title as a folder name: without the characters Windows doesn't allow in one.
    nonisolated private static func folderName(_ title: String) -> String {
        let name = title.components(separatedBy: CharacterSet(charactersIn: "<>:\"/\\|?*")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? "Game" : name
    }

    /// The game's program from its MicrosoftGame.config (the first <Executable Name="…">).
    nonisolated static func executable(in folder: URL) -> String? {
        guard let config = WindowsIcons.caseInsensitive(folder, "MicrosoftGame.config"),
              let xml = try? String(contentsOf: config, encoding: .utf8),
              let match = xml.firstMatch(of: #/<Executable\s[^>]*Name="([^"]+)"/#) else { return nil }
        return String(match.1)
    }

    func cancel(_ game: LibraryGame) {
        if let index = queue.firstIndex(of: game.id), index > 0 {
            queue.remove(at: index)
            return
        }
        guard let process = running, progress[game.id] != nil else { return }
        cancelled.insert(game.id)
        StoreHelper.interrupt(process)
    }

    /// Deletes the game's folder and OverPass's record of it. Saved games in the bottle's user folders stay.
    func uninstall(_ id: String, using manager: BottleManager) async {
        var all = Self.installed()
        guard let game = all.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: game.path))
        Self.saveInstalled(all)
        progress = progress  // isInstalled reads the file; this redraws the library
        manager.loadBottles()
    }

    private func title(_ id: String) -> String { games.first { $0.id == id }?.title ?? Self.installed()[id]?.title ?? id }

    // NEXUS_PROGRESS {"schema":1,"event":"progress","phase":…,"completedBytes":…,"totalBytes":…,"bytesPerSecond":…}
    private func parseProgress(_ line: String, for id: String) {
        guard progress[id] != nil, line.hasPrefix("NEXUS_PROGRESS "),
              let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(15).utf8)) as? [String: Any] else { return }
        let done = (json["completedBytes"] as? NSNumber)?.int64Value ?? 0
        let total = (json["totalBytes"] as? NSNumber)?.int64Value ?? 0
        let rate = (json["bytesPerSecond"] as? NSNumber)?.doubleValue ?? 0
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if total > 0 {
            progress[id]?.percent = Double(done) / Double(total) * 100
            progress[id]?.total = size(total)
        }
        progress[id]?.downloaded = size(done)
        if rate > 0, total > done {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            progress[id]?.eta = formatter.string(from: Double(total - done) / rate)
        }
    }

    // MARK: Launch

    /// Starts xodus-service for the game's Xbox runtime, then the game through `xodus-cli run`, which licenses it
    /// and hands Wine the decrypted program. The service stops when the game has quit.
    static func launch(_ app: WineApp, id: String, in bottle: Bottle, using manager: BottleManager) async throws {
        guard let game = installed()[id] else { throw StoreHelper.Failure.message("\(app.name) isn't installed.") }
        let wine = try manager.exeProcessTemplate([], in: bottle)

        let sessions = configDir.appendingPathComponent("service")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let runtime = sessions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let socket = runtime.appendingPathComponent("xodus.sock")
        let service = Process()
        service.executableURL = ComponentManager.xodusServicePath
        service.environment = ProcessInfo.processInfo.environment.merging(["XDG_RUNTIME_DIR": runtime.path,
                                                                           "XODUS_LOG": "error"]) { $1 }
        service.standardInput = FileHandle.nullDevice
        service.standardOutput = FileHandle.nullDevice
        service.standardError = FileHandle.nullDevice
        let stop = {
            if service.isRunning { service.interrupt() }
            try? FileManager.default.removeItem(at: runtime)
        }
        try service.run()
        let deadline = Date.now.addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: socket.path) {
            guard service.isRunning, Date.now < deadline else {
                stop()
                throw StoreHelper.Failure.message("The Xbox service didn't start. Check that you're signed in and online.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let process = Process()
        process.executableURL = ComponentManager.xodusCLIPath
        process.arguments = ["run", game.path, wine.executable.path, "--exe", game.executable, "--materialize-chain",
                             "--market", market]
        process.environment = wine.environment.merging(["XODUS_SOCKET": socket.path]) { $1 }
        process.currentDirectoryURL = URL(fileURLWithPath: game.path)
        if let log = LogCollector.lastRunHandle(app.name, in: bottle) {
            process.environment?["WINEDEBUG"] = process.environment?["WINEDEBUG"] ?? LogCollector.lastRunChannels(for: bottle)
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { _ in Task { @MainActor in stop() } }
        do { try process.run() } catch { stop(); throw error }
    }

    // MARK: Running Xodus

    nonisolated static func failure(_ result: StoreHelper.Result, or fallback: String) -> String {
        StoreHelper.failure(result, or: fallback)
    }

    nonisolated static func run(_ args: [String], started: (@MainActor (Process) -> Void)? = nil,
                                stdoutLine: (@MainActor (String) -> Void)? = nil) async throws -> StoreHelper.Result {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return try await StoreHelper.run(ComponentManager.xodusCLIPath, name: "Xbox Library", args,
                                         environment: ["XODUS_LOG": "error"], started: started, stdoutLine: stdoutLine)
    }
}

// MARK: - Sign-in

/// Microsoft's sign-in, driven by Xodus: xodus-cli asks for each page over its private stdio protocol (MACxus'
/// "NEXUS_AUTH_V1", ported from its MIT-licensed auth-transport/auth-window) and gets back what the page reports
/// through window.external.notify, as the Windows sign-in host would. The sheet closes when Xodus has the tokens.
struct XboxSignInSheet: View {
    let done: (String?) -> Void
    @State private var session = XboxSignIn()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let view = session.page {
                    XboxWebViewHost(view: view)
                } else if let failure = session.failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text(failure).multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else {
                    ProgressView("Connecting to Microsoft…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Signing in to Xbox with your Microsoft account. Xodus keeps the sign-in in your Keychain, not your password.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(session.failure == nil ? "Cancel" : "Close") { session.cancel() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 700)
        .onAppear {
            session.finished = { done($0 ? "signed-in" : nil) }
            session.start()
        }
    }
}

@MainActor
@Observable
final class XboxSignIn: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private(set) var page: WKWebView?
    private(set) var failure: String?
    @ObservationIgnored var finished: ((Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var active: Int?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var cancelled = false
    /// One cookie store for every page of this attempt, forgotten afterwards: the sign-in is Xodus' to keep.
    @ObservationIgnored private let store = WKWebsiteDataStore.nonPersistent()

    private static let prefix = "NEXUS_AUTH_V1 "
    private static let hosts: Set<String> = ["login.live.com", "account.live.com", "login.microsoftonline.com",
                                             "login.microsoft.com", "account.microsoft.com", "sisu.xboxlive.com"]
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; MSAppHost/3.0) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.26100"
    /// The headers Xodus may set on a page's first load.
    private static let headerNames: Set<String> = ["cxh-capabilities", "cxh-correlationid", "cxh-msabinaryversion",
                                                   "cxh-identityclientbinaryversion", "cxh-osversioninfo", "cxh-platform",
                                                   "cxh-protocol", "cxh-source", "hostapp"]
    /// window.external.notify, as the Windows web host provides it, passing the page's messages to Xodus.
    private static let bridge = """
        (() => {
          const notify = p => window.webkit.messageHandlers.xodus.postMessage(String(p));
          try {
            if (!window.external) window.external = {};
            Object.defineProperty(window.external, 'notify', { value: notify, configurable: true });
          } catch (e) { window.external = { notify }; }
        })();
        """

    static func trusted(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host else { return false }
        return hosts.contains(host)
    }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = ComponentManager.xodusCLIPath
        process.arguments = ["--external-webview-stdio", "login"]
        process.environment = ProcessInfo.processInfo.environment.merging(["XODUS_LOG": "off", "RUST_LOG": "off"]) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let lines = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in lines.append(handle.availableData) {
                Task { @MainActor in self?.received(line) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            stdout.fileHandleForReading.readabilityHandler = nil
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status) }
        }
        do {
            try process.run()
        } catch {
            failure = "Couldn't start Xodus: \(error.localizedDescription)"
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
    }

    func cancel() {
        if let active { write(["type": "closed", "session": active]) }
        cancelled = true
        if let process, process.isRunning { process.terminate() } else { finish(false) }
    }

    private func write(_ frame: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        try? input.write(contentsOf: data + Data("\n".utf8))
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        page = nil
        process?.terminate()
    }

    private func received(_ line: String) {
        guard line.hasPrefix(Self.prefix), !cancelled, failure == nil else { return }
        guard let frame = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(Self.prefix.count).utf8)) as? [String: Any],
              let type = frame["type"] as? String else { return fail("Xbox sign-in sent something OverPass doesn't understand.") }
        if type == "ready" {
            ready = true
            write(["type": "hello", "version": 1])
            return
        }
        guard ready, let id = frame["session"] as? Int, id > 0 else {
            return fail("Xbox sign-in sent something OverPass doesn't understand.")
        }
        switch type {
        case "open":
            guard let url = (frame["url"] as? String).flatMap(URL.init(string:)), Self.trusted(url) else {
                return fail("Xbox sign-in asked for a page that isn't Microsoft's.")
            }
            active = id
            open(url, headers: frame["headers"] as? [String: String] ?? [:])
        case "context" where id == active:
            guard let context = frame["context"] as? String, Self.trusted(page?.url) else { return }
            let message: [String: Any] = ["type": "callback", "value": [
                "name": "CloudExperienceHost.getContext",
                "args": ["CloudExperienceHost", "TokenBroker", "TokenBroker",
                         "{\"PrivatePropertyBag\":1,\"PasswordlessConnect\":1,\"PreferAssociate\":1,\"ChromelessUI\":0}"],
                "context": context] as [String: Any]]
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let json = String(data: data, encoding: .utf8),
                  let quoted = try? JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed) else { return }
            page?.evaluateJavaScript("globalThis[\"CloudExperienceHost.Bridge.dispatchMessage\"](\(String(decoding: quoted, as: UTF8.self)))")
        case "close" where id == active:
            active = nil
            page = nil
        default:
            break
        }
    }

    private func open(_ url: URL, headers: [String: String]) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakMessageHandler(self), name: "xodus")
        config.userContentController = content
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        var request = URLRequest(url: url)
        for (name, value) in headers where Self.headerNames.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        page = view
        view.load(request)
    }

    private func ended(_ status: Int32) {
        process = nil
        input = nil
        page = nil
        if cancelled || status == 0 { return finish(!cancelled && status == 0) }
        if failure == nil { failure = "The Xbox sign-in didn't finish. Try again." }
    }

    private func finish(_ signedIn: Bool) {
        let finished = self.finished
        self.finished = nil
        finished?(signedIn)
    }

    // The page's window.external.notify.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let active, message.frameInfo.isMainFrame, message.webView === page, Self.trusted(page?.url),
              let payload = message.body as? String, payload.utf8.count <= 65_536 else { return }
        write(["type": "ipc", "session": active, "payload": payload])
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame != false else { return .allow }
        if Self.trusted(action.request.url) { return .allow }
        fail("The sign-in tried to leave Microsoft's pages.")
        return .cancel
    }

    // At the end of the password step the page holds the sign-in result Xodus needs.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === page, let active, let url = webView.url, url.host == "login.live.com",
              url.path == "/ppsecure/post.srf" else { return }
        webView.evaluateJavaScript("JSON.stringify(globalThis.ServerData ?? null)") { [weak self] result, _ in
            guard let self, let payload = result as? String, payload != "null", payload.utf8.count <= 65_536,
                  self.active == active else { return }
            self.write(["type": "ipc", "session": active, "payload": payload])
        }
    }

    // No pop-ups: Microsoft's sign-in pages run in the one view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    /// Splits a pipe's output into lines on its handler thread.
    private final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = ""
        func append(_ data: Data) -> [String] {
            lock.withLock {
                partial += String(decoding: data, as: UTF8.self)
                var lines = partial.components(separatedBy: "\n")
                partial = lines.removeLast()
                return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            }
        }
    }
}

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the sign-in alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private struct XboxWebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
