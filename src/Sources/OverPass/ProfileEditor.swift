import SwiftUI
import UniformTypeIdentifiers

// The profile editor: everything about how one installed app runs. The app's own settings are saved to its
// profile's "My settings" rule (a copy of the bundled profile, the first time), so they also apply when a
// launcher starts the game. Bottle settings are shared with everything else in the bottle and apply right away.

/// Which XAudio2 a program gets: Wine's own, or Microsoft's from the DirectX June 2010 runtime, as CrossOver
/// sets for games whose sound breaks up or goes missing with Wine's.
enum XAudioChoice: String, CaseIterable, Identifiable {
    case wine, microsoft
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wine: "Wine's own (default)"
        case .microsoft: "Microsoft's (DirectX June 2010)"
        }
    }

    static let overrides = ["xaudio2_6", "xaudio2_7", "x3daudio1_6", "x3daudio1_7"].map { "\($0)=n,b" }
}

/// How OverPass Runtime compiles a Direct3D 12 game's pipelines, set through DXMT_CONFIG.
enum ShaderCompileChoice: String, CaseIterable, Identifiable {
    case background, skip, immediate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "In the background (default)"
        case .skip: "In the background, skip drawing until ready"
        case .immediate: "When the game creates them"
        }
    }

    /// DXMT_CONFIG options this choice sets; the default sets none.
    var options: [String] {
        switch self {
        case .background: []
        case .skip: ["d3d12.skipDrawsWhileCompiling=True"]
        case .immediate: ["d3d12.asyncPipelineCompile=False"]
        }
    }

    static let keys = ["d3d12.skipDrawsWhileCompiling", "d3d12.asyncPipelineCompile"]

    static func isOwn(_ option: String) -> Bool {
        keys.contains { option.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix($0.lowercased() + "=") }
    }
}

