import Foundation

// A bottle's drive letters are links in its dosdevices folder. Wine makes c: (the bottle's own disk) and z: (the
// whole Mac), and adds a letter for every disk image or volume mounted while the bottle runs; when one is ejected
// while the bottle isn't running, its letter stays behind, pointing at nothing. OverPass adds y: for the home
// folder, as CrossOver does, clears those leftovers before a program starts, and hides z: from Explorer and file
// dialogs unless the person wants it (programs can still use z: paths).
enum ContainerDrives {
    /// Puts y: in place and removes letters left by volumes that are gone. Only while nothing runs in the bottle:
    /// a running Wine adds and removes volume letters itself.
    static func tidy(_ bottle: Bottle) {
        let fm = FileManager.default
        let devices = bottle.path.appendingPathComponent("dosdevices")
        guard let names = try? fm.contentsOfDirectory(atPath: devices.path) else { return }
        func target(_ name: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: devices.appendingPathComponent(name).path) }

        if !names.contains("y:") {
            try? fm.createSymbolicLink(atPath: devices.appendingPathComponent("y:").path,
                                       withDestinationPath: fm.homeDirectoryForCurrentUser.path)
        }
        for name in names where name.count == 2 && name.hasSuffix(":") {
            guard let path = target(name), path.hasPrefix("/Volumes/"), !fm.fileExists(atPath: path) else { continue }
            try? fm.removeItem(at: devices.appendingPathComponent(name))
            try? fm.removeItem(at: devices.appendingPathComponent(name + ":"))
        }
        // A raw device link ("f::") without its drive is a disk that has gone; its number may belong to another disk now.
        for name in names where name.count == 3 && name.hasSuffix("::") && target(String(name.dropLast())) == nil {
            try? fm.removeItem(at: devices.appendingPathComponent(name))
        }
    }

    private static let policyKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer"
    /// NoDrives has a bit per letter, A first.
    static let hideZ = 1 << 25

    /// The NoDrives lines the bottle defaults carry.
    static func registryLines(showingMacDisk shown: Bool) -> [String] {
        ["", "[HKEY_CURRENT_USER\\" + policyKey + "]", "\"NoDrives\"=dword:" + String(format: "%08x", shown ? 0 : hideZ)]
    }

    /// Whether z: shows in Explorer and file dialogs; nil when the bottle doesn't say (Wine shows it then).
    static func showsMacDisk(in bottle: Bottle) -> Bool? {
        guard let value = BottleSetup.registryValue("NoDrives", key: policyKey, file: "user.reg", in: bottle),
              let bits = Int(value.replacingOccurrences(of: "dword:", with: ""), radix: 16) else { return nil }
        return bits & hideZ == 0
    }

    @MainActor
    static func setShowsMacDisk(_ shown: Bool, in bottle: Bottle, using manager: BottleManager) async throws {
        let status = try await manager.run(["reg", "add", "HKCU\\" + policyKey, "/v", "NoDrives", "/t", "REG_DWORD",
                                            "/d", shown ? "0" : String(hideZ), "/f"], in: bottle)
        guard status == 0 else { throw BottleSetup.DefaultsError.importFailed(status) }
    }
}
