import SwiftUI

// Where a program's settings come from, for the dots in the profile editor. The editor's form holds only what the
// person set; everything else is read from the same rules the launch uses, in the same order.

enum SettingSource: Hashable {
    case you, profile
    case preset(String), detection(String), rule(String)

    /// In a picker's row for the value the rules give, as "Same as Settings" reads.
    var title: String {
        switch self {
        case .you: "Your setting"
        case .profile: "This game's profile"
        case .preset: "Preset"
        case .detection(let what): "Detected: \(what)"
        case .rule(let name): name
        }
    }

    var help: String {
        switch self {
        case .you: "Set by you"
        case .profile: "Set by this game's profile"
        case .preset(let name): "Set by preset: \(name)"
        case .detection(let what): "Set by detection: \(what)"
        case .rule(let name): "Set by rule: \(name)"
        }
    }

    var color: Color {
        switch self {
        case .you: .accentColor
        case .profile: .green
        case .preset: .purple
        case .detection: .teal
        case .rule: .orange
        }
    }
}

/// A setting's name, with a dot saying where its value comes from when that isn't the default.
struct SettingLabel: View {
    let title: String
    var source: SettingSource?

    init(_ title: String, _ source: SettingSource?) {
        self.title = title
        self.source = source
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let source {
                Circle().fill(source.color).frame(width: 7, height: 7)
                    .accessibilityLabel(source.help)
            }
        }
        .help(source?.help ?? "")
    }
}

/// What the rules give a program before the person's own settings.
struct InheritedSettings {
    struct Entry: Hashable {
        var value: String
        var source: SettingSource
    }

    var graphics: (value: GraphicsBackend, source: SettingSource)?
    var direct3D9: (value: Direct3D9Backend, source: SettingSource)?
    var arguments: [Entry] = []
    /// NAME=value, one per name: the last rule that sets it, as at launch.
    var environment: [Entry] = []
    var dlls: [Entry] = []

    func variable(_ name: String) -> (value: String, source: SettingSource)? {
        environment.first { $0.value.hasPrefix(name + "=") }.map { (String($0.value.dropFirst(name.count + 1)), $0.source) }
    }

    /// Microsoft's XAudio2, set by a preset or rule.
    var xaudio: SettingSource? {
        let set = XAudioChoice.overrides.compactMap { override in dlls.first { $0.value == override } }
        return set.count == XAudioChoice.overrides.count ? set.first?.source : nil
    }

    var shaders: (value: ShaderCompileChoice, source: SettingSource)? {
        guard let config = variable("DXMT_CONFIG") else { return nil }
        let choice = ShaderCompileChoice.choice(in: config.value.split(separator: ";").map(String.init))
        return choice == .background ? nil : (choice, config.source)
    }

    /// Variables and DLLs with no control of their own in the editor.
    var others: [Entry] {
        environment.filter { !["OVERPASS_X87=", MaxResolution.variable + "="].contains(where: $0.value.hasPrefix) }
            + dlls.filter { !XAudioChoice.overrides.contains($0.value) || xaudio == nil }
    }
}

extension CompatRules {
    /// What the rules set for a library title, leaving out its own profile's "My settings", which the editor holds.
    /// Later rules win, as in `apply`; a backend the container already resolves to isn't a change.
    @MainActor
    static func inherited(by item: LibraryItem, profileID: String, presetTitle: (String) -> String) -> InheritedSettings {
        func source(of rule: CompatRule) -> SettingSource {
            if rule.name.hasPrefix("Detected: ") {
                let preset = rule.name.components(separatedBy: ", preset ").last ?? rule.name
                return .detection(Detection.result(for: item)?.engines.first.map(Detection.displayName) ?? presetTitle(preset))
            }
            if rule.file.hasPrefix("00-preset-") {
                return .preset(presetTitle(String(rule.file.dropFirst("00-preset-".count).dropLast(".ini".count))))
            }
            if rule.file == "00-presets-of-profiles.ini" {
                return .preset(presetTitle(rule.name.components(separatedBy: ": preset ").last ?? rule.name))
            }
            return rule.file == "\(profileID).ini" ? .profile : .rule(rule.name)
        }

        var out = InheritedSettings()
        let chosen = item.bottle.graphics != .auto
        for rule in all where rule.covers(item) {
            if rule.name == UserProfiles.settingsSection, rule.file == "\(profileID).ini" { continue }
            let from = source(of: rule)
            out.arguments += rule.addArguments.map { .init(value: $0, source: from) }
            for (key, value) in rule.environment {
                out.environment.removeAll { $0.value.hasPrefix(key + "=") }
                out.environment.append(.init(value: "\(key)=\(value)", source: from))
            }
            for dll in rule.dllOverrides where !out.dlls.contains(where: { $0.value == dll }) {
                out.dlls.append(.init(value: dll, source: from))
            }
            if let graphics = (rule.graphics ?? (chosen ? nil : rule.preferGraphics))?.resolved,
               graphics.dllDirectory.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                out.graphics = (graphics, from)
            }
            if let d3d9 = rule.direct3D9, d3d9 != .auto, Direct3D9Backend.isInstalled { out.direct3D9 = (d3d9, from) }
        }
        if out.graphics?.value == item.bottle.graphics.resolved { out.graphics = nil }
        if out.direct3D9.map({ $0.value.usesMtld3d == item.bottle.direct3D9.usesMtld3d }) ?? false { out.direct3D9 = nil }
        return out
    }
}
