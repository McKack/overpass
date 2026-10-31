import Foundation
import AppKit
import CryptoKit

// Shared components that live outside bottles, installed by the setup wizard or later from the Components window.
// Per-bottle runtimes (vcrun, corefonts, .NET…) are winetricks verbs, see GameInstaller.
enum ComponentID: String, CaseIterable, Identifiable {
    case core, wine, dxmt, addons, winetricks, d3dmetal, x87sidecar, legendary, gogdl, xodus
    var id: String { rawValue }

    /// The Components page's two groups, in display order.
    static let overpass: [ComponentID] = [.core, .wine, .dxmt]
    /// Xodus isn't listed: it comes with turning on the Xbox Library (opt-in), not from here.
    static let extras: [ComponentID] = [.addons, .winetricks, .d3dmetal, .x87sidecar]
    /// The store clients behind the built-in Epic and GOG libraries.
    static let stores: [ComponentID] = [.legendary, .gogdl]

    var name: String {
        switch self {
        case .core: "OverPass Core"
        case .wine: "OverPass Wine"
        case .addons: "Wine Mono & Gecko"
        case .dxmt: "OverPass Runtime"
        case .d3dmetal: "D3DMetal"
        case .winetricks: "Winetricks"
        case .x87sidecar: "x87sidecar"
        case .legendary: "Legendary"
        case .gogdl: "gogdl"
        case .xodus: "Xodus"
        }
    }

    var summary: String {
        switch self {
        case .core: "The OverPass app itself."
        case .wine: "Windows compatibility layer. Required."
        case .addons: "Wine's .NET runtime and HTML engine. New containers get them without Wine asking to download them."
        case .dxmt: "Open-source Direct3D 9 to 12 → Metal translation, with NVAPI and DLSS through MetalFX. Built on DXMT and mtld3d."
        case .d3dmetal: "Apple's Direct3D 11/12 → Metal translation, from the Game Porting Toolkit. Optional: an alternative to OverPass Runtime for games that run better on it."
        case .winetricks: "Installs Windows runtimes (Visual C++, .NET, fonts…) that games depend on."
        case .x87sidecar: "Much faster floating-point math for 32-bit games, in place of Rosetta's slow x87 translation. Used by every 32-bit game unless its profile turns Faster x87 math off."
        case .legendary: "Signs in to Epic Games and downloads, updates and starts your Epic games, without the Epic Games Launcher."
        case .gogdl: "Signs in to GOG and downloads and updates your GOG games, without GOG Galaxy."
        case .xodus: "Signs in to your Microsoft account and downloads, licenses and starts your Xbox PC and Game Pass games. Opt-in: see Settings › Advanced."
        }
    }

    /// Settings' Simple names and descriptions: what it does for you, without the parts' own names.
    var simpleName: String {
        switch self {
        case .core: "OverPass"
        case .wine: "Windows support"
        case .dxmt: "Game graphics"
        case .addons: ".NET and web pages"
        case .winetricks: "Extra Windows parts"
        case .d3dmetal: "Apple's game graphics"
        case .x87sidecar: "Faster older games"
        case .legendary: "Epic Games Library"
        case .gogdl: "GOG Library"
        case .xodus: "Xbox Library"
        }
    }

    var simpleSummary: String {
        switch self {
        case .core: "This app."
        case .wine: "Lets your Mac run Windows games and apps. Required."
        case .dxmt: "Lets Windows games draw with your Mac's graphics chip. Recommended."
        case .addons: "Apps that need .NET or show web pages work without asking to download more."
        case .winetricks: "Installs Windows pieces some games need, such as Visual C++ and .NET."
        case .d3dmetal: "Apple's own version of game graphics. Optional: some games run better with it."
        case .x87sidecar: "Speeds up the math in older 32-bit games. Installed for you."
        case .legendary: "Your Epic games in OverPass, without installing the Epic Games Launcher."
        case .gogdl: "Your GOG games in OverPass, without installing GOG Galaxy."
        case .xodus: "Your Xbox PC and Game Pass games in OverPass. You turned this on yourself."
        }
    }

