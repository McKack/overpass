import Foundation
import AVFoundation
import Network
import SwiftUI

// macOS has no way to grant privacy permissions ahead of time: each prompt appears the first time the app,
// or a Wine process it started, touches the resource. Wine links the Windows Desktop, Documents and
// Downloads folders to the Mac ones and maps mounted drives, so games and installers would otherwise
// trigger prompts mid-install. Touching each resource once, here, brings the prompts forward to setup.
@MainActor
@Observable
final class PermissionsManager {
    enum State: Equatable {
        case notAsked, asking, granted, denied
        /// Nothing to touch yet (no external drive connected); macOS asks when one is first used.
        case later
        /// Asked, but macOS doesn't tell apps the answer.
        case asked
    }

    struct Item: Identifiable {
        let id: String
        let name: String
        let detail: String
        let technical: String
        let symbol: String
        var state: State = .notAsked
    }

    var items: [Item] = [
        Item(id: "folders", name: "Desktop, Documents and Downloads",
             detail: "Windows programs see these as their own folders; games keep saves in Documents.",
             technical: "Wine links each container's Desktop, Documents and Downloads to your Mac's. macOS asks once for OverPass and once for each game's Applications wrapper.",
             symbol: "folder"),
        Item(id: "volumes", name: "External and Network Drives",
             detail: "Install from or onto a connected drive. Wine shows each mounted drive to Windows programs.",
             technical: "Removable Volumes and Network Volumes access. Wine's mount manager gives removable drives a letter, and Z: reaches all of /Volumes; macOS asks when a drive is first read.",
             symbol: "externaldrive"),
        Item(id: "microphone", name: "Microphone",
             detail: "Voice chat in games and launchers.",
             technical: "Wine's Core Audio driver opens the input device. Without NSMicrophoneUsageDescription macOS refuses silently, so wrappers carry it too.",
             symbol: "mic"),
        Item(id: "network", name: "Local Network",
             detail: "LAN multiplayer and finding devices on your network.",
             technical: "Local network access for broadcasts and Bonjour. macOS asks on first use and never reports the answer, so this only shows Asked.",
             symbol: "network"),
        Item(id: "screen", name: "Screen Recording",
             detail: "A screenshot of the game goes with a report you make with \(ReportHotKey.display) while it runs.",
             technical: "ScreenCaptureKit captures only the game's window, and only when the report hotkey is pressed. macOS may want OverPass to restart before it applies.",
             symbol: "camera.viewfinder"),
    ]

    var isAsking: Bool { items.contains { $0.state == .asking } }
    var allAsked: Bool { !items.contains { $0.state == .notAsked } }

    init() {
        refreshMicrophone()
        if CGPreflightScreenCaptureAccess() { set("screen", .granted) }
    }

    /// Requests each permission in turn; every prompt waits for the user before the next appears.
    func requestAll() async {
        for item in items where item.state == .notAsked || item.state == .denied {
            await request(item.id)
        }
    }

    func request(_ id: String) async {
        set(id, .asking)
        let state: State
        switch id {
        case "folders": state = await Self.touchFolders()
        case "volumes": state = await Self.touchVolumes()
        case "microphone": state = await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case "network": state = await Self.touchLocalNetwork()
        // macOS shows its prompt (once) and answers at once, before the person has chosen.
        case "screen": state = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() ? .granted : .asked
        default: state = .notAsked
        }
        set(id, state)
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    private func refreshMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: set("microphone", .granted)
        case .denied, .restricted: set("microphone", .denied)
        default: break
        }
    }

    private func set(_ id: String, _ state: State) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = state }
    }

    // Reading a protected folder blocks until the user answers its prompt, so this runs off the main thread.
    nonisolated private static func touchFolders() async -> State {
        await Task.detached {
            let fm = FileManager.default
            let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
            let granted = dirs.allSatisfy { dir in
                guard let url = fm.urls(for: dir, in: .userDomainMask).first else { return true }
                return (try? fm.contentsOfDirectory(atPath: url.path)) != nil
            }
            return granted ? .granted : .denied
        }.value
    }

    nonisolated private static func touchVolumes() async -> State {
        await Task.detached {
            let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            let external = volumes.filter { url in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return false }
                return v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsLocal == false
            }
            guard !external.isEmpty else { return .later }
            let granted = external.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
            return granted ? .granted : .denied
        }.value
    }

    // Browsing for a Bonjour service is the documented way to raise the Local Network prompt. The service
    // type must be listed in NSBonjourServices; nothing needs to answer. macOS never reports the outcome.
    private static func touchLocalNetwork() async -> State {
        let browser = NWBrowser(for: .bonjour(type: "_overpass._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(2))
        browser.cancel()
        return .asked
    }
}

struct PermissionsList: View {
    let permissions: PermissionsManager
    @AppStorage(SettingsDetail.key) private var detail = SettingsDetail.simple

    var body: some View {
        ForEach(permissions.items) { item in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.bold())
                    Text(detail == .simple ? item.detail : item.technical).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                status(item)
            }
        }
    }

    @ViewBuilder
    private func status(_ item: PermissionsManager.Item) -> some View {
        switch item.state {
        case .notAsked:
            Button("Allow") { Task { await permissions.request(item.id) } }
                .disabled(permissions.isAsking)
        case .asking:
            ProgressView().controlSize(.small)
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Allowed")
        case .asked:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("Asked; change it in System Settings")
        case .later:
            Text("When connected").font(.caption).foregroundStyle(.secondary)
                .help("No external drive is connected; macOS asks the first time one is used.")
        case .denied:
            Button("Open Settings") { permissions.openPrivacySettings() }
                .help("Not allowed. Turn it on in System Settings → Privacy & Security.")
        }
    }
}
