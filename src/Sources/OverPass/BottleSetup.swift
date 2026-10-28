import Foundation

// Settings every OverPass bottle gets on top of what `wineboot` makes, the way CrossOver prepares its bottles:
// which Windows parts prefer Microsoft's DLL when a program brings one, Mac fonts standing in for Windows'
// Chinese, Japanese and Korean fonts, and a few appearance settings. Plus our own: games' display mode changes are
// emulated (the Mac's display stays as it is and the frame is scaled to it), Sony controllers reach games as Xbox
// pads, which is what most PC games read, the light or dark look follows the Mac, and z: is hidden (ContainerDrives). Applied when a bottle is made, and
// once to older bottles (container.conf [OverPass] Defaults records the version applied).
enum BottleSetup {
    /// Raise when the settings below change, so existing bottles get them again.
    static let version = 3

    /// Parts Wine must provide itself: Microsoft's own versions break under Wine (OverPass Wine's RPC fix is
    /// in rpcrt4; Microsoft's wininet has no working SSL there).
    private static let builtin = ["msi", "*msiexec.exe", "ole32", "oleaut32", "olepro32", "rpcrt4", "wininet"]

    /// Parts where a program's or installer's own Microsoft DLL works better than Wine's, when one is there.
    private static let nativeFirst = [
        "amstream", "atl", "crypt32", "d3dxof", "devenum", "dplay", "dplaysvr.exe", "dplayx", "dpnaddr", "dpnet",
        "dpnhpast", "dpnhupnp", "dpnlobby", "dpnsvr.exe", "dpnwsock", "dxdiagn", "hhctrl.ocx", "hlink", "iernonce",
        "itss", "jscript", "mlang", "mshtml", "msvcirt", "msvcrt40", "msvcrtd", "odbc32", "odbccp32", "quartz",
        "riched20", "riched32", "rsabase", "secur32", "shdoclc", "shdocvw", "softpub", "urlmon", "wintrust",
        "wscript.exe",
    ]

    /// Windows fonts and the macOS fonts that stand in for them.
    private static let fontReplacements: [(String, String)] = {
        var pairs: [(String, String)] = []
        let japaneseGothic = "ヒラギノ角ゴ Pro W3", japaneseMincho = "ヒラギノ明朝 Pro W3"
        let groups: [([String], String)] = [
            (["MS Gothic", "MS PGothic", "ＭＳ ゴシック", "ＭＳ Ｐゴシック", "MS UI Gothic"], japaneseGothic),
            (["ＭＳ 明朝", "ＭＳ Ｐ明朝"], japaneseMincho),
            (["SimSun", "宋体", "NSimSun", "新宋体"], "STSong"),
            (["MingLiU", "細明體", "PMingLiU", "新細明體"], "Songti TC"),
        ]
        for (names, mac) in groups {
            for name in names { pairs += [(name, mac), ("@" + name, "@" + mac)] }
        }
        pairs += [("Gulim", "NanumGothic"), ("Microsoft Himalaya", "Kailasa"), ("Euphemia", "Euphemia UCAS")]
        return pairs
    }()

    /// The settings as a .reg file, the format `regedit` imports.
    static func registryFile(playStationControllers: Bool = false, lightTheme: Bool = true, showMacDisk: Bool = false) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["Windows Registry Editor Version 5.00", "", "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]"]
        lines += builtin.map { "\(quoted($0))=\"builtin\"" }
        lines += nativeFirst.map { "\(quoted($0))=\"native,builtin\"" }
        lines += ["", "[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]"]
        lines += fontReplacements.map { "\(quoted($0.0))=\(quoted($0.1))" }
        lines += [
            "", "[HKEY_CURRENT_USER\\Software\\Wine\\Systray]", "\"Hidden\"=dword:00000001",
            "", "[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced]",
            "\"HideFileExt\"=dword:00000000",
            "", "[HKEY_CURRENT_USER\\Control Panel\\Colors]",
        ]
        lines += ["ActiveBorder", "ButtonFace", "ButtonLight", "InactiveBorder", "Menu"].map { "\"\($0)\"=\"228 228 228\"" }
        // Without this Wine really switches the Mac's display mode when a game picks a resolution or Fullscreen,
        // which leaves the menu bar over the game and the picture shrunk on scaled (Retina, 4K) displays.
        lines += ["", "[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]", "\"EmulateModeset\"=\"y\""]
        // DualShock 4 and DualSense through SDL as Xbox pads instead of raw PlayStation devices, which XInput games
        // (most PC games, Unreal Engine) don't see. Games with native PlayStation controller support opt back in.
        lines += ["", "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\054c]",
                  "\"Hidraw\"=dword:0000000\(playStationControllers ? 1 : 0)"]
        lines += ["", "[HKEY_CURRENT_USER\\" + personalizeKey + "]"]
        lines += ["AppsUseLightTheme", "SystemUsesLightTheme"].map { "\"\($0)\"=dword:0000000\(lightTheme ? 1 : 0)" }
        lines += ContainerDrives.registryLines(showingMacDisk: showMacDisk)
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func applied(to bottle: Bottle) -> Bool {
        (BottleConfig.parse(bottle.configURL)["OverPass"]?["Defaults"]).flatMap(Int.init) ?? 0 >= version
    }

