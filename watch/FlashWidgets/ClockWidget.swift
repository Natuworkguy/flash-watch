import SwiftUI
import WidgetKit

/// Flash's next timer or alarm on the watch face and in the Smart Stack:
/// a ring that fills as a timer runs, its time counting down live, and
/// "Ringing" while one rings. It reads what the app last heard from Flash
/// and counts the seconds itself, so it stays live without fetching.
@main
struct FlashWidgets: WidgetBundle {
    var body: some Widget {
        ClockWidget()
    }
}

struct ClockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlashClock", provider: ClockProvider()) { entry in
            ClockWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "flashwatch://clock"))
        }
        .configurationDisplayName("Flash timers")
        .description("Your next timer or alarm from Flash, counting down.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct ClockWidgetEntry: TimelineEntry {
    let date: Date
    let lead: ClockEntry?
    let ringingNow: Bool
    let others: Int
    var relevance: TimelineEntryRelevance? {
        // Up the Smart Stack while something runs or rings.
        guard let lead else { return TimelineEntryRelevance(score: 0) }
        if ringingNow { return TimelineEntryRelevance(score: 100) }
        return TimelineEntryRelevance(score: lead.isTimer ? 60 : 10)
    }
}

struct ClockProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClockWidgetEntry {
        let sample = ClockEntry(id: "x", kind: "timer", title: "Pasta", length: 600, ends: .now.addingTimeInterval(372),
                                remaining: 372, paused: false, ringing: nil, time: "", repeatText: "", on: true, due: nil)
        return ClockWidgetEntry(date: .now, lead: sample, ringingNow: false, others: 1)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClockWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries(from: .now).first!)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClockWidgetEntry>) -> Void) {
        let list = entries(from: .now)
        // Back when the next one comes due, or in a quarter of an hour.
        let next = ClockSnapshot.load().items.compactMap(\.due).filter { $0 > .now }.min()
        completion(Timeline(entries: list, policy: .after(next ?? .now.addingTimeInterval(15 * 60))))
    }

    /// Now, and the moment each running one comes due: from then it shows
    /// as ringing, until the app hears it was stopped and starts afresh.
    private func entries(from now: Date) -> [ClockWidgetEntry] {
        let snap = ClockSnapshot.load()
        var out = [ClockWidgetEntry(date: now, lead: snap.lead, ringingNow: !snap.ringing.isEmpty,
                                    others: max(0, snap.items.count - 1))]
        for item in snap.items where item.ringing == nil {
            guard let due = item.due, due > now else { continue }
            var rang = item
            rang.ringing = due
            out.append(ClockWidgetEntry(date: due, lead: rang, ringingNow: true, others: max(0, snap.items.count - 1)))
        }
        return out.sorted { $0.date < $1.date }
    }
}

struct ClockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClockWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: inline
        default: rectangular
        }
    }

    private var symbol: String {
        guard let lead = entry.lead else { return "timer" }
        if entry.ringingNow { return lead.isTimer ? "bell.and.waves.left.and.right" : "alarm.waves.left.and.right" }
        return lead.isTimer ? "timer" : "alarm"
    }

    @ViewBuilder private var circular: some View {
        if let lead = entry.lead {
            if entry.ringingNow {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: symbol).font(.title3).widgetAccentable()
                }
            } else if let span = lead.span {
                ProgressView(timerInterval: span, countsDown: true) {
                    Image(systemName: "timer")
                } currentValueLabel: {
                    Text(timerInterval: span, countsDown: true)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                }
                .progressViewStyle(.circular)
                .widgetAccentable()
            } else {
                Gauge(value: lead.progress(at: entry.date)) {
                    Image(systemName: symbol)
                } currentValueLabel: {
                    Text(lead.isTimer ? ClockSnapshot.clockText(lead.remaining) : lead.time)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "timer").font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let lead = entry.lead {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).widgetAccentable()
                    Text(lead.title).font(.headline).lineLimit(1)
                }
                if entry.ringingNow {
                    Text(lead.isTimer ? "Time's up" : "Ringing, \(lead.time)")
                        .font(.body.weight(.semibold))
                        .widgetAccentable()
                } else if let span = lead.span {
                    Text(timerInterval: span, countsDown: true)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    ProgressView(timerInterval: span, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.linear)
                        .widgetAccentable()
                } else if lead.isTimer {
                    Text("\(ClockSnapshot.clockText(lead.remaining)) · paused")
                        .font(.title3.monospacedDigit().weight(.semibold))
                } else {
                    Text("\(lead.time) · \(lead.repeatText)").font(.body.monospacedDigit())
                }
                if entry.others > 0 && !entry.ringingNow {
                    Text("+\(entry.others) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading) {
                Label("Flash", systemImage: "timer").font(.headline)
                Text("No timers").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var corner: some View {
        Image(systemName: symbol)
            .font(.title3)
            .widgetAccentable()
            .widgetLabel {
                if let lead = entry.lead, let span = lead.span, !entry.ringingNow {
                    ProgressView(timerInterval: span, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                } else if let lead = entry.lead {
                    Text(entry.ringingNow ? "Ringing" : (lead.isTimer ? ClockSnapshot.clockText(lead.remaining) : lead.time))
                } else {
                    Text("No timers")
                }
            }
    }

    @ViewBuilder private var inline: some View {
        if let lead = entry.lead {
            if entry.ringingNow {
                Label("\(lead.title) ringing", systemImage: symbol)
            } else if let span = lead.span {
                Label { Text(timerInterval: span, countsDown: true) } icon: { Image(systemName: symbol) }
            } else {
                Label(lead.isTimer ? ClockSnapshot.clockText(lead.remaining) : lead.time, systemImage: symbol)
            }
        } else {
            Label("No timers", systemImage: "timer")
        }
    }
}
