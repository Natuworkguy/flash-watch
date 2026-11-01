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
    /// The chat open on the watch now: its replies need no notification.
    var onScreen = ""

    init() {
        if let address = Keychain.read("address"), let key = Keychain.read("key"),
           !address.isEmpty, !key.isEmpty {
            let all = (Keychain.read("addresses") ?? "").split(separator: "\n").map(String.init)
            pairing = Pairing(address: address, addresses: all.isEmpty ? [address] : all, key: key)
        }
    }

    // Pairing --------------------------------------------------------

    func pair(address typed: String, code typedCode: String) async throws {
        let address = try FlashClient.normalized(typed)
        let code = try FlashClient.code(typedCode)
        let key = try await FlashClient(base: address)
            .pair(code: code, name: Self.deviceName)
        Keychain.write(key, for: "key")
        signedOutNote = nil
        save(Pairing(address: address, addresses: [address], key: key))
        await syncAddresses(force: true)
        await refresh()
    }

    /// What the computer lists this watch as, until it is renamed there:
    /// a simulator says so, to tell it from the watch on your wrist.
    static var deviceName: String {
        let name = WKInterfaceDevice.current().name
        #if targetEnvironment(simulator)
        return "\(name) (Simulator)"
        #else
        return name
        #endif
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

    private func save(_ found: Pairing) {
        Keychain.write(found.address, for: "address")
        Keychain.write(found.addresses.joined(separator: "\n"), for: "addresses")
        pairing = found
    }

    /// Runs WORK against the address that answered last, then the others:
    /// on the Wi-Fi at home, through the public link away from it. Signs
    /// out if the computer no longer knows this watch.
    @discardableResult
    func run<T>(_ work: (FlashClient) async throws -> T) async throws -> T {
        guard let pairing else { throw LinkError.signedOut }
        let order = [pairing.address] + pairing.addresses.filter { $0 != pairing.address }
        var failed: Error = LinkError.unreachable(FlashClient.hostOf(pairing.address))
        for address in order {
            do {
                let result = try await work(FlashClient(base: address, key: pairing.key))
                if address != self.pairing?.address, var now = self.pairing {
                    now.address = address
                    save(now)
                    // The one tried first did not answer: Flash, through the
                    // one that did, says where it is now. Its Wi-Fi address
                    // may simply have changed.
                    if !syncing { Task { await syncAddresses(force: true) } }
                }
                return result
            } catch LinkError.unreachable(let host) {
                failed = LinkError.unreachable(order.count > 1 ? "any of its addresses" : host)
                continue
            } catch LinkError.signedOut {
                unpair(note: LinkError.signedOut.errorDescription)
                throw LinkError.signedOut
            }
        }
        throw failed
    }

    // Addresses ------------------------------------------------------

    private var syncedAt = Date.distantPast
    private var syncing = false

    /// The public link, while the computer has one on.
    var publicAddress: String? { pairing?.addresses.first { !FlashClient.isLocal($0) } }

    /// Asks Flash where it can be reached now, so the public link (a new
    /// one each time the tunnel starts) never has to be typed. Addresses
    /// on the Wi-Fi stay, even while the computer is off it; a public
    /// link that ended goes.
    ///
    /// Never a problem to show: away from home the Wi-Fi address cannot
    /// answer, and that is as it should be.
    func syncAddresses(force: Bool = false) async {
        guard pairing != nil, !syncing, force || Date().timeIntervalSince(syncedAt) > 60 else { return }
        syncing = true
        defer { syncing = false }
        syncedAt = Date()
        guard let told = try? await run({ try await $0.command("addresses") }),
              var now = pairing else { return }
        let found = told["addresses"].array.map(\.string).filter { !$0.isEmpty }
        // Where Flash says it is on the Wi-Fi now replaces where it was: an
        // address that changed is put right. Only when it says none (its
        // network access is off for now) are the ones known kept.
        let saysLocal = found.contains(where: FlashClient.isLocal)
        let kept = saysLocal ? [] : now.addresses.filter(FlashClient.isLocal)
        var all: [String] = []
        for address in found + kept where !all.contains(address) {
            all.append(address)
        }
        // Wi-Fi first: at home it is the quicker way.
        all.sort { FlashClient.isLocal($0) && !FlashClient.isLocal($1) }
        guard !all.isEmpty else { return }
        now.addresses = all
        if !all.contains(now.address) { now.address = all[0] }
        save(now)

        // Back home on the public link: the Wi-Fi again, once it answers.
        if !FlashClient.isLocal(now.address), let home = all.first(where: FlashClient.isLocal),
           (try? await FlashClient(base: home, key: now.key, timeout: 3).get("/api/state?lite=1")) != nil,
           var back = pairing {
            back.address = home
            save(back)
        }
    }

    /// Turns on the computer's tunnel, if it is not on, and learns its
    /// address: Flash from anywhere, with nothing to type.
    func openPublicLink() async throws {
        let info = try await run { try await $0.command("tunnel") }
        if info["tunnel"]["state"].string != "on" {
            let installed = info["services"].array
                .filter { $0["installed"].bool }
                .map { $0["name"].string }
            let last = info["tunnel"]["service"].string
            guard let service = installed.contains(last) ? last : installed.first else {
                throw LinkError.refused(
                    "Your computer needs a tunnel program first. In Flash, open Settings and find \"Open from anywhere\".")
            }
            // Starting one takes a while: it waits until Flash answers
            // through it.
            try await run { try await $0.slow.command("tunnel", arg: service) }
        }
        await syncAddresses(force: true)
        guard publicAddress != nil else {
            throw LinkError.refused("The tunnel started, but Flash didn't say its address. Try again.")
        }
    }

    // The lists ------------------------------------------------------

    func refresh() async {
        guard pairing != nil else { return }
        await syncAddresses()
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
        } catch LinkError.unreachable {
            // Out of the house, or the computer asleep: nothing to fix,
            // so nothing alarming. What it said last stays on screen.
            if pairing != nil { problem = "Can't reach your computer right now." }
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

    // Notes and the briefing ------------------------------------------

    /// What Flash had to tell since note SINCE: replies, questions, its
    /// notifications, mentions.
    func notifications(since: Int) async throws -> JSON {
        try await run { try await $0.command("notifications", arg: String(since)) }
    }

    /// The briefing's cards, newest first, as the page shows them.
    func briefing() async throws -> [JSON] {
        try await run { try await $0.command("briefing", arg: "open") }["cards"].array
    }

    func dismissCard(_ id: String) async throws {
        try await run { try await $0.command("briefing-dismiss", arg: id) }
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
