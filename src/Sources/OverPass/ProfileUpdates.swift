import CryptoKit
import Foundation

// Profiles between app releases. The whole of profiles/ is published as one signed set (publish-profiles.mjs); a set
// that's signed and newer than both the bundled copy and the last set replaces the bundled copy for everything, so
// it can also take a profile away. Profiles can set what a program runs with, so the signature is the point: the
// key is only on GitHub, and the site that hands the set out can't make one. The serial is the time of the last change
// to profiles/, and build-app.sh stamps the same on the bundled copy.
enum ProfileUpdates {
    static let url = URL(string: "https://overpass.arctim.no/api/profiles")!

    nonisolated static var directory: URL { UserProfiles.support.appendingPathComponent("Profile Updates") }
    private nonisolated static let serialFile = "serial"

    struct ProfileSet: Decodable {
        let format: Int
        let serial: Int
        let commit: String
        let files: [String: String]
    }

    private struct Signed: Decodable {
        let payload: String
        let signature: String
    }

    nonisolated static func serial(of folder: URL?) -> Int {
        guard let folder, let text = try? String(contentsOf: folder.appendingPathComponent(serialFile), encoding: .utf8) else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private nonisolated static func isProfileName(_ name: String) -> Bool {
        let folders = name.split(separator: "/", omittingEmptySubsequences: false)
        guard folders.count == 1 || (folders.count == 2 && folders[0] == "Presets"), let file = folders.last else { return false }
        return file.hasSuffix(".ini") && !file.hasPrefix(".") && file.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The set in a download, if `key` signed it. A name that isn't a plain profile or preset file throws the set out.
    nonisolated static func verified(_ data: Data, key: String) -> ProfileSet? {
        guard let keyData = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signed = try? JSONDecoder().decode(Signed.self, from: data),
              let signature = Data(base64Encoded: signed.signature),
              publicKey.isValidSignature(signature, for: Data(signed.payload.utf8)),
              let set = try? JSONDecoder().decode(ProfileSet.self, from: Data(signed.payload.utf8)),
              set.format == 1, !set.files.isEmpty,
              set.files.keys.allSatisfy(isProfileName)
        else { return nil }
        return set
    }

    /// Replaces the folder with the set; the serial goes in last, so a half-written set never counts.
    nonisolated static func install(_ set: ProfileSet, in directory: URL) throws {
        let fm = FileManager.default
        let new = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + " New")
        try? fm.removeItem(at: new)
        try fm.createDirectory(at: new.appendingPathComponent("Presets"), withIntermediateDirectories: true)
        for (name, text) in set.files {
            try text.write(to: new.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        try String(set.serial).write(to: new.appendingPathComponent(serialFile), atomically: false, encoding: .utf8)
        try? fm.removeItem(at: directory)
        try fm.moveItem(at: new, to: directory)
    }

    /// Fetches the newest set; true when it took one, so the profiles need reading again.
    static func refresh() async -> Bool {
        guard !ProfilesKey.publicKey.isEmpty,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let set = verified(data, key: ProfilesKey.publicKey),
              set.serial > max(serial(of: directory), serial(of: ProfileStore.shippedDirectory)) else { return false }
        return (try? install(set, in: directory)) != nil
    }
}
