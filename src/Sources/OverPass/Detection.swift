import Foundation

// What a game is made with, told from its file names: engine, middleware, anti-cheat and launcher. The rules are
// SteamDB's FileDetectionRuleSets (Detection/rules.ini, MIT) with our own additions (Detection/overpass.ini). A folder
// is scanned once, in the background, and again when it changes. Detected games get a generated rule file of presets,
// so a game with no profile still gets what its engine needs; a game with a profile or a preset of its own is left alone.
enum Detection {
    struct Result: Codable, Equatable {
        var engines: [String] = []
        var sdks: [String] = []
        var antiCheats: [String] = []
        var launchers: [String] = []
        /// Rule names as in the rule files, "Engine.Unity".
        var matches: [String] { engines.map { "Engine." + $0 } + sdks.map { "SDK." + $0 } }
    }

    /// A rule for one detected game, kept so the rule file can be written without scanning.
    struct Game: Codable, Equatable {
        var name: String
        var matches: [String]
        var presets: [String]
    }

    private struct Scan: Codable {
        var modified: Double
        var result: Result
    }

    private struct Store: Codable {
        var scans: [String: Scan] = [:]
        var games: [Game] = []
    }

    /// Past this a folder isn't one game (a client's folder, a whole disk): what was seen so far counts.
    private static let fileLimit = 300_000
    private static let storeURL = UserProfiles.support.appendingPathComponent("Detection.json")
    // Read and changed on the main thread.
    nonisolated(unsafe) private static var store = (try? Data(contentsOf: storeURL))
        .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()

    // MARK: Rules

    private struct RuleSet {
        /// Every rule at once: most files match none, so only the rest are tried one by one.
        var any: NSRegularExpression
        var rules: [(name: String, regex: NSRegularExpression)]
        var presets: [String: [String]]
    }

    private static func parse(_ text: String) -> (rules: [(String, String)], presets: [String: [String]]) {
        var rules: [(String, String)] = [], presets: [String: [String]] = [:], section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = (raw.components(separatedBy: " ; ").first ?? "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.range(of: " = ") else { continue }
            let key = line[..<eq.lowerBound].replacingOccurrences(of: "[]", with: "")
            let value = String(line[eq.upperBound...])
            if section == "Presets" {
                presets[key, default: []].append(value)
            } else {
                rules.append(("\(section).\(key)", value))
            }
        }
        return (rules, presets)
    }

