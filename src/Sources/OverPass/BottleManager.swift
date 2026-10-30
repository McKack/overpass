import Foundation
import AppKit

@MainActor
@Observable
class BottleManager {
    var bottles: [Bottle] = []
    /// Paths of Mac apps added to the library (MacApps.swift).
    var macApps = MacApps.paths() { didSet { MacApps.save(macApps) } }
    var wineRoot: URL?
    /// Programs started from OverPass that haven't shown a window yet, for the status bar.
    var launches: [Launch] = []
    /// Runtimes being set up for games a client installed, for the status bar.
    var recipeTasks: [RecipeTask] = []
    private var recipeBottlesBusy: Set<URL> = []
    private var defaultsBusy: Set<URL> = []
    /// The light or dark look last written to each bottle this session; user.reg lags behind a running Wine.
    private var appearanceWritten: [URL: Bool] = [:]
    /// Programs running with Wine's log on, for Collect Logs (LogCollector.swift).
    var logRecordings: [LogRecording] = []

    struct RecipeTask: Identifiable {
        let id = UUID()
        let message: String
        var failed: String?
    }

    /// Profiles being installed or removed, so their Home tiles can show a spinner.
    var busyProfiles: Set<String> = []
    /// Set by the app, so a launch can apply its bottle's profile options.
    var profiles: ProfileStore?

    struct Launch: Identifiable {
        let id = UUID()
        let name: String
        let bottlePath: URL
        /// The host path OverPass was asked to run.
        let program: String
        var state: State = .starting

        enum State { case starting, slow, crashed }
    }

    init() {
        detectWine()
        loadBottles()
        yieldActivationToWine()
        followMacAppearance()
        watchForCrashes()
    }

    /// The title last run in each container, and the last one anywhere, for a crash report.
    private var lastRun: [URL: LibraryItem] = [:]
    private var lastRunAnywhere: LibraryItem?
    static let reportCrashesKey = "reportCrashes"

