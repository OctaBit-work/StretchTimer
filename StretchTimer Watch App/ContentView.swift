import SwiftUI
import UserNotifications

private enum OnboardingChoice {
    case alertsOnly
    case healthKit
}

struct ContentView: View {
    @StateObject private var viewModel = TimerViewModel()
    @State private var hasTouchedSettings = false
    @State private var appliedRecommendedDefaults = false
    @State private var crownDetent: Int = 0
    @State private var isCrownAccessoryVisible = false
    @FocusState private var crownFocused: Bool
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var showNotificationsExplainer = false
    @State private var pendingChoice: OnboardingChoice? = nil
    @State private var healthKitErrorMessage: String?
    // Set by the hidden layout probe in mainScreen: the roomiest preset that
    // fits, and how tall that preset is with every gap at its minimum.
    @State private var fittedPreset: LayoutPreset = .comfortable
    @State private var fittedNaturalHeight: CGFloat = 0

    // Dynamic Type multiplier for the −/+ glyphs: 1.0 at the watch's "Large"
    // text size, below 1 at smaller sizes, above 1 at larger ones. Each preset
    // multiplies its stepperIconSize by this, then caps it at stepperMaxIconSize.
    @ScaledMetric(relativeTo: .headline) private var stepperIconScale: CGFloat = 1

    // MARK: - Layout tuning (main screen)
    //
    // Screen-level knobs. Per-preset sizes and minimum gaps are in
    // SettingsLayoutMetrics below. All values are in points (pt); for scale,
    // the SE 40mm screen is 162 × 197 pt and the Ultra 49mm is 211 × 257 pt.

    /// Space kept free above the physical bottom edge so the Announce row
    /// stays clear of the rounded corners. Range 0–16. Larger lifts the whole
    /// layout and leaves less room, so smaller watches fall back to tighter
    /// presets sooner.
    private static let bottomMargin: CGFloat = 8

    /// Left/right inset of the whole screen. Range 4–16. Larger narrows the
    /// Hold/Shift rows, so the titles move above their buttons (stacked
    /// layout) at smaller text sizes.
    private static let screenHorizontalPadding: CGFloat = 10

    /// How leftover height (screen taller than the layout needs) is shared.
    /// The gaps timer → Hold/Shift and Shift → Announce each get 1 share; the
    /// space above the timer and below Announce get these fractions of a share.
    ///   0   = no extra there.
    ///   0.5 = half a gap.
    ///   1   = the same as a gap between controls.
    /// The top already has the clock row above it, so the defaults (top 0,
    /// bottom 1) start the timer right under the clock and put the leftover
    /// below; that reads as centered on the physical screen. Raise the top
    /// weight to move everything down, or lower the bottom weight to push the
    /// Announce row toward the bottom edge. Range 0–2 each.
    private static let leftoverTopWeight: CGFloat = 0.25
    private static let leftoverBottomWeight: CGFloat = 1

    /// Fraction of leftover height spent enlarging the − and + buttons before
    /// the rest goes to the gaps above. Range 0–1: 0 = all to spacing, 1 = all
    /// to the buttons (until they reach maxStepperTapTarget). On a Series 12
    /// 46mm at the default text size about 20pt are left over.
    private static let leftoverForControls: CGFloat = 0.6

    /// Largest − / + tap area that leftover height can grow them to. Range
    /// 34–60; 44 is Apple's recommended size.
    private static let maxStepperTapTarget: CGFloat = 56

    /// How much the visible − / + circle grows per point of tap-area growth.
    /// Range 0–1: 0 = only the invisible tap area grows, 1 = the circle grows
    /// as fast as the tap area.
    private static let stepperIconGrowthPerPoint: CGFloat = 0.8

    private let minVolume: Double = 0.1
    private let maxVolume: Double = 1.0
    private let volumeStep: Double = 0.05

