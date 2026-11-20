import Foundation
import TaugeKit

enum TaugeCLIInstaller {
    static func install() throws -> URL {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TaugeCLI")
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            throw InstallerError.cliMissing
        }

        let destinationDirectory = try writableDirectory()
        let destination = destinationDirectory.appendingPathComponent("tauge")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        return destination
    }

    private static func writableDirectory() throws -> URL {
        let fileManager = FileManager.default
        let preferred = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        if (try? fileManager.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil,
           fileManager.isWritableFile(atPath: preferred.path) {
            return preferred
        }

        let fallback = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: fallback.path) else {
            throw InstallerError.destinationUnavailable
        }
        return fallback
    }
}

private enum InstallerError: Error, LocalizedError {
    case cliMissing
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .cliMissing:
            return L("当前应用包没有包含 tauge 命令行工具，请重新安装最新版本。")
        case .destinationUnavailable:
            return L("没有可写的命令行工具目录。")
        }
    }
}
