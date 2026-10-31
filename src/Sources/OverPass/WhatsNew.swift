import SwiftUI

/// CHANGELOG.md, shipped in the app: one source for this window and GitHub. Each version opens with a plain list,
/// which is what OverPass shows; its "### Details" are for the full file.
@MainActor
enum WhatsNew {
    static let windowID = "whats-new"
    static let changelogURL = URL(string: "https://github.com/McKack/overpass/blob/main/CHANGELOG.md")!
    private static let seenKey = "whatsNewSeenVersion"

    /// Opened by an update rather than from the Help menu.
    static var justUpdated = false

    struct Release: Identifiable {
        let version: String
        var items: [String] = []
        var id: String { version }
    }

    /// Every version in the file, newest first.
    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        var inList = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                guard let version = line.dropFirst(3).split(separator: " ").first else { continue }
                releases.append(Release(version: String(version)))
                inList = true
            } else if line.hasPrefix("### ") {
                inList = false
            } else if inList, line.hasPrefix("- ") {
                releases[releases.count - 1].items.append(String(line.dropFirst(2)))
            }
        }
        return releases
    }

    /// The last three updates, up to this copy's version.
    static func recent() -> [Release] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(parse(text).filter { !AppUpdate.isNewer($0.version, than: AppUpdate.currentVersion) }.prefix(3))
    }

    /// A new install has nothing to catch up on: the setup wizard calls this when it finishes.
    static func markSeen() {
        UserDefaults.standard.set(AppUpdate.currentVersion, forKey: seenKey)
    }

    /// Opens the window once per update. Waits while OverPass is in the background, so it stays away from a
    /// game started from the Dock; it comes up when the person returns to OverPass.
    static func openAfterUpdate(with openWindow: OpenWindowAction) {
        guard NSApp.isActive, UserDefaults.standard.string(forKey: seenKey) != AppUpdate.currentVersion else { return }
        markSeen()
        justUpdated = true
        openWindow(id: windowID)
    }
}

struct WhatsNewView: View {
    private let releases = WhatsNew.recent()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                    VStack(alignment: .leading, spacing: 8) {
                        if index == 0 {
                            Text(WhatsNew.justUpdated ? "OverPass just updated to \(release.version)"
                                                      : "What's New in OverPass \(release.version)")
                                .font(.title2.bold())
                        } else {
                            Text("OverPass \(release.version)").font(.headline)
                        }
                        ForEach(release.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item)
                            }
                        }
                    }
                }
                Link("Full changelog on GitHub", destination: WhatsNew.changelogURL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(width: 460, height: 500)
        .onDisappear { WhatsNew.justUpdated = false }
    }
}
