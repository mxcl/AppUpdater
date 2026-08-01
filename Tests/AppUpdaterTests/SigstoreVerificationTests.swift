@testable import AppUpdater
import XCTest

final class SigstoreVerificationTests: XCTestCase {
    private let digest = Data(
        hex: "e21622e6fdf7a7a05a1d4166c83689929b30337e442fb9fc8ea49331a0d90723"
    )!
    private let commit = "3678ec46fe9e5fde87bcafcbc131e499feef5d5a"

    func testAutomicVault280ProvenanceFixture() async throws {
        let (data, root) = try await fixture()
        try verify(data, root: root)
    }

    func testMutationsAreRejected() async throws {
        let (fixture, root) = try await fixture()
        let mutations: [(String, (inout [String: Any]) throws -> Void)] = [
            ("artifact name", { try Self.mutatePayload(&$0) { payload in
                var subjects = payload["subject"] as! [[String: Any]]
                subjects[0]["name"] = "Other.dmg"
                payload["subject"] = subjects
            }}),
            ("artifact digest", { try Self.mutatePayload(&$0) { payload in
                var subjects = payload["subject"] as! [[String: Any]]
                subjects[0]["digest"] = ["sha256": String(repeating: "0", count: 64)]
                payload["subject"] = subjects
            }}),
            ("DSSE signature", { root in
                var envelope = root["dsseEnvelope"] as! [String: Any]
                var signatures = envelope["signatures"] as! [[String: Any]]
                signatures[0]["sig"] = Data("bad".utf8).base64EncodedString()
                envelope["signatures"] = signatures
                root["dsseEnvelope"] = envelope
            }),
            ("certificate", { root in
                var material = root["verificationMaterial"] as! [String: Any]
                material["certificate"] = ["rawBytes": Data("bad".utf8).base64EncodedString()]
                root["verificationMaterial"] = material
            }),
            ("certificate claim", { try Self.mutateCertificate(&$0) { certificate in
                let claim = Data("automic-vault/automic-vault".utf8)
                let range = try XCTUnwrap(certificate.range(of: claim))
                certificate[range.lowerBound] ^= 1
            }}),
            ("SCT", { try Self.mutateCertificate(&$0) { certificate in
                let oid = Data([0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0xd6, 0x79, 0x02, 0x04, 0x02])
                let range = try XCTUnwrap(certificate.range(of: oid))
                certificate[range.upperBound + 8] ^= 1
            }}),
            ("workflow", { try Self.mutateWorkflow(&$0, key: "path", value: "other.yml") }),
            ("ref", { try Self.mutateWorkflow(&$0, key: "ref", value: "refs/heads/dev") }),
            ("repository", { try Self.mutateWorkflow(&$0, key: "repository", value: "https://github.com/other/repo") }),
            ("source commit", { try Self.mutatePayload(&$0) { payload in
                var predicate = payload["predicate"] as! [String: Any]
                var definition = predicate["buildDefinition"] as! [String: Any]
                var dependencies = definition["resolvedDependencies"] as! [[String: Any]]
                dependencies[0]["digest"] = ["gitCommit": String(repeating: "0", count: 40)]
                definition["resolvedDependencies"] = dependencies
                predicate["buildDefinition"] = definition
                payload["predicate"] = predicate
            }}),
            ("predicate type", { try Self.mutatePayload(&$0) { $0["predicateType"] = "other" } }),
            ("build type", { try Self.mutatePayload(&$0) { payload in
                var predicate = payload["predicate"] as! [String: Any]
                var definition = predicate["buildDefinition"] as! [String: Any]
                definition["buildType"] = "other"
                predicate["buildDefinition"] = definition
                payload["predicate"] = predicate
            }}),
            ("runner", { try Self.mutatePayload(&$0) { payload in
                var predicate = payload["predicate"] as! [String: Any]
                var definition = predicate["buildDefinition"] as! [String: Any]
                var internalParameters = definition["internalParameters"] as! [String: Any]
                var github = internalParameters["github"] as! [String: Any]
                github["runner_environment"] = "self-hosted"
                internalParameters["github"] = github
                definition["internalParameters"] = internalParameters
                predicate["buildDefinition"] = definition
                payload["predicate"] = predicate
            }}),
            ("builder", { try Self.mutatePayload(&$0) { payload in
                var predicate = payload["predicate"] as! [String: Any]
                var details = predicate["runDetails"] as! [String: Any]
                details["builder"] = ["id": "https://github.com/other/repo"]
                predicate["runDetails"] = details
                payload["predicate"] = predicate
            }}),
            ("signing time", { try Self.mutateEntry(&$0) { $0["integratedTime"] = "1" } }),
            ("SET", { try Self.mutateEntry(&$0) { entry in
                entry["inclusionPromise"] = ["signedEntryTimestamp": Data("bad".utf8).base64EncodedString()]
            }}),
            ("inclusion proof", { try Self.mutateEntry(&$0) { entry in
                var proof = entry["inclusionProof"] as! [String: Any]
                proof["rootHash"] = Data(repeating: 0, count: 32).base64EncodedString()
                entry["inclusionProof"] = proof
            }}),
            ("checkpoint", { try Self.mutateEntry(&$0) { entry in
                var proof = entry["inclusionProof"] as! [String: Any]
                proof["checkpoint"] = ["envelope": "bad"]
                entry["inclusionProof"] = proof
            }}),
            ("Rekor body", { try Self.mutateEntry(&$0) { $0["canonicalizedBody"] = Data("{}".utf8).base64EncodedString() } }),
        ]

        for (name, mutation) in mutations {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixture) as? [String: Any]
            )
            try mutation(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try verify(data, root: root), name)
        }
    }

    private func fixture() async throws -> (Data, SigstoreTrustedRoot) {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "AutomicVault-2.8.0.bundle", withExtension: "json")
        )
        let root = try await TUFClient(
            fetch: { _, _ in throw URLError(.notConnectedToInternet) },
            now: { Date(timeIntervalSince1970: 1_785_531_075) }
        ).trustedRoot()
        return (try Data(contentsOf: url), root)
    }

    private func verify(_ data: Data, root: SigstoreTrustedRoot) throws {
        try BundleVerifier(
            owner: "automic-vault",
            repository: "automic-vault",
            policy: .init(
                workflow: ".github/workflows/release.yml",
                sourceRef: "refs/heads/main"
            ),
            trustedRoot: root
        ).verify(
            try JSONDecoder().decode(SigstoreBundle.self, from: data),
            assetName: "Automic-Vault-2.8.0.dmg",
            digest: digest,
            sourceCommit: commit,
            repositoryID: "1228916972"
        )
    }

    private static func mutatePayload(
        _ root: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) throws {
        var envelope = root["dsseEnvelope"] as! [String: Any]
        let data = try XCTUnwrap(Data(base64Encoded: envelope["payload"] as! String))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutation(&payload)
        envelope["payload"] = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
        root["dsseEnvelope"] = envelope
    }

    private static func mutateWorkflow(
        _ root: inout [String: Any], key: String, value: String
    ) throws {
        try mutatePayload(&root) { payload in
            var predicate = payload["predicate"] as! [String: Any]
            var definition = predicate["buildDefinition"] as! [String: Any]
            var external = definition["externalParameters"] as! [String: Any]
            var workflow = external["workflow"] as! [String: Any]
            workflow[key] = value
            external["workflow"] = workflow
            definition["externalParameters"] = external
            predicate["buildDefinition"] = definition
            payload["predicate"] = predicate
        }
    }

    private static func mutateEntry(
        _ root: inout [String: Any], mutation: (inout [String: Any]) -> Void
    ) throws {
        var material = root["verificationMaterial"] as! [String: Any]
        var entries = material["tlogEntries"] as! [[String: Any]]
        mutation(&entries[0])
        material["tlogEntries"] = entries
        root["verificationMaterial"] = material
    }

    private static func mutateCertificate(
        _ root: inout [String: Any], mutation: (inout Data) throws -> Void
    ) throws {
        var material = root["verificationMaterial"] as! [String: Any]
        var certificate = material["certificate"] as! [String: Any]
        var bytes = try XCTUnwrap(Data(base64Encoded: certificate["rawBytes"] as! String))
        try mutation(&bytes)
        certificate["rawBytes"] = bytes.base64EncodedString()
        material["certificate"] = certificate
        root["verificationMaterial"] = material
    }
}
