import Foundation
import SwiftUI
import UserNotifications

/// How often OverPass looks for updates by itself.
enum UpdateInterval: String, CaseIterable, Identifiable {
    case never, hour, sixHours, twelveHours, day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .hour: "Once an hour"
        case .sixHours: "Once every 6 hours"
        case .twelveHours: "Once every 12 hours"
        case .day: "Once every 24 hours"
        case .week: "Once a week"
        case .month: "Once a month"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .never: nil
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        }
    }
}

/// Checks GitHub for newer versions of the app and its components as Settings › Components says (how often, and
/// whether also at startup and when OverPass comes back after a while) and posts one notification per release.
/// Clicking it opens Settings › Components, where each update has its button.
@MainActor
enum UpdateCheck {
    static let intervalKey = "updateCheckInterval"
    static let onReturnKey = "updateCheckOnReturn"
    static let defaultInterval = UpdateInterval.sixHours
    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedPrefix = "notifiedUpdate."
    /// Set by the main window; opens Settings › Components.
    static var openComponents: (() -> Void)?
    private static var components: ComponentManager?

    static var interval: UpdateInterval {
        UserDefaults.standard.string(forKey: intervalKey).flatMap(UpdateInterval.init) ?? migratedInterval
    }
    static var onReturn: Bool { UserDefaults.standard.object(forKey: onReturnKey) as? Bool ?? true }

    /// Before the interval setting there were two switches (app, components): both off means never.
    private static var migratedInterval: UpdateInterval {
        let defaults = UserDefaults.standard
        let app = defaults.object(forKey: "checkForAppUpdates") as? Bool ?? true
        let others = defaults.object(forKey: "checkForWineUpdates") as? Bool ?? true
        return app || others ? defaultInterval : .never
    }

    /// Started once when OverPass opens: the first check (when checks at startup are on), then a check whenever
    /// the interval has passed, and one when OverPass comes back to the front or out of the Dock after that long.
    static func start(_ manager: ComponentManager) {
        components = manager
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        if onReturn { Task { await checkIfDue() } }
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if onReturn { Task { await checkIfDue() } } }
            }
        }
        Task {
            // Wakes often enough to follow a changed setting; checks only once the interval has passed.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10 * 60))
                await checkIfDue()
            }
        }
    }

    private static func checkIfDue() async {
        guard let components, let seconds = interval.seconds, !components.checking else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= seconds else { return }
        UserDefaults.standard.set(Date.now, forKey: lastCheckKey)
        await components.checkForUpdates()
        let defaults = UserDefaults.standard
        for (id, version) in components.updates.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where defaults.string(forKey: notifiedPrefix + id.rawValue) != version {
            await notify(id, version)
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
