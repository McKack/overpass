import Foundation

// OverPass profiles: one INI file per app (Profiles/<id>.ini), designed to be a public, tool-neutral database.
// The [app], [install] and [launch] sections are the recipe, read here; every other section is a
// compatibility rule (CompatRules), which OverPass Wine reads from the same files. Format: Profiles/README.md.
// Field set is informed by what install recipes actually need (bottle template, runtimes, env, DLL
// overrides, graphics backend) — written from scratch, no third-party profile content.
struct GameProfile: Codable, Identifiable, Hashable {
    var schema: Int = 1
    var id: String
    var name: String
    var category: String?
    /// Position among the stores and launchers shown on Home; nil means not shown there.
    var featured: Int?
    /// Shown on Home before OverPass can install it: "Coming soon…" and no Install button.
    var comingSoon = false
    var steamAppID: Int?
    /// GOG product ID, so the profile also applies to the GOG copy of the game.
    var gogGameID: String?
    /// Hex colour of the store's brand, used behind its logo on Home.
    var brandColor: String?
    var rating: Rating = Rating()
    var bottle: BottleSpec = BottleSpec()
    var installer: InstallerSpec?
    /// Runtimes OverPass installs itself (see Runtime), before the installer runs.
    var runtimes: [String] = []
    /// Winetricks verbs installed into the bottle before the installer runs, after `runtimes`.
    var dependencies: [String] = []
    var environment: [String: String] = [:]
    /// Same syntax as WINEDLLOVERRIDES values, e.g. ["d3d11": "n,b"].
    var dllOverrides: [String: String] = [:]
    var graphics: GraphicsBackend = .auto
    /// DualShock 4 and DualSense reach the bottle's programs as PlayStation controllers instead of Xbox pads
    /// (Sony's own PC ports, for haptics and adaptive triggers). Applied when the bottle is made.
    var playStationControllers = false
    /// Backends the profile's rules select for some of its programs.
    var ruleGraphics: [GraphicsBackend] = []
    var launch: LaunchSpec?
    /// An image in UserProfiles.iconsDirectory shown for the app instead of its Windows icon.
    var icon: String?
    /// An image in UserProfiles.coversDirectory shown in the Covers layout instead of the store's art.
    var cover: String?
    /// How the generated cover and the Mac app's icon are drawn (ArtStyle values).
    var coverStyle: String?
    var iconStyle: String?
    var notes: String?
    /// The game engine ("Unity"), when the profile says; otherwise it's told from the game's files.
    var engine: String?
    var sources: [Source] = []

    /// How well the app runs on OverPass, judged by actually testing it on a Mac.
    struct Rating: Codable, Hashable {
        var tier: Tier = .untested
        /// What it was tested with, e.g. "OverPass 0.1, OverPass Wine 11.0-1, macOS 26.6, M4".
        var testedWith: String?
        /// ISO date of the test, e.g. "2026-10-25".
        var date: String?
        var notes: String?

        enum Tier: String, Codable, CaseIterable {
            case platinum, gold, silver, bronze, borked, untested

            var title: String {
                switch self {
                case .platinum: "Platinum"
                case .gold: "Gold"
                case .silver: "Silver"
                case .bronze: "Bronze"
                case .borked: "Borked"
                case .untested: "Not rated yet"
                }
            }

            var summary: String {
                switch self {
                case .platinum: "Runs perfectly out of the box"
                case .gold: "Runs well; OverPass applies the needed tweaks"
                case .silver: "Runs, with minor issues"
                case .bronze: "Runs, with major issues"
                case .borked: "Doesn't run"
                case .untested: "Not tested on OverPass yet"
                }
            }
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? .untested
            testedWith = try c.decodeIfPresent(String.self, forKey: .testedWith)
            date = try c.decodeIfPresent(String.self, forKey: .date)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
        }
    }

