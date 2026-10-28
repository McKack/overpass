import SwiftUI

/// The artwork changes made in the profile editor, kept until it saves.
struct ArtworkDraft: Equatable {
    var pickedIcon: URL?
    var removeIcon = false
    var pickedCover: URL?
    var removeCover = false
    var generatedCover = false
    var coverStyle = ArtStyle.cover
    var iconStyle = ArtStyle.icon

    /// The icon file the title shows with these changes: a picked one, the profile's, or the program's own.
    func iconFile(profileIcon: String?, item: LibraryItem) async -> URL? {
        if let pickedIcon { return pickedIcon }
        if !removeIcon, let profileIcon { return UserProfiles.iconsDirectory.appendingPathComponent(profileIcon) }
        // The app as found in the bottle, before a picked icon replaced its own (a Steam game's is its program's
        // icon, not steam.exe's).
        let (app, bottle) = (item.bottle.apps.first { $0.id == item.app.id } ?? item.app, item.bottle)
        return await Task.detached(priority: .utility) { WindowsIcons.icoFile(for: app, in: bottle) }.value
    }

    /// The cover picture with these changes; nil when the cover is generated.
    func coverPicture(profileCover: String?, storeCover: NSImage?) -> NSImage? {
        if let pickedCover { return NSImage(contentsOf: pickedCover) }
        if generatedCover { return nil }
        if !removeCover, let profileCover, profileCover != ArtStyle.generatedCover,
           let image = NSImage(contentsOf: UserProfiles.coversDirectory.appendingPathComponent(profileCover)) {
            return image
        }
        return storeCover
    }
}

/// A generated cover: the icon on its backdrop, as the Covers layout draws it.
struct GeneratedCover: View {
    let icon: NSImage?
    let background: NSImage?
    let style: ArtStyle
    let width: CGFloat

    var body: some View {
        ZStack {
            if let background {
                Image(nsImage: background).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: width * CGFloat(style.scale) / 100, height: width * CGFloat(style.scale) / 100)
                    .shadow(color: .black.opacity(0.35), radius: width / 30, y: width / 50)
                    .offset(x: width * CGFloat(style.x) / 100, y: width * 1.5 * CGFloat(style.y) / 100)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipped()
    }
}

/// Cover and icon side by side: the pictures, and how the generated cover and the Mac app's icon are drawn.
struct ArtworkEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    let name: String
    let profileIcon: String?
    let profileCover: String?
    let clientColor: String?
    @Binding var draft: ArtworkDraft

    @State private var icon: NSImage?
    @State private var storeCover: NSImage?
    @State private var coverBackground: NSImage?
    @State private var iconPlate: CGImage?
    @State private var iconIsPicture = false
    /// The offset a drag started from, while one is under way.
    @State private var dragStart: (x: Int, y: Int)?
    @State private var artSearch: ArtKind?
    @State private var enteringCoverURL = false
    @State private var coverURL = ""
    @State private var choosingIcon = false
    @State private var iconChoices: [(path: String, image: NSImage)] = []
    @State private var error: String?

