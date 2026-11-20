import Foundation
import TaugeKit

/// Collects progress samples arriving on the downloader's delegate queue.
private final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArchiveDownloadProgress] = []

    func append(_ sample: ArchiveDownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(sample)
    }

    var all: [ArchiveDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Drives the progress-reporting download end to end. A file URL keeps the
/// check offline while still exercising the real delegate, the final sample
/// and the temporary-file handoff.
func runUpdateDownloadChecks() async {
    await runAsync("update.download hands back a copy and counts every byte") {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Tauge-checks-download-" + UUID().uuidString)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let payload = Data((0..<48_000).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("payload.zip")
        try payload.write(to: source)

        let service = TaugeUpdateService()
        let samples = ProgressSamples()
        let (downloaded, response) = try await service.downloadTemporaryCopy(of: source) { sample in
            samples.append(sample)
        }
        defer { try? fileManager.removeItem(at: downloaded) }

        expect(downloaded.path != source.path, "the downloader hands back its own copy")
        expectEqual(try Data(contentsOf: downloaded), payload, "the copy matches the payload")
        expect(!(response is HTTPURLResponse), "a file URL produces no HTTP response")

        let seen = samples.all
        expect(!seen.isEmpty, "progress was reported at least once")
        expectEqual(seen.last?.bytesReceived ?? -1, Int64(payload.count), "the last sample counts every byte")
        expect((seen.last?.fraction ?? 0) >= 0.99, "the last sample reads as complete")
        expectEqual(seen.filter { $0.bytesReceived > Int64(payload.count) }.count, 0, "no sample overshoots the payload")
        expectEqual(seen.filter { $0.totalBytes > Int64(payload.count) }.count, 0, "no sample inflates the total")
    }
}