struct ProfileEditor: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem

    @State private var tab = "general"
    @State private var profileID = ""
    @State private var text = ""
    @State private var name = ""
    @State private var arguments = ""
    @State private var graphics: GraphicsBackend?
    @State private var direct3D9: Direct3D9Backend?
    @State private var xaudio = XAudioChoice.wine
    @State private var shaders = ShaderCompileChoice.background
    /// x87sidecar for this game's 32-bit programs (env OVERPASS_X87=1).
    @State private var fasterX87 = false
    @State private var maxResolution = ""
    @State private var environment = ""
    @State private var dlls = ""
    @State private var art = ArtworkDraft()
    @State private var editingArtwork = false
    @State private var storeCover: NSImage?
    /// The backdrop of the generated cover, shown when the title has no cover art.
    @State private var generatedBackground: NSImage?
    @State private var currentIcon: NSImage?
    @State private var editingName = false
    @State private var hoveringName = false
    @FocusState private var nameFocused: Bool
    @State private var nameMonitor: Any?
    @State private var nameHeight: CGFloat = 26
    @State private var installSize: Int64?
    @State private var loaded = false
    @State private var editingFile = false
    @State private var error: String?

    private static let tabs: [IconTabBar<String>.Item] = [
        .init(tab: "general", title: "General", symbol: "gearshape"),
        .init(tab: "graphics", title: "Graphics & Sound", symbol: "display"),
        .init(tab: "advanced", title: "Advanced", symbol: "wrench.and.screwdriver"),
        .init(tab: "bottle", title: "Container", symbol: BottleIcon.symbol),
    ]

    /// "Notepad++ — General": the title, then the tab, as document windows name their part.
    private var windowTitle: String {
        let title = name.isEmpty ? item.app.name : name
        return "\(title) — \(Self.tabs.first { $0.tab == tab }?.title ?? "")"
    }

    private var profile: GameProfile? { profiles.profile(id: profileID) }
    private var isSteam: Bool { item.app.launcher == "Steam" && item.app.storeID != nil }
    /// What the app's own settings apply to; nil when OverPass can't tell which program runs.
    private var identity: String? {
        if isSteam, let id = item.app.storeID { return "steam-app = \(id)" }
        return item.app.programName.map { "program = \($0)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drawn where Settings has its title and toolbar: the window's title bar is hidden.
            Text(windowTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 80)
                .frame(height: 28)
            IconTabBar(items: Self.tabs, selection: $tab)
                .padding(.top, -6)
            Divider()
            Group {
                switch tab {
                case "graphics": graphicsAndSound
                case "advanced": advanced
                case "bottle": BottleSettings(bottle: item.bottle)
                default: general
                }
            }
            .edgeFade()
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Export…", action: export)
                if profiles.edited.contains(profileID) {
                    Button("Revert to Original") { profiles.revert(id: profileID); load() }
                        .help("Throw away your changes and use the profile that comes with OverPass")
                } else if profiles.custom.contains(profileID) {
                    Button("Delete Profile") { profiles.revert(id: profileID); dismiss() }
                }
                Spacer()
                DetailSwitch().padding(.trailing, 8)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if save() { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identity == nil)
            }
            .padding()
        }
        // The content reaches up under the hidden title bar; the window adds that bar's height to the frame below.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .frame(width: 620, height: 612)
        .navigationTitle(windowTitle)
        .onAppear { if !loaded { load() } }
        .sheet(isPresented: $editingArtwork) {
            ArtworkEditor(item: item, name: name.isEmpty ? item.app.name : name, profileIcon: profile?.icon,
                          profileCover: profile?.cover, clientColor: manager.clientColor(for: item.bottle, in: profiles),
                          draft: $art)
        }
        .sheet(isPresented: $editingFile) {
            ProfileFileEditor(id: profileID, text: profiles.text(of: profileID) ?? builtText()) { load() }
        }
        .alert("Couldn't Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: Tabs

    private var general: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    // The icon, as tall as the name, in front of it; both centred over the section.
                    HStack(spacing: 8) {
                        Button { editingArtwork = true } label: { iconWell }
                            .buttonStyle(.plain)
                            .help("The icon in the library, the Dock and Launchpad")
                        nameEditor
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameHeight = $0 }
                    }
                    .frame(maxWidth: .infinity)
                    // The cover on the left with the facts beside it; the change buttons bottom right.
                    HStack(alignment: .bottom, spacing: 16) {
                        Button { editingArtwork = true } label: { coverWell }
                            .buttonStyle(.plain)
                            .help("The cover shown when titles are shown as covers; a 2:3 picture (600 × 900) fits best")
                        facts
                            .frame(maxHeight: .infinity)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 8) {
                            Button("Edit Artwork…") { editingArtwork = true }
                                .help("The cover, the icon, and how generated ones look")
                            Button("Report Issue…") {
                                ReportCenter.shared.show(ReportContext(item: item, mode: .title, profileText: builtText()))
                            }
                                .help("Record a log while you reproduce a problem, for a bug report")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Program") {
                    HStack {
                        Text(item.app.target ?? item.app.executable).textSelection(.enabled)
                        if let folder = item.installFolder {
                            Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless)
                                .help("Show the install in Finder")
                        }
                    }
                }
                if isSteam, let id = item.app.storeID { LabeledContent("Steam app", value: id) }
                TextField("Extra arguments", text: $arguments, prompt: Text("e.g. -windowed"))
            } footer: {
                if identity == nil {
                    Text("OverPass can't tell which program this shortcut starts, so it can't keep settings for it.")
                        .foregroundStyle(.orange)
                }
            }
            Section("Profile") {
                LabeledContent("Status", value: status)
                if profiles.originalChanged.contains(profileID) {
                    Label("OverPass has a newer version of this profile. Revert to Original to use it; your changes are then lost.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if let profile {
                    if let notes = profile.notes { Text(notes).font(.callout).foregroundStyle(.secondary) }
                    ForEach(profile.sources, id: \.url) { source in
                        Link(source.title, destination: source.url).font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Where the title comes from, how much room its install takes and how well it runs, between the icon
    /// and the cover.
    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Platform").foregroundStyle(.secondary)
                Text(platformName(item, clients: manager.installedClients(from: profiles), manager: manager) ?? "Standalone")
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(installSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                     ?? (item.installFolder == nil ? "Unknown" : "Counting…"))
            }
            GridRow {
                Text("Rating").foregroundStyle(.secondary)
                RatingLabel(rating: profile?.rating ?? GameProfile.Rating())
            }
        }
        .font(.callout)
        .task(id: item.id) {
            guard let folder = item.installFolder else { return }
            installSize = await Task.detached(priority: .utility) { Self.size(of: folder) }.value
        }
    }

    /// The space a folder takes on disk, counting everything inside it.
    nonisolated private static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private var status: String {
        if profiles.edited.contains(profileID) { return "Changed by you (\(profileID).ini)" }
        if profiles.custom.contains(profileID) { return "Made by you (\(profileID).ini)" }
        if profile != nil { return "As it comes with OverPass (\(profileID).ini)" }
        return "None yet. Saving makes one."
    }

    private var iconWell: some View {
        Group {
            if let pickedIcon = art.pickedIcon, let image = NSImage(contentsOf: pickedIcon) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if !art.removeIcon, let icon = profile?.icon,
                      let image = NSImage(contentsOf: UserProfiles.iconsDirectory.appendingPathComponent(icon)) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                // The app as found in the bottle, before a picked icon replaced its own (a Steam game's is its
                // program's icon, not steam.exe's).
                AppIcon(item: LibraryItem(app: item.bottle.apps.first { $0.id == item.app.id } ?? item.app, bottle: item.bottle),
                        size: nameHeight)
            }
        }
        .frame(width: nameHeight, height: nameHeight)
    }

    /// The name as a title; clicking it, or the pencil that shows while hovering, edits it in place.
    private var nameEditor: some View {
        HStack(spacing: 6) {
            if editingName {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .font(.title2.weight(.semibold))
                    .fixedSize()
                    .onAppear { nameMonitor = Self.endEditingOnClickOutside() }
                    .onDisappear { nameMonitor.map(NSEvent.removeMonitor); nameMonitor = nil }
                    .focused($nameFocused)
                    .onSubmit { editingName = false }
                    .onChange(of: nameFocused) { _, focused in if !focused { editingName = false } }
                    .task {
                        nameFocused = true
                        // A field taking focus selects its text; put the caret at the end instead.
                        try? await Task.sleep(for: .milliseconds(50))
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                        }
                    }
            } else {
                Text(name.isEmpty ? item.app.name : name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .onTapGesture { editingName = true }
                Button { editingName = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename")
                    .opacity(hoveringName ? 1 : 0)
            }
        }
        .onHover { hoveringName = $0 }
    }

    /// Clicking anywhere but the field being edited ends editing (and keeps the text), which a Form's empty
    /// space doesn't do by itself.
    private static func endEditingOnClickOutside() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = event.window, let editor = window.firstResponder as? NSTextView,
               let field = editor.delegate as? NSView,
               let hit = window.contentView?.hitTest(event.locationInWindow), !hit.isDescendant(of: field) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private var coverWell: some View {
        Group {
            if let picture = art.coverPicture(profileCover: profile?.cover, storeCover: storeCover) {
                StyledPicture(picture: picture, style: art.coverStyle.withClient(manager.clientColor(for: item.bottle, in: profiles)),
                              width: 80)
            } else {
                GeneratedCover(icon: currentIcon, background: generatedBackground, style: art.coverStyle, width: 80)
            }
        }
        .frame(width: 80, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            var app = item.app
            app.cover = nil
            app.generatedCover = false
            storeCover = await CoverArt.image(for: LibraryItem(app: app, bottle: item.bottle))
        }
        .task(id: "\(art.coverStyle.base)\(art.coverStyle.frost)\(art.pickedIcon?.path ?? "")\(art.removeIcon)") { await drawGeneratedCover() }
    }

    /// The generated cover's backdrop for the form's current icon and style, with the client's colour filled in.
    private func drawGeneratedCover() async {
        let file = await art.iconFile(profileIcon: profile?.icon, item: item)
        let style = art.coverStyle.withClient(manager.clientColor(for: item.bottle, in: profiles))
        let size = CGSize(width: 200, height: 300)
        let images = await Task.detached(priority: .utility) { () -> (NSImage, NSImage?)? in
            guard let icon = file.flatMap(NSImage.init(contentsOf:)) else { return nil }
            return (icon, style.background(for: icon, size: size).map { NSImage(cgImage: $0, size: size) })
        }.value
        currentIcon = images?.0
        generatedBackground = images?.1
    }

    private var graphicsAndSound: some View {
        Form {
            Section {
                Picker("Direct3D 10–12", selection: $graphics) {
                    Text("Same as the container (\(item.bottle.graphics.displayName))").tag(GraphicsBackend?.none)
                    Divider()
                    ForEach(GraphicsBackend.allCases.filter { $0 != .auto }) { Text($0.displayName).tag(Optional($0)) }
                }
                Picker("Direct3D 9", selection: $direct3D9) {
                    Text("Same as the container (\(item.bottle.direct3D9.displayName))").tag(Direct3D9Backend?.none)
                    Divider()
                    ForEach(Direct3D9Backend.allCases.filter { $0 != .auto }) { Text($0.displayName).tag(Optional($0)) }
                }
            } footer: {
                Text("OverPass Runtime suits most Direct3D 10 to 12 games, mtld3d most Direct3D 9 games. Direct3D 8 and older always use WineD3D.")
            }
            Section {
                Toggle("Faster x87 math", isOn: $fasterX87)
            } footer: {
                Text(ComponentManager.current?.isInstalled(.x87sidecar) == false
                     ? "Needs x87sidecar: install it under Settings › Components › Extras. Until then this does nothing."
                     : "For 32-bit games, mostly from the Direct3D 9 era and older: x87sidecar replaces Rosetta's slow translation of their floating-point math.")
            }
            Section {
                MaxResolutionPicker(value: $maxResolution, inherited: MaxResolution.global)
            } footer: {
                Text("The largest resolution this game can pick. Sizes above the desktop are scaled down to fit.")
            }
            Section {
                Picker("Compile shaders", selection: $shaders) {
                    ForEach(ShaderCompileChoice.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Direct3D 12")
            } footer: {
                Text("If the game stutters while new shaders compile, try skipping: an object may be missing for a "
                     + "moment instead of the game pausing. Compiled shaders are kept, so this mostly matters the "
                     + "first time. Applies to OverPass Runtime.")
            }
            Section {
                Picker("XAudio2", selection: $xaudio) {
                    ForEach(XAudioChoice.allCases) { Text($0.title).tag($0) }
                }
                if xaudio == .microsoft && !microsoftXAudioInstalled {
                    HStack {
                        Label("Microsoft's XAudio2 isn't in this container yet.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Install DirectX June 2010") { tab = "bottle" }
                    }
                }
                LabeledContent("Mac sound output", value: LogCollector.outputDevice() ?? "Unknown")
            } header: {
                Text("Sound")
            } footer: {
                Text("If a game's sound crackles, cuts out or is missing, try Microsoft's XAudio2. It only helps "
                     + "games that use XAudio2. Sample rates and sound buffers are matched to your Mac's sound output "
                     + "automatically.")
            }
        }
        .formStyle(.grouped)
    }

    private var microsoftXAudioInstalled: Bool {
        let windows = item.bottle.driveC.appendingPathComponent("windows")
        return ["system32", "syswow64"].contains { dir in
            WindowsIcons.caseInsensitive(windows, "\(dir)/xaudio2_7.dll").map { !LogCollector.isWineBuiltin($0) } ?? false
        }
    }

    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple

    private var advanced: some View {
        Form {
            if detail == .simple {
                // Shader compiling, the maximum resolution and x87 have their own controls on other tabs.
                SimpleSettingsEditor(environment: $environment, dlls: $dlls,
                                     hidden: ["OVERPASS_X87", "OVERPASS_MAX_RESOLUTION", "ROSETTA_X87_PATH",
                                              "d3d12.asyncPipelineCompile", "d3d12.skipDrawsWhileCompiling"])
            } else {
                technicalSettings
            }
            Section {
                HStack {
                    Text("Everything in the profile, including its rules for other programs.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Profile File…") {
                        if save() { editingFile = true }
                    }
                    .disabled(identity == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var technicalSettings: some View {
            Section {
                TextEditor(text: $environment)
                    .font(.body.monospaced())
                    .frame(height: 80)
            } header: {
                Text("Environment Variables")
            } footer: {
                Text("One NAME=value per line, for this app only.")
            }
            Section {
                TextEditor(text: $dlls)
                    .font(.body.monospaced())
                    .frame(height: 80)
            } header: {
                Text("DLL Overrides")
            } footer: {
                Text("One per line, as in WINEDLLOVERRIDES: d3d9=n,b uses the game's own d3d9.dll before Wine's.")
            }
    }

    // MARK: Loading and saving

    private func load() {
        loaded = true
        if let existing = profiles.profile(for: item) {
            profileID = existing.id
            text = profiles.text(of: existing.id) ?? ""
        } else {
            profileID = UserProfiles.newID(for: item.app.name, taken: Set(profiles.profiles.map(\.id)))
            text = newProfileText()
        }
        let profileText = ProfileText(text: text)
        name = profileText.first("name", in: "app") ?? item.app.name
        let mine = profileText.values(in: UserProfiles.settingsSection)
        arguments = mine.filter { $0.key == "add-arguments" }.map(\.value).joined(separator: " ")
        graphics = mine.last { $0.key == "graphics" }.flatMap { GraphicsBackend(rawValue: $0.value) }
        direct3D9 = mine.last { $0.key == "d3d9" }.flatMap { Direct3D9Backend(rawValue: $0.value) }
        // The shader choice lives in DXMT_CONFIG; the rest of it stays in the environment text.
        var envLines = mine.filter { $0.key == "env" }.map(\.value)
        shaders = .background
        if let i = envLines.lastIndex(where: { $0.hasPrefix("DXMT_CONFIG=") }) {
            let options = envLines[i].dropFirst("DXMT_CONFIG=".count).split(separator: ";").map(String.init)
            shaders = ShaderCompileChoice.allCases.first { !$0.options.isEmpty && $0.options.allSatisfy(options.contains) }
                ?? .background
            let rest = options.filter { !ShaderCompileChoice.isOwn($0) }
            if rest.isEmpty { envLines.remove(at: i) } else { envLines[i] = "DXMT_CONFIG=" + rest.joined(separator: ";") }
        }
        // So does the maximum resolution.
        let maxPrefix = MaxResolution.variable + "="
        maxResolution = envLines.last { $0.hasPrefix(maxPrefix) }
            .flatMap { MaxResolution.normalized(String($0.dropFirst(maxPrefix.count))) } ?? ""
        envLines.removeAll { $0.hasPrefix(maxPrefix) }
        fasterX87 = envLines.contains("OVERPASS_X87=1")
        envLines.removeAll { $0.hasPrefix("OVERPASS_X87=") }
        environment = envLines.joined(separator: "\n")
        let overrides = mine.filter { $0.key == "dll" }.map(\.value)
        xaudio = Set(XAudioChoice.overrides).isSubset(of: overrides) ? .microsoft : .wine
        dlls = overrides.filter { xaudio == .wine || !XAudioChoice.overrides.contains($0) }.joined(separator: "\n")
        art = ArtworkDraft(generatedCover: profileText.first("cover", in: "app") == ArtStyle.generatedCover,
                           coverStyle: ArtStyle(profileText.first("cover-style", in: "app"), default: .cover),
                           iconStyle: ArtStyle(profileText.first("icon-style", in: "app"), default: .icon))
    }

    /// A profile for an app OverPass has none for: enough to find the app again.
    private func newProfileText() -> String {
        var lines = ["[app]", "name = \(item.app.name)", "rating = untested", "bottle = \(item.bottle.template.rawValue)"]
        switch (item.app.launcher, item.app.storeID) {
        case ("Steam", let id?): lines.append("steam-app = \(id)")
        case ("GOG", let id?): lines.append("gog-game = \(id)")
        default:
            if let target = item.app.target { lines += ["", "[launch]", "executable = \(target)"] }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The profile with the form's changes, as it would be saved.
    private func builtText() -> String {
        var profileText = ProfileText(text: text)
        profileText.set("name", name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? item.app.name, in: "app")
        if art.removeIcon { profileText.set("icon", nil, in: "app") }
        if let pickedIcon = art.pickedIcon { profileText.set("icon", "\(profileID).\(pickedIcon.pathExtension.lowercased())", in: "app") }
        if art.removeCover { profileText.set("cover", nil, in: "app") }
        if let pickedCover = art.pickedCover { profileText.set("cover", coverFileName(for: pickedCover), in: "app") }
        if art.generatedCover { profileText.set("cover", ArtStyle.generatedCover, in: "app") }
        profileText.set("cover-style", art.coverStyle == .cover ? nil : art.coverStyle.value, in: "app")
        profileText.set("icon-style", art.iconStyle == .icon ? nil : art.iconStyle.value, in: "app")

        var settings: [String] = []
        if !arguments.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.append("add-arguments = \(arguments.trimmingCharacters(in: .whitespaces))")
        }
        if let graphics { settings.append("graphics = \(graphics.rawValue)") }
        // After graphics: OverPass Wine applies d3d9 to the DLL path graphics set.
        if let direct3D9 { settings.append("d3d9 = \(direct3D9.rawValue)") }
        var envLines = environment.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") && !$0.hasPrefix("=") }
        if !shaders.options.isEmpty {
            if let i = envLines.lastIndex(where: { $0.hasPrefix("DXMT_CONFIG=") }) {
                let rest = envLines[i].dropFirst("DXMT_CONFIG=".count).split(separator: ";").map(String.init)
                    .filter { !ShaderCompileChoice.isOwn($0) }
                envLines[i] = "DXMT_CONFIG=" + (rest + shaders.options).joined(separator: ";")
            } else {
                envLines.append("DXMT_CONFIG=" + shaders.options.joined(separator: ";"))
            }
        }
        envLines.removeAll { $0.hasPrefix(MaxResolution.variable + "=") }
        if let value = MaxResolution.normalized(maxResolution) { envLines.append("\(MaxResolution.variable)=\(value)") }
        envLines.removeAll { $0.hasPrefix("OVERPASS_X87=") }
        if fasterX87 { envLines.append("OVERPASS_X87=1") }
        settings += envLines.map { "env = \($0)" }
        var overrides = dlls.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if xaudio == .microsoft { overrides += XAudioChoice.overrides.filter { !overrides.contains($0) } }
        settings += overrides.map { "dll = \($0)" }

        // Keep every program the section already covered (a game can have a Steam and a GOG copy), and add this one.
        var covers = ProfileText(text: text).values(in: UserProfiles.settingsSection)
            .filter { $0.key == "program" || $0.key == "steam-app" }.map { "\($0.key) = \($0.value)" }
        if let identity, !covers.contains(identity) { covers.append(identity) }
        profileText.replace(section: UserProfiles.settingsSection, comment: "Set in OverPass's profile editor.",
                            with: settings.isEmpty ? [] : covers + settings)
        return profileText.text
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let fm = FileManager.default
            let built = builtText()
            if let pickedIcon = art.pickedIcon {
                try fm.createDirectory(at: UserProfiles.iconsDirectory, withIntermediateDirectories: true)
                let dest = UserProfiles.iconsDirectory.appendingPathComponent("\(profileID).\(pickedIcon.pathExtension.lowercased())")
                if pickedIcon.standardizedFileURL != dest.standardizedFileURL {
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: pickedIcon, to: dest)
                }
            } else if art.removeIcon, let icon = profile?.icon {
                try? fm.removeItem(at: UserProfiles.iconsDirectory.appendingPathComponent(icon))
            }
            if let pickedCover = art.pickedCover {
                try fm.createDirectory(at: UserProfiles.coversDirectory, withIntermediateDirectories: true)
                let dest = UserProfiles.coversDirectory.appendingPathComponent(coverFileName(for: pickedCover))
                if pickedCover.standardizedFileURL != dest.standardizedFileURL {
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: pickedCover, to: dest)
                }
            }
            if art.pickedCover != nil || art.removeCover, let old = profile?.cover, old != ArtStyle.generatedCover,
               art.pickedCover.map({ coverFileName(for: $0) }) != old {
                try? fm.removeItem(at: UserProfiles.coversDirectory.appendingPathComponent(old))
            }
            // Nothing to keep for an app that had no profile and still has no settings.
            if profile == nil && built == newProfileText() { return true }
            if built != text || profile == nil || art.pickedIcon != nil || art.removeIcon || art.pickedCover != nil || art.removeCover {
                try profiles.save(id: profileID, text: built)
                // The Mac app wrappers pick up the new name and artwork.
                manager.loadBottles()
            }
            load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Named after the picture's contents, so the library sees a new file (and reloads it) when the cover changes.
    private func coverFileName(for url: URL) -> String {
        let hash = (try? Data(contentsOf: url)).map { WindowsIcons.stableHash($0.base64EncodedString()) } ?? UUID().uuidString
        return "\(profileID)-\(hash.prefix(8)).\(url.pathExtension.lowercased())"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profileID).ini"
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .plainText]
        panel.message = "Share this file so others can import it into OverPass."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = builtText().components(separatedBy: "\n").drop { $0.hasPrefix(UserProfiles.basedOnPrefix) }.joined(separator: "\n")
        do { try body.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}

/// The whole profile file as text, for rules the form doesn't show.
struct ProfileFileEditor: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State var text: String
    let saved: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(id).ini").font(.headline)
            Text("The format is described in Profiles/README.md in the OverPass sources.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .border(.separator)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard GameProfile.parseINI(id: id, text: text) != nil else {
                        error = "A profile needs an [app] section with at least a name."
                        return
                    }
                    do {
                        try profiles.save(id: id, text: text)
                        saved()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 520)
    }
}

/// Settings every app in a bottle shares; they apply right away. As the Containers page (`page`), it also shows
/// what's in the container, what runs in it, and Uninstall.
struct BottleSettings: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ComponentManager.self) private var components
    @Environment(\.openItemSheet) private var openItemSheet
    let bottle: Bottle
    var page = false
    @State private var size: Int64?
    @State private var running: [String] = []
    @State private var busy: String?
    @State private var log = ""
    @State private var verb = ""
    @State private var environment = ""
    @State private var playStation = false
    @State private var macKeys = BottleSetup.MacKeys.standard
    @State private var retina = false
    @State private var appearance = BottleSetup.Appearance.mac
    @State private var detailedLog = false
    @State private var showMacDisk = true
    @State private var moveTarget: URL?
    @State private var exportURL: URL?

    var body: some View {
        Form {
            if page { overview }
            Section {
                if !page {
                    Text("Shared by everything in “\(bottle.name)”: \(bottle.apps.map(\.name).joined(separator: ", ").nilIfEmpty ?? "nothing installed yet").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("Windows version", selection: windowsBinding) {
                    ForEach(WineTemplate.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(busy != nil)
                Picker("Direct3D 10–12", selection: graphicsBinding) {
                    ForEach(GraphicsBackend.allCases) { Text($0.displayName).tag($0) }
                }
                if bottle.graphics == .dxvk && !(GraphicsBackend.dxvk.dllDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                    Label("DXVK comes with OverPass Wine 11.0-8 or later. Until then Direct3D 10–11 uses WineD3D.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if let needed = bottle.graphics.component, !components.isInstalled(needed) {
                    Label("\(needed.name) isn't installed. Open Components to install it.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Picker("Direct3D 9", selection: direct3D9Binding) {
                    ForEach(Direct3D9Backend.allCases) { Text($0.displayName).tag($0) }
                }
                if bottle.direct3D9 != .wined3d && !Direct3D9Backend.isInstalled {
                    Label("mtld3d comes with OverPass Runtime 0.3.0 or later. Until then Direct3D 9 uses WineD3D.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } header: {
                if page { Text("Windows and Graphics") }
            }
            Section {
                Picker("PlayStation controllers", selection: playStationBinding) {
                    Text("As Xbox controllers").tag(false)
                    Text("As PlayStation controllers").tag(true)
                }
                .disabled(busy != nil)
            } footer: {
                Text("DualShock 4 and DualSense. Most PC games only read Xbox controllers; Sony's own PC ports "
                     + "read PlayStation controllers for haptics and adaptive triggers. Takes effect the next time "
                     + "the container starts.")
            }
            Section {
                Picker("Keyboard", selection: macKeysBinding) {
                    ForEach(BottleSetup.MacKeys.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(busy != nil)
                Toggle("High resolution (Retina)", isOn: retinaBinding)
                    .disabled(busy != nil)
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(BottleSetup.Appearance.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(busy != nil)
                Toggle("Show the Mac's disk as Z:", isOn: Binding(get: { showMacDisk }, set: { new in
                    run("drives") {
                        try await ContainerDrives.setShowsMacDisk(new, in: bottle, using: manager)
                        showMacDisk = new
                    }
                }))
                .disabled(busy != nil)
            } header: {
                Text("Mac")
            } footer: {
                Text("High resolution draws programs at the display's full pixel count, sharper but slower in games; "
                     + "text keeps its size. Appearance is the light or dark look launchers and newer Windows apps "
                     + "use. Your home folder is always Y:; Z: is the whole Mac, hidden from Explorer and file "
                     + "dialogs unless shown here. These take effect the next time a program starts.")
            }
            Section("Runtimes") {
                let installed = Runtime.installed(in: bottle)
                ForEach(Runtime.allCases) { runtime in
                    HStack {
                        Text(runtime.name)
                        Spacer()
                        if busy == runtime.rawValue {
                            ProgressView().controlSize(.small)
                        } else if installed.contains(runtime) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Installed")
                        } else {
                            Button("Install") { run(runtime.rawValue) { try await runtime.install(in: bottle, using: manager) { log += $0 } } }
                                .disabled(busy != nil)
                        }
                    }
                }
                HStack {
                    TextField("Other (winetricks)", text: $verb, prompt: Text("winetricks verb, e.g. xact"))
                    Button("Install") { winetricks(verb) }
                        .disabled(busy != nil || verb.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !log.isEmpty {
                    ScrollView {
                        Text(log).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 90)
                }
            }
            Section {
                TextEditor(text: $environment)
                    .font(.body.monospaced())
                    .frame(height: 60)
                HStack {
                    Spacer()
                    Button("Apply") { applyEnvironment() }
                        .disabled(environment == environmentText)
                }
            } header: {
                Text("Environment Variables")
            } footer: {
                Text("One NAME=value per line, for every app in the container.")
            }
            if ContainerLocations.all.count > 1 {
                Section {
                    HStack {
                        LabeledContent("Location", value: ContainerLocations.displayName(of: ContainerLocations.location(of: bottle)))
                        Menu("Move To") {
                            ForEach(ContainerLocations.all.filter { $0.standardizedFileURL != ContainerLocations.location(of: bottle).standardizedFileURL }, id: \.self) { url in
                                Button("\(ContainerLocations.displayName(of: url)) (\(ContainerLocations.freeSpaceText(at: url)))") { moveTarget = url }
                            }
                        }
                        .fixedSize()
                        .disabled(busy != nil)
                        if busy == "move" { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Moving takes the whole container, games and saves included. Programs running in it are "
                         + "closed first; to another disk it's a copy, which can take a while for big games.")
                }
                .confirmationDialog("Move “\(bottle.name)” to \(moveTarget.map(ContainerLocations.displayName(of:)) ?? "")?",
                                    isPresented: Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } })) {
                    Button("Move") {
                        guard let target = moveTarget else { return }
                        run("move") { try await manager.moveBottle(bottle, to: target) }
                    }
                } message: {
                    Text("Programs running in it will be closed.")
                }
            }
            Section {
                HStack {
                    Button("Export…") { export() }
                        .disabled(busy != nil)
                    if busy == "export", let exportURL {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let written = (try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int64) ?? 0
                            Text("\(FolderSize.text(written)) written").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Saves the whole container, games and saves included, as one compressed file: a backup, or a way "
                     + "to bring it to another Mac, where Import Container… in the File menu adds it. Programs "
                     + "running in it are closed first.")
            }
            Section {
                Toggle("Detailed log", isOn: Binding(get: { detailedLog }, set: { new in
                    do { try LogCollector.setDetailedLog(new, in: bottle); detailedLog = new }
                    catch { log += "Error: \(error.localizedDescription)\n" }
                }))
                Button("Show Logs in Finder") {
                    let folder = LogCollector.logFolder(for: bottle)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
            } header: {
                Text("Logs")
            } footer: {
                Text("Every program's last run is kept in a log. Normally it holds errors only; the detailed log also "
                     + "records which DLLs load and any crashes, which slows programs a little. For the next start.")
            }
            Section {
                HStack {
                    ForEach([("Wine Settings", "winecfg"), ("Registry Editor", "regedit"), ("Task Manager", "taskmgr")], id: \.1) { title, program in
                        Button(title) { Task { _ = try? await manager.run([program], in: bottle) } }
                    }
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(bottle.driveC) }
                    Spacer()
                    Button("Quit Everything in Container") { Task { await manager.quitEverything(in: bottle) } }
                        .help("End every Windows program running in this container")
                }
            }
            if page {
                Section {
                    Button("Uninstall Container…", role: .destructive) { openItemSheet(.uninstallBottle(bottle)) }
                }
            }
        }
        .formStyle(.grouped)
        .modifier(PageExtras(bottle: bottle, enabled: page, size: $size, running: $running))
        .onAppear {
            environment = environmentText
            playStation = BottleSetup.playStationControllers(in: bottle) ?? false
            macKeys = BottleSetup.macKeys(in: bottle)
            retina = BottleSetup.retinaMode(in: bottle)
            appearance = BottleSetup.appearance(of: bottle)
            detailedLog = LogCollector.detailedLog(in: bottle)
            showMacDisk = ContainerDrives.showsMacDisk(in: bottle) ?? true
        }
    }

    /// The page's first sections: facts about the container and the programs in it.
    @ViewBuilder private var overview: some View {
        Section {
            if let group = bottle.group { LabeledContent("Group", value: group) }
            LabeledContent("Titles", value: "\(manager.library.filter { $0.bottle.path == bottle.path }.count)")
            LabeledContent("Size on Disk", value: size.map(FolderSize.text) ?? "Counting…")
            if let created = (try? bottle.path.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Running", value: running.isEmpty ? "Nothing" : running.joined(separator: ", "))
            LabeledContent("Folder") {
                Button(bottle.path.path) { NSWorkspace.shared.open(bottle.driveC) }
                    .buttonStyle(.link)
            }
        }
        Section("Apps") {
            if bottle.apps.isEmpty {
                Text("No shortcuts or launcher games found in this container.").foregroundStyle(.secondary)
            }
            ForEach(bottle.apps) { app in
                HStack {
                    Text(app.name)
                    if let launcher = app.launcher {
                        Text(launcher).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    OpenButton(opening: manager.isOpening(in: bottle, program: app.executable), label: app.runLabel) {
                        try? manager.launchApp(app, in: bottle)
                    }
                }
            }
        }
    }

    private var environmentText: String {
        bottle.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private var windowsBinding: Binding<WineTemplate> {
        Binding(get: { bottle.template }, set: { new in
            run("windows") {
                // winecfg names versions without the architecture: "win10".
                let version = new.rawValue.components(separatedBy: "_").first ?? new.rawValue
                _ = try await manager.run(["winecfg", "-v", version], in: bottle) { log += $0 }
                var config = BottleConfig.parse(bottle.configURL)
                config["Container", default: [:]]["Template"] = new.rawValue
                try BottleConfig.write(config, to: bottle.configURL)
                manager.loadBottles()
            }
        })
    }

    private var playStationBinding: Binding<Bool> {
        Binding(get: { playStation }, set: { new in
            run("controllers") {
                try await BottleSetup.setPlayStationControllers(new, in: bottle, using: manager)
                playStation = new
            }
        })
    }

    private var macKeysBinding: Binding<BottleSetup.MacKeys> {
        Binding(get: { macKeys }, set: { new in
            run("keys") {
                try await BottleSetup.setMacKeys(new, in: bottle, using: manager)
                macKeys = new
            }
        })
    }

    private var retinaBinding: Binding<Bool> {
        Binding(get: { retina }, set: { new in
            run("retina") {
                try await BottleSetup.setRetinaMode(new, in: bottle, using: manager)
                retina = new
            }
        })
    }

    private var appearanceBinding: Binding<BottleSetup.Appearance> {
        Binding(get: { appearance }, set: { new in
            run("appearance") {
                try await BottleSetup.setAppearance(new, of: bottle, using: manager)
                appearance = new
            }
        })
    }

    private var graphicsBinding: Binding<GraphicsBackend> {
        Binding(get: { bottle.graphics }, set: { new in
            var config = BottleConfig.parse(bottle.configURL)
            config["OverPass", default: [:]]["Graphics"] = new.rawValue
            try? BottleConfig.write(config, to: bottle.configURL)
            manager.loadBottles()
        })
    }

    private var direct3D9Binding: Binding<Direct3D9Backend> {
        Binding(get: { bottle.direct3D9 }, set: { new in
            var config = BottleConfig.parse(bottle.configURL)
            config["OverPass", default: [:]]["Direct3D9"] = new.rawValue
            try? BottleConfig.write(config, to: bottle.configURL)
            manager.loadBottles()
        })
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(bottle.name).tar.gz"
        panel.message = "Programs running in “\(bottle.name)” will be closed while it's exported."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportURL = url
        run("export") {
            try await manager.exportBottle(bottle, to: url)
            log += "Exported to \(url.path)\n"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func applyEnvironment() {
        var values: [String: String] = [:]
        for line in environment.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        var config = BottleConfig.parse(bottle.configURL)
        config["Environment"] = values
        try? BottleConfig.write(config, to: bottle.configURL)
        manager.loadBottles()
    }

    private func winetricks(_ verb: String) {
        let verb = verb.trimmingCharacters(in: .whitespaces)
        run(verb) {
            if !components.isInstalled(.winetricks) { await components.install(.winetricks) }
            log += "$ winetricks -q \(verb)\n"
            let status = try await manager.runTool(ComponentManager.winetricksPath, ["-q", verb], in: bottle) { log += $0 }
            log += "exit \(status)\n"
        }
    }

    private func run(_ name: String, _ work: @escaping @MainActor () async throws -> Void) {
        busy = name
        Task {
            do { try await work() } catch { log += "Error: \(error.localizedDescription)\n" }
            busy = nil
            manager.loadBottles()
        }
    }
}

/// What only the Containers page does: its status text and Uninstall command, and keeping the size and the
/// running programs current.
private struct PageExtras: ViewModifier {
    @Environment(BottleManager.self) private var manager
    @Environment(\.openItemSheet) private var openItemSheet
    let bottle: Bottle
    let enabled: Bool
    @Binding var size: Int64?
    @Binding var running: [String]

    func body(content: Content) -> some View {
        if enabled {
            content
                .statusText(bottle.name)
                .task(id: bottle.path) {
                    let path = bottle.path
                    size = await Task.detached(priority: .utility) { FolderSize.of(path) }.value
                }
                .task(id: bottle.path) {
                    while !Task.isCancelled {
                        running = Array(Set(manager.runningPrograms(in: bottle).map(\.displayName))).sorted()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
                .focusedSceneValue(\.uninstallSelection, UninstallSelection(name: bottle.name) {
                    openItemSheet(.uninstallBottle(bottle))
                })
        } else {
            content
        }
    }
}

// MARK: - Opening the editor from anywhere an app is shown

enum ItemSheet: Identifiable {
    case editProfile(LibraryItem)
    case reportIssue(LibraryItem)
    case uninstall(LibraryItem)
    case uninstallBottle(Bottle)

    var id: String {
        switch self {
        case .editProfile(let item): "edit|" + item.id
        case .reportIssue(let item): "report|" + item.id
        case .uninstall(let item): "uninstall|" + item.id
        case .uninstallBottle(let bottle): "uninstall-bottle|" + bottle.path.path
        }
    }
}

private struct OpenItemSheetKey: EnvironmentKey {
    static let defaultValue: (ItemSheet) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Shows the profile editor or Report Issue for an app; set by the page that presents them.
    var openItemSheet: (ItemSheet) -> Void {
        get { self[OpenItemSheetKey.self] }
        set { self[OpenItemSheetKey.self] = newValue }
    }
}

extension View {
    /// Presents the profile editor and Report Issue for the apps in this view.
    func itemSheets(_ sheet: Binding<ItemSheet?>) -> some View {
        modifier(ItemSheets(sheet: sheet))
    }
}

private struct ItemSheets: ViewModifier {
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.openWindow) private var openWindow
    @Binding var sheet: ItemSheet?

    func body(content: Content) -> some View {
        content
            .environment(\.openItemSheet) { sheet = $0 }
            // The profile editor has a window of its own, one per title.
            .onChange(of: sheet?.id) {
                switch sheet {
                case .editProfile(let item)?:
                    sheet = nil
                    ProfileWindow.items[item.id] = item
                    openWindow(id: ProfileWindow.id, value: item.id)
                case .reportIssue(let item)?:
                    // The report window is a panel of its own (ReportCenter.swift).
                    sheet = nil
                    ReportCenter.shared.show(ReportContext(item: item, mode: .title))
                default:
                    break
                }
            }
            .sheet(item: Binding(get: {
                switch sheet { case .editProfile?, .reportIssue?: nil; default: sheet }
            }, set: { sheet = $0 })) { sheet in
                switch sheet {
                case .editProfile, .reportIssue:
                    EmptyView()
                case .uninstall(let item):
                    UninstallSheet(item: item)
                case .uninstallBottle(let bottle):
                    BottleUninstallSheet(bottle: bottle)
                }
            }
    }
}

/// The profile editor's window: one per title, laid out like Settings (title, icon tabs, Simple switch).
struct ProfileWindow: View {
    static let id = "profile"
    /// Titles asked for, so one that isn't in the library (a Home recipe) still opens.
    @MainActor static var items: [String: LibraryItem] = [:]
    /// Containers moved to another location while their window was open, old path to new; an item's ID starts with it.
    @MainActor static var movedContainers: [String: String] = [:]
    @Environment(BottleManager.self) private var manager
    let itemID: String?

    private var currentID: String? {
        guard let itemID else { return nil }
        return Self.movedContainers.reduce(itemID) { id, move in
            id.replacingOccurrences(of: move.key + "|", with: move.value + "|")
                .replacingOccurrences(of: move.key + "/", with: move.value + "/")
        }
    }

    var body: some View {
        if let itemID, let item = manager.library.first(where: { $0.id == currentID }) ?? Self.items[itemID] {
            ProfileEditor(item: item)
        } else {
            Text("This title isn't in the library any more.")
                .foregroundStyle(.secondary)
                .frame(width: 400, height: 160)
        }
    }
}
