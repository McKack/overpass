import Foundation

// Which games use an anti-cheat, so OverPass can say so on the tile and before the first start. It never stops a
// game from starting. It comes from the [anti-cheat] section of the profiles, which sync-anticheat.mjs fills from
// AreWeAntiCheatYet (areweanticheatyet.com, MIT), matched by Steam app ID, then by title (Epic, GOG and installed
// games). A game the profiles don't have is still caught by Detection, from the anti-cheat files it ships.
@MainActor
enum AntiCheat {
    struct Info: Equatable {
        var names: [String]
        /// Can't run on a Mac at all: a kernel-level anti-cheat, or the developer refuses Wine and Proton.
        var blocked = false
        /// Where it came from, for the warning text.
        var fromDatabase: Bool
        /// AreWeAntiCheatYet's status: how the game does on Linux.
        var status: String?
    }

    /// Anti-cheats that need a Windows kernel driver; Highball found these never run on macOS.
    nonisolated private static let kernelOnly: Set<String> = ["EA anticheat", "EA Javelin", "Vanguard", "Ricochet", "Denuvo Anti-Cheat"]
    private static let acknowledgedKey = "antiCheatAcknowledged"

    private static var list: (bySteamID: [String: Info], byTitle: [String: Info]) = ([:], [:])

    /// The anti-cheat a title uses, if any is known.
    static func info(for item: LibraryItem) -> Info? {
        if item.app.launcher == "Steam", let id = item.app.storeID, let info = list.bySteamID[id] { return info }
        if let info = list.byTitle[titleKey(item.app.name)] { return info }
        guard let names = Detection.result(for: item)?.antiCheats.map(Detection.displayName), !names.isEmpty else { return nil }
        return Info(names: names, blocked: names.contains(where: kernelOnly.contains), fromDatabase: false)
    }

    /// Titles compared without case, punctuation or trademark signs ("Halo: The Master Chief Collection").
    nonisolated private static func titleKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    /// Fills the list from the text of every profile.
    static func read(_ profiles: [String]) {
        var bySteamID: [String: Info] = [:], byTitle: [String: Info] = [:]
        for text in profiles where text.contains("[anti-cheat]") {
            var section = "", names: [String] = [], status: String?, steam: String?, title: String?
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()).lowercased(); continue }
                guard !line.hasPrefix("#"), !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                switch (section, key) {
                case ("anti-cheat", "uses"): names.append(value)
                case ("anti-cheat", "status"): status = value
                case ("anti-cheat", "game"): title = value
                case ("store", "steam"), ("app", "steam-app"): steam = steam ?? value
                default: break
                }
            }
            guard !names.isEmpty else { continue }
            let info = Info(names: names, blocked: status == "Denied" || names.contains(where: kernelOnly.contains), fromDatabase: true, status: status)
            if let steam { bySteamID[steam] = info }
            if let title, !titleKey(title).isEmpty { byTitle[titleKey(title)] = info }
        }
        list = (bySteamID, byTitle)
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
            + "games ban accounts for it. Offline play usually works." + however(info.status)
    }

    /// The same words as the game's page on the site.
    private static func however(_ status: String?) -> String {
        switch status {
        case "Supported":
            return "\n\nHowever, it's listed as working on Linux with the developer's approval, and Linux runs it through "
                + "Wine or Proton too. That can make it less risky, but not risk free: only the developer can promise you "
                + "won't be banned for playing under Wine."
        case "Running":
            return "\n\nHowever, it's listed as running on Linux through Wine or Proton, without the developer's word on it. "
                + "That can make it less risky, but not risk free, and how it does on a Mac is unknown."
        case "Planned":
            return "\n\nThe developer plans Linux support, but it isn't listed as working yet, so how it does on a Mac is unknown."
        case "Broken":
            return "\n\nIt's also listed as not working on Linux through Wine or Proton, so expect the same on a Mac. "
                + "That's about the anti-cheat: the game itself may still run."
        default:
            return ""
        }
    }
}
