import Foundation

// Containers live in Application Support/OverPass/Bottles unless the person adds other folders (a bigger or
// external disk) in Settings › Advanced. One location is the favorite: new containers go there, and the install
// sheet offers the others. A container moves with everything in it, store games included; what OverPass keeps
// about it by path (favorites, categories, recent titles, the stores' install records) is rewritten to match.
enum ContainerLocations {
    static let key = "containerLocations"
    static let favoriteKey = "favoriteContainerLocation"

    /// The folders added besides the default one, as the person added them (connected or not).
    static var added: [URL] { urls(UserDefaults.standard.string(forKey: key) ?? "") }

    /// The stored list: one path per line.
    static func urls(_ stored: String) -> [URL] {
        stored.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    private static func store(_ paths: [String]) {
        UserDefaults.standard.set(paths.joined(separator: "\n"), forKey: key)
    }

    /// Every location, the default first; added ones on a disk that isn't connected are left out.
    static var all: [URL] {
        [Bottle.bottlesDirectory()] + added.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where new containers go: the favorite while it's connected, otherwise the default.
    static var favorite: URL {
        let path = UserDefaults.standard.string(forKey: favoriteKey) ?? ""
        return all.first { $0.path == path } ?? Bottle.bottlesDirectory()
    }

    static func isDefault(_ url: URL) -> Bool { url.standardizedFileURL == Bottle.bottlesDirectory().standardizedFileURL }

    /// Container folders in `location`. Added folders may hold other things, so only folders with a container's
    /// settings file count there.
    static func containers(in location: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { $0.hasDirectoryPath }.filter {
            isDefault(location) || BottleConfig.exists(in: $0)
        }
    }

    /// Why `url` can't be added, or nil when it can.
    static func problem(adding url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let existing = ([Bottle.bottlesDirectory()] + added).map { $0.standardizedFileURL.path }
        if existing.contains(path) { return "That folder is already a container location." }
        if existing.contains(where: { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) {
            return "That folder is inside a container location, or holds one."
        }
        if !FileManager.default.isWritableFile(atPath: path) { return "OverPass can't write to that folder." }
        return nil
    }

    static func add(_ url: URL) {
        store(added.map(\.path) + [url.standardizedFileURL.path])
    }

    /// Forgets a location; its containers stay on disk but leave the library.
    static func remove(_ url: URL) {
        store(added.map(\.path).filter { $0 != url.path })
        if UserDefaults.standard.string(forKey: favoriteKey) == url.path {
            UserDefaults.standard.removeObject(forKey: favoriteKey)
        }
    }

    /// The location a container is in.
    static func location(of bottle: Bottle) -> URL { bottle.path.deletingLastPathComponent() }

    /// Space left on the location's disk, in bytes.
    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    static func freeSpaceText(at url: URL) -> String {
        freeSpace(at: url).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free" } ?? "Not connected"
    }

    /// A short name for a location: "Default" or the folder's name with its disk.
    static func displayName(of url: URL) -> String {
        if isDefault(url) { return "Default" }
        let volume = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        return volume.map { "\(url.lastPathComponent) on \($0)" } ?? url.lastPathComponent
    }

    /// Moves a container's folder (a rename on the same disk, a copy otherwise) and rewrites the paths OverPass
    /// keeps about it. Nothing may run in it.
    static func move(_ bottle: URL, to location: URL) throws -> URL {
        let fm = FileManager.default
        let destination = location.appendingPathComponent(bottle.lastPathComponent, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw MoveError.nameTaken(bottle.lastPathComponent) }
        do {
            try fm.moveItem(at: bottle, to: destination)
        } catch {
            // Across disks a failed copy leaves part of it behind; the original is untouched until the copy is done.
            if fm.fileExists(atPath: bottle.path) { try? fm.removeItem(at: destination) }
            throw error
        }
        rewritePaths(from: bottle.path, to: destination.path)
        return destination
    }

    /// Library IDs start with the container's path and a "|" and hold the program's path in it; store records hold
    /// paths inside it. Categories and some records are JSON from Swift's encoder, which escapes slashes.
    private static func rewritePaths(from old: String, to new: String) {
        func both(_ a: String, _ b: String) -> [(String, String)] {
            [(a, b), (a.replacingOccurrences(of: "/", with: "\\/"), b.replacingOccurrences(of: "/", with: "\\/"))]
        }
        func rewrite(_ text: String, _ pairs: [(String, String)]) -> String {
            pairs.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
        let defaults = UserDefaults.standard
        let ids = both(old + "|", new + "|") + both(old + "/", new + "/")
        for key in [ViewOptions.favoritesKey, ViewOptions.categoriesKey, RecentTitles.key] {
            if let text = defaults.string(forKey: key) {
                defaults.set(rewrite(text, ids), forKey: key)
            } else if let list = defaults.stringArray(forKey: key) {
                defaults.set(list.map { rewrite($0, ids) }, forKey: key)
            }
        }
        let stores = Bottle.bottlesDirectory().deletingLastPathComponent().appendingPathComponent("Stores")
        let paths = both(old + "/", new + "/")
        for store in (try? FileManager.default.contentsOfDirectory(at: stores, includingPropertiesForKeys: nil)) ?? [] {
            let file = store.appendingPathComponent("installed.json")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let updated = rewrite(text, paths)
            if updated != text { try? updated.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    enum MoveError: LocalizedError {
        case nameTaken(String)
        var errorDescription: String? {
            switch self {
            case .nameTaken(let name): "That location already has a container named “\(name)”."
            }
        }
    }
}
