import Foundation

// Per-program compatibility rules: arguments, environment, DLL overrides and graphics backend for one
// Windows program, wherever it's started from. They're plain INI files in Sources/OverPass/Rules, one per
// app, read as they are by OverPass Wine (OVERPASS_COMPAT_RULES), which applies them to every process
// created from Windows code, such as a launcher's helpers. The format is documented in Rules/README.md.
// OverPass applies the same rules to the program it starts itself, which Wine doesn't see being created.
struct CompatRule: Hashable {
    var name: String
    /// The file in the rules folder this rule came from.
    var file = ""
    var programs: [String] = []
    var steamAppIDs: [String] = []
    /// File names that, found in the program's folder, make the rule cover it (libcef.dll: a Chromium program).
    var besides: [String] = []
    var addArguments: [String] = []
    var unlessArgument: String?
    var environment: [(key: String, value: String)] = []
    var dllOverrides: [String] = []
    var graphics: GraphicsBackend?
    /// The backend the program runs best on, used only while its container is on Automatic.
    var preferGraphics: GraphicsBackend?
    /// mtld3d or WineD3D for this program's Direct3D 9, applied after `graphics`.
    var direct3D9: Direct3D9Backend?
    var replacePaths: [(from: String, to: String)] = []
    /// Winetricks verbs the program needs. Only OverPass reads these: it adds them before it starts the program.
    var winetricks: [String] = []
    /// The GOG and Epic IDs in the [store] of the rule's file, as "gog:<id>" and "epic:<name>".
    var stores: [String] = []

    static func == (a: CompatRule, b: CompatRule) -> Bool { a.name == b.name && a.programs == b.programs }
    func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(programs) }

    /// Whether the rule covers a program, given as a Windows or host path. Same rule as OverPass Wine:
    /// the path ends with "\" + the program entry, in any case.
    /// A `beside` entry needs a host path, to look in the program's folder.
    func matches(program path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "/", with: "\\").lowercased()
        let named = programs.contains { entry in
            if entry == "*" { return true }
            let suffix = "\\" + entry.replacingOccurrences(of: "/", with: "\\")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\")).lowercased()
            return ("\\" + normalized).hasSuffix(suffix)
        }
        guard !named, path.hasPrefix("/") else { return named }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        return besides.contains { name in
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { return false }
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    /// Whether the rule covers a library title: by its Steam app, as OverPass Wine does, or by its program.
    @MainActor
    func covers(_ item: LibraryItem) -> Bool {
        if item.app.launcher == "Steam", let id = item.app.storeID, steamAppIDs.contains(id) { return true }
        return matches(program: item.app.target.map { BottleManager.hostPath($0, in: item.bottle).path } ?? item.app.executable)
    }

    /// Whether the file's [store] names the title's GOG or Epic game. Only for what OverPass applies itself:
    /// OverPass Wine doesn't know which game a process belongs to.
    @MainActor
    func names(_ item: LibraryItem) -> Bool {
        guard let id = item.app.storeID else { return false }
        switch item.app.launcher {
        case "GOG": return stores.contains("gog:" + id)
        case EpicStore.launcherName: return stores.contains("epic:" + id)
        default: return false
        }
    }
}

enum CompatRules {
    /// The profile files in effect, bundled and the user's own, which OverPass Wine reads directly.
    /// Rules live in the profiles, next to each app's recipe.
    static var directory: URL? { UserProfiles.rulesDirectory }

    /// Profile sections that are recipe, not rules (OverPass Wine ignores them: they use no rule keys
    /// except steam-app, env, dll and graphics, which apply to the app's own Steam game).
    static let recipeSections: Set<String> = ["app", "install", "launch", "store", "anti-cheat"]

    /// Every rule in effect; read again whenever profiles change.
    private(set) static var all: [CompatRule] = load()

    static func reload() { all = load() }

    private static func load() -> [CompatRule] {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "ini" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { url in
                ((try? String(contentsOf: url, encoding: .utf8)).map(parse) ?? []).map { rule in
                    var rule = rule
                    rule.file = url.lastPathComponent
                    return rule
                }
            }
    }

    static func parse(_ text: String) -> [CompatRule] {
        var rules: [CompatRule] = []
        var inRecipe = false, inStore = false
        var stores: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast())
                inRecipe = recipeSections.contains(name.lowercased())
                inStore = name.lowercased() == "store"
                if !inRecipe { rules.append(CompatRule(name: name)) }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if inStore, key == "gog" || key == "epic", !value.isEmpty { stores.append("\(key):\(value)") }
            guard !inRecipe, !rules.isEmpty else { continue }
            var rule = rules.removeLast()
            switch key {
            case "program": rule.programs.append(value)
            case "steam-app": rule.steamAppIDs.append(value)
            case "beside": rule.besides.append(value)
            case "add-arguments": rule.addArguments += value.split(separator: " ").map(String.init)
            case "unless-argument": rule.unlessArgument = value
            case "env":
                if let e = value.firstIndex(of: "="), e != value.startIndex {
                    rule.environment.append((String(value[..<e]), String(value[value.index(after: e)...])))
                }
            case "tweak": if let tweak = tweakVariable(value) { rule.environment.append(tweak) }
            case "dll": rule.dllOverrides.append(value)
            case "graphics": rule.graphics = GraphicsBackend(rawValue: value.lowercased())
            case "prefer-graphics": rule.preferGraphics = GraphicsBackend(rawValue: value.lowercased())
            case "d3d9": rule.direct3D9 = Direct3D9Backend(rawValue: value.lowercased())
            case "replace-path":
                if let sep = value.range(of: "=>") {
                    let from = value[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
                    let to = value[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !from.isEmpty, !to.isEmpty { rule.replacePaths.append((from, to)) }
                }
            // "dependency" is the key's old name in [app].
            case "winetricks", "dependency": rule.winetricks += value.split(separator: " ").map(String.init)
            default: break  // source and anything newer
            }
            rules.append(rule)
        }
        return rules.map { rule in
            var rule = rule
            rule.stores = stores
            return rule
        }
    }

