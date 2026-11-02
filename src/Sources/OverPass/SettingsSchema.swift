import AppKit
import SwiftUI

/// What OverPass knows about the variables and options a title can set (Schema/settings.json): their type,
/// values and limits, so the Simple views can show a switch, a menu or a slider instead of NAME=value text.
/// Anything not in it is shown as text. A newer copy comes from overpass-components, with no app release.
struct SettingSpec: Decodable, Identifiable {
    struct Choice: Decodable, Hashable { let value: String; let title: String }
    enum Kind: String, Decodable { case env, dxmtConfig = "dxmt-config", mtld3dConfig = "mtld3d-config", ruleKey = "rule-key", dllOverride = "dll-override", profileKey = "profile-key" }

    let id: String
    let kind: Kind
    let type: String
    let title: String
    let summary: String
    let technical: String
    let group: String
    let on: String?
    let off: String?
    let values: [Choice]?
    let min: Double?
    let max: Double?
    let step: Double?
    let unit: String?
    let `default`: String?
    let source: String?
    let repeatable: Bool?

    /// A number that also accepts "auto" (its default).
    var allowsAutomatic: Bool { (type == "int" || type == "float") && self.default == "auto" }
}

enum SettingsSchema {
    /// An entry this version can't read is left out, so a new kind of setting doesn't cost the whole file.
    private struct Entry: Decodable {
        let spec: SettingSpec?
        init(from decoder: Decoder) { spec = try? SettingSpec(from: decoder) }
    }
    private struct File: Decodable {
        let format: Int
        /// Goes up with every change, so a cached copy never hides a newer one in the app.
        let revision: Int
        let settings: [Entry]
        var specs: [SettingSpec] { settings.compactMap(\.spec) }
    }

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/McKack/overpass-components/main/settings.json")!

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OverPass/settings.json")
    }

    private static func decode(_ data: Data?) -> File? {
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1,
              !file.specs.isEmpty else { return nil }
        return file
    }

    private static let bundled = decode(ProfileStore.resourceBundle
        .url(forResource: "settings", withExtension: "json", subdirectory: "Schema")
        .flatMap { try? Data(contentsOf: $0) })

    /// The newest of the app's copy and the last good download.
    private static var loaded = [bundled, decode(try? Data(contentsOf: cacheURL))].compactMap { $0 }
        .max { $0.revision < $1.revision }

    static var all: [SettingSpec] { loaded?.specs ?? [] }

    /// Downloads the schema and keeps it when it parses and is newer; otherwise what's here stays.
    @MainActor static func refresh() async {
        guard let (data, response) = try? await URLSession.shared.data(from: remoteURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let file = decode(data), file.revision > loaded?.revision ?? -1 else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        loaded = file
    }

    static func spec(_ id: String, _ kind: SettingSpec.Kind) -> SettingSpec? {
        all.first { $0.kind == kind && ($0.kind == .env ? $0.id == id : $0.id.caseInsensitiveCompare(id) == .orderedSame) }
    }

    /// A key of a profile section: its own meaning in a recipe section, otherwise the rule key.
    static func key(_ key: String, in section: String) -> SettingSpec? {
        all.first { $0.kind == .profileKey && $0.group == section.lowercased() && $0.id == key } ?? spec(key, .ruleKey)
    }

    /// Variables holding options of their own, shown as their own sections.
    static let optionVariables: [(name: String, kind: SettingSpec.Kind, title: String)] = [
        ("DXMT_CONFIG", .dxmtConfig, "OverPass Runtime: Direct3D 10–12"),
        ("MTLD3D_CONFIG", .mtld3dConfig, "OverPass Runtime: Direct3D 9"),
    ]

    /// NAME=value lines with the options of `variable` split out.
    static func options(of variable: String, in lines: [String]) -> [(name: String, value: String)] {
        lines.filter { $0.hasPrefix(variable + "=") }.flatMap { line in
            line.dropFirst(variable.count + 1).split(separator: ";").map { option in
                let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                return (pair[0], pair.count > 1 ? pair[1] : "")
            }
        }
    }

    /// Lines with one option of `variable` set, or removed by a nil value; a line left with no options goes.
    static func setting(_ option: String, to value: String?, of variable: String, in lines: [String]) -> [String] {
        let kept = options(of: variable, in: lines).filter { $0.name != option }.map { "\($0.name)=\($0.value)" }
            + (value.map { ["\(option)=\($0)"] } ?? [])
        return lines.filter { !$0.hasPrefix(variable + "=") }
            + (kept.isEmpty ? [] : ["\(variable)=\(kept.joined(separator: ";"))"])
    }
}