    private static let previewWidth: CGFloat = 150
    private var coverPicture: NSImage? { draft.coverPicture(profileCover: profileCover, storeCover: storeCover) }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                column("Cover", caption: coverCaption) {
                    coverPreview
                } picture: {
                    Menu("Change Picture") { coverMenuItems }
                } style: {
                    ArtStyleControls(style: $draft.coverStyle, clientColor: clientColor, picture: coverPicture != nil)
                }
                Divider()
                column("Icon", caption: "In the Dock and Launchpad") {
                    iconPreview
                } picture: {
                    Menu("Change Picture") { iconMenuItems }
                        .popover(isPresented: $choosingIcon, arrowEdge: .bottom) { iconChooser }
                } style: {
                    ArtStyleControls(style: $draft.iconStyle, clientColor: clientColor, picture: iconIsPicture)
                }
            }
            HStack {
                Text("Drag the pictures to move them. Changes are kept when you save the profile.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            var app = item.app
            app.cover = nil
            app.generatedCover = false
            storeCover = await CoverArt.image(for: LibraryItem(app: app, bottle: item.bottle))
        }
        .task(id: "\(draft.pickedIcon?.path ?? "")\(draft.removeIcon)\(draft.coverStyle.base)\(draft.coverStyle.frost)\(draft.iconStyle.base)\(draft.iconStyle.frost)") {
            await render()
        }
        .sheet(item: $artSearch) { kind in
            ArtSearchSheet(kind: kind, pick: { file in
                switch kind {
                case .cover: draft.pickedCover = file; draft.removeCover = false; draft.generatedCover = false
                case .icon: draft.pickedIcon = file; draft.removeIcon = false
                }
            }, query: name)
        }
        .alert("Cover from a Web Address", isPresented: $enteringCoverURL) {
            TextField("https://", text: $coverURL)
            Button("Cancel", role: .cancel) {}
            Button("Download", action: downloadCover)
        } message: {
            Text("The address of a picture, e.g. from the store page or SteamGridDB.")
        }
        .alert("Couldn't Get the Picture", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func column(_ title: String, caption: String, @ViewBuilder preview: () -> some View,
                        @ViewBuilder picture: () -> some View, @ViewBuilder style: () -> some View) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            preview().frame(height: Self.previewWidth * 1.5)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            picture().fixedSize()
            style()
        }
        .frame(maxWidth: .infinity)
    }

    private var coverCaption: String {
        if draft.pickedCover != nil { return "Your picture" }
        if coverPicture == nil { return "Generated" }
        if draft.removeCover || profileCover == nil || profileCover == ArtStyle.generatedCover { return "From the store" }
        return "Your picture"
    }

    private var coverPreview: some View {
        Group {
            if let coverPicture {
                StyledPicture(picture: coverPicture, style: draft.coverStyle.withClient(clientColor), width: Self.previewWidth)
            } else {
                GeneratedCover(icon: icon, background: coverBackground, style: draft.coverStyle, width: Self.previewWidth)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .contentShape(Rectangle())
        .gesture(moving($draft.coverStyle, frame: CGSize(width: Self.previewWidth, height: Self.previewWidth * 1.5)))
    }

    /// The Dock icon as the wrapper will have it; the plate is drawn once, so dragging only redraws the icon.
    private var dockIcon: NSImage? {
        guard let icon, let iconPlate,
              let drawn = DockIcon.render(icon, style: draft.iconStyle.withClient(clientColor), size: 512, plate: iconPlate) else { return nil }
        return NSImage(cgImage: drawn, size: NSSize(width: 512, height: 512))
    }

    /// Dragging moves the icon or picture; `frame` is the area its offsets are a percentage of.
    private func moving(_ style: Binding<ArtStyle>, frame: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                let start = dragStart ?? (style.wrappedValue.x, style.wrappedValue.y)
                dragStart = start
                style.wrappedValue.x = (start.x + Int((drag.translation.width / frame.width * 100).rounded())).clamped(to: ArtStyle.offsetRange)
                style.wrappedValue.y = (start.y + Int((drag.translation.height / frame.height * 100).rounded())).clamped(to: ArtStyle.offsetRange)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var iconPreview: some View {
        Group {
            if let dockIcon {
                Image(nsImage: dockIcon).resizable().interpolation(.high)
            } else {
                ProgressView()
            }
        }
        .frame(width: Self.previewWidth, height: Self.previewWidth)
        .contentShape(Rectangle())
        .gesture(moving($draft.iconStyle, frame: CGSize(width: Self.previewWidth * 824 / 1024, height: Self.previewWidth * 824 / 1024)))
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var coverMenuItems: some View {
        Button("Search Online…") { artSearch = .cover }
        Button("From Web Address…") { coverURL = ""; enteringCoverURL = true }
        Button("Choose File…", action: chooseCover)
        Divider()
        if draft.pickedCover != nil || draft.generatedCover || (profileCover != nil && !draft.removeCover) {
            Button("Use Store Cover") { draft.pickedCover = nil; draft.removeCover = true; draft.generatedCover = false }
        }
        if coverPicture != nil {
            Button("Use Generated Cover") { draft.pickedCover = nil; draft.removeCover = true; draft.generatedCover = true }
        }
        Divider()
        Button("Reset to Default") {
            draft.pickedCover = nil
            draft.removeCover = profileCover != nil
            draft.generatedCover = false
            draft.coverStyle = .cover
        }
        .disabled(draft.pickedCover == nil && !draft.generatedCover && (profileCover == nil || draft.removeCover)
                  && draft.coverStyle == .cover)
    }

    @ViewBuilder private var iconMenuItems: some View {
        Button("Program's Icons…") { choosingIcon = true }
        Button("Search Online…") { artSearch = .icon }
        Button("Choose File…", action: chooseIcon)
        if draft.pickedIcon != nil || (profileIcon != nil && !draft.removeIcon) {
            Divider()
            Button("Use Program's Icon") { draft.pickedIcon = nil; draft.removeIcon = true }
        }
        Divider()
        Button("Reset to Default") {
            draft.pickedIcon = nil
            draft.removeIcon = profileIcon != nil
            draft.iconStyle = .icon
        }
        .disabled(draft.pickedIcon == nil && (profileIcon == nil || draft.removeIcon) && draft.iconStyle == .icon)
    }

    /// The backdrops for the current icon and styles, drawn off the main thread.
    private func render() async {
        let file = await draft.iconFile(profileIcon: profileIcon, item: item)
        let (coverStyle, iconStyle) = (draft.coverStyle.withClient(clientColor), draft.iconStyle.withClient(clientColor))
        let size = CGSize(width: 200, height: 300)
        let drawn = await Task.detached(priority: .userInitiated) { () -> (NSImage, NSImage?, CGImage?, Bool)? in
            guard let icon = file.flatMap(NSImage.init(contentsOf:)) else { return nil }
            let background = coverStyle.background(for: icon, size: size).map { NSImage(cgImage: $0, size: size) }
            let isPicture = icon.cgImage(forProposedRect: nil, context: nil, hints: nil).map(ArtStyle.isPicture) ?? false
            return (icon, background, DockIcon.plate(for: icon, style: iconStyle, size: 512), isPicture)
        }.value
        guard !Task.isCancelled else { return }
        icon = drawn?.0
        coverBackground = drawn?.1
        iconPlate = drawn?.2
        iconIsPicture = drawn?.3 ?? false
    }

    /// The icons found in the app's program, shortcut and install folder, to pick from.
    private var iconChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icons found for \(item.app.name)").font(.headline)
            if iconChoices.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 8), count: 6), spacing: 8) {
                ForEach(iconChoices, id: \.path) { choice in
                    Button {
                        pick(choice.path)
                        choosingIcon = false
                    } label: {
                        Image(nsImage: choice.image).resizable().interpolation(.high).frame(width: 48, height: 48)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .help((choice.path as NSString).lastPathComponent)
                }
            }
            Divider()
            Button("Other Image File…") { choosingIcon = false; chooseIcon() }
        }
        .padding()
        .frame(width: 400)
        .task {
            let (app, bottle) = (item.app, item.bottle)
            let found = await Task.detached(priority: .userInitiated) {
                WindowsIcons.candidates(for: app, in: bottle).compactMap { path -> (String, Data)? in
                    let ext = (path as NSString).pathExtension.lowercased()
                    if ["png", "jpg", "jpeg"].contains(ext) { return (try? Data(contentsOf: URL(fileURLWithPath: path))).map { (path, $0) } }
                    return WindowsIcons.extract(path, bottlePath: bottle.path).map { (path, $0) }
                }
            }.value
            // The same picture often comes from several files; show it once.
            var seen = Set<Data>()
            iconChoices = found.filter { seen.insert($0.1).inserted }.compactMap { path, data in
                NSImage(data: data).map { (path, $0) }
            }
        }
    }

    /// Uses a found icon: Windows icons are saved as .ico, launcher pictures as they are.
    private func pick(_ path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        let data = ["png", "jpg", "jpeg"].contains(ext)
            ? try? Data(contentsOf: URL(fileURLWithPath: path))
            : WindowsIcons.extract(path, bottlePath: item.bottle.path)
        guard let data else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(["png", "jpg", "jpeg"].contains(ext) ? ext : "ico")")
        if (try? data.write(to: file)) != nil {
            draft.pickedIcon = file
            draft.removeIcon = false
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .icns, .ico]
        if panel.runModal() == .OK, let url = panel.url {
            draft.pickedIcon = url
            draft.removeIcon = false
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            draft.pickedCover = url
            draft.removeCover = false
            draft.generatedCover = false
        }
    }

    /// Downloads a picture into a temporary file; it's copied to the profile's covers on Save.
    private func downloadCover() {
        guard let url = URL(string: coverURL.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            error = "That isn't a web address."
            return
        }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                error = "Couldn't download a picture from \(url.host() ?? coverURL)."
                return
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            if (try? jpeg.write(to: file)) != nil {
                draft.pickedCover = file
                draft.removeCover = false
                draft.generatedCover = false
            }
        }
    }
}

