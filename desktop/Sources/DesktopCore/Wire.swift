import Foundation

/// Any JSON value. Used for the request `id`, which is echoed back unchanged.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The fields every request line carries.
struct RequestEnvelope: Decodable {
    var id: JSONValue?
    var op: String?
}

/// `{ "id", "ok": true, ...result }`: the result's fields sit next to `id` and `ok`.
public struct SuccessResponse<Result: Encodable>: Encodable {
    public var id: JSONValue
    public var result: Result

    private enum Keys: String, CodingKey { case id, ok }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(true, forKey: .ok)
        try result.encode(to: encoder)
    }
}

/// `{ "id", "ok": false, "error": { "code", "message" } }`.
public struct FailureResponse: Codable, Equatable {
    public var id: JSONValue
    public var ok: Bool
    public var error: DesktopError

    public init(id: JSONValue, error: DesktopError) {
        self.id = id
        self.ok = false
        self.error = error
    }

    private enum Keys: String, CodingKey { case id, ok, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(JSONValue.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decode(DesktopError.self, forKey: .error)
    }

    // Written in the spec's order: id, ok, error.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
    }
}

/// What a client reads first from any response line.
public struct ResponseHeader: Decodable, Equatable {
    public var id: JSONValue
    public var ok: Bool
    public var error: DesktopError?
}

public enum Wire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// One response line, without the trailing newline. JSONEncoder never emits raw newlines.
    public static func success<Result: Encodable>(id: JSONValue, _ result: Result) -> Data {
        do {
            return try encoder().encode(SuccessResponse(id: id, result: result))
        } catch {
            return failure(id: id, .failed("Could not encode the result: \(error)"))
        }
    }

    public static func failure(id: JSONValue, _ error: DesktopError) -> Data {
        // Encoding plain strings cannot fail.
        (try? encoder().encode(FailureResponse(id: id, error: error))) ?? Data(#"{"id":null,"ok":false}"#.utf8)
    }

    /// A short, readable reason for a request that did not decode.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return keys.isEmpty ? "request" : "`\(keys)`"
        }
        switch error {
        case .typeMismatch(let type, let context): return "\(path(context)) must be \(friendly(type))"
        case .valueNotFound(let type, let context): return "\(path(context)) must be \(friendly(type)), not null"
        case .keyNotFound(let key, _): return "`\(key.stringValue)` is required"
        case .dataCorrupted(let context):
            if context.codingPath.last?.stringValue == "operation" {
                return "`operation` must be one of \(ActOperation.allCases.map(\.rawValue).joined(separator: ", "))"
            }
            if context.codingPath.last?.stringValue == "direction" { return "`direction` must be up or down" }
            return context.codingPath.isEmpty ? "the line is not a JSON object" : "\(path(context)) is invalid"
        @unknown default: return "\(error)"
        }
    }

    private static func friendly(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Int.Type: return "an integer"
        case is Bool.Type: return "a boolean"
        case is [String].Type: return "an array of strings"
        default: return "\(type)"
        }
    }
}
