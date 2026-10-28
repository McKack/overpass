import Foundation
import AppKit

// Icons for Windows programs: follow a .lnk to its icon location or target, then pull the
// RT_GROUP_ICON resource out of the PE file and reassemble it as an .ico, which NSImage reads natively.
enum WindowsIcons {
    static var cacheDirectory: URL { MediaCache.folder("Windows", .icons) }

    /// An image file of the program's own icon, or nil if it has none we can read. Cached on disk by path and mtime.
    static func icoFile(for app: WineApp, in bottle: Bottle) -> URL? {
        let source = app.icon ?? app.executable
        if bottle.isMac && app.icon == nil { return MacApps.iconFile(source) }
        // Launchers keep ready-made icon images (Steam's library cache); NSImage reads those as they are.
        if ["png", "jpg", "jpeg", "ico"].contains((source as NSString).pathExtension.lowercased()) {
            return FileManager.default.fileExists(atPath: source) ? URL(fileURLWithPath: source) : nil
        }
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: source)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = stableHash("\(source)|\(Int(mtime))")
        let cached = cacheDirectory.appendingPathComponent("\(key).ico")
        let missing = cacheDirectory.appendingPathComponent("\(key).none")
        if fm.fileExists(atPath: cached.path) { return cached }
        if fm.fileExists(atPath: missing.path) { return nil }

        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = extract(source, bottlePath: bottle.path) else {
            fm.createFile(atPath: missing.path, contents: nil)
            return nil
        }
        return (try? data.write(to: cached)) != nil ? cached : nil
    }

    /// Icons an app could be shown with, as host paths of files `extract` reads: its program first (what the
    /// Dock shows while it runs), then its shortcut, its launcher's picture, and the .ico and .exe files next
    /// to the program.
    static func candidates(for app: WineApp, in bottle: Bottle) -> [String] {
        var paths: [String] = []
        let program = app.target.flatMap { hostPath($0, bottlePath: bottle.path) }
        if let program { paths.append(program.path) }
        if app.executable.lowercased().hasSuffix(".lnk") || program == nil { paths.append(app.executable) }
        if let shortcut = app.shortcut { paths.append(shortcut) }
        if let icon = app.icon { paths.append(icon) }
        if let folder = program?.deletingLastPathComponent(),
           let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for file in files.sorted() where ["ico", "exe"].contains((file as NSString).pathExtension.lowercased())
                && !file.lowercased().hasPrefix("unins") {
                paths.append(folder.appendingPathComponent(file).path)
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.prefix(24).map { $0 }
    }

    /// .ico bytes for a host path to a .lnk, .exe/.dll or .ico.
    static func extract(_ path: String, bottlePath: URL) -> Data? {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "lnk":
            guard let link = ShellLink(url: url) else { return nil }
            for (file, index) in link.iconCandidates {
                guard let host = hostPath(file, bottlePath: bottlePath, relativeTo: url.deletingLastPathComponent()) else { continue }
                if let ico = extractFile(host, index: index) { return ico }
            }
            return nil
        default:
            return extractFile(url, index: 0)
        }
    }

    private static func extractFile(_ url: URL, index: Int) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        if url.pathExtension.lowercased() == "ico" { return data }
        return PEIcons(data)?.ico(index: index)
    }

    /// Windows path → existing host path, matched case-insensitively. C: is the bottle's drive_c, Z: is the host
    /// root (Wine's default); relative paths resolve against `directory`.
    static func hostPath(_ windowsPath: String, bottlePath: URL, relativeTo directory: URL? = nil) -> URL? {
        var path = expandVariables(windowsPath).replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty else { return nil }
        let chars = Array(path)
        if chars.count >= 2, chars[1] == ":" {
            let drive = chars[0].lowercased()
            path = String(path.dropFirst(2))
            let base: URL
            switch drive {
            case "c": base = bottlePath.appendingPathComponent("drive_c")
            case "z": base = URL(fileURLWithPath: "/")
            default: base = bottlePath.appendingPathComponent("dosdevices/\(drive):").resolvingSymlinksInPath()
            }
            return caseInsensitive(base, path)
        }
        return directory.flatMap { caseInsensitive($0, path) }
    }

    // Shortcuts made by installers often point at %ProgramFiles% or %SystemRoot%.
    private static func expandVariables(_ s: String) -> String {
        let vars = [
            "systemroot": "C:\\windows", "windir": "C:\\windows",
            "programfiles": "C:\\Program Files", "programfiles(x86)": "C:\\Program Files (x86)",
            "programdata": "C:\\ProgramData", "systemdrive": "C:",
        ]
        var out = s
        while let start = out.firstIndex(of: "%"),
              let end = out[out.index(after: start)...].firstIndex(of: "%") {
            let name = out[out.index(after: start)..<end].lowercased()
            guard let value = vars[name] else { break }
            out.replaceSubrange(start...end, with: value)
        }
        return out
    }

    /// Windows paths are case-insensitive, so match each component against what's on disk.
    static func caseInsensitive(_ base: URL, _ relative: String) -> URL? {
        var url = base
        for part in relative.split(separator: "/") where part != "." {
            if part == ".." { url.deleteLastPathComponent(); continue }
            let exact = url.appendingPathComponent(String(part))
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            guard let match = entries.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else { return nil }
            url.appendPathComponent(match)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // FNV-1a; Swift's hashValue is seeded per process, so it can't name cache files.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// MARK: - Byte reading

private extension Data {
    func u8(_ o: Int) -> Int? { o >= 0 && o < count ? Int(self[startIndex + o]) : nil }
    func u16(_ o: Int) -> Int? {
        guard let a = u8(o), let b = u8(o + 1) else { return nil }
        return a | b << 8
    }
    func u32(_ o: Int) -> Int? {
        guard let a = u16(o), let b = u16(o + 2) else { return nil }
        return a | b << 16
    }
    func bytes(_ o: Int, _ n: Int) -> Data? {
        o >= 0 && n >= 0 && o + n <= count ? subdata(in: startIndex + o..<startIndex + o + n) : nil
    }
}

// MARK: - .lnk (MS-SHLLINK)

struct ShellLink {
    var iconLocation: String?
    var iconIndex = 0
    var localBasePath: String?
    var relativePath: String?
    var unicodeTarget: String?

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url), d.u32(0) == 0x4C, let flags = d.u32(0x14) else { return nil }
        iconIndex = Int(Int32(truncatingIfNeeded: d.u32(0x38) ?? 0))
        let unicode = flags & 0x80 != 0
        var o = 0x4C

        if flags & 0x1 != 0, let size = d.u16(o) { o += 2 + size }  // LinkTargetIDList
        if flags & 0x2 != 0, let size = d.u32(o) {                  // LinkInfo
            let headerSize = d.u32(o + 4) ?? 0
            if headerSize >= 0x24, let off = d.u32(o + 0x1C), off > 0 {
                localBasePath = Self.cString(d, o + off, wide: true)
            } else if let off = d.u32(o + 0x10), off > 0 {
                localBasePath = Self.cString(d, o + off, wide: false)
            }
            o += size
        }
        // StringData, in this fixed order, each present only if its flag is set.
        let order: [(flag: Int, keyPath: WritableKeyPath<ShellLink, String?>?)] = [
            (0x4, nil), (0x8, \.relativePath), (0x10, nil), (0x20, nil), (0x40, \.iconLocation),
        ]
        for (flag, keyPath) in order where flags & flag != 0 {
            guard let chars = d.u16(o) else { break }
            let len = unicode ? chars * 2 : chars
            if let keyPath, let raw = d.bytes(o + 2, len) {
                self[keyPath: keyPath] = String(data: raw, encoding: unicode ? .utf16LittleEndian : .windowsCP1252)
            }
            o += 2 + len
        }
        // ExtraData: EnvironmentVariableDataBlock carries the target as an unexpanded Unicode path.
        while let size = d.u32(o), size >= 4, let sig = d.u32(o + 4) {
            if sig == 0xA000_0001 { unicodeTarget = Self.cString(d, o + 8 + 260, wide: true) }
            o += size
        }
    }

    /// Where to look for the icon, best first: the explicit icon location, then the link target.
    var iconCandidates: [(String, Int)] {
        var out: [(String, Int)] = []
        if let iconLocation, !iconLocation.isEmpty { out.append((iconLocation, iconIndex)) }
        for target in [localBasePath, unicodeTarget, relativePath].compactMap({ $0 }) where !target.isEmpty {
            out.append((target, 0))
        }
        return out
    }

    private static func cString(_ d: Data, _ o: Int, wide: Bool) -> String? {
        var bytes: [UInt8] = []
        var i = o
        if wide {
            while let c = d.u16(i), c != 0 { bytes += [UInt8(c & 0xFF), UInt8(c >> 8)]; i += 2 }
            return String(bytes: bytes, encoding: .utf16LittleEndian)
        }
        while let c = d.u8(i), c != 0 { bytes.append(UInt8(c)); i += 1 }
        return String(bytes: bytes, encoding: .windowsCP1252)
    }
}

