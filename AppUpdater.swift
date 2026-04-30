import AppKit
import Foundation

@MainActor
public final class AppUpdater {
    private var active: Task<Void, Swift.Error>?
#if !DEBUG
    private let activity: NSBackgroundActivityScheduler
#endif
    private let owner: String
    private let repo: String
    private let session: URLSession

    public var allowPrereleases = false

    public init(
        owner: String,
        repo: String,
        session: URLSession = .shared
    ) {
        self.owner = owner
        self.repo = repo
        self.session = session
#if !DEBUG
        activity = NSBackgroundActivityScheduler(identifier: "dev.mxcl.AppUpdater")
        activity.repeats = true
        activity.interval = 24 * 60 * 60
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                guard !self.activity.shouldDefer, self.active == nil else {
                    completion(.deferred)
                    return
                }
                do {
                    try await self.check()
                    completion(.finished)
                } catch {
                    completion(.finished)
                }
            }
        }
#endif
    }

#if !DEBUG
    deinit {
        MainActor.assumeIsolated {
            activity.invalidate()
        }
    }
#endif

    public func check() async throws {
        if let active {
            return try await active.value
        }

        let owner = owner
        let repo = repo
        let session = session
        let allowPrereleases = allowPrereleases

        let task = Task {
            guard Bundle.main.executableURL != nil else {
                throw AppUpdaterError.bundleExecutableURL
            }

            let currentVersion = try Bundle.main.appVersion
            let releases = try await Self.fetchReleases(
                owner: owner,
                repo: repo,
                session: session
            )
            guard let asset = try releases.findViableUpdate(
                appVersion: currentVersion,
                repo: repo,
                prerelease: allowPrereleases
            ) else {
                return
            }

            try await Self.update(with: asset, session: session)
        }

        active = task
        defer { active = nil }
        return try await task.value
    }

    private static func fetchReleases(
        owner: String,
        repo: String,
        session: URLSession
    ) async throws -> [Release] {
        let slug = "\(owner)/\(repo)"
        let url = URL(string: "https://api.github.com/repos/\(slug)/releases")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode
        else {
            throw AppUpdaterError.invalidGitHubResponse
        }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    private static func update(with asset: Release.Asset, session: URLSession) async throws {
#if DEBUG
        print("notice: AppUpdater dry-run:", asset)
#else
        guard asset.browserDownloadURL.scheme == "https" else {
            throw AppUpdaterError.insecureDownloadURL
        }

        let tmpdir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: Bundle.main.bundleURL,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let downloadURL = tmpdir.appendingPathComponent("download")
        let (downloadedURL, _) = try await session.download(
            from: asset.browserDownloadURL
        )
        try FileManager.default.moveItem(at: downloadedURL, to: downloadURL)

        let downloadedAppBundleURL = try await ArchiveExtractor.extract(
            downloadURL,
            contentType: asset.contentType,
            into: tmpdir
        )
        guard let downloadedAppBundle = Bundle(url: downloadedAppBundleURL) else {
            throw AppUpdaterError.invalidDownloadedBundle
        }

        try await CodeSignature.requireSameSigner(
            current: .main,
            candidate: downloadedAppBundle
        )

        let installedAppBundle = Bundle.main
        guard let executableURL = downloadedAppBundle.executableURL else {
            throw AppUpdaterError.invalidDownloadedBundle
        }
        let relativeExecutablePath = executableURL.path.replacingOccurrences(
            of: downloadedAppBundle.bundleURL.path + "/",
            with: ""
        )
        let finalExecutableURL = installedAppBundle.bundleURL
            .appendingPathComponent(relativeExecutablePath)

        try FileManager.default.removeItem(at: installedAppBundle.bundleURL)
        try FileManager.default.moveItem(
            at: downloadedAppBundle.bundleURL,
            to: installedAppBundle.bundleURL
        )

        let process = Process()
        process.executableURL = finalExecutableURL
        try process.run()

        NSApp.terminate(nil)
#endif
    }
}

