import CryptoKit
import Foundation

struct SigstoreTrustedRoot: Decodable, Sendable {
    struct Validity: Decodable, Sendable {
        let start: Date?
        let end: Date?

        enum CodingKeys: String, CodingKey { case start, end }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            start = try values.decodeIfPresent(String.self, forKey: .start).map(DateParser.parse)
            end = try values.decodeIfPresent(String.self, forKey: .end).map(DateParser.parse)
        }

        func contains(_ date: Date) -> Bool {
            start.map { $0 <= date } ?? true && end.map { date <= $0 } ?? true
        }
    }

    struct PublicKey: Decodable, Sendable {
        let rawBytes: Data
        let keyDetails: String
        let validFor: Validity?

        enum CodingKeys: String, CodingKey { case rawBytes, keyDetails, validFor }
    }

    struct Log: Decodable, Sendable {
        struct ID: Decodable, Sendable { let keyId: Data }
        let publicKey: PublicKey
        let logId: ID
        let baseUrl: String
    }

    struct Certificate: Decodable, Sendable { let rawBytes: Data }
    struct Chain: Decodable, Sendable { let certificates: [Certificate] }
    struct Authority: Decodable, Sendable {
        let uri: String
        let certChain: Chain
        let validFor: Validity?
    }

    let mediaType: String
    let certificateAuthorities: [Authority]
    let tlogs: [Log]
    let ctlogs: [Log]

    func transparencyLog(
        id: Data,
        at date: Date,
        certificateTransparency: Bool = false
    ) throws -> Log {
        let logs = certificateTransparency ? ctlogs : tlogs
        guard let log = logs.first(where: {
            guard $0.logId.keyId == id,
                  $0.publicKey.validFor?.contains(date) ?? true,
                  let host = URL(string: $0.baseUrl)?.host?.lowercased()
            else { return false }
            return certificateTransparency
                ? host == "ctfe.sigstore.dev"
                : host == "rekor.sigstore.dev" || host.hasSuffix(".rekor.sigstore.dev")
        }) else { throw AttestationFailure.invalid("unknown or inactive transparency log") }
        return log
    }

    func logKey(id: Data, at date: Date, certificateTransparency: Bool = false) throws -> PublicKey {
        try transparencyLog(
            id: id,
            at: date,
            certificateTransparency: certificateTransparency
        ).publicKey
    }
}

enum DateParser {
    static func parse(_ string: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: string) else {
            throw AttestationFailure.invalid("invalid timestamp")
        }
        return date
    }
}

