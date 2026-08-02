import CryptoKit
import Foundation
import Security

struct X509Certificate {
    private static let subjectAlternativeName = "2.5.29.17"
    private static let keyUsage = "2.5.29.15"
    private static let extendedKeyUsage = "2.5.29.37"
    private static let sctList = "1.3.6.1.4.1.11129.2.4.2"

    let raw: Data
    let tbs: Data
    let spki: Data
    let extensions: [String: Data]
    private let tbsChildren: [DER.Node]
    private let extensionsNodeIndex: Int

    init(_ raw: Data) throws {
        self.raw = raw
        let certificate = try DER.parse(raw)
        let certificateChildren = try certificate.children(in: raw)
        guard certificate.tag == 0x30, certificateChildren.count == 3,
              certificateChildren[0].tag == 0x30
        else { throw AttestationFailure.invalid("invalid X.509 certificate") }
        tbs = certificateChildren[0].encoded(in: raw)
        let children = try certificateChildren[0].children(in: raw)
        tbsChildren = children
        let offset = children.first?.tag == 0xa0 ? 1 : 0
        guard children.count > offset + 5, children[offset + 5].tag == 0x30 else {
            throw AttestationFailure.invalid("missing certificate public key")
        }
        spki = children[offset + 5].encoded(in: raw)
        guard let index = children.firstIndex(where: { $0.tag == 0xa3 }) else {
            throw AttestationFailure.invalid("missing certificate extensions")
        }
        extensionsNodeIndex = index
        let wrapper = try children[index].children(in: raw)
        guard wrapper.count == 1, wrapper[0].tag == 0x30 else {
            throw AttestationFailure.invalid("invalid certificate extensions")
        }
        var parsed = [String: Data]()
        for item in try wrapper[0].children(in: raw) {
            let fields = try item.children(in: raw)
            guard item.tag == 0x30, fields.count == 2 || fields.count == 3,
                  fields[0].tag == 0x06,
                  let value = fields.last, value.tag == 0x04
            else { throw AttestationFailure.invalid("invalid X.509 extension") }
            let oid = try DER.oid(fields[0].content(in: raw))
            guard parsed.updateValue(value.content(in: raw), forKey: oid) == nil else {
                throw AttestationFailure.invalid("duplicate X.509 extension")
            }
        }
        extensions = parsed
    }

    func requireIdentity(_ expected: [String: String], subjectAlternativeName expectedSAN: String) throws {
        guard try uriSubjectAlternativeNames() == [expectedSAN] else {
            throw AttestationFailure.invalid("certificate workflow identity mismatch")
        }
        for (oid, expectedValue) in expected {
            guard try extensionString(oid) == expectedValue else {
                throw AttestationFailure.invalid("certificate claim mismatch")
            }
        }
    }

    func requireSigningUsage() throws {
        guard let usage = extensions[Self.keyUsage] else {
            throw AttestationFailure.invalid("missing certificate key usage")
        }
        let bits = try DER.parse(usage)
        let content = bits.content(in: usage)
        guard bits.tag == 0x03, content.count >= 2, content[0] <= 7,
              content[1] & 0x80 != 0
        else { throw AttestationFailure.invalid("certificate cannot sign") }

        guard let extended = extensions[Self.extendedKeyUsage] else {
            throw AttestationFailure.invalid("missing code-signing EKU")
        }
        let sequence = try DER.parse(extended)
        let oids = try sequence.children(in: extended).map {
            guard $0.tag == 0x06 else { throw AttestationFailure.invalid("invalid EKU") }
            return try DER.oid($0.content(in: extended))
        }
        guard oids.contains("1.3.6.1.5.5.7.3.3") else {
            throw AttestationFailure.invalid("missing code-signing EKU")
        }
    }