    struct BottleSpec: Codable, Hashable {
        var template: WineTemplate = .windows10
        /// Apps with the same group share one bottle (e.g. a launcher and the games installed through it).
        var group: String?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            template = try c.decodeIfPresent(WineTemplate.self, forKey: .template) ?? .windows10
            group = try c.decodeIfPresent(String.self, forKey: .group)
        }
    }

    struct InstallerSpec: Codable, Hashable {
        var downloadURL: URL?
        var downloadPage: URL?
        /// Installer file names this profile recognizes when the user picks a file; '*' wildcards allowed.
        var fileNames: [String] = []
        var silentArgs: [String] = []
        /// A program the installer starts that keeps running afterwards, typically the launcher itself; the
        /// install counts as finished when everything else it started has exited (WINE_WAIT_CHILD_PIPE_IGNORE).
        var waitIgnore: String?
        /// For installers whose file name carries the version: the newest GitHub release's asset matching `asset`.
        var githubRelease: GitHubRelease?

        struct GitHubRelease: Codable, Hashable {
            /// "owner/repo"
            var repo: String
            /// Asset file name; '*' wildcards allowed.
            var asset: String
        }

        /// For vendors that publish the current installer's link in a JSON file: `url` is fetched and `key`, a
        /// dotted path such as "content.windows.downloadLink", names the link.
        var latestLink: LatestLink?

        struct LatestLink: Codable, Hashable {
            var url: URL
            var key: String
        }

        var canDownload: Bool { downloadURL != nil || githubRelease != nil || latestLink != nil }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            downloadURL = try c.decodeIfPresent(URL.self, forKey: .downloadURL)
            githubRelease = try c.decodeIfPresent(GitHubRelease.self, forKey: .githubRelease)
            latestLink = try c.decodeIfPresent(LatestLink.self, forKey: .latestLink)
            downloadPage = try c.decodeIfPresent(URL.self, forKey: .downloadPage)
            fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames) ?? []
            silentArgs = try c.decodeIfPresent([String].self, forKey: .silentArgs) ?? []
            waitIgnore = try c.decodeIfPresent(String.self, forKey: .waitIgnore)
        }
    }

    struct LaunchSpec: Codable, Hashable {
        /// Windows path, e.g. "C:\\Program Files (x86)\\Steam\\steam.exe".
        var executable: String
        var arguments: [String] = []
        /// Windows paths ('*' wildcards in the file name) removed before a start while nothing runs in the bottle.
        var staleFiles: [String] = []
        /// Values set in the program's own JSON settings before a start while nothing runs in the bottle.
        var jsonSettings: [JSONSetting] = []

        struct JSONSetting: Codable, Hashable {
            /// Windows path of the JSON file; nothing happens until the program has created it.
            var file: String
            var key: String
            var value: String
        }

        init(executable: String, arguments: [String], staleFiles: [String], jsonSettings: [JSONSetting] = []) {
            self.executable = executable
            self.arguments = arguments
            self.staleFiles = staleFiles
            self.jsonSettings = jsonSettings
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            executable = try c.decode(String.self, forKey: .executable)
            arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
            staleFiles = try c.decodeIfPresent([String].self, forKey: .staleFiles) ?? []
            jsonSettings = try c.decodeIfPresent([JSONSetting].self, forKey: .jsonSettings) ?? []
        }
    }

    struct Source: Codable, Hashable {
        var title: String
        var url: URL
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // Tolerate missing optional keys so profiles stay short.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        featured = try c.decodeIfPresent(Int.self, forKey: .featured)
        steamAppID = try c.decodeIfPresent(Int.self, forKey: .steamAppID)
        brandColor = try c.decodeIfPresent(String.self, forKey: .brandColor)
        rating = try c.decodeIfPresent(Rating.self, forKey: .rating) ?? Rating()
        bottle = try c.decodeIfPresent(BottleSpec.self, forKey: .bottle) ?? BottleSpec()
        installer = try c.decodeIfPresent(InstallerSpec.self, forKey: .installer)
        runtimes = try c.decodeIfPresent([String].self, forKey: .runtimes) ?? []
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        dllOverrides = try c.decodeIfPresent([String: String].self, forKey: .dllOverrides) ?? [:]
        graphics = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics) ?? .auto
        playStationControllers = try c.decodeIfPresent(Bool.self, forKey: .playStationControllers) ?? false
        launch = try c.decodeIfPresent(LaunchSpec.self, forKey: .launch)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
    }

    /// Reads a profile from its INI file; nil when the file has no [app] section (rules only).
    static func parseINI(id: String, text: String) -> GameProfile? {
        var sections: [String: [(key: String, value: String)]] = [:]
        var current: String?
        var inRule = false
        var ruleGraphics: [GraphicsBackend] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).lowercased()
                current = CompatRules.recipeSections.contains(name) ? name : nil
                inRule = current == nil
                continue
            }
            // Rules can ask for a graphics backend per program; the installer needs to know about those too.
            if inRule, let eq = line.firstIndex(of: "="),
               line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "graphics",
               let g = GraphicsBackend(rawValue: line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)) {
                ruleGraphics.append(g)
            }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[section, default: []].append((key, value))
        }
        guard let app = sections["app"] else { return nil }
        func first(_ s: [(key: String, value: String)]?, _ key: String) -> String? { s?.first { $0.key == key }?.value }
        func all(_ s: [(key: String, value: String)]?, _ key: String) -> [String] { s?.filter { $0.key == key }.map(\.value) ?? [] }
        func pair(_ value: String, _ separator: Character) -> (String, String)? {
            guard let i = value.firstIndex(of: separator) else { return nil }
            return (value[..<i].trimmingCharacters(in: .whitespaces), value[value.index(after: i)...].trimmingCharacters(in: .whitespaces))
        }

        var p = GameProfile(id: id, name: first(app, "name") ?? id)
        p.category = first(app, "category")
        p.featured = first(app, "featured").flatMap(Int.init)
        p.comingSoon = first(app, "coming-soon") == "true"
        p.steamAppID = first(app, "steam-app").flatMap(Int.init)
        p.gogGameID = first(app, "gog-game")
        p.brandColor = first(app, "brand-color")
        p.rating.tier = first(app, "rating").flatMap(Rating.Tier.init(rawValue:)) ?? .untested
        p.rating.testedWith = first(app, "tested-with")
        p.rating.date = first(app, "rating-date")
        p.rating.notes = first(app, "rating-notes")
        // "container" is the name OverPass shows; "bottle" the key profiles have always used.
        p.bottle.template = (first(app, "container") ?? first(app, "bottle")).flatMap(WineTemplate.init(rawValue:)) ?? .windows10
        p.bottle.group = first(app, "container-group") ?? first(app, "bottle-group")
        p.runtimes = all(app, "runtime")
        p.dependencies = all(app, "dependency")
        for e in all(app, "env") { if let (k, v) = pair(e, "=") { p.environment[k] = v } }
        for d in all(app, "dll") { if let (k, v) = pair(d, "=") { p.dllOverrides[k] = v } }
        p.graphics = first(app, "graphics").flatMap(GraphicsBackend.init(rawValue:)) ?? .auto
        p.playStationControllers = first(app, "controllers")?.lowercased() == "playstation"
        p.notes = first(app, "notes")
        p.engine = first(app, "engine")
        p.icon = first(app, "icon")
        p.cover = first(app, "cover")
        p.coverStyle = first(app, "cover-style")
        p.iconStyle = first(app, "icon-style")
        p.sources = all(app, "source").compactMap { s in
            guard let (title, url) = pair(s, "|"), let u = URL(string: url) else { return nil }
            return Source(title: title, url: u)
        }

        if let install = sections["install"] {
            var spec = InstallerSpec()
            spec.downloadURL = first(install, "download").flatMap(URL.init(string:))
            spec.downloadPage = first(install, "download-page").flatMap(URL.init(string:))
            spec.fileNames = all(install, "file")
            spec.silentArgs = all(install, "silent").flatMap { $0.split(separator: " ").map(String.init) }
            spec.waitIgnore = first(install, "wait-ignore")
            if let g = first(install, "github-release")?.split(separator: " ", maxSplits: 1), g.count == 2 {
                spec.githubRelease = .init(repo: String(g[0]), asset: String(g[1]))
            }
            if let l = first(install, "latest-link")?.split(separator: " ", maxSplits: 1), l.count == 2, let u = URL(string: String(l[0])) {
                spec.latestLink = .init(url: u, key: String(l[1]))
            }
            p.installer = spec
        }
        p.ruleGraphics = ruleGraphics
        if let launch = sections["launch"], let exe = first(launch, "executable") {
            p.launch = LaunchSpec(executable: exe, arguments: all(launch, "argument").flatMap { $0.split(separator: " ").map(String.init) },
                                  staleFiles: all(launch, "stale-file"),
                                  jsonSettings: all(launch, "json-setting").compactMap { line in
                                      // "<Windows path> | <key> | <value>"
                                      let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                                      return parts.count == 3 ? .init(file: parts[0], key: parts[1], value: parts[2]) : nil
                                  })
        }
        return p
    }

    func matches(installerFileName name: String) -> Bool {
        installer?.fileNames.contains { Self.wildcard(pattern: $0, matches: name) } ?? false
    }

    /// Case-insensitive file name match where '*' stands for any run of characters.
    static func wildcard(pattern: String, matches name: String) -> Bool {
        name.range(of: "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    case auto, wined3d, dxmt, d3dmetal, dxvk
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .wined3d: "WineD3D (OpenGL)"
        case .dxmt: "OverPass Runtime (Metal)"
        case .d3dmetal: "D3DMetal (Metal)"
        case .dxvk: "DXVK (Vulkan via MoltenVK)"
        }
    }

    /// Component the backend needs, if any.
    var component: ComponentID? {
        switch self {
        case .dxmt: .dxmt
        case .d3dmetal: .d3dmetal
        default: nil
        }
    }

    /// Directory whose builtin DLLs replace Wine's own for this backend.
    /// OverPass Wine searches OVERPASS_DLL_PATH_PREPEND before its own DLL directory.
    var dllDirectory: URL? {
        switch self {
        case .dxmt: ComponentManager.dxmtDir
        case .d3dmetal: ComponentManager.d3dmetalDir.appendingPathComponent("wine")
        // OverPass Wine 11.0-8 and later bring DXVK, as CrossOver does.
        case .dxvk: BottleManager.findWine()?.appendingPathComponent("lib/dxvk")
        default: nil
        }
    }

    /// The backend a program actually gets: Automatic means OverPass Runtime when it's installed (it runs
    /// Direct3D 10 to 12 far better than Wine's own Direct3D), otherwise Wine's own.
    var resolved: GraphicsBackend {
        guard self == .auto, let dir = GraphicsBackend.dxmt.dllDirectory,
              FileManager.default.fileExists(atPath: dir.path) else { return self }
        return .dxmt
    }

    /// CodeWeavers' Wine changes check CX_ACTIVE_GRAPHICS_BACKEND (e.g. win32u's Vulkan loader).
    var environment: [String: String] {
        self == .auto ? [:] : ["CX_ACTIVE_GRAPHICS_BACKEND": rawValue]
    }
}

