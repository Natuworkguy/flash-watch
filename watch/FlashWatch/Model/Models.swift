import SwiftUI

/// A chat in the list: enough to name it and say how it stands.
struct ChatItem: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var busy: Bool
    var spark: String
    var updated: Double
    var pinned: Bool
    var waiting: [String]

    init(_ json: JSON) {
        id = json["id"].string
        title = json["title"].string
        busy = json["busy"].bool
        spark = json["spark"].string
        updated = json["updated"].double
        pinned = json["pinned"].bool
        waiting = json["waiting"].array.map(\.string).filter { !$0.isEmpty }
    }

    var shownTitle: String { title.isEmpty ? "New chat" : title }
}

/// One chat, with what was said in it.
struct ChatDetail: Equatable {
    var item: ChatItem
    var log: [JSON]
    var partial: String
    var thinking: String
    var queued: [String]

    init(_ json: JSON) {
        item = ChatItem(json)
        log = json["log"].array
        partial = json["partial"].string
        thinking = json["thinking"].string
        queued = json["pending"].array.map { $0["text"].string }.filter { !$0.isEmpty }
    }
}

/// A spark, as its row and its page show it.
struct Spark: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    /// What @mentions it, without the @: scout-spark.
    var handle: String = ""
    var title: String
    var colour: String
    var status: String
    var activity: String
    var paused: Bool
    var answering: Bool
    var unread: Int
    var waitingOn: String
    var pendingLabel: String
    var pendingDetail: String
    var team: String = ""

    init(_ json: JSON) {
        id = json["id"].string
        name = json["name"].string
        title = json["title"].string
        colour = json["colour"].string
        status = json["status"].string
        activity = json["activity"].string
        paused = json["paused"].bool
        answering = json["answering"].bool
        unread = json["unread"].int
        waitingOn = json["waiting_on"].string
        handle = Mentions.bare(json["handle"].string)
        pendingLabel = json["pending"]["label"].string
        pendingDetail = json["pending"]["detail"].string
    }

    var needsYou: Bool { !pendingLabel.isEmpty }

    /// What it is doing, in a few words.
    var doing: String {
        if paused { return "Paused" }
        if needsYou { return "Needs you: \(pendingLabel)" }
        if !activity.isEmpty { return activity }
        if !waitingOn.isEmpty { return "Waiting on \(waitingOn)" }
        return status.isEmpty ? "Idle" : status.prefix(1).uppercased() + status.dropFirst()
    }

    var color: Color { Color(hex: colour) ?? .accentColor }
}

/// A team of sparks, and how much of its chat is unread.
struct Team: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var colour: String
    var unread: Int
    var paused: Bool

    init(_ json: JSON) {
        id = json["id"].string
        name = json["name"].string
        colour = json["colour"].string
        unread = json["chat_unread"].int
        paused = json["paused"].bool
    }

    var color: Color { Color(hex: colour) ?? .accentColor }
}

/// A message in a team's chat: the user's, a spark's, or news of what
/// happened to the team.
struct TeamEntry: Identifiable, Equatable {
    struct Version: Equatable, Hashable {
        var text: String
        var at: Double
    }

    struct Reaction: Equatable, Hashable {
        var emoji: String
        var count: Int
        var mine: Bool
    }

    let id: Int
    var kind: String
    var spark: String
    var name: String
    var text: String
    var at: Double
    var edited: Double
    var versions: [Version]
    var reactions: [Reaction]
    var failed: Bool
    var replyKind: String
    var replySpark: String
    var replyText: String
    var files: Int

    init(_ json: JSON) {
        id = json["id"].int
        kind = json["kind"].string
        spark = json["spark"].string
        name = json["name"].string
        text = json["text"].string
        at = json["at"].double
        edited = json["edited"].double
        versions = json["versions"].array.map { Version(text: $0["text"].string, at: $0["at"].double) }
        reactions = json["reactions"].object
            .map { emoji, whose -> Reaction in
                let who = whose.array.map(\.string)
                return Reaction(emoji: emoji, count: who.count, mine: who.contains("user"))
            }
            .filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        failed = json["failed"].bool
        replyKind = json["reply"]["kind"].string
        replySpark = json["reply"]["spark"].string
        replyText = json["reply"]["text"].string
        files = json["files"].array.count
    }

    var isMine: Bool { kind == "user" }
    var isNews: Bool { kind == "event" }
    var wasEdited: Bool { !versions.isEmpty }
}

extension Color {
    /// "#d97757", or the three-digit kind.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

/// "2m", "3h", "Mon": how long ago, as short as a watch needs it.
func ago(_ seconds: Double) -> String {
    guard seconds > 0 else { return "" }
    let then = Date(timeIntervalSince1970: seconds)
    let gone = Date().timeIntervalSince(then)
    if gone < 60 { return "now" }
    if gone < 3600 { return "\(Int(gone / 60))m" }
    if gone < 86400 { return "\(Int(gone / 3600))h" }
    if gone < 6 * 86400 { return then.formatted(.dateTime.weekday(.abbreviated)) }
    return then.formatted(.dateTime.month(.abbreviated).day())
}

/// @mentions, as the page and the terminal take them: an @handle in a
/// message calls that spark in, and Flash routes it. Dictation cannot
/// write one, so a spark's spoken name becomes its handle here.
enum Mentions {
    /// TEXT with "@Engineer", "@ engineer" anywhere, or "at Engineer" at
    /// the start or after a comma or a sentence's end, made "@engineer-spark".
    static func resolve(_ text: String, sparks: [Spark]) -> String {
        var out = text
        // Longest names first, so "Dev Team Manager" wins over "Dev".
        let named = sparks.filter { !$0.handle.isEmpty }
            .flatMap { spark in spoken(spark).map { ($0, bare(spark.handle)) } }
            .sorted { $0.0.count > $1.0.count }
        for (words, handle) in named {
            let name = words.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[\\s-]+")
            let pattern = "(?<![\\w@./])(?:@\\s*|(?:^|(?<=[,.!?;:]\\s))at\\s+)"
                + name + "(?:-spark)?(?![\\w-])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(
                in: out, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: "@" + handle))
        }
        return out
    }

    /// A handle without any leading @, as Flash sends it with one.
    static func bare(_ handle: String) -> String {
        String(handle.drop { $0 == "@" })
    }

    /// The ways to say a spark: its name, and its handle without -spark.
    private static func spoken(_ spark: Spark) -> [String] {
        var short = bare(spark.handle).lowercased()
        if short.hasSuffix("-spark") { short.removeLast(6) }
        let base = short.replacingOccurrences(of: "-", with: " ")
        let name = spark.name.trimmingCharacters(in: .whitespaces)
        return Array(Set([name.lowercased(), base].filter { !$0.isEmpty }))
    }

    /// TEXT with MENTIONING's handle in front, unless it names it already.
    static func prefixed(_ text: String, with mentioning: Spark?) -> String {
        guard let spark = mentioning, !bare(spark.handle).isEmpty else { return text }
        let handle = bare(spark.handle)
        let short = handle.hasSuffix("-spark") ? String(handle.dropLast(6)) : handle
        let lower = text.lowercased()
        if lower.contains("@" + handle.lowercased()) || lower.contains("@" + short.lowercased()) {
            return text
        }
        return "@\(handle) " + text
    }
}
