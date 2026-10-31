import Foundation

/// Any JSON, read without a schema. What Flash sends differs from one
/// kind of event to the next, and a field this watch does not know must
/// never stop it reading the rest.
enum JSON: Decodable, Equatable {
    case null
    case flag(Bool)
    case num(Double)
    case text(String)
    case list([JSON])
    case dict([String: JSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .flag(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .num(number)
        } else if let string = try? value.decode(String.self) {
            self = .text(string)
        } else if let array = try? value.decode([JSON].self) {
            self = .list(array)
        } else {
            self = .dict(try value.decode([String: JSON].self))
        }
    }

    static func parse(_ data: Data) -> JSON {
        (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
    }

    subscript(key: String) -> JSON {
        if case .dict(let fields) = self { return fields[key] ?? .null }
        return .null
    }

    var string: String {
        switch self {
        case .text(let text): return text
        case .num(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    var double: Double {
        switch self {
        case .num(let n): return n
        case .text(let text): return Double(text) ?? 0
        default: return 0
        }
    }

    var int: Int { Int(double) }

    var bool: Bool {
        switch self {
        case .flag(let b): return b
        case .num(let n): return n != 0
        case .text(let text): return !text.isEmpty
        case .list(let items): return !items.isEmpty
        case .dict(let fields): return !fields.isEmpty
        case .null: return false
        }
    }

    var array: [JSON] {
        if case .list(let items) = self { return items }
        return []
    }

    var object: [String: JSON] {
        if case .dict(let fields) = self { return fields }
        return [:]
    }
}
