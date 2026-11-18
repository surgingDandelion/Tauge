import AppKit
import SwiftUI
import ShellXKit

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case ready
        case installing
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var update: TaugeUpdate?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCheck: Date?

    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var windowController: UpdateWindowController?

    private init() {
        lastCheck = AppState.shared.settings.lastUpdateCheck
    }

    var currentVersion: String { TaugeAppInfo.version }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    // MARK: - Window

    func presentWindow() {
        if windowController == nil {
            let controller = UpdateWindowController(controller: self)
            controller.onClose = { [weak self] in
                self?.windowController = nil
            }
            windowController = controller
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        windowController?.close()
    }

    // MARK: - Checking

    func scheduleAutomaticCheck() {
        let settings = AppState.shared.settings
        guard settings.automaticallyChecksForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            let current = AppState.shared.settings
            guard current.automaticallyChecksForUpdates else { return }
            if let last = current.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
            self.checkForUpdates(manual: false)
        }
    }

    func checkForUpdates(manual: Bool) {
        if manual { presentWindow() }
        guard !isBusy else { return }
        checkTask?.cancel()
        if case .failed = phase { phase = .idle }
        errorMessage = nil
        phase = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await TaugeUpdateService.shared.checkForUpdate(currentVersion: self.currentVersion)
                try Task.checkCancellation()
                self.apply(result, manual: manual)
            } catch is CancellationError {
                if manual, self.phase == .checking { self.phase = .idle }
            } catch {
                self.handle(error: error, manual: manual)
            }
        }
    }

    private func apply(_ result: TaugeUpdateCheck, manual: Bool) {
        let now = Date()
        lastCheck = now
        AppState.shared.recordUpdateCheck(now)
        switch result {
        case .upToDate:
            update = nil
            phase = .upToDate
        case .available(let update):
            self.update = update
            phase = .available
            if !manual { presentWindow() }
        }
    }

    private func handle(error: Error, manual: Bool) {
        if manual {
            errorMessage = error.localizedDescription
            phase = .failed
        } else {
            phase = .idle
        }
    }

    // MARK: - Download and install

    func downloadAndInstall() {
        guard let update, phase == .available else { return }
        phase = .downloading
        errorMessage = nil
        installTask?.cancel()
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await TaugeUpdateService.shared.downloadVerifiedArchive(
                    for: update,
                    to: Self.archiveDestination(for: update)
                )
                try Task.checkCancellation()
                self.phase = .ready
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try TaugeUpdateInstaller.prepare(archive: archive, update: update)
                }.value
                self.phase = .installing
                try TaugeUpdateInstaller.launch(prepared)
                // The detached script waits for this process to exit before it
                // swaps the bundle. Give it a moment to start, then quit.
                let delay: UInt64 = prepared.privileged ? 1_500_000_000 : 250_000_000
                try? await Task.sleep(nanoseconds: delay)
                NSApp.terminate(nil)
            } catch is CancellationError {
                if self.phase == .downloading || self.phase == .ready {
                    self.phase = .available
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    func cancelDownload() {
        installTask?.cancel()
        installTask = nil
        if phase == .downloading || phase == .ready {
            phase = .available
        }
    }

    func retry() {
        if update != nil {
            if phase == .failed {
                phase = .available
            }
            downloadAndInstall()
        } else {
            checkForUpdates(manual: true)
        }
    }

    func dismiss() {
        if phase == .failed || phase == .upToDate || phase == .available {
            closeWindow()
        }
    }

    private static func archiveDestination(for update: TaugeUpdate) -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Tauge/Updates", isDirectory: true)
        return directory.appendingPathComponent("Tauge-\(update.version).zip")
    }
}
