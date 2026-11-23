import Foundation

// MARK: - Public models

/// The subset of the GitHub release API that the updater consumes.
public struct GitHubReleaseAsset: Decodable, Sendable, Equatable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int64?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        browserDownloadURL = try container.decode(URL.self, forKey: .browserDownloadURL)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
    }
}

public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let publishedAt: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }
}

/// A newer release that can be installed from inside the app.
public struct TaugeUpdate: Sendable, Equatable {
    public let version: TaugeVersion
    public let tagName: String
    public let title: String
    public let notes: String
    public let releaseURL: URL
    public let archiveURL: URL
    public let archiveName: String
    public let archiveSize: Int64
    public let checksumsURL: URL
    public let publishedAt: String?

    /// The release pipeline uploads Tauge-<version>-arm64.zip next to the DMG.
    public var displaySize: String {
        guard archiveSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: archiveSize, countStyle: .file)
    }
}

public enum TaugeUpdateCheck: Sendable, Equatable {
    case upToDate(current: TaugeVersion)
    case available(TaugeUpdate)
}

// MARK: - Errors

public enum TaugeUpdateError: Error, Equatable, LocalizedError {
    case network(String)
    case httpStatus(Int)
    case invalidResponse
    case invalidRelease
    case noStableRelease
    case invalidVersion(String)
    case missingAsset(String)
    case insecureURL
    case checksumMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadIncomplete(expected: Int64, actual: Int64)
    case archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return L("无法连接 GitHub：%@", detail)
        case .httpStatus(let code):
            return L("更新服务器返回 HTTP %d。", code)
        case .invalidResponse:
            return L("GitHub 返回了无法识别的响应。")
        case .invalidRelease:
            return L("无法解析 GitHub 的版本信息。")
        case .noStableRelease:
            return L("GitHub 上没有可用的正式版本。")
        case .invalidVersion(let raw):
            return L("无法识别版本号“%@”。", raw)
        case .missingAsset(let name):
            return L("发布中缺少 %@，无法自动更新。", name)
        case .insecureURL:
            return L("更新地址不是 HTTPS，已停止。")
        case .checksumMissing(let name):
            return L("校验文件中没有 %@。", name)
        case .checksumMismatch:
            return L("更新包的 SHA-256 校验失败，已停止安装。")
        case .downloadIncomplete(let expected, let actual):
            return L("更新包下载不完整（应为 %lld 字节，实际 %lld 字节）。", expected, actual)
        case .archiveTooLarge:
            return L("更新包超出预期大小。")
        }
    }
}

// MARK: - Checksum file

public enum TaugeChecksum {
    /// Parse the output of `shasum -a 256`. Malformed lines are ignored; the
    /// first entry for a name wins.
    public static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        let hex = Set("0123456789abcdef")
        for rawLine in contents.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let digest = String(line[..<separator]).lowercased()
            var name = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard digest.count == 64, digest.allSatisfy({ hex.contains($0) }), !name.isEmpty else { continue }
            if result[name] == nil { result[name] = digest }
        }
        return result
    }

    public static func expectedSHA256(for fileName: String, in contents: String) -> String? {
        parse(contents)[fileName]
    }
}

// MARK: - Service

/// Talks to the GitHub release API and downloads the verified ZIP asset.
///
/// The updater deliberately consumes the latest *published release* rather than
/// the raw tag list: tags have no release notes or assets, while every release
/// in this repository is cut from an annotated tag and carries the ZIP plus its
/// SHA-256 file. That keeps the tag as the source of truth for the version and
/// still gives the app something it can verify before installing.
public final class TaugeUpdateService: @unchecked Sendable {
    public static let shared = TaugeUpdateService()

    public let repository: String
    private let session: URLSession

