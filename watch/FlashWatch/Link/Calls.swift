import SwiftUI
import UserNotifications
import WatchKit

/// A spark's call to you, ringing now.
struct Ring: Identifiable, Equatable {
    let team: String
    let call: String
    let spark: String
    let name: String
    let reason: String

    var id: String { call }

    init(_ json: JSON) {
        team = json["team"].string
        call = json["call"].string
        spark = json["spark"].string
        name = json["name"].string.isEmpty ? "A spark" : json["name"].string
        reason = json["reason"].string
    }

    init(team: String, call: String, spark: String, name: String, reason: String) {
        self.team = team
        self.call = call
        self.spark = spark
        self.name = name
        self.reason = reason
    }

    /// What a notification carries, to answer or decline it from there.
    var userInfo: [String: String] {
        ["team": team, "call": call, "spark": spark, "name": name, "reason": reason]
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let team = userInfo["team"] as? String, let call = userInfo["call"] as? String,
              !team.isEmpty, !call.isEmpty else { return nil }
        self.init(team: team, call: call, spark: userInfo["spark"] as? String ?? "",
                  name: userInfo["name"] as? String ?? "A spark",
                  reason: userInfo["reason"] as? String ?? "")
    }
}

/// A call on the watch with a spark: one it placed, or one picked up here.
struct OnCall: Equatable {
    enum Status: Equatable { case connecting, listening, thinking, speaking, ended }

    let team: String
    var call: String
    let spark: String
    let name: String
    /// Why the spark called, for a call it placed.
    let reason: String
    let incoming: Bool
    var status: Status = .connecting
    /// When it connected: the call's clock counts from here.
    var since: Date?
    /// The last thing said, and who said it.
    var caption = ""
    var said = ""
}

/// Sparks calling you, rung on the watch, and the call once picked up.
///
/// While the app is open, the watch asks Flash every few seconds whether
/// a spark is calling, and rings with taps on the wrist until it is
/// answered, declined, or picked up somewhere else. With the app closed,
/// a call that is still ringing when watchOS lets the app look comes as
/// a notification with Answer and Decline.
///
/// On a call, the spark speaks first. You talk by dictation, and each
/// answer is read out in that spark's own voice when the computer has
/// one.
@MainActor
final class Calls: ObservableObject {
    static let shared = Calls()

    @Published private(set) var ringing: Ring?
    @Published private(set) var call: OnCall?

    /// The Flash the app talks to, once it is watching for calls.
    private(set) var flash: Flash?
    /// Calls this watch declined or let ring out: not rung again.
    private var passed: Set<String> = []
    /// One answered from a notification before the app was watching.
    private var wanted: Ring?
    private var buzz: Task<Void, Never>?
    private var beat: Task<Void, Never>?
    private var round: Task<Void, Never>?

    /// How long a spark's call rings before it is missed, as on Flash.
    static let ringSeconds: TimeInterval = 45
    /// How often a call says it is still going.
    private static let beatSeconds: Double = 20

    private init() {}

    var showing: Bool { ringing != nil || call != nil }

    /// Looks for a spark calling, every few seconds, for as long as the
    /// task runs: while the app is open.
    func watch(_ flash: Flash) async {
        self.flash = flash
        while !Task.isCancelled {
            await look(flash)
            try? await Task.sleep(for: .seconds(ringing == nil ? 3 : 1.5))
        }
    }

    private func look(_ flash: Flash) async {
        guard flash.pairing != nil else { return }
        if let wanted {
            self.wanted = nil
            await answer(wanted)
            return
        }
        guard call == nil, let rings = try? await flash.rings() else { return }
        if let now = ringing {
            // Answered somewhere else, declined there, or rung out.
            if !rings.contains(where: { $0.call == now.call }) { stopRinging() }
            return
        }
        if let ring = rings.first(where: { !passed.contains($0.call) }) { startRinging(ring) }
    }

    // Ringing ---------------------------------------------------------

    private func startRinging(_ ring: Ring) {
        ringing = ring
        buzz?.cancel()
        buzz = Task {
            let end = Date().addingTimeInterval(Self.ringSeconds)
            while !Task.isCancelled, Date() < end {
                // A ring: two taps, then quiet, as a phone rings.
                WKInterfaceDevice.current().play(.notification)
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                WKInterfaceDevice.current().play(.directionUp)
                try? await Task.sleep(for: .seconds(2.3))
            }
            if !Task.isCancelled, self.ringing?.call == ring.call {
                self.passed.insert(ring.call)
                self.stopRinging()
            }
        }
    }

