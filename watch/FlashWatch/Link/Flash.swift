import SwiftUI
import WatchKit

/// Flash on the computer, as this watch knows it: whether it is paired,
/// the chats, the sparks and their teams, and everything it can ask.
@MainActor
final class Flash: ObservableObject {
    @Published private(set) var pairing: Pairing?
    @Published private(set) var chats: [ChatItem] = []
    @Published private(set) var sparks: [Spark] = []
    @Published private(set) var teams: [Team] = []
    @Published private(set) var loaded = false
    /// Why the last refresh failed, while it keeps failing.
    @Published var problem: String?
    /// Said on the pairing screen when the computer signed this watch out.
    @Published var signedOutNote: String?

    init() {
        if let address = Keychain.read("address"), let key = Keychain.read("key"),
           !address.isEmpty, !key.isEmpty {
            pairing = Pairing(address: address, key: key)
        }
    }

    private var client: FlashClient? { pairing.map { FlashClient($0) } }

    private func linked() throws -> FlashClient {
        guard let client else { throw LinkError.signedOut }
        return client
    }

    // Pairing --------------------------------------------------------

    func pair(address typed: String, code typedCode: String) async throws {
        let address = try FlashClient.normalized(typed)
        let code = try FlashClient.code(typedCode)
        let key = try await FlashClient(base: address)
            .pair(code: code, name: WKInterfaceDevice.current().name)
        Keychain.write(address, for: "address")
        Keychain.write(key, for: "key")
        signedOutNote = nil
        pairing = Pairing(address: address, key: key)
        await refresh()
    }

    func unpair(note: String? = nil) {
        Keychain.write(nil, for: "key")
        pairing = nil
        chats = []
        sparks = []
        teams = []
        loaded = false
        problem = nil
        signedOutNote = note
    }

    /// The address it was paired with, to offer again when pairing anew.
    var lastAddress: String { pairing?.address ?? Keychain.read("address") ?? "" }

    /// Runs WORK, and signs out if the computer no longer knows this watch.
    @discardableResult
    func run<T>(_ work: (FlashClient) async throws -> T) async throws -> T {
        do {
            return try await work(try linked())
        } catch LinkError.signedOut {
            unpair(note: LinkError.signedOut.errorDescription)
            throw LinkError.signedOut
        }
    }

    // The lists ------------------------------------------------------

    func refresh() async {
        guard pairing != nil else { return }
        do {
            let state = try await run { try await $0.get("/api/state?lite=1") }
            let roster = try await run { try await $0.command("sparks") }
            let teamOf = Dictionary(
                roster["sparks"].array.map { ($0["id"].string, $0["team"].string) },
                uniquingKeysWith: { first, _ in first })

            chats = state["chats"].array.map(ChatItem.init)
                .filter { !$0.id.isEmpty }
                .sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
            sparks = state["sparks"].array.map {
                var spark = Spark($0)
                spark.team = teamOf[spark.id] ?? ""
                return spark
            }
            teams = roster["teams"].array.map(Team.init)
            problem = nil
            loaded = true
        } catch {
            if pairing != nil { problem = error.localizedDescription }
        }
    }

    func spark(_ id: String) -> Spark? { sparks.first { $0.id == id } }
    func team(_ id: String) -> Team? { teams.first { $0.id == id } }

    // Chats ----------------------------------------------------------

    func chat(_ id: String) async throws -> ChatDetail {
        let shown = try await run { try await $0.command("chat-view", chat: id) }
        return ChatDetail(shown["chat"])
    }

    /// A new chat, with a spark when SPARK is one, and TEXT sent in it.
    func startChat(_ text: String, spark: String = "") async throws -> String {
        let made = try await run { try await $0.command("new", ["spark": spark]) }
        let id = made["chat"].string
        try await send(text, to: id)
        return id
    }

    func send(_ text: String, to chat: String) async throws {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        // Sent as spoken, Flash keeps its reply short and plain: what a
        // watch can show, and read aloud.
        let short = UserDefaults.standard.object(forKey: Prefs.shortReplies) as? Bool ?? true
        try await run { try await $0.post("/api/send", ["chat": chat, "text": said, "voice": short]) }
        Task { await refresh() }
    }

    func answer(_ ask: String, yes: Bool) async throws {
        try await run { try await $0.post("/api/answer", ["id": ask, "answer": yes ? "y" : "n"]) }
    }

    func stop(_ chat: String) async throws {
        try await run { try await $0.command("stop", chat: chat) }
    }

    func pin(_ chat: String, _ on: Bool) async throws {
        try await run { try await $0.command("pin", arg: on ? "on" : "off", chat: chat) }
        await refresh()
    }

    // Sparks ---------------------------------------------------------

    /// spark-run, spark-pause, spark-resume, spark-approve, spark-deny.
    func sparkDo(_ what: String, _ id: String) async throws {
        try await run { try await $0.command("spark-\(what)", arg: id) }
        await refresh()
    }

    // Team chats -----------------------------------------------------

    /// The entries after SINCE, those before it changed since, and who
    /// is typing. Reading it while it is on screen marks it read.
    func teamChat(_ team: String, since: Int) async throws -> JSON {
        try await run { try await $0.command("team-chat", arg: team, ["since": since, "read": true]) }
    }

    func say(_ text: String, team: String, replyTo: Int = 0) async throws {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        try await run {
            try await $0.command("team-chat-say", arg: team, ["text": said, "reply_to": replyTo])
        }
    }

    func react(_ emoji: String, to entry: Int, team: String) async throws {
        try await run {
            try await $0.command("team-chat-react", arg: team, ["id": entry, "emoji": emoji])
        }
    }

    // Voice ----------------------------------------------------------

    /// TEXT in Flash's own voice, as a WAV, when the computer has one.
    func voice(_ text: String) async throws -> Data {
        let said = try await run { try await $0.post("/api/voice/say", ["text": text]) }
        guard let audio = Data(base64Encoded: said["audio"].string), !audio.isEmpty else {
            throw LinkError.refused("No voice on the computer.")
        }
        return audio
    }
}