    public init(repository: String = "surgingDandelion/Tauge", session: URLSession? = nil) {
        self.repository = repository
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 600
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Fetch the newest stable release and compare it with the running app.
    public func checkForUpdate(currentVersion: String) async throws -> TaugeUpdateCheck {
        let url = latestReleaseURL
        let request = makeRequest(url: url)
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, maxBytes: 8 * 1024 * 1024, received: data.count)
            return try Self.evaluate(releaseData: data, currentVersion: currentVersion)
        } catch let error as TaugeUpdateError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TaugeUpdateError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TaugeUpdateError.network(error.localizedDescription)
        }
    }

    /// Download the release ZIP, verify it against SHA256SUMS.txt from the same
    /// release, and leave the verified archive at `destination`.
    ///
    /// `progress` runs on the downloader's own delegate queue and is throttled
    /// to a handful of updates per second; UI callers must hop back to the main
    /// actor before touching state.
    @discardableResult
    public func downloadVerifiedArchive(
        for update: TaugeUpdate,
        to destination: URL,
        progress: (@Sendable (ArchiveDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let checksumText = try await downloadChecksumFile(for: update)
        guard let expected = TaugeChecksum.expectedSHA256(for: update.archiveName, in: checksumText) else {
            throw TaugeUpdateError.checksumMissing(update.archiveName)
        }

        let temporaryURL: URL
        do {
            let (downloaded, response) = try await downloadTemporaryCopy(of: update.archiveURL, progress: progress)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: downloaded)
                throw TaugeUpdateError.invalidResponse
            }
            guard http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: downloaded)
                throw TaugeUpdateError.httpStatus(http.statusCode)
            }
            temporaryURL = downloaded
        } catch let error as TaugeUpdateError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TaugeUpdateError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TaugeUpdateError.network(error.localizedDescription)
        }

        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = Int64(values.fileSize ?? 0)
        if update.archiveSize > 0, actualSize != update.archiveSize {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw TaugeUpdateError.downloadIncomplete(expected: update.archiveSize, actual: actualSize)
        }
        let actual = try TaugeSHA256.hash(fileAt: temporaryURL)
        guard actual.lowercased() == expected else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw TaugeUpdateError.checksumMismatch(expected: expected, actual: actual)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: destination)
            try? fileManager.removeItem(at: temporaryURL)
        }
        return destination
    }

    /// Download one file with byte-level progress and hand back the temporary
    /// copy plus the response headers. Errors arrive unmapped so the caller
    /// decides how to report them.
    ///
    /// Public so the self-check suite can drive the progress plumbing against a
    /// file URL instead of the network.
    public func downloadTemporaryCopy(
        of url: URL,
        progress: (@Sendable (ArchiveDownloadProgress) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        let downloader = ArchiveDownloadCoordinator(progress: progress)
        return try await downloader.download(makeAssetRequest(url: url), configuration: session.configuration)
    }

    private func downloadChecksumFile(for update: TaugeUpdate) async throws -> String {
        let request = makeRequest(url: update.checksumsURL)
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, maxBytes: 1024 * 1024, received: data.count)
            guard let text = String(data: data, encoding: .utf8) else {
                throw TaugeUpdateError.invalidResponse
            }
            return text
        } catch let error as TaugeUpdateError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TaugeUpdateError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TaugeUpdateError.network(error.localizedDescription)
        }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tauge/\(TaugeAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The asset endpoint redirects to a signed objects host, so the request
    /// stays minimal: no GitHub Accept header, just a user agent.
    private func makeAssetRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Tauge/\(TaugeAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw TaugeUpdateError.invalidResponse }
        return http
    }

    private static func validate(response: URLResponse, maxBytes: Int, received: Int) throws {
        let http = try httpResponse(response)
        guard http.statusCode == 200 else { throw TaugeUpdateError.httpStatus(http.statusCode) }
        guard received <= maxBytes else { throw TaugeUpdateError.archiveTooLarge }
    }

    private static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }

    /// Pure parsing step, kept public so the self-check suite can exercise the
    /// release JSON without touching the network.
    public static func evaluate(releaseData: Data, currentVersion: String) throws -> TaugeUpdateCheck {
        guard let current = TaugeVersion(currentVersion) else {
            throw TaugeUpdateError.invalidVersion(currentVersion)
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        } catch {
            throw TaugeUpdateError.invalidRelease
        }
        guard !release.draft, !release.prerelease else {
            throw TaugeUpdateError.noStableRelease
        }
        guard let latest = TaugeVersion(release.tagName) else {
            throw TaugeUpdateError.invalidVersion(release.tagName)
        }
        guard current < latest else {
            return .upToDate(current: current)
        }
        guard isSecure(release.htmlURL) else { throw TaugeUpdateError.insecureURL }
        // The architecture suffix keeps older updaters from offering this ZIP on Intel Macs.
        let archiveName = "Tauge-\(latest)-arm64.zip"
        guard let archive = release.assets.first(where: { $0.name == archiveName }) else {
            throw TaugeUpdateError.missingAsset(archiveName)
        }
        guard let checksums = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else {
            throw TaugeUpdateError.missingAsset("SHA256SUMS.txt")
        }
        guard isSecure(archive.browserDownloadURL), isSecure(checksums.browserDownloadURL) else {
            throw TaugeUpdateError.insecureURL
        }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .available(TaugeUpdate(
            version: latest,
            tagName: release.tagName,
            title: title.isEmpty ? "Tauge \(latest)" : title,
            notes: notes,
            releaseURL: release.htmlURL,
            archiveURL: archive.browserDownloadURL,
            archiveName: archive.name,
            archiveSize: archive.size ?? 0,
            checksumsURL: checksums.browserDownloadURL,
            publishedAt: release.publishedAt
        ))
    }
}

