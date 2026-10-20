import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {
    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuth = false
    private var pendingIdentifiers: [String] = []

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuth else { return }
        hasRequestedAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleIntervalNotifications(phase: TimerPhase, duration seconds: Int, isFinalPhase: Bool) {
        requestAuthorizationIfNeeded()
        clearPending()

        let phaseLabel = (phase == .hold) ? "Hold" : "Shift"

        for offset in [3, 2, 1] {
            let fireIn = seconds - offset
            guard fireIn >= 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "StretchTimer"
            content.body = "\(phaseLabel) \(offset)"
            content.sound = .default
            schedule(content: content, in: fireIn)
        }

        if seconds >= 1 {
            let content = UNMutableNotificationContent()
            content.title = "StretchTimer"
            content.body = isFinalPhase ? "Session complete" : "\(phaseLabel) complete"
            content.sound = .default
            schedule(content: content, in: seconds)
        }
    }

    func scheduleImmediateSessionCompleteNotification() {
        requestAuthorizationIfNeeded()
        clearPending()

        let content = UNMutableNotificationContent()
        content.title = "StretchTimer"
        content.body = "Session complete"
        content.sound = .default
        schedule(content: content, in: 1)
    }

    func clearPending() {
        if !pendingIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
            pendingIdentifiers.removeAll()
        }
    }

    func clearAll() {
        center.removeAllPendingNotificationRequests()
        pendingIdentifiers.removeAll()
    }

    private func schedule(content: UNNotificationContent, in seconds: Int) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let identifier = "phase-\(UUID().uuidString)"
        pendingIdentifiers.append(identifier)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }
}