    /// Imports the settings into the bottle and records that it has them.
    @MainActor
    static func apply(to bottle: Bottle, using manager: BottleManager) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overpass-defaults-\(UUID().uuidString).reg")
        // UTF-16 with a byte order mark, as regedit expects for non-ASCII text.
        // A bottle keeps the controller setting it has; a new one takes its profile's.
        let playStation = playStationControllers(in: bottle)
            ?? manager.profiles?.profiles.first { $0.id == bottle.profileID }?.playStationControllers ?? false
        let light = appearance(of: bottle).usesLightTheme
        // Hidden unless the bottle already shows it by choice.
        let showZ = ContainerDrives.showsMacDisk(in: bottle) ?? false
        guard let data = registryFile(playStationControllers: playStation, lightTheme: light, showMacDisk: showZ)
            .data(using: .utf16LittleEndian) else { return }
        try (Data([0xFF, 0xFE]) + data).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var output = ""
        let status = try await manager.run(["regedit", "/S", "Z:" + file.path.replacingOccurrences(of: "/", with: "\\")], in: bottle) {
            output += $0
        }
        guard status == 0 else { throw DefaultsError.importFailed(status, output) }
        var config = BottleConfig.parse(bottle.configURL)
        config["OverPass", default: [:]]["Defaults"] = String(version)
        try BottleConfig.write(config, to: bottle.configURL)
    }

    private static let sonyKey = "System\\CurrentControlSet\\Services\\WineBus\\Devices\\054c"

    /// Whether Sony controllers reach the bottle as PlayStation controllers (true) or Xbox pads (false); nil
    /// when the bottle doesn't say. Read from system.reg, where Wine keeps the key under ControlSet001.
    static func playStationControllers(in bottle: Bottle) -> Bool? {
        registryValue("Hidraw", key: sonyKey.replacingOccurrences(of: "CurrentControlSet", with: "ControlSet001"),
                      file: "system.reg", in: bottle).map { $0 != "dword:00000000" }
    }

    /// A value as Wine saved it in one of the bottle's registry files (system.reg for HKLM, user.reg for HKCU,
    /// keys relative to the hive): `"y"` for a string, `dword:00000001` for a number. nil when it isn't set.
    static func registryValue(_ name: String, key: String, file: String, in bottle: Bottle) -> String? {
        guard let text = try? String(contentsOf: bottle.path.appendingPathComponent(file), encoding: .utf8) else { return nil }
        let header = "[" + key.replacingOccurrences(of: "\\", with: "\\\\").lowercased() + "]"
        let prefix = "\"" + name.lowercased() + "\"="
        var inKey = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("[") { inKey = line.lowercased().hasPrefix(header); continue }
            if inKey, line.lowercased().hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        }
        return nil
    }

    private static let macDriverKey = "Software\\Wine\\Mac Driver"

    /// What the Mac's modifier keys send to Windows programs. Wine's own default is `standard`.
    enum MacKeys: String, CaseIterable, Identifiable {
        case standard, optionAsAlt, commandAsControl
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .standard: "Command is Alt, Option types characters"
            case .optionAsAlt: "Command and Option are Alt"
            case .commandAsControl: "Command is Ctrl, Option is Alt"
            }
        }
        /// Both Command keys as Ctrl only together with Option as Alt, or there would be no Alt key left.
        var optionIsAlt: Bool { self != .standard }
        var commandIsControl: Bool { self == .commandAsControl }
    }

    static func macKeys(in bottle: Bottle) -> MacKeys {
        if macDriverOption("LeftCommandIsCtrl", in: bottle) { return .commandAsControl }
        return macDriverOption("LeftOptionIsAlt", in: bottle) ? .optionAsAlt : .standard
    }

    /// A Mac Driver switch the way Wine reads it: on when the text starts with y, t or 1.
    private static func macDriverOption(_ name: String, in bottle: Bottle) -> Bool {
        registryValue(name, key: macDriverKey, file: "user.reg", in: bottle)?.dropFirst().first.map { "yYtT1".contains($0) } ?? false
    }

    /// Changes the modifier keys. Wine reads them when a program starts.
    @MainActor
    static func setMacKeys(_ keys: MacKeys, in bottle: Bottle, using manager: BottleManager) async throws {
        for side in ["Left", "Right"] {
            try await setString(side + "OptionIsAlt", keys.optionIsAlt ? "y" : "n", key: "HKCU\\" + macDriverKey, in: bottle, using: manager)
            try await setString(side + "CommandIsCtrl", keys.commandIsControl ? "y" : "n", key: "HKCU\\" + macDriverKey, in: bottle, using: manager)
        }
    }

    /// Whether programs draw at the display's full pixel resolution (Wine's RetinaMode).
    static func retinaMode(in bottle: Bottle) -> Bool {
        macDriverOption("RetinaMode", in: bottle)
    }

    /// Retina mode doubles the pixels programs see, so the DPI goes to 192 with it to keep text and windows at
    /// their usual size (and back to Windows' 96 without it).
    @MainActor
    static func setRetinaMode(_ on: Bool, in bottle: Bottle, using manager: BottleManager) async throws {
        try await setString("RetinaMode", on ? "y" : "n", key: "HKCU\\" + macDriverKey, in: bottle, using: manager)
        let status = try await manager.run(["reg", "add", "HKCU\\Control Panel\\Desktop", "/v", "LogPixels", "/t", "REG_DWORD",
                                            "/d", on ? "192" : "96", "/f"], in: bottle)
        guard status == 0 else { throw DefaultsError.importFailed(status) }
    }

    private static let personalizeKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"

    /// Whether the bottle's programs are told to use a light or dark look (Windows' app mode, which launchers built
    /// on Chromium and newer Windows apps follow; Wine's own windows stay light until OverPass has a dark theme).
    enum Appearance: String, CaseIterable, Identifiable {
        case mac, light, dark
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .mac: "Same as Mac"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var usesLightTheme: Bool {
            switch self {
            case .mac: !Self.macIsDark
            case .light: true
            case .dark: false
            }
        }
        /// The Mac's own setting, not OverPass's window appearance (also right while Auto has switched it).
        static var macIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    }

    /// The bottle's choice, from container.conf [OverPass] Appearance; following the Mac when it doesn't say.
    static func appearance(of bottle: Bottle) -> Appearance {
        (BottleConfig.parse(bottle.configURL)["OverPass"]?["Appearance"]).flatMap(Appearance.init) ?? .mac
    }

    /// What the bottle's registry says now; nil before Wine has made it.
    static func usesLightTheme(in bottle: Bottle) -> Bool? {
        registryValue("AppsUseLightTheme", key: personalizeKey, file: "user.reg", in: bottle).map { $0 != "dword:00000000" }
    }

    /// Records the choice and writes it to the registry; programs pick it up when they start.
    @MainActor
    static func setAppearance(_ appearance: Appearance, of bottle: Bottle, using manager: BottleManager) async throws {
        var config = BottleConfig.parse(bottle.configURL)
        config["OverPass", default: [:]]["Appearance"] = appearance == .mac ? nil : appearance.rawValue
        try BottleConfig.write(config, to: bottle.configURL)
        try await setLightTheme(appearance.usesLightTheme, in: bottle, using: manager)
    }

    @MainActor
    static func setLightTheme(_ light: Bool, in bottle: Bottle, using manager: BottleManager) async throws {
        for name in ["AppsUseLightTheme", "SystemUsesLightTheme"] {
            let status = try await manager.run(["reg", "add", "HKCU\\" + personalizeKey, "/v", name, "/t", "REG_DWORD",
                                                "/d", light ? "1" : "0", "/f"], in: bottle)
            guard status == 0 else { throw DefaultsError.importFailed(status) }
        }
    }

    @MainActor
    private static func setString(_ name: String, _ value: String, key: String, in bottle: Bottle,
                                  using manager: BottleManager) async throws {
        let status = try await manager.run(["reg", "add", key, "/v", name, "/t", "REG_SZ", "/d", value, "/f"], in: bottle)
        guard status == 0 else { throw DefaultsError.importFailed(status) }
    }

    /// Changes how Sony controllers reach the bottle. Wine reads it when the bottle starts.
    @MainActor
    static func setPlayStationControllers(_ on: Bool, in bottle: Bottle, using manager: BottleManager) async throws {
        let status = try await manager.run(["reg", "add", "HKLM\\" + sonyKey, "/v", "Hidraw", "/t", "REG_DWORD",
                                            "/d", on ? "1" : "0", "/f"], in: bottle)
        guard status == 0 else { throw DefaultsError.importFailed(status) }
    }

    enum DefaultsError: LocalizedError {
        case importFailed(Int32, String = "")
        var errorDescription: String? {
            guard case .importFailed(let status, let output) = self else { return nil }
            let last = output.split(separator: "\n").suffix(3).joined(separator: "\n")
            return "regedit exited with status \(status)." + (last.isEmpty ? "" : "\n" + last)
        }
    }
}
