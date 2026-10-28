import AppKit
import SwiftUI

/// Downloaded and extracted pictures, by service and kind, in ~/Library/Caches/OverPass/Media:
/// `Steam/Covers`, `GOG/Covers`, `GOG/Icons`, `Epic/Covers`, `Epic/Icons`, `Windows/Icons` (icons pulled out of
/// programs) and so on. Everything here can be downloaded or made again; pictures people choose themselves live
/// with their profiles in Application Support instead.
enum MediaCache {
    nonisolated static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OverPass/Media", isDirectory: true)
    }

    enum Kind: String { case covers = "Covers", icons = "Icons" }

    nonisolated static func folder(_ service: String, _ kind: Kind) -> URL {
        root.appendingPathComponent(service, isDirectory: true).appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// The file for one picture: `<service>/<kind>/<id>.<ext>`.
    nonisolated static func file(_ service: String, _ kind: Kind, id: String, ext: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return folder(service, kind).appendingPathComponent(String(safe) + "." + ext)
    }

    @MainActor private static let memory = NSCache<NSURL, NSImage>()
    @MainActor private static var loading: [URL: Task<NSImage?, Never>] = [:]

    /// The picture at `remote`, from the cache file when it's there, else downloaded once into it.
    @MainActor
    static func image(_ remote: URL, service: String, kind: Kind, id: String) async -> NSImage? {
        let ext = ["png", "jpg", "jpeg", "webp"].first { remote.path.lowercased().hasSuffix($0) } ?? "jpg"
        let local = file(service, kind, id: id, ext: ext)
        if let image = memory.object(forKey: local as NSURL) { return image }
        if let task = loading[local] { return await task.value }
        let task = Task<NSImage?, Never> {
            if let image = NSImage(contentsOf: local) { return image }
            guard let (data, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: local, options: .atomic)
            return image
        }
        loading[local] = task
        let image = await task.value
        loading[local] = nil
        if let image { memory.setObject(image, forKey: local as NSURL) }
        return image
    }

    /// Moves pictures from the folders older versions used (Caches/OverPass/Covers and Icons) into Media.
    nonisolated static func migrate() {
        let fm = FileManager.default
        let caches = root.deletingLastPathComponent()
        let services = ["steam": "Steam", "gog": "GOG", "epic": "Epic"]
        let oldCovers = caches.appendingPathComponent("Covers")
        for name in (try? fm.contentsOfDirectory(atPath: oldCovers.path)) ?? [] {
            guard let dash = name.firstIndex(of: "-"), let service = services[String(name[..<dash])] else { continue }
            let dest = folder(service, .covers)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try? fm.moveItem(at: oldCovers.appendingPathComponent(name),
                             to: dest.appendingPathComponent(String(name[name.index(after: dash)...])))
        }
        try? fm.removeItem(at: oldCovers)
        let oldIcons = caches.appendingPathComponent("Icons")
        if fm.fileExists(atPath: oldIcons.path), !fm.fileExists(atPath: folder("Windows", .icons).path) {
            try? fm.createDirectory(at: root.appendingPathComponent("Windows"), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldIcons, to: folder("Windows", .icons))
        }
        try? fm.removeItem(at: oldIcons)
    }
}

/// A store picture through the media cache, with a placeholder while it loads or when there is none.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    let service: String
    let kind: MediaCache.Kind
    let id: String
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await MediaCache.image(url, service: service, kind: kind, id: id)
        }
    }
}
