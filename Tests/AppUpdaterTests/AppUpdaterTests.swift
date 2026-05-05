@testable import AppUpdater
import Version
import XCTest

final class AppUpdaterTests: XCTestCase {
    @MainActor
    func testPublicInitializerCreatesUpdater() {
        let updater = AppUpdater(owner: "mxcl", repo: "AppUpdater")

        XCTAssertFalse(updater.allowPrereleases)
    }

    func testFetchReleasesUsesGitHubAPIAndTolerantVersionDecoding() async throws {
        let session = URLSession.stubbed(
            statusCode: 200,
            body: """
            [
              {
                "tag_name": "v2.1",
                "prerelease": false,
                "assets": [
                  {
                    "name": "AppUpdater-2.1.0.zip",
                    "browser_download_url": "https://example.com/app.zip",
                    "content_type": "application/zip"
                  }
                ]
              }
            ]
            """
        )

        let releases = try await AppUpdater.fetchReleases(
            owner: "mxcl",
            repo: "AppUpdater",
            session: session
        )
        let request = try XCTUnwrap(URLProtocolStub.requests.first)

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.github.com/repos/mxcl/AppUpdater/releases"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/vnd.github+json"
        )
        XCTAssertEqual(releases.first?.tagName, Version(2, 1, 0))
    }

    func testFetchReleasesThrowsForNonSuccessStatus() async throws {
        let session = URLSession.stubbed(statusCode: 500, body: "[]")

        do {
            _ = try await AppUpdater.fetchReleases(
                owner: "mxcl",
                repo: "AppUpdater",
                session: session
            )
            XCTFail("fetch should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidGitHubResponse)
        }
    }

    func testFetchReleasesThrowsForMalformedJSON() async throws {
        let session = URLSession.stubbed(statusCode: 200, body: "{")

        do {
            _ = try await AppUpdater.fetchReleases(
                owner: "mxcl",
                repo: "AppUpdater",
                session: session
            )
            XCTFail("fetch should throw")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    @MainActor
    func testCheckUpdatesSelectedAsset() async throws {
        let releases = try [
            release("2.0.0", prerelease: false, assetName: "AppUpdater-2.0.0.zip"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            stageAsset: { asset in stagedUpdate(assetName: asset.name) }
        )

        let update = try await updater.check()

        XCTAssertEqual(update?.assetName, "AppUpdater-2.0.0.zip")
    }

    @MainActor
    func testCheckThrowsWhenBundleHasNoExecutable() async throws {
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            hasExecutable: { false },
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { [] },
            stageAsset: { _ in
                XCTFail("update should not run")
                return stagedUpdate()
            }
        )

        do {
            _ = try await updater.check()
            XCTFail("check should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .bundleExecutableURL)
        }
    }

    @MainActor
    func testCheckDoesNotUpdateWithoutMatchingAsset() async throws {
        let releases = try [
            release("2.0.0", prerelease: false, assetName: "OtherApp-2.0.0.zip"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            stageAsset: { _ in
                XCTFail("update should not run")
                return stagedUpdate()
            }
        )

        let update = try await updater.check()

        XCTAssertNil(update)
    }

    @MainActor
    func testCheckRespectsPrereleaseOptIn() async throws {
        let releases = try [
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.zip"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            stageAsset: { asset in stagedUpdate(assetName: asset.name) }
        )
        updater.allowPrereleases = true

        let update = try await updater.check()

        XCTAssertEqual(update?.assetName, "AppUpdater-2.0.0-beta.1.zip")
    }

    @MainActor
    func testCheckReusesActiveTask() async throws {
        let gate = AsyncGate()
        let release = try release(
            "2.0.0",
            prerelease: false,
            assetName: "AppUpdater-2.0.0.zip"
        )
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: {
                await gate.wait()
                return [release]
            },
            stageAsset: { asset in stagedUpdate(assetName: asset.name) }
        )

        async let first = updater.check()
        async let second = updater.check()
        await gate.waitForWaiters()
        await gate.open()

        let updates = try await [first, second]
        XCTAssertEqual(updates.map(\.?.assetName), [
            "AppUpdater-2.0.0.zip",
            "AppUpdater-2.0.0.zip",
        ])
        let waiterCount = await gate.waitCallCount()
        XCTAssertEqual(waiterCount, 1)
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

    func testReleaseDecodingAcceptsDiskImageContentType() throws {
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

        let release = try JSONDecoder().decode(Release.self, from: json)

        XCTAssertEqual(release.assets.first?.contentType, .dmg)
        XCTAssertEqual(
            release.viableAsset(forRepo: "AppUpdater")?.name,
            "AppUpdater-2.0.0.dmg"
        )
    }

    func testReleaseDecodingAcceptsGenericDiskImageContentType() throws {
        let json = """
        {
          "tag_name": "2.0.0",
          "prerelease": false,
          "assets": [
            {
              "name": "AppUpdater-2.0.0.dmg",
              "browser_download_url": "https://example.com/AppUpdater.dmg",
              "content_type": "application/octet-stream"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(Release.self, from: json)

        XCTAssertEqual(release.assets.first?.contentType, .dmg)
    }

    func testReleaseDecodingRejectsUnsupportedContentTypes() {
        let json = """
        {
          "tag_name": "2.0.0",
          "prerelease": false,
          "assets": [
            {
              "name": "AppUpdater-2.0.0.pkg",
              "browser_download_url": "https://example.com/AppUpdater.pkg",
              "content_type": "application/octet-stream"
            }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Release.self, from: json))
    }

    func testReleaseDecodingAcceptsTarContentTypes() throws {
        let json = """
        {
          "tag_name": "2.0.0",
          "prerelease": false,
          "assets": [
            {
              "name": "AppUpdater-2.0.0.tar.gz",
              "browser_download_url": "https://example.com/AppUpdater.tar.gz",
              "content_type": "application/x-gzip"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(Release.self, from: json)

        XCTAssertEqual(release.assets.first?.contentType, .tar)
        XCTAssertEqual(
            release.viableAsset(forRepo: "AppUpdater")?.name,
            "AppUpdater-2.0.0.tar.gz"
        )
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

    func testFindViableUpdateCanSelectDiskImage() throws {
        let releases = try [
            release(
                "2.0.0",
                prerelease: false,
                assetName: "AppUpdater-2.0.0.dmg",
                contentType: "application/x-apple-diskimage"
            ),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertEqual(asset?.name, "AppUpdater-2.0.0.dmg")
        XCTAssertEqual(asset?.contentType, .dmg)
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

    func testFindViableUpdateReturnsNilWhenAlreadyCurrent() throws {
        let releases = try [
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.zip"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(2, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertNil(asset)
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

    @MainActor
    func testStagingDirectoryAvoidsItemReplacementDirectory() throws {
        let directory = try AppUpdater.stagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(directory.path.contains("/TemporaryItems/NSIRD_"))
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
        try makeApp(named: "AppUpdater.app", in: source)

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

    func testArchiveExtractorExtractsTarWithSingleApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeApp(named: "AppUpdater.app", in: source)

        let archive = root.appendingPathComponent("AppUpdater.tar.gz")
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-czf",
                archive.path,
                "-C",
                source.path,
                "AppUpdater.app",
            ]
        )

        let extractedApp = try await ArchiveExtractor.extract(
            archive,
            contentType: .tar,
            into: root
        )

        XCTAssertEqual(extractedApp.lastPathComponent, "AppUpdater.app")
    }

    func testArchiveExtractorExtractsDiskImageWithSingleApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeApp(named: "AppUpdater.app", in: source)
        let diskImage = try await makeDiskImage(from: source, in: root)

        do {
            let extractedApp = try await ArchiveExtractor.extract(
                diskImage,
                contentType: .dmg,
                into: root
            )

            XCTAssertEqual(extractedApp.lastPathComponent, "AppUpdater.app")
        } catch AppUpdaterError.processFailed(let executable, _, let stderr)
            where executable.lastPathComponent == "hdiutil"
        {
            throw XCTSkip("hdiutil could not attach disk image: \(stderr)")
        }
    }

    func testArchiveExtractorRejectsDiskImageWithoutApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: source.appendingPathComponent("README"))
        let diskImage = try await makeDiskImage(from: source, in: root)

        do {
            _ = try await ArchiveExtractor.extract(
                diskImage,
                contentType: .dmg,
                into: root
            )
            XCTFail("extract should throw")
        } catch AppUpdaterError.processFailed(let executable, _, let stderr)
            where executable.lastPathComponent == "hdiutil"
        {
            throw XCTSkip("hdiutil could not attach disk image: \(stderr)")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidDownloadedBundle)
        }
    }

    func testArchiveExtractorRejectsDiskImageWithMultipleApps() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeApp(named: "One.app", in: source)
        try makeApp(named: "Two.app", in: source)
        let diskImage = try await makeDiskImage(from: source, in: root)

        do {
            _ = try await ArchiveExtractor.extract(
                diskImage,
                contentType: .dmg,
                into: root
            )
            XCTFail("extract should throw")
        } catch AppUpdaterError.processFailed(let executable, _, let stderr)
            where executable.lastPathComponent == "hdiutil"
        {
            throw XCTSkip("hdiutil could not attach disk image: \(stderr)")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidDownloadedBundle)
        }
    }

    func testArchiveExtractorRejectsArchiveWithoutApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: source.appendingPathComponent("README"))

        let archive = root.appendingPathComponent("NoApp.zip")
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-qry", archive.path, "README"],
            currentDirectory: source
        )

        do {
            _ = try await ArchiveExtractor.extract(
                archive,
                contentType: .zip,
                into: root
            )
            XCTFail("extract should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidDownloadedBundle)
        }
    }

    func testArchiveExtractorRejectsArchiveWithMultipleApps() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeApp(named: "One.app", in: source)
        try makeApp(named: "Two.app", in: source)

        let archive = root.appendingPathComponent("MultipleApps.zip")
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-qry", archive.path, "One.app", "Two.app"],
            currentDirectory: source
        )

        do {
            _ = try await ArchiveExtractor.extract(
                archive,
                contentType: .zip,
                into: root
            )
            XCTFail("extract should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidDownloadedBundle)
        }
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

    func testProcessRunnerThrowsWhenExecutableCannotLaunch() async throws {
        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/tmp/not-a-real-executable"),
                arguments: []
            )
            XCTFail("process should throw")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testErrorDescriptions() {
        let errors: [AppUpdaterError] = [
            .bundleExecutableURL,
            .invalidAppVersion("wat"),
            .invalidArchiveEntry("../App.app"),
            .invalidDownloadedBundle,
            .invalidGitHubResponse,
            .insecureDownloadURL,
            .missingCodeSigningInfo,
            .mismatchedCodeSigningInfo,
            .processFailed(URL(fileURLWithPath: "/bin/false"), 1, "nope"),
            .unsupportedContentType("application/octet-stream"),
        ]

        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testAppVersionParsing() throws {
        XCTAssertEqual(try Version.appVersion(from: "v2.1"), Version(2, 1, 0))

        XCTAssertThrowsError(try Version.appVersion(from: nil)) { error in
            XCTAssertEqual(error as? AppUpdaterError, .invalidAppVersion(""))
        }
        XCTAssertThrowsError(try Version.appVersion(from: "nope")) { error in
            XCTAssertEqual(error as? AppUpdaterError, .invalidAppVersion("nope"))
        }
    }

    func testInstallerHelperWritesExecutableArgumentDrivenScript() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = try InstallerHelper.writeScript(in: root)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: scriptURL.path
        )[.posixPermissions] as? Int

        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("staged_bundle=\"$2\""))
        XCTAssertTrue(script.contains("installed_bundle=\"$3\""))
        XCTAssertTrue(script.contains("executable=\"$4\""))
        XCTAssertTrue(script.contains("deadline=$(( $(date +%s) + 300 ))"))
        XCTAssertEqual(permissions, 0o700)
    }

    @MainActor
    func testInstallAndRelaunchWritesHelperAndLaunchesIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = LauncherRecorder()
        let terminator = TerminatorRecorder()
        let update = Update(
            assetName: "AppUpdater-2.0.0.zip",
            stagedBundleURL: root.appendingPathComponent("Staged.app"),
            installedBundleURL: URL(fileURLWithPath: "/Applications/AppUpdater.app"),
            executableURL: URL(fileURLWithPath: "/Applications/AppUpdater.app/Contents/MacOS/AppUpdater"),
            stagingDirectoryURL: root,
            relauncher: { scriptURL, arguments in
                launcher.record(scriptURL: scriptURL, arguments: arguments)
            },
            terminator: {
                terminator.record()
            }
        )

        try await update.installAndRelaunch()

        let launch = launcher.launch()
        XCTAssertEqual(launch?.scriptURL.lastPathComponent, "install-update.sh")
        XCTAssertEqual(launch?.arguments.dropFirst(), [
            update.stagedBundleURL.path,
            update.installedBundleURL.path,
            update.executableURL.path,
            root.path,
        ])
        XCTAssertTrue(terminator.wasCalled())
    }

    private func release(
        _ version: String,
        prerelease: Bool,
        assetName: String,
        contentType: String = "application/zip"
    ) throws -> Release {
        let json = """
        {
          "tag_name": "\(version)",
          "prerelease": \(prerelease),
          "assets": [
            {
              "name": "\(assetName)",
              "browser_download_url": "https://example.com/\(assetName)",
              "content_type": "\(contentType)"
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

    private func makeDiskImage(from source: URL, in root: URL) async throws -> URL {
        let diskImage = root.appendingPathComponent("AppUpdater.dmg")
        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: [
                    "create",
                    "-quiet",
                    "-fs",
                    "HFS+",
                    "-srcfolder",
                    source.path,
                    diskImage.path,
                ]
            )
        } catch AppUpdaterError.processFailed(let executable, _, let stderr)
            where executable.lastPathComponent == "hdiutil"
        {
            throw XCTSkip("hdiutil could not create disk image: \(stderr)")
        }
        return diskImage
    }

    private func makeApp(named name: String, in directory: URL) throws {
        let app = directory.appendingPathComponent(name, isDirectory: true)
        let executableDirectory = app
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: executableDirectory.appendingPathComponent(name))
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waiterContinuations: [CheckedContinuation<Void, Never>] = []
    private var waits = 0

    func waitCallCount() -> Int {
        waits
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            waits += 1
            continuations.append(continuation)
            waiterContinuations.forEach { $0.resume() }
            waiterContinuations.removeAll()
        }
    }

    func waitForWaiters() async {
        guard continuations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            waiterContinuations.append(continuation)
        }
    }

    func open() {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class LauncherRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLaunch: (scriptURL: URL, arguments: [String])?

    func launch() -> (scriptURL: URL, arguments: [String])? {
        lock.withLock { recordedLaunch }
    }

    func record(scriptURL: URL, arguments: [String]) {
        lock.withLock {
            recordedLaunch = (scriptURL, arguments)
        }
    }
}

private final class TerminatorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func wasCalled() -> Bool {
        lock.withLock { called }
    }

    func record() {
        lock.withLock {
            called = true
        }
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var body = Data()
    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        recordedRequests
    }

    static func configure(statusCode: Int, body: String) {
        self.body = Data(body.utf8)
        recordedRequests = []
        self.statusCode = statusCode
    }

    private nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recordedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLSession {
    static func stubbed(statusCode: Int, body: String) -> URLSession {
        URLProtocolStub.configure(statusCode: statusCode, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private func stagedUpdate(assetName: String = "AppUpdater-2.0.0.zip") -> Update {
    Update(
        assetName: assetName,
        stagedBundleURL: URL(fileURLWithPath: "/tmp/staged/AppUpdater.app"),
        installedBundleURL: URL(fileURLWithPath: "/Applications/AppUpdater.app"),
        executableURL: URL(fileURLWithPath: "/Applications/AppUpdater.app/Contents/MacOS/AppUpdater"),
        stagingDirectoryURL: URL(fileURLWithPath: "/tmp/staged")
    )
}
