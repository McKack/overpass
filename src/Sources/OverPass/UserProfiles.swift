import Foundation

// Profiles people change or make themselves. They live in Application Support/OverPass/Profiles in the same
// format as the bundled ones (Profiles/README.md). A file there named like a bundled profile replaces it; its
// first line records which version of the bundled file it was copied from, so OverPass can tell when that
// one has changed since. Deleting the file goes back to the bundled profile.
enum UserProfiles {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OverPass")
    }
    static var directory: URL { support.appendingPathComponent("Profiles") }
    /// Icons people pick for their apps; a profile's `icon` key names a file here.
    static var iconsDirectory: URL { directory.appendingPathComponent("Icons") }
    /// Covers people pick for the Covers layout; a profile's `cover` key names a file here.
    static var coversDirectory: URL { directory.appendingPathComponent("Covers") }
    /// The profile files in effect, the folder OverPass Wine reads its rules from: every bundled file no
    /// profile here replaces, plus every profile here.
    static var rulesDirectory: URL { support.appendingPathComponent("Rules") }

    static let basedOnPrefix = "# Based on OverPass's profile version "
    /// The section the profile editor writes an app's own settings to.
    static let settingsSection = "My settings"

    static func version(of text: String) -> String { WindowsIcons.stableHash(text) }

    /// The bundled version a user profile was copied from; nil for profiles made from scratch.
    static func basedOn(_ text: String) -> String? {
        text.components(separatedBy: .newlines).first.flatMap {
            $0.hasPrefix(basedOnPrefix) ? String($0.dropFirst(basedOnPrefix.count)) : nil
        }
    }

    /// A rules file OverPass writes itself (presets), kept with OverPass's data so syncRules can copy it.
    static func generatedRule(_ name: String, text: String) -> URL {
        let url = support.appendingPathComponent("Generated").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) != text { try? text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    /// Makes rulesDirectory hold exactly the given files.
    static func syncRules(_ files: [URL]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        let wanted = Set(files.map(\.lastPathComponent))
        for name in (try? fm.contentsOfDirectory(atPath: rulesDirectory.path)) ?? [] where !wanted.contains(name) {
            try? fm.removeItem(at: rulesDirectory.appendingPathComponent(name))
        }
        for file in files {
            let dest = rulesDirectory.appendingPathComponent(file.lastPathComponent)
            if let new = try? Data(contentsOf: file), (try? Data(contentsOf: dest)) != new {
                try? new.write(to: dest, options: .atomic)
            }
        }
    }

    /// A file name for a new profile: the app's name in lowercase words joined by '-', unique among `taken`.
    static func newID(for name: String, taken: Set<String>) -> String {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let base = words.isEmpty ? "app" : words.joined(separator: "-")
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

/// A profile file as text, for changes that keep everything else in it (comments, rules) as it is.
struct ProfileText {
    var text: String

    private var lines: [String] { text.components(separatedBy: "\n") }

    private static func sectionName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]") ? String(t.dropFirst().dropLast()) : nil
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), !t.hasPrefix(";"), let eq = t.firstIndex(of: "=") else { return nil }
        return (t[..<eq].trimmingCharacters(in: .whitespaces).lowercased(),
                t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    /// Line range of a section, header included, up to the next header (comments just above the next header
    /// belong to it).
    private func range(of section: String) -> Range<Int>? {
        let lines = lines
        guard let start = lines.firstIndex(where: { Self.sectionName($0)?.caseInsensitiveCompare(section) == .orderedSame })
        else { return nil }
        var end = lines[(start + 1)...].firstIndex { Self.sectionName($0) != nil } ?? lines.count
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { end -= 1 }
        return start..<end
    }

    func values(in section: String) -> [(key: String, value: String)] {
        guard let range = range(of: section) else { return [] }
        return lines[range].dropFirst().compactMap(Self.keyValue)
    }

    func first(_ key: String, in section: String) -> String? {
        values(in: section).first { $0.key == key }?.value
    }

    /// Sets one `key = value` line in a section, replacing the first such line; nil removes every such line.
    mutating func set(_ key: String, _ value: String?, in section: String) {
        var lines = lines
        guard let range = range(of: section) else {
            if let value { lines.insert(contentsOf: ["[\(section)]", "\(key) = \(value)", ""], at: 0) }
            text = lines.joined(separator: "\n")
            return
        }
        let matching = range.dropFirst().filter { Self.keyValue(lines[$0])?.key == key }
        if let value {
            if let first = matching.first {
                lines[first] = "\(key) = \(value)"
                for i in matching.dropFirst().reversed() { lines.remove(at: i) }
            } else {
                // After the section's last value, before trailing blank lines.
                var at = range.upperBound
                while at > range.lowerBound + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                lines.insert("\(key) = \(value)", at: at)
            }
        } else {
            for i in matching.reversed() { lines.remove(at: i) }
        }
        text = lines.joined(separator: "\n")
    }

    /// Sets a key that can repeat: one `key = value` line per value.
    mutating func set(_ key: String, all values: [String], in section: String) {
        set(key, nil, in: section)
        guard !values.isEmpty else { return }
        set(key, values.joined(separator: "\n\(key) = "), in: section)
    }

    /// Replaces a section (or adds it at the end) with these lines; an empty list removes it.
    mutating func replace(section: String, comment: String, with body: [String]) {
        var lines = lines
        if let range = range(of: section) {
            var start = range.lowerBound
            // Its comment goes with it.
            while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { start -= 1 }
            lines.removeSubrange(start..<range.upperBound)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !body.isEmpty {
            lines += ["", "# \(comment)", "[\(section)]"] + body
        }
        text = lines.joined(separator: "\n") + "\n"
    }
}
