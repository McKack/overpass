import SwiftUI
import CoreImage

/// A game's cover in the cover grid: 2:3 art like Steam's library capsules, or a generated one with the app's
/// icon when no art is found.
struct CoverTile: View {
    @Environment(BottleManager.self) private var manager
    let item: LibraryItem
    let width: CGFloat
    var selected = false
    /// A Play button under the caption, where a store's games that aren't installed show Install.
    var playButton = false
    var select: () -> Void = {}
    /// The store a title comes from, shown as the cover style says (a label or a game case).
    var platform: CasePlatform? = nil
    /// The store's logo before the name; not needed in the store's own category.
    var captionIcon = true
    let launch: () -> Void
    @State private var cover: NSImage?
    @State private var background: NSImage?

    var body: some View {
        let opening = manager.isOpening(item.app, in: item.bottle)
        VStack(spacing: 8) {
            StyledCover(platform: platform, width: width, selected: selected, dimmed: opening) { corner in
                art(width: width, corner: corner)
            }
            .overlay { if opening { ProgressView() } }
            CoverCaption(title: item.app.name, platform: platform, width: width, icon: captionIcon)
            if playButton { OpenButton(opening: opening, label: item.app.runLabel, action: launch)
                .buttonStyle(.borderedProminent).controlSize(.small) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !opening { launch() } })
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(manager.tooltip(for: item))
        .contextMenu { LibraryItemMenu(item: item, launch: launch) }
        .task(id: item.id + (item.app.cover ?? "") + "\(item.app.generatedCover)") { cover = await CoverArt.image(for: item) }
    }