/// The Simple view of environment variables and DLL overrides: a control per known setting, for the schema
/// groups of one tab of a title, a container, or one section of a profile file. Reads and writes the same NAME=value lines the Technical view edits as text, and
/// leaves the lines of other tabs as they are.
struct SimpleSettingsEditor: View {
    @Binding var environment: String
    @Binding var dlls: String
    /// The schema groups this tab shows.
    var groups: Set<String>
    /// Variables and options that have their own controls elsewhere in the editor.
    var hidden: Set<String> = []
    /// Switches always on screen, for this tab's common settings.
    var pinned: [String] = []
    /// Settings OverPass has no description for, and DLL overrides, go on this tab.
    var showsOthers = false
    var showsDLLs = true
    /// Variables left as they are, with no row: OverPass sets them itself.
    var kept: Set<String> = []
    var inherited = InheritedSettings()
    var title = "More Settings"
    var note = "For this title only. Hover over a setting for what it does in detail."
    /// Rows for a section of the caller's, with no section of their own.
    var bare = false

    /// One setting; `value` nil keeps a pinned setting on screen without writing it.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String?
        var kind = SettingSpec.Kind.env
    }
    @State private var rows: [Row] = []
    @State private var overrides: [Row] = []
    @State private var loaded = false

    /// Variables OverPass must not take per title: msync has to match the bottle's wineserver.
    private static let unsafe: Set<String> = ["WINEMSYNC"]

    var body: some View {
        Group {
            if bare {
                settingRows
                if showsDLLs { dllRows }
            } else {
                Section {
                    settingRows
                } header: {
                    Text(title)
                } footer: {
                    Text(note)
                }
                if showsOthers && showsDLLs {
                    Section {
                        dllRows
                    } header: {
                        Text("DLL Overrides")
                    } footer: {
                        Text("Which copy of a DLL the title loads: its own (native) or Wine's (builtin).")
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: rows) { write() }
        .onChange(of: overrides) { write() }
    }

    @ViewBuilder private var settingRows: some View {
        ForEach(rows) { row in
            SettingRow(row: Self.binding(row, in: $rows), spec: SettingsSchema.spec(row.name, row.kind),
                       pinned: pinned.contains(row.name), inherited: inherited.variable(row.name)) {
                rows.removeAll { $0.id == row.id }
            }
        }
        addMenu
        ForEach(SettingsSchema.optionVariables.filter { line($0.name).count >= 260 }, id: \.name) { variable in
            Label("\(variable.title): too many options. The runtime ignores all of them past 259 characters.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption)
        }
    }

    @ViewBuilder private var dllRows: some View {
        ForEach(overrides) { row in
            DLLOverrideRow(row: Self.binding(row, in: $overrides)) { overrides.removeAll { $0.id == row.id } }
        }
        Button { overrides.append(Row(name: "", value: "n,b")) } label: { Label("Add DLL Override", systemImage: "plus") }
            .buttonStyle(.borderless)
    }

    /// The Add menu: known settings of this tab not set yet, by what reads them, then a variable of one's own.
    private var addMenu: some View {
        let open = SettingsSchema.all.filter { spec in
            groups.contains(spec.group) && !rows.contains { $0.name == spec.id && $0.kind == spec.kind }
                && !hidden.contains(spec.id) && !Self.unsafe.contains(spec.id)
                && !SettingsSchema.optionVariables.contains { $0.name == spec.id }
        }
        return Menu {
            ForEach(open.filter { $0.kind == .env }) { spec in
                Button(spec.title) { add(spec.id, .env) }
            }
            ForEach(SettingsSchema.optionVariables, id: \.name) { variable in
                let specs = open.filter { $0.kind == variable.kind }
                if !specs.isEmpty {
                    Section(variable.title) {
                        ForEach(specs) { spec in
                            Button(spec.title) { add(spec.id, spec.kind) }
                        }
                    }
                }
            }
            if showsOthers {
                Divider()
                Button("Other Variable…") { add("", .env) }
            }
        } label: {
            Label("Add Setting", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func add(_ id: String, _ kind: SettingSpec.Kind) {
        rows.append(Row(name: id, value: initial(for: id, kind), kind: kind))
    }

    /// The value a newly added setting starts with: on for switches, else its default when that's a value.
    private func initial(for id: String, _ kind: SettingSpec.Kind) -> String? {
        guard let spec = SettingsSchema.spec(id, kind) else { return "" }
        if spec.type == "bool" { return spec.on }
        if let first = spec.values?.first(where: { $0.value == spec.default }) ?? spec.values?.first { return first.value }
        if spec.allowsAutomatic { return "auto" }
        if let min = spec.min, spec.type == "int" || spec.type == "float" { return number(Swift.max(min, Double(spec.default ?? "") ?? min), spec) }
        return ""
    }

    /// A row's binding found by its ID, not its position: a text field can still read its row once more after
    /// the row is removed, and a position-based binding then reads past the end of the list and crashes.
    private static func binding(_ row: Row, in rows: Binding<[Row]>) -> Binding<Row> {
        Binding(get: { rows.wrappedValue.first { $0.id == row.id } ?? row },
                set: { new in
                    if let i = rows.wrappedValue.firstIndex(where: { $0.id == row.id }) { rows.wrappedValue[i] = new }
                })
    }

    private var lines: [String] { environment.split(separator: "\n").map(String.init) }

    private func line(_ variable: String) -> String {
        lines.first { $0.hasPrefix(variable + "=") } ?? ""
    }

    /// Whether a setting is this tab's to show.
    private func isOurs(_ name: String, _ kind: SettingSpec.Kind) -> Bool {
        !kept.contains(name) && (SettingsSchema.spec(name, kind).map { groups.contains($0.group) } ?? showsOthers)
    }

    private func isOptionVariable(_ line: String) -> Bool {
        SettingsSchema.optionVariables.contains { line.hasPrefix($0.name + "=") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        for line in lines where !isOptionVariable(line) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty, isOurs(name, .env) else { continue }
            rows.append(Row(name: name, value: parts.count > 1 ? parts[1] : ""))
        }
        for variable in SettingsSchema.optionVariables {
            rows += SettingsSchema.options(of: variable.name, in: lines).filter { isOurs($0.name, variable.kind) }
                .map { Row(name: $0.name, value: $0.value, kind: variable.kind) }
        }
        let set = rows
        rows = pinned.map { name in set.first { $0.name == name } ?? Row(name: name, value: nil) }
            + set.filter { !pinned.contains($0.name) }
        guard showsOthers && showsDLLs else { return }
        overrides = dlls.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return Row(name: parts[0], value: parts.count > 1 ? parts[1] : "")
        }
    }

    private func write() {
        var new = lines.filter { line in
            isOptionVariable(line) || !isOurs(String(line.prefix { $0 != "=" }), .env)
        } + rows.filter { $0.kind == .env && !$0.name.isEmpty }.compactMap { row in row.value.map { "\(row.name)=\($0)" } }
        for variable in SettingsSchema.optionVariables {
            for option in SettingsSchema.options(of: variable.name, in: new) where isOurs(option.name, variable.kind) {
                new = SettingsSchema.setting(option.name, to: nil, of: variable.name, in: new)
            }
            for row in rows where row.kind == variable.kind {
                new = SettingsSchema.setting(row.name, to: row.value, of: variable.name, in: new)
            }
        }
        // Showing a tab changes nothing, not even the order, so an unchanged title stays unchanged on Save.
        if Self.pairs(new) != Self.pairs(lines) { environment = new.joined(separator: "\n") }
        guard showsOthers && showsDLLs else { return }
        let newDLLs = overrides.filter { !$0.name.isEmpty }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "\n")
        if newDLLs != dlls { dlls = newDLLs }
    }

    /// Every variable and option in a list of lines, in no particular order.
    private static func pairs(_ lines: [String]) -> Set<String> {
        Set(lines.flatMap { line in
            let variable = SettingsSchema.optionVariables.first { line.hasPrefix($0.name + "=") }
            return variable.map { variable in
                SettingsSchema.options(of: variable.name, in: [line]).map { "\(variable.name):\($0.name)=\($0.value)" }
            } ?? [line]
        })
    }

    fileprivate static func number(_ value: Double, _ spec: SettingSpec) -> String {
        spec.type == "int" ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
    private func number(_ value: Double, _ spec: SettingSpec) -> String { Self.number(value, spec) }
}

/// One setting: its plain title and sentence, and the control its type calls for.
struct SettingRow: View {
    @Binding var row: SimpleSettingsEditor.Row
    let spec: SettingSpec?
    /// Always on screen: a switch that writes a line only when it differs from what the title gets anyway.
    var pinned = false
    var inherited: (value: String, source: SettingSource)?
    /// Text gets the width of the row, under its title: profile lines can be long.
    var wide = false
    let remove: () -> Void

    /// The switch's position with no line of the title's own: a rule's value, else the setting's default.
    private var usualValue: String? {
        inherited?.value ?? spec?.default.flatMap { $0.hasPrefix("\(spec?.on ?? "") ") ? spec?.on : nil }
    }

    private var isWide: Bool { wide && !["bool", "enum", "int", "float"].contains(spec?.type ?? "") }

    var body: some View {
        if isWide {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    label
                    Spacer(minLength: 8)
                    removeButton
                }
                control
            }
        } else {
            line
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let spec {
                SettingLabel(spec.title, pinned ? (row.value != nil ? .you : inherited?.source) : nil)
                Text(spec.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Name", text: $row.name, prompt: Text("VARIABLE_NAME"))
                    .font(.body.monospaced())
                    .textFieldStyle(.plain)
                    .labelsHidden()
            }
        }
        .help(spec.map { "\($0.id): \($0.technical)" } ?? "A variable OverPass has no description for.")
    }

    private var removeButton: some View {
        Button(action: remove) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove this setting")
    }

    private var line: some View {
        HStack(alignment: .center, spacing: 10) {
            label
            Spacer(minLength: 8)
            if pinned {
                Toggle("", isOn: Binding(get: { (row.value ?? usualValue) == spec?.on },
                                         set: { new in
                                             row.value = new == (usualValue == spec?.on) ? nil : new ? spec?.on : spec?.off ?? "0"
                                         }))
                    .toggleStyle(.switch).labelsHidden()
            } else {
                control
                removeButton
            }
        }
    }

    private var text: Binding<String> {
        Binding(get: { row.value ?? "" }, set: { row.value = $0 })
    }

    @ViewBuilder
    private var control: some View {
        switch spec?.type {
        case "bool":
            Toggle("", isOn: Binding(get: { row.value == spec?.on },
                                     set: { row.value = $0 ? spec?.on : spec?.off }))
                .toggleStyle(.switch).labelsHidden()
        case "enum":
            Picker("", selection: text) {
                ForEach(spec?.values ?? [], id: \.self) { Text($0.title).tag($0.value) }
                if let value = row.value, !(spec?.values ?? []).contains(where: { $0.value == value }) {
                    Text(value).tag(value)
                }
            }
            .labelsHidden().fixedSize()
        case "int", "float":
            if let spec { NumberControl(value: text, spec: spec) }
        case "path":
            HStack(spacing: 4) {
                TextField("", text: text, prompt: Text("Path")).frame(width: wide ? nil : 180)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { row.value = url.path }
                }
            }
        default:
            TextField("", text: text, prompt: Text(wide ? "Value" : spec?.default.map { "Default: \($0)" } ?? "Value"))
                .labelsHidden()
                .multilineTextAlignment(wide ? .leading : .trailing)
                .frame(width: wide ? nil : 200)
        }
    }
}

/// A number: a slider where the source defines both limits, otherwise a field; "Automatic" where allowed.
private struct NumberControl: View {
    @Binding var value: String
    let spec: SettingSpec

    var body: some View {
        HStack(spacing: 6) {
            if spec.allowsAutomatic {
                Toggle("Automatic", isOn: Binding(get: { value == "auto" },
                                                  set: { value = $0 ? "auto" : SimpleSettingsEditor.number(spec.min ?? 1, spec) }))
                    .toggleStyle(.checkbox)
            }
            if value != "auto" {
                if let min = spec.min, let max = spec.max {
                    Slider(value: Binding(get: { Double(value) ?? min },
                                          set: { value = SimpleSettingsEditor.number($0, spec) }),
                           in: min...max, step: spec.step ?? (spec.type == "int" ? 1 : 0.01))
                        .frame(width: 130)
                }
                // Wider with no slider: IDs, not settings, are what has no limits.
                TextField("", text: $value).frame(width: spec.max == nil ? 90 : 56).multilineTextAlignment(.trailing)
                if let unit = spec.unit, !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A DLL override: the DLL's name and which copy loads.
private struct DLLOverrideRow: View {
    @Binding var row: SimpleSettingsEditor.Row
    let remove: () -> Void
    private var modes: [SettingSpec.Choice] { SettingsSchema.all.first { $0.kind == .dllOverride }?.values ?? [] }

    var body: some View {
        HStack {
            TextField("DLL", text: $row.name, prompt: Text("d3d9")).font(.body.monospaced()).frame(width: 160)
            Spacer()
            Picker("", selection: Binding(get: { row.value ?? "" }, set: { row.value = $0 })) {
                ForEach(modes, id: \.self) { Text($0.title).tag($0.value) }
                if let value = row.value, !modes.contains(where: { $0.value == value }) { Text(value).tag(value) }
            }
            .labelsHidden().fixedSize()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }
}
