import SwiftUI

// Uninstalling an app or game. A store's game goes through its launcher where the launcher allows it (Steam asks
// for confirmation itself), so the launcher's records stay right; anything else through its own Windows
// uninstaller, found in the registry's Uninstall keys and run by Wine's `uninstaller`. Only an app with neither
// has its folder and shortcuts moved to the Trash. A game client goes with its bottle, a Mac app to the Trash.
// Profiles always stay.
struct UninstallPlan {
    enum Method {
        case steam(appID: String)
        /// A game the built-in Epic library installed: Legendary removes its files and its record.
        case epic(appName: String)
        /// A game the built-in GOG library installed: OverPass removes its files and its record.
        case gog(id: String)
        case xbox(id: String)
        case windows(UninstallEntry)
        /// The launcher has no way for other programs to uninstall its games.
        case inLauncher(String)
        case files([URL])
        case bottle
        /// A Mac app in the library: the app itself goes to the Trash, unless macOS owns it.
        case macApp(URL?)
    }

    let method: Method

    @MainActor
    init(for item: LibraryItem, manager: BottleManager, profiles: ProfileStore) {
        if item.bottle.isMac {
            let app = URL(fileURLWithPath: item.app.executable)
            method = .macApp(app.path.hasPrefix("/System/") ? nil : app)
            return
        }
        let entries = UninstallEntry.all(in: item.bottle)
        if profiles.profiles.contains(where: { $0.category == "Game Launcher" && manager.bottle(for: $0)?.path == item.bottle.path
                                               && manager.isClient(item, of: $0) }) {
            method = .bottle
        } else if item.app.backend == .legendary, let id = item.app.storeID {
            method = .epic(appName: id)
        } else if item.app.backend == .gogdl, let id = item.app.storeID {
            method = .gog(id: id)
        } else if item.app.backend == .xodus, let id = item.app.storeID {
            method = .xbox(id: id)
        } else if item.app.launcher == "Steam", let id = item.app.storeID {
            method = .steam(appID: id)
        } else if item.app.launcher == "GOG", let id = item.app.storeID,
                  let entry = entries.first(where: { $0.key.lowercased() == id + "_is1" }) {
            method = .windows(entry)
        } else if let entry = Self.entry(for: item, in: entries, manager: manager) {
            method = .windows(entry)
        } else if let launcher = item.app.launcher, launcher != "GOG" {
            method = .inLauncher(launcher)
        } else {
            method = .files(Self.files(of: item, manager: manager))
        }
    }

    /// The entry whose install location holds the app's folder (the deepest one), or else one with the app's name.
    /// A location that also holds another app of the bottle belongs to something else, such as a game client.
    @MainActor
    private static func entry(for item: LibraryItem, in entries: [UninstallEntry], manager: BottleManager) -> UninstallEntry? {
        let others = manager.library.filter { $0.bottle.path == item.bottle.path && $0.id != item.id }
            .compactMap { $0.app.target.map(UninstallEntry.folder) }
        if let folder = item.app.target.map(UninstallEntry.folder) {
            let match = entries.filter { entry in
                guard let location = entry.location else { return false }
                return (folder == location || folder.hasPrefix(location + "\\"))
                    && !others.contains { $0 != folder && ($0 == location || $0.hasPrefix(location + "\\")) }
            }.max { $0.location!.count < $1.location!.count }
            if let match { return match }
        }
        return entries.first { $0.name.caseInsensitiveCompare(item.app.name) == .orderedSame }
    }

