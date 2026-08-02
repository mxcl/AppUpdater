import CryptoKit
import Foundation
import Security

public struct GitHubAttestationPolicy: Sendable, Equatable {
    public let workflow: String
    public let sourceRef: String

    public init(workflow: String, sourceRef: String) {
        self.workflow = workflow
        self.sourceRef = sourceRef
    }
}

enum FileHasher {
    static func sha256(_ url: URL, maximumBytes: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            guard Int64(chunk.count) <= maximumBytes - total else {
                throw AttestationFailure.invalid("file exceeds hashing limit")
            }
            total += Int64(chunk.count)
            hash.update(data: chunk)
        }
        guard total > 0 else { throw AttestationFailure.invalid("empty artifact") }
        return Data(hash.finalize())
    }
}

extension String {
    var isFullGitCommit: Bool {
        count == 40 && unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

struct GitHubAttestationVerifier: Sendable {
    private static let predicateType = "https://slsa.dev/provenance/v1"
    private static let maximumResponseBytes: Int64 = 2 * 1024 * 1024
    private static let maximumBundleBytes = 8 * 1024 * 1024
    private static let maximumAttestations = 16

    let owner: String
    let repository: String
    let policy: GitHubAttestationPolicy
    let session: URLSession
    let timeout: TimeInterval

    func verify(assetName: String, digest: Data, sourceCommit: String) async throws {
        try validatePolicy()
        let digestText = digest.hex
        var components = URLComponents(
            string: "https://api.github.com/repos/\(owner)/\(repository)/attestations/sha256:\(digestText)"
        )!
        components.queryItems = [.init(name: "predicate_type", value: Self.predicateType)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data = try await NetworkTransfer.data(
            for: request,
            with: session,
            maximumBytes: Self.maximumResponseBytes,
            allowedContentTypes: ["application/json", "application/vnd.github+json"],
            permitsCompression: false
        )
        let response = try JSONDecoder().decode(AttestationResponse.self, from: data)
        guard !response.attestations.isEmpty,
              response.attestations.count <= Self.maximumAttestations
        else { throw AttestationFailure.invalid("invalid attestation count") }

        let trustedRoot = try await TUFClient(session: session, timeout: timeout).trustedRoot()
        var lastError: Error?
        for item in response.attestations {
            do {
                guard item.repositoryID > 0 else {
                    throw AttestationFailure.invalid("invalid repository id")
                }
                let bundle = try await fetchBundle(item.bundleURL)
                try BundleVerifier(
                    owner: owner,
                    repository: repository,
                    policy: policy,
                    trustedRoot: trustedRoot
                ).verify(
                    bundle,
                    assetName: assetName,
                    digest: digest,
                    sourceCommit: sourceCommit,
                    repositoryID: String(item.repositoryID)
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AttestationFailure.invalid("no matching provenance")
    }

    private func fetchBundle(_ url: URL) async throws -> SigstoreBundle {
        guard url.scheme?.lowercased() == "https" else {
            throw AttestationFailure.invalid("insecure bundle URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let compressed = try await NetworkTransfer.data(
            for: request,
            with: session,
            maximumBytes: Self.maximumResponseBytes,
            allowedContentTypes: ["application/x-snappy"],
            permitsCompression: false
        )
        let raw = try Snappy.decompress(compressed, maximumOutputBytes: Self.maximumBundleBytes)
        return try JSONDecoder().decode(SigstoreBundle.self, from: raw)
    }

    private func validatePolicy() throws {
        guard owner.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#, options: .regularExpression) != nil,
              repository.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              policy.workflow.hasPrefix(".github/workflows/"),
              !policy.workflow.contains(".."),
              policy.workflow.hasSuffix(".yml") || policy.workflow.hasSuffix(".yaml"),
              policy.sourceRef.hasPrefix("refs/heads/"),
              !policy.sourceRef.contains("..")
        else { throw AttestationFailure.invalid("invalid attestation policy") }
    }
}

private struct AttestationResponse: Decodable {
    struct Item: Decodable {
        let repositoryID: Int64
        let bundleURL: URL
        enum CodingKeys: String, CodingKey {
            case repositoryID = "repository_id"
            case bundleURL = "bundle_url"
        }
    }
    let attestations: [Item]
}

struct SigstoreBundle: Decodable {
    struct VerificationMaterial: Decodable {
        struct Certificate: Decodable { let rawBytes: Data }
        let certificate: Certificate
        let tlogEntries: [TransparencyEntry]
    }
    struct Envelope: Decodable {
        struct Signature: Decodable { let sig: Data }
        let payload: Data
        let payloadType: String
        let signatures: [Signature]
    }
    let mediaType: String
    let verificationMaterial: VerificationMaterial
    let dsseEnvelope: Envelope
}

struct TransparencyEntry: Decodable {
    struct LogID: Decodable { let keyId: Data }
    struct KindVersion: Decodable { let kind: String; let version: String }
    struct Promise: Decodable { let signedEntryTimestamp: Data }
    struct Proof: Decodable {
        struct Checkpoint: Decodable { let envelope: String }
        let logIndex: String
        let rootHash: Data
        let treeSize: String
        let hashes: [Data]
        let checkpoint: Checkpoint
    }
    let logIndex: String
    let logId: LogID
    let kindVersion: KindVersion
    let integratedTime: String
    let inclusionPromise: Promise
    let inclusionProof: Proof
    let canonicalizedBody: Data
}

struct Statement: Decodable {
    struct Subject: Decodable { let name: String; let digest: [String: String] }
    struct Predicate: Decodable {
        struct BuildDefinition: Decodable {
            struct ExternalParameters: Decodable {
                struct Workflow: Decodable { let ref: String; let repository: String; let path: String }
                let workflow: Workflow
            }
            struct InternalParameters: Decodable {
                struct GitHub: Decodable {
                    let eventName: String
                    let repositoryID: String
                    let repositoryOwnerID: String
                    let runnerEnvironment: String
                    enum CodingKeys: String, CodingKey {
                        case eventName = "event_name"
                        case repositoryID = "repository_id"
                        case repositoryOwnerID = "repository_owner_id"
                        case runnerEnvironment = "runner_environment"
                    }
                }
                let github: GitHub
            }
            struct Dependency: Decodable { let uri: String; let digest: [String: String] }
            let buildType: String
            let externalParameters: ExternalParameters
            let internalParameters: InternalParameters
            let resolvedDependencies: [Dependency]
        }
        struct RunDetails: Decodable {
            struct Builder: Decodable { let id: String }
            struct Metadata: Decodable { let invocationId: String }
            let builder: Builder
            let metadata: Metadata
        }
        let buildDefinition: BuildDefinition
        let runDetails: RunDetails
    }
    let type: String
    let subject: [Subject]
    let predicateType: String
    let predicate: Predicate
    enum CodingKeys: String, CodingKey {
        case type = "_type", subject, predicateType, predicate
    }
}

struct RekorBody: Decodable {
    struct Spec: Decodable {
        struct Hash: Decodable { let algorithm: String; let value: String }
        struct Signature: Decodable { let signature: String; let verifier: String }
        let envelopeHash: Hash
        let payloadHash: Hash
        let signatures: [Signature]
    }
    let apiVersion: String
    let kind: String
    let spec: Spec
}
