import AppKit
import Darwin
import Foundation
import Security
import Version

@MainActor
public final class AppUpdater {
    private var active: Task<Update?, Swift.Error>?
    private let owner: String
    private let repo: String
    private let session: URLSession
    private let hasExecutable: @Sendable () -> Bool
    private let currentVersion: @Sendable () throws -> Version
    private let fetchReleases: @Sendable () async throws -> [Release]
    private let stageAsset: @MainActor @Sendable (Release.Asset) async throws -> Update

    public var allowPrereleases = false

    public struct Configuration: Sendable {
        public var maximumDownloadBytes: Int64
        public var maximumMountedBytes: Int64
        public var maximumEntries: Int
        public var timeout: TimeInterval

        public init(
            maximumDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024,
            maximumMountedBytes: Int64 = 4 * 1024 * 1024 * 1024,
            maximumEntries: Int = 100_000,
            timeout: TimeInterval = 10 * 60
        ) {
            precondition(maximumDownloadBytes > 0)
            precondition(maximumMountedBytes > 0)
            precondition(maximumEntries > 0)
            precondition(timeout > 0)
            self.maximumDownloadBytes = maximumDownloadBytes
            self.maximumMountedBytes = maximumMountedBytes
            self.maximumEntries = maximumEntries
            self.timeout = timeout
        }
    }

    public init(
        owner: String,
        repo: String,
        configuration: Configuration = .init(),
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        let session = URLSession(configuration: sessionConfiguration)
        self.owner = owner
        self.repo = repo
        self.session = session
        hasExecutable = { Bundle.main.executableURL != nil }
        currentVersion = { try Bundle.main.appVersion }
        fetchReleases = {
            try await Self.fetchReleases(
                owner: owner,
                repo: repo,
                session: session,
                configuration: configuration
            )
        }
        stageAsset = { asset in
            try await Self.stageUpdate(
                with: asset,
                replacing: .main,
                session: session,
                configuration: configuration
            )
        }
    }

    init(
        owner: String,
        repo: String,
        hasExecutable: @escaping @Sendable () -> Bool = { true },
        currentVersion: @escaping @Sendable () throws -> Version,
        fetchReleases: @escaping @Sendable () async throws -> [Release],
        stageAsset: @escaping @MainActor @Sendable (Release.Asset) async throws -> Update
    ) {
        self.owner = owner
        self.repo = repo
        self.session = .shared
        self.hasExecutable = hasExecutable
        self.currentVersion = currentVersion
        self.fetchReleases = fetchReleases
        self.stageAsset = stageAsset
    }

    public func check() async throws -> Update? {
        if let active {
            return try await active.value
        }

        let repo = repo
        let allowPrereleases = allowPrereleases
        let hasExecutable = hasExecutable
        let currentVersion = currentVersion
        let fetchReleases = fetchReleases
        let stageAsset = stageAsset

        let task = Task<Update?, Swift.Error> {
            guard hasExecutable() else {
                throw AppUpdaterError.bundleExecutableURL
            }

            let appVersion = try currentVersion()
            let releases = try await fetchReleases()
            guard let asset = try releases.findViableUpdate(
                appVersion: appVersion,
                repo: repo,
                prerelease: allowPrereleases
            ) else {
                return nil
            }

            return try await stageAsset(asset)
        }

        active = task
        defer { active = nil }
        return try await task.value
    }

    static func fetchReleases(
        owner: String,
        repo: String,
        session: URLSession,
        configuration: Configuration = .init()
    ) async throws -> [Release] {
        let slug = "\(owner)/\(repo)"
        let url = URL(string: "https://api.github.com/repos/\(slug)/releases")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        request.timeoutInterval = configuration.timeout
        let data = try await NetworkTransfer.data(
            for: request,
            with: session,
            maximumBytes: min(configuration.maximumDownloadBytes, 10 * 1024 * 1024)
        )
        let decoder = JSONDecoder()
        decoder.userInfo[.decodingMethod] = DecodingMethod.tolerant
        return try decoder.decode([Release].self, from: data)
    }