    var body: some View {
        if viewModel.isCompletingOnboarding {
            onboardingProgressScreen
        } else if viewModel.needsOnboarding {
            welcomeScreen
        } else {
            mainScreen
                .onAppear {
                    if !appliedRecommendedDefaults && !viewModel.isRunning {
                        viewModel.updateHoldSeconds(20)
                        viewModel.updateShiftSeconds(10)
                        appliedRecommendedDefaults = true
                    }
                }
        }
    }

    private var onboardingProgressScreen: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Setting up StretchTimer")
                .font(.headline)
            Text("Finishing permissions and saving your choice.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }

    private var welcomeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose your setup")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)

                // Enable HealthKit option
                VStack(alignment: .leading, spacing: 6) {
                    Button("Enable HealthKit") {
                        pendingChoice = .healthKit
                        showNotificationsExplainer = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Enable HealthKit")
                    .accessibilityHint("Enable background running and Smart Stack using workout permission only.")

                    Text("...only to keep sessions active and visible in Smart Stack.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Alerts Only option
                VStack(alignment: .leading, spacing: 6) {
                    Button("Alerts Only") {
                        pendingChoice = .alertsOnly
                        showNotificationsExplainer = true
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Alerts Only")
                    .accessibilityHint("Use the app without HealthKit. You can enable it later.")

                    Text("Use the app without HealthKit. You can turn it on later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .sheet(isPresented: $showNotificationsExplainer) {
            NotificationsExplainerView(
                onAllow: {
                    requestNotificationAuthorization { _ in
                        proceedAfterExplainer()
                    }
                },
                onNotNow: {
                    proceedAfterExplainer()
                }
            )
        }
        .alert("HealthKit Permission Needed", item: $healthKitErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // Size presets, roomiest first. The hidden probe in mainScreen picks the
    // first one whose layout fits the screen with every gap at its minimum, so
    // big watches at normal text get .spacious and the SE at the largest text
    // falls through to .minimal. Leftover height is then shared out as set by
    // leftoverTopWeight/leftoverBottomWeight above.
    // Keep each preset's values less than or equal to the one before it, or a
    // roomier preset can be skipped for a tighter one.
    private enum LayoutPreset: CaseIterable {
        case spacious, comfortable, compact, tight, minimal

        var metrics: SettingsLayoutMetrics {
            switch self {
            case .spacious: return .spacious
            case .comfortable: return .comfortable
            case .compact: return .compact
            case .tight: return .tight
            case .minimal: return .minimal
            }
        }
    }

    // One preset's sizes, in points. "Minimum" gaps can grow when the screen has
    // leftover height; everything else is fixed for the preset.
    private struct SettingsLayoutMetrics {
        /// Minimum gap between the timer button and the Hold row. Range 0–16.
        var screenSpacing: CGFloat
        /// Minimum space above the timer button and below the Announce row. Range 0–12.
        var screenVerticalPadding: CGFloat
        /// Padding inside the timer button above "6:30" and below "START";
        /// sets the button's height. Range 2–20.
        var timerButtonVerticalPadding: CGFloat
        /// Minimum gap between the Shift row and the Announce row. Range 0–12.
        var panelSpacing: CGFloat
        /// Inset around the Hold/Shift/Announce group, all four sides. Range 0–12.
        var panelPadding: CGFloat
        /// Side-by-side rows ("Hold  −  20s  +"): gap between the title and
        /// the − button. Range 0–8.
        var gridHorizontalSpacing: CGFloat
        /// Side-by-side rows: gap between the Hold and Shift rows. Range 0–12.
        var gridVerticalSpacing: CGFloat
        /// Stacked rows (title above its buttons, used when the title won't
        /// fit beside them): gap between the Hold and Shift blocks. Range 0–12.
        var stackedRowSpacing: CGFloat
        /// Stacked rows: gap between a title and its −/+ row. Range 0–6.
        var stackedTitleSpacing: CGFloat
        /// Gap between −, the value and + within a row. Range 2–8; keep at
        /// least 4 so neighboring tap areas don't touch.
        var controlsSpacing: CGFloat
        /// Tappable square around each − and + (larger than the visible
        /// circle). Range 28–52: Apple's minimum is 28, recommended is 44.
        var stepperTapTarget: CGFloat
        /// Diameter of the − and + circles at the "Large" text size; scaled by
        /// stepperIconScale for other text sizes. Range 16–34.
        var stepperIconSize: CGFloat
        /// Largest the − and + circles can grow at big text sizes. Keep it at
        /// or above stepperIconSize and at or below stepperTapTarget.
        var stepperMaxIconSize: CGFloat
        /// Announce/Alert switch size: .mini, .small, .regular, .large or
        /// .extraLarge. On the watchOS 27.2 simulator the switch graphic
        /// looked the same at every size; the label follows Dynamic Type.
        var toggleControlSize: ControlSize

        /// This preset with the − and + tap areas `points` larger and their
        /// circles grown by stepperIconGrowthPerPoint per point.
        func growingSteppers(by points: CGFloat, iconGrowthPerPoint: CGFloat) -> SettingsLayoutMetrics {
            var grown = self
            grown.stepperTapTarget += points
            grown.stepperIconSize += points * iconGrowthPerPoint
            grown.stepperMaxIconSize += points * iconGrowthPerPoint
            return grown
        }

        // The presets share the same small minimum gaps and differ mainly in
        // control size (timer button height, −/+ size), so the largest
        // controls that fit are chosen first and only what's left over is
        // added to the gaps. .minimal also squeezes the gaps for the SE at
        // large text sizes.
        static let spacious = SettingsLayoutMetrics(
            screenSpacing: 4,
            screenVerticalPadding: 2,
            timerButtonVerticalPadding: 12,
            panelSpacing: 4,
            panelPadding: 4,
            gridHorizontalSpacing: 4,
            gridVerticalSpacing: 4,
            stackedRowSpacing: 4,
            stackedTitleSpacing: 2,
            controlsSpacing: 6,
            stepperTapTarget: 48,
            stepperIconSize: 28,
            stepperMaxIconSize: 34,
            toggleControlSize: .large
        )

        static let comfortable = SettingsLayoutMetrics(
            screenSpacing: 4,
            screenVerticalPadding: 2,
            timerButtonVerticalPadding: 10,
            panelSpacing: 4,
            panelPadding: 4,
            gridHorizontalSpacing: 4,
            gridVerticalSpacing: 4,
            stackedRowSpacing: 4,
            stackedTitleSpacing: 2,
            controlsSpacing: 6,
            stepperTapTarget: 44,
            stepperIconSize: 26,
            stepperMaxIconSize: 30,
            toggleControlSize: .large
        )

        static let compact = SettingsLayoutMetrics(
            screenSpacing: 4,
            screenVerticalPadding: 2,
            timerButtonVerticalPadding: 8,
            panelSpacing: 4,
            panelPadding: 4,
            gridHorizontalSpacing: 4,
            gridVerticalSpacing: 4,
            stackedRowSpacing: 4,
            stackedTitleSpacing: 2,
            controlsSpacing: 6,
            stepperTapTarget: 40,
            stepperIconSize: 24,
            stepperMaxIconSize: 28,
            toggleControlSize: .regular
        )

        static let tight = SettingsLayoutMetrics(
            screenSpacing: 4,
            screenVerticalPadding: 2,
            timerButtonVerticalPadding: 6,
            panelSpacing: 4,
            panelPadding: 4,
            gridHorizontalSpacing: 4,
            gridVerticalSpacing: 4,
            stackedRowSpacing: 4,
            stackedTitleSpacing: 2,
            controlsSpacing: 6,
            stepperTapTarget: 34,
            stepperIconSize: 22,
            stepperMaxIconSize: 24,
            toggleControlSize: .regular
        )

        static let minimal = SettingsLayoutMetrics(
            screenSpacing: 1,
            screenVerticalPadding: 0,
            timerButtonVerticalPadding: 2,
            panelSpacing: 1,
            panelPadding: 3,
            gridHorizontalSpacing: 2,
            gridVerticalSpacing: 1,
            stackedRowSpacing: 1,
            stackedTitleSpacing: 0,
            controlsSpacing: 4,
            stepperTapTarget: 30,
            stepperIconSize: 20,
            stepperMaxIconSize: 22,
            toggleControlSize: .regular
        )
    }

    private var mainScreen: some View {
        ZStack {
            GeometryReader { proxy in
                // Height from just below the clock to bottomMargin above the
                // physical bottom edge (see .ignoresSafeArea below).
                let usableHeight = max(0, proxy.size.height - Self.bottomMargin)
                ZStack(alignment: .top) {
                    // Hidden, non-interactive copy used only for measuring:
                    // ViewThatFits picks the roomiest preset that fits, and that
                    // preset reports its minimum-gap height (presetProbe). The
                    // visible layout below then adds the leftover height to its
                    // gaps. (ViewThatFits always draws its pick at that minimum
                    // height, so it can't spread the gaps itself.)
                    ViewThatFits(in: .vertical) {
                        presetProbe(.spacious)
                        presetProbe(.comfortable)
                        presetProbe(.compact)
                        presetProbe(.tight)
                        presetProbe(.minimal)
                    }
                    .hidden()
                    // Pinned to the screen so an overflowing pick can't grow the ZStack.
                    .frame(width: proxy.size.width, height: usableHeight, alignment: .top)

                    // When a preset fits, its gaps add up to exactly this height.
                    // If even .minimal is too tall (SE at the largest text),
                    // centering splits the overflow between the clock area and
                    // the bottom edge, as the original layout did.
                    screenBody(
                        metrics: fittedPreset.metrics,
                        leftover: max(0, usableHeight - fittedNaturalHeight)
                    )
                    .frame(height: usableHeight)
                }
            }
            // watchOS reserves a deep bottom safe area (about 40pt on large
            // watches) for the rounded corners. These full-width rows stay
            // clear of the corners, so measure to the physical bottom edge
            // instead; bottomMargin keeps a little room. The top safe area is
            // kept so nothing sits under the clock.
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                syncCrownValue()
                viewModel.updateDisplayDimmed(isLuminanceReduced)
            }
            .onChange(of: viewModel.isRunning) { _, _ in
                syncCrownValue()
                isCrownAccessoryVisible = false
            }
            .onChange(of: isLuminanceReduced) { _, _ in
                viewModel.updateDisplayDimmed(isLuminanceReduced)
            }
            .onChange(of: viewModel.totalDurationSeconds) { _, _ in
                if !viewModel.isRunning {
                    syncCrownValue()
                }
            }
            .onChange(of: viewModel.sessionVolume) { _, _ in
                if viewModel.isRunning {
                    syncCrownValue()
                }
            }

            // Shown once per launch, before the defaults applied in body's
            // .onAppear have been touched — purely informational, so a single
            // tap anywhere dismisses it rather than requiring a choice.
            if shouldShowRecommendationOverlay {
                RecommendedSetView(onDismiss: { hasTouchedSettings = true })
            }
        }
    }

    // The main screen for one preset. `leftover` is extra height beyond the
    // preset's minimum-gap layout (0 when measuring). leftoverForControls of it
    // enlarges the − and + buttons; the rest is shared between the two gaps
    // between controls and the space above/below per the leftover*Weight
    // constants.
    private func screenBody(metrics baseMetrics: SettingsLayoutMetrics, leftover: CGFloat = 0, isProbe: Bool = false) -> some View {
        let gapCount: CGFloat = isSettingsPanelVisible ? 2 : 0

        // Two stepper rows, so each point of tap-area growth costs 2pt of height.
        let stepperRoom = max(0, Self.maxStepperTapTarget - baseMetrics.stepperTapTarget)
        let stepperGrowth = gapCount > 0 ? min(leftover * Self.leftoverForControls / 2, stepperRoom) : 0
        let metrics = baseMetrics.growingSteppers(by: stepperGrowth, iconGrowthPerPoint: Self.stepperIconGrowthPerPoint)

        let spacingLeftover = leftover - stepperGrowth * 2
        let shares = gapCount + Self.leftoverTopWeight + Self.leftoverBottomWeight
        // With no gaps and zero edge weights there's nowhere to put leftover;
        // the .frame in mainScreen then centers the timer on its own.
        let share = shares > 0 ? spacingLeftover / shares : 0

        return VStack(spacing: 0) {
            crownHost(metrics: metrics, isProbe: isProbe)
            if isSettingsPanelVisible {
                Color.clear.frame(height: metrics.screenSpacing + share)
                settingsPanel(metrics: metrics, extraGap: share)
            }
        }
        .padding(.horizontal, Self.screenHorizontalPadding)
        .padding(.top, metrics.screenVerticalPadding + share * Self.leftoverTopWeight)
        .padding(.bottom, metrics.screenVerticalPadding + share * Self.leftoverBottomWeight)
    }

    // Measuring copy of screenBody for the hidden ViewThatFits. Only the
    // preset ViewThatFits picks is laid out, so only it reports its height.
    private func presetProbe(_ preset: LayoutPreset) -> some View {
        screenBody(metrics: preset.metrics, isProbe: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                fittedPreset = preset
                fittedNaturalHeight = height
            }
    }

    @ViewBuilder
    private func crownHost(metrics: SettingsLayoutMetrics, isProbe: Bool) -> some View {
        if isProbe {
            // Layout-only copy: no focus or Digital Crown handling to compete
            // with the visible layout.
            timerActionButton(metrics: metrics)
        } else {
            interactiveCrownHost(metrics: metrics)
        }
    }

    private func interactiveCrownHost(metrics: SettingsLayoutMetrics) -> some View {
        timerActionButton(metrics: metrics)
            .contentShape(Rectangle())
            .focusable(true)
            .focused($crownFocused)
            .digitalCrownRotation(
                detent: $crownDetent,
                from: 0,
                through: viewModel.isRunning ? maxVolumeSteps : maxDurationSteps,
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            ) { _ in
                isCrownAccessoryVisible = viewModel.isRunning
                if viewModel.isRunning {
                    let volume = minVolume + (Double(crownDetent) * volumeStep)
                    viewModel.updateSessionVolume(Float(clamp(volume, minVolume, maxVolume)))
                } else {
                    let seconds = TimerViewModel.minTotalSeconds + crownDetent * TimerViewModel.totalStepSeconds
                    viewModel.updateTotalDurationSeconds(clamp(seconds, TimerViewModel.minTotalSeconds, TimerViewModel.maxTotalSeconds))
                }
            } onIdle: {
                isCrownAccessoryVisible = false
                syncCrownValue()
            }
            .digitalCrownAccessory {
                if viewModel.isRunning && isCrownAccessoryVisible {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                }
            }
            .onAppear {
                crownFocused = true
            }
            .onTapGesture {
                crownFocused = true
            }
    }

    @ViewBuilder
    private func timerActionButton(metrics: SettingsLayoutMetrics) -> some View {
        if viewModel.isRunning && isLuminanceReduced {
            TimelineView(ExplicitTimelineSchedule(viewModel.dimmedTimelineDates)) { context in
                timerButton(displayDate: context.date, metrics: metrics)
            }
        } else {
            timerButton(displayDate: nil, metrics: metrics)
        }
    }

    private func timerButton(displayDate: Date?, metrics: SettingsLayoutMetrics) -> some View {
        Button {
            if viewModel.isRunning || viewModel.isPreparingStart {
                viewModel.stop()
            } else {
                viewModel.start()
            }
        } label: {
            timerButtonLabel(displayDate: displayDate)
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.timerButtonVerticalPadding)
        }
        .buttonStyle(.plain)
        .foregroundStyle(timerButtonColor)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(timerButtonColor.opacity(0.14))
        )
        .overlay(timerButtonOverlay(displayDate: displayDate))
    }

    @ViewBuilder
    private func timerButtonLabel(displayDate: Date?) -> some View {
        if viewModel.isPreparingStart {
            VStack(spacing: 4) {
                Text("\(viewModel.startCountdownValue)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text("GET READY")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        } else
        if let displayDate, viewModel.isRunning && isLuminanceReduced {
            VStack(spacing: 4) {
                Spacer(minLength: 12)
                Text(dimmedPhaseLabel(at: displayDate))
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer(minLength: 12)
            }
        } else {
            VStack(spacing: 4) {
                Text(formatted(seconds: viewModel.isRunning ? viewModel.remainingSeconds : viewModel.totalDisplaySeconds))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if viewModel.isRunning {
                    Text(viewModel.currentPhase == .hold ? "HOLD" : "SHIFT")
                        .font(.caption)
                        .fontWeight(.semibold)
                } else {
                    Text("START")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func timerButtonOverlay(displayDate: Date?) -> some View {
        if viewModel.isRunning {
            let progress = progressForDisplay(at: displayDate)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.red, lineWidth: 6)
                ProgressRoundedRect(progress: progress, cornerRadius: 18)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    .animation(isLuminanceReduced ? nil : .linear(duration: 0.2), value: progress)
            }
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(timerButtonColor, lineWidth: 6)
        }
    }

    private var timerButtonColor: Color {
        if viewModel.isPreparingStart {
            return .orange
        }
        return viewModel.isRunning ? .red : .green
    }

    // Hold/Shift rows and the Announce switch. `extraGap` is this layout's share
    // of leftover height, added between the Shift row and the switch.
    private func settingsPanel(metrics: SettingsLayoutMetrics, extraGap: CGFloat) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .leading, horizontalSpacing: metrics.gridHorizontalSpacing, verticalSpacing: metrics.gridVerticalSpacing) {
                    durationGridRow(
                        title: "Hold",
                        value: viewModel.holdSeconds,
                        decrement: viewModel.decrementHold,
                        increment: viewModel.incrementHold,
                        metrics: metrics
                    )

                    durationGridRow(
                        title: "Shift",
                        value: viewModel.shiftSeconds,
                        decrement: viewModel.decrementShift,
                        increment: viewModel.incrementShift,
                        metrics: metrics
                    )
                }

                VStack(spacing: metrics.stackedRowSpacing) {
                    durationStackedRow(
                        title: "Hold",
                        value: viewModel.holdSeconds,
                        decrement: viewModel.decrementHold,
                        increment: viewModel.incrementHold,
                        metrics: metrics
                    )

                    durationStackedRow(
                        title: "Shift",
                        value: viewModel.shiftSeconds,
                        decrement: viewModel.decrementShift,
                        increment: viewModel.incrementShift,
                        metrics: metrics
                    )
                }
            }

            Color.clear.frame(height: metrics.panelSpacing + extraGap)

            // Same text style and shrink limit as the Hold/Shift titles.
            Toggle(viewModel.announcementsEnabled ? "Announce" : "Alert", isOn: announcementsBinding)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .controlSize(metrics.toggleControlSize)
                .disabled(viewModel.isRunning)

        }
        .padding(metrics.panelPadding)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shouldShowRecommendationOverlay: Bool {
        !hasTouchedSettings && !viewModel.isRunning
    }

    private var isSettingsPanelVisible: Bool {
        !shouldHideControlsForReducedLuminance && !viewModel.isPreparingStart
    }

    private var shouldHideControlsForReducedLuminance: Bool {
        viewModel.isRunning && isLuminanceReduced
    }

    private func durationGridRow(
        title: String,
        value: Int,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void,
        metrics: SettingsLayoutMetrics
    ) -> some View {
        GridRow {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            durationControls(value: value, decrement: decrement, increment: increment, metrics: metrics)
        }
    }

    private func durationStackedRow(
        title: String,
        value: Int,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void,
        metrics: SettingsLayoutMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.stackedTitleSpacing) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            durationControls(value: value, decrement: decrement, increment: increment, metrics: metrics)
        }
    }

    private func durationControls(
        value: Int,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void,
        metrics: SettingsLayoutMetrics
    ) -> some View {
        HStack(spacing: metrics.controlsSpacing) {
            Button(action: decrement) {
                stepperIcon("minus.circle.fill", metrics: metrics)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRunning || value <= TimerSettings.minSeconds)

            Text("\(value)s")
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)

            Button(action: increment) {
                stepperIcon("plus.circle.fill", metrics: metrics)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRunning || value >= TimerSettings.maxSeconds)
        }
    }

    // One − or + button face. The circle is stepperIconSize × stepperIconScale
    // (capped at stepperMaxIconSize); the frame + contentShape make the whole
    // stepperTapTarget square tappable, not just the circle.
    private func stepperIcon(_ systemName: String, metrics: SettingsLayoutMetrics) -> some View {
        Image(systemName: systemName)
            .font(.system(size: min(metrics.stepperIconSize * stepperIconScale, metrics.stepperMaxIconSize)))
            .frame(minWidth: metrics.stepperTapTarget, minHeight: metrics.stepperTapTarget)
            .contentShape(Rectangle())
    }

    private var announcementsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.announcementsEnabled },
            set: { viewModel.updateAnnouncementsEnabled($0) }
        )
    }

