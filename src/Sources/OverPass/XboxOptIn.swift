import SwiftUI

/// The Xbox Library is off until the user turns it on and accepts the risks: Xodus decrypts the game packages
/// with the account's own licences and signs in as a Microsoft client, which Microsoft's terms may not allow.
/// Turning it off signs out, removes Xodus and greys the Xbox tile again; installed games stay on disk.
@MainActor
enum XboxOptIn {
    static let key = "xboxLibrary"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func disable(_ components: ComponentManager) async {
        if XboxStore.shared.account != nil { await XboxStore.shared.signOut() }
        components.remove(.xodus)
        UserDefaults.standard.set(false, forKey: key)
    }
}

/// The risks, an "I understand the risks" box, and only then "Enable and Install": turns the Xbox Library on,
/// installs Xodus and goes on to the Microsoft sign-in.
struct XboxEnableSheet: View {
    @Environment(ComponentManager.self) private var components
    @Environment(\.storeActions) private var storeActions
    @Environment(\.dismiss) private var dismiss
    @AppStorage(XboxOptIn.key) private var enabled = false
    @State private var understood = false
    @State private var installing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield").font(.largeTitle).foregroundStyle(.orange)
                Text("Enable the Xbox Library?").font(.title2.bold())
                BetaBadge()
            }
            Text("OverPass plays Xbox PC and Game Pass games through Xodus, an open-source Xbox client made by "
                 + "volunteers, not by Microsoft. Before you turn it on:")
            VStack(alignment: .leading, spacing: 8) {
                risk("person.crop.circle.badge.exclamationmark",
                     "Xodus signs in to your Microsoft account as a Microsoft app would. Microsoft's terms don't allow unofficial clients, and accounts could be suspended or banned.")
                risk("lock.open",
                     "To run a game, Xodus decrypts its package with your own licence. Copy-protection laws in some countries forbid this, even for games you own.")
                risk("wrench.and.screwdriver",
                     "Many games won't work yet: anything with anti-cheat, and some newer packages. Microsoft can change its services and break sign-in or downloads at any time.")
                risk("arrow.down.circle",
                     "Xodus is downloaded separately (GPL-3.0). OverPass keeps no games, keys or passwords; your sign-in stays in your Keychain.")
            }
            Text("You can turn it off again in Settings › Advanced.").font(.callout).foregroundStyle(.secondary)
            Toggle("I understand the risks", isOn: $understood).toggleStyle(.checkbox)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                if installing { ProgressView().controlSize(.small); Text("Installing Xodus…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enable and Install") { enable() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood || installing)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func risk(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
        }
    }

    private func enable() {
        installing = true
        failure = nil
        enabled = true
        Task {
            await components.install(.xodus)
            installing = false
            guard components.isInstalled(.xodus) else {
                // Off again until Xodus is actually there.
                enabled = false
                failure = components.lastError ?? "Xodus couldn't be installed."
                return
            }
            dismiss()
            storeActions.connect(XboxStore.group)
        }
    }
}

/// Marks a feature that works in principle but hasn't been tested end to end (the Xbox Library).
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.orange.opacity(0.6)))
            .help("Experimental: not yet tested end to end")
    }
}
