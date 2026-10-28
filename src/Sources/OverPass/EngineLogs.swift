import Foundation

// What a game's engine writes about itself, for a report: the engine is told from the files in the game's folder,
// and its own logs and crash reports are copied next to Wine's log (the ends of long logs, the newest crashes).
// Logs any program leaves (*.log in its folder, Windows' crash dumps) are taken too.
enum EngineLogs {
    /// The end of each log that goes in; crash dumps up to `dumpLimit` go in whole.
    private static let tail = 4 << 20
    private static let dumpLimit = 16 << 20

    enum Engine: String {
        case unity = "Unity", unreal = "Unreal Engine", godot = "Godot", renpy = "Ren'Py", source = "Source",
             cryengine = "CryEngine", gamemaker = "GameMaker", unknown = "not recognised"
    }

    // Read and filled while the library draws, on the main thread.
    nonisolated(unsafe) private static var detected: [URL: Engine] = [:]

    /// The engine's name for the library, looked for once per folder; "Unknown" when the files don't tell.
    static func name(of folder: URL?) -> String {
        guard let folder else { return "Unknown" }
        let engine = detected[folder] ?? detect(folder)
        detected[folder] = engine
        return engine == .unknown ? "Unknown" : engine.rawValue
    }

    static func detect(_ folder: URL) -> Engine {
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        if names.contains("unityplayer.dll") || names.contains(where: { $0.hasSuffix("_data") }) { return .unity }
        if names.contains("engine") || unrealProject(in: folder) != nil { return .unreal }
        if names.contains(where: { $0.hasSuffix(".pck") }) { return .godot }
        if names.contains("renpy") { return .renpy }
        if names.contains("hl2.exe") || names.contains("bin") && names.contains(where: { $0.hasSuffix(".vpk") }) { return .source }
        if names.contains("game.log") || names.contains("system.cfg") { return .cryengine }
        if names.contains("data.win") { return .gamemaker }
        return .unknown
    }

    /// Copies what's relevant into `folder` and writes engine.txt saying what was found.
    static func collect(installFolder: URL?, bottle: Bottle, into folder: URL) {
        var found: [String] = []
        func take(_ url: URL, as name: String) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let destination = folder.appendingPathComponent("engine – " + name)
            if url.pathExtension.lowercased() == "dmp" {
                guard size <= dumpLimit else { found.append("\(name) (left out: \(size >> 20) MB)"); return }
                try? FileManager.default.copyItem(at: url, to: destination)
            } else {
                copyTail(of: url, to: destination)
            }
            found.append(name)
        }
        let users = (try? FileManager.default.contentsOfDirectory(at: bottle.driveC.appendingPathComponent("users"),
                                                                    includingPropertiesForKeys: nil)) ?? []
        let engine = installFolder.map(detect) ?? .unknown

        if let install = installFolder {
            switch engine {
            case .unity:
                // <Game>_Data/app.info holds the company and product names Unity's folders are named after.
                let data = (try? FileManager.default.contentsOfDirectory(at: install, includingPropertiesForKeys: nil))?
                    .first { $0.lastPathComponent.lowercased().hasSuffix("_data") }
                let info = data.flatMap { try? String(contentsOf: $0.appendingPathComponent("app.info"), encoding: .utf8) }?
                    .components(separatedBy: .newlines)
                if let info, info.count >= 2 {
                    for user in users {
                        let dir = user.appendingPathComponent("AppData/LocalLow/\(info[0])/\(info[1])")
                        for log in ["Player.log", "Player-prev.log"] where exists(dir.appendingPathComponent(log)) {
                            take(dir.appendingPathComponent(log), as: log)
                        }
                        newestCrash(in: user.appendingPathComponent("AppData/Local/Temp/\(info[0])/\(info[1])/Crashes"), take: take)
                    }
                }
            case .unreal:
                if let project = unrealProject(in: install) {
                    let saved = [install.appendingPathComponent("\(project)/Saved")]
                        + users.map { $0.appendingPathComponent("AppData/Local/\(project)/Saved") }
                    for dir in saved {
                        for log in newest(in: dir.appendingPathComponent("Logs"), ext: "log", count: 2) {
                            take(log, as: "Saved/Logs/" + log.lastPathComponent)
                        }
                        newestCrash(in: dir.appendingPathComponent("Crashes"), take: take)
                    }
                }
            case .godot:
                for user in users {
                    let base = user.appendingPathComponent("AppData/Roaming/Godot/app_userdata")
                    for app in newest(in: base, ext: nil, count: 1) {
                        for log in newest(in: app.appendingPathComponent("logs"), ext: "log", count: 2) {
                            take(log, as: "godot/" + log.lastPathComponent)
                        }
                    }
                }
            case .renpy:
                for name in ["log.txt", "traceback.txt", "errors.txt"] where exists(install.appendingPathComponent(name)) {
                    take(install.appendingPathComponent(name), as: name)
                }
            case .cryengine, .source, .gamemaker, .unknown:
                break
            }
            // Logs any program keeps beside itself, written in the last two days.
            for log in newest(in: install, ext: "log", count: 3) where modifiedRecently(log) {
                take(log, as: log.lastPathComponent)
            }
            for dump in newest(in: install, ext: "dmp", count: 1) where modifiedRecently(dump) {
                take(dump, as: dump.lastPathComponent)
            }
        }
        // Windows' own crash dumps.
        for user in users {
            for dump in newest(in: user.appendingPathComponent("AppData/Local/CrashDumps"), ext: "dmp", count: 1)
                where modifiedRecently(dump) {
                take(dump, as: "CrashDumps/" + dump.lastPathComponent)
            }
        }
        let summary = ["Engine: \(engine.rawValue)", "Files: " + (found.isEmpty ? "none found" : found.joined(separator: ", "))]
        try? summary.joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent("engine.txt"),
                                                                    atomically: true, encoding: .utf8)
    }

    /// The Unreal project folder: the one with Content/Paks beside Engine.
    private static func unrealProject(in folder: URL) -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).first {
            $0 != "Engine" && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0)/Content/Paks").path)
        }
    }

    /// The newest crash folder's files: Unreal's CrashContext and logs, Unity's error.log and dump.
    private static func newestCrash(in folder: URL, take: (URL, String) -> Void) {
        guard let crash = newest(in: folder, ext: nil, count: 1).first, modifiedRecently(crash) else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: crash, includingPropertiesForKeys: nil)) ?? [] {
            take(file, "Crashes/\(crash.lastPathComponent)/\(file.lastPathComponent)")
        }
    }

    private static func newest(in folder: URL, ext: String?, count: Int) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ext == nil ? $0.hasDirectoryPath : $0.pathExtension.lowercased() == ext }
            .sorted { LogCollector.modified($0) > LogCollector.modified($1) }
            .prefix(count).map { $0 }
    }

    private static func modifiedRecently(_ url: URL) -> Bool { Date.now.timeIntervalSince(LogCollector.modified(url)) < 2 * 86_400 }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func copyTail(of file: URL, to copy: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
        try? handle.readToEnd()?.write(to: copy)
    }
}