/// Who runs a program's Direct3D 9: mtld3d, which comes with OverPass Runtime, or Wine's own WineD3D on OpenGL
/// (what the Direct3D 10–12 setting leaves it with: none of those backends brings a d3d9.dll).
enum Direct3D9Backend: String, CaseIterable, Identifiable {
    case auto, mtld3d, wined3d
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .mtld3d: "mtld3d (Metal)"
        case .wined3d: "WineD3D (OpenGL)"
        }
    }

    /// mtld3d's builtin d3d9.dll + mtld3d.dll pair and its unix half, inside OverPass Runtime.
    nonisolated static var directory: URL { ComponentManager.dxmtDir.appendingPathComponent("mtld3d") }
    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("x86_64-unix/mtld3d.so").path)
    }

    /// Automatic means mtld3d whenever OverPass Runtime has it: it runs Direct3D 9 on Metal, where WineD3D
    /// goes through Apple's old OpenGL.
    var usesMtld3d: Bool { self != .wined3d && Self.isInstalled }

    /// OVERPASS_DLL_PATH_PREPEND for a program on `graphics`: mtld3d's folder in front of the backend's.
    func dllPath(with graphics: GraphicsBackend) -> String {
        [usesMtld3d ? Self.directory : nil,
         graphics.dllDirectory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }]
            .compactMap { $0?.path }.joined(separator: ":")
    }
}

