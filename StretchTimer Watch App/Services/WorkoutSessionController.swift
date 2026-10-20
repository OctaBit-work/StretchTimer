import Foundation
import HealthKit

@MainActor
final class WorkoutSessionController: NSObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isStopping = false
    private var hasStartedActivity = false

    var onSessionPaused: (() -> Void)?

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    var isAuthorizedForBackgroundSession: Bool {
        healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func requestAuthorizationIfNeeded() async throws {
        guard isAvailable else {
            throw WorkoutSessionError.unavailable
        }
        guard !isAuthorizedForBackgroundSession else { return }

        let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
        try await healthStore.requestAuthorization(toShare: shareTypes, read: [])
    }

    /// Creates and prepares the workout session ahead of the actual workout
    /// activity. Apple documents `HKWorkoutSessionState.prepared` as already
    /// granting background execution, even though it doesn't yet generate
    /// workout data. Call this before a period where the screen may be
    /// covered (e.g. during the pre-start countdown) so the app isn't
    /// backgrounded/suspended before `startIfAvailable()` runs.
    func prepareIfAvailable() {
        guard isAvailable, isAuthorizedForBackgroundSession, session == nil else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .flexibility
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            isStopping = false
            hasStartedActivity = false

            session.prepare()
        } catch {
            self.session = nil
            self.builder = nil
        }
    }

    func startIfAvailable() {
        guard let session, let builder, session.state == .prepared else { return }

        let startDate = Date()
        session.startActivity(with: startDate)
        builder.beginCollection(withStart: startDate) { _, _ in }
        hasStartedActivity = true
    }

    func stop() {
        onSessionPaused = nil
        guard let session else { return }
        guard !isStopping else { return }

        isStopping = true
        if hasStartedActivity {
            session.stopActivity(with: Date())
        } else {
            session.end()
        }
    }

    private func finishStopping(at endDate: Date) {
        guard let builder, let session else {
            reset()
            return
        }

        builder.endCollection(withEnd: endDate) { [weak self] _, _ in
            guard let self else { return }
            builder.discardWorkout()
            session.end()
            Task { @MainActor in
                self.reset()
            }
        }
    }

    private func reset() {
        session = nil
        builder = nil
        isStopping = false
        hasStartedActivity = false
    }
}

extension WorkoutSessionController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        switch toState {
        case .stopped:
            Task { @MainActor in self.finishStopping(at: date) }
        case .ended:
            Task { @MainActor in self.reset() }
        case .paused:
            Task { @MainActor in self.onSessionPaused?() }
        default:
            break
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.reset()
        }
    }
}

extension WorkoutSessionController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {}
}

enum WorkoutSessionError: LocalizedError {
    case unavailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit workout sessions are not available on this device."
        case .authorizationDenied:
            return "Workout permission is required to keep the session active in the background."
        }
    }
}
