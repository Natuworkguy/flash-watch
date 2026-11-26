import SwiftUI
import WatchKit

/// Flash's timers and alarms: each counting down live with its ring, what
/// rings at the top with Stop and Snooze. Only Flash sets them: ask it.
struct ClockView: View {
    @EnvironmentObject private var flash: Flash
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        List {
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            if flash.clock.items.isEmpty {
                Text("No timers or alarms.").foregroundStyle(.secondary)
            }
            ForEach(flash.clock.items) { item in
                ClockRow(item: item, act: act)
            }
            Section {
                Text("Ask Flash to set one: “set a timer for 10 minutes”, “wake me at 6:45”.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Clock")
        .task {
            await flash.refreshClock()
            // Kept fresh while it shows; the rows count the seconds themselves.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await flash.refreshClock()
            }
        }
    }

    private func act(_ action: String, _ extra: [String: Any] = [:]) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await flash.clockAct(action, extra)
                problem = nil
                WKInterfaceDevice.current().play(.click)
            } catch {
                problem = error.localizedDescription
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}

/// One timer or alarm: its ring and time, what it is, and what can be done.
struct ClockRow: View {
    let item: ClockEntry
    let act: (String, [String: Any]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ClockRing(item: item).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    big.font(.title3.monospacedDigit().weight(.semibold))
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                if item.ringing != nil {
                    Button("Snooze") { act("snooze", ["id": item.id]) }.tint(.gray)
                    Button("Stop") { act("stop", ["id": item.id]) }.tint(.orange)
                } else if item.isTimer {
                    Button(item.paused ? "Resume" : "Pause") { act(item.paused ? "resume" : "pause", ["id": item.id]) }
                    Button("+1") { act("add_time", ["id": item.id, "length": "1m"]) }
                    Button(role: .destructive) { act("cancel", ["id": item.id]) } label: { Image(systemName: "xmark") }
                } else {
                    Button(item.on ? "Off" : "On") { act(item.on ? "off" : "on", ["id": item.id]) }
                    Button(role: .destructive) { act("cancel", ["id": item.id]) } label: { Image(systemName: "trash") }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.vertical, 2)
        .listRowBackground(item.ringing != nil ? Color.orange.opacity(0.25) : nil)
    }

    @ViewBuilder private var big: some View {
        if item.ringing != nil {
            Text(item.isTimer ? "0:00" : item.time)
        } else if let span = item.span {
            Text(timerInterval: span, countsDown: true)
        } else if item.isTimer {
            Text(ClockSnapshot.clockText(item.remaining))
        } else {
            Text(item.time)
        }
    }

    private var sub: String {
        if item.ringing != nil { return "\(item.title) · ringing" }
        if item.isTimer { return item.paused ? "\(item.title) · paused" : item.title }
        return "\(item.title) · \(item.on ? item.repeatText : "Off")"
    }
}

/// The ring round a timer, filling as it runs, live.
struct ClockRing: View {
    let item: ClockEntry

    var body: some View {
        ZStack {
            if let span = item.span {
                ProgressView(timerInterval: span, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(.orange)
            } else {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: item.progress())
                    .stroke(item.ringing != nil ? Color.orange : Color.orange.opacity(item.isTimer ? 1 : 0.6),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: item.isTimer ? "timer" : "alarm")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Over everything while something rings: what it is, big, and Stop and
/// Snooze; the wrist taps until one is pressed.
struct RingingView: View {
    @EnvironmentObject private var flash: Flash
    @State private var pulse = false

    var body: some View {
        if let item = flash.clock.ringing.first {
            VStack(spacing: 10) {
                Image(systemName: item.isTimer ? "timer" : "alarm.waves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.orange)
                    .scaleEffect(pulse ? 1.12 : 0.94)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: pulse)
                Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(item.isTimer ? "Time's up" : item.time).font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Snooze") { act("snooze", item) }.tint(.gray)
                    Button("Stop") { act("stop", item) }.tint(.orange)
                }
                .buttonStyle(.borderedProminent)
            }
            .onAppear { pulse = true }
            .task(id: item.id) {
                // A tap on the wrist every couple of seconds until it is answered.
                while !Task.isCancelled {
                    WKInterfaceDevice.current().play(.notification)
                    try? await Task.sleep(for: .seconds(2.2))
                }
            }
        }
    }

    private func act(_ what: String, _ item: ClockEntry) {
        Task { try? await flash.clockAct(what, ["id": item.id]) }
    }
}
