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
    /// The last of Flash's notes the watch has seen.
    private static let seenKey = "notesSeen"
    static let refreshID = "flash.notes"
    /// How often to ask watchOS for a background refresh. It decides when.
    private static let every: TimeInterval = 15 * 60

    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Shows what came since the last look. QUIET is the chat on screen,
    /// whose replies need no notification. How many it showed.
    @discardableResult
    static func check(_ flash: Flash, quiet: String = "") async -> Int {
        let defaults = UserDefaults.standard
        let firstTime = defaults.object(forKey: seenKey) == nil
        let seen = defaults.integer(forKey: seenKey)
        guard let got = try? await flash.notifications(since: seen) else { return 0 }
        let last = got["last"].int
        // Flash started again since: its notes count from the start.
        let since = last < seen ? 0 : seen
        defaults.set(last, forKey: seenKey)
        // Paired just now: what came before is old news.
        guard !firstTime else { return 0 }

        let replies = defaults.object(forKey: Prefs.notifyReplies) as? Bool ?? true
        let others = defaults.object(forKey: Prefs.notifyFlash) as? Bool ?? true
        var shown = 0
        for note in got["notes"].array where note["id"].int > since {
            let kind = note["kind"].string
            let chat = note["chat"].string
            if kind == "reply" && (!replies || (!quiet.isEmpty && chat == quiet)) { continue }
            if kind != "reply" && !others { continue }
            post(note)
            shown += 1
        }
        return shown
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
        let chat = response.notification.request.content.userInfo["chat"] as? String ?? ""
        DispatchQueue.main.async {
            if !chat.isEmpty { self.opened = chat }
            completionHandler()
        }
    }
}
