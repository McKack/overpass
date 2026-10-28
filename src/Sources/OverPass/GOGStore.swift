import SwiftUI
import Foundation
import WebKit

// GOG without GOG Galaxy. gogdl (GPL-3, the downloader Heroic Games Launcher uses; a separate program OverPass
// downloads as a component) keeps the sign-in and downloads games, their updates and GOG's shared
// redistributables. OverPass lists the library from GOG's own web services, runs each game's install scripts and
// redistributables in the GOG bottle, and starts the games directly: GOG games need no client to run.
// Research notes: ~/Dev/OverPass-reference/stores/gog.md.

@MainActor
@Observable
final class GOGStore: StoreLibrary {
    static let shared = GOGStore()

    static let storeName = "GOG"
    static let component = ComponentID.gogdl
    static let about = "Play your GOG games without GOG Galaxy. OverPass downloads gogdl, an open-source GOG "
        + "downloader, to sign in and download games."
    static let userAgent: String? = nil

    /// The signed-in account's user name; nil when signed out.
    private(set) var account: String?
    private(set) var games: [LibraryGame] = []
    private(set) var refreshed: Date?
    private(set) var loading = false
    var error: String?
    private(set) var progress: [String: StoreProgress] = [:]
    private(set) var queue: [String] = []
    private var running: Process?
    private var cancelled: Set<String> = []

    nonisolated static let group = "gog"
    nonisolated static let launcherName = "GOG"
    static let clientName = "GOG Galaxy"