enum AppUpdaterError: LocalizedError, Equatable {
    case bundleExecutableURL
    case invalidAppVersion(String)
    case invalidArchiveEntry(String)
    case invalidDownloadedBundle
    case invalidGitHubResponse
    case insecureDownloadURL
    case missingCodeSigningInfo
    case mismatchedCodeSigningInfo
    case noUpdateAvailable
    case processFailed(URL, Int32, String)
    case unsupportedContentType(String)

    var errorDescription: String? {
        switch self {
        case .bundleExecutableURL:
            "The running bundle has no executable URL."
        case .invalidAppVersion(let version):
            "The running bundle has an invalid version: \(version)."
        case .invalidArchiveEntry(let entry):
            "The downloaded archive contains an unsafe entry: \(entry)."
        case .invalidDownloadedBundle:
            "The downloaded asset did not contain a valid app bundle."
        case .invalidGitHubResponse:
            "GitHub returned an invalid response."
        case .insecureDownloadURL:
            "The release asset download URL is not HTTPS."
        case .missingCodeSigningInfo:
            "A bundle is missing required code-signing information."
        case .mismatchedCodeSigningInfo:
            "The downloaded app was signed by a different identity."
        case .noUpdateAvailable:
            "No update is available."
        case .processFailed(let executable, let status, let stderr):
            "\(executable.path) failed with status \(status): \(stderr)"
        case .unsupportedContentType(let contentType):
            "Unsupported release asset content type: \(contentType)."
        }
    }
}

struct Release: Decodable, Comparable {
    let tagName: SemanticVersion
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case assets
    }

    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL
        let contentType: ContentType

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case contentType = "content_type"
        }
    }

    func viableAsset(forRepo repo: String) -> Asset? {
        assets.first { asset in
            let prefix = "\(repo.lowercased())-\(tagName)"
            let name = (asset.name as NSString).deletingPathExtension
                .lowercased()

            switch (name, asset.contentType) {
            case ("\(prefix).tar", .tar):
                return true
            case (prefix, _):
                return true
            default:
                return false
            }
        }
    }

    static func < (lhs: Release, rhs: Release) -> Bool {
        lhs.tagName < rhs.tagName
    }
}

enum ContentType: Decodable, Equatable {
    case zip
    case tar

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "application/x-bzip2", "application/x-xz", "application/x-gzip":
            self = .tar
        case "application/zip":
            self = .zip
        default:
            throw AppUpdaterError.unsupportedContentType(rawValue)
        }
    }
}

extension Array where Element == Release {
    func findViableUpdate(
        appVersion: SemanticVersion,
        repo: String,
        prerelease: Bool
    ) throws -> Release.Asset? {
        let suitableReleases = prerelease ? self : filter { !$0.prerelease }
        for release in suitableReleases.sorted().reversed() {
            guard appVersion < release.tagName else {
                throw AppUpdaterError.noUpdateAvailable
            }
            if let asset = release.viableAsset(forRepo: repo) {
                return asset
            }
        }
        return nil
    }
}

struct SemanticVersion: Comparable, CustomStringConvertible, Decodable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    init(_ string: String) throws {
        let version = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = version.split(separator: "-", maxSplits: 1).map(String.init)
        let core = parts[0].split(separator: ".").map(String.init)
        guard core.count == 3,
              let major = Int(core[0]),
              let minor = Int(core[1]),
              let patch = Int(core[2])
        else {
            throw AppUpdaterError.invalidAppVersion(string)
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = try parts.dropFirst().first?
            .split(separator: ".")
            .map { try Identifier(String($0)) } ?? []
    }

