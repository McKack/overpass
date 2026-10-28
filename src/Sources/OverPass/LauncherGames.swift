import Foundation

// Games installed through a store launcher often get no Start-menu .lnk (Steam and Epic make .url files, if
// anything), so read each launcher's own records of what it installed. Steam and Epic games launch through
// their client, which handles DRM, updates and cloud saves; GOG games run directly.
enum LauncherGames {
    static func scan(bottlePath: URL) -> [WineApp] {
        steam(bottlePath) + epic(bottlePath) + epicLibrary(bottlePath) + gogLibrary(bottlePath, registered: gog(bottlePath))
            + xboxLibrary(bottlePath)
    }

    // MARK: Steam

    // Steamworks Common Redistributables: installed alongside games, not playable.
    private static let steamTools: Set<String> = ["228980"]

    /// steamapps/libraryfolders.vdf lists every library; each has an appmanifest_<id>.acf per installed app.
    private static func steam(_ bottlePath: URL) -> [WineApp] {
        guard let root = WindowsIcons.hostPath("C:\\Program Files (x86)\\Steam", bottlePath: bottlePath),
              let client = WindowsIcons.caseInsensitive(root, "steam.exe") else { return [] }
        var games: [WineApp] = []
        for library in steamLibraries(root, bottlePath) {
            guard let steamapps = WindowsIcons.caseInsensitive(library, "steamapps"),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = read(steamapps.appendingPathComponent(file)),
                      let app = VDF.parse(text)["AppState"] as? [String: Any],
                      let id = app["appid"] as? String, !steamTools.contains(id),
                      let name = app["name"] as? String,
                      // StateFlags bit 4 is "fully installed"; anything mid-download is left out.
                      let flags = (app["StateFlags"] as? String).flatMap(Int.init), flags & 4 != 0 else { continue }
                let installDir = (app["installdir"] as? String).flatMap {
                    WindowsIcons.caseInsensitive(steamapps, "common/\($0)")
                }
                let icon = installDir.flatMap(mainExecutable) ?? steamCachedIcon(root, id)
                games.append(WineApp(name: name, executable: client.path, arguments: ["-silent", "steam://rungameid/\(id)"],
                                     icon: icon?.path, launcher: "Steam", storeID: id,
                                     target: installDir.flatMap(mainExecutable).map { windowsPath($0, bottlePath: bottlePath) }))
            }
        }
        return games
    }

    private static func steamLibraries(_ root: URL, _ bottlePath: URL) -> [URL] {
        var libraries = [root]
        if let text = read(root.appendingPathComponent("steamapps/libraryfolders.vdf")),
           let folders = VDF.parse(text)["libraryfolders"] as? [String: Any] {
            for case let folder as [String: Any] in folders.values {
                guard let path = folder["path"] as? String,
                      let host = WindowsIcons.hostPath(path, bottlePath: bottlePath),
                      !libraries.contains(where: { $0.standardizedFileURL == host.standardizedFileURL }) else { continue }
                libraries.append(host)
            }
        }
        return libraries
    }

    /// The small icon Steam caches per game: librarycache/<id>/<sha1>.jpg on current clients, <id>_icon.jpg before.
    private static func steamCachedIcon(_ root: URL, _ id: String) -> URL? {
        let cache = root.appendingPathComponent("appcache/librarycache")
        let legacy = cache.appendingPathComponent("\(id)_icon.jpg")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        let dir = cache.appendingPathComponent(id)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.first { $0.hasSuffix(".jpg") && $0.count == 44 && $0.dropLast(4).allSatisfy(\.isHexDigit) }
            .map { dir.appendingPathComponent($0) }
    }

    private static let helperNames = ["unins", "crash", "redist", "setup", "prereq", "dxwebsetup", "easyanticheat",
                                      "battleye", "be_service", "cefprocess", "helper", "report"]

    /// Best guess at a game's own executable, for its icon: the largest .exe at the top of the install
    /// directory (Unreal puts a small stub there that carries the icon), else one folder down.
    private static func mainExecutable(in dir: URL) -> URL? {
        let fm = FileManager.default
        func exes(_ d: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasSuffix(".exe") && !helperNames.contains { name.contains($0) }
            }
        }
        func largest(_ urls: [URL]) -> URL? {
            urls.max { a, b in
                ((try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    < ((try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        if let top = largest(exes(dir)) { return top }
        let subdirs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
        return largest(subdirs.flatMap(exes))
    }

    // MARK: Epic Games

    /// One JSON .item per installed app in ProgramData/Epic/EpicGamesLauncher/Data/Manifests.
    private static func epic(_ bottlePath: URL) -> [WineApp] {
        guard let manifests = WindowsIcons.hostPath("C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests", bottlePath: bottlePath),
              let files = try? FileManager.default.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil) else { return [] }
        let client = ["Win64", "Win32"].lazy.compactMap {
            WindowsIcons.hostPath("C:\\Program Files (x86)\\Epic Games\\Launcher\\Portal\\Binaries\\\($0)\\EpicGamesLauncher.exe",
                                  bottlePath: bottlePath)
        }.first

        var games: [WineApp] = []
        for file in files where file.pathExtension.lowercased() == "item" {
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = item["DisplayName"] as? String,
                  let location = item["InstallLocation"] as? String,
                  item["bIsIncompleteInstall"] as? Bool != true else { continue }
            // Engines and plugins have manifests too; only "games" are playable.
            if let categories = item["AppCategories"] as? [String], !categories.contains("games") { continue }
            let exe = (item["LaunchExecutable"] as? String).flatMap {
                WindowsIcons.hostPath(location + "\\" + $0, bottlePath: bottlePath)
            }
            if let client, let ns = item["CatalogNamespace"] as? String, let catalog = item["CatalogItemId"] as? String,
               let appName = item["AppName"] as? String {
                // The URL the launcher registers for itself; it starts the game once the launcher is signed in.
                let url = "com.epicgames.launcher://apps/\(ns)%3A\(catalog)%3A\(appName)?action=launch&silent=true"
                games.append(WineApp(name: name, executable: client.path, arguments: [url], icon: exe?.path, launcher: "Epic Games"))
            } else if let exe {
                games.append(WineApp(name: name, executable: exe.path, launcher: "Epic Games"))
            }
        }
        return games
    }

    /// Games OverPass installed itself through Legendary (EpicStore) into this bottle. They start through
    /// Legendary, which fetches Epic's launch token, so they don't need the Epic Games Launcher.
    private static func epicLibrary(_ bottlePath: URL) -> [WineApp] {
        let root = bottlePath.standardizedFileURL.path + "/"
        return EpicStore.installed().compactMap { game in
            guard game.path.standardizedFileURL.path.hasPrefix(root) else { return nil }
            let exe = game.path.appendingPathComponent(game.executable.replacingOccurrences(of: "\\", with: "/"))
            return WineApp(name: game.title, executable: exe.path, launcher: EpicStore.launcherName,
                           storeID: game.appName, target: windowsPath(exe, bottlePath: bottlePath), backend: .legendary)
        }
    }

    /// Games OverPass installed through Xodus (XboxStore) into this bottle. They start through Xodus.
    private static func xboxLibrary(_ bottlePath: URL) -> [WineApp] {
        let root = bottlePath.standardizedFileURL.path + "/"
        return XboxStore.installed().compactMap { id, game in
            guard game.path.hasPrefix(root) else { return nil }
            let exe = URL(fileURLWithPath: game.path).appendingPathComponent(game.executable.replacingOccurrences(of: "\\", with: "/"))
            return WineApp(name: game.title, executable: exe.path, launcher: XboxStore.launcherName, storeID: id,
                           target: windowsPath(exe, bottlePath: bottlePath), backend: .xodus)
        }
    }

    // MARK: GOG

    /// GOG games, with those OverPass installed itself through gogdl (GOGStore) marked as such. Their install
    /// script registers most of them like any GOG game; the rest come from the game's own goggame-<id>.info.
    private static func gogLibrary(_ bottlePath: URL, registered: [WineApp]) -> [WineApp] {
        let root = bottlePath.standardizedFileURL.path + "/"
        let ours = GOGStore.installed().filter { $0.value.path.hasPrefix(root) }
        var games = registered.map { app in
            var app = app
            if let id = app.storeID, ours[id] != nil { app.backend = .gogdl }
            return app
        }
        for (id, game) in ours where !registered.contains(where: { $0.storeID == id }) {
            guard let task = GOGStore.playTask(id, in: URL(fileURLWithPath: game.path)) else { continue }
            games.append(WineApp(name: game.title, executable: task.exe.path, arguments: task.arguments,
                                 launcher: GOGStore.launcherName, storeID: id,
                                 target: windowsPath(task.exe, bottlePath: bottlePath), backend: .gogdl))
        }
        return games
    }

    /// GOG installers (with or without Galaxy) register each game under HKLM\Software\GOG.com\Games\<id>.
    private static func gog(_ bottlePath: URL) -> [WineApp] {
        guard let text = read(bottlePath.appendingPathComponent("system.reg")) else { return [] }
        let prefixes = ["[software\\\\wow6432node\\\\gog.com\\\\games\\\\", "[software\\\\gog.com\\\\games\\\\"]
        var games: [WineApp] = []
        var current: [String: String]?
        var currentID: String?
        func finish() {
            guard let values = current, let name = values["gamename"], let exePath = values["exe"],
                  (values["dependson"] ?? "").isEmpty,  // DLC depend on their base game
                  let exe = WindowsIcons.hostPath(exePath, bottlePath: bottlePath) else { return }
            // launchParam is a raw command-line tail; it's nearly always empty or a few plain flags.
            let args = (values["launchparam"] ?? "").split(separator: " ").map(String.init)
            games.append(WineApp(name: name, executable: exe.path, arguments: args, launcher: "GOG",
                                 storeID: currentID, target: exePath))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("[") {
                finish()
                let lower = line.lowercased()
                let prefix = prefixes.first(where: lower.hasPrefix)
                current = prefix != nil ? [:] : nil
                currentID = prefix.map { String(lower.dropFirst($0.count).prefix { $0.isNumber }) }
            } else if current != nil, let (key, value) = regValue(line) {
                current?[key.lowercased()] = value
            }
        }
        finish()
        return games
    }

    /// Windows path of a host file in the bottle: C: for drive_c, Z: (the host root) for anything else.
    static func windowsPath(_ url: URL, bottlePath: URL) -> String {
        let path = url.standardizedFileURL.path
        let driveC = bottlePath.appendingPathComponent("drive_c").standardizedFileURL.path
        if path.hasPrefix(driveC + "/") {
            return "C:" + path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: Store IDs

    struct StoreGame: Hashable {
        enum Store { case steam, gog }
        let store: Store
        let id: String
        let name: String
    }

    /// Every game a client has started installing in the bottle, finished or not, by store ID. A client can stop
    /// partway, at its own copy of a runtime the game needs, before the game is in the library.
    static func storeGames(bottlePath: URL) -> [StoreGame] {
        var found: [StoreGame] = []
        if let root = WindowsIcons.hostPath("C:\\Program Files (x86)\\Steam", bottlePath: bottlePath) {
            for library in steamLibraries(root, bottlePath) {
                guard let steamapps = WindowsIcons.caseInsensitive(library, "steamapps"),
                      let files = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path) else { continue }
                for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                    guard let text = read(steamapps.appendingPathComponent(file)),
                          let app = VDF.parse(text)["AppState"] as? [String: Any],
                          let id = app["appid"] as? String else { continue }
                    found.append(StoreGame(store: .steam, id: id, name: app["name"] as? String ?? id))
                }
            }
        }
        // GOG: registered games, and Galaxy's game folders, which hold goggame-<id>.info from the download on.
        if let text = read(bottlePath.appendingPathComponent("system.reg")) {
            for line in text.split(separator: "\n") {
                let lower = line.lowercased()
                for prefix in ["[software\\\\wow6432node\\\\gog.com\\\\games\\\\", "[software\\\\gog.com\\\\games\\\\"]
                where lower.hasPrefix(prefix) {
                    let id = lower.dropFirst(prefix.count).prefix { $0.isNumber }
                    if !id.isEmpty { found.append(StoreGame(store: .gog, id: String(id), name: String(id))) }
                }
            }
        }
        if let games = WindowsIcons.hostPath("C:\\Program Files (x86)\\GOG Galaxy\\Games", bottlePath: bottlePath),
           let folders = try? FileManager.default.contentsOfDirectory(at: games, includingPropertiesForKeys: nil) {
            for folder in folders {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for file in files where file.lowercased().hasPrefix("goggame-") && file.lowercased().hasSuffix(".info") {
                    let id = String(file.dropFirst("goggame-".count).dropLast(".info".count))
                    found.append(StoreGame(store: .gog, id: id, name: folder.lastPathComponent))
                }
            }
        }
        return Array(Set(found))
    }

    /// `"name"="string"` from a Wine .reg file; other value types are skipped.
    static func regValue(_ line: Substring) -> (String, String)? {
        guard line.hasPrefix("\""), let sep = line.range(of: "\"=\"") , line.hasSuffix("\"") else { return nil }
        let key = line[line.index(after: line.startIndex)..<sep.lowerBound]
        let value = line[sep.upperBound..<line.index(before: line.endIndex)]
        return (unescape(key), unescape(value))
    }

    static func unescape(_ s: Substring) -> String {
        var out = ""
        var escaped = false
        for c in s {
            if escaped { out.append(c == "n" ? "\n" : c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }
}

/// Valve KeyValues text (.vdf/.acf): `"key" "value"` pairs and `"key" { … }` blocks, into nested dictionaries.
enum VDF {
    static func parse(_ text: String) -> [String: Any] {
        var tokens = tokenize(text)[...]
        return block(&tokens)
    }

    private enum Token: Equatable { case string(String), open, close }

    private static func block(_ tokens: inout ArraySlice<Token>) -> [String: Any] {
        var dict: [String: Any] = [:]
        while let token = tokens.popFirst() {
            guard case .string(let key) = token else { return dict }  // `}` ends this block
            switch tokens.popFirst() {
            case .string(let value): dict[key] = value
            case .open: dict[key] = block(&tokens)
            default: return dict
            }
        }
        return dict
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var chars = text[...]
        while let c = chars.popFirst() {
            switch c {
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "/" where chars.first == "/":
                chars = chars.drop { $0 != "\n" }
            case "\"":
                var s = ""
                while let c = chars.popFirst(), c != "\"" {
                    if c == "\\", let next = chars.popFirst() { s.append(next == "n" ? "\n" : next) } else { s.append(c) }
                }
                tokens.append(.string(s))
            default: break
            }
        }
        return tokens
    }
}
