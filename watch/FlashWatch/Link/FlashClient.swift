import Foundation

/// What went wrong talking to Flash, said the way the watch says it.
enum LinkError: LocalizedError, Equatable {
    case badAddress
    case badCode
    case unreachable(String)
    case signedOut
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .badAddress:
            return "That address doesn't look right. It's shown under Watch in Flash on your computer."
        case .badCode:
            return "A pairing code is six digits."
        case .unreachable(let host):
            return "Can't reach Flash at \(host). Is it running, with the network on?"
        case .signedOut:
            return "This watch was signed out of Flash."
        case .refused(let why):
            return why
        }
    }
}

/// The computer running Flash, and this watch's key to it.
struct Pairing: Equatable {
    /// The address that answered last: tried first.
    var address: String
    /// Every address Flash is known at: on the Wi-Fi, and its public link.
    var addresses: [String]
    var key: String
}

/// Requests to Flash's own web API, as a signed-in device.
///
/// The watch sends its key in a header of its own, since it keeps no
/// cookies, and the same JSON the web page sends.
struct FlashClient {
    /// What the list of signed-in devices on the computer names it by.
    static let agent = "FlashDevice/1.0 watchOS"
    static let defaultPort = 7433

    let base: String
    let key: String
    /// How long a request may take before the address counts as down.
    var timeout: TimeInterval = 10

    init(base: String, key: String = "", timeout: TimeInterval = 10) {
        self.base = base
        self.key = key
        self.timeout = timeout
    }

    /// The same, for a request that takes its time, such as starting
    /// the computer's tunnel.
    var slow: FlashClient { FlashClient(base: base, key: key, timeout: 150) }

    static func hostOf(_ address: String) -> String {
        URLComponents(string: address)?.host ?? address
    }

    /// Whether ADDRESS is on the network here, rather than the internet.
    static func isLocal(_ address: String) -> Bool {
        onNetwork(hostOf(address))
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 150
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Where Flash is, from what was typed: "192.168.1.20", a name, or
    /// the whole link. Plain addresses on the network get Flash's own
    /// port; a name on the internet is the tunnel, over HTTPS.
    static func normalized(_ typed: String) throws -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { throw LinkError.badAddress }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let name = host.split(separator: ":").first.map(String.init) ?? host
            text = (onNetwork(name) ? "http://" : "https://") + text
        }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty
        else { throw LinkError.badAddress }
        if scheme == "http", parts.port == nil, onNetwork(host) {
            parts.port = defaultPort
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.string else { throw LinkError.badAddress }
        return url
    }

    /// Whether HOST is a machine on this network rather than the internet.
    static func onNetwork(_ host: String) -> Bool {
        let name = host.lowercased()
        if name.hasSuffix(".local") || !name.contains(".") { return true }
        let numbers = name.split(separator: ".")
        return numbers.count == 4 && numbers.allSatisfy { UInt8($0) != nil }
    }

    /// The six digits in what was typed or dictated.
    /// The pairing code as Flash shows it, "1.20 · 482 019": the address on
    /// the Wi-Fi, then six digits. The address part is the end of a home
    /// network's 192.168 address, or a whole one, with a port when it is not
    /// Flash's own. Either part is nil when it is not there.
    static func pairingCode(_ typed: String) -> (address: String?, code: String?) {
        let parts = typed.split { " ·-_,".contains($0) }.map(String.init)
        var address: String?
        var digits = ""
        for part in parts {
            if part.contains(".") || part.contains(":") {
                address = networkAddress(part)
            } else {
                digits += part.filter { $0.isASCII && $0.isNumber }
            }
        }
        return (address, digits.count == 6 ? digits : nil)
    }

    /// "1.20" is 192.168.1.20, "10.0.0.5" is itself; ":8000" after either
    /// is the port. As http on Flash's port when none is given.
    static func networkAddress(_ part: String) -> String? {
        let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
        let numbers = pieces[0].split(separator: ".").map(String.init)
        guard numbers.allSatisfy({ UInt8($0) != nil }) else { return nil }
        let host: String
        switch numbers.count {
        case 2: host = "192.168." + numbers.joined(separator: ".")
        case 4: host = numbers.joined(separator: ".")
        default: return nil
        }
        let port = pieces.count > 1 ? (Int(pieces[1]) ?? defaultPort) : defaultPort
        return "http://\(host):\(port)"
    }

    static func code(_ typed: String) throws -> String {
        let digits = typed.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 6 else { throw LinkError.badCode }
        return digits
    }

    // Requests -------------------------------------------------------

    func get(_ path: String) async throws -> JSON {
        try await call(path, body: nil)
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> JSON {
        try await call(path, body: body)
    }

    /// One of the page's own commands, as the web page sends it.
    func command(_ name: String, arg: String = "", chat: String = "",
                 _ extra: [String: Any] = [:]) async throws -> JSON {
        var body: [String: Any] = ["name": name, "arg": arg]
        if !chat.isEmpty { body["chat"] = chat }
        body.merge(extra) { _, new in new }
        return try await post("/api/command", body)
    }

    /// Trades a pairing code for this watch's own key.
    func pair(code: String, name: String) async throws -> String {
        let answer = try await post("/api/pair", ["code": code, "name": name])
        let key = answer["key"].string
        guard !key.isEmpty else { throw LinkError.refused("Flash didn't give this watch a key.") }
        return key
    }

    private func call(_ path: String, body: [String: Any]?) async throws -> JSON {
        guard let url = URL(string: base + path) else { throw LinkError.badAddress }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        if !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Flash-Device")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw LinkError.unreachable(url.host ?? base)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = JSON.parse(data)
        if status == 403 {
            if key.isEmpty {
                throw LinkError.refused("Flash turned this watch away. Check the address.")
            }
            throw LinkError.signedOut
        }
        guard (200..<300).contains(status) else {
            let said = json["error"].string
            throw LinkError.refused(said.isEmpty ? "Flash answered with an error (\(status))." : said)
        }
        return json
    }
}
