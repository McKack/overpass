import Foundation
import AppKit
import CoreAudio
import CryptoKit

// Report Issue (ReportCenter.swift): can start an app with Wine's log on, and when it has quit puts that log
// together with what's needed to make sense of it — the Mac, the Wine and runtime versions, the app's profile,
// its bottle's settings and its engine's own logs — in one zip, with the user's name taken out. Every ordinary
// run also keeps Wine's errors in a last-run log, so a report can be sent without running the app again. The
// report block carries a checksum the report repository's issue check recomputes.

struct LogRecording: Identifiable {
    let id = UUID()
    let item: LibraryItem
    let name: String
    let bottle: Bottle
    let profileText: String?
    /// The profile's ID and whether the person changed or made it ("ghostrunner (changed)"); nil without one.
    let profile: String?
    /// The store and the game's ID there ("Steam 1139900").
    let store: String?
    let folder: URL
    /// Where the app is installed; mtld3d writes its logs into mtld3d-logs there.
    let installFolder: URL?
    var started = Date.now
    /// Whether this is a log from an earlier run rather than one recorded for the report.
    var lastRun = false
    /// What the person wrote before the run, kept for the report window afterwards.
    var description = ""
    /// Wine's crash handler came up during the run.
    var crashed = false
    var saving = false

    init(_ item: LibraryItem, profile: String?, profileText: String?, folder: URL) {
        self.item = item
        name = item.app.name
        bottle = item.bottle
        self.profile = profile
        self.profileText = profileText
        store = item.app.storeID.map { "\(item.app.launcher ?? "Store") \($0)" }
        self.folder = folder
        installFolder = item.installFolder
    }

    var logURL: URL { folder.appendingPathComponent("wine.log") }
}

enum LogCollector {
    /// Wine debug channels the log records unless the person asks for others: errors, which DLLs load
    /// (Windows' own or Wine's), and exceptions, with times and thread IDs.
    nonisolated static let defaultChannels = "+timestamp,+pid,+tid,err+all,+loaddll,+seh,fixme-all"

    /// What an ordinary run keeps in its last-run log: errors only, which costs next to nothing.
    nonisolated static let lastRunChannels = "err+all,fixme-all"

    /// What a run keeps instead when its bottle has the detailed log on (container.conf [OverPass] DebugLog).
    nonisolated static func lastRunChannels(for bottle: Bottle) -> String {
        detailedLog(in: bottle) ? defaultChannels : lastRunChannels
    }

    nonisolated static func detailedLog(in bottle: Bottle) -> Bool {
        BottleConfig.parse(bottle.configURL)["OverPass"]?["DebugLog"] == "1"
    }

    nonisolated static func setDetailedLog(_ on: Bool, in bottle: Bottle) throws {
        var config = BottleConfig.parse(bottle.configURL)
        config["OverPass", default: [:]]["DebugLog"] = on ? "1" : nil
        try BottleConfig.write(config, to: bottle.configURL)
    }

    /// The folder the bottle's last-run logs go in.
    nonisolated static func logFolder(for bottle: Bottle) -> URL {
        lastRunURL("x", in: bottle).deletingLastPathComponent()
    }

    /// The repository that takes reports.
    static let reportRepo = "McKack/overpass"

    /// How much of each last-run log goes in a report: the end, where the problem usually is.
    nonisolated static let lastRunTail = 20 << 20

    /// DLLs whose version (Wine's own or Microsoft's) often explains sound, graphics or input problems.
    static let notableDLLs = ["xaudio2_6", "xaudio2_7", "xaudio2_8", "xaudio2_9", "x3daudio1_6", "x3daudio1_7",
                              "xactengine3_7", "dsound", "d3dx9_43", "d3dx10_43", "d3dx11_43", "d3dcompiler_43",
                              "d3dcompiler_47", "xinput1_3", "xinput1_4", "msvcp140", "vcruntime140", "mfplat"]