    /// Settings' Technical descriptions: what the part is and how OverPass uses it.
    var technicalSummary: String {
        switch self {
        case .core: "The OverPass app (SwiftUI) with its bundled game profiles and compatibility rules; updates from GitHub releases."
        case .wine: "Wine 11 from CodeWeavers' CrossOver 26.3.0 LGPL sources plus OverPass patches (compatibility rules, DLL path prepend, Game Mode bundles, x87sidecar…). x86_64 with WoW64 for 32-bit, under Rosetta 2; GStreamer and FFmpeg for video, MoltenVK for Vulkan."
        case .dxmt: "DXMT with OverPass patches: Direct3D 10/11/12 and DXGI on Metal (DXBC/DXIL → AIR), NVAPI, DLSS through MetalFX. mtld3d for Direct3D 9 (shader models 1–3 and fixed function → MSL). Loaded as builtins through OVERPASS_DLL_PATH_PREPEND."
        case .addons: "Wine's .NET Framework (Wine Mono) and MSHTML (Wine Gecko) replacements, cached in the versions this Wine asks for."
        case .winetricks: "Shell script that installs redistributables (vcrun, dotnet, corefonts, d3dx9…) into a container as native DLLs."
        case .d3dmetal: "Apple's Direct3D 11/12 → Metal (D3DMetal.framework, libd3dshared) from the Game Porting Toolkit, imported from Apple's download; found through CX_APPLEGPTK_LIBD3DSHARED_PATH."
        case .x87sidecar: "Native arm64 JIT that replaces Rosetta 2's x87 translation, attached cooperatively (no entitlements): 32-bit processes re-exec under it once `--probe` has passed on this macOS build; a profile opts out with OVERPASS_X87=0. Pinned to 1.9.0, checksum-verified."
        case .legendary: "Open-source Epic Games Store client (Python, PyInstaller build), run as a separate program: OAuth sign-in, library, manifest/chunk downloads, updates and the launch token. OverPass starts the games with its own Wine. Pinned to 0.21.1, checksum-verified; its data is in Application Support/OverPass/Stores/Epic."
        case .gogdl: "Open-source GOG downloader from Heroic Games Launcher (Python, PyInstaller build), run as a separate program: OAuth tokens, Galaxy content-system downloads, updates, repairs and GOG's shared redistributables. OverPass lists the library from GOG's web services, runs the install scripts in the bottle and starts the games itself. Pinned to 1.3.1, checksum-verified; its data is in Application Support/OverPass/Stores/GOG."
        case .xodus: "Open-source Xbox PC client (Rust), xodus-cli and xodus-service, with the Xodus Nexus/MACxus patch set; run as separate programs: Microsoft account sign-in (tokens in the Keychain), entitlements, MSIXVC streaming downloads, licences and the launch view our Wine loads through WINE_DLL_FILE_MAP. xodus-service answers the game's Xbox runtime (xgameruntime) over a Unix socket. Opt-in, see Settings › Advanced."
        }
    }