    private static let ruleSet: RuleSet? = {
        var parsed: [(String, String)] = [], presets: [String: [String]] = [:]
        for name in ["rules", "overpass"] {
            guard let url = ProfileStore.resourceBundle.url(forResource: name, withExtension: "ini", subdirectory: "Detection"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let file = parse(text)
            parsed += file.rules
            presets.merge(file.presets) { $0 + $1 }
        }
        return ruleSet(parsed, presets: presets)
    }()

    private static func ruleSet(_ parsed: [(String, String)], presets: [String: [String]]) -> RuleSet? {
        let rules = parsed.compactMap { name, pattern in
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { (name: name, regex: $0) }
        }
        let joined = parsed.map(\.1).map { "(?:\($0))" }.joined(separator: "|")
        guard let any = try? NSRegularExpression(pattern: joined, options: .caseInsensitive) else { return nil }
        return RuleSet(any: any, rules: rules, presets: presets)
    }

    private static func matches(_ regex: NSRegularExpression, _ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    // MARK: Scanning

    /// The game's top folder, above the bin folders its program may sit in. Nil for folders that hold more than one
    /// game or aren't a game's: a container's own folders, a store client's.
    static func root(of folder: URL) -> URL? {
        let parts = folder.standardizedFileURL.pathComponents
        if let common = parts.lastIndex(where: { $0.lowercased() == "common" }), common > 0, common + 1 < parts.count,
           parts[common - 1].lowercased() == "steamapps" {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...(common + 1)])))
        }
        // The first bin folder inside the container, as builds can sit deeper (bin/win32_galaxy_release).
        let binFolders: Set<String> = ["win64", "win32", "x64", "x86", "bin", "bin64", "bin32", "binaries"]
        let inside = (parts.lastIndex { $0.lowercased() == "drive_c" } ?? 0) + 1
        let bin = parts.indices.first { $0 >= inside && binFolders.contains(parts[$0].lowercased()) }
        var root = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<(bin ?? parts.count)])))
        // Unreal: <game>/<project>/Binaries/Win64/<project>-Win64-Shipping.exe, with Engine beside <project>.
        if root != folder.standardizedFileURL,
           FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("Engine").path) {
            root.deleteLastPathComponent()
        }
        let notAGame: Set<String> = ["drive_c", "program files", "program files (x86)", "users", "games", "gog games", "epic games"]
        guard !notAGame.contains(root.lastPathComponent.lowercased()),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) else { return nil }
        return root
    }

    /// Paths inside a folder, relative to it, as the rules expect.
    static func files(in root: URL) -> [String] {
        let start = root.standardizedFileURL.path.count + 1
        var paths: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let url = walker?.nextObject() as? URL, paths.count < fileLimit {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            let path = url.standardizedFileURL.path
            if path.count > start { paths.append(String(path.dropFirst(start))) }
        }
        return paths
    }

    static func scan(_ root: URL) -> Result {
        guard let ruleSet else { return Result() }
        return detect(files(in: root), ruleSet)
    }

    private static func detect(_ files: [String], _ ruleSet: RuleSet) -> Result {
        var found = Set<String>()
        for path in files where matches(ruleSet.any, path) {
            for rule in ruleSet.rules where !found.contains(rule.name) && matches(rule.regex, path) {
                found.insert(rule.name)
            }
        }
        if !found.isEmpty, let guess = deducedEngine(files, found) { found.insert(guess) }
        func names(_ section: String) -> [String] {
            found.filter { $0.hasPrefix(section + ".") }.map { String($0.dropFirst(section.count + 1)) }.sorted()
        }
        return Result(engines: names("Engine"), sdks: names("SDK"), antiCheats: names("AntiCheat"), launchers: names("Launcher"))
    }

    /// The second pass: file types that only say something together. Follows SteamDB's FileDetector.php.
    private static func deducedEngine(_ files: [String], _ found: Set<String>) -> String? {
        func has(_ name: String) -> Bool { found.contains(name) }
        func evidence(_ name: String) -> Bool { has("Evidence." + name) }
        func count(_ names: [String]) -> Int { names.filter(evidence).count }
        if evidence("ARC"), evidence("TAB") { return "Engine.ApexEngine" }
        if evidence("RPF"), evidence("METADATA_DAT") { return "Engine.RAGE" }
        if evidence("HDLL"), !has("Engine.Lime_OR_OpenFL") { return "Engine.Heaps" }
        if has("Emulator.DOSBOX") {
            if evidence("Build") { return "Engine.Build" }
            if evidence("VSWAP") || (evidence("CFG") && evidence("WAD")) { return "Engine.idTech" }
        }
        if evidence("U"), !has("Emulator.DOSBOX") { return "Engine.Unreal" }
        if count(["BIF", "TLK"]) > 1 { return evidence("RIM") || evidence("TGA") ? "Engine.Aurora" : "Engine.Infinity" }
        if count(["OPTIONS_INI", "DATA_WIN", "SND_OGG"]) > 1 { return "Engine.GameMaker" }
        if evidence("SIERRA_EXE"), evidence("SCR") { return "Engine.SCI" }
        if evidence("PCK"), isGodot(files) { return "Engine.Godot" }
        if evidence("PK3") { return "Engine.idTech" }
        return nil
    }

    /// One data.pck and no other, or a .pck named after a program.
    private static func isGodot(_ files: [String]) -> Bool {
        let upper = files.map { $0.uppercased() }
        let packs = upper.filter { $0.hasSuffix(".PCK") }
        guard !packs.isEmpty else { return false }
        let programs = Set(upper.filter { $0.hasSuffix(".EXE") }.map { String($0.dropLast(4)) + ".PCK" })
        if packs.contains(where: programs.contains) { return true }
        return packs.allSatisfy { ($0 as NSString).lastPathComponent == "DATA.PCK" }
    }

    // MARK: Names

    /// "RE_Engine" as people write it.
    static func displayName(_ key: String) -> String {
        let names = ["Unreal": "Unreal Engine", "RE_Engine": "RE Engine", "RenPy": "Ren'Py", "idTech": "id Tech",
                     "RPGMaker": "RPG Maker", "CreationEngine": "Creation Engine", "Source2": "Source 2",
                     "EasyAntiCheat": "Easy Anti-Cheat", "EA_AntiCheat": "EA anticheat", "UbisoftAnvil": "Anvil",
                     "ClickTeamFusion": "Clickteam Fusion", "XNA": "XNA"]
        return names[key] ?? key.replacingOccurrences(of: "_OR_", with: " / ").replacingOccurrences(of: "_", with: " ")
    }

    /// What's known about an item so far; nil until its folder has been scanned.
    static func result(for item: LibraryItem) -> Result? {
        item.installFolder.flatMap(root).flatMap { store.scans[$0.path]?.result }
    }

    // MARK: Generated rules

    /// The rule file: read when profiles load. Comes before the presets' files, so anything else that names the game wins.
    @MainActor
    static func ruleText(presets: [String: URL]) -> String {
        var out = "# Made by OverPass from what it found in each game's folder; changes here are overwritten.\n"
        for game in store.games {
            for name in game.presets {
                guard let url = presets[name] else { continue }
                out += "\n[Detected: \(game.name), preset \(name)]\n"
                    + (game.matches + ProfileStore.presetSettings(url)).joined(separator: "\n") + "\n"
            }
        }
        return out
    }

    /// Scans what hasn't been scanned, in the background; true when the rules changed.
    @MainActor
    static func refresh(_ items: [LibraryItem], ruled: @escaping (LibraryItem) -> Bool) async -> Bool {
        let games = items.filter { !$0.bottle.isMac }
        let roots = Set(games.compactMap { $0.installFolder.flatMap(root) })
        let known = store.scans
        let scanned: [String: Scan] = await Task.detached(priority: .utility) {
            var out: [String: Scan] = [:]
            for root in roots {
                let modified = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                if let old = known[root.path], old.modified == modified { continue }
                out[root.path] = Scan(modified: modified, result: scan(root))
            }
            return out
        }.value
        let before = store.scans.count
        store.scans.merge(scanned) { $1 }
        let current = Set(roots.map(\.path))
        store.scans = store.scans.filter { current.contains($0.key) }
        let dropped = store.scans.count != before + scanned.keys.filter { known[$0] == nil }.count
        var rules: [Game] = []
        for item in games where !ruled(item) {
            guard let result = result(for: item), let target = item.app.target else { continue }
            let presets = (ruleSet?.presets ?? [:]).filter { result.matches.contains($0.key) }.values.flatMap { $0 }
            guard !presets.isEmpty else { continue }
            // Two path parts: Game.exe alone would catch every game of that name.
            let program = target.split(separator: "\\").suffix(2).joined(separator: "\\")
            var matches = ["program = \(program)"]
            if item.app.launcher == "Steam", let id = item.app.storeID { matches.append("steam-app = \(id)") }
            rules.append(Game(name: item.app.name, matches: matches, presets: Array(Set(presets)).sorted()))
        }
        rules.sort { $0.name < $1.name }
        let changed = rules != store.games
        store.games = rules
        if changed || dropped || !scanned.isEmpty, let data = try? JSONEncoder().encode(store) { try? data.write(to: storeURL, options: .atomic) }
        return changed
    }
}

extension BottleManager {
    /// Keeps detection up to date with the library. One pass at a time: a change while one runs waits for the next load.
    func refreshDetection() {
        guard !detecting else { return }
        detecting = true
        Task { @MainActor in
            defer { detecting = false }
            let profiles = profiles
            let changed = await Detection.refresh(library) { [weak self] item in
                self?.hasOwnRules(item, profiles: profiles) ?? true
            }
            if changed { profiles?.load() }
            bottles = bottles  // Library views show what was found.
        }
    }

    /// A profile of its own, or a rule that names it: then detection stays out of it.
    private func hasOwnRules(_ item: LibraryItem, profiles: ProfileStore?) -> Bool {
        if profiles?.profile(for: item) != nil { return true }
        return CompatRules.all.contains { !$0.name.hasPrefix("Detected: ") && $0.covers(item) }
    }
}
