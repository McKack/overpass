import Foundation
import AppKit

// The one-click install flow: everything CrossOver hides behind its Install button.
// Pick or create the bottle, make sure needed components and runtimes are present, run the installer,
// then pick up the new shortcuts for the library.
@MainActor
@Observable
class GameInstaller {
    enum Phase: Equatable {
        case idle
        /// The profile wants a graphics component that isn't installed; the UI asks what to do.
        case needsComponent(ComponentID)
        case running
        case finished(success: Bool)
    }

    enum StepState { case pending, running, done, skipped, failed }

    struct Step: Identifiable {
        let id: String
        let title: String
        var state: StepState = .pending
        var detail: String?
    }

    var phase: Phase = .idle
    var steps: [Step] = []
    var log = ""
    var error: String?
    var bottle: Bottle?
    var newApps: [WineApp] = []
    /// The installer itself has exited, but programs it started are still running.
    var waitingForChildren = false
    var stopWaitingRequested = false
    /// The installer runs without a wizard, so there's no window to point the user at.
    var runsUnattended = false

    static var installerCache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OverPass/Installers")
    }

    /// `graphicsOverride` lets the user continue with a different backend when the profile's isn't available.
    func start(profile: GameProfile?, installerFile: URL?, bottles: BottleManager, components: ComponentManager,
               graphicsOverride: GraphicsBackend? = nil, location: URL? = nil) async {
        error = nil
        newApps = []
        bottle = nil
        let graphics = graphicsOverride ?? profile?.graphics ?? .auto

        if bottles.wineRoot == nil {
            fail("Wine isn't installed. Install it from Components first.")
            return
        }
        // OverPass Runtime is a plain download, so fetch it here; D3DMetal has to be imported, so ask.
        let wanted = ([graphics] + (profile?.ruleGraphics ?? [])).compactMap(\.component)
        for needed in Set(wanted) where !components.isInstalled(needed) {
            if needed == .dxmt {
                phase = .running
                appendLog("Downloading OverPass Runtime…\n")
                await components.install(.dxmt)
                if components.isInstalled(.dxmt) { continue }
            }
            phase = .needsComponent(needed)
            return
        }

        phase = .running
        steps = [
            Step(id: "installer", title: "Get installer"),
            Step(id: "bottle", title: "Prepare container"),
            Step(id: "runtimes", title: "Install runtimes"),
            Step(id: "install", title: "Run installer"),
            Step(id: "scan", title: "Add to library"),
        ]

        do {
            // 1. Installer file
            set("installer", .running)
            let file: URL
            if let installerFile {
                file = installerFile
                set("installer", .done, installerFile.lastPathComponent)
            } else if let url = profile?.installer?.downloadURL {
                file = try await download(url)
                set("installer", .done, file.lastPathComponent)
            } else if let link = profile?.installer?.latestLink {
                file = try await download(try await latestLink(link))
                set("installer", .done, file.lastPathComponent)
            } else if let release = profile?.installer?.githubRelease {
                file = try await download(try await latestAsset(release))
                set("installer", .done, file.lastPathComponent)
            } else {
                throw InstallError.noInstaller
            }

            // 2. Bottle: reuse one in the same group (a launcher's games join the launcher), otherwise create one.
            set("bottle", .running)
            let target: Bottle
            var created = false
            if let group = profile?.bottle.group, let existing = bottles.bottles.first(where: { $0.group == group }) {
                target = existing
                set("bottle", .done, "Using \(existing.name)")
            } else {
                let name = bottles.freeBottleName(profile?.name ?? file.deletingPathExtension().lastPathComponent)
                var env = profile?.environment ?? [:]
                if let overrides = profile?.dllOverrides, !overrides.isEmpty {
                    env["WINEDLLOVERRIDES"] = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
                }
                // With Mono and Gecko in Wine's cache, the new bottle's first boot installs them without a dialog.
                if !components.isInstalled(.addons) {
                    appendLog("Downloading Wine Mono & Gecko…\n")
                    await components.install(.addons)
                }
                appendLog("Creating container \(name)…\n")
                target = try await bottles.createBottle(
                    name: name,
                    template: profile?.bottle.template ?? .windows10,
                    group: profile?.bottle.group,
                    profileID: profile?.id,
                    graphics: graphics,
                    environment: env,
                    runtimes: Set((profile?.runtimes ?? []).compactMap(Runtime.init(rawValue:))),
                    location: location
                )
                created = env["WINEDLLOVERRIDES"] == nil
                set("bottle", .done, "Created \(name)")
            }
            bottle = target
            let before = Set(target.apps.map(\.id))

            // 3. Runtimes: OverPass's own first, then winetricks verbs (fetched on demand; a small script).
            let have = Runtime.installed(in: target)
            let runtimes = (profile?.runtimes ?? []).compactMap(Runtime.init(rawValue:)).filter { !have.contains($0) }
            let verbs = profile?.dependencies ?? []
            let names = runtimes.map(\.name) + verbs
            if names.isEmpty {
                set("runtimes", .skipped, have.isEmpty ? "None needed" : "Already installed")
            } else {
                set("runtimes", .running, names.joined(separator: ", "))
                for runtime in runtimes {
                    try await runtime.install(in: target, using: bottles) { [weak self] in self?.appendLog($0) }
                }
                // The next bottle with the same runtimes starts from this one as it is now.
                if created && have.isEmpty { await bottles.saveRuntimeTemplate(from: target, runtimes: Set(runtimes)) }
                if !verbs.isEmpty {
                    if !components.isInstalled(.winetricks) {
                        await components.install(.winetricks)
                    }
                    guard components.isInstalled(.winetricks) else { throw InstallError.noWinetricks }
                }
                for verb in verbs {
                    appendLog("$ winetricks -q \(verb)\n")
                    let status = try await bottles.runTool(ComponentManager.winetricksPath, ["-q", verb], in: target) { [weak self] in self?.appendLog($0) }
                    if status != 0 { appendLog("winetricks \(verb) exited \(status)\n") }
                }
                set("runtimes", .done, names.joined(separator: ", "))
            }

            // 4. Installer. Exit codes from Windows installers are unreliable under Wine, so we log rather than fail.
            set("install", .running)
            // A profile's own switches win. A file chosen without a profile gets its framework's documented
            // silent switches; launcher profiles keep their wizard until a switch is verified for them.
            var silent = profile?.installer?.silentArgs ?? []
            if profile == nil, let kind = InstallerKind.detect(file) {
                silent = kind.silentArgs
                appendLog("\(kind.name) installer; running it unattended.\n")
            }
            runsUnattended = !silent.isEmpty
            // Installers run directly, not through `start`: the wait for everything they start was tested that way.
            let isExe = file.pathExtension.lowercased() == "exe"
            let args = (isExe ? [file.path] : BottleManager.launchArgs(file.path)) + silent
            appendLog("$ wine \(args.joined(separator: " "))\n")
            // Installers with a wizard open behind OverPass (Wine apps start in the background), which looks
            // like a hang; bring each new Wine window forward once while the installer runs.
            let raiser = Task { await bottles.raiseNewWineWindows() }
            stopWaitingRequested = false
            let run = try await bottles.runWaitingForChildren(
                args, in: target, ignore: profile?.installer?.waitIgnore,
                log: { [weak self] in self?.appendLog($0) },
                mainExited: { [weak self] in
                    self?.waitingForChildren = true
                    self?.set("install", .running, "Waiting for programs the installer started…")
                },
                stopWaiting: { [weak self] in self?.stopWaitingRequested ?? true })
            waitingForChildren = false
            raiser.cancel()
            if !run.allExited { appendLog("Stopped waiting; programs the installer started are still running.\n") }
            set("install", .done, run.status == 0 ? "" : "Installer exited with code \(run.status)")

            // 5. Pick up new shortcuts.
            set("scan", .running)
            bottles.loadBottles()
            let refreshed = bottles.bottles.first { $0.path == target.path } ?? target
            bottle = refreshed
            newApps = refreshed.apps.filter { !before.contains($0.id) }
            set("scan", .done, newApps.isEmpty ? "No new shortcuts found" : newApps.map(\.name).joined(separator: ", "))
            phase = .finished(success: true)
        } catch {
            if let i = steps.firstIndex(where: { $0.state == .running }) { steps[i].state = .failed }
            fail(error.localizedDescription)
        }
    }

    func reset() {
        phase = .idle
        steps = []
        log = ""
        error = nil
        bottle = nil
        newApps = []
    }

    private func latestAsset(_ release: GameProfile.InstallerSpec.GitHubRelease) async throws -> URL {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let assets: [Asset]
        }
        let api = URL(string: "https://api.github.com/repos/\(release.repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: api)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let latest = try? JSONDecoder().decode(Release.self, from: data),
              let asset = latest.assets.first(where: { GameProfile.wildcard(pattern: release.asset, matches: $0.name) })
        else { throw InstallError.downloadFailed }
        return asset.browser_download_url
    }

    private func latestLink(_ link: GameProfile.InstallerSpec.LatestLink) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: link.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              var value = try? JSONSerialization.jsonObject(with: data) else { throw InstallError.downloadFailed }
        for part in link.key.split(separator: ".") {
            guard let next = (value as? [String: Any])?[String(part)] else { throw InstallError.downloadFailed }
            value = next
        }
        guard let string = value as? String, let url = URL(string: string) else { throw InstallError.downloadFailed }
        return url
    }

    private func download(_ url: URL) async throws -> URL {
        appendLog("Downloading \(url.absoluteString)\n")
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.downloadFailed
        }
        let name = response.suggestedFilename ?? url.lastPathComponent
        let fm = FileManager.default
        try fm.createDirectory(at: Self.installerCache, withIntermediateDirectories: true)
        let dest = Self.installerCache.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    private func set(_ id: String, _ state: StepState, _ detail: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        if let detail { steps[i].detail = detail }
    }

    private func appendLog(_ text: String) {
        log += text
    }

    private func fail(_ message: String) {
        error = message
        appendLog("Error: \(message)\n")
        phase = .finished(success: false)
    }

    enum InstallError: LocalizedError {
        case noInstaller, downloadFailed, noWinetricks
        var errorDescription: String? {
            switch self {
            case .noInstaller: "Choose an installer file."
            case .downloadFailed: "The installer download failed."
            case .noWinetricks: "Winetricks couldn't be installed, so required runtimes can't be set up."
            }
        }
    }
}

/// Installer frameworks with documented unattended switches, recognized by the marker each one embeds near
/// the start of its stub (checked against Steam's NSIS installer and GOG's Inno Setup installers).
enum InstallerKind {
    case nsis, inno, msi

    var name: String {
        switch self {
        case .nsis: "NSIS"
        case .inno: "Inno Setup"
        case .msi: "Windows Installer"
        }
    }

    var silentArgs: [String] {
        switch self {
        case .nsis: ["/S"]
        case .inno: ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"]
        case .msi: ["/qn"]
        }
    }

    static func detect(_ file: URL) -> InstallerKind? {
        if file.pathExtension.lowercased() == "msi" { return .msi }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The markers sit in the stub, before the payload; 4 MB covers it even for multi-GB game installers.
        guard let head = try? handle.read(upToCount: 4 << 20) else { return nil }
        if head.range(of: Data("Inno Setup Setup Data".utf8)) != nil { return .inno }
        if head.range(of: Data("Nullsoft".utf8)) != nil { return .nsis }
        return nil
    }
}
