import CryptoKit
import Foundation

enum AttestationFailure: Error, Equatable {
    case invalid(String)
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    var sha256: Data { Data(SHA256.hash(data: self)) }
}

enum JSONCanonicalizer {
    static func canonicalize(_ value: Any) throws -> Data {
        try canonicalize(value, tuf: false)
    }

    static func canonicalizeTUF(_ value: Any) throws -> Data {
        try canonicalize(value, tuf: true)
    }

    private static func canonicalize(_ value: Any, tuf: Bool) throws -> Data {
        var output = Data()
        try append(value, tuf: tuf, to: &output)
        return output
    }

    private static func append(_ value: Any, tuf: Bool, to output: inout Data) throws {
        switch value {
        case let dictionary as [String: Any]:
            output.append(UInt8(ascii: "{"))
            for (offset, key) in dictionary.keys.sorted().enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                try appendString(key, tuf: tuf, to: &output)
                output.append(UInt8(ascii: ":"))
                guard let item = dictionary[key] else {
                    throw AttestationFailure.invalid("missing JSON value")
                }
                try append(item, tuf: tuf, to: &output)
            }
            output.append(UInt8(ascii: "}"))
        case let array as [Any]:
            output.append(UInt8(ascii: "["))
            for (offset, item) in array.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                try append(item, tuf: tuf, to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case let string as String:
            try appendString(string, tuf: tuf, to: &output)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output.append(contentsOf: number.boolValue ? Data("true".utf8) : Data("false".utf8))
            } else {
                let double = number.doubleValue
                guard double.isFinite, double.rounded() == double else {
                    throw AttestationFailure.invalid("non-integer JSON number")
                }
                output.append(contentsOf: Data(String(number.int64Value).utf8))
            }
        case _ as NSNull:
            output.append(contentsOf: Data("null".utf8))
        default:
            throw AttestationFailure.invalid("unsupported JSON value")
        }
    }

    private static func appendString(_ string: String, tuf: Bool, to output: inout Data) throws {
        output.append(UInt8(ascii: "\""))
        for scalar in string.unicodeScalars {
            if tuf {
                if scalar.value == 0x22 || scalar.value == 0x5c {
                    output.append(UInt8(ascii: "\\"))
                }
                output.append(contentsOf: Data(String(scalar).utf8))
                continue
            }
            switch scalar.value {
            case 0x08: output.append(contentsOf: Data(#"\b"#.utf8))
            case 0x09: output.append(contentsOf: Data(#"\t"#.utf8))
            case 0x0a: output.append(contentsOf: Data(#"\n"#.utf8))
            case 0x0c: output.append(contentsOf: Data(#"\f"#.utf8))
            case 0x0d: output.append(contentsOf: Data(#"\r"#.utf8))
            case 0x22: output.append(contentsOf: Data(#"\""#.utf8))
            case 0x5c: output.append(contentsOf: Data(#"\\"#.utf8))
            case 0..<0x20:
                output.append(contentsOf: Data(String(format: #"\u%04x"#, scalar.value).utf8))
            default:
                output.append(contentsOf: Data(String(scalar).utf8))
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}

enum SignatureVerifier {
    static func verifyP256(spkiDER: Data, signatureDER: Data, message: Data) throws {
        let key = try P256.Signing.PublicKey(derRepresentation: spkiDER)
        let signature = if signatureDER.count == 64 {
            try P256.Signing.ECDSASignature(rawRepresentation: signatureDER)
        } else {
            try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        }
        guard key.isValidSignature(signature, for: message) else {
            throw AttestationFailure.invalid("invalid P-256 signature")
        }
    }

    static func verifyEd25519(spkiDER: Data, signature: Data, message: Data) throws {
        let node = try DER.parse(spkiDER)
        let children = try node.children(in: spkiDER)
        guard children.count == 2,
              children[1].tag == 0x03,
              children[1].content(in: spkiDER).first == 0,
              children[1].content(in: spkiDER).count == 33
        else { throw AttestationFailure.invalid("invalid Ed25519 SPKI") }
        let rawKey = children[1].content(in: spkiDER).dropFirst()
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        guard key.isValidSignature(signature, for: message) else {
            throw AttestationFailure.invalid("invalid Ed25519 signature")
        }
    }
}

struct DER {
    struct Node {
        let tag: UInt8
        let encodedRange: Range<Int>
        let contentRange: Range<Int>

        func encoded(in data: Data) -> Data { data.subdata(in: encodedRange) }
        func content(in data: Data) -> Data { data.subdata(in: contentRange) }

        func children(in data: Data) throws -> [Node] {
            var offset = contentRange.lowerBound
            var result = [Node]()
            while offset < contentRange.upperBound {
                let node = try DER.parse(data, at: &offset)
                guard node.encodedRange.upperBound <= contentRange.upperBound else {
                    throw AttestationFailure.invalid("DER child exceeds parent")
                }
                result.append(node)
            }
            guard offset == contentRange.upperBound else {
                throw AttestationFailure.invalid("invalid DER children")
            }
            return result
        }
    }

    static func parse(_ data: Data) throws -> Node {
        var offset = 0
        let node = try parse(data, at: &offset)
        guard offset == data.count else {
            throw AttestationFailure.invalid("trailing DER data")
        }
        return node
    }

    static func parse(_ data: Data, at offset: inout Int) throws -> Node {
        let start = offset
        guard offset < data.count else { throw AttestationFailure.invalid("truncated DER tag") }
        let tag = data[offset]
        offset += 1
        guard tag & 0x1f != 0x1f, offset < data.count else {
            throw AttestationFailure.invalid("unsupported DER tag")
        }
        let first = data[offset]
        offset += 1
        let length: Int
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard count > 0, count <= MemoryLayout<Int>.size, offset + count <= data.count,
                  data[offset] != 0
            else { throw AttestationFailure.invalid("invalid DER length") }
            var value = 0
            for byte in data[offset..<(offset + count)] {
                guard value <= (Int.max - Int(byte)) / 256 else {
                    throw AttestationFailure.invalid("DER length overflow")
                }
                value = value * 256 + Int(byte)
            }
            offset += count
            length = value
        }
        let contentStart = offset
        guard length >= 0, contentStart <= data.count - length else {
            throw AttestationFailure.invalid("truncated DER content")
        }
        offset += length
        return Node(
            tag: tag,
            encodedRange: start..<offset,
            contentRange: contentStart..<offset
        )
    }

    static func encode(tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        if content.count < 128 {
            result.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes = [UInt8]()
            while length > 0 {
                bytes.append(UInt8(length & 0xff))
                length >>= 8
            }
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes.reversed())
        }
        result.append(content)
        return result
    }

    static func oid(_ data: Data) throws -> String {
        guard let first = data.first else { throw AttestationFailure.invalid("empty OID") }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        var active = false
        for byte in data.dropFirst() {
            active = true
            guard value <= (Int.max - Int(byte & 0x7f)) / 128 else {
                throw AttestationFailure.invalid("OID overflow")
            }
            value = value * 128 + Int(byte & 0x7f)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
                active = false
            }
        }
        guard !active else { throw AttestationFailure.invalid("truncated OID") }
        return parts.map(String.init).joined(separator: ".")
    }
}

enum Snappy {
    static func decompress(_ input: Data, maximumOutputBytes: Int) throws -> Data {
        var cursor = 0
        let expected = try readVarint(input, cursor: &cursor)
        guard expected <= maximumOutputBytes else {
            throw AttestationFailure.invalid("Snappy output exceeds limit")
        }
        var output = Data()
        output.reserveCapacity(expected)
        while cursor < input.count, output.count < expected {
            let tag = input[cursor]
            cursor += 1
            switch tag & 0x03 {
            case 0:
                var length = Int(tag >> 2)
                if length < 60 {
                    length += 1
                } else {
                    let count = length - 59
                    guard count <= 4, cursor + count <= input.count else {
                        throw AttestationFailure.invalid("invalid Snappy literal")
                    }
                    length = 1
                    for index in 0..<count { length += Int(input[cursor + index]) << (8 * index) }
                    cursor += count
                }
                guard length <= expected - output.count, cursor + length <= input.count else {
                    throw AttestationFailure.invalid("truncated Snappy literal")
                }
                output.append(input[cursor..<(cursor + length)])
                cursor += length
            case 1:
                let length = 4 + Int((tag >> 2) & 0x7)
                guard cursor < input.count else { throw AttestationFailure.invalid("truncated Snappy copy") }
                let offset = Int(tag & 0xe0) << 3 | Int(input[cursor])
                cursor += 1
                try copy(length: length, offset: offset, into: &output, expected: expected)
            case 2:
                guard cursor + 2 <= input.count else { throw AttestationFailure.invalid("truncated Snappy copy") }
                let offset = Int(input[cursor]) | Int(input[cursor + 1]) << 8
                cursor += 2
                try copy(length: 1 + Int(tag >> 2), offset: offset, into: &output, expected: expected)
            default:
                guard cursor + 4 <= input.count else { throw AttestationFailure.invalid("truncated Snappy copy") }
                var offset = 0
                for index in 0..<4 { offset |= Int(input[cursor + index]) << (8 * index) }
                cursor += 4
                try copy(length: 1 + Int(tag >> 2), offset: offset, into: &output, expected: expected)
            }
        }
        guard output.count == expected, cursor == input.count else {
            throw AttestationFailure.invalid("invalid Snappy stream")
        }
        return output
    }

    private static func readVarint(_ input: Data, cursor: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        while cursor < input.count, shift <= 28 {
            let byte = input[cursor]
            cursor += 1
            value |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw AttestationFailure.invalid("invalid Snappy length")
    }

    private static func copy(length: Int, offset: Int, into output: inout Data, expected: Int) throws {
        guard offset > 0, offset <= output.count, length <= expected - output.count else {
            throw AttestationFailure.invalid("invalid Snappy copy")
        }
        for _ in 0..<length { output.append(output[output.count - offset]) }
    }
}

enum Merkle {
    static func verify(
        body: Data,
        leafIndex: UInt64,
        treeSize: UInt64,
        hashes: [Data],
        expectedRoot: Data
    ) throws {
        guard leafIndex < treeSize, expectedRoot.count == 32 else {
            throw AttestationFailure.invalid("invalid Merkle proof bounds")
        }
        let inner = 64 - (leafIndex ^ (treeSize - 1)).leadingZeroBitCount
        let border = (leafIndex >> UInt64(inner)).nonzeroBitCount
        guard hashes.count == inner + border else {
            throw AttestationFailure.invalid("invalid Merkle proof length")
        }
        var hash = Data([0]).appending(body).sha256
        for (level, sibling) in hashes.enumerated() {
            guard sibling.count == 32 else {
                throw AttestationFailure.invalid("invalid Merkle hash")
            }
            if level < inner, (leafIndex >> UInt64(level)) & 1 == 0 {
                hash = Data([1]).appending(hash).appending(sibling).sha256
            } else {
                hash = Data([1]).appending(sibling).appending(hash).sha256
            }
        }
        guard hash == expectedRoot else {
            throw AttestationFailure.invalid("invalid Merkle inclusion proof")
        }
    }
}

private extension Data {
    func appending(_ other: Data) -> Data {
        var result = self
        result.append(other)
        return result
    }
}
