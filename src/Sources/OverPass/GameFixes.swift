import Foundation

// Fixes for single games, from MacGameFix (Mathias Kowoll, GPL-3.0): mostly a proxy DLL that takes the place of
// one the game ships and forwards to it, plus a script that installs it into the game folder, reports its state
// (--status) and puts the game's own file back (--restore). A game's profile names its fixes in [app]:
//
//   fix = gow-fix dxmt          the fix (install-gow-fix.sh) and the backend it was measured on: dxmt, d3dmetal,
//                               dxvk, or any
//
// Before the game starts, OverPass puts each fix in place when the game runs on that backend, and restores the
// game's own files when it doesn't, so changing the backend never leaves a fix behind that wasn't made for it.
// The scripts only touch the game folder; the ones that need a CrossOver bottle aren't used.
enum GameFixes {
    struct Fix: Equatable {
        /// The script's name without "install-" and ".sh".
        var name: String
        /// nil: on any backend.
        var backend: GraphicsBackend?
    }

    /// A game a fix serves, from the script's MGVF-GAME lines: name | executable | carrier folder.
    struct Game {
        var executable: String
        /// Where the carrier DLL sits, relative to the game folder; empty for the folder itself.
        var carrierDir: String
    }

    nonisolated static var directory: URL { ComponentManager.gameFixesDir.appendingPathComponent("fixes") }

    /// "gow-fix dxmt" -> the fix and its backend; nil for anything else.
    static func parse(_ value: String) -> Fix? {
        let parts = value.split(separator: " ").map(String.init)
        guard let name = parts.first, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let backend = parts.count > 1 && parts[1].lowercased() != "any" ? GraphicsBackend(rawValue: parts[1].lowercased()) : nil
        if parts.count > 1, parts[1].lowercased() != "any", backend == nil { return nil }
        return Fix(name: name, backend: backend)
    }

    static func script(_ fix: Fix) -> URL { directory.appendingPathComponent("install-\(fix.name).sh") }

    /// The games a fix's script serves; empty when it isn't a game-folder fix this works with.
    static func games(_ fix: Fix) -> [Game] {
        guard let text = try? String(contentsOf: script(fix), encoding: .utf8),
              text.contains("# MGVF-SCOPE: folder"),
              // Fixes that copy from or write into a CrossOver bottle don't fit OverPass containers.
              !text.contains("bottles.sh"), !text.contains("MGVF_BOTTLE"), !text.contains("MGVF_CX") else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("# MGVF-GAME:") else { return nil }
            let fields = line.dropFirst("# MGVF-GAME:".count).split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, !fields[1].isEmpty else { return nil }
            return Game(executable: fields[1], carrierDir: fields.count > 2 ? fields[2] : "")
        }
    }

    /// The folder the script takes, found from anywhere inside the game's install (its executable, or the
    /// store's install folder). As MacGameFix decides it: the folder holding the executable through the carrier
    /// folder, the one above Unreal's <Project>/Binaries/Win64, or the executable's own folder.
    static func gameFolder(for games: [Game], near anchor: URL) -> URL? {
        let fm = FileManager.default
        let root = installRoot(of: anchor)
        for game in games {
            guard let exe = find(game.executable, under: root) else { continue }
            var ancestors: [URL] = []
            var dir = exe.deletingLastPathComponent()
            while dir.path.count >= root.path.count {
                ancestors.append(dir)
                dir = dir.deletingLastPathComponent()
            }
            if !game.carrierDir.isEmpty, let folder = ancestors.first(where: {
                fm.fileExists(atPath: $0.appendingPathComponent(game.carrierDir).appendingPathComponent(game.executable).path)
            }) { return folder }
            if exe.deletingLastPathComponent().path.hasSuffix("/Binaries/Win64"), ancestors.count > 3 { return ancestors[3] }
            return exe.deletingLastPathComponent()
        }
        return nil
    }

    /// The store's folder for the game (steamapps/common/<game>, GOG Games/<game>, Epic Games/<game>), or the
    /// anchor's own folder.
    private static func installRoot(of anchor: URL) -> URL {
        let parts = anchor.standardizedFileURL.pathComponents
        for (i, part) in parts.enumerated() where i + 1 < parts.count {
            let lower = part.lowercased()
            if lower == "common" && i > 0 && parts[i - 1].lowercased() == "steamapps" || lower == "gog games" || lower == "epic games" {
                return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...(i + 1)])))
            }
        }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: anchor.path, isDirectory: &isDir) && isDir.boolValue
            ? anchor : anchor.deletingLastPathComponent()
    }

    /// A file by name (any case), at most six folders down.
    private static func find(_ name: String, under root: URL) -> URL? {
        let rootDepth = root.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker {
            if url.pathComponents.count - rootDepth > 6 { walker.skipDescendants(); continue }
            if url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame { return url }
        }
        return nil
    }

    /// Before a game starts: puts each fix in place when the game runs on its backend and restores the game's
    /// own files otherwise. Returns what went wrong, if anything; the game starts either way.
    static func prepare(_ values: [String], near anchor: URL, backend: GraphicsBackend, name: String) async -> String? {
        let fixes = values.compactMap(parse)
        guard !fixes.isEmpty else { return nil }
        var problems: [String] = []
        for fix in fixes {
            let wanted = fix.backend == nil || fix.backend == backend
            if !FileManager.default.fileExists(atPath: script(fix).path) {
                // Nothing to restore without the scripts, and nothing to install on another backend.
                guard wanted else { continue }
                await ComponentManager.current?.install(.gamefixes)
                guard FileManager.default.fileExists(atPath: script(fix).path) else {
                    problems.append("the Game fixes component couldn't be installed"); break
                }
            }
            let games = games(fix)
            guard !games.isEmpty, let folder = gameFolder(for: games, near: anchor) else {
                if wanted { problems.append("\(fix.name): the game's files weren't found") }
                continue
            }
            // Notes on stderr come in the same output, so the state is the line that is one of these.
            let states: Set<String> = ["installed", "outdated", "broken", "half", "absent"]
            let status = (try? await run(fix, folder, "--status", statusOnly: true))?
                .split(separator: "\n").map(String.init).first(where: states.contains) ?? ""
            do {
                if wanted && status != "installed" {
                    log(try await run(fix, folder, nil), fix: fix, game: name)
                } else if !wanted && status != "absent" {
                    log(try await run(fix, folder, "--restore"), fix: fix, game: name)
                }
            } catch {
                log(error.localizedDescription, fix: fix, game: name)
                problems.append("\(fix.name): \(error.localizedDescription)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Runs a fix's script on the game folder; no mode installs (not every script takes --install).
    private static func run(_ fix: Fix, _ folder: URL, _ mode: String?, statusOnly: Bool = false) async throws -> String {
        // MGVF_STATUS_ONLY makes the script report even if the mode were lost on the way.
        var args = ["MGVF_STATUS_ONLY=\(statusOnly ? 1 : 0)", "/bin/bash", script(fix).path, folder.path]
        if let mode { args.append(mode) }
        return try await WineInstaller.run("/usr/bin/env", args)
    }

    /// What each install or restore printed, kept with OverPass's logs.
    private static func log(_ text: String, fix: Fix, game: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OverPass/game-fixes.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = "\(Date.now.formatted(.iso8601)) \(game), \(fix.name):\n\(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
