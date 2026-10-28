import Foundation

// A container exported to one file: a gzip tar with the container's folder at its top. Import unpacks into a temporary folder on the location's disk (the
// last step is then a rename, and a half-unpacked container never shows in the library), gives the container a new
// ID and a name no other container has, and points y: at this Mac's home folder.
enum ContainerArchive {
    /// Writes the container folder `bottle` to `archive`. Nothing may run in it.
    nonisolated static func export(_ bottle: URL, to archive: URL) throws {
        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
        do {
            try tar(["-czf", archive.path, "-C", bottle.deletingLastPathComponent().path, bottle.lastPathComponent])
        } catch {
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
    }

    /// Unpacks `archive` next to `location` and returns the container folder in it and the name it had. The caller
    /// moves it into place with `place(_:as:in:)`; until then it sits in a temporary folder.
    nonisolated static func unpack(_ archive: URL, near location: URL) throws -> (folder: URL, name: String) {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: location, create: true)
        do {
            // bsdtar finds the compression itself, and without -P keeps every entry inside the folder.
            try tar(["-xf", archive.path, "-C", staging.path])
            if BottleConfig.exists(in: staging) {
                // An archive without a top folder: the container is named after the file.
                let name = archive.lastPathComponent.components(separatedBy: ".").first ?? "Imported"
                let folder = staging.appendingPathComponent(name)
                let inner = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                for item in inner { try fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent)) }
                return (folder, name)
            }
            let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            guard entries.count == 1, let folder = entries.first,
                  BottleConfig.exists(in: folder) else {
                throw ArchiveError.noContainer(archive.lastPathComponent)
            }
            return (folder, folder.lastPathComponent)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Moves an unpacked container into `location` as `name`, with its own ID and y: on this Mac's home, and
    /// removes the temporary folder it came in.
    nonisolated static func place(_ folder: URL, as name: String, in location: URL) throws -> URL {
        let fm = FileManager.default
        let destination = location.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: location, withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: destination)
        try? fm.removeItem(at: folder.deletingLastPathComponent())

        // Bottle IDs tell containers apart in the library, so the same archive imported twice needs two.
        BottleConfig.migrate(in: destination)
        let configURL = destination.appendingPathComponent(Bottle.configName)
        var config = BottleConfig.parse(configURL)
        config["Container", default: [:]]["ID"] = UUID().uuidString
        config["Container", default: [:]]["Description"] = name
        try BottleConfig.write(config, to: configURL)

        let home = fm.homeDirectoryForCurrentUser.path
        let y = destination.appendingPathComponent("dosdevices/y:").path
        if let target = try? fm.destinationOfSymbolicLink(atPath: y), target != home {
            try? fm.removeItem(atPath: y)
            try? fm.createSymbolicLink(atPath: y, withDestinationPath: home)
        }
        return destination
    }

    nonisolated private static func tar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: "\n")
            throw ArchiveError.tar(text.isEmpty ? "tar exited with status \(process.terminationStatus)" : text)
        }
    }

    enum ArchiveError: LocalizedError {
        case noContainer(String)
        case tar(String)
        var errorDescription: String? {
            switch self {
            case .noContainer(let file): "“\(file)” doesn't hold a container."
            case .tar(let message): message
            }
        }
    }
}