    private func syncCrownValue() {
        if viewModel.isRunning {
            let steps = ((Double(viewModel.sessionVolume) - minVolume) / volumeStep).rounded()
            crownDetent = clamp(Int(steps), 0, maxVolumeSteps)
        } else {
            let steps = (viewModel.totalDurationSeconds - TimerViewModel.minTotalSeconds) / TimerViewModel.totalStepSeconds
            crownDetent = clamp(steps, 0, maxDurationSteps)
        }
    }

    private var maxDurationSteps: Int {
        (TimerViewModel.maxTotalSeconds - TimerViewModel.minTotalSeconds) / TimerViewModel.totalStepSeconds
    }

    private var maxVolumeSteps: Int {
        Int(((maxVolume - minVolume) / volumeStep).rounded())
    }

    private func clamp<T: Comparable>(_ value: T, _ minValue: T, _ maxValue: T) -> T {
        min(max(value, minValue), maxValue)
    }

    private var elapsedFraction: CGFloat {
        let total = max(1, viewModel.totalDurationSeconds)
        let remaining = viewModel.totalRemainingSeconds
        let fraction = 1.0 - (Double(remaining) / Double(total))
        return CGFloat(max(0.0, min(1.0, fraction)))
    }

    private func progressForDisplay(at displayDate: Date?) -> CGFloat {
        if let displayDate, isLuminanceReduced, viewModel.isRunning {
            return viewModel.elapsedFraction(at: displayDate)
        }
        return elapsedFraction
    }

