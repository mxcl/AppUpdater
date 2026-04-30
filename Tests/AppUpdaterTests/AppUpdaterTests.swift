@testable import AppUpdater
import Version
import XCTest

final class AppUpdaterTests: XCTestCase {
    @MainActor
    func testCheckUpdatesSelectedAsset() async throws {
        let recorder = UpdateRecorder()
        let releases = try [
            release("2.0.0", prerelease: false, assetName: "AppUpdater-2.0.0.zip"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            updateAsset: { asset in await recorder.record(asset.name) }
        )

        try await updater.check()

        let names = await recorder.names()
        XCTAssertEqual(names, ["AppUpdater-2.0.0.zip"])
    }

    @MainActor
    func testCheckThrowsWhenBundleHasNoExecutable() async throws {
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            hasExecutable: { false },
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { [] },
            updateAsset: { _ in XCTFail("update should not run") }
        )

        do {
            try await updater.check()
            XCTFail("check should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .bundleExecutableURL)
        }
    }

    @MainActor
    func testCheckDoesNotUpdateWithoutMatchingAsset() async throws {
        let recorder = UpdateRecorder()
        let releases = try [
            release("2.0.0", prerelease: false, assetName: "OtherApp-2.0.0.zip"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            updateAsset: { asset in await recorder.record(asset.name) }
        )

        try await updater.check()

        let names = await recorder.names()
        XCTAssertEqual(names, [])
    }

    @MainActor
    func testCheckRespectsPrereleaseOptIn() async throws {
        let recorder = UpdateRecorder()
        let releases = try [
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.zip"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            updateAsset: { asset in await recorder.record(asset.name) }
        )
        updater.allowPrereleases = true

        try await updater.check()

        let names = await recorder.names()
        XCTAssertEqual(names, ["AppUpdater-2.0.0-beta.1.zip"])
    }

    func testReleaseDecodingAcceptsSupportedContentTypes() throws {
        let json = """
        {
          "tag_name": "2.0.0",
          "prerelease": false,
          "assets": [
            {
              "name": "AppUpdater-2.0.0.zip",
              "browser_download_url": "https://example.com/AppUpdater.zip",
              "content_type": "application/zip"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(Release.self, from: json)

        XCTAssertEqual(release.tagName, Version(2, 0, 0))
        XCTAssertEqual(release.assets.first?.contentType, .zip)
    }

    func testReleaseDecodingAcceptsVPrefixedTags() throws {
        let json = """
        {
          "tag_name": "v2.1.3",
          "prerelease": false,
          "assets": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.userInfo[.decodingMethod] = DecodingMethod.tolerant

        let release = try decoder.decode(Release.self, from: json)

        XCTAssertEqual(release.tagName, Version(2, 1, 3))
    }

    func testReleaseDecodingRejectsUnsupportedContentTypes() {
        let json = """
        {
          "tag_name": "2.0.0",
          "prerelease": false,
          "assets": [
            {
              "name": "AppUpdater-2.0.0.dmg",
              "browser_download_url": "https://example.com/AppUpdater.dmg",
              "content_type": "application/x-apple-diskimage"
            }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Release.self, from: json))
    }

    func testFindViableUpdateSelectsHighestStableRelease() throws {
        let releases = try [
            release("1.5.0", prerelease: false, assetName: "AppUpdater-1.5.0.zip"),
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.zip"),
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.zip"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertEqual(asset?.name, "AppUpdater-1.9.0.zip")
    }

    func testFindViableUpdateCanSelectPrerelease() throws {
        let releases = try [
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.zip"),
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.zip"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: true
        )

        XCTAssertEqual(asset?.name, "AppUpdater-2.0.0-beta.1.zip")
    }

    func testFindViableUpdateSkipsReleasesWithoutMatchingAssets() throws {
        let releases = try [
            release("2.0.0", prerelease: false, assetName: "OtherApp-2.0.0.zip"),
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.zip"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertEqual(asset?.name, "AppUpdater-1.9.0.zip")
    }

    func testFindViableUpdateThrowsWhenAlreadyCurrent() throws {
        let releases = try [
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.zip"),
        ]

        XCTAssertThrowsError(
            try releases.findViableUpdate(
                appVersion: Version(2, 0, 0),
                repo: "AppUpdater",
                prerelease: false
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .noUpdateAvailable)
        }
    }

    func testFindViableUpdateReturnsNilWhenNoReleasesExist() throws {
        let releases: [Release] = []

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertNil(asset)
    }

    func testArchiveValidationRejectsAbsolutePaths() {
        XCTAssertThrowsError(
            try ArchiveExtractor.validate(entries: ["/tmp/evil.app/Contents/MacOS/evil"])
        ) { error in
            XCTAssertEqual(
                error as? AppUpdaterError,
                .invalidArchiveEntry("/tmp/evil.app/Contents/MacOS/evil")
            )
        }
    }

    func testArchiveValidationRejectsParentTraversal() {
        XCTAssertThrowsError(
            try ArchiveExtractor.validate(entries: ["App.app/../evil"])
        ) { error in
            XCTAssertEqual(
                error as? AppUpdaterError,
                .invalidArchiveEntry("App.app/../evil")
            )
        }
    }

    func testArchiveValidationAllowsNormalBundleEntries() throws {
        XCTAssertNoThrow(
            try ArchiveExtractor.validate(
                entries: ["AppUpdater.app/Contents/MacOS/AppUpdater"]
            )
        )
    }

    func testArchiveValidationRejectsEmptyArchives() {
        XCTAssertThrowsError(try ArchiveExtractor.validate(entries: [])) { error in
            XCTAssertEqual(error as? AppUpdaterError, .invalidDownloadedBundle)
        }
    }

    func testArchiveExtractorExtractsZipWithSingleApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let app = source.appendingPathComponent("AppUpdater.app", isDirectory: true)
        let executableDirectory = app
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(
            to: executableDirectory.appendingPathComponent("AppUpdater")
        )

        let archive = root.appendingPathComponent("AppUpdater.zip")
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: [
                "-qry",
                archive.path,
                "AppUpdater.app",
            ],
            currentDirectory: source
        )

        let extractedApp = try await ArchiveExtractor.extract(
            archive,
            contentType: .zip,
            into: root
        )

        XCTAssertEqual(extractedApp.lastPathComponent, "AppUpdater.app")
    }

    func testProcessRunnerCapturesStdout() async throws {
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )

        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertEqual(output.stderr, "")
    }

    func testProcessRunnerThrowsForNonZeroExitStatus() async throws {
        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo nope >&2; exit 7"]
            )
            XCTFail("process should throw")
        } catch AppUpdaterError.processFailed(let executable, let status, let stderr) {
            XCTAssertEqual(executable.path, "/bin/sh")
            XCTAssertEqual(status, 7)
            XCTAssertEqual(stderr, "nope\n")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func release(
        _ version: String,
        prerelease: Bool,
        assetName: String
    ) throws -> Release {
        let json = """
        {
          "tag_name": "\(version)",
          "prerelease": \(prerelease),
          "assets": [
            {
              "name": "\(assetName)",
              "browser_download_url": "https://example.com/\(assetName)",
              "content_type": "application/zip"
            }
          ]
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(Release.self, from: json)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor UpdateRecorder {
    private var recordedNames: [String] = []

    func names() -> [String] {
        recordedNames
    }

    func record(_ name: String) {
        recordedNames.append(name)
    }
}