    /// The cover picture (or the generated one) at `width`, with the anti-cheat badge.
    private func art(width: CGFloat, corner: CGFloat) -> some View {
        ZStack {
            if let cover {
                StyledPicture(picture: cover, style: item.app.coverStyle ?? .cover, width: width)
            } else {
                generated(width: width)
            }
        }
        .frame(width: width, height: width * 1.5)
        .overlay(alignment: .topTrailing) { AntiCheatBadge(item: item, size: max(16, width * 0.14)).padding(6) }
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    /// The app's icon over its backdrop (ArtStyle), filling the cover.
    private func generated(width: CGFloat) -> some View {
        let style = item.app.coverStyle ?? .cover
        return ZStack {
            if let background {
                Image(nsImage: background).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            AppIcon(item: item, size: width * CGFloat(style.scale) / 100)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                .offset(x: width * CGFloat(style.x) / 100, y: width * 1.5 * CGFloat(style.y) / 100)
        }
        .task(id: "\(item.id)\(item.app.icon ?? "")\(style)") {
            let (app, bottle) = (item.app, item.bottle)
            background = await Task.detached(priority: .utility) {
                let size = CGSize(width: 200, height: 300)
                return WindowsIcons.icoFile(for: app, in: bottle).flatMap(NSImage.init(contentsOf:))
                    .flatMap { style.background(for: $0, size: size) }
                    .map { NSImage(cgImage: $0, size: size) }
            }.value
        }
    }
}

/// A cover picture as its style places it, over the style's backdrop where it leaves the frame uncovered.
struct StyledPicture: View {
    let picture: NSImage
    let style: ArtStyle
    let width: CGFloat
    @State private var backdrop: NSImage?

    var body: some View {
        let frame = CGRect(x: 0, y: 0, width: width, height: width * 1.5)
        let rect = style.pictureRect(picture.size, in: frame)
        ZStack(alignment: .topLeading) {
            if style.showsBackdrop {
                if let backdrop {
                    Image(nsImage: backdrop).resizable()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            Image(nsImage: picture).resizable().interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
        .task(id: style.showsBackdrop ? "\(ObjectIdentifier(picture))\(style.base)\(style.frost)" : "") {
            guard style.showsBackdrop, let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let style = style
            backdrop = await Task.detached(priority: .utility) {
                let size = CGSize(width: 200, height: 300)
                return style.background(for: cg, size: size).map { NSImage(cgImage: $0, size: size) }
            }.value
        }
    }
}

/// How a generated cover or a Mac app's icon is drawn where no art exists: the icon at `scale` percent of the
/// width over a base colour, with a frosted blur of the icon layered on top at `frost` percent. A cover picture,
/// or an icon that is a picture (no transparency), is drawn at `picture` percent instead, where 50 fills the frame
/// and 100 is twice that; the backdrop shows where it doesn't reach. Either is moved by `x` and `y` percent of the
/// frame. A profile sets it with `cover-style` / `icon-style` = "<base> <frost> <size> <picture> <x> <y>", e.g.
/// "dark 40 70"; what's left out keeps its default. The frosted layer and custom colours are toned: washed out and
/// kept off full black and full white, so they read as a backdrop, not as part of the icon. The preset colours are
/// flat with a light gradient.
struct ArtStyle: Hashable {
    enum Base: Hashable {
        /// Light or dark, whichever the icon stands out from more.
        case contrast
        case light
        case dark
        /// The brand colour of the game client whose bottle the title is in (`client` in a profile; the library
        /// fills in the colour).
        case client(String?)
        case custom(String)
    }

    var base: Base = .contrast
    var frost = 100
    var scale: Int
    var picture = 50
    var x = 0
    var y = 0

    static let cover = ArtStyle(scale: 74)
    static let icon = ArtStyle(scale: 70)
    /// `cover = generated`: the generated cover even when the store has art.
    static let generatedCover = "generated"
    static let lightColor = "F2F2F7"
    static let darkColor = "2C2C2E"
    static let frostRange = 0...100
    static let scaleRange = 30...100
    static let pictureRange = 0...100
    /// How far the icon or picture moves: a full frame either way.
    static let offsetRange = -100...100

    init(base: Base = .contrast, frost: Int = 100, scale: Int) {
        self.base = base
        self.frost = frost
        self.scale = scale
    }

    /// Parses a profile value; what's missing or malformed keeps the default's.
    init(_ value: String?, default fallback: ArtStyle) {
        self = fallback
        let words = (value ?? "").lowercased().split(separator: " ").map(String.init)
        if let word = words.first {
            switch word {
            case "contrast": base = .contrast
            case "light": base = .light
            case "dark": base = .dark
            case "client": base = .client(nil)
            case _ where word.hasPrefix("client:"): base = .client(String(word.dropFirst("client:".count)))
            case _ where Self.isHex(word): base = .custom(word)
            default: break
            }
        }
        if words.count > 1, let n = Int(words[1]) { frost = n.clamped(to: Self.frostRange) }
        if words.count > 2, let n = Int(words[2]) { scale = n.clamped(to: Self.scaleRange) }
        if words.count > 3, let n = Int(words[3]) { picture = n.clamped(to: Self.pictureRange) }
        if words.count > 4, let n = Int(words[4]) { x = n.clamped(to: Self.offsetRange) }
        if words.count > 5, let n = Int(words[5]) { y = n.clamped(to: Self.offsetRange) }
    }

    var value: String {
        let word: String
        switch base {
        case .contrast: word = "contrast"
        case .light: word = "light"
        case .dark: word = "dark"
        case .client: word = "client"
        case .custom(let hex): word = hex
        }
        let extra = picture != 50 || x != 0 || y != 0 ? " \(picture) \(x) \(y)" : ""
        return "\(word) \(frost) \(scale)\(extra)"
    }

    /// Whether a picture drawn with this style leaves part of the frame to the backdrop.
    var showsBackdrop: Bool { picture < 50 || x != 0 || y != 0 }

    /// Where a picture goes in `frame`, in top-down coordinates: filling it at 50%, scaled from its centre, moved.
    func pictureRect(_ size: CGSize, in frame: CGRect) -> CGRect {
        let fill = max(frame.width / max(size.width, 1), frame.height / max(size.height, 1)) * CGFloat(picture) / 50
        let (w, h) = (size.width * fill, size.height * fill)
        return CGRect(x: frame.midX - w / 2 + frame.width * CGFloat(x) / 100,
                      y: frame.midY - h / 2 + frame.height * CGFloat(y) / 100, width: w, height: h)
    }

    /// An image with no transparent pixels: a picture to fill the frame rather than an icon to sit on it.
    static func isPicture(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: break
        }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 250 }
    }

    /// With a game client's colour filled in.
    func withClient(_ color: String?) -> ArtStyle {
        guard case .client = base else { return self }
        var style = self
        style.base = .client(color)
        return style
    }

    /// The backdrop behind the icon, `size` points.
    func background(for icon: NSImage, size: CGSize) -> CGImage? {
        icon.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { background(for: $0, size: size) }
    }

    func background(for cg: CGImage, size: CGSize) -> CGImage? {
        let source = CIImage(cgImage: cg)
        let frame = CGRect(origin: .zero, size: size)
        let context = CIContext()
        func flat(_ hex: String) -> CIImage {
            let bottom = Self.ciColor(hex)
            let top = CIColor(red: min(1, bottom.red + 0.08), green: min(1, bottom.green + 0.08), blue: min(1, bottom.blue + 0.08))
            return CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: size.height), "inputColor0": top,
                "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": bottom])?.outputImage ?? CIImage(color: bottom)
        }
        var image: CIImage
        switch base {
        case .light: image = flat(Self.lightColor)
        case .dark: image = flat(Self.darkColor)
        case .client(let hex?) where Self.isHex(hex): image = flat(hex)
        case .contrast, .client:
            if let icon = Self.luminance(of: cg) {
                image = flat(Self.contrast(Self.luminance(Self.lightColor), icon) >= Self.contrast(Self.luminance(Self.darkColor), icon)
                             ? Self.lightColor : Self.darkColor)
            } else {
                image = flat(Self.lightColor)
            }
        case .custom(let hex): image = Self.toned(CIImage(color: Self.ciColor(hex)))
        }
        if frost > 0 {
            // Scaled to fill the frame plus 10%, centred.
            let scale = max(size.width / source.extent.width, size.height / source.extent.height) * 1.1
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = scaled.transformed(by: CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                  y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
            // Transparent corners of round icons take the icon's average colour instead of showing through.
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(source.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: source.extent)]),
                           toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let alpha = max(CGFloat(pixel[3]), 1)
            let average = CIImage(color: CIColor(red: CGFloat(pixel[0]) / alpha, green: CGFloat(pixel[1]) / alpha,
                                                 blue: CGFloat(pixel[2]) / alpha))
            // Sigma 45 on a 200-point-wide cover; other sizes blur in proportion.
            let frosted = Self.toned(placed.clampedToExtent()
                .applyingGaussianBlur(sigma: 45 * min(size.width, size.height) / 200)
                .composited(over: average))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(frost) / 100)])
            image = frosted.composited(over: image)
        }
        return context.createCGImage(image.cropped(to: frame), from: frame)
    }

    /// Washed out (lower contrast, lifted darks) and kept between 10% and 80% in every channel.
    private static func toned(_ image: CIImage) -> CIImage {
        image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1, kCIInputContrastKey: 0.75,
                                                            kCIInputBrightnessKey: -0.05])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.85])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.1, y: 0.1, z: 0.1, w: 1),
                                                         "inputMaxComponents": CIVector(x: 0.8, y: 0.8, z: 0.8, w: 1)])
    }

    static func isHex(_ s: String) -> Bool { s.count == 6 && UInt32(s, radix: 16) != nil }

    static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    static func ciColor(_ hex: String) -> CIColor {
        let v = UInt32(hex, radix: 16) ?? 0
        return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255)
    }

    /// Relative luminance (WCAG) of the icon's visible pixels, averaged by their opacity; nil for an empty icon.
    private static func luminance(of icon: CGImage) -> Double? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(icon, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.05 else { continue }
            // Premultiplied: divide the alpha back out.
            sum += a * luminance(Double(pixels[i]) / 255 / a, Double(pixels[i + 1]) / 255 / a, Double(pixels[i + 2]) / 255 / a)
            weight += a
        }
        return weight > 0 ? sum / weight : nil
    }

    private static func luminance(_ hex: String) -> Double {
        let c = ciColor(hex)
        return luminance(Double(c.red), Double(c.green), Double(c.blue))
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((min(c, 1) + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// The store a title comes from, for its game case. Store profiles give the colour and logo (as on Home); titles
/// from no store get a plain grey case named Other.
@MainActor func casePlatform(_ item: LibraryItem, clients: [GameProfile], stores: [GameProfile], manager: BottleManager) -> CasePlatform {
    guard let name = platformName(item, clients: clients, manager: manager) else {
        // A soft peach.
        return CasePlatform(name: BuiltInCategory.other.name, color: Color(red: 0.85, green: 0.52, blue: 0.40), logo: nil,
                            symbol: BuiltInCategory.other.symbol)
    }
    if item.bottle.isMac {
        // Finder's darker blue.
        return CasePlatform(name: name, color: Color(red: 0.0, green: 0.33, blue: 0.80), logo: nil,
                            symbol: BuiltInCategory.mac.symbol)
    }
    let profile = clients.first { manager.bottle(for: $0)?.path == item.bottle.path && $0.name.localizedCaseInsensitiveContains(name) }
        ?? stores.first { $0.name.localizedCaseInsensitiveContains(name) }
    return CasePlatform(name: name, color: profile.map(StoreIcon.color(for:)) ?? Color(white: 0.42),
                        logo: profile.flatMap { StoreIcon.logo(for: $0.id) })
}

/// A store's case, for its games that aren't installed yet.
@MainActor func casePlatform(store name: String, stores: [GameProfile]) -> CasePlatform {
    let profile = stores.first { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }
    return CasePlatform(name: name, color: profile.map(StoreIcon.color(for:)) ?? Color(white: 0.42),
                        logo: profile.flatMap { StoreIcon.logo(for: $0.id) })
}

/// The store or service a title comes from, as a short name.
@MainActor func platformName(_ item: LibraryItem, clients: [GameProfile], manager: BottleManager) -> String? {
    let name = item.app.launcher ?? clients.first { manager.bottle(for: $0)?.path == item.bottle.path }?.name
    guard let name else { return nil }
    let short = [("Steam", "Steam"), ("GOG", "GOG"), ("Epic", "Epic Games"), ("Xbox", "Xbox"), ("EA", "EA"),
                 ("Ubisoft", "Ubisoft"), ("Battle.net", "Battle.net"), ("Rockstar", "Rockstar")]
    return short.first { name.localizedCaseInsensitiveContains($0.0) }?.1 ?? name
}

/// Cover art, downloaded once from the game's store and kept in the media cache (`<service>/Covers`).
@MainActor
enum CoverArt {
    private static let memory = NSCache<NSString, NSImage>()
    /// Downloads under way, so a cover shown twice (All Titles and a client's category) loads once.
    private static var loading: [String: Task<NSImage?, Never>] = [:]
    /// How long a title with no art waits before the stores are asked again.
    private static let retryAfter: TimeInterval = 7 * 24 * 3600

    static func image(for item: LibraryItem) async -> NSImage? {
        if let cover = item.app.cover { return NSImage(contentsOfFile: cover) }
        if item.app.generatedCover { return nil }
        guard let (service, id) = key(for: item.app) else { return nil }
        let key = service + "/" + id
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = loading[key] { return await task.value }
        let task = Task { await load(item, service: service, id: id) }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    /// The media cache's service folder and the store's ID for a title; nil for apps no store knows.
    private static func key(for app: WineApp) -> (String, String)? {
        guard let id = app.storeID?.filter({ $0.isLetter || $0.isNumber || $0 == "-" }), !id.isEmpty else { return nil }
        switch app.launcher {
        case "Steam": return ("Steam", id)
        case "GOG": return ("GOG", id)
        case EpicStore.launcherName where app.backend == .legendary: return ("Epic", id)
        default: return nil
        }
    }

    private static func load(_ item: LibraryItem, service: String, id: String) async -> NSImage? {
        let fm = FileManager.default
        let file = MediaCache.file(service, .covers, id: id, ext: "jpg")
        let none = MediaCache.file(service, .covers, id: id, ext: "none")
        if let image = NSImage(contentsOf: file) { return image }
        if let date = (try? fm.attributesOfItem(atPath: none.path))?[.modificationDate] as? Date,
           Date.now.timeIntervalSince(date) < retryAfter { return nil }
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in await sources(for: item) {
            guard let data = url.isFileURL ? try? Data(contentsOf: url) : await download(url),
                  let image = NSImage(data: data) else { continue }
            try? data.write(to: file, options: .atomic)
            try? fm.removeItem(at: none)
            return image
        }
        fm.createFile(atPath: none.path, contents: nil)
        return nil
    }

    private static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        await download(url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Where to look for a title's 2:3 art, best first.
    private static func sources(for item: LibraryItem) async -> [URL] {
        guard let id = item.app.storeID else { return [] }
        switch item.app.launcher {
        case "Steam":
            var urls: [URL] = []
            // Newer games keep their art under a hashed folder that only the store API names.
            let request = #"{"ids":[{"appid":\#(id)}],"context":{"language":"english","country_code":"US","steam_realm":1},"data_request":{"include_assets":true}}"#
            var api = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1")!
            api.queryItems = [URLQueryItem(name: "input_json", value: request)]
            if let url = api.url, let response = await json(url)?["response"] as? [String: Any],
               let assets = ((response["store_items"] as? [[String: Any]])?.first)?["assets"] as? [String: Any],
               let format = assets["asset_url_format"] as? String {
                for name in ["library_capsule_2x", "library_capsule"] {
                    if let file = assets[name] as? String,
                       let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/"
                                     + format.replacingOccurrences(of: "${FILENAME}", with: file)) {
                        urls.append(url)
                    }
                }
            }
            urls.append(URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900_2x.jpg")!)
            // Offline, the art the Steam client keeps for the games it shows (often only 300x450). Games start
            // through steam.exe, so the client's folder is the executable's.
            let cache = URL(fileURLWithPath: item.app.executable).deletingLastPathComponent()
                .appendingPathComponent("appcache/librarycache/\(id)")
            let folders = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            urls += ([cache] + folders).map { $0.appendingPathComponent("library_600x900.jpg") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            return urls
        case "GOG":
            guard let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(id)"),
                  let game = await json(url)?["game"] as? [String: Any],
                  let format = (game["vertical_cover"] as? [String: Any])?["url_format"] as? String else { return [] }
            return URL(string: format.replacingOccurrences(of: "{formatter}", with: "")
                .replacingOccurrences(of: "{ext}", with: "jpg")).map { [$0] } ?? []
        case EpicStore.launcherName:
            return EpicStore.cachedCover(id).map { [$0] } ?? []
        default:
            return []
        }
    }
}

/// The store a title comes from, for its game case: the short name, the Home tile's colour and its logo.
struct CasePlatform {
    let name: String
    let color: Color
    let logo: NSImage?
    /// An SF Symbol in place of a logo.
    var symbol: String? = nil
}

/// A cover as the View menu's Cover View says: bare, or in a game case (flat, or tilting toward the pointer).
/// `art` draws the 2:3 picture at the cover's width, clipped to the corner radius it's given.
struct StyledCover<Art: View>: View {
    let platform: CasePlatform?
    let width: CGFloat
    var selected = false
    var dimmed = false
    @ViewBuilder let art: (CGFloat) -> Art
    @AppStorage(ViewOptions.coverStyleKey) private var style: CoverStyle = .gameCase

    var body: some View {
        let inCase = platform != nil && style.isCase
        let shape = RoundedRectangle(cornerRadius: inCase ? GameCase<EmptyView>.corner : 8, style: .continuous)
        Group {
            if let platform, inCase {
                GameCase(platform: platform, width: width) { art(0) }
            } else {
                art(8)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 3).opacity(selected ? 1 : 0) }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .modifier(CaseTilt(enabled: inCase && style == .tiltingCase, shape: shape))
    }
}

/// A cover's name, after the logo of the store it comes from (left out in that store's own category).
struct CoverCaption: View {
    let title: String
    let platform: CasePlatform?
    let width: CGFloat
    var dimmed = false
    var icon = true

    var body: some View {
        HStack(spacing: 4) {
            if icon, let platform { PlatformIcon(platform: platform) }
            Text(title)
                .lineLimit(1)
                .foregroundStyle(dimmed ? .secondary : .primary)
        }
        .font(.callout)
        .frame(maxWidth: width)
    }
}

/// The store's logo in small grey, before a cover's name.
struct PlatformIcon: View {
    let platform: CasePlatform

    var body: some View {
        Group {
            if let logo = platform.logo {
                Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit().frame(width: 12, height: 12)
            } else if let symbol = platform.symbol {
                Image(systemName: symbol).font(.system(size: 10))
            }
        }
        .foregroundStyle(.secondary)
        .help(platform.name)
    }
}

/// A game case around a cover, like a console game's box: a band on top with the store's logo and name in the
/// store's colour (as on its Home tile), the cover filling the rest edge to edge, and a bevel over both.
struct GameCase<Content: View>: View {
    let platform: CasePlatform
    let width: CGFloat
    @ViewBuilder let content: Content

    static var corner: CGFloat { 5 }
    static func band(for width: CGFloat) -> CGFloat { max(24, width * 0.18) }

    var body: some View {
        let band = Self.band(for: width)
        let text: Color = platform.color.isLight ? .black.opacity(0.8) : .white
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: band * 0.22) {
                if let logo = platform.logo {
                    Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: band * 0.56, height: band * 0.56)
                } else if let symbol = platform.symbol {
                    Image(systemName: symbol).font(.system(size: band * 0.42))
                }
                Text(platform.name)
                    .font(.system(size: band * 0.42, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(text)
            .padding(.horizontal, band * 0.3)
            .padding(.top, 3)
            .frame(height: band + 3)
            // The store's colour, flat.
            .background(platform.color)
            content
                // A thin seam where the cover meets the band.
                .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.3)).frame(height: 1) }
        }
        .frame(width: width)
        // Bevel over the whole case, cover included: light from the top left, shade to the bottom right.
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1), .black.opacity(0.45)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
        .overlay(shape.inset(by: 1.5).strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.2)],
                                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .clipShape(shape)
    }
}

/// Tilts a case toward the pointer while it's over or near it, with a shine that moves with the angle, the way
/// Steam's library does. Springs back flat when the pointer leaves.
struct CaseTilt<S: Shape>: ViewModifier {
    let enabled: Bool
    let shape: S
    /// How far outside the case the pointer already tilts it.
    private let reach: CGFloat = 14
    /// -1...1 across each axis, from where the pointer is over the case.
    @State private var tilt = CGPoint.zero
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        if enabled {
            let amount = min(1, hypot(tilt.x, tilt.y))
            content
                .overlay {
                    // A band of light across the case; the angle moves it.
                    LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .white.opacity(0.3), location: 0.5),
                                           .init(color: .clear, location: 0.75)],
                                   startPoint: UnitPoint(x: -0.6 - tilt.x * 0.7, y: -0.6 - tilt.y * 0.7),
                                   endPoint: UnitPoint(x: 1.0 - tilt.x * 0.7, y: 1.0 - tilt.y * 0.7))
                        .blendMode(.plusLighter)
                        .opacity(amount)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
                .rotation3DEffect(.degrees(tilt.x * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(-tilt.y * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .scaleEffect(1 + amount * 0.03)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .padding(reach)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point) where size.width > 0:
                        let x = (point.x - reach) / size.width * 2 - 1, y = (point.y - reach) / size.height * 2 - 1
                        withAnimation(.interactiveSpring(response: 0.25)) {
                            tilt = CGPoint(x: x.clamped(to: -1...1), y: y.clamped(to: -1...1))
                        }
                    default:
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { tilt = .zero }
                    }
                }
                .padding(-reach)
        } else {
            content
        }
    }
}