    private static func stageUpdate(
        with asset: Release.Asset,
        replacing installedAppBundle: Bundle,
        session: URLSession,
        configuration: Configuration
    ) async throws -> Update {
        guard asset.browserDownloadURL.scheme == "https" else {
            throw AppUpdaterError.insecureDownloadURL
        }

        guard let contentType = asset.contentType, contentType == .dmg else {
            throw AppUpdaterError.unsupportedAsset(asset.name)
        }
        guard asset.size > 0 else {
            throw AppUpdaterError.invalidGitHubResponse
        }
        guard asset.size <= configuration.maximumDownloadBytes else {
            throw AppUpdaterError.resourceLimitExceeded("download size")
        }

        let tmpdir = try Self.stagingDirectory()
        do {
            let downloadURL = tmpdir.appendingPathComponent(
                ".app-updater-\(UUID().uuidString).dmg"
            )
            try await NetworkTransfer.download(
                asset.browserDownloadURL,
                with: session,
                to: downloadURL,
                maximumBytes: asset.size,
                timeout: configuration.timeout
            )

            let limits = ArchiveExtractor.Limits(configuration)
            let mount = try await ArchiveExtractor.mount(
                downloadURL,
                at: tmpdir.appendingPathComponent("mounted", isDirectory: true),
                expectedAppName: installedAppBundle.bundleURL.lastPathComponent,
                limits: limits
            )
            guard let downloadedAppBundle = Bundle(url: mount.appURL) else {
                await mount.discard()
                throw AppUpdaterError.invalidDownloadedBundle
            }

            do {
                try CodeSignature.requireSameDeveloperID(
                    current: installedAppBundle,
                    candidate: downloadedAppBundle
                )
            } catch {
                await mount.discard()
                throw error
            }

            let lease = StagingLease(root: tmpdir, mount: mount)
            return Update(
                assetName: asset.name,
                prepare: {
                    try await Installation.prepare(
                        assetName: asset.name,
                        lease: lease,
                        installedBundle: installedAppBundle,
                        limits: limits
                    )
                },
                discard: { await lease.discard() }
            )
        } catch {
            try? FileManager.default.removeItem(at: tmpdir)
            throw error
        }
    }

