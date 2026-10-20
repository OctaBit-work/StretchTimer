import Combine
import Foundation
import SwiftUI
import WatchKit
import WidgetKit

@MainActor
final class TimerViewModel: ObservableObject {
    @Published var holdSeconds: Int
    @Published var shiftSeconds: Int
    @Published var announcementsEnabled: Bool
    @Published var totalDurationSeconds: Int
    @Published var sessionVolume: Float
    @Published private(set) var isCompletingOnboarding = false
    @Published private(set) var isPreparingStart = false
    @Published private(set) var startCountdownValue = 6

    @Published private(set) var isRunning = false
    @Published private(set) var currentPhase: TimerPhase = .hold
    @Published private(set) var remainingSeconds: Int
    @Published private(set) var totalRemainingSeconds: Int
    @Published private(set) var backgroundModeChoice: BackgroundModeChoice?
    private(set) var isDisplayDimmed = false

    private let announcementService: AnnouncementService
    private let workoutSessionController: WorkoutSessionController
    private let notificationScheduler: NotificationScheduler
    private var startCountdownTask: Task<Void, Never>?
    private var ticker: AnyCancellable?
    private var phaseEndDate: Date?
    private var totalEndDate: Date?

    private enum Key {
        static let holdSeconds = "settings.holdSeconds"
        static let shiftSeconds = "settings.shiftSeconds"
        static let announcementsEnabled = "settings.announcementsEnabled"
        static let backgroundModeChoice = "settings.backgroundModeChoice"
        static let totalDurationSeconds = "settings.totalDurationSeconds"
        static let sessionVolume = "settings.sessionVolume"
    }

    static let minTotalSeconds = 120
    static let maxTotalSeconds = 900
    static let totalStepSeconds = 30
    static let defaultTotalSeconds = 390
    static let defaultSessionVolume: Float = 1.0

    init(
        announcementService: AnnouncementService,
        workoutSessionController: WorkoutSessionController,
        notificationScheduler: NotificationScheduler
    ) {
        self.announcementService = announcementService
        self.workoutSessionController = workoutSessionController
        self.notificationScheduler = notificationScheduler

        let hold = UserDefaults.standard.object(forKey: Key.holdSeconds) as? Int ?? 30
        let shift = UserDefaults.standard.object(forKey: Key.shiftSeconds) as? Int ?? 10
        let announcements = UserDefaults.standard.object(forKey: Key.announcementsEnabled) as? Bool ?? true
        let total = UserDefaults.standard.object(forKey: Key.totalDurationSeconds) as? Int ?? Self.defaultTotalSeconds
        let storedVolume = UserDefaults.standard.object(forKey: Key.sessionVolume) as? Float ?? Self.defaultSessionVolume
        if let rawMode = UserDefaults.standard.string(forKey: Key.backgroundModeChoice) {
            backgroundModeChoice = BackgroundModeChoice(rawValue: rawMode)
        } else {
            backgroundModeChoice = nil
        }

        let initial = TimerSettings(holdSeconds: hold, shiftSeconds: shift, announcementsEnabled: announcements).clamped()
        let clampedTotal = min(max(total, Self.minTotalSeconds), Self.maxTotalSeconds)
        holdSeconds = initial.holdSeconds
        shiftSeconds = initial.shiftSeconds
        announcementsEnabled = initial.announcementsEnabled
        totalDurationSeconds = clampedTotal
        sessionVolume = min(max(storedVolume, 0.1), 1.0)
        remainingSeconds = initial.holdSeconds
        totalRemainingSeconds = clampedTotal
    }

    convenience init() {
        self.init(
            announcementService: AnnouncementService(),
            workoutSessionController: WorkoutSessionController(),
            notificationScheduler: NotificationScheduler()
        )
    }

    var needsOnboarding: Bool {
        backgroundModeChoice == nil
    }

    var phaseTitle: String {
        isRunning ? currentPhase.title : "Ready"
    }

    var totalDisplaySeconds: Int {
        isRunning ? totalRemainingSeconds : totalDurationSeconds
    }

    var sessionStartDate: Date? {
        guard let totalEndDate else { return nil }
        return totalEndDate.addingTimeInterval(-TimeInterval(totalDurationSeconds))
    }

    var dimmedTimelineDates: [Date] {
        guard isRunning,
              let sessionStartDate,
              let totalEndDate else { return [] }

        var dates: [Date] = []
        var cursor = sessionStartDate
        var phase: TimerPhase = .hold

        while cursor < totalEndDate {
            cursor = cursor.addingTimeInterval(TimeInterval(duration(for: phase)))
            if cursor <= totalEndDate {
                dates.append(cursor)
            }
            phase = nextPhase(after: phase)
        }

        return dates
    }