/// Size and Frosted sliders over one row of base colours: the presets, then a custom colour. For a picture the size
/// is the picture's, where 50% fills the frame.
struct ArtStyleControls: View {
    @Binding var style: ArtStyle
    let clientColor: String?
    var picture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if picture {
                slider("Size", value: $style.picture, in: ArtStyle.pictureRange)
                    .help("50% fills the frame")
            } else {
                slider("Icon size", value: $style.scale, in: ArtStyle.scaleRange)
            }
            slider("Frosted", value: $style.frost, in: ArtStyle.frostRange)
            HStack(spacing: 10) {
                swatch(.contrast, help: "Light or dark, whichever the icon stands out from") {
                    Circle().fill(LinearGradient(stops: [.init(color: Color(hex: ArtStyle.lightColor)!, location: 0.5),
                                                         .init(color: Color(hex: ArtStyle.darkColor)!, location: 0.5)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                swatch(.light, help: "Light") { Circle().fill(Color(hex: ArtStyle.lightColor)!.gradient) }
                swatch(.dark, help: "Dark") { Circle().fill(Color(hex: ArtStyle.darkColor)!.gradient) }
                if let clientColor, let color = Color(hex: clientColor) {
                    swatch(.client(nil), help: "The game client's color") { Circle().fill(color.gradient) }
                }
                ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .overlay { if isCustom { Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-4).allowsHitTesting(false) } }
                    .help("A color of your own, toned down like the frosted layer")
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 260)
    }

    private var isCustom: Bool { if case .custom = style.base { true } else { false } }

    private var customColor: Binding<Color> {
        Binding(get: {
            if case .custom(let hex) = style.base, let color = Color(hex: hex) { return color }
            return .gray
        }, set: { color in
            if let hex = ArtStyle.hex(NSColor(color)) { style.base = .custom(hex) }
        })
    }

    private func slider(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(value.wrappedValue)%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .font(.callout)
    }

    private func swatch(_ base: ArtStyle.Base, help: String, @ViewBuilder content: () -> some View) -> some View {
        let selected = base == style.base || (base == .client(nil) && { if case .client = style.base { true } else { false } }())
        return Button { style.base = base } label: {
            content()
                .frame(width: 24, height: 24)
                .overlay { Circle().strokeBorder(.primary.opacity(0.2)) }
                .padding(3)
                .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0) }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
