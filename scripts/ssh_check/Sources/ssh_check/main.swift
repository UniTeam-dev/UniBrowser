// SSH checks that need Citadel. Run: swift run --package-path scripts/ssh_check
// `--live` also logs in to the test server:
//   docker compose -f scripts/ssh_check/docker-compose.yml up -d && swift run --package-path scripts/ssh_check ssh_check --live
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

@MainActor
func waitFor(_ session: SSHSession, _ what: String, _ ok: (SSHSession.State) -> Bool) async {
    for _ in 0..<400 where !ok(session.state) { try? await Task.sleep(for: .milliseconds(50)) }
    precondition(ok(session.state), "\(what): state \(session.state)")
}

@MainActor
func waitForOutput(_ out: () -> [UInt8], _ needle: [UInt8]) async {
    func found() -> Bool { let o = out(); return o.indices.contains { o[$0...].starts(with: needle) } }
    for _ in 0..<200 where !found() { try? await Task.sleep(for: .milliseconds(50)) }
    precondition(found(), "output lacks \(String(decoding: needle, as: UTF8.self)): \(String(decoding: out(), as: UTF8.self))")
}

func shell(_ args: [String]) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(filePath: "/bin/sh")
    p.arguments = ["-c"] + args
    p.standardOutput = out
    try! p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@MainActor
