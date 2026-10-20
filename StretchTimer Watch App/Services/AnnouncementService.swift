import AVFoundation
import WatchKit

@MainActor
final class AnnouncementService {
    private let synthesizer = AVSpeechSynthesizer()
    private var isWarmedUp = false

    /// Warm up the speech synthesizer to avoid delays on first announcement
    func warmUp() {
        #if !targetEnvironment(simulator)
        guard !isWarmedUp else { return }

        // Configure audio session early
        configureAudioSessionIfNeeded()

        // Speak a silent utterance to initialize the synthesizer
        let warmupUtterance = AVSpeechUtterance(string: " ")
        warmupUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
        warmupUtterance.volume = 0.0 // Silent
        synthesizer.speak(warmupUtterance)

        isWarmedUp = true
        #endif
    }

    func announce(_ text: String, volume: Float = 1.0) {
        #if !targetEnvironment(simulator)
        guard !text.isEmpty else { return }
        configureAudioSessionIfNeeded()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = max(0.0, min(volume, 1.0))
        synthesizer.speak(utterance)
        #endif
    }

    func playPhaseTransitionHaptic(for completedPhase: TimerPhase) {
        let haptic: WKHapticType = (completedPhase == .hold) ? .directionUp : .directionDown
        WKInterfaceDevice.current().play(haptic)
    }

    func playSessionCompleteHaptic() {
        WKInterfaceDevice.current().play(.success)
    }

    func playStartCountdownHaptic() {
        WKInterfaceDevice.current().play(.directionDown)
    }

    func playStartCountdownCompletionHaptic() {
        WKInterfaceDevice.current().play(.success)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSessionIfNeeded()
    }

    private func configureAudioSessionIfNeeded() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            // Keep running without voice if category setup fails.
            return
        }
        // Use the async activate API to avoid blocking the main thread.
        audioSession.activate(options: []) { _, _ in }
    }

    private func deactivateAudioSessionIfNeeded() {
        Task.detached {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                // Ignore deactivation failures; the next announcement will reactivate the session.
            }
        }
    }
}
