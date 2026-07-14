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
                    "name": "AppUpdater-2.1.0.dmg",
                    "browser_download_url": "https://example.com/app.dmg",
                    "content_type": "application/x-apple-diskimage",
                    "size": 42
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
            XCTAssertEqual(error as? AppUpdaterError, .invalidHTTPResponse)
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

    func testNetworkTransferRejectsNonHTTPSFinalURL() async throws {
        let session = URLSession.stubbed(
            statusCode: 200,
            body: "[]",
            responseURL: URL(string: "http://example.com/releases")!
        )
        let request = URLRequest(
            url: URL(string: "https://example.com/releases")!
        )

        do {
            _ = try await NetworkTransfer.data(
                for: request,
                with: session,
                maximumBytes: 100
            )
            XCTFail("transfer should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidHTTPResponse)
        }
    }

    func testNetworkTransferRejectsOversizedResponse() async throws {
        let session = URLSession.stubbed(statusCode: 200, body: "12345")
        let request = URLRequest(
            url: URL(string: "https://example.com/releases")!
        )

        do {
            _ = try await NetworkTransfer.data(
                for: request,
                with: session,
                maximumBytes: 4
            )
            XCTFail("transfer should throw")
        } catch {
            XCTAssertEqual(
                error as? AppUpdaterError,
                .resourceLimitExceeded("response size")
            )
        }
    }

    func testNetworkTransferRejectsHTTPSDowngradeRedirect() async throws {
        let delegate = NetworkTransfer.TransferDelegate(maximumBytes: 100)
        let session = URLSession.shared
        let task = session.dataTask(
            with: URL(string: "https://example.com/update.dmg")!
        )
        let response = HTTPURLResponse(
            url: task.originalRequest!.url!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let request = URLRequest(
            url: URL(string: "http://example.com/update.dmg")!
        )
        let redirectedRequest = RequestRecorder()

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        ) { redirectedRequest.set($0) }

        XCTAssertNil(redirectedRequest.value())
        XCTAssertEqual(delegate.error, .insecureDownloadURL)
    }

    func testNetworkDownloadRejectsActualBytesBeyondDeclaredSize() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("update.dmg")
        let session = URLSession.stubbed(statusCode: 200, body: "12345")

        do {
            try await NetworkTransfer.download(
                URL(string: "https://example.com/update.dmg")!,
                with: session,
                to: destination,
                maximumBytes: 4,
                timeout: 10
            )
            XCTFail("download should throw")
        } catch {
            XCTAssertEqual(
                error as? AppUpdaterError,
                .resourceLimitExceeded("download size")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testCheckUpdatesSelectedAsset() async throws {
        let releases = try [
            release("2.0.0", prerelease: false, assetName: "AppUpdater-2.0.0.dmg"),
        ]
        let updater = AppUpdater(
            owner: "mxcl",
            repo: "AppUpdater",
            currentVersion: { Version(1, 0, 0) },
            fetchReleases: { releases },
            stageAsset: { asset in stagedUpdate(assetName: asset.name) }
        )

        let update = try await updater.check()

        XCTAssertEqual(update?.assetName, "AppUpdater-2.0.0.dmg")
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
            release("2.0.0", prerelease: false, assetName: "OtherApp-2.0.0.dmg"),
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
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.dmg"),
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

        XCTAssertEqual(update?.assetName, "AppUpdater-2.0.0-beta.1.dmg")
    }

    @MainActor
    func testCheckReusesActiveTask() async throws {
        let gate = AsyncGate()
        let release = try release(
            "2.0.0",
            prerelease: false,
            assetName: "AppUpdater-2.0.0.dmg"
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
            "AppUpdater-2.0.0.dmg",
            "AppUpdater-2.0.0.dmg",
        ])
        let waiterCount = await gate.waitCallCount()
        XCTAssertEqual(waiterCount, 1)
    }

    func testReleaseDecodingIgnoresZipAndTarAssets() throws {
        let json = """
        {
          "tag_name": "2.0.0",
          "prerelease": false,
          "assets": [
            {
              "name": "AppUpdater-2.0.0.zip",
              "browser_download_url": "https://example.com/AppUpdater.zip",
              "content_type": "application/zip"
            },
            {
              "name": "AppUpdater-2.0.0.tar.gz",
              "browser_download_url": "https://example.com/AppUpdater.tar.gz",
              "content_type": "application/gzip"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(Release.self, from: json)

        XCTAssertEqual(release.tagName, Version(2, 0, 0))
        XCTAssertTrue(release.assets.allSatisfy { $0.contentType == nil })
        XCTAssertNil(release.viableAsset(forRepo: "AppUpdater"))
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

    func testReleaseDecodingIgnoresNonDiskImageAssets() throws {
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

        let release = try JSONDecoder().decode(Release.self, from: json)
        XCTAssertNil(release.assets.first?.contentType)
    }

    func testFindViableUpdateSelectsHighestStableRelease() throws {
        let releases = try [
            release("1.5.0", prerelease: false, assetName: "AppUpdater-1.5.0.dmg"),
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.dmg"),
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.dmg"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertEqual(asset?.name, "AppUpdater-1.9.0.dmg")
    }

    func testFindViableUpdateCanSelectPrerelease() throws {
        let releases = try [
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.dmg"),
            release("2.0.0-beta.1", prerelease: true, assetName: "AppUpdater-2.0.0-beta.1.dmg"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: true
        )

        XCTAssertEqual(asset?.name, "AppUpdater-2.0.0-beta.1.dmg")
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
            release("2.0.0", prerelease: false, assetName: "OtherApp-2.0.0.dmg"),
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.dmg"),
        ]

        let asset = try releases.findViableUpdate(
            appVersion: Version(1, 0, 0),
            repo: "AppUpdater",
            prerelease: false
        )

        XCTAssertEqual(asset?.name, "AppUpdater-1.9.0.dmg")
    }

    func testFindViableUpdateReturnsNilWhenAlreadyCurrent() throws {
        let releases = try [
            release("1.9.0", prerelease: false, assetName: "AppUpdater-1.9.0.dmg"),
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
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testMountedContentInspectionEnforcesEntryLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("one"))
        try Data().write(to: root.appendingPathComponent("two"))

        XCTAssertThrowsError(
            try ArchiveExtractor.inspect(
                root,
                limits: .init(
                    .init(maximumMountedBytes: 100, maximumEntries: 1)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AppUpdaterError,
                .resourceLimitExceeded("mounted entry count")
            )
        }
    }

    func testMountedContentInspectionEnforcesSizeLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 5).write(
            to: root.appendingPathComponent("large")
        )

        XCTAssertThrowsError(
            try ArchiveExtractor.inspect(
                root,
                limits: .init(
                    .init(maximumMountedBytes: 4, maximumEntries: 10)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AppUpdaterError,
                .resourceLimitExceeded("mounted content size")
            )
        }
    }

    func testMountedContentInspectionEnforcesTimeout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("entry"))

        XCTAssertThrowsError(
            try ArchiveExtractor.inspect(
                root,
                limits: .init(.init(timeout: .leastNonzeroMagnitude))
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .operationTimedOut)
        }
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

    func testArchiveExtractorRejectsMisnamedApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeApp(named: "Other.app", in: source)
        let diskImage = try await makeDiskImage(from: source, in: root)

        do {
            _ = try await ArchiveExtractor.mount(
                diskImage,
                at: root.appendingPathComponent("mount", isDirectory: true),
                expectedAppName: "AppUpdater.app",
                limits: .init(.init())
            )
            XCTFail("mount should throw")
        } catch AppUpdaterError.processFailed(let executable, _, let stderr)
            where executable.lastPathComponent == "hdiutil"
        {
            throw XCTSkip("hdiutil could not attach disk image: \(stderr)")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .invalidDownloadedBundle)
        }
    }

    func testArchiveExtractorRejectsMalformedDiskImage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diskImage = root.appendingPathComponent("malformed.dmg")
        try Data("not a disk image".utf8).write(to: diskImage)

        do {
            _ = try await ArchiveExtractor.mount(
                diskImage,
                at: root.appendingPathComponent("mount", isDirectory: true),
                expectedAppName: "AppUpdater.app",
                limits: .init(.init())
            )
            XCTFail("mount should throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("mount/AppUpdater.app").path
            ))
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

    func testProcessRunnerTimesOut() async throws {
        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["1"],
                timeout: 0.01
            )
            XCTFail("process should time out")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .operationTimedOut)
        }
    }

    func testCodeSignatureRejectsBroadAdHocRequirement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try makeBundle(named: "Current", version: "1.0", in: root)
        let candidate = try makeBundle(named: "Candidate", version: "2.0", in: root)
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-f", "-s", "-", "-r=designated => true", current.bundlePath]
        )
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-f", "-s", "-", candidate.bundlePath]
        )

        XCTAssertThrowsError(
            try CodeSignature.requireSameDeveloperID(
                current: current,
                candidate: candidate
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .invalidDeveloperID)
        }
    }

    func testCodeSignatureRequiresMatchingIdentityFields() throws {
        let identity = CodeSignature.Identity(
            teamIdentifier: "TEAM",
            signingIdentifier: "dev.mxcl.App",
            bundleIdentifier: "dev.mxcl.App"
        )

        XCTAssertThrowsError(
            try CodeSignature.requireMatch(
                current: identity,
                candidate: .init(
                    teamIdentifier: "OTHER",
                    signingIdentifier: identity.signingIdentifier,
                    bundleIdentifier: identity.bundleIdentifier
                )
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .mismatchedCodeSigningInfo)
        }
        XCTAssertThrowsError(
            try CodeSignature.requireMatch(
                current: identity,
                candidate: .init(
                    teamIdentifier: identity.teamIdentifier,
                    signingIdentifier: "dev.mxcl.Other",
                    bundleIdentifier: identity.bundleIdentifier
                )
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .mismatchedCodeSigningInfo)
        }
        XCTAssertThrowsError(
            try CodeSignature.requireMatch(
                current: identity,
                candidate: .init(
                    teamIdentifier: identity.teamIdentifier,
                    signingIdentifier: identity.signingIdentifier,
                    bundleIdentifier: "dev.mxcl.Other"
                )
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .mismatchedBundleIdentifier)
        }
    }

    func testCodeSignatureRejectsModifiedNestedCode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(named: "Current", version: "1.0", in: root)
        let nested = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS/Nested")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nested)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nested.path
        )
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-f", "-s", "-", "--deep", bundle.bundlePath]
        )
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: nested)

        XCTAssertThrowsError(try CodeSignature.validateStructure(of: bundle))
    }

    func testCodeSignatureRejectsUnsafeSymlink() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(named: "Current", version: "1.0", in: root)
        let resources = bundle.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: resources.appendingPathComponent("outside"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-f", "-s", "-", bundle.bundlePath]
        )

        XCTAssertThrowsError(try CodeSignature.validateStructure(of: bundle))
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

    @MainActor
    func testUpdateAndPreparedUpdateAreOneShot() async throws {
        var installs = 0
        let update = Update(
            assetName: "AppUpdater-2.0.0.dmg",
            prepare: {
                PreparedUpdate(
                    assetName: "AppUpdater-2.0.0.dmg",
                    install: { installs += 1 },
                    discard: {}
                )
            },
            discard: {}
        )

        let prepared = try await update.prepareInstallation()
        try await prepared.installAndRelaunch()
        XCTAssertEqual(installs, 1)
        await XCTAssertThrowsErrorAsync(try await update.prepareInstallation())
        await XCTAssertThrowsErrorAsync(try await prepared.installAndRelaunch())
    }

    @MainActor
    func testReplacementTransactionLaunchesBeforeCleanupAndTermination() async throws {
        var events: [String] = []
        let prepared = preparedInstallation(
            driver: transactionDriver(events: { events.append($0) }),
            cleanup: { events.append("cleanup") }
        )

        try await prepared.installAndRelaunch()

        XCTAssertEqual(events, [
            "validate", "validate", "replace", "validate", "launch",
            "cleanup", "remove", "remove", "terminate",
        ])
    }

    @MainActor
    func testRelaunchWaitsForSpawnedProcess() async throws {
        var samples = [false, false, true]
        var launches = 0
        try await ApplicationLauncher.launchNewInstance(
            attempts: 3,
            spawn: {
                launches += 1
                return 42
            },
            isReady: { processIdentifier in
                XCTAssertEqual(processIdentifier, 42)
                return samples.removeFirst()
            },
            pause: {}
        )
        XCTAssertEqual(launches, 1)
    }

    @MainActor
    func testRelaunchRejectsUnreadySpawnedProcess() async {
        do {
            try await ApplicationLauncher.launchNewInstance(
                attempts: 2,
                spawn: { 42 },
                isReady: { _ in false },
                pause: {}
            )
            XCTFail("launch should fail until the spawned process is ready")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .relaunchFailed)
        }
    }

    @MainActor
    func testInstalledValidationFailureRollsBack() async throws {
        var validations = 0
        var events: [String] = []
        var driver = transactionDriver(events: { events.append($0) })
        driver.validate = { _, _ in
            validations += 1
            events.append("validate")
            if validations == 3 { throw AppUpdaterError.invalidDeveloperID }
        }
        let prepared = preparedInstallation(driver: driver)

        await XCTAssertThrowsErrorAsync(try await prepared.installAndRelaunch())

        XCTAssertEqual(events, [
            "validate", "validate", "replace", "validate", "restore", "remove",
        ])
    }

    @MainActor
    func testLaunchFailureRollsBackWithoutTerminating() async throws {
        var events: [String] = []
        var driver = transactionDriver(events: { events.append($0) })
        driver.launch = { _ in
            events.append("launch")
            throw AppUpdaterError.invalidUpdateState
        }
        let prepared = preparedInstallation(driver: driver)

        await XCTAssertThrowsErrorAsync(try await prepared.installAndRelaunch())

        XCTAssertEqual(events, [
            "validate", "validate", "replace", "validate", "launch", "restore",
            "remove",
        ])
    }

    @MainActor
    func testPreReplacementValidationFailureCleansPreparedState() async throws {
        var events: [String] = []
        var driver = transactionDriver(events: { events.append($0) })
        driver.validate = { _, _ in
            events.append("validate")
            throw AppUpdaterError.invalidDeveloperID
        }
        let prepared = preparedInstallation(
            driver: driver,
            cleanup: { events.append("cleanup") }
        )

        await XCTAssertThrowsErrorAsync(try await prepared.installAndRelaunch())

        XCTAssertEqual(events, ["validate", "cleanup", "remove"])
    }

    @MainActor
    func testRollbackFailureIsReportedExplicitly() async throws {
        var validations = 0
        var driver = transactionDriver(events: { _ in })
        driver.validate = { _, _ in
            validations += 1
            if validations == 3 { throw AppUpdaterError.invalidDeveloperID }
        }
        driver.restore = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        let prepared = preparedInstallation(driver: driver)

        do {
            try await prepared.installAndRelaunch()
            XCTFail("installation should throw")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .rollbackFailed)
        }
    }

    @MainActor
    func testWritableReplacementRestoresBackupWhenCopyFails() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("App.app", isDirectory: true)
        let missingCandidate = root.appendingPathComponent("Missing.app", isDirectory: true)
        let backup = root.appendingPathComponent(".app-updater-backup-00000000-0000-0000-0000-000000000000.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))

        await XCTAssertThrowsErrorAsync(
            try await InstallationDriver.live.replace(
                missingCandidate, installed, backup, false
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8),
            "old"
        )
    }

    @MainActor
    func testPromotionCopyIsIndependentOfOriginalDMG() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.dmg")
        let destination = root.appendingPathComponent("promoted.dmg")
        try Data("validated".utf8).write(to: source)

        try await InstallationDriver.live.promote(source, destination, false)
        try Data("attacker".utf8).write(to: source)

        XCTAssertEqual(try Data(contentsOf: destination), Data("validated".utf8))
    }

    func testProtectedPromotionRejectsUserOwnedFileEvenWhenReadOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent(".app-updater-00000000-0000-0000-0000-000000000000.dmg")
        try Data().write(to: image)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: image.path
        )

        XCTAssertThrowsError(
            try Installation.validatePromotion(
                image,
                expectedParent: root,
                protected: true
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .unsafeInstallationState)
        }
    }

    func testStaleCleanupRecognizesOnlyOwnedRegularNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent(
            ".app-updater-00000000-0000-0000-0000-000000000000.dmg"
        )
        let lookalike = root.appendingPathComponent(".app-updater-important.dmg")
        try Data().write(to: owned)
        try Data().write(to: lookalike)

        XCTAssertTrue(Installation.ownsStaleItem(owned))
        XCTAssertFalse(Installation.ownsStaleItem(lookalike))

        let symlink = root.appendingPathComponent(
            ".app-updater-11111111-1111-1111-1111-111111111111.dmg"
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: owned)
        XCTAssertFalse(Installation.ownsStaleItem(symlink))
    }

    @MainActor
    func testStaleCleanupTouchesOnlyOwnedNames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("App.app", isDirectory: true)
        let owned = root.appendingPathComponent(
            ".app-updater-00000000-0000-0000-0000-000000000000.dmg"
        )
        let lookalike = root.appendingPathComponent(".app-updater-important.dmg")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data().write(to: owned)
        try Data().write(to: lookalike)
        var removed: [URL] = []
        var driver = transactionDriver(events: { _ in })
        driver.remove = { url, _ in removed.append(url) }

        try await Installation.cleanupStaleItems(
            in: root,
            excluding: installed,
            protected: false,
            driver: driver
        )

        XCTAssertEqual(removed.map(\.lastPathComponent), [owned.lastPathComponent])
    }

    @MainActor
    private func preparedInstallation(
        driver: InstallationDriver,
        cleanup: @escaping () async -> Void = {}
    ) -> PreparedUpdate {
        let identity = CodeSignature.Identity(
            teamIdentifier: "TEAM",
            signingIdentifier: "dev.mxcl.App",
            bundleIdentifier: "dev.mxcl.App"
        )
        return PreparedInstallation(
            assetName: "App-2.0.0.dmg",
            installedURL: URL(fileURLWithPath: "/Applications/App.app"),
            candidateURL: URL(fileURLWithPath: "/Volumes/Update/App.app"),
            promotedImageURL: URL(fileURLWithPath: "/Applications/.app-updater-00000000-0000-0000-0000-000000000000.dmg"),
            expectedIdentity: identity,
            protected: true,
            driver: driver,
            cleanup: cleanup
        ).publicUpdate()
    }

    @MainActor
    private func transactionDriver(
        events: @escaping (String) -> Void
    ) -> InstallationDriver {
        InstallationDriver(
            promote: { _, _, _ in events("promote") },
            replace: { _, _, _, _ in events("replace") },
            restore: { _, _, _ in events("restore") },
            remove: { _, _ in events("remove") },
            validate: { _, _ in events("validate") },
            launch: { _ in events("launch") },
            terminate: { events("terminate") }
        )
    }

    private func release(
        _ version: String,
        prerelease: Bool,
        assetName: String,
        contentType: String = "application/x-apple-diskimage"
    ) throws -> Release {
        let json = """
        {
          "tag_name": "\(version)",
          "prerelease": \(prerelease),
          "assets": [
            {
              "name": "\(assetName)",
              "browser_download_url": "https://example.com/\(assetName)",
              "content_type": "\(contentType)",
              "size": 42
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
        let executable = executableDirectory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    private func makeBundle(named name: String, version: String, in directory: URL) throws -> Bundle {
        let app = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let info: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "dev.mxcl.\(name.lowercased())",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: app))
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

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest?) {
        lock.withLock { self.request = request }
    }

    func value() -> URLRequest? {
        lock.withLock { request }
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var body = Data()
    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private nonisolated(unsafe) static var responseURL: URL?

    static var requests: [URLRequest] {
        recordedRequests
    }

    static func configure(statusCode: Int, body: String, responseURL: URL?) {
        self.body = Data(body.utf8)
        recordedRequests = []
        self.statusCode = statusCode
        self.responseURL = responseURL
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
            url: Self.responseURL ?? request.url!,
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
    static func stubbed(
        statusCode: Int,
        body: String,
        responseURL: URL? = nil
    ) -> URLSession {
        URLProtocolStub.configure(
            statusCode: statusCode,
            body: body,
            responseURL: responseURL
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private func stagedUpdate(assetName: String = "AppUpdater-2.0.0.dmg") -> Update {
    Update(
        assetName: assetName,
        prepare: {
            PreparedUpdate(assetName: assetName, install: {}, discard: {})
        },
        discard: {}
    )
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure @MainActor () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