    var credit: (author: String, license: String, url: URL) {
        switch self {
        case .core: ("Arctic Imaginarium and contributors", "GPL-3.0", URL(string: "https://github.com/McKack/overpass")!)
        case .wine: ("The Wine project · CodeWeavers' LGPL changes · OverPass Wine", "LGPL-2.1", URL(string: "https://github.com/McKack/overpass-wine")!)
        case .addons: ("The Wine project (Wine Mono, Wine Gecko)", "MIT and others · MPL-2.0", URL(string: "https://gitlab.winehq.org/wine-mono/wine-mono")!)
        case .dxmt: ("OverPass · DXMT by Feifan He (3Shain) and contributors · mtld3d by Alexander Theißen", "LGPL-2.1, zlib", URL(string: "https://github.com/McKack/overpass-runtime")!)
        case .d3dmetal: ("Apple Inc.", "Apple Game Porting Toolkit license (not redistributable)", URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
        case .winetricks: ("Winetricks contributors", "LGPL-2.1", URL(string: "https://github.com/Winetricks/winetricks")!)
        case .x87sidecar: ("Alexander Theißen", "MIT", URL(string: "https://github.com/athei/x87sidecar")!)
        case .legendary: ("Rodney (derrod) and the Legendary contributors", "GPL-3.0", URL(string: "https://github.com/legendary-gl/legendary")!)
        case .gogdl: ("imLinguin and the Heroic Games Launcher contributors", "GPL-3.0", URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl")!)
        case .xodus: ("The Xodus contributors · Xodus Nexus and MACxus patches", "GPL-3.0", URL(string: "https://github.com/xodus-gaming/xodus")!)
        }
    }
}

@MainActor
@Observable
class ComponentManager {
    /// The manager the app created; menu commands reach it here.
    private(set) static weak var current: ComponentManager?

    /// Newer versions found by `checkForUpdates()`, by component, as shown to the person.
    var updates: [ComponentID: String] = [:]
    private var appRelease: AppUpdate.Release?
    var checking = false
    var lastCheck: Date?

    /// Looks up the newest release of every component that can update itself (D3DMetal comes from Apple's
    /// download, so it's imported again by hand).
    func checkForUpdates() async {
        guard !checking else { return }
        checking = true
        defer { checking = false; lastCheck = .now }
        async let app = AppUpdate.latest()
        async let wine = try? wineInstaller.latestRelease(flavor: .overpass)
        async let runtime = try? GitHubRelease.latest(repo: "McKack/overpass-runtime") { $0.hasSuffix(".tar.xz") }
        async let tricks = try? GitHubRelease.latestTag(repo: "Winetricks/winetricks")
        await ComponentCatalog.refresh()

        var found: [ComponentID: String] = [:]
        appRelease = await app.flatMap { AppUpdate.isNewer($0.version, than: AppUpdate.currentVersion) ? $0 : nil }
        if let appRelease { found[.core] = appRelease.version }
        if let wine = await wine, WineInstaller.installedVersion != nil, wine.version != WineInstaller.installedTag {
            found[.wine] = WineInstaller.shortVersion(wine.version)
        }
        var runtimeLatest = ComponentCatalog.pin(.dxmt, arch: Self.arch)?.version
        if runtimeLatest == nil, let runtime = await runtime {
            runtimeLatest = runtime.tag.hasPrefix("v") ? String(runtime.tag.dropFirst()) : runtime.tag
        }
        if let latest = runtimeLatest, isInstalled(.dxmt) {
            if Self.runtimeVersion.map({ AppUpdate.isNewer(latest, than: $0) }) ?? true { found[.dxmt] = latest }
        }
        // Pinned tools move when the catalog's pin does (either way: a pin can also go back to a working version).
        for id in [ComponentID.x87sidecar, .legendary, .gogdl] where isInstalled(id) {
            if let pinned = ComponentCatalog.pin(id, arch: Self.arch)?.version, pinned != installedVersion(id) {
                found[id] = pinned
            }
        }
        if let tag = await tricks, isInstalled(.winetricks),
           Self.winetricksVersion.map({ AppUpdate.isNewer(tag, than: $0) }) ?? true {
            found[.winetricks] = tag
        }
        // After a Wine update the add-ons it wants can be newer than the ones in the cache.
        if let wine = BottleManager.findWine(), WineAddons.hasAny {
            let missing = WineAddons.missing(wineRoot: wine)
            if !missing.isEmpty { found[.addons] = WineAddons.versions(missing) }
        }
        updates = found
    }

    /// Installs every update found, OverPass Core last because it quits and relaunches the app.
    func updateAll() async {
        for id in ComponentID.allCases where id != .core && updates[id] != nil {
            await install(id)
        }
        if updates[.core] != nil, lastError == nil { await install(.core) }
    }

    let wineInstaller = WineInstaller()

    init() {
        Self.current = self
        // Builds from 2026-10-26 put OverPass Runtime in OverPass/Runtime, a folder older versions used for other
        // things; move an install found there to its own folder.
        let fm = FileManager.default
        let old = Self.dxmtDir.deletingLastPathComponent().appendingPathComponent("Runtime")
        if !fm.fileExists(atPath: Self.dxmtDir.path),
           fm.fileExists(atPath: old.appendingPathComponent("x86_64-windows/d3d11.dll").path) {
            try? fm.moveItem(at: old, to: Self.dxmtDir)
        }
    }
    var busy: ComponentID?
    var progress: Double?
    var log = ""
    var lastError: String?

    // Bumped after installs so views re-read the filesystem-backed status.
    private(set) var revision = 0

    nonisolated static var toolsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/Tools")
    }
    nonisolated static var winetricksPath: URL { toolsDir.appendingPathComponent("winetricks") }

    /// x87sidecar, pinned: it patches Rosetta's runtime in memory, so each version is checked before OverPass
    /// moves to it (`x87sidecar --probe`).
    static let x87sidecarVersion = "1.9.0"
    static let x87sidecarSHA256 = "104098b0ba8baed37d4d63cf62ab3b55493889b8fe9ee225cad8febcd6bc1e78"
    nonisolated static var x87sidecarPath: URL { toolsDir.appendingPathComponent("x87sidecar/x87sidecar") }

    /// Fetches x87sidecar once on an Apple Silicon Mac (removing it afterwards sticks), then checks it works here.
    func prepareX87Sidecar() async {
        let key = "x87sidecarFetched"
        if Self.isArm64, BottleManager.findWine() != nil, !isInstalled(.x87sidecar),
           !UserDefaults.standard.bool(forKey: key) {
            await install(.x87sidecar)
            if isInstalled(.x87sidecar) { UserDefaults.standard.set(true, forKey: key) }
        }
        await X87Sidecar.probe()
    }

    /// Legendary, pinned: OverPass reads its output, which isn't a stable interface, so each version is tried
    /// before OverPass moves to it. Upstream's own macOS builds, one per architecture.
    static let legendaryVersion = "0.21.1"
    static let legendarySHA256 = [
        "arm64": "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e",
        "x64": "3dfab50277284b5bb0104f8710e4ff1d9ff00c992e44f5843fd0c977c5cc99c4",
    ]
    nonisolated static var legendaryPath: URL { toolsDir.appendingPathComponent("legendary/legendary") }

    /// gogdl, pinned for the same reason. Upstream's own macOS builds, one per architecture.
    static let gogdlVersion = "1.3.1"
    static let gogdlSHA256 = [
        "arm64": "33a6d9b329c35f1caa7968009bf2f4f0a6f57cd00f749a4d2cb2204f3e794d2e",
        "x86_64": "9f78f5916141692704f9587e6519082abc2b12c5f8825548fe4d1dee1e46180c",
    ]
    nonisolated static var gogdlPath: URL { toolsDir.appendingPathComponent("gogdl/gogdl") }

    /// Xodus: xodus-cli and xodus-service side by side. No OverPass build is published yet, so it installs from
    /// a local build folder (`defaults write no.arctim.overpass xodusLocalBuild <folder>`) until there is one.
    nonisolated static var xodusDir: URL { toolsDir.appendingPathComponent("xodus") }
    nonisolated static var xodusCLIPath: URL { xodusDir.appendingPathComponent("xodus-cli") }
    nonisolated static var xodusServicePath: URL { xodusDir.appendingPathComponent("xodus-service") }
    /// GPTK's redist/lib, kept outside the Wine root so it survives Wine updates. Wine reaches it only
    /// through CX_APPLEGPTK_LIBD3DSHARED_PATH and the backend DLL path, so its location doesn't matter.
    nonisolated static var d3dmetalDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/D3DMetal")
    }

