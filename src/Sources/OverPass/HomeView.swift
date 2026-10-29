import SwiftUI

/// Everything you can start from: pick an installer, or install a game store / launcher in one click.
struct HomeView: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Binding var installRequest: InstallRequest?
    @State private var launchError: String?
    /// The selected card's profile; its actions show in the toolbar.
    @State private var selection: String?
    @State private var itemSheet: ItemSheet?
    @Environment(\.searchText) private var searchText
    @Environment(\.storeActions) private var storeActions
    /// Redraws the tiles when the Xbox Library is turned on or off.
    @AppStorage(XboxOptIn.key) private var xboxEnabled = false
    @AppStorage(ViewOptions.otherAppsKey) private var otherApps = false
    @State private var enablingXbox = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        BrandLogo().frame(width: 52, height: 52)
                        Text("OverPass").font(.system(size: 40, weight: .bold, design: .rounded))
                    }
                    .padding(.bottom, 8)
                    Button {
                        installRequest = InstallRequest()
                    } label: {
                        Label(manager.library.isEmpty ? "Install Your First Game…" : "Install a Game…", systemImage: "plus")
                            .font(.title3.bold())
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    Text("Choose a game's Windows installer, or start with a gaming service below. Other Windows apps work too.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                ForEach(sections, id: \.title) { section in
                    VStack(spacing: 12) {
                        // With only Gaming Services on Home, the section needs no title.
                        if otherApps { Text(section.title).font(.title2.bold()) }
                        CenteredGrid(minimumWidth: 260, spacing: 14) {
                            ForEach(section.profiles) { profile in tile(profile) }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            // Clicking outside the cards clears the selection.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
        }
        .bottomFade()
        .focusable()
        .focusEffectDisabled()
        .statusText(searchText.trimmingCharacters(in: .whitespaces).isEmpty ? "Home"
                    : "Home · \(sections.reduce(0) { $0 + $1.profiles.count }) found")
        .toolbar {
            // The selection's actions sit in the middle and stay there, greyed out while nothing is selected;
            // the window's own buttons stay on the right.
            ToolbarItemGroup(placement: .principal) {
                let profile = selectedProfile
                let installed = profile.map { bottle(for: $0) != nil } ?? false
                if let profile, !isSetUp(profile) {
                    Button { install(profile) } label: { Label("Install \(profile.name)", systemImage: "arrow.down.circle") }
                        .help(profile.comingSoon ? "Coming soon" : "Install \(profile.name)")
                        .disabled(profile.comingSoon)
                } else {
                    Button { if let profile { open(profile) } } label: {
                        Label(profile.map { "Run \($0.name)" } ?? "Run", systemImage: "play.fill")
                    }
                    .help(profile.map { "Run \($0.name)" } ?? "Select an app to run it")
                    .disabled(profile == nil)
                }
                Button { if let item = profile.flatMap(item(for:)) { itemSheet = .editProfile(item) } } label: {
                    Label(profile.map { "Edit \($0.name)'s Profile" } ?? "Edit Profile", systemImage: "slider.horizontal.3")
                }
                .help(installed ? "Change how \(profile!.name) runs" : "Select an installed app to edit its profile")
                .disabled(!installed)
                Button { if let profile { uninstall(profile) } } label: {
                    Label(profile.map { "Uninstall \($0.name)" } ?? "Uninstall", systemImage: "trash")
                }
                .help(installed ? "Uninstall \(profile!.name)…" : "Select an installed app to uninstall it")
                .disabled(!installed)
            }
            ToolbarItemGroup(placement: .principal) {
                WindowActionButtons()
            }
        }
        .focusedSceneValue(\.uninstallSelection, selectedProfile.flatMap { profile in
            bottle(for: profile).map { _ in UninstallSelection(name: profile.name) { uninstall(profile) } }
        })
        .onDeleteCommand {
            if let profile = selectedProfile { uninstall(profile) }
        }
        .alert("Couldn't Run", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") {}
        } message: {
            Text(launchError ?? "")
        }
        .itemSheets($itemSheet)
        .sheet(isPresented: $enablingXbox) { XboxEnableSheet() }
    }

    /// Featured profiles grouped by category, in the order their first member is featured.
    private var sections: [(title: String, profiles: [GameProfile])] {
        var order: [String] = []
        var groups: [String: [GameProfile]] = [:]
        let search = searchText.trimmingCharacters(in: .whitespaces)
        for profile in profiles.featured where search.isEmpty || profile.name.localizedStandardContains(search) {
            let category = profile.category ?? "Other"
            if !otherApps && category != Self.gamingCategory { continue }
            if groups[category] == nil { order.append(category) }
            groups[category, default: []].append(profile)
        }
        // Installed apps come first in their section, in featured order otherwise.
        return order.map { category in
            let members = groups[category]!
            let installed = members.filter(isSetUp)
            return (Self.sectionTitles[category] ?? category, installed + members.filter { !isSetUp($0) })
        }
    }

    private static let gamingCategory = "Game Launcher"
    private static let sectionTitles = [gamingCategory: "Gaming Services"]

    private func bottle(for profile: GameProfile) -> Bottle? { manager.bottle(for: profile) }

    /// Installed, or a built-in library's store that is signed in: either way it has a category to open.
    private func isSetUp(_ profile: GameProfile) -> Bool {
        bottle(for: profile) != nil || BuiltInLibrary.signedIn(profile.bottle.group)
    }

    /// The store's category once signed in; signing in first otherwise.
    private func openLibrary(_ profile: GameProfile) {
        guard let group = profile.bottle.group else { return }
        if BuiltInLibrary.signedIn(group) { storeActions.show(group) } else { storeActions.connect(group) }
    }

    /// The installed app a Home card stands for: its program in the bottle, as the library lists it.
    private func item(for profile: GameProfile) -> LibraryItem? {
        guard let bottle = bottle(for: profile) else { return nil }
        let program = profile.launch.map { ($0.executable.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased() }
        if let item = manager.library.first(where: { $0.bottle.path == bottle.path && $0.app.programName?.lowercased() == program }) {
            return item
        }
        guard let launch = profile.launch else { return nil }
        return LibraryItem(app: WineApp(name: profile.name, executable: manager.hostPath(launch.executable, in: bottle).path,
                                        arguments: launch.arguments, target: launch.executable), bottle: bottle)
    }

    private func tile(_ profile: GameProfile) -> StoreTile {
        let group = profile.bottle.group
        return StoreTile(profile: profile, bottle: bottle(for: profile),
                         signedIn: BuiltInLibrary.signedIn(group),
                         selected: selection == profile.id,
                         select: { selection = profile.id },
                         install: { install(profile) },
                         library: BuiltInLibrary.entry(for: group),
                         openLibrary: { _ in openLibrary(profile) },
                         open: { open(profile) },
                         remove: { uninstall(profile) },
                         sheet: { (kind: (LibraryItem) -> ItemSheet) in
                             if let item = item(for: profile) { itemSheet = kind(item) }
                         })
    }

    private var selectedProfile: GameProfile? { profiles.featured.first { $0.id == selection } }

    private func install(_ profile: GameProfile) {
        guard !profile.comingSoon else { return }
        // Xbox has no client to install: the risks first, then its library.
        if profile.bottle.group == XboxStore.group {
            if xboxEnabled { openLibrary(profile) } else { enablingXbox = true }
            return
        }
        installRequest = InstallRequest(profile: profile)
    }

    /// The app's own uninstall sheet, or the bottle's when the app itself can't be found in it.
    private func uninstall(_ profile: GameProfile) {
        if let item = item(for: profile) { itemSheet = .uninstall(item) }
        else if let bottle = bottle(for: profile) { itemSheet = .uninstallBottle(bottle) }
    }

    // Prefer the profile's known executable; otherwise the first shortcut in the store's bottle.
    private func open(_ profile: GameProfile) {
        guard let bottle = bottle(for: profile) else {
            if BuiltInLibrary.entry(for: profile.bottle.group) != nil { openLibrary(profile) }
            return
        }
        do {
            if let exe = profile.launch?.executable {
                let path = manager.hostPath(exe, in: bottle)
                if FileManager.default.fileExists(atPath: path.path) {
                    try manager.runExe(path.path, in: bottle, arguments: profile.launch?.arguments ?? [], name: profile.name)
                    return
                }
            }
            // A store's bottle without its client in it holds the built-in library's games.
            if BuiltInLibrary.entry(for: profile.bottle.group) != nil {
                openLibrary(profile)
                return
            }
            if let app = bottle.apps.first(where: { $0.launcher == nil }) {
                try manager.launchApp(app, in: bottle)
            } else {
                launchError = "\(profile.name) is set up, but no program was found to open. Try installing it again."
            }
        } catch {
            launchError = error.localizedDescription
        }
    }
}

private struct StoreTile: View {
    @Environment(BottleManager.self) private var manager
    @AppStorage(XboxOptIn.key) private var xboxEnabled = false
    @AppStorage(ViewOptions.legacyClientsKey) private var legacyClients = false
    @State private var enablingXbox = false
    let profile: GameProfile
    let bottle: Bottle?
    /// A built-in library's store, signed in: Play opens its category.
    let signedIn: Bool
    let selected: Bool
    let select: () -> Void
    let install: () -> Void
    /// A store with a built-in library: Install offers it first, the store's own client second.
    let library: BuiltInLibrary.Entry?
    let openLibrary: (BuiltInLibrary.Entry) -> Void
    let open: () -> Void
    let remove: () -> Void
    let sheet: ((LibraryItem) -> ItemSheet) -> Void

    /// Xbox before the user has turned the Xbox Library on: greyed out, with Enable… instead of Install.
    private var optIn: Bool { profile.bottle.group == XboxStore.group && !xboxEnabled }

    var body: some View {
        HStack(spacing: 12) {
            StoreIcon(profile: profile)
                .grayscale(optIn ? 1 : 0)
                .opacity(optIn ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(profile.name).font(.headline).lineLimit(1).truncationMode(.tail)
                    if profile.bottle.group == XboxStore.group { BetaBadge() }
                }
                .help(profile.name)
                if optIn {
                    Text("Opt-in").font(.caption).foregroundStyle(.secondary)
                } else if profile.comingSoon {
                    Text("Coming soon…").font(.caption).foregroundStyle(.secondary)
                } else {
                    RatingLabel(rating: profile.rating)
                }
            }
            Spacer(minLength: 4)
            if optIn {
                Button("Enable…") { enablingXbox = true }
                    .help("Turn on the Xbox Library: shows the risks first")
            } else if manager.busyProfiles.contains(profile.id) {
                TileButton(symbol: "arrow.down", help: "Working…", busy: true, prominent: bottle != nil) {}
            } else if bottle != nil || signedIn {
                TileButton(symbol: "play.fill", help: library.map { "Open \($0.name)" } ?? "Run \(profile.name)",
                           busy: bottle.map { manager.isOpening(in: $0) } ?? false, prominent: true, action: open)
            } else if let library, library.client == nil || !legacyClients {
                // Without the legacy clients (Settings › Advanced), Install goes straight to the built-in library.
                TileButton(symbol: "arrow.down", help: "Install \(profile.name)") { openLibrary(library) }
            } else if let library {
                // A native pop-up menu: a SwiftUI Menu here comes out smaller than the other tile buttons.
                TileButton(symbol: "arrow.down", help: "Install \(profile.name)") { popUpInstallChoices(library) }
            } else {
                TileButton(symbol: "arrow.down", help: profile.comingSoon ? "Coming soon" : "Install \(profile.name)",
                           action: install)
                    .disabled(profile.comingSoon)
            }
        }
        .padding(12)
        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // A click selects; a double click opens an installed app or starts installing one.
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if optIn { enablingXbox = true }
            else if bottle != nil || signedIn { open() } else if let library { openLibrary(library) } else { install() }
        })
        .sheet(isPresented: $enablingXbox) { XboxEnableSheet() }
        .contextMenu {
            if optIn {
                Button("Enable Xbox Library…") { enablingXbox = true }
            } else if bottle != nil || signedIn {
                Button(signedIn && library != nil ? "Open \(library!.name)" : "Run") { open() }
                if let library, bottle != nil, !signedIn { Button("Open \(library.name)") { openLibrary(library) } }
            } else if let library {
                installChoices(library)
            } else {
                Button("Install…") { install() }.disabled(profile.comingSoon)
            }
            if let bottle {
                Divider()
                Button("Edit Profile…") { sheet(ItemSheet.editProfile) }
                Button("Report Issue…") { sheet(ItemSheet.reportIssue) }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bottle.path.path)
                }
                Divider()
                Button("Uninstall…", role: .destructive) { remove() }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A round icon button on a Home tile; shows a spinner in place of the symbol while busy.
extension StoreTile {
    func popUpInstallChoices(_ library: BuiltInLibrary.Entry) {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Recommended"))
        menu.addItem(.action(library.name) { openLibrary(library) })
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Legacy option"))
        menu.addItem(.action("\(library.client ?? profile.name)…") { install() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @ViewBuilder
    func installChoices(_ library: BuiltInLibrary.Entry) -> some View {
        if let client = library.client, legacyClients {
            Section("Recommended") {
                Button(library.name) { openLibrary(library) }
            }
            Section("Legacy option") {
                Button("\(client)…") { install() }
            }
        } else {
            Button("Install \(profile.name)…") { openLibrary(library) }
        }
    }
}

private struct TileButton: View {
    let symbol: String
    let help: String
    var busy = false
    var prominent = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            ZStack {
                Image(systemName: symbol).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.small) }
            }
            .frame(width: 16, height: 16)
        }
        .buttonBorderShape(.circle)
        // The size of the toolbar's buttons.
        .controlSize(.regular)
        .disabled(busy)
        .help(help)
        .accessibilityLabel(help)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// The store's official mark (from Simple Icons, or Bootstrap Icons for Xbox; unmodified) on a rounded tile in its brand colour.
/// Falls back to initials if the logo is missing.
struct StoreIcon: View {
    let profile: GameProfile

    var body: some View {
        let background = Self.color(for: profile)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background.gradient)
            if let logo = Self.logo(for: profile.id) {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(9)
                    .foregroundStyle(background.isLight ? Color.black : Color.white)
            } else {
                Text(initials)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel(profile.name)
    }

    /// "Music Bee" and "MusicBee" give MB (words first, then capitals inside one word), "Musicbee" gives M.
    private var initials: String {
        let words = profile.name.split(separator: " ")
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        let capitals = profile.name.filter(\.isUppercase)
        return String((capitals.count > 1 ? capitals : String(profile.name.prefix(1))).prefix(2)).uppercased()
    }

    /// The profile's brand colour, or one picked from its name.
    static func color(for profile: GameProfile) -> Color {
        if let color = Color(hex: profile.brandColor) { return color }
        let hue = Double(profile.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    static func logo(for id: String) -> NSImage? {
        guard let url = ProfileStore.resourceBundle.url(forResource: id, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

/// The OverPass mark from Logos/overpass.svg, in its own colours; the app icon until that file exists.
struct BrandLogo: View {
    private static let image: NSImage? = ProfileStore.resourceBundle
        .url(forResource: "overpass", withExtension: "svg", subdirectory: "Logos")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var isLight: Bool {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

/// Equal-width columns like an adaptive grid, but a last row that isn't full is centred.
struct CenteredGrid: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumWidth + spacing)))
    }

    private func tileWidth(_ width: CGFloat, _ columns: Int) -> CGFloat {
        (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimumWidth
        let cols = columns(for: width)
        let tile = tileWidth(width, cols)
        var height: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let row = subviews[start..<min(start + cols, subviews.count)]
            height += row.map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
        }
        height += CGFloat((subviews.count + cols - 1) / cols - 1) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = columns(for: bounds.width)
        let tile = tileWidth(bounds.width, cols)
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let row = subviews[start..<min(start + cols, subviews.count)]
            let proposal = ProposedViewSize(width: tile, height: nil)
            let height = row.map { $0.sizeThatFits(proposal).height }.max() ?? 0
            let rowWidth = CGFloat(row.count) * tile + CGFloat(row.count - 1) * spacing
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            for view in row {
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: tile, height: height))
                x += tile + spacing
            }
            y += height + spacing
        }
    }
}
