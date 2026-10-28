import AppKit
import SwiftUI

/// What OverPass knows about the variables and options a title can set (Schema/settings.json): their type,
/// values and limits, so the profile editor's Simple view can show a switch, a menu or a slider instead of
/// NAME=value text. Anything not in it is shown as text.
struct SettingSpec: Decodable, Identifiable {
    struct Choice: Decodable, Hashable { let value: String; let title: String }
    enum Kind: String, Decodable { case env, dxmtConfig = "dxmt-config", mtld3dConfig = "mtld3d-config", ruleKey = "rule-key", dllOverride = "dll-override" }

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

    /// A number that also accepts "auto" (its default).
    var allowsAutomatic: Bool { (type == "int" || type == "float") && self.default == "auto" }
}

enum SettingsSchema {
    private struct File: Decodable { let format: Int; let settings: [SettingSpec] }

    static let all: [SettingSpec] = {
        guard let url = ProfileStore.resourceBundle.url(forResource: "settings", withExtension: "json", subdirectory: "Schema"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1 else { return [] }
        return file.settings
    }()

    static func spec(_ id: String, _ kind: SettingSpec.Kind) -> SettingSpec? {
        all.first { $0.kind == kind && ($0.kind == .env ? $0.id == id : $0.id.caseInsensitiveCompare(id) == .orderedSame) }
    }

    /// The order groups are listed in.
    static let groups = ["Graphics", "Display", "Performance", "Compatibility", "Sound", "Network", "Launch", "Debugging"]

    /// Variables holding options of their own, shown as their own sections.
    static let optionVariables: [(name: String, kind: SettingSpec.Kind, title: String)] = [
        ("DXMT_CONFIG", .dxmtConfig, "OverPass Runtime: Direct3D 10–12"),
        ("MTLD3D_CONFIG", .mtld3dConfig, "OverPass Runtime: Direct3D 9"),
    ]
}

/// The Simple view of a title's environment variables and DLL overrides: a control per known setting.
/// Reads and writes the same NAME=value lines the Technical view edits as text.
struct SimpleSettingsEditor: View {
    @Binding var environment: String
    @Binding var dlls: String
    /// Variables and options that have their own controls elsewhere in the editor.
    var hidden: Set<String> = []

    /// One setting; `value` nil keeps a switched-off setting on screen without writing it.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String?
    }
    @State private var variables: [Row] = []
    @State private var options: [String: [Row]] = [:]
    @State private var overrides: [Row] = []
    @State private var loaded = false
    /// Option variables shown as sections, also while they hold no options yet.
    @State private var openSections: Set<String> = []

    /// Variables OverPass must not take per title: msync has to match the bottle's wineserver.
    private static let unsafe: Set<String> = ["WINEMSYNC"]