    static func stagingDirectory() throws -> URL {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = baseURL.appendingPathComponent(
            "app-updater-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}

@MainActor
public final class Update {
    typealias PrepareOperation = @MainActor () async throws -> PreparedUpdate
    typealias DiscardOperation = @MainActor () async -> Void

    public let assetName: String
    private var prepareOperation: PrepareOperation?
    private var discardOperation: DiscardOperation?

    public func prepareInstallation() async throws -> PreparedUpdate {
        guard let operation = prepareOperation else {
            throw AppUpdaterError.invalidUpdateState
        }
        prepareOperation = nil
        discardOperation = nil
        return try await operation()
    }

    public func discard() async {
        let operation = discardOperation
        prepareOperation = nil
        discardOperation = nil
        await operation?()
    }

    init(
        assetName: String,
        prepare: @escaping PrepareOperation,
        discard: @escaping DiscardOperation
    ) {
        self.assetName = assetName
        prepareOperation = prepare
        discardOperation = discard
    }
}

@MainActor
public final class PreparedUpdate {
    typealias InstallOperation = @MainActor () async throws -> Void
    typealias DiscardOperation = @MainActor () async -> Void

    public let assetName: String
    private var installOperation: InstallOperation?
    private var discardOperation: DiscardOperation?

    public func installAndRelaunch() async throws {
        guard let operation = installOperation else {
            throw AppUpdaterError.invalidUpdateState
        }
        installOperation = nil
        discardOperation = nil
        try await operation()
    }

    public func discard() async {
        let operation = discardOperation
        installOperation = nil
        discardOperation = nil
        await operation?()
    }

    init(
        assetName: String,
        install: @escaping InstallOperation,
        discard: @escaping DiscardOperation
    ) {
        self.assetName = assetName
        installOperation = install
        discardOperation = discard
    }
}

public enum AppUpdaterError: LocalizedError, Equatable {
    case bundleExecutableURL
    case invalidAppVersion(String)
    case invalidArchiveEntry(String)
    case invalidDownloadedBundle
    case invalidGitHubResponse
    case insecureDownloadURL
    case invalidHTTPResponse
    case invalidUpdateState
    case invalidDeveloperID
    case missingCodeSigningInfo
    case mismatchedBundleIdentifier
    case mismatchedCodeSigningInfo
    case operationTimedOut
    case promotionFailed
    case processFailed(URL, Int32, String)
    case relaunchFailed
    case resourceLimitExceeded(String)
    case rollbackFailed
    case unsafeInstallationState
    case unsupportedAsset(String)
    case unsupportedContentType(String)

    public var errorDescription: String? {
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
        case .invalidHTTPResponse:
            "The server returned an invalid or insecure response."
        case .invalidUpdateState:
            "This update operation has already been consumed or discarded."
        case .invalidDeveloperID:
            "An app is not signed with a valid Developer ID Application identity."
        case .missingCodeSigningInfo:
            "A bundle is missing required code-signing information."
        case .mismatchedBundleIdentifier:
            "The downloaded app has a different bundle identifier."
        case .mismatchedCodeSigningInfo:
            "The downloaded app was signed by a different identity."
        case .operationTimedOut:
            "The update operation timed out."
        case .promotionFailed:
            "The DMG could not be promoted into a safe installation boundary."
        case .processFailed(let executable, let status, let stderr):
            "\(executable.path) failed with status \(status): \(stderr)"
        case .relaunchFailed:
            "The updated app could not be relaunched safely."
        case .resourceLimitExceeded(let resource):
            "The update exceeded the configured \(resource) limit."
        case .rollbackFailed:
            "The previous app could not be restored after installation failed."
        case .unsafeInstallationState:
            "The installation staging location is writable or unsafe."
        case .unsupportedAsset(let asset):
            "Unsupported release asset: \(asset). Only DMGs are supported."
        case .unsupportedContentType(let contentType):
            "Unsupported release asset content type: \(contentType)."
        }
    }
}

enum NetworkTransfer {
    static func data(
        for request: URLRequest,
        with session: URLSession,
        maximumBytes: Int64
    ) async throws -> Data {
        let delegate = TransferDelegate(maximumBytes: maximumBytes)
        do {
            let (data, response) = try await session.data(
                for: request,
                delegate: delegate
            )
            if let error = delegate.error { throw error }
            try validate(response)
            guard data.count <= maximumBytes else {
                throw AppUpdaterError.resourceLimitExceeded("response size")
            }
            return data
        } catch {
            throw delegate.error ?? mapped(error)
        }
    }

    static func download(
        _ url: URL,
        with session: URLSession,
        to destination: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let delegate = TransferDelegate(maximumBytes: maximumBytes)
        do {
            let (temporaryURL, response) = try await session.download(
                for: request,
                delegate: delegate
            )
            if let error = delegate.error { throw error }
            try validate(response)
            let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                .fileSize ?? 0
            guard size <= maximumBytes else {
                throw AppUpdaterError.resourceLimitExceeded("download size")
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            throw delegate.error ?? mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        if (error as? URLError)?.code == .timedOut {
            return AppUpdaterError.operationTimedOut
        }
        return error
    }

    private static func validate(_ response: URLResponse) throws {
        guard response.url?.scheme?.lowercased() == "https",
              let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode
        else {
            throw AppUpdaterError.invalidHTTPResponse
        }
    }

    final class TransferDelegate: NSObject,
        URLSessionTaskDelegate,
        URLSessionDownloadDelegate,
        @unchecked Sendable
    {
        private let maximumBytes: Int64
        private let lock = NSLock()
        private var storedError: AppUpdaterError?

        init(maximumBytes: Int64) {
            self.maximumBytes = maximumBytes
        }

        var error: AppUpdaterError? {
            lock.withLock { storedError }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard request.url?.scheme?.lowercased() == "https" else {
                lock.withLock {
                    storedError = .insecureDownloadURL
                }
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesWritten > maximumBytes else { return }
            lock.withLock {
                storedError = .resourceLimitExceeded("download size")
            }
            downloadTask.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }
}

struct Release: Decodable, Comparable {
    let tagName: Version
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
        let contentType: ContentType?
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case contentType = "content_type"
            case size
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            browserDownloadURL = try container.decode(
                URL.self,
                forKey: .browserDownloadURL
            )
            let rawContentType = try container.decode(
                String.self,
                forKey: .contentType
            )
            contentType = ContentType(
                rawValue: rawContentType,
                assetName: name
            )
            size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        }
    }

    func viableAsset(forRepo repo: String) -> Asset? {
        assets.first { asset in
            let prefix = "\(repo.lowercased())-\(tagName)"
            let name = (asset.name as NSString).deletingPathExtension
                .lowercased()

            return name == prefix && asset.contentType == .dmg
        }
    }

    static func < (lhs: Release, rhs: Release) -> Bool {
        lhs.tagName < rhs.tagName
    }
}

enum ContentType: Decodable, Equatable {
    case dmg

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue, assetName: nil) else {
            throw AppUpdaterError.unsupportedContentType(rawValue)
        }
        self = value
    }

    init?(rawValue: String, assetName: String?) {
        switch rawValue {
        case "application/x-apple-diskimage":
            self = .dmg
        case let value where [
            "application/octet-stream",
            "binary/octet-stream",
        ].contains(value) && assetName?.lowercased().hasSuffix(".dmg") == true:
            self = .dmg
        default:
            return nil
        }
    }
}

extension Array where Element == Release {
    func findViableUpdate(
        appVersion: Version,
        repo: String,
        prerelease: Bool
    ) throws -> Release.Asset? {
        let suitableReleases = prerelease ? self : filter { !$0.prerelease }
        for release in suitableReleases.sorted().reversed() {
            guard appVersion < release.tagName else {
                return nil
            }
            if let asset = release.viableAsset(forRepo: repo) {
                return asset
            }
        }
        return nil
    }
}

enum ArchiveExtractor {
    struct Limits: Sendable {
        let maximumBytes: Int64
        let maximumEntries: Int
        let timeout: TimeInterval

        init(_ configuration: AppUpdater.Configuration) {
            maximumBytes = configuration.maximumMountedBytes
            maximumEntries = configuration.maximumEntries
            timeout = configuration.timeout
        }
    }

    static func extract(
        _ url: URL,
        contentType: ContentType,
        into directory: URL,
        limits: Limits = .init(.init())
    ) async throws -> URL {
        let extractionDirectory = directory.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )

        return try await extractDiskImage(
            url,
            into: extractionDirectory,
            limits: limits
        )
    }

    final class Mount: @unchecked Sendable {
        let imageURL: URL
        let mountPoint: URL
        let appURL: URL
        private var hold: FileHandle?
        private let timeout: TimeInterval

        fileprivate init(
            imageURL: URL,
            mountPoint: URL,
            appURL: URL,
            hold: FileHandle,
            timeout: TimeInterval
        ) {
            self.imageURL = imageURL
            self.mountPoint = mountPoint
            self.appURL = appURL
            self.hold = hold
            self.timeout = timeout
        }

        func discard() async {
            try? hold?.close()
            hold = nil
            try? await ArchiveExtractor.detachDiskImage(
                at: mountPoint,
                timeout: timeout
            )
        }
    }

    static func mount(
        _ image: URL,
        at mountDirectory: URL,
        expectedAppName: String,
        limits: Limits
    ) async throws -> Mount {
        try FileManager.default.createDirectory(
            at: mountDirectory,
            withIntermediateDirectories: true
        )
        let mountPoint = try await attachDiskImage(
            image,
            at: mountDirectory,
            timeout: limits.timeout
        )
        do {
            let app = try findSingleApp(in: mountPoint)
            guard app.lastPathComponent == expectedAppName else {
                throw AppUpdaterError.invalidDownloadedBundle
            }
            try inspect(app, limits: limits)
            guard let executable = Bundle(url: app)?.executableURL else {
                throw AppUpdaterError.invalidDownloadedBundle
            }
            let hold = try FileHandle(forReadingFrom: executable)
            return Mount(
                imageURL: image,
                mountPoint: mountPoint,
                appURL: app,
                hold: hold,
                timeout: limits.timeout
            )
        } catch {
            try? await detachDiskImage(at: mountPoint, timeout: limits.timeout)
            throw error
        }
    }

    private static func extractDiskImage(
        _ url: URL,
        into extractionDirectory: URL,
        limits: Limits
    ) async throws -> URL {
        let mountDirectory = extractionDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("mounted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mountDirectory,
            withIntermediateDirectories: true
        )

        let mountPoint = try await attachDiskImage(
            url,
            at: mountDirectory,
            timeout: limits.timeout
        )
        do {
            let app = try findSingleApp(in: mountPoint)
            try inspect(app, limits: limits)
            let destination = extractionDirectory.appendingPathComponent(
                app.lastPathComponent,
                isDirectory: true
            )
            try FileManager.default.copyItem(at: app, to: destination)
            try await detachDiskImage(at: mountPoint, timeout: limits.timeout)
            return try findSingleApp(in: extractionDirectory)
        } catch {
            try? await detachDiskImage(at: mountPoint, timeout: limits.timeout)
            throw error
        }
    }

    static func inspect(_ app: URL, limits: Limits) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: app,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw AppUpdaterError.invalidDownloadedBundle
        }

