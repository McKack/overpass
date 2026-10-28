import Foundation
import SwiftUI
import UserNotifications

/// While OverPass runs, checks GitHub once a day for newer versions of the app and its components and posts
/// one notification per release. Clicking it opens Settings › Components, where each update has its button.
@MainActor
enum UpdateCheck {
    static let appKey = "checkForAppUpdates"
    static let componentsKey = "checkForWineUpdates"   // key from when only Wine was checked
    private static let notifiedPrefix = "notifiedUpdate."
    /// Set by the main window; opens Settings › Components.
    static var openComponents: (() -> Void)?

    static func run(_ components: ComponentManager) async {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        while !Task.isCancelled {
            let defaults = UserDefaults.standard
            let app = defaults.object(forKey: appKey) as? Bool ?? true
            let others = defaults.object(forKey: componentsKey) as? Bool ?? true
            if app || others {
                await components.checkForUpdates()
                for (id, version) in components.updates.sorted(by: { $0.key.rawValue < $1.key.rawValue })
                where (id == .core ? app : others) && defaults.string(forKey: notifiedPrefix + id.rawValue) != version {
                    await notify(id, version)
                }
            }
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
        }
    }

    /// Check for Updates…: opens Settings › Components and checks there.
    static func checkNow(with openSettings: OpenSettingsAction) {
        SettingsTab.open(.components, with: openSettings)
        Task { await ComponentManager.current?.checkForUpdates() }
    }

    private static func notify(_ id: ComponentID, _ version: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(id == .core ? "OverPass" : id.name) \(version) is available"
        content.body = "Open Settings › Components to update."
        try? await center.add(UNNotificationRequest(identifier: "update-\(id.rawValue)", content: content, trigger: nil))
        UserDefaults.standard.set(version, forKey: notifiedPrefix + id.rawValue)
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            UpdateCheck.openComponents?()
        }
    }
}
