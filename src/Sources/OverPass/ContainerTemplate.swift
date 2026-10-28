import Foundation

// What `wineboot` makes for a new bottle is the same every time for one Wine build: about 1.4 GB (Wine's DLLs are
// copied into system32 and syswow64) and 10–15 seconds of work. The first bottle made with a build keeps a copy of
// that as the template; later bottles are APFS clones of it, made in a fraction of a second and sharing its disk
// space until files change. The template is taken before BottleSetup, so each bottle still gets its own.
// Bottles whose profile needs runtimes get a second kind: a template saved after those runtimes were installed
// ("overpass-wine-11.0-7+cjkfonts,corefonts,d3dcompiler_47,vcrun"), so the next launcher bottle skips running
// Microsoft's VC++ installers. That one is taken after BottleSetup; clones get them again anyway.
enum ContainerTemplate {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OverPass/Templates")
    }

    /// One template per Wine build, named after its folder ("overpass-wine-11.0-7"), plus one per runtime set.
    static func url(forWine root: URL, runtimes: Set<Runtime> = []) -> URL {
        let build = root.resolvingSymlinksInPath().lastPathComponent
        guard !runtimes.isEmpty else { return directory.appendingPathComponent(build) }
        return directory.appendingPathComponent(build + "+" + runtimes.map(\.rawValue).sorted().joined(separator: ","))
    }

    /// Makes the bottle folder `bottle` (which must not exist yet) from the template; false when there's no
    /// template, the folder exists or cloning failed.
    static func clone(into bottle: URL, wine root: URL, runtimes: Set<Runtime> = []) -> Bool {
        let template = url(forWine: root, runtimes: runtimes)
        guard FileManager.default.fileExists(atPath: template.appendingPathComponent("system.reg").path),
              !FileManager.default.fileExists(atPath: bottle.path) else { return false }
        if clonefile(template.path, bottle.path, 0) == 0 { return true }
        // Not APFS, or a different volume: an ordinary copy still saves the wineboot.
        return (try? FileManager.default.copyItem(at: template, to: bottle)) != nil
    }

    /// Keeps a just-booted bottle (or one that has just got `runtimes`) as a template for its Wine build,
    /// replacing templates of other builds. Wine must have finished writing the bottle's registry.
    static func save(from bottle: URL, wine root: URL, runtimes: Set<Runtime> = []) {
        let fm = FileManager.default
        let template = url(forWine: root, runtimes: runtimes)
        // Without Wine Mono (not downloaded yet) every clone would lack it.
        guard !fm.fileExists(atPath: template.path),
              fm.fileExists(atPath: bottle.appendingPathComponent("drive_c/windows/mono").path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".new-\(UUID().uuidString)")
        guard clonefile(bottle.path, staging.path, 0) == 0 || (try? fm.copyItem(at: bottle, to: staging)) != nil else { return }
        try? fm.removeItem(at: staging.appendingPathComponent(Bottle.configName))
        // Letters for volumes mounted while it booted belong to that moment, not to every later bottle.
        let devices = staging.appendingPathComponent("dosdevices")
        for name in (try? fm.contentsOfDirectory(atPath: devices.path)) ?? [] where !["c:", "z:"].contains(name) {
            try? fm.removeItem(at: devices.appendingPathComponent(name))
        }
        // Another bottle may have saved one meanwhile; either is fine.
        if (try? fm.moveItem(at: staging, to: template)) == nil { try? fm.removeItem(at: staging) }
        let build = url(forWine: root).lastPathComponent
        for old in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != build && !old.lastPathComponent.hasPrefix(build + "+") && !old.lastPathComponent.hasPrefix(".new-") {
            try? fm.removeItem(at: old)
        }
    }
}