    var body: some View {
        Group {
            Section {
                ForEach($variables) { $row in
                    SettingRow(row: $row, spec: SettingsSchema.spec(row.name, .env)) { remove(row.id, from: &variables) }
                }
                addMenu(.env, present: Set(variables.map(\.name))) { name in
                    if SettingsSchema.optionVariables.contains(where: { $0.name == name }) {
                        openSections.insert(name)
                    } else {
                        variables.append(Row(name: name, value: initial(for: name, .env)))
                    }
                }
            } header: {
                Text("Settings")
            } footer: {
                Text("For this title only. Hover over a setting for what it does in detail.")
            }
            ForEach(SettingsSchema.optionVariables, id: \.name) { variable in
                let rows = options[variable.name] ?? []
                if !rows.isEmpty || openSections.contains(variable.name) {
                    Section {
                        ForEach(Binding(get: { options[variable.name] ?? [] }, set: { options[variable.name] = $0 })) { $row in
                            SettingRow(row: $row, spec: SettingsSchema.spec(row.name, variable.kind)) {
                                options[variable.name]?.removeAll { $0.id == row.id }
                            }
                        }
                        addMenu(variable.kind, present: Set(rows.map(\.name))) {
                            options[variable.name, default: []].append(Row(name: $0, value: initial(for: $0, variable.kind)))
                        }
                        if optionsLine(variable.name).count >= 260 {
                            Label("Too many options: the runtime ignores all of them past 259 characters.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    } header: {
                        Text(variable.title)
                    }
                }
            }
            Section {
                ForEach($overrides) { $row in
                    DLLOverrideRow(row: $row) { remove(row.id, from: &overrides) }
                }
                Button { overrides.append(Row(name: "", value: "n,b")) } label: { Label("Add DLL Override", systemImage: "plus") }
                    .buttonStyle(.borderless)
            } header: {
                Text("DLL Overrides")
            } footer: {
                Text("Which copy of a DLL the title loads: its own (native) or Wine's (builtin).")
            }
        }
        .onAppear(perform: load)
        .onChange(of: variables) { write() }
        .onChange(of: options) { write() }
        .onChange(of: overrides) { write() }
    }

    /// The Add menu: known settings of a kind not set yet, by group, then a variable of one's own.
    @ViewBuilder
    private func addMenu(_ kind: SettingSpec.Kind, present: Set<String>, add: @escaping (String) -> Void) -> some View {
        let open = SettingsSchema.all.filter {
            $0.kind == kind && !present.contains($0.id) && !hidden.contains($0.id) && !Self.unsafe.contains($0.id)
                && !openSections.contains($0.id)
        }
        Menu {
            ForEach(SettingsSchema.groups, id: \.self) { group in
                let specs = open.filter { $0.group == group }
                if !specs.isEmpty {
                    Section(group) {
                        ForEach(specs) { spec in
                            Button(spec.title) { add(spec.id) }
                        }
                    }
                }
            }
            if kind == .env {
                Divider()
                Button("Other Variable…") { add("") }
            }
        } label: {
            Label(kind == .env ? "Add Setting" : "Add Option", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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

    private func remove(_ id: UUID, from rows: inout [Row]) { rows.removeAll { $0.id == id } }

    private func optionsLine(_ variable: String) -> String {
        (options[variable] ?? []).compactMap { row in row.value.map { "\(row.name)=\($0)" } }.joined(separator: ";")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        for line in environment.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            if SettingsSchema.optionVariables.contains(where: { $0.name == name }) {
                openSections.insert(name)
                options[name, default: []] += value.split(separator: ";").map { option in
                    let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                    return Row(name: pair[0], value: pair.count > 1 ? pair[1] : "")
                }
            } else {
                variables.append(Row(name: name, value: value))
            }
        }
        overrides = dlls.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return Row(name: parts[0], value: parts.count > 1 ? parts[1] : "")
        }
    }

    private func write() {
        var lines = variables.compactMap { row in row.value.map { "\(row.name)=\($0)" } }.filter { !$0.hasPrefix("=") }
        for variable in SettingsSchema.optionVariables {
            let line = optionsLine(variable.name)
            if !line.isEmpty { lines.append("\(variable.name)=\(line)") }
        }
        environment = lines.joined(separator: "\n")
        dlls = overrides.filter { !$0.name.isEmpty }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "\n")
    }

    fileprivate static func number(_ value: Double, _ spec: SettingSpec) -> String {
        spec.type == "int" ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
    private func number(_ value: Double, _ spec: SettingSpec) -> String { Self.number(value, spec) }
}

/// One setting: its plain title and sentence, and the control its type calls for.
private struct SettingRow: View {
    @Binding var row: SimpleSettingsEditor.Row
    let spec: SettingSpec?
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let spec {
                    Text(spec.title)
                    Text(spec.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Name", text: $row.name, prompt: Text("VARIABLE_NAME"))
                        .font(.body.monospaced())
                        .textFieldStyle(.plain)
                }
            }
            .help(spec.map { "\($0.id): \($0.technical)" } ?? "A variable OverPass has no description for.")
            Spacer(minLength: 8)
            control
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this setting")
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
                TextField("", text: text, prompt: Text("Path")).frame(width: 180)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { row.value = url.path }
                }
            }
        default:
            TextField("", text: text, prompt: Text(spec?.default.map { "Default: \($0)" } ?? "Value"))
                .frame(width: 200)
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
                TextField("", text: $value).frame(width: 56).multilineTextAlignment(.trailing)
                if let unit = spec.unit, !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A DLL override: the DLL's name and which copy loads.
private struct DLLOverrideRow: View {
    @Binding var row: SimpleSettingsEditor.Row
    let remove: () -> Void
    private static let modes = SettingsSchema.all.first { $0.kind == .dllOverride }?.values ?? []

    var body: some View {
        HStack {
            TextField("DLL", text: $row.name, prompt: Text("d3d9")).font(.body.monospaced()).frame(width: 160)
            Spacer()
            Picker("", selection: Binding(get: { row.value ?? "" }, set: { row.value = $0 })) {
                ForEach(Self.modes, id: \.self) { Text($0.title).tag($0.value) }
                if let value = row.value, !Self.modes.contains(where: { $0.value == value }) { Text(value).tag(value) }
            }
            .labelsHidden().fixedSize()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }
}