func checkSession() async {
    let store = KnownHostsStore(fileURL: nil)
    let server = SSHHost(address: "127.0.0.1", port: 2222, username: "test")
    func session(_ host: SSHHost = server, _ secret: SSHSecret = SSHSecret(password: "test"), route: SSHRoute = .direct) -> SSHSession {
        SSHSession(host: host, secret: secret, knownHosts: store, route: route)
    }
    precondition(SSHRoute.direct.label == "Напрямую" && SSHRoute.socks(host: "127.0.0.1", port: 1).label == "Через Mac")

    // unknown host key: prompt, trust, stored with the ssh-keygen fingerprint
    let first = session()
    await first.connect(cols: 80, rows: 24)
    guard case .hostKeyPrompt(let key, previous: nil) = first.state else { preconditionFailure("prompt: \(first.state)") }
    first.answerHostKey(trust: true)
    await waitFor(first, "trusted") { $0 == .connected }
    precondition(store.all == [key] && key.hostPort == "127.0.0.1:2222")
    let scanned = shell(["ssh-keyscan -t \(key.keyType) -p 2222 127.0.0.1 2>/dev/null | ssh-keygen -lf -"])
    precondition(scanned.contains(" \(key.fingerprintSHA256) "), "\(scanned) vs \(key.fingerprintSHA256)")
    precondition(key.publicKey.hasPrefix(key.keyType + " "))

    // password login: exec and cwd
    let hi = try! await first.exec("echo hi")
    precondition(hi == "hi\n")
    precondition(first.cwd == "/config", "cwd \(first.cwd ?? "nil")")

    // PTY: raw bytes, resize
    var out: [UInt8] = []
    first.onOutput = { out += $0 }
    first.send(Array("printf 'x\\303\\251y\\n'\n".utf8))
    await waitForOutput({ out }, [0x78, 0xC3, 0xA9, 0x79])
    first.resize(cols: 100, rows: 30)
    first.send(Array("stty size\n".utf8))
    await waitForOutput({ out }, Array("30 100".utf8))
    // a shell exiting with a non-zero status is a normal end, not a refused terminal
    first.send(Array("exit 3\n".utf8))
    await waitFor(first, "exit 3") { $0 != .connected }
    precondition(first.state == .closed, "exit 3: \(first.state)")

    // a trusted key skips the prompt; key login
    let keyed = session(SSHHost(address: "127.0.0.1", port: 2222, username: "test", auth: .key), SSHSecret(privateKey: fixture("ed25519")))
    await keyed.connect(cols: 80, rows: 24)
    precondition(keyed.state == .connected, "key login: \(keyed.state)")
    let whoami = try! await keyed.exec("whoami")
    precondition(whoami == "test\n")
    keyed.close()

    // close() during a login, then connect again: the first login's connection must not survive
    func serverSessions() -> Int {
        Int(shell(["docker exec ssh_check-ssh-1 ps ax -o args | grep -c '^sshd-session.*: test \\[priv\\]'"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
    for _ in 0..<100 where serverSessions() > 0 { try? await Task.sleep(for: .milliseconds(100)) }
    precondition(serverSessions() == 0, "sessions left before the restart check")
    let restarted = session()
    Task { await restarted.connect(cols: 80, rows: 24) }
    await Task.yield()
    precondition(restarted.state == .connecting, "restart: \(restarted.state)")
    restarted.close()
    await restarted.connect(cols: 80, rows: 24)
    precondition(restarted.state == .connected, "restart: \(restarted.state)")
    try? await Task.sleep(for: .seconds(3))
    precondition(serverSessions() == 1, "restart: \(serverSessions()) server sessions")
    restarted.close()

    // RSA keys are signed with ssh-rsa (SHA-1), which OpenSSH refuses
    let rsa = session(SSHHost(address: "127.0.0.1", port: 2222, username: "test", auth: .key), SSHSecret(privateKey: fixture("rsa")))
    await rsa.connect(cols: 80, rows: 24)
    precondition(rsa.state == .failed("Сервер отклонил RSA-ключ (подпись SHA-1). Используйте ключ ed25519"), "rsa: \(rsa.state)")

    // wrong password
    let wrong = session(server, SSHSecret(password: "nope"))
    await wrong.connect(cols: 80, rows: 24)
    precondition(wrong.state == .failed("Сервер не принял пароль или ключ"), "wrong password: \(wrong.state)")

    // closed port, unknown name
    let closedPort = session(SSHHost(address: "127.0.0.1", port: 1, username: "test"))
    await closedPort.connect(cols: 80, rows: 24)
    precondition(closedPort.state == .failed("Сервер 127.0.0.1:1 отклонил подключение") || closedPort.state == .failed("Сервер не ответил за 15 с"), "port 1: \(closedPort.state)")
    let noName = session(SSHHost(address: "no-such-host.invalid", username: "test"))
    await noName.connect(cols: 80, rows: 24)
    precondition(noName.state == .failed("Не удалось найти no-such-host.invalid"), "dns: \(noName.state)")

    // SOCKS: ssh -D against the same container; nothing listening → «Нет связи с Mac»
    let noProxy = session(route: .socks(host: "127.0.0.1", port: 1))
    await noProxy.connect(cols: 80, rows: 24)
    precondition(noProxy.state == .failed("Нет связи с Mac"), "no proxy: \(noProxy.state)")
    let proxy = Process()
    proxy.executableURL = URL(filePath: "/usr/bin/ssh")
    proxy.arguments = ["-D", "1080", "-N", "-i", fixtures.appending(path: "ed25519").path, "-p", "2222",
                       "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "test@127.0.0.1"]
    try! proxy.run()
    defer { proxy.terminate() }
    try? await Task.sleep(for: .seconds(2))
    let viaSocks = session(route: .socks(host: "127.0.0.1", port: 1080))
    await viaSocks.connect(cols: 80, rows: 24)
    precondition(viaSocks.state == .connected, "socks: \(viaSocks.state)")
    let socks = try! await viaSocks.exec("echo socks")
    precondition(socks == "socks\n")
    let listening = shell(["lsof -nP -a -p \(getpid()) -iTCP -sTCP:LISTEN"])
    precondition(listening.isEmpty, "relay still listening: \(listening)")
    viaSocks.close()

    // changed key: prompt with the previous one
    store.trust(KnownHost(hostPort: key.hostPort, keyType: key.keyType, fingerprintSHA256: "SHA256:old",
                          publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICR6Oht0ItGBTO2Nk97PrnrPNyWh2uw5ZUf5NU1vGd0k", addedAt: .now))
    let changed = session()
    await changed.connect(cols: 80, rows: 24)
    guard case .hostKeyPrompt(let current, previous: let previous?) = changed.state else { preconditionFailure("changed: \(changed.state)") }
    precondition(current.publicKey == key.publicKey && previous.fingerprintSHA256 == "SHA256:old")
    changed.answerHostKey(trust: false)
    precondition(changed.state == .closed && store.all.first?.fingerprintSHA256 == "SHA256:old")
    print("session: ok")
}

checkKeys()
if CommandLine.arguments.contains("--live") { await checkSession() }
