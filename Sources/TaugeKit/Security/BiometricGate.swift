import Foundation
import LocalAuthentication

/// Outcome of asking the user to prove they are present.
public enum BiometricUnlockOutcome: Sendable, Equatable {
    /// Touch ID (or the system password fallback) accepted.
    case unlocked
    /// The Mac cannot evaluate the policy at all — no sensor, no enrolled
    /// biometrics and no device password. Callers should carry on as usual.
    case unavailable
    /// The user dismissed the sheet; treat the action as abandoned.
    case cancelled
    /// Authentication ran but was rejected (too many attempts, sensor error).
    case failed(String)
}

/// One Touch ID gate per process.
///
/// The credential vault is two ordinary files, so the filesystem cannot tell a
/// passer-by from the owner. The app therefore asks the user to confirm with
/// Touch ID (or the device password) before it reads a saved credential, and
/// remembers the answer until it quits, so a session costs one touch instead of
/// one prompt per connection.
public final class BiometricGate: @unchecked Sendable {
    public static let shared = BiometricGate()

    private let mutex = NSLock()
    private var unlocked = false
    /// One prompt at a time. Restoring a workspace connects several tabs at
    /// once; without this every tab would stack its own Touch ID sheet.
    private var pending: Task<BiometricUnlockOutcome, Never>?

    public init() {}

    /// True when the Mac has a usable Touch ID / Optic ID sensor and an
    /// enrolled finger.
    public static func hasBiometrics() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// True when the system can verify the user at all — biometry, the Apple
    /// Watch, or the device password fallback.
    public static func isAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public var isUnlocked: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return unlocked
    }

    /// Forgets the unlock, e.g. when the user closes the last window or asks to
    /// lock the app again.
    public func lock() {
        mutex.lock()
        unlocked = false
        mutex.unlock()
    }

    /// Records an unlock that already happened elsewhere (or a policy that does
    /// not need one).
    public func markUnlocked() {
        mutex.lock()
        unlocked = true
        mutex.unlock()
    }

    /// Asks for Touch ID, falling back to the device password when the sensor
    /// is unavailable or fails. The answer is cached for the process, and
    /// concurrent callers share the sheet that is already up.
    public func unlock(reason: String) async -> BiometricUnlockOutcome {
        if isUnlocked { return .unlocked }

        // The lock only guards the hand-off of the in-flight task: holding an
        // NSLock across an await is exactly what Swift 6 refuses to compile, and
        // the sheet itself must not block another caller.
        let task = mutex.withLock { () -> Task<BiometricUnlockOutcome, Never> in
            if let pending { return pending }
            let task = Task { await self.prompt(reason: reason) }
            pending = task
            return task
        }

        let outcome = await task.value
        mutex.withLock { pending = nil }
        return outcome
    }

    private func prompt(reason: String) async -> BiometricUnlockOutcome {
        if isUnlocked { return .unlocked }

        let context = LAContext()
        context.localizedCancelTitle = L("取消")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            _ = error
            return .unavailable
        }

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            markUnlocked()
            return .unlocked
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                return .cancelled
            default:
                return .failed(laError.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
