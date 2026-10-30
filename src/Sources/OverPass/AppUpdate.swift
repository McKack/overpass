import Foundation
import AppKit

// Updates for OverPass itself. Releases are GitHub releases with the zipped app attached, looked for first in
// OverPass's own repo and then in McKack/overpass-releases, where releases up to 0.3.2 were published.
// OverPass 0.3.0 and older look for an asset named "OverPass…zip" (case-sensitive) and accept only their old
// bundle ID, so the own repo's assets are named "overpass-<version>.zip": those versions skip it and find 0.3.2
// in overpass-releases, which takes them over to the new ID. Never attach an "OverPass…zip" there.
// The update is downloaded by the app, so macOS doesn't quarantine it and Gatekeeper doesn't ask again.
@MainActor
enum AppUpdate {
    /// Repos checked in order; the first with a release wins.
    static let repos = ["McKack/overpass", "McKack/overpass-releases"]

    struct Release {
        let version: String
        let zip: URL
        let page: URL
        let notes: String
    }

    /// OverPass 0.3 and older: their updates and settings carry over to no.arctim.overpass.
    nonisolated static let oldBundleID = "com.overpass.app"
    /// An update must be one of these. Fixed rather than taken from this copy, so a build under the old ID
    /// (the bridge release) accepts the new one.
    static let updateBundleIDs: Set<String> = ["no.arctim.overpass", oldBundleID]

    /// Brings the settings an older OverPass saved under its old bundle ID, once. Runs before anything reads them.
    nonisolated static func moveOldSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "settingsMovedFromOldID") else { return }
        for (key, value) in defaults.persistentDomain(forName: oldBundleID) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "settingsMovedFromOldID")
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The newest release in the first repo that has one; nil when there are none or GitHub can't be reached.
    static func latest() async -> Release? {
        struct GitHubRelease: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
        }
        for repo in repos {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  !release.draft, !release.prerelease,
                  let asset = release.assets.first(where: { $0.name.lowercased().hasPrefix("overpass") && $0.name.hasSuffix(".zip") })
            else { continue }
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            return Release(version: version, zip: asset.browser_download_url, page: release.html_url, notes: release.body ?? "")
        }
        return nil
    }

    /// Whether version `a` ("0.2.1") is newer than `b`, comparing numbers part by part.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Downloads and unpacks the new app, checks it's OverPass with an intact signature, then replaces this
    /// copy once OverPass has quit and opens the new one.
    static func install(_ release: Release) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("OverPass Update \(release.version)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (download, _) = try await URLSession.shared.download(from: release.zip)
        let zip = work.appendingPathComponent("OverPass.zip")
        try FileManager.default.moveItem(at: download, to: zip)
        try await runTool("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("OverPass.app")
        guard let id = Bundle(url: app)?.bundleIdentifier, updateBundleIDs.contains(id) else {
            throw UpdateError.notOverPass
        }
        try await runTool("/usr/bin/codesign", ["--verify", "--deep", app.path])

        // Waits for this copy to quit, swaps the apps, and opens the new one. The old copy goes only once the new
        // one is complete; if anything fails, this copy opens again and says so (showUpdateFailure).
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1.new" "$1.old"
        if ditto "$2" "$1.new" && { [ ! -e "$1" ] || mv "$1" "$1.old"; } && mv "$1.new" "$1"; then
            rm -rf "$1.old"
            open "$1"
        else
            rm -rf "$1.new"
            if [ -e "$1.old" ] && [ ! -e "$1" ]; then mv "$1.old" "$1"; fi
            touch "$3"
            open "$4"
        fi
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", destination.path, app.path, updateFailed.path, Bundle.main.bundleURL.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    /// Where an update goes. A quarantined app opened where it was downloaded runs from a read-only copy macOS
    /// makes (App Translocation), which can't be replaced, so it goes to Applications instead.
    private static var destination: URL {
        let own = Bundle.main.bundleURL
        return own.path.contains("/AppTranslocation/") ? URL(fileURLWithPath: "/Applications/OverPass.app") : own
    }

    /// Left by a swap that failed, for the copy that opens after it.
    private static var updateFailed: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OverPass Update Failed")
    }

    /// Says so when the last update couldn't replace this copy; otherwise it would simply look like nothing happened.
    static func showUpdateFailure() {
        guard FileManager.default.fileExists(atPath: updateFailed.path) else { return }
        try? FileManager.default.removeItem(at: updateFailed)
        let alert = NSAlert()
        alert.messageText = "OverPass couldn't update itself"
        alert.informativeText = "macOS didn't let it replace the app. Allow OverPass in System Settings › Privacy & Security "
            + "› App Management, or download the new version and drag it to Applications."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let page = URL(string: "https://github.com/McKack/overpass/releases/latest") {
            NSWorkspace.shared.open(page)
        }
    }

    private static func runTool(_ path: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        await Task.detached { process.waitUntilExit() }.value
        guard process.terminationStatus == 0 else { throw UpdateError.toolFailed((path as NSString).lastPathComponent) }
    }

    enum UpdateError: LocalizedError {
        case notOverPass, toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .notOverPass: "The download doesn't contain OverPass."
            case .toolFailed(let tool): "The update couldn't be unpacked or checked (\(tool) failed)."
            }
        }
    }
}
