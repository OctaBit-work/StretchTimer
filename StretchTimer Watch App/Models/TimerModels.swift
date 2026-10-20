import Foundation

enum TimerPhase: String, CaseIterable {
    case hold
    case shift

    var title: String {
        switch self {
        case .hold: return "Holding"
        case .shift: return "Shifting"
        }
    }

    var startAnnouncement: String {
        switch self {
        case .hold: return "Hold stretch"
        case .shift: return "Shift position"
        }
    }
}

enum BackgroundModeChoice: String {
    case alertsOnly
    case healthKit
}

struct TimerSettings: Equatable {
    var holdSeconds: Int
    var shiftSeconds: Int
    var announcementsEnabled: Bool

    static let minSeconds = 5
    static let maxSeconds = 600
    static let stepSeconds = 5

    func clamped() -> TimerSettings {
        TimerSettings(
            holdSeconds: min(max(holdSeconds, Self.minSeconds), Self.maxSeconds),
            shiftSeconds: min(max(shiftSeconds, Self.minSeconds), Self.maxSeconds),
            announcementsEnabled: announcementsEnabled
        )
    }

    func duration(for phase: TimerPhase) -> Int {
        switch phase {
        case .hold: return holdSeconds
        case .shift: return shiftSeconds
        }
    }
}