    /// The app's shortcuts, and its folder when that holds nothing else the library knows about.
    @MainActor
    private static func files(of item: LibraryItem, manager: BottleManager) -> [URL] {
        var urls = [item.app.executable, item.app.shortcut].compactMap { $0 }
            .filter { $0.lowercased().hasSuffix(".lnk") }.map(URL.init(fileURLWithPath:))
        let driveC = item.bottle.driveC.standardizedFileURL.path + "/"
        if let target = item.app.target, let folder = item.installFolder?.standardizedFileURL,
           folder.path.hasPrefix(driveC) {
            let inside = folder.path.dropFirst(driveC.count).split(separator: "/").map { $0.lowercased() }
            let shared: Set<String> = ["program files", "program files (x86)", "programdata", "users", "windows",
                                       "appdata", "local", "roaming", "desktop", "documents", "games"]
            let others = manager.library.filter { $0.bottle.path == item.bottle.path && $0.id != item.id }
                .compactMap { $0.app.target.map(UninstallEntry.folder) }
            let windowsFolder = UninstallEntry.folder(target)
            if inside.count >= 2, inside.first != "windows", !shared.contains(inside.last ?? ""),
               !others.contains(where: { $0 == windowsFolder || $0.hasPrefix(windowsFolder + "\\") }) {
                urls.append(folder)
            }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// A program's entry under Software\Microsoft\Windows\CurrentVersion\Uninstall, as Wine's `uninstaller` lists it.
struct UninstallEntry: Hashable {
    let key: String
    let name: String
    /// Lowercased Windows path of the folder the program is installed in, without a trailing backslash.
    let location: String?

    /// Lowercased Windows folder of a Windows file path.
    static func folder(_ path: String) -> String {
        let lower = path.lowercased()
        return lower.range(of: "\\", options: .backwards).map { String(lower[..<$0.lowerBound]) } ?? lower
    }

    static func all(in bottle: Bottle) -> [UninstallEntry] {
        let prefixes = ["[software\\\\microsoft\\\\windows\\\\currentversion\\\\uninstall\\\\",
                        "[software\\\\wow6432node\\\\microsoft\\\\windows\\\\currentversion\\\\uninstall\\\\"]
        var entries: [UninstallEntry] = []
        for file in ["system.reg", "user.reg"] {
            guard let text = LauncherGames.read(bottle.path.appendingPathComponent(file)) else { continue }
            var key: String?
            var values: [String: String] = [:]
            func finish() {
                guard let key, let name = values["displayname"], values["uninstallstring"] != nil
                        || values["windowsinstaller"] != nil else { return }
                entries.append(UninstallEntry(key: key, name: name, location: location(values)))
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("[") {
                    finish()
                    values = [:]
                    let lower = line.lowercased()
                    key = prefixes.first(where: lower.hasPrefix).flatMap { prefix -> String? in
                        // "[...\\Uninstall\\<key>] <timestamp>"; the key name keeps its case.
                        guard let end = line.range(of: "] ", options: .backwards) ?? line.range(of: "]", options: .backwards)
                        else { return nil }
                        let name = line[line.index(line.startIndex, offsetBy: prefix.count)..<end.lowerBound]
                        return name.contains("\\\\") ? nil : LauncherGames.unescape(name)
                    }
                } else if key != nil, let (name, value) = LauncherGames.regValue(line) {
                    values[name.lowercased()] = value
                } else if key != nil, line.lowercased().hasPrefix("\"windowsinstaller\"=dword:00000001") {
                    values["windowsinstaller"] = "1"
                }
            }
            finish()
        }
        return entries
    }

    /// InstallLocation, or else the folder of the program's icon or uninstaller.
    private static func location(_ values: [String: String]) -> String? {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\\ ")) }
        if let l = values["installlocation"], !trimmed(l).isEmpty { return trimmed(l).lowercased() }
        for value in [values["displayicon"], values["uninstallstring"]].compactMap({ $0 }) {
            // "C:\x\app.exe",0  or  "C:\x\unins000.exe" /SILENT  or  C:\x\uninstall.exe
            var path = value.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("\"") { path = String(path.dropFirst().prefix { $0 != "\"" }) }
            else if let exe = path.range(of: ".exe", options: .caseInsensitive) { path = String(path[..<exe.upperBound]) }
            guard path.count > 3, path.dropFirst().hasPrefix(":\\"),
                  !path.lowercased().contains("\\windows\\") else { continue }
            return folder(path)
        }
        return nil
    }
}

struct UninstallSheet: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    @State private var plan: UninstallPlan?
    @State private var running = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall \(item.app.name)").font(.title3.bold())
            if let plan { details(plan.method) }
            if running {
                HStack { ProgressView().controlSize(.small); Text("Waiting for the uninstaller to finish…") }
            }
            if let result { Text(result).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                if result != nil {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if let plan, let title = actionTitle(plan.method) {
                        Button(title, role: .destructive) { perform(plan.method) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(running)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { plan = UninstallPlan(for: item, manager: manager, profiles: profiles) }
    }

    @ViewBuilder
    private func details(_ method: UninstallPlan.Method) -> some View {
        switch method {
        case .steam:
            text("Steam removes the game and asks you to confirm in its own window. \(item.app.name) leaves the "
                 + "library once Steam has removed it.")
        case .epic, .gog, .xbox:
            text("OverPass deletes \(item.app.name)'s files from “\(item.bottle.name)”. Saved games in the container's "
                 + "user folders stay.")
        case .windows(let entry):
            text("OverPass runs the uninstaller of “\(entry.name)”. Follow its steps; it may ask whether to keep its "
                 + "settings and saved data.")
        case .inLauncher(let launcher):
            text("\(launcher) doesn't let other programs uninstall its games. Uninstall \(item.app.name) in "
                 + "\(launcher)'s library.")
        case .files(let urls) where urls.isEmpty:
            text("\(item.app.name) has no uninstaller, and OverPass found nothing it could safely remove.")
        case .files(let urls):
            text("\(item.app.name) has no uninstaller. OverPass moves these to the Trash:")
            pathList(urls.map { $0.path.replacingOccurrences(of: item.bottle.driveC.path, with: "C:") })
        case .bottle:
            text("\(item.app.name) is a game client. Uninstalling it deletes its container, “\(item.bottle.name)”, "
                 + "with everything in it, including these games and their saved games:")
            let games = manager.library.filter { $0.bottle.path == item.bottle.path && $0.id != item.id }.map(\.app.name)
            pathList(games.isEmpty ? ["No games"] : games)
        case .macApp(let app?):
            text("OverPass moves \(item.app.name) to the Trash and removes it from the library:")
            pathList([app.path])
        case .macApp(nil):
            text("\(item.app.name) comes with macOS and can't be uninstalled. OverPass can remove it from the library.")
        }
    }

    private func text(_ s: String) -> some View { Text(s).fixedSize(horizontal: false, vertical: true) }

    private func pathList(_ lines: [String]) -> some View {
        ScrollView {
            Text(lines.joined(separator: "\n")).font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
    }

    private func actionTitle(_ method: UninstallPlan.Method) -> String? {
        switch method {
        case .steam: "Uninstall in Steam"
        case .epic, .gog, .xbox: "Uninstall"
        case .windows: "Run Uninstaller"
        case .inLauncher: nil
        case .files(let urls): urls.isEmpty ? nil : "Move to Trash"
        case .bottle: "Delete Container"
        case .macApp(let app): app == nil ? "Remove from Library" : "Move to Trash"
        }
    }

    private func perform(_ method: UninstallPlan.Method) {
        error = nil
        Task {
            do {
                switch method {
                case .steam(let id):
                    // steam.exe hands the URL to the running Steam, or starts Steam with it.
                    try manager.exeProcess(item.app.executable, in: item.bottle, arguments: ["steam://uninstall/\(id)"]).run()
                    dismiss()
                case .epic(let appName):
                    running = true
                    await EpicStore.shared.uninstall(appName, using: manager)
                    running = false
                    dismiss()
                case .gog(let id):
                    running = true
                    await GOGStore.shared.uninstall(id, using: manager)
                    running = false
                    dismiss()
                case .xbox(let id):
                    running = true
                    await XboxStore.shared.uninstall(id, using: manager)
                    running = false
                    dismiss()
                case .windows(let entry):
                    running = true
                    let raiser = Task { await manager.raiseNewWineWindows() }
                    defer { raiser.cancel() }
                    _ = try await manager.runWaitingForChildren(["uninstaller", "--remove", entry.key], in: item.bottle,
                                                                ignore: nil, log: { _ in }, mainExited: {},
                                                                stopWaiting: { false })
                    running = false
                    manager.loadBottles()
                    result = manager.library.contains { $0.id == item.id }
                        ? "The uninstaller has finished, but \(item.app.name) is still installed. It may have been cancelled."
                        : "\(item.app.name) has been uninstalled."
                case .files(let urls):
                    for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    manager.loadBottles()
                    dismiss()
                case .bottle:
                    running = true
                    try await manager.deleteBottle(item.bottle)
                    dismiss()
                case .macApp(let app):
                    if let app { try FileManager.default.trashItem(at: app, resultingItemURL: nil) }
                    manager.removeMacApp(item)
                    dismiss()
                case .inLauncher:
                    break
                }
            } catch {
                running = false
                self.error = error.localizedDescription
            }
        }
    }
}

/// Deleting a whole bottle: everything installed in it goes, with its saved games. Programs still running in it
/// are quit first.
struct BottleUninstallSheet: View {
    @Environment(BottleManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    @State private var size: Int64?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        let titles = manager.library.filter { $0.bottle.path == bottle.path }.map(\.app.name)
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall “\(bottle.name)”").font(.title3.bold())
            Text("Deleting the container removes everything in it\(size.map { " (" + FolderSize.text($0) + ")" } ?? ""): "
                 + "these programs, and the saved games and settings they keep there. Programs running in it are quit first.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text((titles.isEmpty ? ["Nothing in the library"] : titles).joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            if running { HStack { ProgressView().controlSize(.small); Text("Deleting…") } }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete Container", role: .destructive) {
                    running = true
                    Task {
                        do { try await manager.deleteBottle(bottle); dismiss() }
                        catch { running = false; self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let path = bottle.path
            size = await Task.detached { FolderSize.of(path) }.value
        }
    }
}

/// The space a folder takes on disk, counted file by file.
enum FolderSize {
    nonisolated static func of(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