    /// OverPass Runtime's builtin DLLs, also outside the Wine install so Wine updates keep them.
    nonisolated static var dxmtDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/OverPass Runtime")
    }

    static let gptkDownloadPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    // MARK: Status

    func isInstalled(_ id: ComponentID) -> Bool {
        _ = revision
        if id == .core { return true }
        let fm = FileManager.default
        guard let wine = BottleManager.findWine() else {
            return id == .winetricks && fm.isExecutableFile(atPath: Self.winetricksPath.path)
                || id == .legendary && fm.isExecutableFile(atPath: Self.legendaryPath.path)
                || id == .gogdl && fm.isExecutableFile(atPath: Self.gogdlPath.path)
                || id == .xodus && Self.xodusInstalled
        }
        switch id {
        case .core, .wine: return true
        case .addons: return WineAddons.missing(wineRoot: wine).isEmpty
        case .dxmt: return fm.fileExists(atPath: Self.dxmtDir.appendingPathComponent("x86_64-windows/d3d11.dll").path)
        case .d3dmetal: return fm.fileExists(atPath: Self.d3dmetalDir.appendingPathComponent("external/D3DMetal.framework").path)
        case .winetricks: return fm.isExecutableFile(atPath: Self.winetricksPath.path)
        case .x87sidecar: return fm.isExecutableFile(atPath: Self.x87sidecarPath.path)
        case .legendary: return fm.isExecutableFile(atPath: Self.legendaryPath.path)
        case .gogdl: return fm.isExecutableFile(atPath: Self.gogdlPath.path)
        case .xodus: return Self.xodusInstalled
        }
    }

    /// What Xodus needs from Wine when there is no catalog yet.
    static let xodusWineFeatures = ["af-unix>=1", "dll-file-map>=1", "winhttp-http2>=1", "gdk-winrt>=1", "dll-path-prepend>=1"]

    nonisolated static var xodusInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: xodusCLIPath.path)
            && FileManager.default.isExecutableFile(atPath: xodusServicePath.path)
    }

    /// DXMT and D3DMetal plug into a CrossOver-derived Wine (OverPass Wine): its winemac.drv exports
    /// `macdrv_functions`. Upstream Wine builds don't.
    nonisolated static func wineSupportsMetalBackends(_ wineRoot: URL? = BottleManager.findWine()) -> Bool {
        guard let wineRoot,
              let data = try? Data(contentsOf: wineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"), options: .mappedIfSafe)
        else { return false }
        return data.range(of: Data("_macdrv_functions".utf8)) != nil
    }

    /// Why a component can't be installed right now, or nil if it can.
    func blocker(for id: ComponentID) -> String? {
        switch id {
        case .core, .wine, .winetricks, .x87sidecar, .legendary, .gogdl: return nil
        case .xodus:
            guard let wine = BottleManager.findWine() else { return "Install Wine first." }
            let needs = ComponentCatalog.entry(.xodus)?.requires?.wineFeatures ?? Self.xodusWineFeatures
            return WineFeatures.missing(needs, wineRoot: wine).isEmpty ? nil
                : "Needs a newer OverPass Wine (11.0-7 or later). Update Wine in Components first."
        case .addons: return BottleManager.findWine() == nil ? "Install Wine first." : nil
        case .dxmt, .d3dmetal:
            if BottleManager.findWine() == nil { return "Install Wine first." }
            if !Self.wineSupportsMetalBackends() {
                return "Needs OverPass Wine. The installed Wine is upstream Wine, which can't load \(id.name). Reinstall Wine from Components once an OverPass Wine release is available."
            }
            return nil
        }
    }

    // MARK: Install

    func install(_ id: ComponentID) async {
        guard busy == nil else { return }
        busy = id
        lastError = nil
        progress = nil
        defer { busy = nil; progress = nil; revision += 1 }
        do {
            switch id {
            case .core:
                guard let appRelease else { return }
                log += "OverPass \(appRelease.version)\n"
                try await AppUpdate.install(appRelease)
            case .wine:
                try await wineInstaller.install { [weak self] in self?.log += $0 }
                // A different Wine can want different add-on versions.
                try await installAddons()
                updates[.addons] = nil
            case .addons:
                try await installAddons()
            case .dxmt:
                try await installDXMT()
            case .winetricks:
                try await installWinetricks()
            case .x87sidecar:
                try await installX87Sidecar()
            case .legendary:
                try await installLegendary()
            case .gogdl:
                try await installGogdl()
            case .xodus:
                try await installXodus()
            case .d3dmetal:
                // Apple requires a developer sign-in to download GPTK, so the user downloads it and we import it.
                guard let source = chooseGPTK() else { return }
                try await importD3DMetal(from: source)
            }
            updates[id] = nil
        } catch {
            lastError = "\(id.name): \(error.localizedDescription)"
            log += "Error: \(error.localizedDescription)\n"
        }
    }

    func cancel() {
        wineInstaller.cancel()
    }

    func remove(_ id: ComponentID) {
        guard let wine = BottleManager.findWine() else { return }
        let fm = FileManager.default
        switch id {
        case .core: return
        case .wine: try? fm.removeItem(at: WineInstaller.installRoot)
        case .addons:
            for file in WineAddons.required(wineRoot: wine) { try? fm.removeItem(at: WineAddons.cacheDirectory.appendingPathComponent(file)) }
        case .dxmt: try? fm.removeItem(at: Self.dxmtDir)
        case .d3dmetal: try? fm.removeItem(at: Self.d3dmetalDir)
        case .winetricks: try? fm.removeItem(at: Self.winetricksPath)
        case .x87sidecar: try? fm.removeItem(at: Self.x87sidecarPath.deletingLastPathComponent())
        case .legendary: try? fm.removeItem(at: Self.legendaryPath.deletingLastPathComponent())
        case .gogdl: try? fm.removeItem(at: Self.gogdlPath.deletingLastPathComponent())
        case .xodus: try? fm.removeItem(at: Self.xodusDir)
        }
        revision += 1
    }

    /// The installed version of a component, for display; nil when unknown or not installed.
    func installedVersion(_ id: ComponentID) -> String? {
        _ = revision
        switch id {
        case .core: return AppUpdate.currentVersion
        case .wine: return WineInstaller.displayVersion
        case .dxmt: return isInstalled(.dxmt) ? Self.runtimeVersion : nil
        case .winetricks: return isInstalled(.winetricks) ? Self.winetricksVersion : nil
        case .addons:
            guard let wine = BottleManager.findWine(), isInstalled(.addons) else { return nil }
            return WineAddons.versions(WineAddons.required(wineRoot: wine))
        case .d3dmetal: return nil
        case .x87sidecar: return isInstalled(.x87sidecar) ? Self.recordedVersion(Self.x87sidecarPath) ?? Self.x87sidecarVersion : nil
        case .legendary: return isInstalled(.legendary) ? Self.recordedVersion(Self.legendaryPath) ?? Self.legendaryVersion : nil
        case .gogdl: return isInstalled(.gogdl) ? Self.recordedVersion(Self.gogdlPath) ?? Self.gogdlVersion : nil
        case .xodus: return isInstalled(.xodus) ? "local build" : nil
        }
    }

    /// The version a pinned tool was installed at, kept in a .version file beside it; nil for installs made before
    /// the catalog (those are the built-in pins).
    nonisolated static func recordedVersion(_ tool: URL) -> String? {
        (try? String(contentsOf: tool.deletingLastPathComponent().appendingPathComponent(".version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// From the first line of the release's README.txt, "OverPass Runtime 0.2.0".
    nonisolated static var runtimeVersion: String? {
        guard let text = try? String(contentsOf: dxmtDir.appendingPathComponent("README.txt"), encoding: .utf8),
              let first = text.split(separator: "\n").first, first.hasPrefix("OverPass Runtime ")
        else { return nil }
        return String(first.dropFirst("OverPass Runtime ".count))
    }

    /// The script's own WINETRICKS_VERSION line ("20260125", or "20260125-next" from git).
    nonisolated static var winetricksVersion: String? {
        guard let text = try? String(contentsOf: winetricksPath, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("WINETRICKS_VERSION=") })
        else { return nil }
        return String(line.dropFirst("WINETRICKS_VERSION=".count).prefix { $0 != "-" })
    }

    // OverPass Runtime (our DXMT build) ships as prebuilt "builtin" DLLs, laid out like CrossOver's lib/dxmt;
    // the Wine loader only uses them when a bottle selects the dxmt backend.
    private func installDXMT() async throws {
        let tarball: URL
        if let pin = ComponentCatalog.pin(.dxmt, arch: Self.arch) {
            log += "OverPass Runtime \(pin.version)\n\(pin.url.absoluteString)\n"
            tarball = try await Self.download(pin.url, sha256: pin.sha256)
        } else {
            let release = try await GitHubRelease.latest(repo: "McKack/overpass-runtime") { $0.hasSuffix(".tar.xz") }
            log += "OverPass Runtime \(release.tag)\n\(release.assetURL.absoluteString)\n"
            tarball = try await URLSession.shared.download(from: release.assetURL).0
        }
        defer { try? FileManager.default.removeItem(at: tarball) }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("overpass-runtime-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await WineInstaller.run("/usr/bin/tar", ["-xf", tarball.path, "-C", staging.path])

        // Archive root is a single version directory holding x86_64-windows/, x86_64-unix/ and, from 0.4.0, i386-windows/.
        guard let root = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("x86_64-windows/d3d11.dll").path)
        }) else { throw ComponentError.badArchive }

        let dest = Self.dxmtDir
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: root, to: dest)
        // Before OverPass Runtime this component installed upstream DXMT here.
        try? fm.removeItem(at: dest.deletingLastPathComponent().appendingPathComponent("DXMT"))
        log += "Installed to \(dest.path)\n"
    }

    private func installAddons() async throws {
        guard let wine = BottleManager.findWine() else { throw ComponentError.noWine }
        let fm = FileManager.default
        try fm.createDirectory(at: WineAddons.cacheDirectory, withIntermediateDirectories: true)
        for file in WineAddons.missing(wineRoot: wine) {
            guard let url = WineAddons.downloadURL(for: file) else { continue }
            log += "\(file)\n\(url.absoluteString)\n"
            let (download, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? fm.removeItem(at: download)
                throw ComponentError.badArchive
            }
            let dest = WineAddons.cacheDirectory.appendingPathComponent(file)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: download, to: dest)
        }
        log += "Wine add-ons are in \(WineAddons.cacheDirectory.path)\n"
    }

    // x87sidecar's release (the entitlement-free build), checked against the pinned checksum.
    private func installX87Sidecar() async throws {
        let pin = ComponentCatalog.pin(.x87sidecar, arch: Self.arch) ?? (Self.x87sidecarVersion,
            URL(string: "https://github.com/athei/x87sidecar/releases/download/v\(Self.x87sidecarVersion)/x87sidecar.tar.xz")!,
            Self.x87sidecarSHA256)
        log += "x87sidecar \(pin.version)\n\(pin.url.absoluteString)\n"
        let tarball = try await Self.download(pin.url, sha256: pin.sha256)
        defer { try? FileManager.default.removeItem(at: tarball) }
        let fm = FileManager.default
        let dest = Self.x87sidecarPath.deletingLastPathComponent()
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try await WineInstaller.run("/usr/bin/tar", ["-xf", tarball.path, "-C", dest.path])
        guard fm.isExecutableFile(atPath: Self.x87sidecarPath.path) else { throw ComponentError.badArchive }
        try pin.version.write(to: dest.appendingPathComponent(".version"), atomically: true, encoding: .utf8)
        log += "Installed to \(dest.path)\n"
    }

    /// This Mac's architecture as the catalog names it.
    nonisolated static var arch: String { isArm64 ? "arm64" : "x86_64" }

    /// Downloads a file and checks it against its pinned checksum.
    private static func download(_ url: URL, sha256: String) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              SHA256.hash(data: try Data(contentsOf: file)).map({ String(format: "%02x", $0) }).joined() == sha256
        else {
            try? FileManager.default.removeItem(at: file)
            throw ComponentError.badArchive
        }
        return file
    }

    private nonisolated static var isArm64: Bool {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "arm64"
    }

    // Legendary's single-file build for this Mac's architecture, checked against the pinned checksum.
    private func installLegendary() async throws {
        if let pin = ComponentCatalog.pin(.legendary, arch: Self.arch) {
            log += "Legendary \(pin.version)\n"
            return try await installPinnedBinary(pin.url, sha256: pin.sha256, version: pin.version, to: Self.legendaryPath)
        }
        let version = Self.legendaryVersion
        let arch = Self.isArm64 ? "arm64" : "x64"
        let url = URL(string: "https://github.com/legendary-gl/legendary/releases/download/\(version)/legendary_macOS_\(arch)")!
        log += "Legendary \(version)\n"
        try await installPinnedBinary(url, sha256: Self.legendarySHA256[arch], version: version, to: Self.legendaryPath)
    }

    // gogdl's single-file build for this Mac's architecture, checked against the pinned checksum.
    private func installGogdl() async throws {
        if let pin = ComponentCatalog.pin(.gogdl, arch: Self.arch) {
            log += "gogdl \(pin.version)\n"
            return try await installPinnedBinary(pin.url, sha256: pin.sha256, version: pin.version, to: Self.gogdlPath)
        }
        let version = Self.gogdlVersion
        let url = URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v\(version)/gogdl_macos_\(Self.arch)")!
        log += "gogdl \(version)\n"
        try await installPinnedBinary(url, sha256: Self.gogdlSHA256[Self.arch], version: version, to: Self.gogdlPath)
    }

    // No published build yet: copies xodus-cli and xodus-service from the local build folder.
    private func installXodus() async throws {
        guard let folder = UserDefaults.standard.string(forKey: "xodusLocalBuild").map(URL.init(fileURLWithPath:)) else {
            throw StoreHelper.Failure.message("Xodus isn't available for download yet.")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: Self.xodusDir)
        try fm.createDirectory(at: Self.xodusDir, withIntermediateDirectories: true)
        for name in ["xodus-cli", "xodus-service"] {
            try fm.copyItem(at: folder.appendingPathComponent(name), to: Self.xodusDir.appendingPathComponent(name))
        }
        guard Self.xodusInstalled else { throw ComponentError.badArchive }
        log += "Xodus (local build from \(folder.path))\nInstalled to \(Self.xodusDir.path)\n"
    }

    /// A one-file program, downloaded and checked against its pinned checksum, into its own folder in Tools.
    private func installPinnedBinary(_ url: URL, sha256: String?, version: String, to dest: URL) async throws {
        log += url.absoluteString + "\n"
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              SHA256.hash(data: try Data(contentsOf: file)).map({ String(format: "%02x", $0) }).joined()
                == sha256 else { throw ComponentError.badArchive }
        let fm = FileManager.default
        try? fm.removeItem(at: dest.deletingLastPathComponent())
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: file, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        try version.write(to: dest.deletingLastPathComponent().appendingPathComponent(".version"), atomically: true, encoding: .utf8)
        log += "Installed to \(dest.path)\n"
    }

    // Winetricks is a single shell script; fetch it from the latest tagged release.
    private func installWinetricks() async throws {
        let tag = try await GitHubRelease.latestTag(repo: "Winetricks/winetricks")
        let url = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(tag)/src/winetricks")!
        log += "Winetricks \(tag)\n\(url.absoluteString)\n"
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ComponentError.badArchive }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.toolsDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: Self.winetricksPath)
        try fm.moveItem(at: file, to: Self.winetricksPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.winetricksPath.path)
        log += "Installed to \(Self.winetricksPath.path)\n"
        if !["/opt/homebrew/bin/cabextract", "/usr/local/bin/cabextract"].contains(where: fm.isExecutableFile(atPath:)) {
            log += "Note: some runtimes (e.g. corefonts) also need cabextract: brew install cabextract\n"
        }
    }

    private func chooseGPTK() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit disk image (.dmg) you downloaded from Apple, or its mounted volume."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.diskImage, .folder, .volume]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Copies `redist/lib` (external/D3DMetal.framework, libd3dshared.dylib, wine/*) from the user's own
    /// GPTK download into `d3dmetalDir`.
    func importD3DMetal(from source: URL) async throws {
        var mountPoint: URL?
        var searchRoot = source
        if source.pathExtension.lowercased() == "dmg" {
            log += "Mounting \(source.lastPathComponent)…\n"
            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("overpass-gptk-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await WineInstaller.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, source.path])
            mountPoint = mount
            searchRoot = mount
        }
        defer {
            if let mountPoint {
                Task.detached { try? await WineInstaller.run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path]) }
            }
        }

        guard let lib = Self.findRedistLib(in: searchRoot) else { throw ComponentError.noD3DMetal }
        let dest = Self.d3dmetalDir
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: lib, to: dest)
        log += "Imported D3DMetal from \(lib.path)\nInstalled to \(dest.path)\n"
    }

    nonisolated static func findRedistLib(in root: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == "D3DMetal.framework" {
            // .../redist/lib/external/D3DMetal.framework → .../redist/lib
            let lib = url.deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: lib.appendingPathComponent("wine").path) { return lib }
        }
        return nil
    }

    enum ComponentError: LocalizedError {
        case noWine, badArchive, noD3DMetal
        var errorDescription: String? {
            switch self {
            case .noWine: "Install Wine first."
            case .badArchive: "The download didn't contain the expected files."
            case .noD3DMetal: "No D3DMetal found. Choose the Game Porting Toolkit .dmg from developer.apple.com (it contains redist/lib/external/D3DMetal.framework)."
            }
        }
    }
}