        let deadline = Date().addingTimeInterval(limits.timeout)
        var entries = 0
        var bytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard Date() < deadline else {
                throw AppUpdaterError.operationTimedOut
            }
            entries += 1
            guard entries <= limits.maximumEntries else {
                throw AppUpdaterError.resourceLimitExceeded("mounted entry count")
            }
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                guard size <= limits.maximumBytes - bytes else {
                    throw AppUpdaterError.resourceLimitExceeded("mounted content size")
                }
                bytes += size
            }
        }
    }

    private static func attachDiskImage(
        _ url: URL,
        at mountPoint: URL,
        timeout: TimeInterval
    ) async throws -> URL {
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: [
                "attach",
                "-plist",
                "-nobrowse",
                "-readonly",
                "-mountpoint",
                mountPoint.path,
                url.path,
            ],
            timeout: timeout
        )
        return diskImageMountPoint(from: output.stdout) ?? mountPoint
    }

    private static func detachDiskImage(
        at mountPoint: URL,
        timeout: TimeInterval
    ) async throws {
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path],
            timeout: timeout
        )
    }

    private static func diskImageMountPoint(from plist: String) -> URL? {
        let data = Data(plist.utf8)
        let decoded = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let root = decoded as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]]
        else {
            return nil
        }

        for entity in entities {
            if let path = entity["mount-point"] as? String {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
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

enum CodeSignature {
    struct Identity: Equatable, Sendable {
        let teamIdentifier: String
        let signingIdentifier: String
        let bundleIdentifier: String
    }

    static func requireSameDeveloperID(
        current: Bundle,
        candidate: Bundle
    ) throws {
        try requireMatch(
            current: try validatedIdentity(of: current),
            candidate: try validatedIdentity(of: candidate)
        )
    }

    static func validatedIdentity(of bundle: Bundle) throws -> Identity {
        let code = try staticCode(for: bundle)
        try checkValidity(of: code, requirement: developerIDRequirement())
        return try identity(of: code, bundle: bundle)
    }

    static func requireMatch(current: Identity, candidate: Identity) throws {
        guard current.bundleIdentifier == candidate.bundleIdentifier else {
            throw AppUpdaterError.mismatchedBundleIdentifier
        }
        guard current.teamIdentifier == candidate.teamIdentifier,
              current.signingIdentifier == candidate.signingIdentifier
        else {
            throw AppUpdaterError.mismatchedCodeSigningInfo
        }
    }

    static func validateStructure(of bundle: Bundle) throws {
        try checkValidity(of: staticCode(for: bundle), requirement: nil)
    }

    private static func developerIDRequirement() throws -> SecRequirement {
        let source = """
        anchor apple generic and \
        certificate 1[field.1.2.840.113635.100.6.2.6] and \
        certificate leaf[field.1.2.840.113635.100.6.1.13]
        """ as CFString
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            source,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw AppUpdaterError.missingCodeSigningInfo
        }
        return requirement
    }

    private static func identity(
        of staticCode: SecStaticCode,
        bundle: Bundle
    ) throws -> Identity {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess,
              let information = information as? [CFString: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier]
                as? String,
              let signingIdentifier = information[kSecCodeInfoIdentifier]
                as? String,
              let bundleIdentifier = bundle.bundleIdentifier
        else {
            throw AppUpdaterError.missingCodeSigningInfo
        }
        return Identity(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func staticCode(for bundle: Bundle) throws -> SecStaticCode {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard status == errSecSuccess, let staticCode else {
            throw AppUpdaterError.missingCodeSigningInfo
        }
        return staticCode
    }

    private static func checkValidity(
        of staticCode: SecStaticCode,
        requirement: SecRequirement?
    ) throws {
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSRestrictSymlinks
                | kSecCSRestrictToAppLike
        )
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            flags,
            requirement,
            &error
        )
        guard status == errSecSuccess else {
            _ = error?.takeRetainedValue()
            throw AppUpdaterError.invalidDeveloperID
        }
    }
}

@MainActor
final class StagingLease {
    let root: URL
    let mount: ArchiveExtractor.Mount

    init(root: URL, mount: ArchiveExtractor.Mount) {
        self.root = root
        self.mount = mount
    }

    func discard() async {
        await mount.discard()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
struct InstallationDriver {
    var promote: (URL, URL, Bool) async throws -> Void
    var replace: (URL, URL, URL, Bool) async throws -> Void
    var restore: (URL, URL, Bool) async throws -> Void
    var remove: (URL, Bool) async throws -> Void
    var validate: (URL, CodeSignature.Identity) throws -> Void
    var launch: (URL) async throws -> Void
    var terminate: () -> Void

    static let live = Self(
        promote: { source, destination, protected in
            if protected {
                try await FinderOperations.copy(
                    source,
                    to: destination.deletingLastPathComponent()
                )
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        },
        replace: { candidate, installed, backup, protected in
            if protected {
                try await FinderOperations.replace(
                    installed: installed,
                    with: candidate,
                    backup: backup
                )
            } else {
                try FileManager.default.moveItem(at: installed, to: backup)
                do {
                    try FileManager.default.copyItem(at: candidate, to: installed)
                } catch {
                    try? FileManager.default.moveItem(at: backup, to: installed)
                    throw error
                }
            }
        },
        restore: { installed, backup, protected in
            if protected {
                try await FinderOperations.restore(installed: installed, backup: backup)
            } else {
                if FileManager.default.fileExists(atPath: installed.path) {
                    try FileManager.default.removeItem(at: installed)
                }
                try FileManager.default.moveItem(at: backup, to: installed)
            }
        },
        remove: { url, protected in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if protected {
                try await FinderOperations.remove(url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        },
        validate: { url, expected in
            guard let bundle = Bundle(url: url) else {
                throw AppUpdaterError.invalidDownloadedBundle
            }
            try CodeSignature.requireMatch(
                current: expected,
                candidate: CodeSignature.validatedIdentity(of: bundle)
            )
        },
        launch: { url in
            try await ApplicationLauncher.launchNewInstance(at: url)
        },
        terminate: { NSApp.terminate(nil) }
    )
}

@MainActor
enum ApplicationLauncher {
    static func launchNewInstance(at url: URL) async throws {
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              let executableURL = bundle.executableURL?.resolvingSymlinksInPath()
        else {
            throw AppUpdaterError.invalidDownloadedBundle
        }
        var probe: Process?
        try await launchNewInstance(
            spawn: {
                let process = Process()
                process.executableURL = executableURL
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                probe = process
                return process.processIdentifier
            },
            isReady: { processIdentifier in
                guard let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                ),
                    !application.isTerminated,
                    application.isFinishedLaunching,
                    application.bundleIdentifier == identifier,
                    application.executableURL?.resolvingSymlinksInPath() == executableURL
                else { return false }
                return true
            },
            terminateProbe: {
                if probe?.isRunning == true { probe?.terminate() }
            },
            isProbeTerminated: { probe?.isRunning == false },
            armFallback: { _ in
                try armFallback(
                    oldProcessIdentifier: getpid(),
                    applicationURL: url
                )
            },
            pause: { try await Task.sleep(nanoseconds: 50_000_000) }
        )
    }

    private static func armFallback(
        oldProcessIdentifier: pid_t,
        applicationURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            i=0
            while kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do
                /bin/sleep 0.05
                i=$((i + 1))
            done
            kill -0 "$1" 2>/dev/null && exit 0
            /bin/sleep 1
            exec /usr/bin/open "$2"
            """,
            "app-updater-relauncher",
            String(oldProcessIdentifier),
            applicationURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func launchNewInstance(
        attempts: Int = 200,
        spawn: () throws -> pid_t,
        isReady: (pid_t) -> Bool,
        terminateProbe: () -> Void,
        isProbeTerminated: () -> Bool,
        armFallback: (pid_t) throws -> Void = { _ in },
        pause: () async throws -> Void
    ) async throws {
        let processIdentifier = try spawn()
        for _ in 0..<attempts {
            if isReady(processIdentifier) {
                terminateProbe()
                for _ in 0..<attempts {
                    if isProbeTerminated() {
                        try armFallback(processIdentifier)
                        return
                    }
                    try await pause()
                }
                throw AppUpdaterError.relaunchFailed
            }
            try await pause()
        }
        throw AppUpdaterError.relaunchFailed
    }
}

@MainActor
final class PreparedInstallation {
    let assetName: String
    let installedURL: URL
    let candidateURL: URL
    let promotedImageURL: URL
    let backupURL: URL
    let expectedIdentity: CodeSignature.Identity
    let protected: Bool
    let driver: InstallationDriver
    let cleanup: () async -> Void

    init(
        assetName: String,
        installedURL: URL,
        candidateURL: URL,
        promotedImageURL: URL,
        expectedIdentity: CodeSignature.Identity,
        protected: Bool,
        driver: InstallationDriver,
        cleanup: @escaping () async -> Void
    ) {
        self.assetName = assetName
        self.installedURL = installedURL
        self.candidateURL = candidateURL
        self.promotedImageURL = promotedImageURL
        backupURL = installedURL.deletingLastPathComponent().appendingPathComponent(
            ".app-updater-backup-\(UUID().uuidString).app"
        )
        self.expectedIdentity = expectedIdentity
        self.protected = protected
        self.driver = driver
        self.cleanup = cleanup
    }

    func publicUpdate() -> PreparedUpdate {
        PreparedUpdate(
            assetName: assetName,
            install: { [self] in try await installAndRelaunch() },
            discard: { [self] in await discard() }
        )
    }

    func installAndRelaunch() async throws {
        do {
            try driver.validate(installedURL, expectedIdentity)
            try driver.validate(candidateURL, expectedIdentity)
            try await driver.replace(candidateURL, installedURL, backupURL, protected)
        } catch {
            await discard()
            throw error
        }
        do {
            try driver.validate(installedURL, expectedIdentity)
            try await driver.launch(installedURL)
        } catch {
            do {
                try await driver.restore(installedURL, backupURL, protected)
            } catch {
                await discard()
                throw AppUpdaterError.rollbackFailed
            }
            await discard()
            throw error
        }

        await cleanup()
        try? await driver.remove(backupURL, protected)
        try? await driver.remove(promotedImageURL, protected)
        driver.terminate()
    }

    func discard() async {
        await cleanup()
        try? await driver.remove(promotedImageURL, protected)
    }
}

enum Installation {
    @MainActor
    static func prepare(
        assetName: String,
        lease: StagingLease,
        installedBundle: Bundle,
        limits: ArchiveExtractor.Limits,
        driver: InstallationDriver = .live
    ) async throws -> PreparedUpdate {
        let installedURL = installedBundle.bundleURL
        let parent = installedURL.deletingLastPathComponent()
        let protected = !FileManager.default.isWritableFile(atPath: parent.path)
            && !FileManager.default.isWritableFile(atPath: installedURL.path)
        let promotedImage = parent.appendingPathComponent(
            lease.mount.imageURL.lastPathComponent
        )
        let mountRoot = try AppUpdater.stagingDirectory()
        var preparedMount: ArchiveExtractor.Mount?

        do {
            try await cleanupStaleItems(
                in: parent,
                excluding: installedURL,
                protected: protected,
                driver: driver
            )
            try await driver.promote(lease.mount.imageURL, promotedImage, protected)
            try validatePromotion(
                promotedImage,
                expectedParent: parent,
                protected: protected
            )
            let mount = try await ArchiveExtractor.mount(
                promotedImage,
                at: mountRoot.appendingPathComponent("mounted", isDirectory: true),
                expectedAppName: installedURL.lastPathComponent,
                limits: limits
            )
            preparedMount = mount
            guard let candidate = Bundle(url: mount.appURL) else {
                throw AppUpdaterError.invalidDownloadedBundle
            }
            let identity = try CodeSignature.validatedIdentity(of: installedBundle)
            try CodeSignature.requireMatch(
                current: identity,
                candidate: CodeSignature.validatedIdentity(of: candidate)
            )
            await lease.discard()
            return PreparedInstallation(
                assetName: assetName,
                installedURL: installedURL,
                candidateURL: mount.appURL,
                promotedImageURL: promotedImage,
                expectedIdentity: identity,
                protected: protected,
                driver: driver,
                cleanup: {
                    await mount.discard()
                    try? FileManager.default.removeItem(at: mountRoot)
                }
            ).publicUpdate()
        } catch {
            await preparedMount?.discard()
            await lease.discard()
            try? FileManager.default.removeItem(at: mountRoot)
            try? await driver.remove(promotedImage, protected)
            if error is AppUpdaterError { throw error }
            throw AppUpdaterError.promotionFailed
        }
    }

    static func validatePromotion(
        _ image: URL,
        expectedParent: URL,
        protected: Bool
    ) throws {
        let image = image.standardizedFileURL
        guard image.deletingLastPathComponent() == expectedParent.standardizedFileURL,
              !hasSymlinkComponent(image)
        else {
            throw AppUpdaterError.unsafeInstallationState
        }
        var info = stat()
        guard lstat(image.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG
        else {
            throw AppUpdaterError.unsafeInstallationState
        }
        if protected {
            guard info.st_uid != geteuid(), access(image.path, W_OK) != 0,
                  access(expectedParent.path, W_OK) != 0
            else {
                throw AppUpdaterError.unsafeInstallationState
            }
        }
    }

    static func hasSymlinkComponent(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return true }
            if info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    static func ownsStaleItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let value: String
        let expectedType: mode_t
        if name.hasPrefix(".app-updater-backup-"), name.hasSuffix(".app") {
            value = String(name.dropFirst(20).dropLast(4))
            expectedType = S_IFDIR
        } else if name.hasPrefix(".app-updater-"), name.hasSuffix(".dmg") {
            value = String(name.dropFirst(13).dropLast(4))
            expectedType = S_IFREG
        } else {
            return false
        }
        var info = stat()
        return UUID(uuidString: value) != nil
            && lstat(url.path, &info) == 0
            && info.st_mode & S_IFMT == expectedType
    }

    @MainActor
    static func cleanupStaleItems(
        in parent: URL,
        excluding installed: URL,
        protected: Bool,
        driver: InstallationDriver
    ) async throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents where url != installed && ownsStaleItem(url) {
            try await driver.remove(url, protected)
        }
    }
}

enum FinderOperations {
    private static let executable = URL(fileURLWithPath: "/usr/bin/osascript")

    static func copy(_ source: URL, to parent: URL) async throws {
        let script = """
        on run argv
          set sourceFile to POSIX file (item 1 of argv) as alias
          set destinationFolder to POSIX file (item 2 of argv) as alias
          tell application "Finder" to duplicate sourceFile to destinationFolder
        end run
        """
        _ = try await ProcessRunner.run(
            executable,
            arguments: ["-e", script, source.path, parent.path]
        )
    }

    static func replace(installed: URL, with candidate: URL, backup: URL) async throws {
        let script = """
        on run argv
          set candidateApp to POSIX file (item 1 of argv) as alias
          set installedApp to POSIX file (item 2 of argv) as alias
          set destinationFolder to POSIX file (item 3 of argv) as alias
          set backupName to item 4 of argv
          set installedName to item 5 of argv
          tell application "Finder"
            set name of installedApp to backupName
            try
              duplicate candidateApp to destinationFolder
            on error message number code
              set backupApp to POSIX file ((item 3 of argv) & "/" & backupName) as alias
              set name of backupApp to installedName
              error message number code
            end try
          end tell
        end run
        """
        _ = try await ProcessRunner.run(
            executable,
            arguments: [
                "-e", script, candidate.path, installed.path,
                installed.deletingLastPathComponent().path,
                backup.lastPathComponent, installed.lastPathComponent,
            ]
        )
    }

    static func restore(installed: URL, backup: URL) async throws {
        let script = """
        on run argv
          set installedPath to item 1 of argv
          set backupApp to POSIX file (item 2 of argv) as alias
          set installedName to item 3 of argv
          tell application "Finder"
            if exists POSIX file installedPath then delete POSIX file installedPath
            set name of backupApp to installedName
          end tell
        end run
        """
        _ = try await ProcessRunner.run(
            executable,
            arguments: ["-e", script, installed.path, backup.path, installed.lastPathComponent]
        )
    }

    static func remove(_ url: URL) async throws {
        let script = """
        on run argv
          tell application "Finder" to delete POSIX file (item 1 of argv)
        end run
        """
        _ = try await ProcessRunner.run(
            executable,
            arguments: ["-e", script, url.path]
        )
    }
}

enum ProcessRunner {
    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var workItem: DispatchWorkItem?
        private var didTimeOut = false

        var timedOut: Bool { lock.withLock { didTimeOut } }

        func schedule(after timeout: TimeInterval, process: Process) {
            let workItem = DispatchWorkItem { [weak self, weak process] in
                self?.lock.withLock { self?.didTimeOut = true }
                process?.terminate()
            }
            lock.withLock { self.workItem = workItem }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout,
                execute: workItem
            )
        }

        func cancel() {
            lock.withLock { workItem }?.cancel()
        }
    }

    struct Output {
        let stdout: String
        let stderr: String
    }

    static func run(
        _ executableURL: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let timeoutState = TimeoutState()

            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                timeoutState.cancel()
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = Output(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                )
                if timeoutState.timedOut {
                    continuation.resume(throwing: AppUpdaterError.operationTimedOut)
                } else if process.terminationStatus != 0 {
                    continuation.resume(
                        throwing: AppUpdaterError.processFailed(
                            executableURL,
                            process.terminationStatus,
                            output.stderr
                        )
                    )
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try process.run()
                if let timeout {
                    timeoutState.schedule(after: timeout, process: process)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private extension Bundle {
    var appVersion: Version {
        get throws {
            let rawVersion = object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
            return try Version.appVersion(from: rawVersion)
        }
    }
}

extension Version {
    static func appVersion(from rawVersion: String?) throws -> Version {
            guard let rawVersion else {
                throw AppUpdaterError.invalidAppVersion("")
            }
            guard let version = Version(tolerant: rawVersion) else {
                throw AppUpdaterError.invalidAppVersion(rawVersion)
            }
            return version
    }
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }
}
