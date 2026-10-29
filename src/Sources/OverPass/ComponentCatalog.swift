import Foundation

// The component catalog from github.com/McKack/overpass-components (format in its SOCKET.md): pinned versions,
// download addresses and checksums, and the Wine features each component needs. A catalog change reaches
// everyone without an app release. Offline, or when the download fails, the last good copy is used, and
// failing that the versions built into the app (ComponentManager's constants).
struct ComponentCatalog: Codable {
    struct Component: Codable {
        struct Requires: Codable { var wineFeatures: [String]?; var arch: [String]? }
        struct Part: Codable {
            struct Asset: Codable { var arch: String; var url: URL?; var urlTemplate: String?; var sha256: String?; var format: String? }
            var name: String
            var version: String
            var authors: String?
            var licence: String?
            var upstream: URL?
            var assets: [Asset]
        }
        var id: String
        var available: Bool?
        var requires: Requires?
        var parts: [Part]
    }
    var format: Int
    var components: [Component]

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/McKack/overpass-components/main/catalog.json")!

    nonisolated static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/catalog.json")
    }

    /// The last good catalog; nil until one has been downloaded.
    nonisolated(unsafe) private static var loaded: ComponentCatalog? = read(cacheURL)
    nonisolated static var current: ComponentCatalog? { loaded }

    private nonisolated static func read(_ url: URL) -> ComponentCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private nonisolated static func decode(_ data: Data) -> ComponentCatalog? {
        guard let catalog = try? JSONDecoder().decode(ComponentCatalog.self, from: data), catalog.format == 1 else { return nil }
        return catalog
    }

    /// Downloads the catalog and keeps it when it parses; otherwise the previous one stays.
    static func refresh() async {
        guard let (data, response) = try? await URLSession.shared.data(from: remoteURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let catalog = decode(data) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        loaded = catalog
    }

    /// The catalog's entry for a component.
    nonisolated static func entry(_ id: ComponentID) -> Component? {
        guard let name = id.catalogID else { return nil }
        return current?.components.first { $0.id == name }
    }

    /// The pinned download for this Mac of a component's first part: version, address and checksum.
    nonisolated static func pin(_ id: ComponentID, arch: String) -> (version: String, url: URL, sha256: String)? {
        guard let part = entry(id)?.parts.first,
              let asset = part.assets.first(where: { $0.arch == arch || $0.arch == "any" }),
              let url = asset.url, let sha256 = asset.sha256 else { return nil }
        return (part.version, url, sha256)
    }
}

extension ComponentID {
    /// The component's folder name in overpass-components.
    var catalogID: String? {
        switch self {
        case .core: nil
        case .wine: "wine"
        case .dxmt: "runtime"
        case .addons: "dotnet-web"
        case .winetricks: "winetricks"
        case .d3dmetal: "d3dmetal"
        case .x87sidecar: "x87sidecar"
        case .gamefixes: "game-fixes"
        case .legendary: "epic"
        case .gogdl: "gog"
        case .xodus: "xbox"
        }
    }
}

/// What an OverPass Wine build supports, from its share/overpass/features.json; empty for builds without one.
enum WineFeatures {
    private struct File: Decodable {
        struct Feature: Decodable { var version: Int }
        var format: Int
        var features: [String: Feature]
    }

    nonisolated static func versions(wineRoot: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: wineRoot.appendingPathComponent("share/overpass/features.json")),
              let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1 else { return [:] }
        return file.features.mapValues(\.version)
    }

    /// The requirements ("name" or "name>=version") the Wine doesn't meet.
    nonisolated static func missing(_ requirements: [String], wineRoot: URL) -> [String] {
        let have = versions(wineRoot: wineRoot)
        return requirements.filter { requirement in
            let pieces = requirement.components(separatedBy: ">=")
            guard let version = have[pieces[0]] else { return true }
            return pieces.count > 1 && version < Int(pieces[1]) ?? Int.max
        }
    }
}
