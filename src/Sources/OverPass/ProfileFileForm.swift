import SwiftUI

/// A profile file laid out section by section. Every change goes straight into the file's text, so comments and
/// the lines of other sections stay as they are, and the Advanced view shows the same file.
struct ProfileFileForm: View {
    @Binding var text: String
    @State private var newRule = ""

    private static let recipes = ["app": "About This App", "store": "Where It's Sold", "install": "Installing", "launch": "Starting"]

    private var file: ProfileText { ProfileText(text: text) }

    private func change(_ edit: (inout ProfileText) -> Void) {
        var file = file
        edit(&file)
        text = file.text
    }

    /// The env or dll lines of a section as the text SimpleSettingsEditor edits. Looks the section up on each
    /// use: its place in the file moves as other sections change.
    private func lines(_ key: String, of id: String) -> Binding<String> {
        Binding(get: { current(id)?.lines.filter { $0.key == key }.map(\.value).joined(separator: "\n") ?? "" },
                set: { new in
                    guard let part = current(id) else { return }
                    change { $0.setAll(key, new.split(separator: "\n").map(String.init), in: part) }
                })
    }

    private func current(_ id: String) -> ProfileText.Part? { file.parts.first { $0.id == id } }

    private func row(_ line: ProfileText.Part.Line) -> Binding<SimpleSettingsEditor.Row> {
        Binding(get: { SimpleSettingsEditor.Row(name: line.key, value: line.value, kind: .ruleKey) },
                set: { new in change { $0.setLine(line.id, key: new.name, value: new.value ?? "") } })
    }

    var body: some View {
        Form {
            ForEach(file.parts) { part in
                let isRecipe = Self.recipes[part.name.lowercased()] != nil
                let controls = !isRecipe || part.lines.contains { $0.key == "env" || $0.key == "dll" }
                Section {
                    ForEach(part.lines.filter { !controls || ($0.key != "env" && $0.key != "dll") }) { line in
                        SettingRow(row: row(line), spec: SettingsSchema.key(line.key, in: part.name), wide: true) {
                            change { $0.setLine(line.id, key: line.key, value: nil) }
                        }
                    }
                    if controls {
                        SimpleSettingsEditor(environment: lines("env", of: part.id), dlls: lines("dll", of: part.id),
                                             groups: Set(SettingsSchema.all.map(\.group)), showsOthers: true, bare: true)
                    }
                    addLine(part, isRecipe: isRecipe)
                } header: {
                    HStack {
                        Text(Self.recipes[part.name.lowercased()] ?? part.name)
                        Spacer()
                        if !isRecipe {
                            Button("Remove", systemImage: "minus.circle") { change { $0.remove(part) } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Remove this rule")
                        }
                    }
                } footer: {
                    if !part.comment.isEmpty { Text(part.comment) }
                }
            }
            Section {
                HStack {
                    TextField("New rule", text: $newRule, prompt: Text("Name of the rule"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                    Button("Add Rule") {
                        change { $0.addSection(newRule.trimmingCharacters(in: .whitespaces)) }
                        newRule = ""
                    }
                    .disabled(!isFreeName)
                }
            } footer: {
                Text("A rule changes how the programs it names start, in any container.")
            }
        }
        .formStyle(.grouped)
    }

    /// A rule's name can't have brackets, nor be taken: rules with one name would read as one.
    private var isFreeName: Bool {
        let name = newRule.trimmingCharacters(in: .whitespaces).lowercased()
        return !name.isEmpty && !name.contains("[") && !name.contains("]") && Self.recipes[name] == nil
            && !file.parts.contains { $0.name.lowercased() == name }
    }

    /// Lines the section can still take; a key that can't repeat goes once it's there.
    private func addLine(_ part: ProfileText.Part, isRecipe: Bool) -> some View {
        let specs = SettingsSchema.all.filter { spec in
            (isRecipe ? spec.kind == .profileKey && spec.group == part.name.lowercased() : spec.kind == .ruleKey)
                && spec.id != "env" && spec.id != "dll"
                && (spec.repeatable == true || !part.lines.contains { $0.key == spec.id })
        }
        return Menu {
            ForEach(specs) { spec in
                Button(spec.title) {
                    let first = spec.type == "bool" ? spec.on : spec.values?.first?.value
                    change { $0.setAll(spec.id, part.lines.filter { $0.key == spec.id }.map(\.value) + [first ?? ""], in: part) }
                }
            }
        } label: {
            Label("Add Line", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
