import Foundation

/// Flash's timers and alarms as the watch last heard them: what the app's
/// Clock page shows, what rings on the wrist, and what the widget on the
/// watch face counts down. The app writes it to the app group whenever
/// Flash's clock changes; the widget only reads it, and counts the seconds
/// itself, so it stays live with nothing fetched.
struct ClockEntry: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var kind: String            // "timer" or "alarm"
    var title: String
    var length: Double          // a timer's full length, in seconds
    var ends: Date?             // a running timer's end
    var remaining: Double       // a paused timer's time left
    var paused: Bool
    var ringing: Date?          // since when, while it rings
    var time: String            // an alarm's "07:30"
    var repeatText: String      // an alarm's "Weekdays"
    var on: Bool
    var due: Date?              // when it rings next, if it will

    var isTimer: Bool { kind == "timer" }

    /// How far through a timer is at NOW, 0 to 1.
    func progress(at now: Date = .now) -> Double {
        guard isTimer else { return on ? 1 : 0 }
        if ringing != nil { return 1 }
        let left = paused ? remaining : max(0, (ends ?? now).timeIntervalSince(now))
        return max(0, min(1, 1 - left / max(1, length)))
    }

    /// The span a live countdown runs over, for Text(timerInterval:) and
    /// ProgressView(timerInterval:): from where a full timer would have
    /// started to its end.
    var span: ClosedRange<Date>? {
        guard isTimer, !paused, ringing == nil, let ends else { return nil }
        return ends.addingTimeInterval(-max(1, length))...ends
    }
}

struct ClockSnapshot: Codable, Equatable {
    var items: [ClockEntry] = []
    var saved: Date = .distantPast

    var ringing: [ClockEntry] { items.filter { $0.ringing != nil } }
    /// The one a glance cares about: whatever rings, else the timer that
    /// ends soonest, else the next alarm.
    var lead: ClockEntry? {
        ringing.first
            ?? items.filter { $0.isTimer && !$0.paused }.min { ($0.ends ?? .distantFuture) < ($1.ends ?? .distantFuture) }
            ?? items.first { $0.isTimer }
            ?? items.filter { !$0.isTimer && $0.on }.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    // ----- kept in the app group, so the widget can read it -----
    static let key = "clock"

    static var store: UserDefaults {
        let group = Bundle.main.object(forInfoDictionaryKey: "FlashAppGroup") as? String ?? ""
        return UserDefaults(suiteName: group.isEmpty ? nil : group) ?? .standard
    }

    static func load() -> ClockSnapshot {
        guard let data = store.data(forKey: key),
              let found = try? JSONDecoder().decode(ClockSnapshot.self, from: data) else { return ClockSnapshot() }
        return found
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Self.store.set(data, forKey: Self.key)
        }
    }

    /// "4:05", "1:02:30".
    static func clockText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
