@testable import AppUpdater
import XCTest

final class AppUpdaterTests: XCTestCase {
    func testSemanticVersionOrdersPrereleasesBeforeFinalRelease() throws {
        let alpha = try SemanticVersion("2.0.0-alpha.1")
        let beta = try SemanticVersion("2.0.0-beta.1")
        let release = try SemanticVersion("2.0.0")

        XCTAssertLessThan(alpha, beta)
        XCTAssertLessThan(beta, release)
    }

    func testSemanticVersionAcceptsVPrefixedTags() throws {
        XCTAssertEqual(try SemanticVersion("v2.1.3").description, "2.1.3")
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

        XCTAssertEqual(release.tagName, try SemanticVersion("2.0.0"))
        XCTAssertEqual(release.assets.first?.contentType, .zip)
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
            appVersion: SemanticVersion("1.0.0"),
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
            appVersion: SemanticVersion("1.0.0"),
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
            appVersion: SemanticVersion("1.0.0"),
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
                appVersion: SemanticVersion("2.0.0"),
                repo: "AppUpdater",
                prerelease: false
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdaterError, .noUpdateAvailable)
        }
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
}