    /// The variable a `tweak = <name> [value]` line sets, as OverPass Wine sets it: OVERPASS_TWEAK_<NAME> (letters
    /// and digits upper case, anything else `_`) to the value, or 1. OverPass Runtime and OverPass Wine read them.
    static func tweakVariable(_ line: String) -> (key: String, value: String)? {
        let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty else { return nil }
        let key = "OVERPASS_TWEAK_" + String(name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return (key, parts.count > 1 && !parts[1].isEmpty ? parts[1] : "1")
    }

    /// The Winetricks verbs the rules ask for a library title: by its Steam app or program, as every rule
    /// matches, or by the GOG or Epic game in the [store] of the rule's file.
    @MainActor
    static func winetricks(for item: LibraryItem) -> [String] {
        all.filter { !$0.winetricks.isEmpty && ($0.covers(item) || $0.names(item)) }.flatMap(\.winetricks)
    }

    /// Environment that points OverPass Wine at the bundled rules and at each graphics backend's DLLs.
    static func environment() -> [String: String] {
        var env: [String: String] = [:]
        // Z: is the host root in every bottle, so this Windows path reaches the folder from any process.
        if let dir = directory { env["OVERPASS_COMPAT_RULES"] = "Z:" + dir.path.replacingOccurrences(of: "/", with: "\\") }
        for backend in GraphicsBackend.allCases {
            guard let dir = backend.dllDirectory else { continue }
            if FileManager.default.fileExists(atPath: dir.path) {
                env["OVERPASS_BACKEND_" + backend.rawValue.uppercased()] = dir.path
            }
        }
        return env
    }

    /// Applies matching rules to a program OverPass starts itself, given as a host path; a replace-path
    /// rule changes `program`.
    /// `graphicsChosen`: the container has a backend of its own (not Automatic), which `prefer-graphics` leaves alone.
    static func apply(to program: inout String, arguments: inout [String], environment env: inout [String: String],
                      graphicsChosen: Bool = false) {
        for rule in all where rule.matches(program: program) {
            for (from, to) in rule.replacePaths {
                // Absolute replacements are Windows paths for programs other programs start, which OverPass
                // Wine handles; OverPass only starts programs inside the bottle by host path.
                if to.dropFirst().hasPrefix(":") || to.hasPrefix("\\\\") { continue }
                let hostFrom = from.replacingOccurrences(of: "\\", with: "/")
                guard let range = program.range(of: hostFrom, options: .caseInsensitive) else { continue }
                let replaced = program.replacingCharacters(in: range, with: to.replacingOccurrences(of: "\\", with: "/"))
                if FileManager.default.fileExists(atPath: replaced) { program = replaced }
            }
            let commandLine = arguments.joined(separator: " ")
            if rule.unlessArgument.map({ !commandLine.contains($0) }) ?? true {
                arguments += rule.addArguments.filter { !arguments.contains($0) }
            }
            for (key, value) in rule.environment { env[key] = value }
            if !rule.dllOverrides.isEmpty {
                env["WINEDLLOVERRIDES"] = ([env["WINEDLLOVERRIDES"]].compactMap { $0 }.filter { !$0.isEmpty }
                    + rule.dllOverrides).joined(separator: ";")
            }
            // As in OverPass Wine: a backend that isn't installed leaves the program on its usual one.
            if let graphics = (rule.graphics ?? (graphicsChosen ? nil : rule.preferGraphics))?.resolved,
               graphics.dllDirectory.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                env.merge(graphics.environment) { $1 }
                if graphics == .auto { env.removeValue(forKey: "CX_ACTIVE_GRAPHICS_BACKEND") }
                // mtld3d stays in front when the bottle uses it for Direct3D 9.
                let mtld3d = Direct3D9Backend.directory.path
                let keep = env["OVERPASS_DLL_PATH_PREPEND"]?.split(separator: ":").first.map(String.init) == mtld3d
                env["OVERPASS_DLL_PATH_PREPEND"] = [keep ? mtld3d : nil, graphics.dllDirectory?.path]
                    .compactMap { $0 }.joined(separator: ":")
            }
            // As OverPass Wine does: mtld3d's folder to the front of the DLL path, or out of it.
            if let d3d9 = rule.direct3D9, d3d9 != .auto, Direct3D9Backend.isInstalled {
                let mtld3d = Direct3D9Backend.directory.path
                var parts = (env["OVERPASS_DLL_PATH_PREPEND"] ?? "").split(separator: ":").map(String.init)
                if parts.first == mtld3d { parts.removeFirst() }
                if d3d9 == .mtld3d { parts.insert(mtld3d, at: 0) }
                env["OVERPASS_DLL_PATH_PREPEND"] = parts.joined(separator: ":")
            }
        }
    }
}
