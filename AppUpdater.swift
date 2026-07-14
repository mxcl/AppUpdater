import AppKit
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
    private let stageAsset: @Sendable (Release.Asset) async throws -> Update

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
        stageAsset: @escaping @Sendable (Release.Asset) async throws -> Update
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
                maximumBytes: configuration.maximumDownloadBytes,
                timeout: configuration.timeout
            )

            let downloadedAppBundleURL = try await ArchiveExtractor.extract(
                downloadURL,
                contentType: contentType,
                into: tmpdir,
                limits: .init(configuration)
            )
            guard let downloadedAppBundle = Bundle(url: downloadedAppBundleURL) else {
                throw AppUpdaterError.invalidDownloadedBundle
            }

            try CodeSignature.requireSameSigner(
                current: installedAppBundle,
                candidate: downloadedAppBundle
            )

            guard let executableURL = downloadedAppBundle.executableURL else {
                throw AppUpdaterError.invalidDownloadedBundle
            }
            let relativeExecutablePath = executableURL.path.replacingOccurrences(
                of: downloadedAppBundle.bundleURL.path + "/",
                with: ""
            )
            let finalExecutableURL = installedAppBundle.bundleURL
                .appendingPathComponent(relativeExecutablePath)

            return Update(
                assetName: asset.name,
                stagedBundleURL: downloadedAppBundle.bundleURL,
                installedBundleURL: installedAppBundle.bundleURL,
                executableURL: finalExecutableURL,
                stagingDirectoryURL: tmpdir
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

public struct Update: Sendable {
    typealias Relauncher = @Sendable (URL, [String]) throws -> Void
    typealias Terminator = @MainActor @Sendable () -> Void

    public let assetName: String
    public let stagedBundleURL: URL
    public let installedBundleURL: URL
    public let executableURL: URL

    let stagingDirectoryURL: URL
    let relauncher: Relauncher
    let terminator: Terminator

    @MainActor
    public func installAndRelaunch() async throws {
        let helperURL = try InstallerHelper.writeScript(in: stagingDirectoryURL)
        try relauncher(helperURL, [
            "\(getpid())",
            stagedBundleURL.path,
            installedBundleURL.path,
            executableURL.path,
            stagingDirectoryURL.path,
        ])
        terminator()
    }

    init(
        assetName: String,
        stagedBundleURL: URL,
        installedBundleURL: URL,
        executableURL: URL,
        stagingDirectoryURL: URL,
        relauncher: @escaping Relauncher = InstallerHelper.launch,
        terminator: @escaping Terminator = { NSApp.terminate(nil) }
    ) {
        self.assetName = assetName
        self.stagedBundleURL = stagedBundleURL
        self.installedBundleURL = installedBundleURL
        self.executableURL = executableURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.relauncher = relauncher
        self.terminator = terminator
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
    case missingCodeSigningInfo
    case mismatchedCodeSigningInfo
    case operationTimedOut
    case processFailed(URL, Int32, String)
    case resourceLimitExceeded(String)
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
        case .missingCodeSigningInfo:
            "A bundle is missing required code-signing information."
        case .mismatchedCodeSigningInfo:
            "The downloaded app was signed by a different identity."
        case .operationTimedOut:
            "The update operation timed out."
        case .processFailed(let executable, let status, let stderr):
            "\(executable.path) failed with status \(status): \(stderr)"
        case .resourceLimitExceeded(let resource):
            "The update exceeded the configured \(resource) limit."
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
            throw delegate.error ?? error
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
            throw delegate.error ?? error
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard response.url?.scheme?.lowercased() == "https",
              let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode
        else {
            throw AppUpdaterError.invalidHTTPResponse
        }
    }

    private final class TransferDelegate: NSObject,
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
                bytes += Int64(values.fileSize ?? 0)
                guard bytes <= limits.maximumBytes else {
                    throw AppUpdaterError.resourceLimitExceeded("mounted content size")
                }
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
    static func requireSameSigner(current: Bundle, candidate: Bundle) throws {
        let currentCode = try staticCode(for: current)
        let candidateCode = try staticCode(for: candidate)

        try checkValidity(of: currentCode, requirement: nil)

        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(
            currentCode,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw AppUpdaterError.missingCodeSigningInfo
        }

        try checkValidity(of: candidateCode, requirement: requirement)
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
            throw AppUpdaterError.mismatchedCodeSigningInfo
        }
    }
}

enum InstallerHelper {
    static func launch(scriptURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = arguments
        try process.run()
    }

    static func writeScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("install-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    static let script = """
    #!/bin/sh
    set -eu

    pid="$1"
    staged_bundle="$2"
    installed_bundle="$3"
    executable="$4"
    staging_directory="$5"
    installed_name="$(basename "$installed_bundle")"
    installed_parent="$(dirname "$installed_bundle")"
    prepared_bundle="$(dirname "$staged_bundle")/$installed_name"
    deadline=$(( $(date +%s) + 300 ))

    trap 'rm -rf "$staging_directory"' EXIT

    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            exit 1
        fi
        sleep 0.2
    done

    if [ "$staged_bundle" != "$prepared_bundle" ]; then
        rm -rf "$prepared_bundle"
        mv "$staged_bundle" "$prepared_bundle"
        staged_bundle="$prepared_bundle"
    fi

    if [ -w "$installed_parent" ] && { [ ! -e "$installed_bundle" ] || [ -w "$installed_bundle" ]; }; then
        rm -rf "$installed_bundle"
        mv "$staged_bundle" "$installed_bundle"
    else
        /usr/bin/osascript - "$staged_bundle" "$installed_parent" <<'APPLESCRIPT'
    on run argv
        set stagedBundle to POSIX file (item 1 of argv) as alias
        set destinationFolder to POSIX file (item 2 of argv) as alias
        tell application "Finder" to move stagedBundle to destinationFolder with replacing
    end run
    APPLESCRIPT
    fi

    if [ -x "$executable" ]; then
        "$executable" >/dev/null 2>&1 &
    else
        /usr/bin/open "$installed_bundle"
    fi
    """
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
