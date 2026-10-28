import SwiftUI
import Foundation
import WebKit

// The Epic Games Store without the Epic Games Launcher. Legendary (GPL-3, a separate program OverPass downloads
// as a component, see ComponentManager) signs in, lists the account's games, downloads and updates them;
// OverPass shows them and runs them in the Epic bottle with its own Wine, passing the one-time launch token
// Legendary fetches before each start. Legendary prints JSON on stdout and its log on stderr.
// Research notes: ~/Dev/OverPass-reference/stores/epic.md.

@MainActor
@Observable
final class EpicStore: StoreLibrary {
    static let shared = EpicStore()

    static let storeName = launcherName
    static let component = ComponentID.legendary
    static let about = "Play your Epic games without the Epic Games Launcher. OverPass downloads Legendary, an "
        + "open-source Epic client, to sign in and download games."

    /// The signed-in account's display name; nil when signed out.
    private(set) var account: String?
    private(set) var games: [LibraryGame] = []
    private(set) var refreshed: Date?
    private(set) var loading = false
    var error: String?
    /// Installs: the one running has progress, the rest wait their turn (Legendary takes one at a time).
    private(set) var progress: [String: StoreProgress] = [:]
    private(set) var queue: [String] = []
    private var running: Process?
    private var cancelled: Set<String> = []

    nonisolated static let group = "epic-games"
    nonisolated static let launcherName = "Epic Games"
    static let clientName = "Epic Games Launcher"