    private func formatted(seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private func dimmedPhaseLabel(at date: Date) -> String {
        switch viewModel.phase(at: date) {
        case .hold:
            return "HOLD"
        case .shift:
            return "SHIFT"
        case .none:
            return viewModel.currentPhase == .hold ? "HOLD" : "SHIFT"
        }
    }

    private func requestNotificationAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    private func proceedAfterExplainer() {
        let choice = pendingChoice
        pendingChoice = nil
        showNotificationsExplainer = false

        switch choice {
        case .alertsOnly:
            viewModel.beginOnboardingResolution()
            viewModel.selectBackgroundMode(.alertsOnly)
            viewModel.finishOnboardingResolution()
        case .healthKit:
            viewModel.beginOnboardingResolution()
            Task {
                defer { viewModel.finishOnboardingResolution() }
                do {
                    try await viewModel.enableHealthKitMode()
                } catch {
                    healthKitErrorMessage = error.localizedDescription
                }
            }
        case .none:
            break
        }
    }
}

private struct RecommendedSetView: View {
    var onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Minimum recommended set")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("3 stretches 3x each side")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Hold 20s+ shift 10s")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Tap to continue")
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}

private struct NotificationsExplainerView: View {
    var onAllow: () -> Void
    var onNotNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enable Alerts")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)

