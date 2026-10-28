import Foundation

// Which games use an anti-cheat, so OverPass can say so on the tile and before the first start. It never stops a
// game from starting. The list is AreWeAntiCheatYet's (areweanticheatyet.com, MIT), downloaded once a day and
// matched by Steam app ID, then by title (Epic, GOG and installed games). A game the list doesn't have is still
// caught by the anti-cheat folders and launchers it ships next to its program.
@MainActor
enum AntiCheat {
    struct Info: Equatable {
        var names: [String]
        /// Can't run on a Mac at all: a kernel-level anti-cheat, or the developer refuses Wine and Proton.
        var blocked = false
        /// Where it came from, for the warning text.
        var fromDatabase: Bool
    }

    static let listURL = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json")!
    /// Anti-cheats that need a Windows kernel driver; Highball found these never run on macOS.
    nonisolated private static let kernelOnly: Set<String> = ["EA anticheat", "EA Javelin", "Vanguard", "Ricochet", "Denuvo Anti-Cheat"]
    private static let acknowledgedKey = "antiCheatAcknowledged"

    nonisolated static var cacheURL: URL {
        Bottle.bottlesDirectory().deletingLastPathComponent().appendingPathComponent("AntiCheat/games.json")
    }

    private static var list = parse((try? Data(contentsOf: cacheURL)) ?? Data())
    private static var scanned: [String: Info?] = [:]

    /// The anti-cheat a title uses, if any is known.
    static func info(for item: LibraryItem) -> Info? {
        if item.app.launcher == "Steam", let id = item.app.storeID, let info = list.bySteamID[id] { return info }
        if let info = list.byTitle[titleKey(item.app.name)] { return info }
        guard let target = item.app.target else { return nil }
        let folder = BottleManager.hostPath(target, in: item.bottle).deletingLastPathComponent()
        if let cached = scanned[folder.path] { return cached }
        let found = scan(folder)
        scanned[folder.path] = found
        return found
    }

    /// Anti-cheats install a folder or a launcher next to the game (or one folder up, for games in a bin folder).
    private static func scan(_ folder: URL) -> Info? {
        let marks: [(String, String)] = [("easyanticheat", "Easy Anti-Cheat"), ("easyanticheat_eos", "Easy Anti-Cheat"),
                                         ("start_protected_game.exe", "Easy Anti-Cheat"), ("battleye", "BattlEye"),
                                         ("beservice.exe", "BattlEye"), ("beservice_x64.exe", "BattlEye")]
        var names: [String] = []
        for dir in [folder, folder.deletingLastPathComponent()] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for entry in entries.map({ $0.lowercased() }) {
                for (mark, name) in marks where (entry == mark || entry.hasPrefix(mark + "_")) && !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names.isEmpty ? nil : Info(names: names, fromDatabase: false)
    }

    /// Titles compared without case, punctuation or trademark signs ("Halo: The Master Chief Collection").
    nonisolated private static func titleKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    nonisolated private static func parse(_ data: Data) -> (bySteamID: [String: Info], byTitle: [String: Info]) {
        guard let games = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([:], [:]) }
        var bySteamID: [String: Info] = [:], byTitle: [String: Info] = [:]
        for game in games {
            guard let names = game["anticheats"] as? [String], !names.isEmpty else { continue }
            let info = Info(names: names, blocked: game["status"] as? String == "Denied" || names.contains(where: kernelOnly.contains),
                            fromDatabase: true)
            if let steam = (game["storeIds"] as? [String: Any])?["steam"] as? String { bySteamID[steam] = info }
            if let name = game["name"] as? String, !titleKey(name).isEmpty { byTitle[titleKey(name)] = info }
        }
        return (bySteamID, byTitle)
    }

    /// Downloads the list when the cached copy is older than a day.
    static func refresh() async {
        let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard (modified.map { Date.now.timeIntervalSince($0) } ?? .infinity) > 86_400,
              let (data, response) = try? await URLSession.shared.data(from: listURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let parsed = parse(data)
        guard !parsed.byTitle.isEmpty else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
        list = parsed
        scanned = [:]
        // The list used to come through Highball's database.
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Highball"))
    }

    static func isAcknowledged(_ item: LibraryItem) -> Bool {
        (UserDefaults.standard.stringArray(forKey: acknowledgedKey) ?? []).contains(item.id)
    }

    static func acknowledge(_ item: LibraryItem) {
        let list = UserDefaults.standard.stringArray(forKey: acknowledgedKey) ?? []
        if !list.contains(item.id) { UserDefaults.standard.set(list + [item.id], forKey: acknowledgedKey) }
    }

    /// The warning shown before a title with an anti-cheat starts.
    static func warning(_ info: Info, for name: String) -> String {
        let names = ListFormatter.localizedString(byJoining: info.names)
        let source = info.fromDatabase ? "AreWeAntiCheatYet lists \(names) for “\(name)”."
            : "“\(name)” comes with \(names)."
        if info.blocked {
            return source + " This anti-cheat doesn't run on a Mac at all, so the game most likely won't get past it, "
                + "and trying could flag your account."
        }
        return source + " Anti-cheats often refuse to run under Wine on a Mac; online play may not work, and some "
            + "games ban accounts for it. Offline play usually works."
    }
}