    nonisolated static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/Stores/GOG")
    }
    nonisolated static var authFile: URL { configDir.appendingPathComponent("auth.json") }
    /// gogdl's own data (one manifest per installed game), under GOGDL_CONFIG_PATH.
    nonisolated static var manifestsDir: URL { configDir.appendingPathComponent("heroic_gogdl/manifests") }
    /// GOG's shared redistributables (the install script interpreter, DirectX, Visual C++…), kept once for all games.
    nonisolated static var redistDir: URL { configDir.appendingPathComponent("redist") }

    init() {
        account = Self.storedAccount()
        if account != nil { (games, refreshed) = SavedLibrary.load(Self.configDir) }
    }

    // MARK: Account

    /// GOG's login page, as Galaxy opens it; it ends on embed.gog.com/on_login_success?code=….
    nonisolated static let clientID = "46899977096215655"
    nonisolated static let redirect = "https://embed.gog.com/on_login_success?origin=client"
    nonisolated static var loginURL: URL {
        var url = URLComponents(string: "https://auth.gog.com/auth")!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                          URLQueryItem(name: "redirect_uri", value: redirect),
                          URLQueryItem(name: "response_type", value: "code"),
                          URLQueryItem(name: "layout", value: "galaxy")]
        return url.url!
    }

    static func code(in webView: WKWebView, at url: URL) async -> String? {
        guard url.host == "embed.gog.com", url.path == "/on_login_success" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    nonisolated static func storedAccount() -> String? {
        guard FileManager.default.fileExists(atPath: authFile.path),
              let data = try? Data(contentsOf: configDir.appendingPathComponent("user.json")),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return user["username"] as? String
    }

    func signIn(code: String) async {
        error = nil
        do {
            let result = try await Self.run(["auth", "--code", code])
            guard let token = Self.token(from: result) else {
                error = Self.failure(result, or: "GOG didn't accept the sign-in. Try again.")
                return
            }
            // The account's name, for the toolbar; gogdl keeps only the tokens.
            var request = URLRequest(url: URL(string: "https://embed.gog.com/userData.json")!)
            request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["username"] as? String
            try JSONSerialization.data(withJSONObject: ["username": name ?? "GOG"])
                .write(to: Self.configDir.appendingPathComponent("user.json"))
            account = Self.storedAccount()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        let fm = FileManager.default
        for file in ["auth.json", "user.json", "library.json", "library-2.json"] {
            try? fm.removeItem(at: Self.configDir.appendingPathComponent(file))
        }
        account = nil
        games = []
        refreshed = nil
        SavedLibrary.remove(Self.configDir)
    }

    struct Token {
        let access: String
        let user: String
    }

    nonisolated private static func token(from result: StoreHelper.Result) -> Token? {
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              json["error"] as? Bool != true, let access = json["access_token"] as? String else { return nil }
        let user = json["user_id"].map { "\($0)" } ?? ""
        return Token(access: access, user: user)
    }

    /// A current access token; gogdl refreshes it first when it has expired.
    private func token() async throws -> Token {
        let result = try await Self.run(["auth"])
        guard let token = Self.token(from: result) else {
            account = nil
            throw StoreHelper.Failure.message("The GOG sign-in has expired. Sign in again.")
        }
        return token
    }

    // MARK: Library

    /// What OverPass knows about a product: from GOG's games database, kept in library.json so the library opens
    /// at once and only new purchases are looked up.
    private struct Product: Codable {
        let title: String
        let cover: String?
        let icon: String?
        let windows: Bool
        let isGame: Bool
    }

    /// The account's Windows games: the product IDs it owns from GOG's library service, then each product's
    /// title, cover and platforms from GOG's games database.
    func refresh() async {
        guard account != nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let token = try await token()
            var ids: [String] = []
            var pageToken: String?
            repeat {
                var url = URLComponents(string: "https://galaxy-library.gog.com/users/\(token.user)/releases")!
                if let pageToken { url.queryItems = [URLQueryItem(name: "page_token", value: pageToken)] }
                var request = URLRequest(url: url.url!)
                request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                for item in page["items"] as? [[String: Any]] ?? [] where item["platform_id"] as? String == "gog" {
                    if let id = item["external_id"].map({ "\($0)" }) { ids.append(id) }
                }
                pageToken = page["next_page_token"] as? String
            } while pageToken?.isEmpty == false

            // library-2.json: products with their square icons (library.json had covers only).
            let cacheFile = Self.configDir.appendingPathComponent("library-2.json")
            var products = (try? JSONDecoder().decode([String: Product].self, from: Data(contentsOf: cacheFile))) ?? [:]
            let missing = ids.filter { products[$0] == nil }
            await withTaskGroup(of: (String, Product?).self) { group in
                var next = missing.makeIterator()
                for _ in 0..<8 {
                    guard let id = next.next() else { break }
                    group.addTask { (id, await Self.product(id)) }
                }
                for await (id, product) in group {
                    if let product { products[id] = product }
                    if let id = next.next() { group.addTask { (id, await Self.product(id)) } }
                }
            }
            try? JSONEncoder().encode(products).write(to: cacheFile)
            games = Set(ids).compactMap { id in
                guard let p = products[id], p.windows, p.isGame else { return nil }
                return LibraryGame(id: id, service: "GOG", title: p.title, cover: p.cover.flatMap(URL.init(string:)),
                                   icon: p.icon.flatMap(URL.init(string:)))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            refreshed = .now
            SavedLibrary.save(games, to: Self.configDir)
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func product(_ id: String) async -> Product? {
        guard let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(id)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let game = release["game"] as? [String: Any] ?? [:]
        let title = (release["title"] as? [String: Any])?["*"] as? String
            ?? (game["title"] as? [String: Any])?["*"] as? String ?? id
        // The 2:3 cover.
        let cover = ((game["vertical_cover"] as? [String: Any])?["url_format"] as? String)?
            .replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg")
        let icon = ((game["square_icon"] as? [String: Any])?["url_format"] as? String)?
            .replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "png")
        let systems = (release["supported_operating_systems"] as? [[String: Any]] ?? []).compactMap { $0["slug"] as? String }
        let type = release["type"] as? String
        return Product(title: title, cover: cover, icon: icon, windows: systems.contains("windows"),
                       isGame: (type == nil || type == "game") && game["visible_in_library"] as? Bool != false)
    }

    struct Installed: Codable {
        let title: String
        let path: String
        var buildID: String?
        var version: String?
    }

    nonisolated private static var installedFile: URL { configDir.appendingPathComponent("installed.json") }

    /// The games OverPass installed through gogdl, by product ID.
    nonisolated static func installed() -> [String: Installed] {
        (try? JSONDecoder().decode([String: Installed].self, from: Data(contentsOf: installedFile))) ?? [:]
    }

    nonisolated private static func saveInstalled(_ all: [String: Installed]) {
        try? JSONEncoder().encode(all).write(to: installedFile)
    }

    func isInstalled(_ game: LibraryGame) -> Bool {
        _ = progress
        return Self.installed()[game.id] != nil
    }

    func item(_ game: LibraryGame, in manager: BottleManager) -> LibraryItem? {
        manager.library.first { $0.app.backend == .gogdl && $0.app.storeID == game.id }
    }

    // MARK: Install

    /// The bottle GOG games go into: GOG Galaxy's if it's installed, otherwise one made here with the GOG
    /// profile's runtimes, so either way they show under GOG in the sidebar.
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

    private static let language = "en-US"

    private func runInstall(_ id: String, using manager: BottleManager) async {
        error = nil
        do {
            let bottle = try await bottle(using: manager)
            let base = bottle.driveC.appendingPathComponent("GOG Games")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let filters = ["--platform", "windows", "--lang", Self.language, "--with-dlcs"]

            // The build to install, its folder name and size. Games without a Galaxy build have only offline
            // installers, which gogdl doesn't download.
            let info = try await Self.run(["info", id] + filters)
            guard let build = try? JSONSerialization.jsonObject(with: info.stdout) as? [String: Any],
                  let folder = build["folder_name"] as? String else {
                error = info.stderr.contains("doesn't support content system")
                    ? "\(title(id)) has no download for Galaxy. Install it with its offline installer from gog.com."
                    : Self.failure(info, or: "Couldn't get \(title(id)) from GOG.")
                return
            }
            let size = ((build["size"] as? [String: Any])?["*"] as? [String: Any])?["download_size"] as? Int
            progress[id]?.total = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }

            let support = Self.configDir.appendingPathComponent("support/\(id)")
            let result = try await Self.run(["download", id, "--path", base.path, "--support", support.path] + filters,
                                            started: { [weak self] in self?.running = $0 },
                                            stderrLine: { [weak self] in self?.parseProgress($0, for: id) })
            running = nil
            if cancelled.remove(id) != nil { return }
            let path = base.appendingPathComponent(folder)
            guard result.status == 0, FileManager.default.fileExists(atPath: path.path),
                  !FileManager.default.fileExists(atPath: path.appendingPathComponent(".gogdl-resume").path) else {
                error = Self.failure(result, or: "Couldn't install \(title(id)).")
                return
            }
            var all = Self.installed()
            all[id] = Installed(title: title(id), path: path.path, buildID: build["buildId"].map { "\($0)" },
                                version: build["versionName"] as? String)
            Self.saveInstalled(all)
            try await setUp(id, at: path, support: support, in: bottle, using: manager)
        } catch {
            running = nil
            self.error = error.localizedDescription
        }
    }

    /// What Galaxy does after a download: the game's install scripts (registry keys, its own setup steps) and the
    /// shared redistributables it lists, run silently in the bottle.
    private func setUp(_ id: String, at path: URL, support: URL, in bottle: Bottle, using manager: BottleManager) async throws {
        guard let data = try? Data(contentsOf: Self.manifestsDir.appendingPathComponent(id)),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let installed = Self.installed()[id]
        let version1 = manifest["version"] as? Int == 1
        let product = manifest["product"] as? [String: Any] ?? [:]
        let dependencies: [String] = version1
            ? (product["depots"] as? [[String: Any]] ?? []).compactMap { $0["redist"] as? String }
            : manifest["dependencies"] as? [String] ?? []

        progress[id]?.step = "Getting Windows components…"
        let ids = (["ISI"] + dependencies).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        _ = try await Self.run(["redist", "--ids", ids.joined(separator: ","), "--path", Self.redistDir.path])

        // GOG's installers take Windows paths and the product's language as a name ("English").
        let dir = LauncherGames.windowsPath(path, bottlePath: bottle.path)
        let supportDir = LauncherGames.windowsPath(support, bottlePath: bottle.path)
        var common = ["/VERYSILENT", "/DIR=\(dir)", "/Language=English", "/LANG=English", "/galaxyclient",
                      "/lang-code=\(Self.language)", "/nodesktopshortcut", "/nodesktopshorctut"]  // GOG's own typo too
        if let build = installed?.buildID { common.append("/buildId=\(build)") }
        if let version = installed?.version { common.append("/versionName=\(version)") }

        progress[id]?.step = "Setting up \(title(id))…"
        let products = manifest["products"] as? [[String: Any]] ?? []
        if version1 {
            for command in product["support_commands"] as? [[String: Any]] ?? [] {
                let languages = command["languages"] as? [String] ?? []
                guard languages.contains("Neutral") || languages.contains("English"),
                      let exe = command["executable"] as? String, let game = command["gameID"].map({ "\($0)" }) else { continue }
                let file = support.appendingPathComponent(game).appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/"))
                _ = try? await manager.run([file.path] + common + ["/ProductId=\(game)"], in: bottle)
            }
        } else if manifest["scriptInterpreter"] as? Bool == true {
            let isi = Self.redistDir.appendingPathComponent("__redist/ISI/scriptinterpreter.exe")
            for p in products {
                guard let product = p["productId"].map({ "\($0)" }) else { continue }
                _ = try? await manager.run([isi.path] + common + ["/ProductId=\(product)", "/supportDir=\(supportDir)"],
                                           in: bottle)
            }
        } else {
            for p in products {
                guard let product = p["productId"].map({ "\($0)" }),
                      let exe = p["temp_executable"] as? String, !exe.isEmpty else { continue }
                let file = support.appendingPathComponent(product).appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/"))
                _ = try? await manager.run([file.path] + common + ["/ProductId=\(product)"], in: bottle)
            }
        }

        // The shared redistributables, each with the silent arguments GOG's repository gives it.
        guard let repoData = try? Data(contentsOf: Self.redistDir.appendingPathComponent(".gogdl-redist-manifest")),
              let repo = try JSONSerialization.jsonObject(with: repoData) as? [String: Any] else { return }
        let depots = repo["depots"] as? [[String: Any]] ?? []
        for dependency in dependencies {
            guard let depot = depots.first(where: { $0["dependencyId"] as? String == dependency }),
                  let executable = depot["executable"] as? [String: Any],
                  let exe = executable["path"] as? String, !exe.isEmpty else { continue }
            progress[id]?.step = "Installing \(depot["readableName"] as? String ?? dependency)…"
            let file = Self.redistDir.appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/"))
            let args = (executable["arguments"] as? String ?? "").split(separator: " ").map(String.init)
            let command = dependency == "PHYSXLEGACY" ? ["msiexec", "/i", file.path] + args + ["/qb"] : [file.path] + args
            _ = try? await manager.run(command, in: bottle)
        }
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

    /// Deletes the game's folder and what OverPass and gogdl kept about it, and the registry keys its install
    /// script wrote. Saved games in the bottle's user folders stay.
    func uninstall(_ id: String, using manager: BottleManager) async {
        var all = Self.installed()
        guard let game = all.removeValue(forKey: id) else { return }
        let path = URL(fileURLWithPath: game.path)
        if let bottle = manager.bottles.first(where: { path.path.hasPrefix($0.path.standardizedFileURL.path + "/") }) {
            for key in ["HKLM\\Software\\GOG.com\\Games\\\(id)", "HKLM\\Software\\Wow6432Node\\GOG.com\\Games\\\(id)"] {
                _ = try? await manager.run(["reg", "delete", key, "/f"], in: bottle)
            }
        }
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: Self.manifestsDir.appendingPathComponent(id))
        try? FileManager.default.removeItem(at: Self.configDir.appendingPathComponent("support/\(id)"))
        Self.saveInstalled(all)
        progress = progress  // isInstalled reads the file; this redraws the library
        manager.loadBottles()
    }

    private func title(_ id: String) -> String { games.first { $0.id == id }?.title ?? Self.installed()[id]?.title ?? id }

    // [PROGRESS] INFO: = Progress: 12.34 123456/1000000, Running for: 00:01:02, ETA: 00:07:40
    // [PROGRESS] INFO: = Downloaded: 512.00 MiB, Written: 600.00 MiB
    private func parseProgress(_ line: String, for id: String) {
        guard progress[id] != nil else { return }
        if let range = line.range(of: "= Progress: ") {
            let rest = line[range.upperBound...]
            progress[id]?.percent = Double(rest.prefix { $0 != " " }) ?? progress[id]!.percent
            if let eta = rest.range(of: "ETA: ") { progress[id]?.eta = String(rest[eta.upperBound...]).trimmingCharacters(in: .whitespaces) }
        } else if let range = line.range(of: "= Downloaded: ") {
            progress[id]?.downloaded = String(line[range.upperBound...].prefix { $0 != "," })
        }
    }

    // MARK: Launch

    /// A game's main program from goggame-<id>.info, which every GOG game carries: the primary play task's
    /// program and arguments, relative to the game folder.
    nonisolated static func playTask(_ id: String, in folder: URL) -> (exe: URL, arguments: [String])? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("goggame-\(id).info")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = info["playTasks"] as? [[String: Any]],
              let task = tasks.first(where: { $0["isPrimary"] as? Bool == true }) ?? tasks.first,
              let path = task["path"] as? String,
              let exe = WindowsIcons.caseInsensitive(folder, path.replacingOccurrences(of: "\\", with: "/")) else { return nil }
        let arguments = (task["arguments"] as? String ?? "").split(separator: " ").map(String.init)
        return (exe, arguments)
    }

    // MARK: Running gogdl

    nonisolated static var gogdl: URL { ComponentManager.gogdlPath }

    nonisolated static func failure(_ result: StoreHelper.Result, or fallback: String) -> String {
        StoreHelper.failure(result, or: fallback)
    }

    nonisolated static func run(_ args: [String], started: (@MainActor (Process) -> Void)? = nil,
                                stderrLine: (@MainActor (String) -> Void)? = nil) async throws -> StoreHelper.Result {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return try await StoreHelper.run(gogdl, name: "GOG Library", ["--auth-config-path", authFile.path] + args,
                                         environment: ["GOGDL_CONFIG_PATH": configDir.path],
                                         started: started, stderrLine: stderrLine)
    }
}
