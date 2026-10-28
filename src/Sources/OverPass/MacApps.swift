import AppKit
import UniformTypeIdentifiers

extension Bottle {
    /// A stand-in bottle for Mac apps added to the library, so favorites, categories and every layout treat
    /// them like the rest. Nothing of it is on disk.
    static let mac = Bottle(id: UUID(uuidString: "6D616300-0000-4000-8000-000000000001")!, name: "macOS",
                            path: URL(fileURLWithPath: "/Applications"), template: .windows11, wineArch: "",
                            description: "Mac apps added to the library", apps: [])

    var isMac: Bool { id == Bottle.mac.id }
}

/// Mac games and apps added to the library, so OverPass is one place to start every game. Kept as their
/// paths in the `macApps` default, one per line.
enum MacApps {
    static let key = "macApps"

    static func paths() -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
    }

    static func save(_ paths: [String]) {
        UserDefaults.standard.set(paths.joined(separator: "\n"), forKey: key)
    }

    /// Library entries for the added apps that are still there.
    static func apps(_ paths: [String]) -> [WineApp] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }.map { path in
            WineApp(name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                    executable: path, launcher: "Mac")
        }
    }

    /// Asks for apps to add, starting in /Applications.
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose Mac games or apps to add to the library."
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func open(_ app: WineApp) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.executable),
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't Open \(app.name)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// The app's own icon as a PNG in the icon cache, so covers can blur it like a Windows program's icon.
    static func iconFile(_ path: String) -> URL? {
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let folder = MediaCache.folder("Mac", .icons)
        let file = folder.appendingPathComponent(WindowsIcons.stableHash("\(path)|\(Int(mtime))") + ".png")
        if fm.fileExists(atPath: file.path) { return file }
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? png.write(to: file)) != nil ? file : nil
    }
}