@MainActor
@Observable
class ProfileStore {
    private(set) var profiles: [GameProfile] = []

    init() {
        load()
    }

    /// SwiftPM's generated Bundle.module looks next to the .app rather than in Contents/Resources,
    /// so check the app's Resources first and fall back to Bundle.module for `swift run`.
    nonisolated static var resourceBundle: Bundle {
        if let url = Bundle.main.url(forResource: "OverPass_OverPass", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }

    /// Bundled profiles replaced by an edited copy.
    private(set) var edited: Set<String> = []
    /// Profiles made in OverPass, with no bundled original.
    private(set) var custom: Set<String> = []
    /// Edited profiles whose bundled original has changed since the copy was made.
    private(set) var originalChanged: Set<String> = []

    nonisolated static var bundledDirectory: URL? {
        resourceBundle.url(forResource: "Profiles", withExtension: nil)
    }

    private static func iniFiles(in dir: URL?) -> [String: URL] {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [:] }
        return Dictionary(files.filter { $0.pathExtension.lowercased() == "ini" }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }) { a, _ in a }
    }

    /// Reads the bundled profiles and the user's own, which replace bundled ones of the same name, and puts the
    /// files in effect where OverPass Wine reads its rules.
    func load() {
        let bundled = Self.iniFiles(in: Self.bundledDirectory)
        let user = Self.iniFiles(in: UserProfiles.directory)
        let effective = bundled.merging(user) { $1 }
        edited = Set(user.keys).intersection(bundled.keys)
        custom = Set(user.keys).subtracting(bundled.keys)
        originalChanged = Set(edited.filter { id in
            guard let mine = try? String(contentsOf: user[id]!, encoding: .utf8),
                  let original = try? String(contentsOf: bundled[id]!, encoding: .utf8) else { return false }
            return UserProfiles.basedOn(mine).map { $0 != UserProfiles.version(of: original) } ?? false
        })
        profiles = effective.compactMap { id, url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return GameProfile.parseINI(id: id, text: text)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        UserProfiles.syncRules(Array(effective.values))
        CompatRules.reload()
    }

    /// The text of a profile as in effect: the user's copy, else the bundled file.
    func text(of id: String) -> String? {
        let user = UserProfiles.directory.appendingPathComponent("\(id).ini")
        if let text = try? String(contentsOf: user, encoding: .utf8) { return text }
        return bundledText(of: id)
    }

    func bundledText(of id: String) -> String? {
        Self.bundledDirectory.flatMap { try? String(contentsOf: $0.appendingPathComponent("\(id).ini"), encoding: .utf8) }
    }

    /// Saves a profile as the user's own; a copy of a bundled profile records which version it started from.
    func save(id: String, text: String) throws {
        var body = text.components(separatedBy: "\n").drop { $0.hasPrefix(UserProfiles.basedOnPrefix) }.joined(separator: "\n")
        if !edited.contains(id), let original = bundledText(of: id) {
            body = UserProfiles.basedOnPrefix + UserProfiles.version(of: original) + "\n" + body
        } else if let mine = try? String(contentsOf: UserProfiles.directory.appendingPathComponent("\(id).ini"), encoding: .utf8),
                  let basedOn = UserProfiles.basedOn(mine) {
            body = UserProfiles.basedOnPrefix + basedOn + "\n" + body
        }
        try FileManager.default.createDirectory(at: UserProfiles.directory, withIntermediateDirectories: true)
        try body.write(to: UserProfiles.directory.appendingPathComponent("\(id).ini"), atomically: true, encoding: .utf8)
        load()
    }

    /// Goes back to the bundled profile, or removes a profile made in OverPass.
    func revert(id: String) {
        try? FileManager.default.removeItem(at: UserProfiles.directory.appendingPathComponent("\(id).ini"))
        load()
    }

    /// Adds a profile file someone shared; one named like an existing profile replaces it. Returns its ID.
    @discardableResult
    func importProfile(from url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let id = url.deletingPathExtension().lastPathComponent
        guard GameProfile.parseINI(id: id, text: text) != nil else { throw ProfileError.notAProfile }
        try save(id: id, text: text)
        return id
    }

    /// The profile an installed app runs with: by its store ID, as the app its bottle was made for, or as the
    /// program a profile made in OverPass names.
    func profile(for item: LibraryItem) -> GameProfile? {
        if let id = item.app.storeID {
            switch item.app.launcher {
            case "Steam": if let p = profiles.first(where: { $0.steamAppID.map(String.init) == id }) { return p }
            case "GOG": if let p = profiles.first(where: { $0.gogGameID == id }) { return p }
            default: break
            }
            return nil
        }
        guard let program = item.app.programName?.lowercased() else { return nil }
        func launches(_ p: GameProfile) -> Bool {
            p.launch.map { ($0.executable.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased() } == program
        }
        if let id = item.bottle.profileID, let p = profile(id: id), launches(p) { return p }
        if let group = item.bottle.group,
           let p = profiles.first(where: { $0.bottle.group == group && launches($0) }) { return p }
        return profiles.first { custom.contains($0.id) && launches($0) }
    }

    /// Game stores and launchers for the Home screen, in display order.
    var featured: [GameProfile] {
        profiles.filter { $0.featured != nil }.sorted { $0.featured! < $1.featured! }
    }

    func profile(id: String) -> GameProfile? {
        profiles.first { $0.id == id }
    }

    func match(installer url: URL) -> GameProfile? {
        // Profiles made in OverPass name no installers, so they never match here.
        profiles.first { $0.matches(installerFileName: url.lastPathComponent) }
    }
}

enum ProfileError: LocalizedError {
    case notAProfile

    var errorDescription: String? {
        "This file isn't an OverPass profile: it has no [app] section."
    }
}