/// Wine Mono (.NET) and Wine Gecko (HTML rendering): the add-ons Wine offers to download when it sets up a
/// bottle. Before asking, Wine's appwiz.cpl looks for the exact .msi it wants in its download cache and installs
/// it silently from there (install_from_cache), so that's where these go. CrossOver ships them unpacked in
/// share/wine/{mono,gecko} instead; the cache keeps them out of the Wine build and shared across Wine updates.
enum WineAddons {
    static var cacheDirectory: URL {
        // Same rule as appwiz.cpl: $XDG_CACHE_HOME/wine, else ~/.cache/wine.
        let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (xdg ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache"))
            .appendingPathComponent("wine")
    }

    /// The add-on files this Wine build asks for, read from its appwiz.cpl (they're compiled in as UTF-16
    /// strings, e.g. "wine-mono-10.4.1-x86.msi"); the versions change with every Wine release.
    static func required(wineRoot: URL) -> [String] {
        var files = Set<String>()
        for arch in ["x86_64-windows", "i386-windows"] {
            let url = wineRoot.appendingPathComponent("lib/wine/\(arch)/appwiz.cpl")
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let pattern = #/wine-(?:mono|gecko)-[0-9][0-9a-z.]*-x86(?:_64)?\.msi/#
            for text in asciiUTF16Runs(data) {
                for match in text.matches(of: pattern) { files.insert(String(match.output)) }
            }
        }
        return files.sorted()
    }

    /// Runs of printable ASCII stored as UTF-16LE, at either byte alignment; a whole binary won't decode as UTF-16.
    private static func asciiUTF16Runs(_ data: Data) -> [String] {
        var runs: [String] = []
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for start in 0..<2 {
                var run = ""
                var i = start
                while i + 1 < bytes.count {
                    let (lo, hi) = (bytes[i], bytes[i + 1])
                    if hi == 0, lo >= 0x20, lo < 0x7F {
                        run.unicodeScalars.append(Unicode.Scalar(lo))
                    } else {
                        if run.count >= 12 { runs.append(run) }
                        run = ""
                    }
                    i += 2
                }
            }
        }
        return runs
    }