                Text("...for interval timer sounds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Allow Alerts", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
    }
}

private struct ProgressRoundedRect: Shape {
    var progress: CGFloat
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let topCenter = CGPoint(x: rect.midX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX - r, y: rect.minY)
        let rightTop = CGPoint(x: rect.maxX, y: rect.minY + r)
        let bottomRight = CGPoint(x: rect.maxX - r, y: rect.maxY)
        let leftBottom = CGPoint(x: rect.minX, y: rect.maxY - r)
        let topLeft = CGPoint(x: rect.minX + r, y: rect.minY)
        let topCenterLeft = CGPoint(x: rect.midX - r, y: rect.minY)

        let arcLength = CGFloat.pi / 2 * r
        let topHalf = rect.width / 2 - r
        let rightSide = rect.height - 2 * r
        let bottomSide = rect.width - 2 * r
        let leftSide = rect.height - 2 * r
        let total = topHalf + arcLength + rightSide + arcLength + bottomSide + arcLength + leftSide + arcLength + topHalf

        var remaining = max(0, min(1, progress)) * total
        var path = Path()
        path.move(to: topCenter)

        func addLine(to point: CGPoint, length: CGFloat) {
            guard remaining > 0 else { return }
            let use = min(remaining, length)
            let t = use / length
            let x = topCenter.x + (point.x - topCenter.x) * t
            let y = topCenter.y + (point.y - topCenter.y) * t
            path.addLine(to: CGPoint(x: x, y: y))
            remaining -= use
        }

