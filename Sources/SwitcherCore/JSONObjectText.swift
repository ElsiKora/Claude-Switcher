public import Foundation

/// The text of a JSON object file, edited member by member.
///
/// Claude's `config.json` holds app state next to the sign-in. Only the
/// members we touch change; every other byte, including key order and
/// indentation, stays exactly as Claude wrote it.
public struct JSONObjectText: Sendable, Equatable {
    public private(set) var bytes: [UInt8]

    private struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    public init(data: Data) throws(JSONTextError) {
        bytes = Array(data)
        _ = try members()
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    public static func empty() -> JSONObjectText { JSONObjectText(bytes: Array("{}".utf8)) }

    public var data: Data { Data(bytes) }

    public var keys: [String] {
        (try? members().map(\.key)) ?? []
    }

    /// The member's value as JSON text.
    public func raw(_ key: String) -> Data? {
        guard let m = try? members().first(where: { $0.key == key }) else { return nil }
        return Data(bytes[m.valueStart..<m.valueEnd])
    }

    public func string(_ key: String) -> String? {
        guard let raw = raw(key) else { return nil }
        return try? JSONDecoder().decode(String.self, from: raw)
    }

    public func contains(_ key: String) -> Bool { raw(key) != nil }

    /// Sets a member to the JSON text `raw`, appending it when it is new.
    public mutating func set(_ key: String, raw: Data) throws(JSONTextError) {
        let all = try members()
        let value = Array(raw)
        if let m = all.first(where: { $0.key == key }) {
            bytes.replaceSubrange(m.valueStart..<m.valueEnd, with: value)
            return
        }
        let keyText = Self.encode(key)
        guard let last = all.last else {
            let close = bytes.lastIndex(of: UInt8(ascii: "}"))!
            bytes.replaceSubrange(0...close, with: Array("{\n\t".utf8) + keyText + Array(": ".utf8) + value + Array("\n}".utf8))
            return
        }
        // Copy the layout of the existing members.
        let colon = Array(bytes[afterKey(last)..<last.valueStart])
        var indent = Array("\n\t".utf8)
        if all.count > 1 {
            let prev = all[all.count - 2]
            if let comma = bytes[prev.valueEnd..<last.keyStart].firstIndex(of: UInt8(ascii: ",")) {
                indent = Array(bytes[(comma + 1)..<last.keyStart])
            }
        } else if let open = bytes.firstIndex(of: UInt8(ascii: "{")) {
            indent = Array(bytes[(open + 1)..<last.keyStart])
        }
        bytes.insert(contentsOf: [UInt8(ascii: ",")] + indent + keyText + colon + value, at: last.valueEnd)
    }

    public mutating func remove(_ key: String) throws(JSONTextError) {
        let all = try members()
        guard let i = all.firstIndex(where: { $0.key == key }) else { return }
        if i > 0 {
            bytes.removeSubrange(all[i - 1].valueEnd..<all[i].valueEnd)
        } else if all.count > 1 {
            bytes.removeSubrange(all[0].keyStart..<all[1].keyStart)
        } else {
            let open = bytes.firstIndex(of: UInt8(ascii: "{"))!
            let close = bytes.lastIndex(of: UInt8(ascii: "}"))!
            bytes.replaceSubrange(open...close, with: Array("{}".utf8))
        }
    }

    /// A JSON string literal for `s`.
    static func encode(_ s: String) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "\"")]
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += Array("\\\"".utf8)
            case "\\": out += Array("\\\\".utf8)
            case "\n": out += Array("\\n".utf8)
            case "\r": out += Array("\\r".utf8)
            case "\t": out += Array("\\t".utf8)
            case _ where u.value < 0x20: out += Array(String(format: "\\u%04x", u.value).utf8)
            default: out += Array(String(u).utf8)
            }
        }
        out.append(UInt8(ascii: "\""))
        return out
    }

    // MARK: - Scanner

    private func afterKey(_ m: Member) -> Int {
        var i = m.keyStart + 1
        while bytes[i] != UInt8(ascii: "\"") {
            i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1
        }
        return i + 1
    }

    private func members() throws(JSONTextError) -> [Member] {
        var i = skipSpace(0)
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { throw .notAnObject }
        i = skipSpace(i + 1)
        var out: [Member] = []
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            return try trailing(i + 1, out)
        }
        while true {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw .malformed(at: i) }
            let keyStart = i
            let keyEnd = try skipString(i)
            guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<keyEnd])) else {
                throw .malformed(at: i)
            }
            i = skipSpace(keyEnd)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw .malformed(at: i) }
            let valueStart = skipSpace(i + 1)
            let valueEnd = try skipValue(valueStart)
            out.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            i = skipSpace(valueEnd)
            guard i < bytes.count else { throw .malformed(at: i) }
            if bytes[i] == UInt8(ascii: ",") {
                i = skipSpace(i + 1)
                continue
            }
            guard bytes[i] == UInt8(ascii: "}") else { throw .malformed(at: i) }
            return try trailing(i + 1, out)
        }
    }

    private func trailing(_ i: Int, _ out: [Member]) throws(JSONTextError) -> [Member] {
        guard skipSpace(i) == bytes.count else { throw .malformed(at: i) }
        return out
    }

    private func skipSpace(_ start: Int) -> Int {
        var i = start
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        return i
    }

    /// Returns the index after the string that starts at `start`.
    private func skipString(_ start: Int) throws(JSONTextError) -> Int {
        var i = start + 1
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""): return i + 1
            default: i += 1
            }
        }
        throw .malformed(at: start)
    }

    private func skipValue(_ start: Int) throws(JSONTextError) -> Int {
        guard start < bytes.count else { throw .malformed(at: start) }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return try skipString(start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    i = try skipString(i)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            throw .malformed(at: start)
        default:
            var i = start
            while i < bytes.count, !",}] \t\n\r".utf8.contains(bytes[i]) { i += 1 }
            guard i > start else { throw .malformed(at: start) }
            return i
        }
    }
}

public enum JSONTextError: Error, Equatable {
    case notAnObject
    case malformed(at: Int)
}