actor TUFClient {
    typealias Fetch = @Sendable (URL, Int) async throws -> Data

    private static let baseURL = URL(string: "https://tuf-repo-cdn.sigstore.dev/")!
    private static let metadataLimit = 1 * 1024 * 1024
    private static let targetLimit = 2 * 1024 * 1024
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let cacheDirectory: URL?
    private let bootstrapRoot: Data?
    private let fallbackTarget: Data?

    init(
        session: URLSession,
        timeout: TimeInterval,
        cacheDirectory: URL? = TUFClient.defaultCacheDirectory,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        fetch = { url, maximumBytes in
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            return try await NetworkTransfer.data(
                for: request,
                with: session,
                maximumBytes: Int64(maximumBytes)
            )
        }
        self.now = now
        self.cacheDirectory = cacheDirectory
        bootstrapRoot = nil
        fallbackTarget = nil
    }

    init(
        fetch: @escaping Fetch,
        cacheDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date,
        bootstrapRoot: Data? = nil,
        fallbackTarget: Data? = nil
    ) {
        self.fetch = fetch
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.bootstrapRoot = bootstrapRoot
        self.fallbackTarget = fallbackTarget
    }

    func trustedRoot() async throws -> SigstoreTrustedRoot {
        let embeddedRoot = try bootstrapRoot ?? resource("tuf-root")
        let embeddedTarget = try fallbackTarget ?? resource("trusted-root")
        do {
            let target = try await refresh(embeddedRoot: embeddedRoot)
            return try decodeTrustedRoot(target)
        } catch where Self.isNetworkFailure(error) {
            if let root = try? verifiedCachedTrustedRoot(embeddedRoot: embeddedRoot) {
                return root
            }
            return try decodeTrustedRoot(embeddedTarget)
        }
    }

    private func verifiedCachedTrustedRoot(embeddedRoot: Data) throws -> SigstoreTrustedRoot {
        var root = try decodeRoot(embeddedRoot)
        var next = root.signed.version + 1
        while let data = try? cachedData("root-\(next).json") {
            root = try verifiedRootUpdate(data, previous: root, expectedVersion: next)
            next += 1
        }
        try requireUnexpired(root.signed.expires)

        let timestampData = try cachedData("timestamp.json")
        let timestamp: TUFEnvelope<TUFTimestamp> = try verify(
            timestampData, role: "timestamp", root: root, expectedType: "timestamp"
        )
        guard let snapshotMeta = timestamp.signed.meta["snapshot.json"] else {
            throw AttestationFailure.invalid("missing cached snapshot metadata")
        }
        let snapshotData = try cachedData("snapshot.json")
        try verifyFile(snapshotData, metadata: snapshotMeta)
        let snapshot: TUFEnvelope<TUFSnapshot> = try verify(
            snapshotData, role: "snapshot", root: root, expectedType: "snapshot"
        )
        guard snapshot.signed.version == snapshotMeta.version,
              let targetsMeta = snapshot.signed.meta["targets.json"]
        else { throw AttestationFailure.invalid("invalid cached snapshot") }

        let targetsData = try cachedData("targets.json")
        try verifyFile(targetsData, metadata: targetsMeta)
        let targets: TUFEnvelope<TUFTargets> = try verify(
            targetsData, role: "targets", root: root, expectedType: "targets"
        )
        guard targets.signed.version == targetsMeta.version,
              let targetMeta = targets.signed.targets["trusted_root.json"]
        else { throw AttestationFailure.invalid("invalid cached targets") }

        let targetData = try cachedData("trusted-root.json")
        try verifyFile(targetData, metadata: targetMeta, requireIntegrity: true)
        return try decodeTrustedRoot(targetData)
    }

    private func refresh(embeddedRoot: Data) async throws -> Data {
        var rootData = embeddedRoot
        var root = try decodeRoot(rootData)
        var rotations = 0
        if let cacheDirectory {
            var next = root.signed.version + 1
            while let cached = try? Data(contentsOf: cacheDirectory.appendingPathComponent("root-\(next).json")) {
                guard rotations < 64 else {
                    throw AttestationFailure.invalid("too many cached TUF roots")
                }
                let candidate = try verifiedRootUpdate(cached, previous: root, expectedVersion: next)
                rootData = cached
                root = candidate
                next += 1
                rotations += 1
            }
        }

        while true {
            guard rotations < 64 else {
                throw AttestationFailure.invalid("too many TUF root rotations")
            }
            let next = root.signed.version + 1
            let url = Self.baseURL.appendingPathComponent("\(next).root.json")
            let data: Data
            do {
                data = try await fetch(url, Self.metadataLimit)
            } catch where Self.isNetworkFailure(error) {
                break
            }
            let candidate = try verifiedRootUpdate(data, previous: root, expectedVersion: next)
            rootData = data
            root = candidate
            try cache(data, name: "root-\(next).json")
            rotations += 1
        }
        try requireUnexpired(root.signed.expires)

        let timestampData = try await fetch(Self.baseURL.appendingPathComponent("timestamp.json"), Self.metadataLimit)
        let timestamp: TUFEnvelope<TUFTimestamp> = try verify(
            timestampData,
            role: "timestamp",
            root: root,
            expectedType: "timestamp"
        )
        try rejectRollback(
            timestamp.signed.version,
            cached: "timestamp.json",
            role: "timestamp",
            root: root,
            as: TUFTimestamp.self
        )
        guard let snapshotMeta = timestamp.signed.meta["snapshot.json"] else {
            throw AttestationFailure.invalid("missing snapshot metadata")
        }
        let snapshotData = try await fetch(
            Self.baseURL.appendingPathComponent("\(snapshotMeta.version).snapshot.json"),
            Self.metadataLimit
        )
        try verifyFile(snapshotData, metadata: snapshotMeta)
        let snapshot: TUFEnvelope<TUFSnapshot> = try verify(
            snapshotData,
            role: "snapshot",
            root: root,
            expectedType: "snapshot"
        )
        guard snapshot.signed.version == snapshotMeta.version else {
            throw AttestationFailure.invalid("snapshot version mismatch")
        }
        try rejectRollback(
            snapshot.signed.version,
            cached: "snapshot.json",
            role: "snapshot",
            root: root,
            as: TUFSnapshot.self
        )

        guard let targetsMeta = snapshot.signed.meta["targets.json"] else {
            throw AttestationFailure.invalid("missing targets metadata")
        }
        let targetsData = try await fetch(
            Self.baseURL.appendingPathComponent("\(targetsMeta.version).targets.json"),
            Self.metadataLimit
        )
        try verifyFile(targetsData, metadata: targetsMeta)
        let targets: TUFEnvelope<TUFTargets> = try verify(
            targetsData,
            role: "targets",
            root: root,
            expectedType: "targets"
        )
        guard targets.signed.version == targetsMeta.version else {
            throw AttestationFailure.invalid("targets version mismatch")
        }
        try rejectRollback(
            targets.signed.version,
            cached: "targets.json",
            role: "targets",
            root: root,
            as: TUFTargets.self
        )

        guard let targetMeta = targets.signed.targets["trusted_root.json"],
              let hash = targetMeta.hashes?["sha256"],
              hash.count == 64
        else { throw AttestationFailure.invalid("missing trusted root target") }
        let targetData = try await fetch(
            Self.baseURL.appendingPathComponent("targets/\(hash).trusted_root.json"),
            Self.targetLimit
        )
        try verifyFile(targetData, metadata: targetMeta, requireIntegrity: true)
        _ = try decodeTrustedRoot(targetData)

        try cache(rootData, name: "root.json")
        try cache(timestampData, name: "timestamp.json")
        try cache(snapshotData, name: "snapshot.json")
        try cache(targetsData, name: "targets.json")
        try cache(targetData, name: "trusted-root.json")
        return targetData
    }

    private func verifiedRootUpdate(
        _ data: Data,
        previous: TUFEnvelope<TUFRoot>,
        expectedVersion: Int
    ) throws -> TUFEnvelope<TUFRoot> {
        let candidate: TUFEnvelope<TUFRoot> = try decode(data)
        guard candidate.signed.type == "root", candidate.signed.version == expectedVersion else {
            throw AttestationFailure.invalid("invalid root rotation")
        }
        try verifySignatures(data, role: "root", root: previous)
        try verifySignatures(data, role: "root", root: candidate)
        try requireUnexpired(candidate.signed.expires)
        return candidate
    }

    private func verify<T: TUFMetadata & Decodable>(
        _ data: Data,
        role: String,
        root: TUFEnvelope<TUFRoot>,
        expectedType: String
    ) throws -> TUFEnvelope<T> {
        let envelope: TUFEnvelope<T> = try decode(data)
        guard envelope.signed.type == expectedType else {
            throw AttestationFailure.invalid("unexpected TUF metadata type")
        }
        try requireUnexpired(envelope.signed.expires)
        try verifySignatures(data, role: role, root: root)
        return envelope
    }

    private func verifySignatures(
        _ data: Data,
        role: String,
        root: TUFEnvelope<TUFRoot>
    ) throws {
        let raw = try rawEnvelope(data)
        guard let roleDefinition = root.signed.roles[role] else {
            throw AttestationFailure.invalid("unknown TUF role")
        }
        let envelope = try JSONDecoder().decode(TUFSignaturesEnvelope.self, from: data)
        let message = try JSONCanonicalizer.canonicalizeTUF(raw.signed)
        var verified = Set<String>()
        for signature in envelope.signatures where roleDefinition.keyids.contains(signature.keyid) {
            guard !verified.contains(signature.keyid),
                  let key = root.signed.keys[signature.keyid],
                  key.keytype == "ecdsa",
                  key.scheme == "ecdsa-sha2-nistp256",
                  let signatureData = Data(hex: signature.sig),
                  let publicKey = key.keyval.publicKeyDER
            else { continue }
            if (try? SignatureVerifier.verifyP256(
                spkiDER: publicKey,
                signatureDER: signatureData,
                message: message
            )) != nil {
                verified.insert(signature.keyid)
            }
        }
        guard verified.count >= roleDefinition.threshold else {
            throw AttestationFailure.invalid("TUF signature threshold not met for \(role)")
        }
    }

    private func rawEnvelope(_ data: Data) throws -> (signed: Any, signatures: Any) {
        guard data.count <= Self.metadataLimit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signed = object["signed"], let signatures = object["signatures"]
        else { throw AttestationFailure.invalid("invalid TUF envelope") }
        return (signed, signatures)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> TUFEnvelope<T> {
        guard data.count <= Self.metadataLimit else {
            throw AttestationFailure.invalid("TUF metadata exceeds limit")
        }
        return try JSONDecoder().decode(TUFEnvelope<T>.self, from: data)
    }

    private func decodeRoot(_ data: Data) throws -> TUFEnvelope<TUFRoot> { try decode(data) }

    private func decodeTrustedRoot(_ data: Data) throws -> SigstoreTrustedRoot {
        guard data.count <= Self.targetLimit else {
            throw AttestationFailure.invalid("trusted root exceeds limit")
        }
        let root = try JSONDecoder().decode(SigstoreTrustedRoot.self, from: data)
        guard root.mediaType == "application/vnd.dev.sigstore.trustedroot+json;version=0.1" else {
            throw AttestationFailure.invalid("unsupported trusted root")
        }
        return root
    }

    private func requireUnexpired(_ string: String) throws {
        guard try DateParser.parse(string) > now() else {
            throw AttestationFailure.invalid("expired TUF metadata")
        }
    }

    private func verifyFile(
        _ data: Data,
        metadata: TUFFileMetadata,
        requireIntegrity: Bool = false
    ) throws {
        if requireIntegrity && (metadata.length == nil || metadata.hashes?["sha256"] == nil) {
            throw AttestationFailure.invalid("missing TUF file integrity metadata")
        }
        if let length = metadata.length, data.count != length {
            throw AttestationFailure.invalid("TUF file length mismatch")
        }
        if let expected = metadata.hashes?["sha256"],
           (expected.count != 64 || data.sha256.hex != expected)
        {
            throw AttestationFailure.invalid("TUF file hash mismatch")
        }
    }

    private func rejectRollback<T: TUFMetadata & Decodable>(
        _ version: Int,
        cached name: String,
        role: String,
        root: TUFEnvelope<TUFRoot>,
        as type: T.Type
    ) throws {
        guard let data = try? cachedData(name) else { return }
        let envelope: TUFEnvelope<T>
        do {
            envelope = try decode(data)
            try verifySignatures(data, role: role, root: root)
        } catch { return }
        guard version >= envelope.signed.version else {
            throw AttestationFailure.invalid("TUF metadata rollback")
        }
    }

    private func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw AttestationFailure.invalid("missing trust bootstrap")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func cachedData(_ name: String) throws -> Data {
        guard let cacheDirectory else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: cacheDirectory.appendingPathComponent(name), options: .mappedIfSafe)
    }

    private func cache(_ data: Data, name: String) throws {
        guard let cacheDirectory else { return }
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = cacheDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppUpdater/SigstoreTUF", isDirectory: true)
    }

    private static func isNetworkFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? URLError { return error.code != .cancelled }
        guard let error = error as? AppUpdaterError else { return false }
        return error == .invalidHTTPResponse || error == .operationTimedOut
    }
}