    /// The library title a running Windows program belongs to: by its program's file name in its container, or the
    /// title last run there (a game started through its launcher), or that container's first title. Nil in a container
    /// without titles; the last one run anywhere only for a process in no known container.
    func reportItem(forProcess pid: pid_t) -> LibraryItem? {
        guard let root = wineRoot, let process = WineProcess.all(under: root).first(where: { $0.pid == pid }) else {
            return lastRunAnywhere
        }
        let location = URL(fileURLWithPath: process.location).resolvingSymlinksInPath().path
        let bottle = bottles.first {
            let path = $0.path.resolvingSymlinksInPath().path
            return location == path || location.hasPrefix(path + "/")
        }
        let program = process.displayName.lowercased()
        let titles = library.filter { bottle == nil || $0.bottle.path == bottle?.path }
        return titles.first { ($0.app.target.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }?
                                .lowercased().replacingOccurrences(of: ".exe", with: "")) == program }
            ?? (bottle.map { lastRun[$0.path] ?? titles.first } ?? lastRunAnywhere ?? titles.first)
    }

    /// Opens the report window when Wine's crash handler starts (ReportCenter.swift). A crash during a run with
    /// extra debugging is reported when that run ends, with its log. Crash handlers already running when
    /// OverPass starts aren't reported.
    private func watchForCrashes() {
        Task { [weak self] in
            var seen: Set<pid_t>?
            while let self {
                try? await Task.sleep(for: .seconds(2))
                guard let root = wineRoot else { continue }
                let handlers = await Task.detached { WineProcess.all(under: root).filter(\.isCrashHandler) }.value
                let pids = Set(handlers.map(\.pid))
                guard let known = seen else { seen = pids; continue }
                seen = pids
                guard UserDefaults.standard.object(forKey: Self.reportCrashesKey) as? Bool ?? true else { continue }
                for handler in handlers where !known.contains(handler.pid) {
                    let location = URL(fileURLWithPath: handler.location).resolvingSymlinksInPath().path
                    let bottle = bottles.first {
                        let path = $0.path.resolvingSymlinksInPath().path
                        return location == path || location.hasPrefix(path + "/")
                    }
                    if let index = logRecordings.firstIndex(where: { $0.bottle.path == (bottle ?? $0.bottle).path }) {
                        logRecordings[index].crashed = true
                        continue
                    }
                    guard let item = bottle.flatMap({ self.lastRun[$0.path] }) ?? lastRunAnywhere else { continue }
                    ReportCenter.shared.show(ReportContext(item: item, mode: .crash))
                }
            }
        }
    }

    /// Since macOS 14 an app can only come to the front when the frontmost app hands over. Wine asks for that
    /// with a distributed notification that only other Wine processes answered, so games and launchers started
    /// from OverPass opened behind it (and behind its full-screen space).
    private func yieldActivationToWine() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("WineAppWillActivateNotification"), object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?["ActivatingAppPID"] as? NSNumber)?.int32Value else { return }
            MainActor.assumeIsolated { self?.yieldActivation(toWine: pid) }
        }
    }

    private func yieldActivation(toWine pid: pid_t) {
        guard NSApp.isActive, let root = wineRoot,
              let app = NSRunningApplication(processIdentifier: pid),
              let path = app.executableURL?.path, WineProcess.runsWine(under: root)(path) else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// Every app across all bottles, and the Mac apps added: the library the main window shows.
    var library: [LibraryItem] {
        (bottles.flatMap { b in b.apps.map { personalized(LibraryItem(app: $0, bottle: b)) } }
            + MacApps.apps(macApps).map { LibraryItem(app: $0, bottle: .mac) })
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    /// An app as its profile names and pictures it, when someone changed that in OverPass.
    private func personalized(_ item: LibraryItem) -> LibraryItem {
        guard let profiles, let profile = profiles.profile(for: item) else { return item }
        var app = item.app
        app.engine = profile.engine
        guard profiles.edited.contains(profile.id) || profiles.custom.contains(profile.id) else {
            return LibraryItem(app: app, bottle: item.bottle)
        }
        app.name = profile.name
        if let icon = profile.icon {
            let url = UserProfiles.iconsDirectory.appendingPathComponent(icon)
            if FileManager.default.fileExists(atPath: url.path) { app.icon = url.path }
        }
        if profile.cover == ArtStyle.generatedCover {
            app.generatedCover = true
        } else if let cover = profile.cover {
            let url = UserProfiles.coversDirectory.appendingPathComponent(cover)
            if FileManager.default.fileExists(atPath: url.path) { app.cover = url.path }
        }
        if profile.coverStyle != nil || profile.iconStyle != nil {
            let color = clientColor(for: item.bottle, in: profiles)
            app.coverStyle = profile.coverStyle.map { ArtStyle($0, default: .cover).withClient(color) }
            app.iconStyle = profile.iconStyle.map { ArtStyle($0, default: .icon).withClient(color) }
        }
        return LibraryItem(app: app, bottle: item.bottle)
    }

    /// The titles in a built-in category: Mac apps, or Windows titles outside every game client's bottle.
    func titles(in category: BuiltInCategory) -> [LibraryItem] {
        switch category {
        case .mac:
            return library.filter(\.bottle.isMac)
        case .other:
            let clientBottles = Set((profiles.map(installedClients) ?? []).compactMap { bottle(for: $0)?.path })
            return library.filter { !$0.bottle.isMac && !clientBottles.contains($0.bottle.path) }
        }
    }

    /// The bottle a profile was installed into: its own, or one shared through the profile's bottle group.
    func bottle(for profile: GameProfile) -> Bottle? {
        bottles.first { b in
            b.profileID == profile.id || (profile.bottle.group != nil && b.group == profile.bottle.group)
        }
    }

    /// The brand colour of the game client whose bottle this is.
    func clientColor(for bottle: Bottle, in profiles: ProfileStore) -> String? {
        installedClients(from: profiles).first { self.bottle(for: $0)?.path == bottle.path }?.brandColor
    }

    /// Game clients (store launchers) that have been installed, in profile order.
    func installedClients(from profiles: ProfileStore) -> [GameProfile] {
        // A built-in library's store counts once signed in, before any of its games is installed.
        profiles.profiles.filter {
            $0.category == "Game Launcher" && (bottle(for: $0) != nil || BuiltInLibrary.signedIn($0.bottle.group))
        }
    }

    /// Games in a store launcher's bottle, with the launcher itself first when `includeClient` is set.
    func games(of launcher: GameProfile, includeClient: Bool = true) -> [LibraryItem] {
        guard let bottle = bottle(for: launcher) else { return [] }
        let items = library.filter { $0.bottle.path == bottle.path }
        let isClient = { self.isClient($0, of: launcher) }
        return (includeClient ? items.filter(isClient) : []) + items.filter { !isClient($0) }
    }

    /// Whether an app in the launcher's bottle is the launcher itself. A game found through the launcher's
    /// records starts through the launcher's own program (steam.exe steam://rungameid/...), so only shortcuts
    /// are checked.
    func isClient(_ item: LibraryItem, of launcher: GameProfile) -> Bool {
        let client = launcher.launch.map { hostPath($0.executable, in: item.bottle).standardizedFileURL.path }
        return item.app.launcher == nil
            && (URL(fileURLWithPath: item.app.executable).standardizedFileURL.path == client
                || item.app.name.localizedCaseInsensitiveContains(launcher.name))
    }

    // Prefer the Wine the setup wizard downloaded; fall back to a manual Wine.app or brew install.
    func detectWine() {
        wineRoot = Self.findWine()
    }

    nonisolated static func findWine() -> URL? {
        let candidates = [
            WineInstaller.currentWine.path,
            "/Applications/Wine Devel.app/Contents/Resources/wine",
            "/Applications/Wine Staging.app/Contents/Resources/wine",
            "/Applications/Wine Stable.app/Contents/Resources/wine",
            "/opt/homebrew",
            "/usr/local",
        ]
        return candidates.map { URL(fileURLWithPath: $0) }.first { wineBinary(in: $0) != nil }
    }

    /// Wine 9+ (new WoW64) ships only `wine`; older builds had `wine64`.
    nonisolated static func wineBinary(in root: URL) -> URL? {
        ["wine", "wine64"].map { root.appendingPathComponent("bin/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func loadBottles() {
        bottles = ContainerLocations.all.flatMap(ContainerLocations.containers(in:)).map { Self.loadBottle(at: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        AppWrappers.sync(library.filter { !$0.bottle.isMac })
        applyBottleSetup()
        syncAppearance()
        applyGameRecipes()
    }

    /// Bottles that follow the Mac's light or dark look get it written to their registry when it differs, at start and
    /// whenever the Mac switches. Programs already running keep the look they started with.
    func syncAppearance() {
        guard wineRoot != nil else { return }
        for bottle in bottles where !bottle.isMac && !defaultsBusy.contains(bottle.path) {
            let light = BottleSetup.appearance(of: bottle).usesLightTheme
            guard let current = appearanceWritten[bottle.path] ?? BottleSetup.usesLightTheme(in: bottle)
                    ?? (BottleSetup.applied(to: bottle) ? true : nil), current != light else { continue }
            appearanceWritten[bottle.path] = light
            Task {
                if (try? await BottleSetup.setLightTheme(light, in: bottle, using: self)) == nil {
                    appearanceWritten[bottle.path] = nil
                }
            }
        }
    }

    private func followMacAppearance() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAppearance() }
        }
    }

    /// Bottles made before OverPass set its defaults (or an older set of them) get them, once, in the background.
    private func applyBottleSetup() {
        guard wineRoot != nil else { return }
        for bottle in bottles where !BottleSetup.applied(to: bottle) && !defaultsBusy.contains(bottle.path)
            && FileManager.default.fileExists(atPath: bottle.driveC.path) {
            defaultsBusy.insert(bottle.path)
            Task {
                // A bottle that failed stays marked until OverPass restarts, so it isn't retried on every refresh.
                if (try? await BottleSetup.apply(to: bottle, using: self)) != nil { defaultsBusy.remove(bottle.path) }
            }
        }
    }

    /// A game installed through a client gets its profile's runtimes in that client's bottle, whichever store it
    /// came from: a profile matches by Steam app ID or GOG product ID. Runs in the background, one bottle at a time.
    func applyGameRecipes() {
        guard let profiles = profiles?.profiles, wineRoot != nil else { return }
        for bottle in bottles where !recipeBottlesBusy.contains(bottle.path) {
            let have = Runtime.installed(in: bottle)
            var missing: [(game: String, runtime: Runtime)] = []
            for game in LauncherGames.storeGames(bottlePath: bottle.path) {
                guard let profile = profiles.first(where: { p in
                    switch game.store {
                    case .steam: p.steamAppID.map(String.init) == game.id
                    case .gog: p.gogGameID == game.id
                    }
                }) else { continue }
                for runtime in profile.runtimes.compactMap(Runtime.init(rawValue:))
                where !have.contains(runtime) && !missing.contains(where: { $0.runtime == runtime }) {
                    missing.append((profile.name, runtime))
                }
            }
            guard !missing.isEmpty else { continue }
            recipeBottlesBusy.insert(bottle.path)
            Task {
                for (game, runtime) in missing {
                    let task = RecipeTask(message: "Setting up \(runtime.name) for \(game)…")
                    recipeTasks.append(task)
                    do {
                        try await runtime.install(in: bottle, using: self) { _ in }
                        recipeTasks.removeAll { $0.id == task.id }
                    } catch {
                        if let i = recipeTasks.firstIndex(where: { $0.id == task.id }) {
                            recipeTasks[i].failed = "Couldn't set up \(runtime.name) for \(game): \(error.localizedDescription)"
                        }
                        break
                    }
                }
                // A failed bottle stays marked until OverPass restarts, so it isn't retried on every refresh.
                if !recipeTasks.contains(where: { $0.failed != nil }) { recipeBottlesBusy.remove(bottle.path) }
            }
        }
    }

    nonisolated static func loadBottle(at url: URL) -> Bottle {
        BottleConfig.migrate(in: url)
        let config = BottleConfig.parse(url.appendingPathComponent(Bottle.configName))
        let container = config["Container"] ?? [:]
        let overpass = config["OverPass"] ?? [:]
        return Bottle(
            id: UUID(uuidString: container["ID"] ?? "") ?? UUID(),
            name: url.lastPathComponent,
            path: url,
            template: WineTemplate(rawValue: container["Template"] ?? "windows10") ?? .windows10,
            wineArch: container["Arch"] ?? "win64",
            description: container["Description"] ?? "",
            group: overpass["Group"],
            profileID: overpass["ProfileID"],
            graphics: GraphicsBackend(rawValue: overpass["Graphics"] ?? "") ?? .auto,
            direct3D9: Direct3D9Backend(rawValue: overpass["Direct3D9"] ?? "") ?? .auto,
            environment: config["Environment"] ?? [:],
            apps: mergeApps(scanApps(in: url), LauncherGames.scan(bottlePath: url))
        )
    }

    /// A bottle name not yet taken, derived from `base` ("Steam", "Steam 2", …).
    func freeBottleName(_ base: String) -> String {
        let cleaned = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let root = cleaned.isEmpty ? "Bottle" : cleaned
        var name = root
        var n = 2
        // Unique across locations, so a container can move to any of them.
        while ([Bottle.bottlesDirectory()] + ContainerLocations.added).contains(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path)
        }) {
            name = "\(root) \(n)"
            n += 1
        }
        return name
    }

    @discardableResult
    func createBottle(name: String, template: WineTemplate, group: String? = nil, profileID: String? = nil,
                      graphics: GraphicsBackend = .auto, environment: [String: String] = [:],
                      runtimes: Set<Runtime> = [], location: URL? = nil) async throws -> Bottle {
        let location = location ?? ContainerLocations.favorite
        let dir = location.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        // DLL overrides can change what wineboot installs (a profile turning off Mono), so those bottles boot their own.
        let useTemplate = environment["WINEDLLOVERRIDES"] == nil
        // A template that already has the profile's runtimes saves running their installers too.
        let withRuntimes = useTemplate && !runtimes.isEmpty
            && (wineRoot.map { ContainerTemplate.clone(into: dir, wine: $0, runtimes: runtimes) } ?? false)
        let cloned = withRuntimes || useTemplate && (wineRoot.map { ContainerTemplate.clone(into: dir, wine: $0) } ?? false)
        if !cloned { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        var overpass = ["Graphics": graphics.rawValue]
        // Applied below; this keeps loadBottles from starting a second copy in the background.
        overpass["Defaults"] = String(BottleSetup.version)
        overpass["Group"] = group
        overpass["ProfileID"] = profileID
        let config: [String: [String: String]] = [
            "Container": [
                "ID": UUID().uuidString,
                "Created": "\(Int(Date().timeIntervalSince1970))",
                "Template": template.rawValue,
                "Arch": "win64",
                "Description": name,
            ],
            "Environment": ["WINEMSYNC": "1"].merging(environment) { $1 },
            "OverPass": overpass,
        ]
        try BottleConfig.write(config, to: dir.appendingPathComponent(Bottle.configName))
        loadBottles()
        guard let bottle = bottles.first(where: { $0.path.standardizedFileURL == dir.standardizedFileURL }) else {
            throw WineError.noWineInstallation
        }

        if let root = wineRoot {
            do {
                if !cloned {
                    _ = try await run(["wineboot", "--init"], in: bottle)
                    if useTemplate {
                        // The template needs the registry on disk, which Wine writes when its server exits.
                        await waitForWineserver(in: bottle)
                        await Task.detached { ContainerTemplate.save(from: dir, wine: root) }.value
                    }
                }
                try await BottleSetup.apply(to: bottle, using: self)
                ContainerDrives.tidy(bottle)
                if withRuntimes { try Runtime.markInstalled(runtimes, in: bottle) }
            } catch {
                // Don't leave a half-made bottle behind for the next attempt to trip over.
                try? FileManager.default.removeItem(at: dir)
                loadBottles()
                throw error
            }
        }
        return bottle
    }

    /// Keeps a new bottle that has just got `runtimes` (and nothing else yet) as the template for that set.
    func saveRuntimeTemplate(from bottle: Bottle, runtimes: Set<Runtime>) async {
        guard let root = wineRoot, !runtimes.isEmpty,
              !FileManager.default.fileExists(atPath: ContainerTemplate.url(forWine: root, runtimes: runtimes).path) else { return }
        await waitForWineserver(in: bottle)
        let dir = bottle.path
        await Task.detached { ContainerTemplate.save(from: dir, wine: root, runtimes: runtimes) }.value
    }

    /// Moves a container to another location, closing what runs in it first. Returns it at its new place.
    @discardableResult
    func moveBottle(_ bottle: Bottle, to location: URL) async throws -> Bottle {
        await quitEverything(in: bottle)
        await waitForWineserver(in: bottle)
        let from = bottle.path
        let moved = try await Task.detached { try ContainerLocations.move(from, to: location) }.value
        ProfileWindow.movedContainers[from.path] = moved.path
        loadBottles()
        return bottles.first { $0.path.standardizedFileURL == moved.standardizedFileURL } ?? bottle
    }

    /// Writes the bottle to one archive file (ContainerArchive.swift), closing what runs in it first.
    func exportBottle(_ bottle: Bottle, to archive: URL) async throws {
        await quitEverything(in: bottle)
        await waitForWineserver(in: bottle)
        let path = bottle.path
        try await Task.detached { try ContainerArchive.export(path, to: archive) }.value
    }

    /// Adds the container in `archive` to `location` under a name no other container has, shown in the status bar
    /// meanwhile. `wineboot -u` then brings it to this Wine build and this Mac's user folders.
    @discardableResult
    func importBottle(from archive: URL, to location: URL? = nil) async -> Bottle? {
        let location = location ?? ContainerLocations.favorite
        let task = RecipeTask(message: "Importing \(archive.lastPathComponent)…")
        recipeTasks.append(task)
        do {
            let (folder, name) = try await Task.detached { try ContainerArchive.unpack(archive, near: location) }.value
            let unique = freeBottleName(name)
            let placed = try await Task.detached { try ContainerArchive.place(folder, as: unique, in: location) }.value
            loadBottles()
            guard let bottle = bottles.first(where: { $0.path.standardizedFileURL == placed.standardizedFileURL }) else {
                throw ContainerArchive.ArchiveError.noContainer(archive.lastPathComponent)
            }
            ContainerDrives.tidy(bottle)
            if wineRoot != nil {
                _ = try await run(["wineboot", "-u"], in: bottle)
                await waitForWineserver(in: bottle)
            }
            recipeTasks.removeAll { $0.id == task.id }
            loadBottles()
            return bottles.first { $0.path == bottle.path } ?? bottle
        } catch {
            if let i = recipeTasks.firstIndex(where: { $0.id == task.id }) {
                recipeTasks[i].failed = "Couldn't import \(archive.lastPathComponent): \(error.localizedDescription)"
            }
            return nil
        }
    }

    func deleteBottle(_ bottle: Bottle) async throws {
        // wineserver lingers after the last process exits and would rewrite *.reg into the deleted folder.
        await quitEverything(in: bottle)
        let path = bottle.path
        try await Task.detached {
            try FileManager.default.removeItem(at: path)
        }.value
        loadBottles()
    }

    /// Waits until the bottle's wineserver has exited (a few seconds after its last program).
    func waitForWineserver(in bottle: Bottle) async {
        guard let root = wineRoot, let wine = Self.wineBinary(in: root) else { return }
        let process = Process()
        process.executableURL = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        process.arguments = ["-w"]
        process.environment = buildWineEnv(for: bottle, wine: wine)
        await Task.detached {
            if (try? process.run()) != nil { process.waitUntilExit() }
        }.value
    }

    /// Ends every Windows program running in the bottle, and its wineserver.
    func quitEverything(in bottle: Bottle) async {
        guard let root = wineRoot, let wine = Self.wineBinary(in: root) else { return }
        let process = Process()
        process.executableURL = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        process.arguments = ["-k"]
        process.environment = buildWineEnv(for: bottle, wine: wine)
        await Task.detached {
            if (try? process.run()) != nil { process.waitUntilExit() }
        }.value
        // Hung programs (a busy loop, a lost wineserver) ignore that; give them a few seconds, then force them.
        for _ in 0..<6 {
            if WineProcess.all(under: root, in: bottle.path).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        for process in WineProcess.all(under: root, in: bottle.path) { kill(process.pid, SIGKILL) }
    }

    /// Wine's own background programs, which aren't what anyone started.
    nonisolated static let wineServices: Set<String> = ["wineserver", "services.exe", "winedevice.exe", "plugplay.exe",
        "svchost.exe", "explorer.exe", "rpcss.exe", "conhost.exe", "start.exe", "tabtip.exe", "winedbg.exe"]

    /// Windows programs running in the bottle, apart from Wine's own background services.
    func runningPrograms(in bottle: Bottle) -> [WineProcess] {
        guard let root = wineRoot else { return [] }
        return WineProcess.all(under: root, in: bottle.path).filter { p in
            let name = (p.commandLine.split(separator: " ").first.map(String.init) ?? "")
                .replacingOccurrences(of: "\\", with: "/")
            return !Self.wineServices.contains((name as NSString).lastPathComponent.lowercased())
        }
    }

    func launchApp(_ app: WineApp, in bottle: Bottle) throws {
        RecentTitles.add(LibraryItem(app: app, bottle: bottle).id)
        lastRun[bottle.path] = LibraryItem(app: app, bottle: bottle)
        lastRunAnywhere = LibraryItem(app: app, bottle: bottle)
        if bottle.isMac { return MacApps.open(app) }
        if app.backend == .legendary, let appName = app.storeID { return launchEpic(app, appName: appName, in: bottle) }
        if app.backend == .xodus, let id = app.storeID { return launchXbox(app, id: id, in: bottle) }
        try runExe(app.executable, in: bottle, arguments: app.arguments, name: app.name)
    }

    /// An Epic game installed through Legendary: Legendary fetches a one-time launch token, then the game
    /// runs like any other program in the bottle.
    private func launchEpic(_ app: WineApp, appName: String, in bottle: Bottle) {
        let task = RecipeTask(message: "Getting \(app.name) ready to start…")
        recipeTasks.append(task)
        Task {
            do {
                let launch = try await EpicStore.launchParameters(appName)
                recipeTasks.removeAll { $0.id == task.id }
                try runExe(launch.exe, in: bottle, arguments: app.arguments + launch.arguments, name: app.name,
                           extraEnv: launch.environment)
            } catch {
                if let i = recipeTasks.firstIndex(where: { $0.id == task.id }) {
                    recipeTasks[i].failed = "\(app.name) couldn't start: \(error.localizedDescription)"
                }
            }
        }
    }

    private func launchXbox(_ app: WineApp, id: String, in bottle: Bottle) {
        let task = RecipeTask(message: "Getting \(app.name) ready to start…")
        recipeTasks.append(task)
        Task {
            do {
                try await XboxStore.launch(app, id: id, in: bottle, using: self)
                recipeTasks.removeAll { $0.id == task.id }
            } catch {
                if let i = recipeTasks.firstIndex(where: { $0.id == task.id }) {
                    recipeTasks[i].failed = "\(app.name) couldn't start: \(error.localizedDescription)"
                }
            }
        }
    }

    func runExe(_ path: String, in bottle: Bottle, arguments: [String] = [], name: String? = nil,
                extraEnv: [String: String] = [:], output: FileHandle? = nil) throws {
        if let root = wineRoot, WineProcess.all(under: root, in: bottle.path).isEmpty { ContainerDrives.tidy(bottle) }
        clearStaleFiles(in: bottle)
        let process = try exeProcess(path, in: bottle, arguments: arguments)
        process.environment?.merge(extraEnv) { $1 }
        let name = name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // A program run some other way than from the library (Quick Run) is what a crash report is about then.
        if lastRun[bottle.path]?.app.executable != path {
            let item = LibraryItem(app: WineApp(name: name, executable: path), bottle: bottle)
            lastRun[bottle.path] = item
            lastRunAnywhere = item
        }
        // Without a log of its own, a run keeps Wine's errors in its last-run log (Report Issue › Send Last Logs).
        if let output = output ?? LogCollector.lastRunHandle(name, in: bottle) {
            if extraEnv["WINEDEBUG"] == nil { process.environment?["WINEDEBUG"] = LogCollector.lastRunChannels(for: bottle) }
            process.standardOutput = output
            process.standardError = output
        }
        try process.run()
        track(name, program: path, process: process, in: bottle)
    }

    func addMacApps(_ urls: [URL]) {
        let new = urls.filter { $0.pathExtension == "app" }.map(\.path).filter { !macApps.contains($0) }
        macApps += new
    }

    func removeMacApp(_ item: LibraryItem) {
        macApps.removeAll { $0 == item.app.executable }
    }

    /// Whether something (or this program) is still starting in the bottle; a crashed start doesn't count.
    func isOpening(in bottle: Bottle, program: String? = nil) -> Bool {
        launches.contains { $0.bottlePath == bottle.path && $0.state != .crashed && (program == nil || $0.program == program) }
    }

    func dismissLaunch(_ id: Launch.ID) {
        launches.removeAll { $0.id == id }
    }

    /// Follows a launch until the program shows a window (brought forward), Wine's crash handler starts in its
    /// bottle (reported right away; Wine's own dialog takes a while), or it gives up after five minutes.
    private func track(_ name: String, program: String, process: Process, in bottle: Bottle) {
        guard let root = wineRoot else { return }
        let launch = Launch(name: name, bottlePath: bottle.path, program: program)
        launches.append(launch)
        let bottlePath = bottle.path
        let windowsBefore = Set(wineWindows().map(\.processIdentifier))
        let crashesBefore = Set(WineProcess.all(under: root, in: bottlePath).filter(\.isCrashHandler).map(\.pid))
        let start = Date.now
        Task {
            while launches.contains(where: { $0.id == launch.id }) {
                try? await Task.sleep(for: .seconds(1))
                let running = WineProcess.all(under: root, in: bottlePath)
                guard let index = launches.firstIndex(where: { $0.id == launch.id }) else { return }
                if running.contains(where: { $0.isCrashHandler && !crashesBefore.contains($0.pid) }) {
                    launches[index].state = .crashed
                    return
                }
                // The crash handler's own window doesn't count as the program starting.
                let pids = Set(running.filter { !$0.isCrashHandler }.map(\.pid))
                // A program outside drive_c (an installer in Downloads, Quick Run) can't be told apart by
                // container: Wine overwrites its environment with the Windows command line, and its folder isn't
                // in the container. A Wine process started since the launch counts too.
                let windows = wineWindows().filter {
                    pids.contains($0.processIdentifier) || (WineProcess.startDate(of: $0.processIdentifier) ?? .distantPast) >= start
                        && !Self.wineServices.contains(($0.localizedName ?? "").lowercased() + ".exe")
                }
                // A program that's already open often hands over to its running copy and exits.
                if let window = windows.first(where: { !windowsBefore.contains($0.processIdentifier) })
                    ?? (process.isRunning ? nil : windows.first) {
                    window.activate()
                    dismissLaunch(launch.id)
                    return
                }
                let elapsed = Date.now.timeIntervalSince(start)
                if elapsed > 300 {
                    dismissLaunch(launch.id)
                } else if elapsed > 60 {
                    launches[index].state = .slow
                }
            }
        }
    }

    /// Files a program leaves behind when it crashes and then trips over (GOG Galaxy's lock files), removed
    /// only while nothing runs in the bottle.
    private func clearStaleFiles(in bottle: Bottle) {
        guard let root = wineRoot, let id = bottle.profileID,
              let launch = profiles?.profiles.first(where: { $0.id == id })?.launch,
              !launch.staleFiles.isEmpty || !launch.jsonSettings.isEmpty,
              WineProcess.all(under: root, in: bottle.path).isEmpty else { return }
        // The program rewrites its settings when it exits, so only change them while it isn't running.
        for setting in launch.jsonSettings {
            let url = hostPath(setting.file, in: bottle)
            guard let data = try? Data(contentsOf: url),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json[setting.key] as? String != setting.value else { continue }
            json[setting.key] = setting.value
            if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: url, options: .atomic)
            }
        }
        let patterns = launch.staleFiles
        let fm = FileManager.default
        for pattern in patterns {
            let host = hostPath(pattern, in: bottle)
            let dir = host.deletingLastPathComponent()
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where GameProfile.wildcard(pattern: host.lastPathComponent, matches: name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// The configured but not yet started process that runs a program; also used by app wrappers.
    func exeProcess(_ path: String, in bottle: Bottle, arguments: [String] = []) throws -> Process {
        var path = path, arguments = arguments
        var ruleEnv: [String: String] = [:]
        // A program started through `start` is created by Windows code, so OverPass Wine applies the rules to it
        // (and runs it from an app bundle, which macOS needs for Game Mode); others get them applied here.
        if !Self.startsThroughStart(path) {
            CompatRules.apply(to: &path, arguments: &arguments, environment: &ruleEnv, graphicsChosen: bottle.graphics != .auto)
        }
        let process = try wineProcess(for: bottle, args: Self.launchArgs(path) + arguments)
        process.environment?.merge(ruleEnv) { $1 }
        process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        return process
    }

    /// Runs Wine in the bottle and waits for it to exit, streaming output to `log`. Returns the exit status.
    func run(_ args: [String], in bottle: Bottle, extraEnv: [String: String] = [:],
             log: (@MainActor (String) -> Void)? = nil) async throws -> Int32 {
        let process = try wineProcess(for: bottle, args: args)
        process.environment?.merge(extraEnv) { $1 }
        return try await Self.runStreaming(process, log: log)
    }

    /// Runs an arbitrary tool (e.g. winetricks) with the bottle's Wine environment.
    func runTool(_ tool: URL, _ args: [String], in bottle: Bottle,
                 log: (@MainActor (String) -> Void)? = nil) async throws -> Int32 {
        guard let root = wineRoot, let wine = Self.wineBinary(in: root) else { throw WineError.noWineInstallation }
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        var env = buildWineEnv(for: bottle, wine: wine)
        Self.addBackendPlaceholders(to: bottle)
        env["WINE"] = wine.path
        process.environment = env
        process.currentDirectoryURL = bottle.path
        return try await Self.runStreaming(process, log: log)
    }

    /// Running Wine processes that have a window (winemac.drv makes those regular apps).
    /// Whether a running app is a Windows program under this Wine.
    func runsWine(_ app: NSRunningApplication) -> Bool {
        guard let root = wineRoot, let path = app.executableURL?.path else { return false }
        return WineProcess.runsWine(under: root)(path)
    }

    func wineWindows() -> [NSRunningApplication] {
        guard let root = wineRoot else { return [] }
        let isWine = WineProcess.runsWine(under: root)
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.executableURL.map { isWine($0.path) } == true
        }
    }

    /// Brings the newest Wine window to the front, e.g. an installer hidden behind OverPass.
    @discardableResult
    func showWineWindows() -> Bool {
        guard let app = wineWindows().max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { return false }
        return app.activate()
    }

    /// Until cancelled, activates each Wine process once, when it first shows a window.
    func raiseNewWineWindows() async {
        var seen = Set(wineWindows().map(\.processIdentifier))
        while !Task.isCancelled {
            for app in wineWindows() where seen.insert(app.processIdentifier).inserted {
                app.activate()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    nonisolated static func runStreaming(_ process: Process, log: (@MainActor (String) -> Void)?) async throws -> Int32 {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), let log else { return }
            Task { @MainActor in log(text) }
        }
        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Host path of a Windows path inside the bottle ("C:\\Program Files\\x.exe" → …/drive_c/Program Files/x.exe).
    func hostPath(_ windowsPath: String, in bottle: Bottle) -> URL { Self.hostPath(windowsPath, in: bottle) }

    nonisolated static func hostPath(_ windowsPath: String, in bottle: Bottle) -> URL {
        var rel = windowsPath.replacingOccurrences(of: "\\", with: "/")
        if rel.count >= 2, rel.dropFirst().first == ":" { rel = String(rel.dropFirst(2)) }
        return bottle.driveC.appendingPathComponent(rel.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    // `start /unix` resolves .lnk shortcuts and takes a host path. Programs go through `start /wait` too: Wine
    // runs the first program in the process it was started as, and only programs that Windows code starts get
    // OverPass Wine's compatibility rules and an app bundle of their own (Game Mode, the program's name).
    nonisolated static func launchArgs(_ path: String) -> [String] {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "msi" { return ["msiexec", "/i", path] }
        if ext == "exe" { return ["start", "/wait", "/unix", path] }
        return ["lnk", "bat"].contains(ext) ? ["start", "/unix", path] : [path]
    }

    nonisolated static func startsThroughStart(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "exe"
    }

    struct ProcessTemplate {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let directory: URL
    }

    /// What `run` would start, for callers that spawn the process themselves.
    func exeProcessTemplate(_ args: [String], in bottle: Bottle) throws -> ProcessTemplate {
        let p = try wineProcess(for: bottle, args: args)
        guard let exe = p.executableURL else { throw WineError.noWineInstallation }
        return ProcessTemplate(executable: exe, arguments: p.arguments ?? [], environment: p.environment ?? [:],
                               directory: p.currentDirectoryURL ?? bottle.path)
    }

    private func wineProcess(for bottle: Bottle, args: [String]) throws -> Process {
        guard let root = wineRoot, let wine = Self.wineBinary(in: root) else { throw WineError.noWineInstallation }
        let process = Process()
        process.executableURL = wine
        process.arguments = args
        process.environment = buildWineEnv(for: bottle, wine: wine)
        Self.addBackendPlaceholders(to: bottle)
        // A new bottle has no drive_c until `wineboot --init` makes it, and Process won't start in a missing directory.
        let driveCExists = FileManager.default.fileExists(atPath: bottle.driveC.path)
        process.currentDirectoryURL = driveCExists ? bottle.driveC : bottle.path
        return process
    }

    /// Wine loads a builtin DLL only when the bottle has a file of that name in system32 (or syswow64), and
    /// wineboot makes those only for Wine's own DLLs. Backends bring DLLs Wine doesn't have (DXMT's
    /// winemetal.dll, nvapi64.dll, nvngx.dll), so copy those in; Wine then loads the copy from the backend's
    /// directory. A copy for a backend the program doesn't use fails to load, as if it weren't there.
    nonisolated static func addBackendPlaceholders(to bottle: Bottle) {
        let fm = FileManager.default
        let windows = bottle.driveC.appendingPathComponent("windows")
        for dir in GraphicsBackend.allCases.compactMap(\.dllDirectory) + [Direct3D9Backend.directory] {
            for (arch, target) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
                let source = dir.appendingPathComponent(arch), dest = windows.appendingPathComponent(target)
                guard fm.fileExists(atPath: dest.path),
                      let dlls = try? fm.contentsOfDirectory(atPath: source.path) else { continue }
                for dll in dlls where dll.lowercased().hasSuffix(".dll")
                    && !fm.fileExists(atPath: dest.appendingPathComponent(dll.lowercased()).path)
                    && !fm.fileExists(atPath: dest.appendingPathComponent(dll).path) {
                    try? fm.copyItem(at: source.appendingPathComponent(dll), to: dest.appendingPathComponent(dll.lowercased()))
                }
            }
        }
    }

    // ponytail: the environment every Wine process in a bottle starts with
    private func buildWineEnv(for bottle: Bottle, wine: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // As CrossOver does: the host's own Python path and DLL overrides don't belong in a bottle.
        env["PYTHONPATH"] = nil
        env["WINEDLLOVERRIDES"] = nil
        let bin = wine.deletingLastPathComponent().path
        env["WINEPREFIX"] = bottle.path.path
        env["PATH"] = "\(bin):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["WINELOADER"] = wine.path
        env["WINESERVER"] = "\(bin)/wineserver"
        env["WINEDEBUG"] = "-all"
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"
        env["WINEMSYNC"] = "1"
        // As CrossOver does: with WINEDLLPATH set, the loader re-execs through a link named after the program
        // (CW Hack 22144), so the Dock and menu bar show the program's name instead of "wine".
        let lib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/wine").path
        env["WINEDLLPATH"] = "\(lib)/x86_64-windows:\(lib)"

        // Wine with CodeWeavers' D3DMetal support loads D3DMetal's unix side from this path.
        let d3dshared = ComponentManager.d3dmetalDir.appendingPathComponent("external/libd3dshared.dylib")
        if FileManager.default.fileExists(atPath: d3dshared.path) {
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dshared.path
        }

        // OverPass Wine's GStreamer (game video): its plugins, the scanner that loads them, and a registry of
        // what's in them, kept with OverPass's data rather than in the user's GStreamer cache.
        let wineDir = wine.deletingLastPathComponent().deletingLastPathComponent()
        let gstPlugins = wineDir.appendingPathComponent("lib/gstreamer-1.0")
        if FileManager.default.fileExists(atPath: gstPlugins.path) {
            env["GST_PLUGIN_SYSTEM_PATH"] = gstPlugins.path
            env["GST_PLUGIN_SCANNER"] = wineDir.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
            env["GST_REGISTRY"] = ComponentManager.toolsDir.deletingLastPathComponent()
                .appendingPathComponent("gstreamer-plugins.cache").path
        }

        // Wine builds before 11.0-8 open the Vulkan loader, which finds the bundled MoltenVK only through a driver
        // manifest; without one, Vulkan programs and DXVK get no device.
        if FileManager.default.fileExists(atPath: wineDir.appendingPathComponent("lib/libvulkan.1.dylib").path),
           let manifest = Self.moltenVKManifest(for: wineDir) {
            env["VK_DRIVER_FILES"] = manifest.path
        }

        let graphics = bottle.graphics.resolved
        env.merge(graphics.environment) { $1 }
        // A container with a backend of its own keeps it over a rule's `prefer-graphics`.
        if bottle.graphics != .auto { env["OVERPASS_GRAPHICS_CHOSEN"] = "1" }
        let dllPath = bottle.direct3D9.dllPath(with: graphics)
        if !dllPath.isEmpty { env["OVERPASS_DLL_PATH_PREPEND"] = dllPath }
        // For a game's `d3d9 =` rule, which moves this folder into or out of the DLL path.
        if Direct3D9Backend.isInstalled { env["OVERPASS_D3D9_MTLD3D"] = Direct3D9Backend.directory.path }
        env[MaxResolution.variable] = MaxResolution.global
        // Where OverPass Wine finds x87sidecar for games whose profile sets OVERPASS_X87=1.
        if FileManager.default.isExecutableFile(atPath: ComponentManager.x87sidecarPath.path) {
            env["OVERPASS_X87SIDECAR"] = ComponentManager.x87sidecarPath.path
        }
        env.merge(bottle.environment) { $1 }
        env.merge(CompatRules.environment()) { $1 }
        if bottle.direct3D9.usesMtld3d {
            // A rule that picks another backend for a program keeps mtld3d in front of it (OverPass Wine takes
            // the folder from OVERPASS_BACKEND_<NAME>).
            for backend in GraphicsBackend.allCases {
                env["OVERPASS_BACKEND_" + backend.rawValue.uppercased()] = bottle.direct3D9.dllPath(with: backend)
            }
        }
        return env
    }

    /// A launcher's record of a game wins over a shortcut of the same name: it knows the game's own program
    /// and store ID, where a launcher's shortcut (GOG Galaxy's) starts the launcher. The shortcut is kept for
    /// its icon, which can be picked instead of the program's.
    /// A Vulkan driver manifest for the MoltenVK in `wineDir`, kept with OverPass's data. Not marked as a
    /// portability driver: Wine doesn't ask the loader for those, so it would hide MoltenVK.
    nonisolated private static func moltenVKManifest(for wineDir: URL) -> URL? {
        let library = wineDir.appendingPathComponent("lib/libMoltenVK.dylib")
        guard FileManager.default.fileExists(atPath: library.path) else { return nil }
        let folder = ComponentManager.toolsDir.deletingLastPathComponent().appendingPathComponent("Vulkan")
        let manifest = folder.appendingPathComponent("MoltenVK-\(wineDir.resolvingSymlinksInPath().lastPathComponent).json")
        if !FileManager.default.fileExists(atPath: manifest.path) {
            let json: [String: Any] = ["file_format_version": "1.0.0",
                                       "ICD": ["library_path": library.resolvingSymlinksInPath().path, "api_version": "1.4.0"]]
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                  (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  (try? data.write(to: manifest)) != nil else { return nil }
        }
        return manifest
    }

    nonisolated private static func mergeApps(_ shortcuts: [WineApp], _ games: [WineApp]) -> [WineApp] {
        var games = games
        var kept: [WineApp] = []
        for shortcut in shortcuts {
            if let i = games.firstIndex(where: { $0.name.caseInsensitiveCompare(shortcut.name) == .orderedSame }) {
                games[i].shortcut = shortcut.executable
            } else {
                kept.append(shortcut)
            }
        }
        var seen = Set(kept.map { $0.name.lowercased() })
        return kept + games.filter { seen.insert($0.name.lowercased()).inserted }
    }

    // Start-menu and desktop shortcuts, both all-users and per-user; uninstallers are left out of the library.
    nonisolated private static func scanApps(in bottlePath: URL) -> [WineApp] {
        let users = bottlePath.appendingPathComponent("drive_c/users")
        var dirs = [
            bottlePath.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs"),
            users.appendingPathComponent("Public/Desktop"),
        ]
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            dirs.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
            dirs.append(users.appendingPathComponent("\(user)/Desktop"))
        }

        var seen = Set<String>()
        var apps: [WineApp] = []
        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator where ["lnk", "exe"].contains(file.pathExtension.lowercased()) {
                let name = file.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                if lower.contains("uninstall") || lower.hasPrefix("unins") { continue }
                guard seen.insert(lower).inserted else { continue }
                let target = file.pathExtension.lowercased() == "lnk"
                    ? ShellLink(url: file).flatMap { $0.localBasePath ?? $0.unicodeTarget }
                    : LauncherGames.windowsPath(file, bottlePath: bottlePath)
                apps.append(WineApp(name: name, executable: file.path, target: target))
            }
        }
        return apps
    }
}

struct LibraryItem: Identifiable, Hashable {
    let app: WineApp
    let bottle: Bottle
    // The arguments tell apart games that start through one launcher program (steam.exe steam://rungameid/...).
    var id: String { bottle.path.path + "|" + app.id }
}

enum WineError: LocalizedError {
    case noWineInstallation

    var errorDescription: String? {
        switch self {
        case .noWineInstallation:
            "No Wine installation found. Install it from Components or run the setup wizard again."
        }
    }
}
