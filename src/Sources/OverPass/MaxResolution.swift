import CoreGraphics
import SwiftUI

// The largest resolution games are offered, through OverPass Wine's OVERPASS_MAX_RESOLUTION: "desktop" (the
// Mac's current size, the default), "display" (everything the display supports) or "<width>x<height>". The
// global setting goes into every launch; a game's profile can set its own.

enum MaxResolution {
    static let key = "maxResolution"
    static let variable = "OVERPASS_MAX_RESOLUTION"
    static let desktop = "desktop"
    static let display = "display"

    static var global: String {
        UserDefaults.standard.string(forKey: key).flatMap(normalized) ?? desktop
    }

    /// A valid setting, or nil: "desktop", "display" or "<width>x<height>".
    static func normalized(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value == desktop || value == display { return value }
        guard let size = size(of: value) else { return nil }
        return "\(size.width)x\(size.height)"
    }

    static func size(of value: String) -> (width: Int, height: Int)? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    /// The main display's desktop size in points, as Wine sees it.
    static var desktopSize: (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        return (mode.width, mode.height)
    }

    /// Every size the main display reports, largest first, in points as Wine sees them.
    static var displaySizes: [(width: Int, height: Int)] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(CGMainDisplayID(), options) as? [CGDisplayMode] ?? []
        var seen = Set<String>()
        return modes.map { ($0.width, $0.height) }
            .filter { seen.insert("\($0.0)x\($0.1)").inserted }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
    }

    static func title(_ value: String) -> String {
        switch value {
        case desktop: desktopSize.map { "Desktop (\($0.width) × \($0.height))" } ?? "Desktop"
        case display: displaySizes.first.map { "Everything the display supports (\($0.width) × \($0.height))" }
            ?? "Everything the display supports"
        default: size(of: value).map { "\($0.width) × \($0.height)" } ?? value
        }
    }
}

/// A Max resolution picker: Desktop, everything the display supports, each size the display reports at or
/// above 1280 wide, and Custom with width and height fields. `inherited` adds a first choice that leaves the
/// setting unset (value ""), for a game that follows the global setting.
struct MaxResolutionPicker: View {
    @Binding var value: String
    var inherited: String?
    /// Where `inherited` comes from, when that isn't Settings.
    var inheritedFrom: SettingSource?
    var source: SettingSource?

    @State private var choice = ""
    @State private var width = ""
    @State private var height = ""

    private static let custom = "custom"
    private let sizes = MaxResolution.displaySizes.filter { $0.width >= 1280 && $0.width > $0.height }

    var body: some View {
        Group {
            Picker(selection: $choice) {
                if let inherited {
                    Text("\(inheritedFrom?.title ?? "Same as Settings"): \(MaxResolution.title(inherited))").tag("")
                    Divider()
                }
                Text(MaxResolution.title(MaxResolution.desktop)).tag(MaxResolution.desktop)
                Text(MaxResolution.title(MaxResolution.display)).tag(MaxResolution.display)
                Divider()
                ForEach(sizes.map { "\($0.width)x\($0.height)" }, id: \.self) { Text(MaxResolution.title($0)).tag($0) }
                Divider()
                Text("Custom…").tag(Self.custom)
            } label: {
                SettingLabel("Max resolution", source)
            }
            if choice == Self.custom {
                LabeledContent("Custom size") {
                    HStack {
                        TextField("Width", text: $width, prompt: Text("Width")).frame(width: 70)
                        Text("×")
                        TextField("Height", text: $height, prompt: Text("Height")).frame(width: 70)
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: choice) { store() }
        .onChange(of: width) { store() }
        .onChange(of: height) { store() }
    }

    private func load() {
        if value.isEmpty, inherited != nil { choice = ""; return }
        let value = MaxResolution.normalized(value) ?? MaxResolution.desktop
        if value == MaxResolution.desktop || value == MaxResolution.display || sizes.contains(where: { "\($0.width)x\($0.height)" == value }) {
            choice = value
        } else {
            choice = Self.custom
        }
        if let size = MaxResolution.size(of: value) { width = String(size.width); height = String(size.height) }
    }

    private func store() {
        if choice == Self.custom, width.isEmpty || height.isEmpty, let size = MaxResolution.desktopSize {
            width = String(size.width)
            height = String(size.height)
        }
        if choice != Self.custom {
            value = choice
            if let size = MaxResolution.size(of: choice) { width = String(size.width); height = String(size.height) }
        } else if let w = Int(width), let h = Int(height), w > 0, h > 0 {
            value = "\(w)x\(h)"
        }
    }
}