private protocol TUFMetadata {
    var type: String { get }
    var expires: String { get }
    var version: Int { get }
}

private struct TUFEnvelope<T: Decodable>: Decodable {
    let signed: T
    let signatures: [TUFSignature]
}

private struct TUFSignature: Decodable { let keyid: String; let sig: String }

private struct TUFSignaturesEnvelope: Decodable { let signatures: [TUFSignature] }

private struct TUFRoot: TUFMetadata, Decodable {
    let type: String
    let expires: String
    let version: Int
    let consistentSnapshot: Bool
    let keys: [String: TUFKey]
    let roles: [String: TUFRole]

    enum CodingKeys: String, CodingKey {
        case type = "_type", expires, version, consistentSnapshot = "consistent_snapshot", keys, roles
    }
}

private struct TUFKey: Decodable {
    struct Value: Decodable {
        let `public`: String
        var publicKeyDER: Data? {
            let lines = `public`.split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("-----") }
                .joined()
            return Data(base64Encoded: lines)
        }
    }
    let keytype: String
    let scheme: String
    let keyval: Value
}

private struct TUFRole: Decodable { let keyids: [String]; let threshold: Int }

private struct TUFTimestamp: TUFMetadata, Decodable {
    let type: String; let expires: String; let version: Int
    let meta: [String: TUFFileMetadata]
    enum CodingKeys: String, CodingKey { case type = "_type", expires, version, meta }
}

private struct TUFSnapshot: TUFMetadata, Decodable {
    let type: String; let expires: String; let version: Int
    let meta: [String: TUFFileMetadata]
    enum CodingKeys: String, CodingKey { case type = "_type", expires, version, meta }
}

private struct TUFTargets: TUFMetadata, Decodable {
    let type: String; let expires: String; let version: Int
    let targets: [String: TUFFileMetadata]
    enum CodingKeys: String, CodingKey { case type = "_type", expires, version, targets }
}

private struct TUFFileMetadata: Decodable {
    let version: Int
    let length: Int?
    let hashes: [String: String]?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        length = try values.decodeIfPresent(Int.self, forKey: .length)
        hashes = try values.decodeIfPresent([String: String].self, forKey: .hashes)
    }

    enum CodingKeys: String, CodingKey { case version, length, hashes }
}
