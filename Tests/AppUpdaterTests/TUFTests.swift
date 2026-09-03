@testable import AppUpdater
import XCTest

final class TUFTests: XCTestCase {
    private let validDate = Date(timeIntervalSince1970: 1_785_531_075)

    func testSequentialRootRotationAndMetadataChain() async throws {
        let files = try fixtureFiles()
        let root = try await client(files: files, bootstrap: files["14.root.json"]!).trustedRoot()
        XCTAssertFalse(root.certificateAuthorities.isEmpty)
        XCTAssertFalse(root.tlogs.isEmpty)
    }

    func testRootRotationRequiresSignatureThreshold() async throws {
        var files = try fixtureFiles()
        var root = try json(files["15.root.json"]!)
        root["signatures"] = []
        files["15.root.json"] = try JSONSerialization.data(withJSONObject: root)
        await XCTAssertThrowsErrorAsync {
            _ = try await self.client(files: files, bootstrap: files["14.root.json"]!).trustedRoot()
        }
    }

    func testTamperedTruncatedAndUnknownKeyMetadataAreRejected() async throws {
        let originals = try fixtureFiles()
        var cases = [[String: Data]]()

        var truncated = originals
        truncated["timestamp.json"] = Data(#"{"signed":"#.utf8)
        cases.append(truncated)

        var hashMismatch = originals
        hashMismatch[
            "6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66.trusted_root.json"
        ]!.append(0x20)
        cases.append(hashMismatch)

        var snapshotMismatch = originals
        var snapshot = try json(snapshotMismatch["165.snapshot.json"]!)
        var snapshotSigned = snapshot["signed"] as! [String: Any]
        snapshotSigned["version"] = 1
        snapshot["signed"] = snapshotSigned
        snapshotMismatch["165.snapshot.json"] = try JSONSerialization.data(withJSONObject: snapshot)
        cases.append(snapshotMismatch)

        var targetsMismatch = originals
        var targets = try json(targetsMismatch["14.targets.json"]!)
        var targetsSigned = targets["signed"] as! [String: Any]
        targetsSigned["version"] = 1
        targets["signed"] = targetsSigned
        targetsMismatch["14.targets.json"] = try JSONSerialization.data(withJSONObject: targets)
        cases.append(targetsMismatch)

        var unknownKey = originals
        var timestamp = try json(unknownKey["timestamp.json"]!)
        var signatures = timestamp["signatures"] as! [[String: Any]]
        signatures[0]["keyid"] = String(repeating: "0", count: 64)
        timestamp["signatures"] = signatures
        unknownKey["timestamp.json"] = try JSONSerialization.data(withJSONObject: timestamp)
        cases.append(unknownKey)

        for files in cases {
            await XCTAssertThrowsErrorAsync {
                _ = try await self.client(files: files).trustedRoot()
            }
        }
    }

    func testExpiredMetadataIsRejected() async throws {
        await XCTAssertThrowsErrorAsync {
            _ = try await self.client(
                files: try self.fixtureFiles(),
                now: Date(timeIntervalSince1970: 1_786_160_000)
            ).trustedRoot()
        }
    }

    func testRollbackIsRejected() async throws {
        let files = try fixtureFiles(timestamp: "742.timestamp.json")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: cache) }
        try fixture("timestamp.json").write(
            to: cache.appendingPathComponent("timestamp.json"),
            options: .atomic
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await self.client(files: files, cache: cache).trustedRoot()
        }
    }

    func testMappedNetworkFailureUsesEmbeddedFallback() async throws {
        let date = validDate
        let client = TUFClient(
            fetch: { _, _ in
                throw AppUpdaterNetworkError(
                    host: "tuf-repo-cdn.sigstore.dev",
                    code: .notConnectedToInternet
                )
            },
            now: { date },
            bootstrapRoot: try fixture("15.root.json"),
            fallbackTarget: try fixture("trusted-root.json")
        )

        let root = try await client.trustedRoot()
        XCTAssertFalse(root.certificateAuthorities.isEmpty)
    }

    func testMappedCancellationDoesNotUseEmbeddedFallback() async throws {
        let date = validDate
        let client = TUFClient(
            fetch: { _, _ in
                throw AppUpdaterNetworkError(
                    host: "tuf-repo-cdn.sigstore.dev",
                    code: .cancelled
                )
            },
            now: { date },
            bootstrapRoot: try fixture("15.root.json"),
            fallbackTarget: try fixture("trusted-root.json")
        )

        await XCTAssertThrowsErrorAsync { _ = try await client.trustedRoot() }
    }

    func testOversizedMetadataFailureDoesNotUseFallback() async throws {
        let bootstrap = try fixture("15.root.json")
        let fallback = try fixture("trusted-root.json")
        let date = validDate
        let client = TUFClient(
            fetch: { _, _ in throw AppUpdaterError.resourceLimitExceeded("TUF metadata") },
            now: { date },
            bootstrapRoot: bootstrap,
            fallbackTarget: fallback
        )
        await XCTAssertThrowsErrorAsync { _ = try await client.trustedRoot() }
    }

    private func client(
        files: [String: Data],
        bootstrap: Data? = nil,
        cache: URL? = nil,
        now: Date? = nil
    ) -> TUFClient {
        let date = now ?? validDate
        return TUFClient(
            fetch: { url, maximumBytes in
                let name = url.lastPathComponent
                guard let data = files[name] else { throw URLError(.fileDoesNotExist) }
                guard data.count <= maximumBytes else {
                    throw AppUpdaterError.resourceLimitExceeded("TUF metadata")
                }
                return data
            },
            cacheDirectory: cache,
            now: { date },
            bootstrapRoot: bootstrap ?? (try? fixture("15.root.json")),
            fallbackTarget: try? fixture("trusted-root.json")
        )
    }

    private func fixtureFiles(timestamp: String = "timestamp.json") throws -> [String: Data] {
        [
            "14.root.json": try fixture("14.root.json"),
            "15.root.json": try fixture("15.root.json"),
            "timestamp.json": try fixture(timestamp),
            "165.snapshot.json": try fixture("165.snapshot.json"),
            "14.targets.json": try fixture("14.targets.json"),
            "6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66.trusted_root.json":
                try fixture("trusted-root.json"),
        ]
    }

    private func fixture(_ suffix: String) throws -> Data {
        let name = suffix == "trusted-root.json" ? "tuf-trusted-root" : "tuf-\(suffix)"
        let base = (name as NSString).deletingPathExtension
        return try Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: base, withExtension: "json")
        ))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
