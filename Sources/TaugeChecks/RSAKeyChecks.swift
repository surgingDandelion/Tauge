import Foundation
import NIOSSH
import TaugeKit

/// Helpers for the RSA self checks.
private enum RSAKeyFixtures {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RSAKeyFixtures", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: executable + " " + arguments.joined(separator: " ") + " failed: " + text,
            ])
        }
        return text
    }

    static func makeKey(directory: URL, name: String, bits: Int, format: String?) throws -> URL {
        let path = directory.appendingPathComponent(name).path
        var arguments = ["-q", "-t", "rsa", "-b", String(bits), "-N", "", "-C", "tauge-check", "-f", path]
        if let format {
            arguments.insert(contentsOf: ["-m", format], at: 0)
        }
        _ = try run("/usr/bin/ssh-keygen", arguments)
        return URL(fileURLWithPath: path)
    }

    static func publicKeyLine(_ keyPath: URL) throws -> (blob: String, comment: String) {
        let text = try String(contentsOfFile: keyPath.path + ".pub", encoding: .utf8)
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard fields.count >= 2 else {
            throw NSError(domain: "RSAKeyFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected .pub format"])
        }
        return (fields[1], fields.count > 2 ? fields.dropFirst(2).joined(separator: " ") : "")
    }
}

/// Exercises RSA private key support: OpenSSH, PKCS#1 and PKCS#8 encodings for
/// 2048 and 4096 bit keys, plus real end-to-end authentication against the
/// in-process SSH server (which verifies the RSA signature itself).
@MainActor
func runRSAKeyChecks() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tauge-rsa-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        expect(false, "rsa fixtures directory: \(error)")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }

    var parsedKeys: [(String, ParsedPrivateKey, URL)] = []

    for (name, bits, format) in [("id_rsa_openssh_2048", 2048, nil as String?),
                                 ("id_rsa_pem_2048", 2048, "PEM"),
                                 ("id_rsa_pkcs8_2048", 2048, "PKCS8"),
                                 ("id_rsa_openssh_4096", 4096, nil)] {
        let label = name
        let path: URL
        do {
            path = try RSAKeyFixtures.makeKey(directory: directory, name: name, bits: bits, format: format)
        } catch {
            expect(false, "ssh-keygen generates \(label): \(error)")
            continue
        }
        do {
            let parsed = try SSHKeyParser.parse(path: path.path)
            expect(parsed.keyType == "ssh-rsa", "\(label) parses as ssh-rsa (got \(parsed.keyType))")
            let expected = try RSAKeyFixtures.publicKeyLine(path)
            expect(parsed.publicKeyOpenSSH == "ssh-rsa " + expected.blob,
                   "derived public key matches ssh-keygen for \(label)")
            expect(parsed.comment == nil || parsed.comment == expected.comment || expected.comment.isEmpty,
                   "comment handling for \(label) is consistent")
            if let blob = Data(base64Encoded: expected.blob) {
                let fingerprint = KeyFingerprint.sha256(blob)
                let sshKeygen = try RSAKeyFixtures.run("/usr/bin/ssh-keygen", ["-lf", path.path + ".pub"])
                expect(sshKeygen.contains(fingerprint),
                       "SHA256 fingerprint matches ssh-keygen for \(label) (\(fingerprint))")
            } else {
                expect(false, "public key blob decodes for \(label)")
            }
            parsedKeys.append((label, parsed, path))
        } catch {
            expect(false, "\(label) parses: \(error)")
        }
    }

    // A passphrase-protected RSA key still reports the encrypted-key error.
    do {
        let path = directory.appendingPathComponent("id_rsa_encrypted").path
        _ = try RSAKeyFixtures.run("/usr/bin/ssh-keygen",
                                   ["-q", "-t", "rsa", "-b", "2048", "-N", "hunter2", "-f", path])
        do {
            _ = try SSHKeyParser.parse(path: path)
            expect(false, "encrypted RSA key is rejected")
        } catch SSHKeyError.encrypted {
            expect(true, "encrypted RSA key asks for a passphrase")
        } catch SSHKeyError.unsupported {
            expect(true, "encrypted RSA key reports the supported-format limitation")
        }
    } catch {
        expect(false, "ssh-keygen generates an encrypted key: \(error)")
    }

    // Both RFC 8332 signature algorithms must authenticate against a real server
    // implementation, which validates the signature blob and the algorithm name.
    // A successful signature also proves the derived CRT parameters are correct.
    let authenticationCases: [(algorithm: NIOSSHRSASignatureAlgorithm, fixture: String)] = [
        (.rsaSHA2_512, "id_rsa_openssh_2048"),
        (.rsaSHA2_256, "id_rsa_pem_2048"),
        (.rsaSHA2_512, "id_rsa_pkcs8_2048"),
        (.rsaSHA2_256, "id_rsa_openssh_4096"),
    ]
    let repeatCount = max(1, Int(ProcessInfo.processInfo.environment["TAUGE_RSA_REPEAT"] ?? "1") ?? 1)
    for iteration in 0..<repeatCount {
    for (algorithm, fixture) in authenticationCases {
        await runAsync("mock.ssh \(fixture) authenticates with \(algorithm.rawValue) [\(iteration)]") {
            guard let source = parsedKeys.first(where: { $0.0 == fixture }) else {
                throw NSError(domain: "RSAKeyChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no fixture key named " + fixture])
            }
            let parsed = try SSHKeyParser.parse(path: source.2.path, rsaAlgorithm: algorithm)
            let server = MockSSHServer()
            do {
                try server.start()
            } catch {
                expect(false, "mock ssh server binds: \(error)")
                return
            }
            defer { server.stop() }

            let client = SSHClient()
            let options = SSHConnectOptions(host: "127.0.0.1",
                                            port: server.port,
                                            username: "rsauser",
                                            auth: .privateKey(parsed.key),
                                            hostKeyValidator: { _ in .trust(remember: false) },
                                            connectTimeout: .seconds(15))
            do {
                try await client.connect(options)
                let recorder = OutputRecorder()
                _ = try await client.openTerminal(term: "xterm-256color",
                                                  columns: 100,
                                                  rows: 30,
                                                  onData: { recorder.append($0) },
                                                  onClose: { _ in })
                try await waitUntil(10) { recorder.contains("mock-shell-ready") }
                expect(true, "server accepts the \(algorithm.rawValue) signature")
                await client.shutdown()
            } catch {
                expect(false, "rsa \(algorithm.rawValue) session: \(error)")
                await client.shutdown()
            }
        }
    }
    }
}
