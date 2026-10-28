import Foundation
import AppKit

struct Bottle: Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: URL
    var template: WineTemplate
    var wineArch: String
    var description: String
    /// Apps that share a bottle (a launcher and its games) carry the same group.
    var group: String? = nil
    var profileID: String? = nil
    var graphics: GraphicsBackend = .auto
    var direct3D9: Direct3D9Backend = .auto
    var environment: [String: String] = [:]
    var apps: [WineApp]

    /// The container's settings file: [Container] ID, Template, Arch, Created, Description; [Environment]; [OverPass].
    static let configName = "container.conf"
    var configURL: URL { path.appendingPathComponent(Self.configName) }
    var driveC: URL { path.appendingPathComponent("drive_c") }

    static func bottlesDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/Bottles")
    }
}

struct WineApp: Identifiable, Hashable {
    var name: String
    /// Host path of the shortcut (.lnk) or executable.
    var executable: String
    var arguments: [String] = []
    /// Host path of an .exe, .ico, .png or .jpg to take the icon from, when it isn't `executable` itself.
    var icon: String? = nil
    /// Host path of a cover picked in the profile editor, used instead of the store's art.
    var cover: String? = nil
    /// The generated cover even when the store has art.
    var generatedCover = false
    /// How the generated cover and the Mac app's icon are drawn, when the profile says (ArtStyle).
    var coverStyle: ArtStyle? = nil
    var iconStyle: ArtStyle? = nil
    /// The store a game was found through ("Steam"); nil for Start-menu and desktop shortcuts.
    var launcher: String? = nil
    /// The game's ID in that store (Steam app ID, GOG product ID).
    var storeID: String? = nil
    /// "Play" for a game from a store, "Run" for other programs.
    var runLabel: String { launcher == nil || launcher == "Mac" ? "Run" : "Play" }
    /// Windows path of the program a shortcut starts, or of the program itself; nil when unknown.
    var target: String? = nil
    /// Host path of a Start-menu shortcut to a launcher's game, kept for its icon.
    var shortcut: String? = nil
    /// The store client OverPass starts the game through, for games its built-in libraries installed.
    var backend: StoreBackend? = nil

    /// File name of the program that runs ("notepad++.exe"), what compatibility rules match on.
    var programName: String? {
        target.map { $0.replacingOccurrences(of: "\\", with: "/") }.map { ($0 as NSString).lastPathComponent }
    }
    // Every Steam game runs steam.exe, so the arguments are part of what tells apps apart.
    var id: String { ([executable] + arguments).joined(separator: "|") }
}

enum StoreBackend: String, Hashable {
    /// Epic Games, through Legendary (EpicStore).
    case legendary
    /// GOG, through gogdl (GOGStore). The games start directly; gogdl only downloads them.
    case gogdl
    /// Xbox, through Xodus (XboxStore). Xodus licenses each start and hands Wine the decrypted program.
    case xodus
}

enum WineTemplate: String, CaseIterable, Identifiable, Codable {
    case windows7, windows10, windows11

    /// Also reads the values profiles and containers used up to OverPass 0.3 (`win10_64` and so on).
    init?(rawValue: String) {
        switch rawValue {
        case "windows7", "win7_64": self = .windows7
        case "windows10", "win10_64": self = .windows10
        case "windows11", "win11_64": self = .windows11
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .windows7: "windows7"
        case .windows10: "windows10"
        case .windows11: "windows11"
        }
    }

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .windows7: "Windows 7 (64-bit)"
        case .windows10: "Windows 10 (64-bit)"
        case .windows11: "Windows 11 (64-bit)"
        }
    }
}

struct BottleConfig {
    // INI-style: `"Name" = "Value"` with backslash escapes, or bare `Name = Value`. Lines starting with ';' or '#'
    // are comments. We always write the quoted form.
    static func parse(_ url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var sections: [String: [String: String]] = [:]
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
                current = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            } else if let (key, val) = parseQuoted(trimmed) {
                sections[current, default: [:]][key] = val
            } else if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                sections[current, default: [:]][key] = val
            }
        }
        return sections
    }

    /// Reads `"key" = "value" ; optional comment`; nil if the line isn't in quoted form.
    private static func parseQuoted(_ line: String) -> (String, String)? {
        var chars = Substring(line)
        func quoted() -> String? {
            guard chars.first == "\"" else { return nil }
            chars = chars.dropFirst()
            var out = ""
            while let c = chars.first {
                chars = chars.dropFirst()
                if c == "\"" { return out }
                if c == "\\", let next = chars.first {
                    chars = chars.dropFirst()
                    out.append(next)
                } else {
                    out.append(c)
                }
            }
            return nil
        }
        guard let key = quoted() else { return nil }
        chars = chars.drop { $0 == " " || $0 == "\t" }
        guard chars.first == "=" else { return nil }
        chars = chars.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let value = quoted() else { return nil }
        return (key, value)
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The file OverPass 0.3 and older wrote, with other section and key names.
    private static let legacyName = "cxbottle.conf"

    /// Whether `dir` holds a container's settings, in either file.
    static func exists(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(Bottle.configName).path)
            || fm.fileExists(atPath: dir.appendingPathComponent(legacyName).path)
    }

    /// Moves an older container's settings into container.conf with our section and key names.
    static func migrate(in dir: URL) {
        let fm = FileManager.default
        let old = dir.appendingPathComponent(legacyName), new = dir.appendingPathComponent(Bottle.configName)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        var sections = parse(old)
        if let info = sections.removeValue(forKey: "Bottle") {
            let template = info["Template"].flatMap(WineTemplate.init(rawValue:))?.rawValue
            sections["Container"] = ["ID": info["BottleID"], "Template": template, "Arch": info["WineArch"],
                                     "Created": info["Timestamp"], "Description": info["Description"]].compactMapValues { $0 }
        }
        if let environment = sections.removeValue(forKey: "EnvironmentVariables") { sections["Environment"] = environment }
        guard (try? write(sections, to: new)) != nil else { return }
        try? fm.removeItem(at: old)
    }

    static func write(_ sections: [String: [String: String]], to url: URL) throws {
        var lines: [String] = []
        for (section, fields) in sections.sorted(by: { $0.key < $1.key }) {
            lines.append("[\(section)]")
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                lines.append("\(quote(key)) = \(quote(value))")
            }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