    private func stopRinging() {
        buzz?.cancel()
        buzz = nil
        ringing = nil
    }

    func decline() {
        guard let ring = ringing else { return }
        passed.insert(ring.call)
        stopRinging()
        WKInterfaceDevice.current().play(.stop)
        Task { try? await flash?.callStep("decline", call: ring.call, team: ring.team) }
    }

    /// RING answered from a notification: answered as soon as the app
    /// can.
    func answerFromNote(_ ring: Ring) {
        if flash != nil {
            Task { await answer(ring) }
        } else {
            wanted = ring
        }
    }

    /// Declined from a notification, with the app in the background.
    static func declineFromNote(_ ring: Ring) async {
        let flash = shared.flash ?? Flash()
        shared.passed.insert(ring.call)
        try? await flash.callStep("decline", call: ring.call, team: ring.team)
    }

    // On a call -------------------------------------------------------

    /// Picks up RING, the one ringing unless another is given.
    func answer(_ given: Ring? = nil) async {
        guard let ring = given ?? ringing, let flash, call == nil else { return }
        passed.insert(ring.call)
        stopRinging()
        call = OnCall(team: ring.team, call: ring.call, spark: ring.spark, name: ring.name,
                      reason: ring.reason, incoming: true)
        do {
            try await flash.callStep("answer", call: ring.call, team: ring.team)
        } catch {
            finish("That call is over.")
            return
        }
        // Hung up while it was being picked up.
        guard call?.call == ring.call, call?.status != .ended else {
            try? await flash.callStep("end", call: ring.call, team: ring.team)
            return
        }
        WKInterfaceDevice.current().play(.start)
        call?.since = Date()
        keepAlive()
        let why = ring.reason.isEmpty ? "" : " about: \(ring.reason)"
        start("(Voice call) You called me\(why). I've picked up; say hi and tell me why you called.")
    }

    /// Calls SPARK from the watch.
    func place(_ spark: Spark) async {
        guard let flash, call == nil, ringing == nil else { return }
        let team = "dm-\(spark.id)"
        call = OnCall(team: team, call: "", spark: spark.id, name: spark.name,
                      reason: "", incoming: false)
        do {
            let id = try await flash.startCall(team)
            guard !id.isEmpty else {
                finish("The call didn't start. Try again.")
                return
            }
            // Hung up before it got going.
            guard call?.team == team, call?.status != .ended else {
                try? await flash.callStep("cancel", call: id, team: team)
                return
            }
            call?.call = id
        } catch {
            finish(error.localizedDescription)
            return
        }
        WKInterfaceDevice.current().play(.start)
        keepAlive()
        start("(Voice call) Hi! You've picked up my call; greet me briefly.")
    }

    /// TEXT said on the call. Said while the spark talks, it stops and
    /// listens.
    func talk(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, let on = call, on.status != .ended else { return }
        round?.cancel()
        Speaker.shared.stop()
        call?.caption = said
        call?.said = "You"
        round = Task { await turn(said, on: on.call) }
    }

    /// Hangs up here.
    func hangUp() {
        guard let on = call, on.status != .ended else { return }
        let step = on.since == nil && !on.incoming ? "cancel" : "end"
        if !on.call.isEmpty, let flash {
            Task { try? await flash.callStep(step, call: on.call, team: on.team) }
        }
        finish(on.since == nil ? "Call cancelled." : "Call ended.")
    }

    private func start(_ hello: String) {
        guard let on = call else { return }
        round = Task { await turn(hello, on: on.call, hidden: true) }
    }

