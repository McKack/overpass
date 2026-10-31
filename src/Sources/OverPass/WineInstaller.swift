import Foundation

// Downloads Wine on first run instead of bundling it (~260 MB download).
// Preferred: OverPass Wine (github.com/McKack/overpass-wine), built from upstream Wine + CodeWeavers' LGPL
// CrossOver changes, which can host DXMT and D3DMetal. There's deliberately no fallback to upstream Wine: it lacks
// CodeWeavers' fixes (GOG Galaxy's service, MSync) and silently breaks launchers.
// URLSession downloads carry no quarantine xattr, so Gatekeeper never sees them.
@MainActor
@Observable
class WineInstaller {
    enum Flavor: String, CaseIterable, Identifiable {
        case overpass, devel, staging
        var id: String { rawValue }

        var repo: String {
            self == .overpass ? "McKack/overpass-wine" : "Gcenx/macOS_Wine_builds"
        }

        func matches(asset name: String) -> Bool {
            switch self {
            case .overpass: name.hasPrefix("overpass-wine-") && name.hasSuffix("-x86_64.tar.xz")
            default: name.hasPrefix("wine-\(rawValue)-") && name.hasSuffix("-osx64.tar.xz")
            }
        }
    }

    struct Release {
        let version: String
        let url: URL
        let size: Int64
        /// Checked after download when the version comes from the component catalog.
        var sha256: String? = nil
    }

    var progress: Double = 0
    var status = ""
    var isRunning = false

    private var downloadTask: URLSessionDownloadTask?