    /// Whether the cache holds any add-on, for any Wine version.
    static var hasAny: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        return files.contains { $0.hasPrefix("wine-mono-") || $0.hasPrefix("wine-gecko-") }
    }

    /// "Mono 10.4.1 · Gecko 2.47.4" for a list of add-on files.
    static func versions(_ files: [String]) -> String {
        var parts: [String] = []
        for (kind, title) in [("mono", "Mono"), ("gecko", "Gecko")] {
            let found = Set(files.compactMap { file -> Substring? in
                guard file.hasPrefix("wine-\(kind)-") else { return nil }
                let rest = file.dropFirst("wine-\(kind)-".count)
                return rest.range(of: "-x86").map { rest[..<$0.lowerBound] }
            })
            parts += found.sorted().map { "\(title) \($0)" }
        }
        return parts.joined(separator: " · ")
    }

    static func missing(wineRoot: URL) -> [String] {
        required(wineRoot: wineRoot).filter { !FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent($0).path) }
    }

    /// WineHQ's download location for an add-on file, the same place Wine itself downloads from.
    static func downloadURL(for file: String) -> URL? {
        for kind in ["mono", "gecko"] where file.hasPrefix("wine-\(kind)-") {
            let rest = file.dropFirst("wine-\(kind)-".count)
            guard let dash = rest.range(of: "-x86") else { return nil }
            return URL(string: "https://dl.winehq.org/wine/wine-\(kind)/\(rest[..<dash.lowerBound])/\(file)")
        }
        return nil
    }
}

enum GitHubRelease {
    struct Asset { let tag: String; let assetURL: URL }
    private struct Release: Decodable {
        struct A: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [A]
    }

    static func latest(repo: String, matching: (String) -> Bool) async throws -> Asset {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10")!
        let (data, _) = try await URLSession.shared.data(from: url)
        for r in try JSONDecoder().decode([Release].self, from: data) {
            if let a = r.assets.first(where: { matching($0.name) }) {
                return Asset(tag: r.tag_name, assetURL: a.browser_download_url)
            }
        }
        throw ComponentManager.ComponentError.badArchive
    }

    static func latestTag(repo: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }
}