    func verifyChain(using authority: SigstoreTrustedRoot.Authority, at date: Date) throws -> Data {
        guard authority.uri == "https://fulcio.sigstore.dev",
              authority.validFor?.contains(date) ?? true,
              let leaf = SecCertificateCreateWithData(nil, raw as CFData)
        else { throw AttestationFailure.invalid("inactive certificate authority") }
        let chain = try authority.certChain.certificates.map { certificate -> SecCertificate in
            guard let value = SecCertificateCreateWithData(nil, certificate.rawBytes as CFData) else {
                throw AttestationFailure.invalid("invalid trust certificate")
            }
            return value
        }
        guard let anchor = chain.last else {
            throw AttestationFailure.invalid("empty certificate chain")
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            [leaf] + chain as CFArray,
            SecPolicyCreateBasicX509(),
            &trust
        ) == errSecSuccess, let trust else {
            throw AttestationFailure.invalid("could not create certificate trust")
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, date as CFDate)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw AttestationFailure.invalid("invalid certificate chain")
        }
        guard chain.count >= 2 else {
            throw AttestationFailure.invalid("missing issuing certificate")
        }
        return try X509Certificate(authority.certChain.certificates[0].rawBytes).spki
    }

    func verifySignature(_ signature: Data, message: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, raw as CFData),
              let key = SecCertificateCopyKey(certificate),
              SecKeyVerifySignature(
                key,
                .ecdsaSignatureMessageX962SHA256,
                message as CFData,
                signature as CFData,
                nil
              )
        else { throw AttestationFailure.invalid("invalid DSSE signature") }
    }

    func verifySCT(issuerSPKI: Data, trustedRoot: SigstoreTrustedRoot) throws {
        guard let encoded = extensions[Self.sctList] else {
            throw AttestationFailure.invalid("missing SCT")
        }
        let octet = try DER.parse(encoded)
        guard octet.tag == 0x04 else { throw AttestationFailure.invalid("invalid SCT list") }
        let list = octet.content(in: encoded)
        var cursor = 0
        let declared = try TLS.readUInt16(list, cursor: &cursor)
        guard declared == list.count - cursor else {
            throw AttestationFailure.invalid("invalid SCT list length")
        }
        var verified = false
        while cursor < list.count {
            let length = try TLS.readUInt16(list, cursor: &cursor)
            guard length > 0, cursor <= list.count - length else {
                throw AttestationFailure.invalid("truncated SCT")
            }
            let item = list.subdata(in: cursor..<(cursor + length))
            cursor += length
            if (try? verifySCTItem(item, issuerSPKI: issuerSPKI, trustedRoot: trustedRoot)) != nil {
                verified = true
            }
        }
        guard verified else { throw AttestationFailure.invalid("no valid SCT") }
    }

    private func verifySCTItem(
        _ data: Data,
        issuerSPKI: Data,
        trustedRoot: SigstoreTrustedRoot
    ) throws {
        var cursor = 0
        guard try TLS.readUInt8(data, cursor: &cursor) == 0 else {
            throw AttestationFailure.invalid("unsupported SCT version")
        }
        let logID = try TLS.read(data, count: 32, cursor: &cursor)
        let timestamp = try TLS.readUInt64(data, cursor: &cursor)
        let extensions = try TLS.readVector16(data, cursor: &cursor)
        guard try TLS.readUInt8(data, cursor: &cursor) == 4,
              try TLS.readUInt8(data, cursor: &cursor) == 3
        else { throw AttestationFailure.invalid("unsupported SCT signature") }
        let signature = try TLS.readVector16(data, cursor: &cursor)
        guard cursor == data.count else { throw AttestationFailure.invalid("trailing SCT data") }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let key = try trustedRoot.logKey(id: logID, at: date, certificateTransparency: true)
        guard key.keyDetails == "PKIX_ECDSA_P256_SHA_256" else {
            throw AttestationFailure.invalid("unsupported CT log key")
        }
        let precertificate = try tbsWithoutSCT()
        var message = Data([0, 0])
        message.append(TLS.uint64(timestamp))
        message.append(contentsOf: [0, 1])
        message.append(issuerSPKI.sha256)
        message.append(TLS.uint24(precertificate.count))
        message.append(precertificate)
        message.append(TLS.uint16(extensions.count))
        message.append(extensions)
        try SignatureVerifier.verifyP256(
            spkiDER: key.rawBytes,
            signatureDER: signature,
            message: message
        )
    }

    private func tbsWithoutSCT() throws -> Data {
        let extensionWrapper = tbsChildren[extensionsNodeIndex]
        let sequence = try extensionWrapper.children(in: raw)[0]
        let retained = try sequence.children(in: raw).filter { item in
            let fields = try item.children(in: raw)
            return try DER.oid(fields[0].content(in: raw)) != Self.sctList
        }
        guard retained.count < (try sequence.children(in: raw)).count else {
            throw AttestationFailure.invalid("SCT extension not found")
        }
        let rebuiltSequence = DER.encode(
            tag: 0x30,
            content: retained.reduce(into: Data()) { $0.append($1.encoded(in: raw)) }
        )
        let rebuiltWrapper = DER.encode(tag: 0xa3, content: rebuiltSequence)
        var content = Data()
        for (index, child) in tbsChildren.enumerated() {
            content.append(index == extensionsNodeIndex ? rebuiltWrapper : child.encoded(in: raw))
        }
        return DER.encode(tag: 0x30, content: content)
    }

    private func extensionString(_ oid: String) throws -> String? {
        guard let encoded = extensions[oid] else { return nil }
        if let value = try? DER.parse(encoded), value.tag == 0x0c || value.tag == 0x16 {
            return String(data: value.content(in: encoded), encoding: .utf8)
        }
        guard let string = String(data: encoded, encoding: .utf8),
              string.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { throw AttestationFailure.invalid("invalid certificate claim") }
        return string
    }

    private func uriSubjectAlternativeNames() throws -> [String] {
        guard let encoded = extensions[Self.subjectAlternativeName] else { return [] }
        let sequence = try DER.parse(encoded)
        return try sequence.children(in: encoded).compactMap { item in
            guard item.tag == 0x86 else { return nil }
            guard let value = String(data: item.content(in: encoded), encoding: .ascii) else {
                throw AttestationFailure.invalid("invalid URI SAN")
            }
            return value
        }
    }
}

private enum TLS {
    static func readUInt8(_ data: Data, cursor: inout Int) throws -> UInt8 {
        guard cursor < data.count else { throw AttestationFailure.invalid("truncated TLS data") }
        defer { cursor += 1 }
        return data[cursor]
    }

    static func readUInt16(_ data: Data, cursor: inout Int) throws -> Int {
        let bytes = try read(data, count: 2, cursor: &cursor)
        return Int(bytes[0]) << 8 | Int(bytes[1])
    }

    static func readUInt64(_ data: Data, cursor: inout Int) throws -> UInt64 {
        let bytes = try read(data, count: 8, cursor: &cursor)
        return bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func readVector16(_ data: Data, cursor: inout Int) throws -> Data {
        try read(data, count: readUInt16(data, cursor: &cursor), cursor: &cursor)
    }

    static func read(_ data: Data, count: Int, cursor: inout Int) throws -> Data {
        guard count >= 0, cursor <= data.count - count else {
            throw AttestationFailure.invalid("truncated TLS data")
        }
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }

    static func uint16(_ value: Int) -> Data {
        Data([UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    static func uint24(_ value: Int) -> Data {
        Data([UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    static func uint64(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xff) })
    }
}