// MARK: - PE resources

struct PEIcons {
    private let d: Data
    private let sections: [(va: Int, size: Int, raw: Int)]
    private let resourceRoot: Int  // file offset of the resource directory

    private static let rtIcon = 3, rtGroupIcon = 14

    init?(_ data: Data) {
        d = data
        guard d.u16(0) == 0x5A4D, let pe = d.u32(0x3C), d.u32(pe) == 0x4550,
              let sectionCount = d.u16(pe + 6), let optSize = d.u16(pe + 20) else { return nil }
        let opt = pe + 24
        let dirs: Int
        switch d.u16(opt) {
        case 0x10B: dirs = opt + 96   // PE32
        case 0x20B: dirs = opt + 112  // PE32+
        default: return nil
        }
        let table = opt + optSize
        let sections: [(va: Int, size: Int, raw: Int)] = (0..<sectionCount).compactMap { i in
            let s = table + i * 40
            guard let vsize = data.u32(s + 8), let va = data.u32(s + 12), let rawSize = data.u32(s + 16), let raw = data.u32(s + 20) else { return nil }
            return (va, max(vsize, rawSize), raw)
        }
        self.sections = sections
        guard let rva = d.u32(dirs + 2 * 8), rva != 0 else { return nil }
        var root: Int?
        for s in sections where rva >= s.va && rva < s.va + s.size { root = rva - s.va + s.raw }
        guard let root else { return nil }
        resourceRoot = root
    }

