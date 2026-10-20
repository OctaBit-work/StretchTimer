import SwiftUI
import WidgetKit
import RelevanceKit

struct StretchTimerSessionEntry: TimelineEntry {
    let date: Date
    let isActive: Bool
    let phaseTitle: String
    let sessionEndDate: Date?
}

struct StretchTimerSessionProvider: TimelineProvider {
    func placeholder(in context: Context) -> StretchTimerSessionEntry {
        StretchTimerSessionEntry(
            date: .now,
            isActive: true,
            phaseTitle: "Holding",
            sessionEndDate: Date().addingTimeInterval(390)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (StretchTimerSessionEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StretchTimerSessionEntry>) -> Void) {
        let entry = currentEntry()
        let policy: TimelineReloadPolicy

        if let endDate = entry.sessionEndDate, entry.isActive {
            policy = .after(endDate)
        } else {
            policy = .never
        }

        completion(Timeline(entries: [entry], policy: policy))
    }

    func relevance() async -> WidgetRelevance<Void> {
        let snapshot = WidgetSessionSnapshot.load()
        guard snapshot.isActive, let endDate = snapshot.sessionEndDate, endDate > .now else {
            return WidgetRelevance([])
        }

        let context = RelevantContext.date(
            interval: DateInterval(start: .now, end: endDate),
            kind: .scheduled
        )
        return WidgetRelevance([WidgetRelevanceAttribute(context: context)])
    }

    private func currentEntry() -> StretchTimerSessionEntry {
        let snapshot = WidgetSessionSnapshot.load()
        return StretchTimerSessionEntry(
            date: .now,
            isActive: snapshot.isActive,
            phaseTitle: snapshot.phaseTitle,
            sessionEndDate: snapshot.sessionEndDate
        )
    }
}

struct StretchTimerSessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "work.OctaBit.StretchTimer.session",
            provider: StretchTimerSessionProvider()
        ) { entry in
            StretchTimerSessionWidgetView(entry: entry)
        }
        .configurationDisplayName("StretchTimer")
        .description("Open StretchTimer and glance at the current session.")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct StretchTimerSessionWidgetView: View {
    let entry: StretchTimerSessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.isActive ? entry.phaseTitle : "StretchTimer")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let sessionEndDate = entry.sessionEndDate, entry.isActive {
                Text(sessionEndDate, style: .timer)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
            } else {
                Text("Ready")
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color.black
        }
    }
}

private struct WidgetSessionSnapshot {
    let isActive: Bool
    let phaseTitle: String
    let sessionEndDate: Date?

    static func load() -> WidgetSessionSnapshot {
        guard let defaults = UserDefaults(suiteName: "group.work.OctaBit.StretchTimer") else {
            return WidgetSessionSnapshot(isActive: false, phaseTitle: "StretchTimer", sessionEndDate: nil)
        }

        let isActive = defaults.bool(forKey: "shared.isSessionActive")
        let phaseRawValue = defaults.string(forKey: "shared.currentPhase") ?? ""
        let phaseTitle: String

        switch phaseRawValue {
        case "hold":
            phaseTitle = "Holding"
        case "shift":
            phaseTitle = "Shifting"
        default:
            phaseTitle = "StretchTimer"
        }

        let sessionEndDate = defaults.object(forKey: "shared.sessionEndDate") as? Date
        return WidgetSessionSnapshot(isActive: isActive, phaseTitle: phaseTitle, sessionEndDate: sessionEndDate)
    }
}