    init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return base }
        return "\(base)-\(prerelease.map(\.description).joined(separator: "."))"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        guard lhsCore == rhsCore else {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            return lhs.prerelease.lexicographicallyPrecedes(rhs.prerelease)
        }
    }

    enum Identifier: Comparable, CustomStringConvertible {
        case numeric(Int)
        case alphanumeric(String)

        init(_ string: String) throws {
            guard !string.isEmpty else {
                throw AppUpdaterError.invalidAppVersion(string)
            }
            if let value = Int(string) {
                self = .numeric(value)
            } else {
                self = .alphanumeric(string)
            }
        }

        var description: String {
            switch self {
            case .numeric(let value):
                "\(value)"
            case .alphanumeric(let value):
                value
            }
        }

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let lhs), .numeric(let rhs)):
                lhs < rhs
            case (.numeric, .alphanumeric):
                true
            case (.alphanumeric, .numeric):
                false
            case (.alphanumeric(let lhs), .alphanumeric(let rhs)):
                lhs < rhs
            }
        }
    }
}

enum ArchiveExtractor {
    static func extract(
        _ url: URL,
        contentType: ContentType,
        into directory: URL
    ) async throws -> URL {
        let entries = try await entries(in: url, contentType: contentType)
        try validate(entries: entries)

        let extractionDirectory = directory.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )

        switch contentType {
        case .tar:
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", url.path, "-C", extractionDirectory.path]
            )
        case .zip:
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", url.path, extractionDirectory.path]
            )
        }

        return try findSingleApp(in: extractionDirectory)
    }

    static func validate(entries: [String]) throws {
        guard !entries.isEmpty else {
            throw AppUpdaterError.invalidDownloadedBundle
        }

        for entry in entries {
            let path = entry.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = path.split(separator: "/").map(String.init)
            guard !entry.hasPrefix("/"),
                  !components.contains("..")
            else {
                throw AppUpdaterError.invalidArchiveEntry(entry)
            }
        }
    }

    private static func entries(
        in url: URL,
        contentType: ContentType
    ) async throws -> [String] {
        switch contentType {
        case .tar:
            let output = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-tf", url.path]
            )
            return output.stdout.lines
        case .zip:
            let output = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-Z", "-1", url.path]
            )
            return output.stdout.lines
        }
    }

    private static func findSingleApp(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let apps = try contents.filter { url in
            guard url.pathExtension == "app" else { return false }
            return try url.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory == true
        }
        guard apps.count == 1, let app = apps.first else {
            throw AppUpdaterError.invalidDownloadedBundle
        }
        return app
    }
}

struct CodeSignature {
    let identifier: String
    let teamIdentifier: String

    static func requireSameSigner(current: Bundle, candidate: Bundle) async throws {
        async let currentInfo = info(for: current)
        async let candidateInfo = info(for: candidate)

        guard try await currentInfo == candidateInfo else {
            throw AppUpdaterError.mismatchedCodeSigningInfo
        }
    }

    static func info(for bundle: Bundle) async throws -> CodeSignature {
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", bundle.bundlePath]
        )
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dvvv", bundle.bundlePath]
        )

        let fields = Dictionary<String, String>(
            uniqueKeysWithValues: output.stderr.lines.compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
        )
        guard let identifier = fields["Identifier"],
              let teamIdentifier = fields["TeamIdentifier"],
              !identifier.isEmpty,
              !teamIdentifier.isEmpty
        else {
            throw AppUpdaterError.missingCodeSigningInfo
        }
        return CodeSignature(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }
}

extension CodeSignature: Equatable {}

enum ProcessRunner {
    struct Output {
        let stdout: String
        let stderr: String
    }

    static func run(
        _ executableURL: URL,
        arguments: [String]
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = Output(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                )
                guard process.terminationStatus == 0 else {
                    continuation.resume(
                        throwing: AppUpdaterError.processFailed(
                            executableURL,
                            process.terminationStatus,
                            output.stderr
                        )
                    )
                    return
                }
                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private extension Bundle {
    var appVersion: SemanticVersion {
        get throws {
            let rawVersion = object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String
            guard let rawVersion else {
                throw AppUpdaterError.invalidAppVersion("")
            }
            return try SemanticVersion(rawVersion)
        }
    }
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }
}