    private func fileOffset(_ rva: Int) -> Int? {
        sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { rva - $0.va + $0.raw }
    }

    /// (id or -1 for named entries, offset relative to resourceRoot, isDirectory) for one directory level.
    private func entries(_ dirOffset: Int) -> [(id: Int, offset: Int, isDir: Bool)] {
        let base = resourceRoot + dirOffset
        guard let named = d.u16(base + 12), let ids = d.u16(base + 14) else { return [] }
        return (0..<(named + ids)).compactMap { i in
            guard let name = d.u32(base + 16 + i * 8), let off = d.u32(base + 20 + i * 8) else { return nil }
            return (name & 0x8000_0000 != 0 ? -1 : name, off & 0x7FFF_FFFF, off & 0x8000_0000 != 0)
        }
    }

    /// First language's data for a resource directory entry.
    private func leafData(_ entry: (id: Int, offset: Int, isDir: Bool)) -> Data? {
        var e = entry
        while e.isDir { guard let first = entries(e.offset).first else { return nil }; e = first }
        let leaf = resourceRoot + e.offset
        guard let rva = d.u32(leaf), let size = d.u32(leaf + 4), let off = fileOffset(rva) else { return nil }
        return d.bytes(off, size)
    }

    private func typeDirectory(_ type: Int) -> [(id: Int, offset: Int, isDir: Bool)] {
        guard let t = entries(0).first(where: { $0.id == type && $0.isDir }) else { return [] }
        return entries(t.offset)
    }

    /// Windows convention: index >= 0 is the nth group icon, negative is the resource id -index.
    func ico(index: Int) -> Data? {
        let groups = typeDirectory(Self.rtGroupIcon)
        let group = index < 0 ? groups.first { $0.id == -index } : (groups.indices.contains(index) ? groups[index] : groups.first)
        guard let group, let dir = leafData(group), let count = dir.u16(4), count > 0 else { return nil }
        let icons = typeDirectory(Self.rtIcon)

        var images: [(entry: Data, image: Data)] = []
        for i in 0..<count {
            let e = 6 + i * 14
            guard let header = dir.bytes(e, 12), let id = dir.u16(e + 12),
                  let res = icons.first(where: { $0.id == id }), let image = leafData(res) else { continue }
            images.append((header, image))
        }
        guard !images.isEmpty else { return nil }

        // .ico layout: ICONDIR, then 16-byte entries (the group's 12 bytes + a u32 file offset), then image data.
        var out = Data([0, 0, 1, 0, UInt8(images.count & 0xFF), UInt8(images.count >> 8)])
        var offset = 6 + images.count * 16
        for (entry, image) in images {
            var header = entry
            header.replaceSubrange(header.startIndex + 8..<header.startIndex + 12, with: withUnsafeBytes(of: UInt32(image.count).littleEndian) { Data($0) })
            out += header
            out += withUnsafeBytes(of: UInt32(offset).littleEndian) { Data($0) }
            offset += image.count
        }
        for (_, image) in images { out += image }
        return out
    }
}