    nonisolated static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/Stores/Epic")
    }

    nonisolated static var legendary: URL { ComponentManager.legendaryPath }

    init() {
        account = Self.storedAccount()
        if account != nil { (games, refreshed) = SavedLibrary.load(Self.configDir) }
    }

    // MARK: Account

    nonisolated static let clientID = "34a02cf8f4414e29b15921876da36f9a"
    static let userAgent: String? = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) EpicGamesLauncher"

    /// Epic's login page as the Epic Games Launcher opens it (as Heroic does): with the launcher's user agent it
    /// ends on localhost?code=…. With a redirectUrl added (Legendary's browser login) Epic now answers
    /// "Redirect URL is not known to the client" for that user agent.
    nonisolated static let loginURL = URL(string: "https://www.epicgames.com/id/login?responseType=code")!

    /// The code from localhost?code=…, or from the JSON page Legendary's browser login ends on.
    static func code(in webView: WKWebView, at url: URL) async -> String? {
        if url.host == "localhost" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
        }
        guard url.path.hasSuffix("/id/api/redirect"),
              let text = try? await webView.evaluateJavaScript("document.body.innerText") as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return json["authorizationCode"] as? String
    }

    /// Legendary keeps the OAuth session in user.json; its display name is all OverPass reads from it.
    nonisolated static func storedAccount() -> String? {
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("user.json")),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return user["displayName"] as? String
    }

    func signIn(code: String) async {
        error = nil
        do {
            let result = try await Self.run(["auth", "--code", code])
            account = Self.storedAccount()
            if account == nil { error = Self.failure(result, or: "Epic didn't accept the sign-in. Try again.") }
            else { await refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        _ = try? await Self.run(["auth", "--delete"])
        account = Self.storedAccount()
        games = []
        refreshed = nil
        SavedLibrary.remove(Self.configDir)
    }

    // MARK: Library

    /// The account's Windows games, with art from Epic's catalog. Installed ones come from installed.json.
    func refresh() async {
        guard account != nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await Self.run(["list", "--json", "--platform", "Windows"])
            guard let list = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else {
                error = Self.failure(result, or: "Couldn't read the Epic library.")
                return
            }
            games = list.compactMap(Self.game).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            refreshed = .now
            SavedLibrary.save(games, to: Self.configDir)
            account = Self.storedAccount()
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func game(_ entry: [String: Any]) -> LibraryGame? {
        guard let id = entry["app_name"] as? String, let title = entry["app_title"] as? String else { return nil }
        let metadata = entry["metadata"] as? [String: Any] ?? [:]
        // Fab and Unreal Engine marketplace items (assets, plugins, sample projects) and engine editors and dev kits
        // come with the account but aren't games.
        let categories = (metadata["categories"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        if metadata["namespace"] as? String == "ue"
            || categories.contains(where: { $0 == "engines" || ["asset-format", "plugins", "projects"].contains($0.split(separator: "/").first.map(String.init)) }) {
            return nil
        }
        let attributes = metadata["customAttributes"] as? [String: Any]
        // Another store's launcher runs it ("Origin", "Uplay"); OverPass can't start those yet.
        let thirdParty = (attributes?["ThirdPartyManagedApp"] as? [String: Any])?["value"] as? String
        let cover = cover(in: metadata).flatMap { URL(string: $0.absoluteString + "?h=480&resize=1&w=320") }
        let icon = image(in: metadata, types: ["Thumbnail", "DieselGameBoxLogo"])
            .flatMap { URL(string: $0.absoluteString + "?h=256&resize=1&w=256") }
        return LibraryGame(id: id, service: "Epic", title: title, cover: cover, icon: icon,
                           unavailable: thirdParty.map { "Needs the \($0) launcher" })
    }

    /// The 2:3 box art from a catalog item's keyImages.
    nonisolated static func cover(in metadata: [String: Any]) -> URL? {
        image(in: metadata, types: ["DieselGameBoxTall", "OfferImageTall", "DieselStoreFrontTall"])
    }

    /// The first of these keyImages types the catalog item has.
    nonisolated static func image(in metadata: [String: Any], types: [String]) -> URL? {
        let images = metadata["keyImages"] as? [[String: Any]] ?? []
        for type in types {
            if let url = images.first(where: { $0["type"] as? String == type })?["url"] as? String {
                return URL(string: url)
            }
        }
        return nil
    }

    /// Legendary caches each game's catalog item; covers for installed games come from there, offline too.
    nonisolated static func cachedCover(_ appName: String) -> URL? {
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("metadata/\(appName).json")),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return cover(in: entry["metadata"] as? [String: Any] ?? [:])
    }

    struct Installed {
        let appName: String
        let title: String
        let path: URL
        let executable: String
        let prerequisite: (path: String, arguments: String)?
    }

    /// What Legendary has installed, from its installed.json (`list-installed --json` without starting it).
    nonisolated static func installed() -> [Installed] {
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("installed.json")),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return all.compactMap { name, game in
            guard let path = game["install_path"] as? String, let exe = game["executable"] as? String,
                  game["is_dlc"] as? Bool != true else { return nil }
            let prereq = (game["prereq_info"] as? [String: Any]).flatMap { info -> (String, String)? in
                guard let path = info["path"] as? String, !path.isEmpty else { return nil }
                return (path, info["args"] as? String ?? "")
            }
            return Installed(appName: name, title: game["title"] as? String ?? name,
                             path: URL(fileURLWithPath: path), executable: exe, prerequisite: prereq)
        }
    }

    func isInstalled(_ game: LibraryGame) -> Bool {
        _ = progress
        return Self.installed().contains { $0.appName == game.id }
    }

    func item(_ game: LibraryGame, in manager: BottleManager) -> LibraryItem? {
        manager.library.first { $0.app.backend == .legendary && $0.app.storeID == game.id }
    }

    // MARK: Install

    /// The bottle Epic games go into: the Epic Games Launcher's if it's installed, otherwise one made here with
    /// the launcher profile's runtimes, so either way they show under Epic Games in the sidebar.
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
            let bottle = try await bottle(using: manager)
            let base = bottle.driveC.appendingPathComponent("Program Files/Epic Games")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // --skip-sdl: the optional-content prompt otherwise reads a terminal that isn't there.
            let result = try await Self.run(["install", id, "--platform", "Windows", "--base-path", base.path,
                                             "-y", "--skip-sdl"],
                                            started: { [weak self] in self?.running = $0 },
                                            stderrLine: { [weak self] in self?.parseProgress($0, for: id) })
            running = nil
            if cancelled.remove(id) != nil { return }
            guard let game = Self.installed().first(where: { $0.appName == id }) else {
                error = Self.failure(result, or: "Couldn't install \(title(id)).")
                return
            }
            // A game's own redistributables (Visual C++ and the like), as the Epic launcher runs them once.
            if let prereq = game.prerequisite {
                let exe = game.path.appendingPathComponent(prereq.path.replacingOccurrences(of: "\\", with: "/"))
                let args = prereq.arguments.split(separator: " ").map(String.init)
                _ = try? await manager.run([exe.path] + args, in: bottle)
            }
        } catch {
            running = nil
            self.error = error.localizedDescription
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

    func uninstall(_ appName: String, using manager: BottleManager) async {
        // --skip-uninstaller: the game's own Windows uninstaller would run outside Wine.
        _ = try? await Self.run(["uninstall", appName, "-y", "--skip-uninstaller"])
        manager.loadBottles()
    }

    private func title(_ id: String) -> String { games.first { $0.id == id }?.title ?? id }

    // [DLManager] INFO: = Progress: 12.34% (123/1000), Running for 00:01:02, ETA: 00:07:40
    // [DLManager] INFO:  - Downloaded: 512.00 MiB, Written: 600.00 MiB
    // [cli] INFO: Download size: 2048.00 MiB (Compression savings: 10.0%)
    private func parseProgress(_ line: String, for id: String) {
        guard progress[id] != nil else { return }
        if let range = line.range(of: "Progress: ") {
            let rest = line[range.upperBound...]
            progress[id]?.percent = Double(rest.prefix { $0 != "%" }) ?? progress[id]!.percent
            if let eta = rest.range(of: "ETA: ") { progress[id]?.eta = String(rest[eta.upperBound...]).trimmingCharacters(in: .whitespaces) }
        } else if let range = line.range(of: "- Downloaded: ") {
            progress[id]?.downloaded = String(line[range.upperBound...].prefix { $0 != "," })
        } else if let range = line.range(of: "Download size: ") {
            progress[id]?.total = String(line[range.upperBound...].prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Launch

    /// The program, arguments and environment for one start: Legendary asks Epic for a fresh one-time
    /// exchange code each time (`launch --json --no-wine` prints them without running anything).
    nonisolated static func launchParameters(_ appName: String) async throws -> (exe: String, arguments: [String], environment: [String: String]) {
        let result = try await run(["launch", appName, "--json", "--no-wine", "--skip-version-check"])
        guard let p = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              var exe = p["game_executable"] as? String else {
            throw StoreHelper.Failure.message(failure(result, or: "Epic couldn't prepare the game to start."))
        }
        if !exe.hasPrefix("/"), let dir = p["game_directory"] as? String {
            exe = URL(fileURLWithPath: dir).appendingPathComponent(exe).path
        }
        let strings = { (key: String) in p[key] as? [String] ?? [] }
        // The ownership token is a file Legendary writes; the game reads it through Wine's view of the Mac.
        let egl = strings("egl_parameters").map { arg in
            arg.hasPrefix("-epicovt=/") ? "-epicovt=Z:" + arg.dropFirst("-epicovt=".count).replacingOccurrences(of: "/", with: "\\") : arg
        }
        let environment = p["environment"] as? [String: String] ?? [:]
        return (exe, strings("game_parameters") + strings("user_parameters") + egl, environment)
    }

    // MARK: Running Legendary

    nonisolated static func failure(_ result: StoreHelper.Result, or fallback: String) -> String {
        StoreHelper.failure(result, or: fallback)
    }

    nonisolated static func run(_ args: [String], started: (@MainActor (Process) -> Void)? = nil,
                                stderrLine: (@MainActor (String) -> Void)? = nil) async throws -> StoreHelper.Result {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return try await StoreHelper.run(legendary, name: "Epic Games Library", args,
                                         environment: ["LEGENDARY_CONFIG_PATH": configDir.path],
                                         started: started, stderrLine: stderrLine)
    }
}