    /// Says on the call and is still there every few seconds, so Flash
    /// never takes it for one left open.
    private func keepAlive() {
        beat?.cancel()
        beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.beatSeconds))
                guard !Task.isCancelled, let on = call, on.status != .ended,
                      let flash else { return }
                // Hung up on the computer, or over there for long enough
                // that Flash ended it: over here too.
                if let entry = try? await flash.callStep("beat", call: on.call, team: on.team),
                   call?.call == on.call {
                    if !["ringing", "calling", "live", ""].contains(entry["state"].string) {
                        finish("Call ended.")
                        return
                    }
                    if movedAway(entry) {
                        letGo()
                        return
                    }
                }
            }
        }
    }

    /// TEXT said on the call ID, and each answer read out as it comes.
    private func turn(_ text: String, on id: String, hidden: Bool = false) async {
        guard let flash, let team = call?.team else { return }
        set(.thinking, on: id)
        let mine: Int
        do {
            mine = try await flash.sayOnCall(text, call: id, team: team, hidden: hidden)
        } catch {
            guard call?.call == id else { return }
            call?.caption = error.localizedDescription
            call?.said = ""
            set(.listening, on: id)
            return
        }
        var since = mine
        var read = 0
        let started = Date()
        var quiet = Date()
        while !Task.isCancelled, call?.call == id, call?.status != .ended {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, call?.call == id else { return }
            guard let chat = try? await flash.peekTeamChat(team, since: since) else { continue }
            let entries = chat["entries"].array
            for entry in entries { since = max(since, entry["id"].int) }
            // Taken over by another Flash: it goes on there.
            if chat["changed"].array.contains(where: {
                $0["kind"].string == "call" && $0["call"].string == id && movedAway($0)
            }) {
                letGo()
                return
            }
            let answers = entries.filter {
                $0["kind"].string == "spark" && $0["call"].string == id && $0["id"].int > mine
            }
            if answers.isEmpty {
                // Still working on it, or typing: waited for.
                if chat["answering"].bool || !chat["typing"].array.isEmpty {
                    quiet = Date()
                    continue
                }
                let waited = Date().timeIntervalSince(quiet)
                if read > 0, waited > 1.5 { break }
                if read == 0, call?.since == nil, Date().timeIntervalSince(started) > 120 {
                    hangUp()
                    call?.caption = "No one answered."
                    return
                }
                if read == 0, call?.since != nil, waited > 8 { break }
                continue
            }
            for answer in answers {
                guard !Task.isCancelled, call?.call == id else { return }
                connected(id)
                read += 1
                let spoken = answer["spoken"].string
                let words = answer["failed"].bool
                    ? (spoken.isEmpty ? "Sorry, something went wrong on my side." : spoken)
                    : (spoken.isEmpty ? answer["text"].string : spoken)
                call?.caption = Speaker.speakable(words)
                call?.said = answer["name"].string.isEmpty ? (call?.name ?? "") : answer["name"].string
                set(.speaking, on: id)
                await Speaker.shared.sayAndWait(words, id: "call-\(id)-\(answer["id"].int)",
                                                flash: flash, spark: answer["spark"].string)
                // The spark hung up, once its goodbye was said.
                if answer["end_call"].bool, call?.call == id {
                    finish("\(call?.name ?? "The spark") hung up.")
                    return
                }
            }
            quiet = Date()
        }
        if !Task.isCancelled { set(.listening, on: id) }
    }

    /// Whether ENTRY, this call's, is now held by another Flash.
    private func movedAway(_ entry: JSON) -> Bool {
        let holder = entry["holder"].string
        return !holder.isEmpty && holder != Flash.callHolder
    }

    /// The call was taken over by another Flash: it goes on there, so
    /// the watch lets go without hanging up.
    private func letGo() {
        round?.cancel()
        beat?.cancel()
        Speaker.shared.stop()
        guard call != nil else { return }
        call?.status = .ended
        call?.caption = "The call moved to another Flash."
        call?.said = ""
        WKInterfaceDevice.current().play(.directionDown)
        let ended = call?.call
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.call?.call == ended, self.call?.status == .ended { self.call = nil }
        }
    }

    /// The first answer on a call placed from here: it is connected.
    private func connected(_ id: String) {
        guard let on = call, on.call == id, on.since == nil else { return }
        call?.since = Date()
        WKInterfaceDevice.current().play(.success)
        Task { try? await flash?.callStep("connected", call: id, team: on.team) }
    }

    private func set(_ status: OnCall.Status, on id: String) {
        guard call?.call == id, call?.status != .ended else { return }
        call?.status = status
    }

    /// The call is over: WHY shows for a moment, then the screen goes.
    private func finish(_ why: String) {
        round?.cancel()
        beat?.cancel()
        Speaker.shared.stop()
        guard call != nil else { return }
        call?.status = .ended
        call?.caption = why
        call?.said = ""
        WKInterfaceDevice.current().play(.stop)
        let ended = call?.call
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.call?.call == ended, self.call?.status == .ended { self.call = nil }
        }
    }
}