// MARK: - Download coordinator

/// One-shot download with byte-level progress.
///
/// `URLSession.download(from:)` reports nothing while it runs, and the async
/// `download(for:delegate:)` overload hands the finished file to whichever
/// delegate you pass anyway. This coordinator drives its own session, moves the
/// file out of the system's temporary location before returning (URLSession
/// deletes it as soon as the delegate call returns), and bridges the delegate
/// contract to a single continuation.
final class ArchiveDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private enum State {
        case ready
        case running
        case finished(Result<(URL, URLResponse), Error>)
    }

    private let progress: (@Sendable (ArchiveDownloadProgress) -> Void)?
    private let mutex = NSLock()
    private var throttle = ProgressThrottle(minimumInterval: 0.2)
    private var state: State = .ready
    private var continuation: CheckedContinuation<Result<(URL, URLResponse), Error>, Never>?

    init(progress: (@Sendable (ArchiveDownloadProgress) -> Void)?) {
        self.progress = progress
    }

    func download(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        let outcome = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<(URL, URLResponse), Error>, Never>) in
                    let immediate = mutex.withLock { () -> Result<(URL, URLResponse), Error>? in
                        if case .finished(let result) = state { return result }
                        state = .running
                        self.continuation = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                        return
                    }
                    task.resume()
                }
            },
            onCancel: {
                // Resolve the caller even if URLSession never delivers a
                // completion for a task that was cancelled before it started.
                self.finish(.failure(URLError(.cancelled)))
                task.cancel()
            }
        )
        return try outcome.get()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let progress else { return }
        let timestamp = Date().timeIntervalSinceReferenceDate
        let shouldEmit = mutex.withLock { throttle.shouldEmit(at: timestamp) }
        guard shouldEmit else { return }
        progress(ArchiveDownloadProgress(bytesReceived: totalBytesWritten,
                                         totalBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tauge-download-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(.failure(error))
            return
        }
        guard let response = downloadTask.response else {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(TaugeUpdateError.invalidResponse))
            return
        }
        // Always deliver a final, unthrottled sample so the bar lands on 100%.
        progress?(ArchiveDownloadProgress(bytesReceived: downloadTask.countOfBytesReceived,
                                          totalBytes: max(downloadTask.countOfBytesExpectedToReceive,
                                                          downloadTask.countOfBytesReceived)))
        finish(.success((destination, response)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // didFinishDownloadingTo normally settles the download first;
            // reaching here without a file means the server sent nothing
            // usable.
            finish(.failure(TaugeUpdateError.invalidResponse))
            return
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        let pending: CheckedContinuation<Result<(URL, URLResponse), Error>, Never>? = mutex.withLock {
            if case .finished = state { return nil }
            state = .finished(result)
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        pending?.resume(returning: result)
    }
}