    func phase(at date: Date) -> TimerPhase? {
        guard isRunning,
              let sessionStartDate,
              let totalEndDate,
              date < totalEndDate else { return nil }

        var cursor = sessionStartDate
        var phase: TimerPhase = .hold

        while cursor < totalEndDate {
            let nextBoundary = cursor.addingTimeInterval(TimeInterval(duration(for: phase)))
            if date < nextBoundary {
                return phase
            }
            cursor = nextBoundary
            phase = nextPhase(after: phase)
        }

        return nil
    }

    func elapsedFraction(at date: Date) -> CGFloat {
        guard let sessionStartDate,
              let totalEndDate else { return 0 }

        let total = max(1, totalEndDate.timeIntervalSince(sessionStartDate))
        let elapsed = min(max(0, date.timeIntervalSince(sessionStartDate)), total)
        return CGFloat(elapsed / total)
    }

    func selectBackgroundMode(_ mode: BackgroundModeChoice) {
        backgroundModeChoice = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Key.backgroundModeChoice)
        if mode == .alertsOnly {
            notificationScheduler.requestAuthorizationIfNeeded()
        }
    }

    func beginOnboardingResolution() {
        isCompletingOnboarding = true
    }

    func finishOnboardingResolution() {
        isCompletingOnboarding = false
    }

    func enableHealthKitMode() async throws {
        selectBackgroundMode(.healthKit)
        try await workoutSessionController.requestAuthorizationIfNeeded()
        guard workoutSessionController.isAuthorizedForBackgroundSession else {
            throw WorkoutSessionError.authorizationDenied
        }
    }

    func updateHoldSeconds(_ value: Int) {
        guard !isRunning else { return }
        let clamped = min(max(value, TimerSettings.minSeconds), TimerSettings.maxSeconds)
        holdSeconds = clamped
        remainingSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: Key.holdSeconds)
    }

    func updateShiftSeconds(_ value: Int) {
        guard !isRunning else { return }
        let clamped = min(max(value, TimerSettings.minSeconds), TimerSettings.maxSeconds)
        shiftSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: Key.shiftSeconds)
    }

    func updateAnnouncementsEnabled(_ value: Bool) {
        announcementsEnabled = value
        UserDefaults.standard.set(value, forKey: Key.announcementsEnabled)
    }

    func updateTotalDurationSeconds(_ value: Int) {
        guard !isRunning else { return }
        let clamped = min(max(value, Self.minTotalSeconds), Self.maxTotalSeconds)
        totalDurationSeconds = clamped
        totalRemainingSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: Key.totalDurationSeconds)
    }

    func updateSessionVolume(_ value: Float) {
        let clamped = min(max(value, 0.1), 1.0)
        sessionVolume = clamped
        UserDefaults.standard.set(clamped, forKey: Key.sessionVolume)
    }

    func incrementHold() {
        updateHoldSeconds(holdSeconds + TimerSettings.stepSeconds)
    }

    func decrementHold() {
        updateHoldSeconds(holdSeconds - TimerSettings.stepSeconds)
    }

    func incrementShift() {
        updateShiftSeconds(shiftSeconds + TimerSettings.stepSeconds)
    }

    func decrementShift() {
        updateShiftSeconds(shiftSeconds - TimerSettings.stepSeconds)
    }

    func start() {
        guard !isRunning, !isPreparingStart else { return }

        sanitizeAndPersistSettings()
        if effectiveBackgroundMode == .healthKit {
            // Prepare the workout session before the countdown begins so the
            // app keeps running in the background if the user's sleeve covers
            // the screen while moving into position. Apple documents the
            // `.prepared` state as already granting background execution.
            workoutSessionController.prepareIfAvailable()
        }
        beginStartCountdown()
    }

    func stop(clearNotifications: Bool = true) {
        startCountdownTask?.cancel()
        startCountdownTask = nil
        isPreparingStart = false
        startCountdownValue = 6

        isRunning = false
        currentPhase = .hold
        phaseEndDate = nil
        totalEndDate = nil

        ticker?.cancel()
        ticker = nil

        workoutSessionController.stop()
        if clearNotifications {
            notificationScheduler.clearAll()
        }
        announcementService.stop()
        remainingSeconds = holdSeconds
        totalRemainingSeconds = totalDurationSeconds
        SharedSessionStore.clearSession()
        WidgetCenter.shared.reloadTimelines(ofKind: SharedSessionStore.widgetKind)
    }

    private func beginStartCountdown() {
        isPreparingStart = true
        startCountdownValue = 6

        announcementService.playStartCountdownHaptic()
        // Warm up the speech synthesizer during countdown
        if announcementsEnabled {
            announcementService.warmUp()
        }
        startCountdownTask = Task { [weak self] in
            guard let self else { return }

            for nextValue in [5, 4, 3, 2, 1] {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isPreparingStart else { return }
                self.startCountdownValue = nextValue
                if nextValue == 1 {
                    self.announcementService.playStartCountdownCompletionHaptic()
                } else {
                    self.announcementService.playStartCountdownHaptic()
                }
            }

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.isPreparingStart else { return }
            self.startCountdownTask = nil
            self.startRunningSession()
        }
    }

    private func startRunningSession() {
        isPreparingStart = false
        startCountdownValue = 6
        isRunning = true
        currentPhase = .hold
        totalRemainingSeconds = totalDurationSeconds
        totalEndDate = Date().addingTimeInterval(TimeInterval(totalDurationSeconds))

        startTickerIfNeeded()
        beginPhase(.hold)

        switch effectiveBackgroundMode {
        case .alertsOnly:
            notificationScheduler.requestAuthorizationIfNeeded()
        case .healthKit:
            workoutSessionController.onSessionPaused = { [weak self] in self?.stop() }
            workoutSessionController.startIfAvailable()
        }

        syncSharedSessionState()
    }

    private var effectiveBackgroundMode: BackgroundModeChoice {
        guard backgroundModeChoice == .healthKit else { return .alertsOnly }
        guard workoutSessionController.isAvailable else { return .alertsOnly }
        return workoutSessionController.isAuthorizedForBackgroundSession ? .healthKit : .alertsOnly
    }

    private func sanitizeAndPersistSettings() {
        let clean = TimerSettings(
            holdSeconds: holdSeconds,
            shiftSeconds: shiftSeconds,
            announcementsEnabled: announcementsEnabled
        ).clamped()

        holdSeconds = clean.holdSeconds
        shiftSeconds = clean.shiftSeconds
        announcementsEnabled = clean.announcementsEnabled

        UserDefaults.standard.set(clean.holdSeconds, forKey: Key.holdSeconds)
        UserDefaults.standard.set(clean.shiftSeconds, forKey: Key.shiftSeconds)
        UserDefaults.standard.set(clean.announcementsEnabled, forKey: Key.announcementsEnabled)
    }

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }

        ticker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard isRunning else { return }

        if let totalEndDate {
            let totalSeconds = max(0, Int(totalEndDate.timeIntervalSinceNow.rounded(.down)))
            totalRemainingSeconds = totalSeconds
            if totalSeconds == 0 {
                announcementService.playSessionCompleteHaptic()
                if effectiveBackgroundMode == .alertsOnly || WKApplication.shared().applicationState == .active {
                    notificationScheduler.scheduleImmediateSessionCompleteNotification()
                }
                stop(clearNotifications: false)
                return
            }
        }

        guard let endDate = phaseEndDate else { return }
        let seconds = max(0, Int(endDate.timeIntervalSinceNow.rounded(.down)))
        remainingSeconds = seconds

        if seconds == 0 {
            transitionToNextPhase()
            return
        }
    }

    private func beginPhase(_ phase: TimerPhase, announcePhaseStart: Bool = true) {
        currentPhase = phase
        let duration = duration(for: phase)
        remainingSeconds = duration
        phaseEndDate = Date().addingTimeInterval(TimeInterval(duration))

        // In HealthKit background mode, an active workout session keeps background
        // audio alive, so announcements can continue while the display is dimmed.
        // Alerts-only mode has no such session, so background speech isn't
        // supported there and announcements stop once dimmed.
        if announcePhaseStart && announcementsEnabled && (!isDisplayDimmed || effectiveBackgroundMode == .healthKit) {
            announcementService.announce(phase.startAnnouncement, volume: sessionVolume)
        }

        if effectiveBackgroundMode == .alertsOnly && !isDisplayDimmed {
            let totalRemaining = totalEndDate.map { max(0, Int($0.timeIntervalSinceNow.rounded(.down))) } ?? totalDurationSeconds
            let isFinalPhase = totalRemaining <= duration
            notificationScheduler.scheduleIntervalNotifications(phase: phase, duration: duration, isFinalPhase: isFinalPhase)
        }

        syncSharedSessionState()
    }

    private func transitionToNextPhase() {
        guard isRunning else { return }

        let completed = currentPhase
        announcementService.playPhaseTransitionHaptic(for: completed)

        let next: TimerPhase = (completed == .hold) ? .shift : .hold
        beginPhase(next)
    }

    private func duration(for phase: TimerPhase) -> Int {
        switch phase {
        case .hold: return holdSeconds
        case .shift: return shiftSeconds
        }
    }

    private func nextPhase(after phase: TimerPhase) -> TimerPhase {
        phase == .hold ? .shift : .hold
    }

    func updateDisplayDimmed(_ dimmed: Bool) {
        isDisplayDimmed = dimmed
        guard dimmed else { return }

        notificationScheduler.clearPending()
        guard effectiveBackgroundMode != .healthKit else { return }
        announcementService.stop()
    }

    private func syncSharedSessionState() {
        SharedSessionStore.updateSession(
            isActive: isRunning,
            phase: currentPhase,
            sessionEndDate: totalEndDate
        )
        WidgetCenter.shared.reloadTimelines(ofKind: SharedSessionStore.widgetKind)
    }
}
