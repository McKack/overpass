import Foundation
import Darwin

/// A running Wine process: its command line as Wine shows it (Wine renames its processes after the Windows
/// program, e.g. "winedbg --auto 1692") and where it runs. Renaming overwrites the environment too, so only
/// wineserver still shows WINEPREFIX; the others keep their Unix working directory inside the bottle.
struct WineProcess {
    let pid: pid_t
    let commandLine: String
    /// WINEPREFIX when the process still has it, otherwise its working directory.
    let location: String

    /// Wine's crash handler; it starts the moment a program crashes, well before its dialog appears.
    var isCrashHandler: Bool { commandLine.lowercased().hasPrefix("winedbg") }

    /// The program's file name without ".exe", read from its command line (whose path may contain spaces).
    var displayName: String {
        var path = commandLine.hasPrefix("\"") ? String(commandLine.dropFirst().prefix { $0 != "\"" }) : commandLine
        if let exe = path.range(of: ".exe", options: .caseInsensitive) { path = String(path[..<exe.lowerBound]) }
        else { path = String(path.prefix { $0 != " " }) }
        return (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }

    /// Every process whose executable lies under `wineRoot`.
    static func all(under wineRoot: URL) -> [WineProcess] {
        let isWine = runsWine(under: wineRoot)
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(max(count, 0))).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  isWine(String(cString: path)),
                  let (arguments, environment) = arguments(of: pid) else { return nil }
            guard let location = environment["WINEPREFIX"] ?? workingDirectory(of: pid) else { return nil }
            return WineProcess(pid: pid, commandLine: arguments.joined(separator: " "), location: location)
        }
    }

    /// Whether an executable path runs Wine from `wineRoot`: a file under it, or one of the hard links to Wine's
    /// loader that OverPass Wine starts programs through so macOS shows their names (in a "winetemp-" folder).
    static func runsWine(under wineRoot: URL) -> (String) -> Bool {
        let root = wineRoot.resolvingSymlinksInPath().path + "/"
        var loader = stat()
        let haveLoader = stat(wineRoot.appendingPathComponent("lib/wine/x86_64-unix/wine").path, &loader) == 0
        return { path in
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root) { return true }
            var file = stat()
            return haveLoader && stat(path, &file) == 0 && file.st_dev == loader.st_dev && file.st_ino == loader.st_ino
        }
    }

    /// The processes running in one bottle.
    static func all(under wineRoot: URL, in bottle: URL) -> [WineProcess] {
        let prefix = bottle.resolvingSymlinksInPath().path
        return all(under: wineRoot).filter {
            let location = URL(fileURLWithPath: $0.location).resolvingSymlinksInPath().path
            return location == prefix || location.hasPrefix(prefix + "/")
        }
    }

    /// When the process started. NSRunningApplication's launchDate is nil for programs Launch Services didn't open.
    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// argv and environment from KERN_PROCARGS2: argc, the executable path, padding, argv, then environ.
    private static func arguments(of pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var strings: [String] = []
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }          // executable path
        while i < size, buffer[i] == 0 { i += 1 }          // padding
        while i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            if i == start { break }                         // an empty string ends environ
            strings.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        let argv = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for entry in strings.dropFirst(Int(argc)) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (argv, env)
    }
}
