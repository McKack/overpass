import SwiftUI

/// The dependency manager: shared components installed outside any bottle.
struct ComponentsView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(\.openSettings) private var openSettings
    @Environment(ComponentManager.self) private var components
    @AppStorage("componentsShowOverPass") private var showOverPass = true
    @AppStorage("componentsShowStores") private var showStores = false
    @AppStorage("componentsShowExtras") private var showExtras = false
    @AppStorage(UpdateCheck.intervalKey) private var interval = UpdateCheck.interval
    @AppStorage(UpdateCheck.onReturnKey) private var onReturn = true

    var body: some View {
        VStack(spacing: 0) {
            updateBar
            Divider()
            List {
                group("OverPass", ComponentID.overpass, expanded: $showOverPass)
                group("Stores", ComponentID.stores, expanded: $showStores)
                group("Extras", ComponentID.extras, expanded: $showExtras)
                automaticUpdates
            }
            .edgeFade()

            LogDrawer(text: components.log, busy: components.busy != nil || components.checking,
                      storageKey: "componentsLog")
        }
        .onChange(of: components.busy) { manager.detectWine() }
        .task {
            UpdateCheck.openComponents = { SettingsTab.open(.components, with: openSettings) }
            await components.checkForUpdates()
        }
    }

    /// How often OverPass checks by itself; Never turns every automatic check off.
    private var automaticUpdates: some View {
        Section {
            Picker("Check for updates automatically", selection: $interval) {
                ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
            }
            Toggle("On startup or when the window comes back after some time", isOn: $onReturn)
                .toggleStyle(.switch)
                .disabled(interval == .never)
            DetailCaption("OverPass checks for new versions of itself and of these components, and notifies you when one is out. With the switch on, it also checks when it starts, and when you come back to it, once that much time has passed since the last check.",
                          technical: "Asks GitHub for each component's latest release at the chosen interval, counted from the last check, while OverPass runs; with the switch, also at launch and on app activation or window deminiaturize when the interval has passed. One notification per new version.")
        } header: {
            Text("Automatic Updates")
        }
    }

    private var updateBar: some View {
        HStack {
            if components.checking {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            } else if !components.updates.isEmpty {
                Text(components.updates.count == 1 ? "1 update available" : "\(components.updates.count) updates available")
            } else if components.lastCheck != nil {
                Text("Everything is up to date.")
            }
            Spacer()
            Button("Check Now") { Task { await components.checkForUpdates() } }
                .disabled(components.checking || components.busy != nil)
            Button(components.updates[.core] != nil ? "Update All and Relaunch" : "Update All") {
                Task { await components.updateAll() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(components.updates.isEmpty || components.busy != nil)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A collapsible section; the header's chevron opens and closes it.
    private func group(_ title: String, _ ids: [ComponentID], expanded: Binding<Bool>) -> some View {
        Section {
            if expanded.wrappedValue {
                ForEach(ids) { ComponentRow(id: $0) }
            }
        } header: {
            Button {
                withAnimation { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Text(title)
                    let pending = ids.filter { components.updates[$0] != nil }.count
                    if !expanded.wrappedValue, pending > 0 {
                        Text(pending == 1 ? "1 update" : "\(pending) updates").foregroundStyle(.blue)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ComponentRow: View {
    @Environment(ComponentManager.self) private var components
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple
    let id: ComponentID

    var body: some View {
        let installed = components.isInstalled(id)
        let blocker = components.blocker(for: id)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(installed ? .green : .secondary)
                Text(detail == .simple ? id.simpleName : id.name).font(.headline)
                if let v = components.installedVersion(id) {
                    Text(v).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if components.busy == id {
                    if id == .wine, components.wineInstaller.isRunning {
                        ProgressView(value: components.wineInstaller.progress).frame(width: 90)
                        Button("Cancel") { components.cancel() }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    actions(installed: installed, blocker: blocker)
                }
            }
            Text(detail == .simple ? id.simpleSummary : id.technicalSummary).font(.callout).foregroundStyle(.secondary)
            if let update = components.updates[id] {
                Label(id == .addons ? "This Wine wants \(update)." : "\(id.name) \(update) is available.",
                      systemImage: "arrow.down.circle.fill")
                    .font(.caption).foregroundStyle(.blue)
            }
            if id == .d3dmetal, installed {
                Text("To update, import a newer Game Porting Toolkit.").font(.caption).foregroundStyle(.secondary)
            }
            if id == .wine, installed, detail == .technical {
                Text(ComponentManager.wineSupportsMetalBackends()
                     ? "This Wine can use OverPass Runtime and D3DMetal."
                     : "This is upstream Wine: it can't load OverPass Runtime or D3DMetal. Reinstall to get OverPass Wine when a release is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let blocker, !installed {
                Label(blocker, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            if detail == .technical {
                if let entry = ComponentCatalog.entry(id) {
                    ComponentParts(entry: entry)
                } else {
                    let credit = id.credit
                    HStack(spacing: 4) {
                        Text("\(credit.author) · \(credit.license)")
                        Link("Source", destination: credit.url)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(installed: Bool, blocker: String?) -> some View {
        if id == .core {
            if components.updates[.core] != nil {
                Button("Update and Relaunch") { Task { await components.install(id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(components.busy != nil)
            }
        } else if id == .d3dmetal {
            Link("Download from Apple", destination: ComponentManager.gptkDownloadPage)
            Button("Import…") { Task { await components.install(id) } }
                .disabled(blocker != nil || components.busy != nil)
            if installed {
                Button("Remove") { components.remove(id) }
                    .disabled(components.busy != nil)
            }
        } else if installed {
            if components.updates[id] != nil {
                Button("Update") { Task { await components.install(id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(components.busy != nil)
            } else {
                Button("Reinstall") { Task { await components.install(id) } }
                    .disabled(components.busy != nil)
            }
            Button("Remove") { components.remove(id) }
                .disabled(components.busy != nil || id == .wine)
        } else {
            Button(id == .wine ? "Download" : "Install") { Task { await components.install(id) } }
                .disabled(blocker != nil || components.busy != nil)
        }
    }
}

/// Technical view of a component: what the catalog says it is made of, the download for this Mac with its
/// checksum, and the Wine features it needs, each marked as present or missing in the installed Wine.
private struct ComponentParts: View {
    let entry: ComponentCatalog.Component

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(entry.parts, id: \.name) { part in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(part.name).fontWeight(.medium)
                        Text(part.version).foregroundStyle(.secondary)
                        if let upstream = part.upstream { Link("Source", destination: upstream) }
                    }
                    Text([part.authors, part.licence].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let asset = asset(part) {
                        Text(download(asset))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .help(asset.sha256 ?? "")
                    }
                }
            }
            if let needs = entry.requires?.wineFeatures, !needs.isEmpty {
                let missing = BottleManager.findWine().map { WineFeatures.missing(needs, wineRoot: $0) } ?? needs
                needs.reduce(Text("Wine features:").foregroundStyle(.secondary)) { line, need in
                    let have = !missing.contains(need)
                    return line + Text("  ") + Text("\(Image(systemName: have ? "checkmark.circle" : "xmark.circle")) \(need)")
                        .foregroundStyle(have ? .secondary : Color.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let archs = entry.requires?.arch {
                Text("Runs on \(archs.joined(separator: ", ")) Macs").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    /// The file name and how it is checked: a pinned checksum (shortened, in full on hover), or where the
    /// version comes from when the catalog only has an address template.
    private func download(_ asset: ComponentCatalog.Component.Part.Asset) -> String {
        let file = asset.url?.lastPathComponent ?? asset.urlTemplate.map { ($0 as NSString).lastPathComponent } ?? asset.arch
        guard let sha256 = asset.sha256 else { return "\(file) · latest release, no pinned checksum" }
        let pinned = sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
        return pinned ? "\(file) · sha256 \(sha256.prefix(12))…" : "\(file) · checksum \(sha256.lowercased())"
    }

    /// The asset this Mac would download.
    private func asset(_ part: ComponentCatalog.Component.Part) -> ComponentCatalog.Component.Part.Asset? {
        part.assets.first { $0.arch == ComponentManager.arch } ?? part.assets.first { $0.arch == "any" }
    }
}