    static func dateStamp(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: date)
    }

    /// ~/Library/Logs/OverPass/<bottle>/<app>.log, written anew each time the app starts.
    nonisolated static func lastRunURL(_ name: String, in bottle: Bottle) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OverPass/\(bottle.path.lastPathComponent)/")
            .appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".log")
    }

    nonisolated static func lastRunHandle(_ name: String, in bottle: Bottle) -> FileHandle? {
        let url = lastRunURL(name, in: bottle)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }

    /// The app's last-run log first, then the bottle's others: a game started through its store's client logs
    /// to the client's run, which was already going. Empty when the app hasn't run since OverPass kept logs.
    nonisolated static func lastRunLogs(for item: LibraryItem) -> [URL] {
        let own = lastRunURL(item.app.name, in: item.bottle)
        guard FileManager.default.fileExists(atPath: own.path) else { return [] }
        let others = ((try? FileManager.default.contentsOfDirectory(at: own.deletingLastPathComponent(),
                                                                    includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" && $0.lastPathComponent != own.lastPathComponent }
            .sorted { modified($0) > modified($1) }
        return [own] + others
    }

    nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// The facts the report block carries, in its order; the issue check reads them by these names.
    static var overpassFact: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build" }
    static var wineFact: String { WineInstaller.installedTag.map(WineInstaller.shortVersion) ?? WineInstaller.installedVersion ?? "not found" }
    static var runtimeFact: String { ComponentManager.runtimeVersion ?? "not installed" }
    static var macOSFact: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(sysctl("kern.osversion") ?? "?"))"
    }
    static var macFact: String {
        "\(sysctl("hw.model") ?? "?"), \(sysctl("machdep.cpu.brand_string") ?? "?"), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    }

    static func reportBlock(_ facts: KeyValuePairs<String, String>) -> String {
        reportBlock(facts.map { ($0.key, $0.value) })
    }

    static func reportBlock(_ facts: [(String, String)]) -> String {
        let lines = ["overpass-report: 1"] + facts.map { key, value in
            let flat = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return "\(key): \(flat.isEmpty ? "unknown" : flat)"
        }
        let body = lines.joined(separator: "\n")
        let sum = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return body + "\nchecksum: \(sum)"
    }

    /// A new issue in the report repository, from its report form, with the title and report block filled in.
    /// The log can't go in the address (GitHub caps it at about 8 KB), so the person attaches the zip.
    static func issueURL(title: String, what: String = "", block: String, form: String = "report.yml") -> URL? {
        var parts = URLComponents(string: "https://github.com/\(reportRepo)/issues/new")
        parts?.queryItems = [URLQueryItem(name: "template", value: form),
                             URLQueryItem(name: "title", value: title),
                             URLQueryItem(name: "what-happened", value: String(what.prefix(3000))),
                             URLQueryItem(name: "report", value: block)]
        // GitHub reads a bare "+" as a space, which would change names like Notepad++ and break the checksum.
        let query = parts?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        parts?.percentEncodedQuery = query
        return parts?.url
    }
}

extension BottleManager {
    /// Starts the app with Wine's log written to a new folder; nothing else may be running in its bottle, or
    /// what it starts would go to the copy already running and leave the log empty.
    func startLogging(_ item: LibraryItem, profile: String?, profileText: String?, channels: String, description: String) throws {
        var recording = LogRecording(item, profile: profile, profileText: profileText,
                                     folder: try LogCollector.newFolder(for: item.app.name))
        recording.description = description
        FileManager.default.createFile(atPath: recording.logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: recording.logURL)
        try runExe(item.app.executable, in: item.bottle, arguments: item.app.arguments, name: item.app.name,
                   extraEnv: ["WINEDEBUG": channels.isEmpty ? LogCollector.defaultChannels : channels], output: handle)
        logRecordings.append(recording)
        watch(recording.id)
    }

    /// A recording made of the logs of the app's last run, for a report that doesn't run it again; nil when there are none.
    func lastLogs(_ item: LibraryItem, profile: String?, profileText: String?) async throws -> LogRecording? {
        let logs = LogCollector.lastRunLogs(for: item)
        guard let own = logs.first else { return nil }
        var recording = LogRecording(item, profile: profile, profileText: profileText,
                                     folder: try LogCollector.newFolder(for: item.app.name))
        recording.started = LogCollector.modified(own)
        recording.lastRun = true
        let folder = recording.folder, logURL = recording.logURL
        await Task.detached {
            for log in logs {
                let copy = log == own ? logURL : folder.appendingPathComponent("last run – " + log.lastPathComponent)
                LogCollector.copyTail(of: log, to: copy)
            }
        }.value
        return recording
    }

    /// Finishes on its own once everything in the bottle has quit.
    private func watch(_ id: LogRecording.ID) {
        Task {
            try? await Task.sleep(for: .seconds(10))
            while let recording = logRecordings.first(where: { $0.id == id }), !recording.saving {
                if runningPrograms(in: recording.bottle).isEmpty {
                    await finishLogging(id)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The recorded run is over: the report window comes back with its log, as a crash report if it crashed.
    func finishLogging(_ id: LogRecording.ID) async {
        guard let index = logRecordings.firstIndex(where: { $0.id == id }), !logRecordings[index].saving else { return }
        logRecordings[index].saving = true
        let recording = logRecordings.remove(at: index)
        ReportCenter.shared.show(ReportContext(item: recording.item, mode: recording.crashed ? .crash : .afterRun,
                                               recording: recording, description: recording.description))
    }

    /// Puts the log and the details around it (engine logs, the screenshot) in a zip in `folder`.
    func makeZip(_ recording: LogRecording, screenshot: Data?, in folder: URL) async -> URL {
        let bluetooth = await Task.detached { LogCollector.bluetoothDevices() }.value
        let report = report(for: recording, bluetooth: bluetooth)
        let zip = folder.appendingPathComponent("OverPass Logs – \(recording.name) – \(LogCollector.dateStamp(recording.started)).zip")
        let installFolder = recording.installFolder, bottle = recording.bottle
        await Task.detached {
            EngineLogs.collect(installFolder: installFolder, bottle: bottle, into: recording.folder)
            if let screenshot { try? screenshot.write(to: recording.folder.appendingPathComponent("screenshot.jpg")) }
            LogCollector.writeBundle(recording, report: report)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: zip)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            // No ._ files for extended attributes: they'd only clutter the report.
            ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", recording.folder.path, zip.path]
            if (try? ditto.run()) != nil { ditto.waitUntilExit() }
            try? FileManager.default.removeItem(at: recording.folder)
        }.value
        return zip
    }

    /// The facts for the issue's report block, which labels and checks the report. Without a recording the report
    /// carries no log ("log: none"). `submission` is a submitted profile's test result (ProfileSubmit.swift).
    func reportBlock(for item: LibraryItem, recording: LogRecording?, profile: String?, submission: String? = nil) -> String {
        let graphics = item.bottle.graphics
        // Automatic without the Runtime stays .auto: that's Wine's own Direct3D.
        let automatic = graphics.resolved == .auto ? GraphicsBackend.wined3d : graphics.resolved
        return LogCollector.reportBlock((submission.map { [("kind", "profile"), ("test", $0)] } ?? []) + [
            ("app", item.app.name),
            ("profile", profile ?? "none"),
            ("store", item.app.storeID.map { "\(item.app.launcher ?? "Store") \($0)" } ?? "none"),
            ("overpass", LogCollector.overpassFact),
            ("wine", LogCollector.wineFact),
            ("runtime", LogCollector.runtimeFact),
            ("graphics", graphics == .auto ? "auto (\(automatic.rawValue))" : graphics.rawValue),
            ("windows", item.bottle.template.rawValue),
            ("macos", LogCollector.macOSFact),
            ("mac", LogCollector.macFact),
            ("log", recording.map { $0.lastRun ? "last run" : "recorded" } ?? "none"),
        ])
    }

    /// What's known about the Mac and the Wine setup, as text.
    private func report(for recording: LogRecording, bluetooth: [String]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let runtime = (try? String(contentsOf: ComponentManager.dxmtDir.appendingPathComponent("README.txt"), encoding: .utf8))?
            .components(separatedBy: .newlines).first
        let d3dmetal = FileManager.default.fileExists(atPath: ComponentManager.d3dmetalDir.appendingPathComponent("external/D3DMetal.framework").path)
        let rosetta = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        var lines = [
            "App: \(recording.name)",
            "Started: \(recording.started.formatted(.iso8601))" + (recording.lastRun ? " (last run, errors only)" : ""),
            "",
            "OverPass: \(info["CFBundleShortVersionString"] as? String ?? "development build") (\(info["CFBundleVersion"] as? String ?? "-"))",
            "Wine: \(WineInstaller.installedVersion ?? wineRoot?.path ?? "not found")",
            "OverPass Runtime: \(runtime ?? "not installed")",
            "D3DMetal: \(d3dmetal ? "installed" : "not installed")",
            "",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(LogCollector.sysctl("hw.model") ?? "?"), \(LogCollector.sysctl("machdep.cpu.brand_string") ?? "?"), "
                + "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB",
            "Rosetta: \(rosetta ? "installed" : "not installed")",
            "",
            "Sound outputs:",
        ] + LogCollector.soundOutputs() + [
            "",
            "Displays:",
        ] + LogCollector.displays() + [
            "",
            "Bluetooth devices connected:",
        ] + bluetooth + [
            "",
            "Container: \(recording.bottle.name) (\(recording.bottle.template.displayName))",
            "Container graphics: \(recording.bottle.graphics.displayName)",
            "Runtimes installed by OverPass: "
                + (Runtime.installed(in: recording.bottle).map(\.name).sorted().joined(separator: ", ").nilIfEmpty ?? "none"),
            "",
            "DLLs (Microsoft's or Wine's own):",
        ]
        let windows = recording.bottle.driveC.appendingPathComponent("windows")
        for dir in ["system32", "syswow64"] {
            for dll in LogCollector.notableDLLs {
                guard let url = WindowsIcons.caseInsensitive(windows, "\(dir)/\(dll).dll") else { continue }
                lines.append("  \(dir)\\\(dll).dll: \(LogCollector.isWineBuiltin(url) ? "Wine" : "Microsoft")")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension LogCollector {
    static func newFolder(for name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverPass Logs/\(name) \(LogCollector.dateStamp())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies the end of a log, at most `lastRunTail` bytes of it.
    nonisolated static func copyTail(of log: URL, to copy: URL) {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(lastRunTail) ? size - UInt64(lastRunTail) : 0)
        try? handle.readToEnd()?.write(to: copy)
    }

    /// Writes the report, the profile and the bottle's settings next to the log, and takes the user's name and
    /// home folder out of every file.
    nonisolated static func writeBundle(_ recording: LogRecording, report: String) {
        let folder = recording.folder
        try? report.write(to: folder.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
        if let profile = recording.profileText {
            try? profile.write(to: folder.appendingPathComponent("profile.ini"), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.copyItem(at: recording.bottle.configURL, to: folder.appendingPathComponent(Bottle.configName))
        // mtld3d (Direct3D 9) logs one file per process beside the game; the newest three.
        if let logs = recording.installFolder?.appendingPathComponent("mtld3d-logs"),
           let files = try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil) {
            for log in files.filter({ $0.pathExtension == "log" }).sorted(by: { modified($0) > modified($1) }).prefix(3) {
                copyTail(of: log, to: folder.appendingPathComponent("mtld3d – " + log.lastPathComponent))
            }
        }
        // Wine's own settings in the registry: DLL overrides, Windows version, per-app defaults, audio.
        if let reg = try? String(contentsOf: recording.bottle.path.appendingPathComponent("user.reg"), encoding: .utf8) {
            var keep = false
            let wine = reg.components(separatedBy: "\n").filter { line in
                if line.hasPrefix("[") { keep = line.lowercased().hasPrefix("[software\\\\wine") }
                return keep
            }
            try? wine.joined(separator: "\n").write(to: folder.appendingPathComponent("wine-settings.reg"),
                                                     atomically: true, encoding: .utf8)
        }
        let textTypes: Set<String> = ["log", "txt", "conf", "reg", "ini", "xml", "json", "cfg", "runtime-xml"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            // Crash dumps and the screenshot stay as they are.
            guard textTypes.contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) else { continue }
            // Wine logs mix encodings; Latin-1 maps every byte, so nothing is lost on the way back.
            let text = String(decoding: data, as: UTF8.self).contains("\u{FFFD}")
                ? String(data: data, encoding: .isoLatin1) ?? "" : String(decoding: data, as: UTF8.self)
            let cleaned = scrub(text)
            if cleaned != text { try? cleaned.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// What could identify the person, and what each becomes: the home folder, the account and full name (and each
    /// part of it), the computer's name (also as Wine's 15-character NetBIOS name) and host name, e-mail addresses.
    nonisolated private static let personal: [(NSRegularExpression, String)] = {
        func literal(_ text: String, word: Bool = true) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: text)
            return word ? "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])" : escaped
        }
        var rules: [(String, String)] = [(literal(FileManager.default.homeDirectoryForCurrentUser.path, word: false), "~")]
        let user = NSUserName()
        rules.append((literal(user), "user"))
        let fullName = NSFullUserName()
        if fullName.count >= 3, fullName != user { rules.append((literal(fullName), "User")) }
        for part in fullName.split(separator: " ").map(String.init) where part.count >= 3 && part.lowercased() != user.lowercased() {
            rules.append((literal(part), "User"))
        }
        let computer = Host.current().localizedName ?? ""
        for name in [computer, String(computer.prefix(15)), ProcessInfo.processInfo.hostName,
                     ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")] where name.count >= 3 {
            rules.append((literal(name), "Mac"))
        }
        rules.append(("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "email@removed"))
        return rules.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { ($0, NSRegularExpression.escapedTemplate(for: replacement)) }
        }
    }()

    /// `text` with everything in `personal` replaced.
    nonisolated static func scrub(_ text: String) -> String {
        personal.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }

    /// Wine marks its own DLLs, the placeholders in system32 included, with this text after the DOS header.
    nonisolated static func isWineBuiltin(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 0x80) else { return false }
        return head.range(of: Data("Wine builtin DLL".utf8)) != nil || head.range(of: Data("Wine placeholder DLL".utf8)) != nil
    }

    nonisolated static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The Mac's default sound output and its sample rate, which Wine's sound output follows.
    /// One line per sound output: how it's connected and how it takes its audio, which Wine's buffers depend on.
    nonisolated static func soundOutputs() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return ["  unknown"] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return ["  unknown"] }
        var standard = AudioObjectID(0)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &standard)

        func number(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            return value
        }
        return devices.compactMap { device -> String? in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streams = UInt32(0)
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &streams) == noErr, streams > 0 else { return nil }
            var rate = Float64(0)
            var size = UInt32(MemoryLayout<Float64>.size)
            address.mScope = kAudioObjectPropertyScopeGlobal
            address.mSelector = kAudioDevicePropertyNominalSampleRate
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
            var name: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioObjectPropertyName
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
            let transport = transportName(number(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal))
            return "  \(name?.takeRetainedValue() as String? ?? "unnamed device"): \(transport), \(Int(rate)) Hz, "
                + "buffer \(number(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)), "
                + "latency \(number(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)), "
                + "safety offset \(number(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)) frames"
                + (device == standard ? " (in use)" : "")
        }
    }

    nonisolated private static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        default: "other"
        }
    }

    /// One line per display, the one with the menu bar first.
    static func displays() -> [String] {
        NSScreen.screens.map { screen in
            let scale = screen.backingScaleFactor
            let size = "\(Int(screen.frame.width * scale))x\(Int(screen.frame.height * scale))"
            return "  \(screen.localizedName): \(size) at \(Int(scale))x, \(screen.maximumFramesPerSecond) Hz"
        }
    }

    /// The kinds of Bluetooth devices connected. Their names often hold a person's name, so only kind and IDs are kept.
    nonisolated static func bluetoothDevices() -> [String] {
        let profiler = Process()
        let output = Pipe()
        profiler.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        profiler.arguments = ["SPBluetoothDataType", "-json", "-timeout", "5"]
        profiler.standardOutput = output
        profiler.standardError = FileHandle.nullDevice
        guard (try? profiler.run()) != nil else { return ["  unknown"] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        profiler.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return ["  unknown"] }
        let devices = sections.flatMap { $0["device_connected"] as? [[String: [String: Any]]] ?? [] }.flatMap(\.values)
        guard !devices.isEmpty else { return ["  none"] }
        return devices.map { device in
            let ids = [device["device_vendorID"], device["device_productID"]].compactMap { $0 as? String }.joined(separator: " ")
            return "  \(device["device_minorType"] as? String ?? "unknown kind")" + (ids.isEmpty ? "" : " (\(ids))")
        }
    }

    nonisolated static func outputDevice() -> String? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        let title = name?.takeRetainedValue() as String? ?? "unnamed device"
        return "\(title), \(Int(rate)) Hz"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
