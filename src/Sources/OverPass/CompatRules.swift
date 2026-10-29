import Foundation

// Per-program compatibility rules: arguments, environment, DLL overrides and graphics backend for one
// Windows program, wherever it's started from. They're plain INI files in Sources/OverPass/Rules, one per
// app, read as they are by OverPass Wine (OVERPASS_COMPAT_RULES), which applies them to every process
// created from Windows code, such as a launcher's helpers. The format is documented in Rules/README.md.
// OverPass applies the same rules to the program it starts itself, which Wine doesn't see being created.
struct CompatRule: Hashable {
    var name: String
    var programs: [String] = []
    var steamAppIDs: [String] = []
    /// File names that, found in the program's folder, make the rule cover it (libcef.dll: a Chromium program).
    var besides: [String] = []
    var addArguments: [String] = []
    var unlessArgument: String?
    var environment: [(key: String, value: String)] = []
    var dllOverrides: [String] = []
    var graphics: GraphicsBackend?
    /// mtld3d or WineD3D for this program's Direct3D 9, applied after `graphics`.
    var direct3D9: Direct3D9Backend?
    var replacePaths: [(from: String, to: String)] = []

    static func == (a: CompatRule, b: CompatRule) -> Bool { a.name == b.name && a.programs == b.programs }
    func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(programs) }

    /// Whether the rule covers a program, given as a Windows or host path. Same rule as OverPass Wine:
    /// the path ends with "\" + the program entry, in any case.
    /// A `beside` entry needs a host path, to look in the program's folder.
    func matches(program path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "/", with: "\\").lowercased()
        let named = programs.contains { entry in
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
}

enum CompatRules {
    /// The profile files in effect, bundled and the user's own, which OverPass Wine reads directly.
    /// Rules live in the profiles, next to each app's recipe.
    static var directory: URL? { UserProfiles.rulesDirectory }

    /// Profile sections that are recipe, not rules (OverPass Wine ignores them: they use no rule keys
    /// except steam-app, env, dll and graphics, which apply to the app's own Steam game).
    static let recipeSections: Set<String> = ["app", "install", "launch"]

    /// Every rule in effect; read again whenever profiles change.
    private(set) static var all: [CompatRule] = load()

    static func reload() { all = load() }

    private static func load() -> [CompatRule] {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "ini" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { (try? String(contentsOf: $0, encoding: .utf8)).map(parse) ?? [] }
    }

    static func parse(_ text: String) -> [CompatRule] {
        var rules: [CompatRule] = []
        var inRecipe = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast())
                inRecipe = recipeSections.contains(name.lowercased())
                if !inRecipe { rules.append(CompatRule(name: name)) }
                continue
            }
            guard !inRecipe, !rules.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
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
            case "dll": rule.dllOverrides.append(value)
            case "graphics": rule.graphics = GraphicsBackend(rawValue: value.lowercased())
            case "d3d9": rule.direct3D9 = Direct3D9Backend(rawValue: value.lowercased())
            case "replace-path":
                if let sep = value.range(of: "=>") {
                    let from = value[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
                    let to = value[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !from.isEmpty, !to.isEmpty { rule.replacePaths.append((from, to)) }
                }
            default: break  // source and anything newer
            }
            rules.append(rule)
        }
        return rules
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
    static func apply(to program: inout String, arguments: inout [String], environment env: inout [String: String]) {
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
            if let graphics = rule.graphics?.resolved,
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
