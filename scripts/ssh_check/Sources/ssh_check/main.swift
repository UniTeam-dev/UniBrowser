// SSH checks that need Citadel. Run: swift run --package-path scripts/ssh_check
import Foundation

let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures")

func fixture(_ name: String) -> String { try! String(contentsOf: fixtures.appending(path: name), encoding: .utf8) }

func sshKeygenPublic(_ pem: String) -> String {
    let file = FileManager.default.temporaryDirectory.appending(path: "ssh-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try! pem.write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let p = Process(), out = Pipe()
    p.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
    p.arguments = ["-y", "-f", file.path]
    p.standardOutput = out
    try! p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func throwsError(_ text: String, _ pass: String?) -> SSHKeyError? {
    do { _ = try SSHKeys.parse(text, passphrase: pass); return nil } catch { return error as? SSHKeyError }
}

func checkKeys() {
    precondition(try! SSHKeys.parse(fixture("ed25519"), passphrase: nil).publicKeyType == "ssh-ed25519")
    precondition(try! SSHKeys.parse(fixture("rsa"), passphrase: nil).publicKeyType == "ssh-rsa")
    precondition(!SSHKeys.isEncrypted(fixture("ed25519")))
    precondition(SSHKeys.isEncrypted(fixture("ed25519_enc")))
    precondition(throwsError(fixture("ed25519_enc"), nil) == .needsPassphrase)
    precondition(throwsError(fixture("ed25519_enc"), "bad") == .wrongPassphrase)
    precondition(try! SSHKeys.parse(fixture("ed25519_enc"), passphrase: "test").publicKeyType == "ssh-ed25519")
    precondition(throwsError(fixture("key.ppk"), nil) == .puttyFormat)
    precondition(throwsError(fixture("rsa_legacy.pem"), nil) == .legacyPEM)
    precondition(throwsError(fixture("ecdsa"), nil) == .unsupported("ecdsa-sha2-nistp256"))
    precondition(throwsError("garbage", nil) == .unsupported("?"))

    // public key line equals ssh-keygen -y (+ comment), for fixtures and a generated key
    for name in ["ed25519", "rsa"] {
        let pem = fixture(name)
        let line = try! SSHKeys.publicKeyLine(pem, passphrase: nil, comment: "me@mac")
        precondition(line == sshKeygenPublic(pem).split(separator: " ").prefix(2).joined(separator: " ") + " me@mac", name)
    }
    let enc = try! SSHKeys.publicKeyLine(fixture("ed25519_enc"), passphrase: "test", comment: "c")
    precondition(enc.hasPrefix("ssh-ed25519 ") && enc.hasSuffix(" c"))

    let generated = SSHKeys.generateEd25519()
    precondition(!SSHKeys.isEncrypted(generated))
    let line = try! SSHKeys.publicKeyLine(generated, passphrase: nil, comment: "gen")
    precondition(line == sshKeygenPublic(generated).split(separator: " ").prefix(2).joined(separator: " ") + " gen")
    precondition(SSHKeys.generateEd25519() != generated)
    print("keys: ok")
}

checkKeys()