    nonisolated static var installRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/Wine")
    }

    /// `installRoot/current` → `installRoot/<flavor>-<version>`, laid out like a normal Wine prefix (bin/, lib/, share/).
    nonisolated static var currentWine: URL { installRoot.appendingPathComponent("current") }

    nonisolated static var installedVersion: String? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: currentWine.path) else { return nil }
        return URL(fileURLWithPath: dest).lastPathComponent
    }

    /// The installed OverPass Wine's release tag ("overpass-wine-11.0-2"); nil for a development build or other Wine.
    nonisolated static var installedTag: String? {
        guard var name = installedVersion else { return nil }
        if name.hasPrefix("overpass-overpass-wine-") { name.removeFirst("overpass-".count) }   // installed before 11.0-3
        return name.hasPrefix("overpass-wine-") ? name : nil
    }

    /// "11.0-2" for an OverPass Wine release tag; anything else unchanged.
    nonisolated static func shortVersion(_ tag: String) -> String {
        tag.hasPrefix("overpass-wine-") ? String(tag.dropFirst("overpass-wine-".count)) : tag
    }

    /// What to show for the installed Wine.
    nonisolated static var displayVersion: String? {
        installedTag.map(shortVersion) ?? installedVersion
    }

    /// Wine builds are x86_64 only; on Apple silicon they need Rosetta.
    nonisolated static var rosettaAvailable: Bool {
        #if arch(arm64)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
        #else
        return true
        #endif
    }

    /// OverPass Wine: the version the component catalog pins, else the newest release. Other flavors: newest release.
    func latestRelease(flavor: Flavor) async throws -> Release {
        if flavor == .overpass {
            await ComponentCatalog.refresh()
            if let pin = ComponentCatalog.pin(.wine, arch: ComponentManager.arch) {
                return Release(version: "overpass-wine-\(pin.version)", url: pin.url, size: 0, sha256: pin.sha256)
            }
        }
        struct GHRelease: Decodable {
            struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let api = URL(string: "https://api.github.com/repos/\(flavor.repo)/releases?per_page=10")!
        let (data, _) = try await URLSession.shared.data(from: api)
        let releases = (try? JSONDecoder().decode([GHRelease].self, from: data)) ?? []
        for r in releases {
            if let a = r.assets.first(where: { flavor.matches(asset: $0.name) }) {
                return Release(version: r.tag_name, url: a.browser_download_url, size: a.size)
            }
        }
        throw InstallError.noRelease
    }

    /// Installs the latest OverPass Wine release.
    func install(flavor: Flavor = .overpass, log: @escaping (String) -> Void) async throws {
        isRunning = true
        progress = 0
        defer { isRunning = false; downloadTask = nil }

        status = "Finding latest Wine release…"
        let release = try await latestRelease(flavor: flavor)
        log("Wine \(flavor.rawValue) \(release.version)\(release.size > 0 ? " (\(release.size / 1_000_000) MB)" : "")\n\(release.url.absoluteString)\n")

        status = "Downloading Wine \(release.version)…"
        let tarball = try await download(release.url)
        defer { try? FileManager.default.removeItem(at: tarball) }
        if let sha256 = release.sha256 {
            status = "Checking…"
            let digest = try await Self.run("/usr/bin/shasum", ["-a", "256", tarball.path]).prefix { $0 != " " }
            guard digest == sha256 else { throw InstallError.badChecksum }
        }
        log("Downloaded.\n")

        status = "Unpacking…"
        progress = 1
        let fm = FileManager.default
        try fm.createDirectory(at: Self.installRoot, withIntermediateDirectories: true)
        let staging = Self.installRoot.appendingPathComponent(".unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await Self.run("/usr/bin/tar", ["-xJf", tarball.path, "-C", staging.path])

        // OverPass Wine: "overpass-wine-<version>/bin/wine". Gcenx: "Wine Devel.app/Contents/Resources/wine/bin/wine".
        let wineTree = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .flatMap { [$0, $0.appendingPathComponent("Contents/Resources/wine")] }
            .first { fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/wine").path) }
        guard let wineTree else { throw InstallError.badArchive }

        // OverPass Wine tags already start with the flavor ("overpass-wine-11.0-2").
        let folder = release.version.hasPrefix(flavor.rawValue + "-") ? release.version : "\(flavor.rawValue)-\(release.version)"
        let dest = Self.installRoot.appendingPathComponent(folder)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: wineTree, to: dest)
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])

        try? fm.removeItem(at: Self.currentWine)
        try fm.createSymbolicLink(atPath: Self.currentWine.path, withDestinationPath: dest.lastPathComponent)
        log("Installed to \(dest.path)\n")

        status = "Verifying…"
        let version = try await Self.run(dest.appendingPathComponent("bin/wine").path, ["--version"])
        log("\(version)\n")
        status = "Installed \(version.trimmingCharacters(in: .whitespacesAndNewlines))"
        Self.removeOldBuilds()
    }

    /// Keeps the current build and the newest other one to go back to. Every bottle runs `current`, so nothing else needs them.
    nonisolated static func removeOldBuilds(in root: URL = installRoot) {
        let fm = FileManager.default
        guard let link = try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("current").path) else { return }
        let current = URL(fileURLWithPath: link).lastPathComponent
        let others = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "current" && $0 != current }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for old in others.dropFirst() {
            try? fm.removeItem(at: root.appendingPathComponent(old))
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    private func download(_ url: URL) async throws -> URL {
        // Completion-handler task + progress polling: async download(from:) doesn't report progress.
        let result: (URL?, Error?) = await withCheckedContinuation { cont in
            let t = URLSession.shared.downloadTask(with: url) { tmp, _, error in
                // The temp file is deleted when this handler returns, so move it now.
                guard let tmp else { cont.resume(returning: (nil, error)); return }
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("overpass-wine-\(UUID().uuidString).tar.xz")
                do {
                    try FileManager.default.moveItem(at: tmp, to: kept)
                    cont.resume(returning: (kept, nil))
                } catch {
                    cont.resume(returning: (nil, error))
                }
            }
            downloadTask = t
            t.resume()
            Task { @MainActor [weak self] in
                while t.state == .running {
                    self?.progress = t.progress.fractionCompleted
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        if let file = result.0 { return file }
        if (result.1 as? URLError)?.code == .cancelled { throw InstallError.cancelled }
        throw result.1 ?? InstallError.badArchive
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { proc in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: text)
                } else {
                    cont.resume(throwing: InstallError.toolFailed("\(URL(fileURLWithPath: tool).lastPathComponent) exited \(proc.terminationStatus): \(text)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    enum InstallError: LocalizedError {
        case noRelease, badArchive, badChecksum, cancelled, toolFailed(String)
        var errorDescription: String? {
            switch self {
            case .noRelease: "Couldn't find an OverPass Wine release on github.com/McKack/overpass-wine. Check your internet connection and try again."
            case .badArchive: "The downloaded archive didn't contain a Wine installation."
            case .badChecksum: "The downloaded Wine didn't match its checksum. Try again later."
            case .cancelled: "Download cancelled."
            case .toolFailed(let msg): msg
            }
        }
    }
}