        // Top right half
        addLine(to: topRight, length: topHalf)
        if remaining <= 0 { return path }

        // Top-right arc
        let arcUse = min(remaining, arcLength)
        let arcAngle = arcUse / arcLength * CGFloat.pi / 2
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                    radius: r,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + Double(arcAngle * 180 / .pi)),
                    clockwise: false)
        remaining -= arcUse
        if remaining <= 0 { return path }

        // Right side
        let rightUse = min(remaining, rightSide)
        path.addLine(to: CGPoint(x: rect.maxX, y: rightTop.y + rightUse))
        remaining -= rightUse
        if remaining <= 0 { return path }

        // Bottom-right arc
        let arcUse2 = min(remaining, arcLength)
        let arcAngle2 = arcUse2 / arcLength * CGFloat.pi / 2
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                    radius: r,
                    startAngle: .degrees(0),
                    endAngle: .degrees(Double(arcAngle2 * 180 / .pi)),
                    clockwise: false)
        remaining -= arcUse2
        if remaining <= 0 { return path }

        // Bottom side
        let bottomUse = min(remaining, bottomSide)
        path.addLine(to: CGPoint(x: bottomRight.x - bottomUse, y: rect.maxY))
        remaining -= bottomUse
        if remaining <= 0 { return path }

        // Bottom-left arc
        let arcUse3 = min(remaining, arcLength)
        let arcAngle3 = arcUse3 / arcLength * CGFloat.pi / 2
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                    radius: r,
                    startAngle: .degrees(90),
                    endAngle: .degrees(90 + Double(arcAngle3 * 180 / .pi)),
                    clockwise: false)
        remaining -= arcUse3
        if remaining <= 0 { return path }

        // Left side
        let leftUse = min(remaining, leftSide)
        path.addLine(to: CGPoint(x: rect.minX, y: leftBottom.y - leftUse))
        remaining -= leftUse
        if remaining <= 0 { return path }

        // Top-left arc
        let arcUse4 = min(remaining, arcLength)
        let arcAngle4 = arcUse4 / arcLength * CGFloat.pi / 2
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                    radius: r,
                    startAngle: .degrees(180),
                    endAngle: .degrees(180 + Double(arcAngle4 * 180 / .pi)),
                    clockwise: false)
        remaining -= arcUse4
        if remaining <= 0 { return path }

        // Top left half to center
        let topLeftUse = min(remaining, topHalf)
        let t = topLeftUse / topHalf
        let x = topLeft.x + (topCenterLeft.x - topLeft.x) * t
        let y = rect.minY
        path.addLine(to: CGPoint(x: x, y: y))
        return path
    }
}

#Preview {
    ContentView()
}
