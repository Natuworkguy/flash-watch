import Foundation
import UserNotifications
import WatchKit

/// What Flash had to tell, as the watch's own notifications: a reply that
/// came in, a question waiting on a yes or no, Flash's own notifications and
/// a spark's mention of you.
///
/// The watch asks Flash for them: while the app is open, every few seconds;
/// with it closed, when watchOS wakes it to refresh, a few times an hour.
@MainActor
enum Notes {
    /// The last of Flash's notes the watch has seen, on each computer.
    private static func seenKey(_ server: String) -> String { "notesSeen.\(server)" }
    static let refreshID = "flash.notes"
    /// A spark calling: a notification with Answer and Decline.
    static let callCategory = "flash.call"
    /// How often to ask watchOS for a background refresh. It decides when.
    private static let every: TimeInterval = 15 * 60

    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// What a call's notification offers.
    static func register() {
        let answer = UNNotificationAction(identifier: "answer", title: "Answer", options: [.foreground])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: callCategory, actions: [answer, decline],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Shows what came since the last look. QUIET is the chat on screen,
    /// whose replies need no notification. How many it showed.
    @discardableResult
    static func check(_ flash: Flash, quiet: String = "") async -> Int {
        guard let server = flash.pairing?.id else { return 0 }
        let key = seenKey(server)
        let defaults = UserDefaults.standard
        let firstTime = defaults.object(forKey: key) == nil
        let seen = defaults.integer(forKey: key)
        guard let got = try? await flash.notifications(since: seen) else { return 0 }
        let last = got["last"].int
        // Flash started again since: its notes count from the start.
        let since = last < seen ? 0 : seen
        defaults.set(last, forKey: key)
        // Paired just now: what came before is old news.
        guard !firstTime else { return 0 }

        let replies = defaults.object(forKey: Prefs.notifyReplies) as? Bool ?? true
        let others = defaults.object(forKey: Prefs.notifyFlash) as? Bool ?? true
        var shown = 0
        // Open, the watch rings for a call itself (Calls).
        let open = WKApplication.shared().applicationState == .active
        var rings: [Ring]?
        for note in got["notes"].array where note["id"].int > since {
            let kind = note["kind"].string
            let chat = note["chat"].string
            if kind == "call" {
                if open { continue }
                if rings == nil { rings = (try? await flash.rings()) ?? [] }
                if let ring = rings?.first(where: { $0.team == chat }) {
                    postRing(ring)
                    shown += 1
                } else if await missed(note, flash: flash) {
                    shown += 1
                }
                continue
            }
            if kind == "reply" && (!replies || (!quiet.isEmpty && chat == quiet)) { continue }
            if kind != "reply" && !others { continue }
            post(note)
            shown += 1
        }
        return shown
    }

    /// A computer unpaired: its count goes with it.
    static func forget(_ server: String) {
        UserDefaults.standard.removeObject(forKey: seenKey(server))
    }

    private static func post(_ note: JSON) {
        let content = UNMutableNotificationContent()
        let title = note["title"].string
        switch note["kind"].string {
        case "reply":
            content.title = title.isEmpty ? "Flash replied" : title
        case "ask":
            content.title = "Flash asks"
            content.subtitle = title
        default:
            content.title = title.isEmpty ? "Flash" : title
        }
        content.body = Speaker.speakable(note["text"].string)
        content.sound = .default
        content.threadIdentifier = note["chat"].string.isEmpty ? "flash" : note["chat"].string
        content.userInfo = ["chat": note["chat"].string]
        let request = UNNotificationRequest(identifier: "flash.\(note["id"].int).\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A call still ringing: Answer opens the app on it, Decline declines.
    private static func postRing(_ ring: Ring) {
        let content = UNMutableNotificationContent()
        content.title = "\(ring.name) is calling"
        content.body = ring.reason.isEmpty ? "A call from a spark." : ring.reason
        content.sound = .default
        content.categoryIdentifier = callCategory
        content.threadIdentifier = ring.team
        content.userInfo = ring.userInfo
        let request = UNNotificationRequest(identifier: "flash.call.\(ring.call)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A call that rang while the app was closed and is over now: said as
    /// missed only when nobody answered it anywhere. Whether it was shown.
    private static func missed(_ note: JSON, flash: Flash) async -> Bool {
        let team = note["chat"].string
        guard !team.isEmpty, let chat = try? await flash.peekTeamChat(team, since: 0) else { return false }
        let calls = chat["entries"].array.filter {
            $0["kind"].string == "call" && $0["from"].string == "spark"
        }
        guard let last = calls.last, last["state"].string == "missed" else { return false }
        let content = UNMutableNotificationContent()
        let title = note["title"].string
        let name = title.hasSuffix(" is calling") ? String(title.dropLast(" is calling".count)) : "a spark"
        content.title = "Missed call from \(name)"
        content.body = note["text"].string.isEmpty ? "Call back from Flash." : note["text"].string
        content.sound = .default
        content.threadIdentifier = team
        let request = UNNotificationRequest(identifier: "flash.missed.\(last["call"].string)",
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        return true
    }

    /// The next background refresh, to look for notes with the app closed.
    static func schedule() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(every),
            userInfo: refreshID as NSString
        ) { _ in }
    }
}

/// Notifications shown while the app is open too, and a tap on one opens
/// its chat.
final class NoteDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NoteDelegate()
    /// The chat a tapped notification is about, for the app to open.
    @Published var opened: String?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == Notes.callCategory,
           let ring = Ring(userInfo: info) {
            let action = response.actionIdentifier
            Task { @MainActor in
                if action == "decline" {
                    await Calls.declineFromNote(ring)
                } else {
                    // Answer, or a tap on it: picked up, if it still rings.
                    Calls.shared.answerFromNote(ring)
                }
                completionHandler()
            }
            return
        }
        let chat = response.notification.request.content.userInfo["chat"] as? String ?? ""
        DispatchQueue.main.async {
            if !chat.isEmpty { self.opened = chat }
            completionHandler()
        }
    }
}
