import Foundation

// Windows runtimes OverPass installs itself, following how CrossOver's component recipes do it: run the
// vendor's own installer quietly, or copy the files into place. Unlike winetricks, nothing here needs
// cabextract or other host tools. Downloads are cached and shared by all bottles; which runtimes a bottle
// has is recorded in its container.conf.
enum Runtime: String, CaseIterable, Identifiable {
    case vcrun
    case corefonts
    case d3dcompiler47 = "d3dcompiler_47"
    case cjkfonts
    case directx2010 = "directx_jun2010"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vcrun: "Visual C++ Runtime (latest)"
        case .corefonts: "Microsoft Core Fonts"
        case .d3dcompiler47: "D3D Compiler 47"
        case .cjkfonts: "Chinese, Japanese & Korean Fonts"
        case .directx2010: "DirectX June 2010 (D3DX, XAudio, XInput)"
        }
    }

    /// What launchers need, matching CrossOver's shared launcher dependencies (MSync, the last of those,
    /// is on in every bottle).
    static let launcherSet: [Runtime] = [.vcrun, .corefonts, .d3dcompiler47, .cjkfonts]

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OverPass/Runtimes")
    }

    // Microsoft's evergreen VC++ 2015–2026 redistributables. Both, since 32-bit programs need their own.
    private static let vcrunURLs = [
        URL(string: "https://aka.ms/vc14/vc_redist.x86.exe")!,
        URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!,
    ]
    // The core fonts Microsoft released for free redistribution, as its original self-extractors (mirror of
    // the SourceForge corefonts project, which winetricks uses too).
    private static let coreFonts = ["andale32", "arial32", "arialb32", "comic32", "courie32", "georgi32",
                                    "impact32", "times32", "trebuc32", "verdan32", "webdin32"]
    // Microsoft's redistributable d3dcompiler_47, as Mozilla publishes it for Firefox builds.
    private static let d3dcompilerURLs: [(url: URL, systemDir: String)] = [
        (URL(string: "https://github.com/mozilla/fxc2/raw/master/dll/d3dcompiler_47.dll")!, "system32"),
        (URL(string: "https://github.com/mozilla/fxc2/raw/master/dll/d3dcompiler_47_32.dll")!, "syswow64"),
    ]
    // Microsoft's last DirectX end-user runtime: the D3DX, XAudio/XACT and XInput DLLs that games from before
    // Windows 10 ship against. CrossOver's "DirectX for Modern Games" installs this file.
    private static let directxURL = URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!

    // Adobe's Source Han Sans, the CJK fonts CrossOver installs, as the single all-languages collection.
    private static let cjkURL = URL(string: "https://github.com/adobe-fonts/source-han-sans/releases/download/2.005R/01_SourceHanSans.ttc.zip")!

    // MARK: Installed state

    static func installed(in bottle: Bottle) -> Set<Runtime> {
        let value = BottleConfig.parse(bottle.configURL)["OverPass"]?["Runtimes"] ?? ""
        return Set(value.split(separator: ",").compactMap { Runtime(rawValue: String($0)) })
    }

    static func markInstalled(_ runtimes: Set<Runtime>, in bottle: Bottle) throws {
        var config = BottleConfig.parse(bottle.configURL)
        let current = installed(in: bottle).union(runtimes)
        config["OverPass", default: [:]]["Runtimes"] = current.map(\.rawValue).sorted().joined(separator: ",")
        try BottleConfig.write(config, to: bottle.configURL)
    }

    // MARK: Install

    @MainActor
    func install(in bottle: Bottle, using bottles: BottleManager, log: @escaping @MainActor (String) -> Void) async throws {
        log("Installing \(name)…\n")
        let fm = FileManager.default
        let fonts = bottle.driveC.appendingPathComponent("windows/Fonts")
        switch self {
        case .vcrun:
            for url in Self.vcrunURLs {
                let exe = try await Self.fetch(url)
                let status = try await bottles.run([exe.path, "/install", "/quiet", "/norestart"], in: bottle, log: log)
                // 3010 is "installed, reboot required", which a Wine bottle doesn't need.
                guard status == 0 || status == 3010 else { throw RuntimeError.installerFailed(exe.lastPathComponent, status) }
            }

        case .corefonts:
            let ttfs = try await Self.unpackOnce(self) { staging in
                // Each is an IExpress self-extractor: /T: picks the folder, /C extracts without installing, /Q is quiet.
                let tempWindows = "C:\\windows\\Temp\\overpass-corefonts"
                let tempHost = bottle.driveC.appendingPathComponent("windows/Temp/overpass-corefonts")
                defer { try? fm.removeItem(at: tempHost) }
                for font in Self.coreFonts {
                    let exe = try await Self.fetch(URL(string: "https://github.com/pushcx/corefonts/raw/master/\(font).exe")!)
                    try? fm.removeItem(at: tempHost)
                    _ = try await bottles.run([exe.path, "/T:\(tempWindows)", "/C", "/Q"], in: bottle, log: log)
                    let files = (try? fm.contentsOfDirectory(at: tempHost, includingPropertiesForKeys: nil)) ?? []
                    let ttfs = files.filter { $0.pathExtension.lowercased() == "ttf" }
                    guard !ttfs.isEmpty else { throw RuntimeError.nothingExtracted(exe.lastPathComponent) }
                    for ttf in ttfs { try Self.replace(staging.appendingPathComponent(ttf.lastPathComponent), with: ttf) }
                }
            }
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            for ttf in ttfs { try Self.replace(fonts.appendingPathComponent(ttf.lastPathComponent), cloning: ttf) }

        case .d3dcompiler47:
            for (url, dir) in Self.d3dcompilerURLs {
                let dll = try await Self.fetch(url)
                // A real DLL in place of Wine's placeholder is loaded as native; no override needed.
                try Self.replace(bottle.driveC.appendingPathComponent("windows/\(dir)/d3dcompiler_47.dll"), cloning: dll)
            }

        case .directx2010:
            // As CrossOver's recipe does: unpack the redistributable, then run DXSETUP while the bottle reports
            // Windows XP to it (only to that program, through Wine's AppDefaults), then restart the bottle.
            let exe = try await Self.fetch(Self.directxURL)
            let tempWindows = "C:\\windows\\Temp\\overpass-directx"
            let tempHost = bottle.driveC.appendingPathComponent("windows/Temp/overpass-directx")
            defer { try? fm.removeItem(at: tempHost) }
            try? fm.removeItem(at: tempHost)
            _ = try await bottles.run([exe.path, "/Q", "/T:\(tempWindows)"], in: bottle, log: log)
            guard let setup = WindowsIcons.caseInsensitive(tempHost, "DXSETUP.exe") else {
                throw RuntimeError.nothingExtracted(exe.lastPathComponent)
            }
            let appDefaults = "HKCU\\Software\\Wine\\AppDefaults\\DXSETUP.exe"
            _ = try await bottles.run(["reg", "add", appDefaults, "/v", "Version", "/d", "winxp", "/f"], in: bottle, log: log)
            let status = try await bottles.run([setup.path, "/silent"], in: bottle, log: log)
            _ = try await bottles.run(["reg", "delete", appDefaults, "/f"], in: bottle, log: log)
            _ = try await bottles.run(["wineboot", "-r"], in: bottle, log: log)
            guard status == 0 else { throw RuntimeError.installerFailed(setup.lastPathComponent, status) }

        case .cjkfonts:
            let ttcs = try await Self.unpackOnce(self) { staging in
                let zip = try await Self.fetch(Self.cjkURL)
                let unzipped = fm.temporaryDirectory.appendingPathComponent("overpass-cjk-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: unzipped) }
                try await WineInstaller.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
                guard let ttc = fm.enumerator(at: unzipped, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "ttc" })
                else { throw RuntimeError.nothingExtracted(zip.lastPathComponent) }
                try Self.replace(staging.appendingPathComponent(ttc.lastPathComponent), with: ttc)
            }
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            for ttc in ttcs { try Self.replace(fonts.appendingPathComponent(ttc.lastPathComponent), cloning: ttc) }
        }
        try Self.markInstalled([self], in: bottle)
        log("\(name) installed.\n")
    }

    /// Downloads once into the shared cache; later bottles reuse the file.
    private static func fetch(_ url: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let dest = cacheDirectory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { return dest }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? fm.removeItem(at: tmp)
            throw RuntimeError.downloadFailed(url)
        }
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    private static func replace(_ dest: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: source, to: dest)
    }

    /// An APFS clone shares the source's disk space until either file changes; elsewhere it's an ordinary copy.
    private static func replace(_ dest: URL, cloning source: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        if clonefile(source.path, dest.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: dest)
    }

    /// Runtimes that are only files (fonts) are unpacked once, into the cache beside their downloads; later
    /// bottles get clones of those files instead of unpacking and storing their own.
    private static func unpackOnce(_ runtime: Runtime, into make: (URL) async throws -> Void) async throws -> [URL] {
        let fm = FileManager.default
        let folder = cacheDirectory.appendingPathComponent("Unpacked/\(runtime.rawValue)")
        let files = { (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] }
        if !files().isEmpty { return files() }
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".new-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try await make(staging)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
        return files()
    }

    enum RuntimeError: LocalizedError {
        case downloadFailed(URL), installerFailed(String, Int32), nothingExtracted(String)
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let url): "Couldn't download \(url.lastPathComponent)."
            case .installerFailed(let file, let status): "\(file) failed (exit code \(status))."
            case .nothingExtracted(let file): "\(file) didn't contain the expected files."
            }
        }
    }
}
