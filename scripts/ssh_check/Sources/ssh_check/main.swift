// SSH checks that need Citadel. Run: swift run --package-path scripts/ssh_check
// `--live` also logs in to the test server:
//   docker compose -f scripts/ssh_check/docker-compose.yml up -d && swift run --package-path scripts/ssh_check ssh_check --live
import Citadel
import Foundation
import Logging

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

func checkPaths() {
    precondition(SFTPBrowser.join("/config", "тест папка") == "/config/тест папка")
    precondition(SFTPBrowser.join("/a/b", "../c/./d/") == "/a/c/d")
    precondition(SFTPBrowser.join("/", "..") == "/" && SFTPBrowser.join("/a", "../../..") == "/")
    precondition(SFTPBrowser.join("/a", "/x//y") == "/x/y")
    precondition(SFTPBrowser.parent("/a b/c d") == "/a b" && SFTPBrowser.parent("/a") == "/")
    precondition((try? SFTPBrowser.checked("a/b")) == nil && (try? SFTPBrowser.checked("..")) == nil && (try? SFTPBrowser.checked("")) == nil)
    precondition((try? SFTPBrowser.checked("файл 2.bin")) == "файл 2.bin")
    for (name, numbered) in [("a.txt", "a 2.txt"), ("a.tar.gz", "a 2.tar.gz"), ("B.TAR.XZ", "B 2.TAR.XZ"), ("README", "README 2"),
                             ("файл 1.bin", "файл 1 2.bin"), ("x.y.z", "x.y 2.z")] {
        precondition(TransferQueue.numbered(name, 2) == numbered, "\(name) → \(TransferQueue.numbered(name, 2))")
    }
    print("paths: ok")
}

let compose = ["docker", "compose", "-f", fixtures.deletingLastPathComponent().appending(path: "docker-compose.yml").path]

@MainActor
func waitTransfer(_ queue: TransferQueue, _ id: UUID, seconds: Int = 120, _ ok: (TransferQueue.State) -> Bool) async -> TransferQueue.Item {
    func item() -> TransferQueue.Item? { queue.items.first { $0.id == id } }
    for _ in 0..<(seconds * 20) where !(item().map { ok($0.state) } ?? false) { try? await Task.sleep(for: .milliseconds(50)) }
    guard let item = item(), ok(item.state) else { preconditionFailure("transfer \(id): \(String(describing: item()))") }
    return item
}

final class Box: @unchecked Sendable {
    var value: String
    init(_ value: String) { self.value = value }
}

@MainActor
func checkSFTP() async {
    let session = SSHSession(host: SSHHost(address: "127.0.0.1", port: 2222, username: "test"), secret: SSHSecret(password: "test"),
                             knownHosts: KnownHostsStore(fileURL: nil), route: .direct)
    func login() async {
        for _ in 0..<60 {
            await session.connect(cols: 80, rows: 24)
            if case .hostKeyPrompt = session.state { session.answerHostKey(trust: true) }
            for _ in 0..<100 where session.state == .connecting { try? await Task.sleep(for: .milliseconds(50)) }
            if session.state == .connected { return }
            try? await Task.sleep(for: .seconds(1))
        }
        preconditionFailure("login: \(session.state)")
    }
    await login()
    let home = "/config"
    _ = try! await session.exec("rm -rf '\(home)/много' '\(home)/тест папка' '\(home)/удалить' '\(home)/держать' '\(home)/ссылка' \(home)/*.txt \(home)/*.bin")

    // concurrent callers share one SFTP channel
    let clients = await withTaskGroup(of: SFTPClient.self) { group in
        for _ in 0..<2 { group.addTask { try! await session.sftp() } }
        return await group.reduce(into: []) { $0.append($1) }
    }
    precondition(clients[0] === clients[1], "two SFTP clients")

    let browser = SFTPBrowser(session: session)
    await browser.reload()
    precondition(browser.path == home && browser.followsTerminal && browser.error == nil, "start: \(browser.path) \(browser.error ?? "")")
    try! await browser.makeDirectory("тест папка")
    guard let folder = browser.entries.first(where: { $0.name == "тест папка" }) else { preconditionFailure("mkdir: \(browser.entries)") }
    precondition(folder.isDirectory && !folder.isSymlink && folder.path == "\(home)/тест папка")
    await browser.open(folder.path)
    precondition(browser.path == folder.path && !browser.followsTerminal && browser.entries.isEmpty)

    // upload 3 MB: progress reaches the total; the listing keeps the Cyrillic name and the size
    let local = FileManager.default.temporaryDirectory.appending(path: "sftp-check-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local) }
    let three = Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) })
    let upload = local.appending(path: "файл 1.bin")
    try! three.write(to: upload)
    var asked: [String] = []
    browser.transfers.upload(upload, to: browser.path) { asked.append($0); return .replace }
    let up = await waitTransfer(browser.transfers, browser.transfers.items.last!.id) { $0 == .done }
    precondition(up.bytesDone == 3_000_000 && up.bytesTotal == 3_000_000 && up.direction == .upload && asked.isEmpty, "upload: \(up)")
    await browser.reload()
    guard let uploaded = browser.entries.first(where: { $0.name == "файл 1.bin" }) else { preconditionFailure("listing: \(browser.entries)") }
    precondition(uploaded.size == 3_000_000 && !uploaded.isDirectory)

    // name clash: keep both → «файл 1 2.bin»; skip → nothing new, the item leaves the queue
    browser.transfers.upload(upload, to: browser.path) { asked.append($0); return .keepBoth }
    _ = await waitTransfer(browser.transfers, browser.transfers.items.last!.id) { $0 == .done }
    browser.transfers.upload(upload, to: browser.path) { asked.append($0); return .skip }
    let skipped = browser.transfers.items.last!.id
    for _ in 0..<100 where browser.transfers.items.contains(where: { $0.id == skipped }) { try? await Task.sleep(for: .milliseconds(50)) }
    precondition(!browser.transfers.items.contains { $0.id == skipped } && asked == ["файл 1.bin", "файл 1.bin"], "clash: \(asked)")
    await browser.reload()
    precondition(Set(browser.entries.map(\.name)) == ["файл 1.bin", "файл 1 2.bin"], "keep both: \(browser.entries.map(\.name))")
    try! await browser.delete(browser.entries.filter { $0.name == "файл 1 2.bin" })

    // rename, chmod
    try! await browser.rename(uploaded, to: "файл 2.bin")
    guard let renamed = browser.entries.first, browser.entries.count == 1, renamed.name == "файл 2.bin" else { preconditionFailure("rename: \(browser.entries)") }
    try! await browser.chmod(renamed, 0o640)
    precondition(browser.entries[0].permissions & 0o777 == 0o640, "chmod: \(String(browser.entries[0].permissions, radix: 8))")

    // download: same bytes; a second copy gets the Downloads-style name
    browser.transfers.download(renamed, to: local)
    let down = await waitTransfer(browser.transfers, browser.transfers.items.last!.id) { $0 == .done }
    precondition(try! Data(contentsOf: local.appending(path: "файл 2.bin")) == three && down.bytesDone == 3_000_000)
    browser.transfers.download(renamed, to: local)
    let again = await waitTransfer(browser.transfers, browser.transfers.items.last!.id) { $0 == .done }
    precondition(again.name == "файл 2 (1).bin" && (try! Data(contentsOf: local.appending(path: "файл 2 (1).bin"))) == three, "again: \(again)")

    // text: read, write keeps 0o640 and leaves no temp file; > 5 MB and non-UTF-8 → nil
    _ = try! await session.exec("printf 'старый\\n' > '\(home)/заметка.txt' && chmod 640 '\(home)/заметка.txt' && head -c 6291456 /dev/zero > \(home)/six.bin && printf '\\377' > \(home)/bad.txt")
    await browser.followTerminal()
    precondition(browser.path == home && browser.followsTerminal)
    let entry = { (name: String) in browser.entries.first { $0.name == name }! }
    let note = entry("заметка.txt")
    let old = try! await browser.readText(note)
    precondition(old == "старый\n", "readText: \(old ?? "nil")")
    try! await browser.writeText("новый текст\nвторая строка", to: note)
    let written = try! await browser.readText(entry("заметка.txt"))
    precondition(written == "новый текст\nвторая строка", "writeText: \(written ?? "nil")")
    precondition(entry("заметка.txt").permissions & 0o777 == 0o640, "writeText mode: \(String(entry("заметка.txt").permissions, radix: 8))")
    precondition(!browser.entries.contains { $0.name.hasSuffix(".unibrowser-tmp") })
    let six = try! await browser.readText(entry("six.bin")), bad = try! await browser.readText(entry("bad.txt"))
    precondition(six == nil && bad == nil)

    // saving a 0600 file: the temp file is 0600 from the start, the result keeps 0600, nothing is left behind
    _ = try! await session.exec("printf 'секрет\\n' > '\(home)/тайна.txt' && chmod 600 '\(home)/тайна.txt'")
    await browser.reload()
    let tempMode = Box("")
    try! await RemoteSwap.$hook.withValue({ step in
        if step == .tempWritten { tempMode.value = (try? await session.exec("stat -c %a '\(home)/тайна.txt.unibrowser-tmp'")) ?? "missing" }
    }) {
        try await browser.writeText("новый секрет\n", to: entry("тайна.txt"))
    }
    let secretMode = try! await session.exec("stat -c %a '\(home)/тайна.txt'"), secret = try! await session.exec("cat '\(home)/тайна.txt'")
    precondition(tempMode.value == "600\n" && secretMode == "600\n" && secret == "новый секрет\n", "0600 save: tmp \(tempMode.value) final \(secretMode) \(secret)")
    precondition(!browser.entries.contains { $0.name.hasPrefix("тайна.txt.") }, "leftovers: \(browser.entries.map(\.name))")

    // saving through a symlink updates the target and keeps the link
    _ = try! await session.exec("ln -s 'тайна.txt' '\(home)/ярлык.txt'")
    await browser.reload()
    try! await browser.writeText("через ссылку\n", to: entry("ярлык.txt"))
    let linkTarget = try! await session.exec("readlink '\(home)/ярлык.txt'"), viaLink = try! await session.exec("cat '\(home)/тайна.txt'")
    precondition(linkTarget == "тайна.txt\n" && viaLink == "через ссылку\n" && entry("ярлык.txt").isSymlink, "symlink save: \(linkTarget) \(viaLink)")

    // a replacing upload cancelled midway leaves the original; nothing half-written stays behind
    let large = local.appending(path: "тайна.txt")
    try! Data(count: 30_000_000).write(to: large)
    browser.transfers.upload(large, to: home) { _ in .replace }
    let replacing = browser.transfers.items.last!.id
    _ = await waitTransfer(browser.transfers, replacing) { _ in browser.transfers.items.last!.bytesDone > 1_000_000 }
    browser.transfers.cancel(replacing)
    _ = await waitTransfer(browser.transfers, replacing) { $0 == .cancelled }
    let afterCancel = try! await session.exec("cat '\(home)/тайна.txt'; ls -a \(home) | grep -c unibrowser || true")
    precondition(afterCancel == "через ссылку\n0\n", "cancelled replace: \(afterCancel)")

    // a clash waiting for an answer is held by the queue; cancelling the transfer frees the queue
    let queue = browser.transfers
    queue.upload(large, to: home) { await queue.ask($0) }
    let asking = queue.items.last!.id
    for _ in 0..<100 where queue.clash == nil { try? await Task.sleep(for: .milliseconds(50)) }
    precondition(queue.clash?.name == "тайна.txt", "no clash shown")
    queue.cancel(asking)
    _ = await waitTransfer(queue, asking) { $0 == .cancelled }
    precondition(queue.clash == nil)
    queue.upload(large, to: home) { await queue.ask($0) }
    let answered = queue.items.last!.id
    for _ in 0..<100 where queue.clash == nil { try? await Task.sleep(for: .milliseconds(50)) }
    queue.answer(.skip)
    for _ in 0..<100 where queue.items.contains(where: { $0.id == answered }) { try? await Task.sleep(for: .milliseconds(50)) }
    precondition(!queue.items.contains { $0.id == answered } && queue.clash == nil, "skip answer")

    // the connection drops after the original was moved aside: the error names the copies; the next save recovers
    var dropMessage = ""
    do {
        try await RemoteSwap.$hook.withValue({ step in
            if step == .originalMoved { _ = shell([(compose + ["stop", "-t", "1"]).joined(separator: " ")]) }
        }) {
            try await browser.writeText("после обрыва\n", to: entry("тайна.txt"))
        }
        preconditionFailure("save survived a stopped server")
    } catch {
        dropMessage = SFTPBrowser.message(for: error)
    }
    precondition(dropMessage.contains("тайна.txt.unibrowser-old"), "drop message: \(dropMessage)")
    _ = shell([(compose + ["start"]).joined(separator: " ")])
    await login()
    let leftOver = try! await session.exec("ls -a \(home) | grep тайна")
    precondition(leftOver == "тайна.txt.unibrowser-old\nтайна.txt.unibrowser-tmp\n", "after drop: \(leftOver)")
    try! await browser.writeText("после обрыва\n", to: SFTPEntry(name: "тайна.txt", path: "\(home)/тайна.txt", isDirectory: false, isSymlink: false, size: 0, permissions: 0))
    let recovered = try! await session.exec("cat '\(home)/тайна.txt'; stat -c %a '\(home)/тайна.txt'; ls -a \(home) | grep -c unibrowser || true")
    precondition(recovered == "после обрыва\n600\n0\n", "recovered: \(recovered)")
    try! await browser.delete(["тайна.txt", "ярлык.txt"].map(entry))

    // stale loads: the last folder asked for wins, though the first (300 links, one stat each) finishes later
    _ = try! await session.exec("mkdir '\(home)/много' && cd '\(home)/много' && for i in $(seq 300); do ln -s /config l$i; done")
    let slow = Task { await browser.open("\(home)/много") }
    await Task.yield() // the slow load is now waiting on the server
    await browser.open(home)
    await slow.value
    precondition(browser.path == home && !browser.entries.contains { $0.name == "l1" }, "stale load: \(browser.path)")
    _ = try! await session.exec("rm -rf '\(home)/много'")
    await browser.followTerminal()

    // hidden files behind the toggle
    precondition(!browser.entries.contains { $0.name.hasPrefix(".") })
    browser.showHidden = true
    precondition(browser.entries.contains { $0.name == ".ssh" })
    browser.showHidden = false

    // symlinks: a link to a folder opens it; deleting a folder removes a link inside it, not the link's target
    _ = try! await session.exec("ln -s '\(home)/тест папка' '\(home)/ссылка' && mkdir -p '\(home)/держать' '\(home)/удалить' && touch '\(home)/держать/цел' && ln -s '\(home)/держать' '\(home)/удалить/ссылка'")
    await browser.reload()
    let link = entry("ссылка")
    precondition(link.isSymlink && link.isDirectory, "link: \(link)")
    await browser.open(link.path)
    precondition(browser.entries.map(\.name) == ["файл 2.bin"], "via link: \(browser.entries)")
    await browser.open("..")
    precondition(browser.path == home)
    try! await browser.delete([entry("ссылка")])
    let doomed = entry("удалить")
    let doomedCount = try! await browser.countForDelete([doomed])
    precondition(doomedCount == 2, "count: \(doomedCount)")
    try! await browser.delete([doomed])
    precondition(!browser.entries.contains { $0.name == "удалить" || $0.name == "ссылка" })
    let kept = try! await session.exec("ls '\(home)/держать'"), inFolder = try! await session.exec("ls '\(home)/тест папка'")
    precondition(kept == "цел\n" && inFolder == "файл 2.bin\n", "followed a link: \(kept) \(inFolder)")

    // recursive delete with the count
    let testFolder = entry("тест папка")
    let testCount = try! await browser.countForDelete([testFolder])
    precondition(testCount == 2, "count: \(testCount)")
    try! await browser.delete([testFolder])
    precondition(!browser.entries.contains { $0.name == "тест папка" })
    let gone = try! await session.exec("ls -a '\(home)/тест папка' 2>/dev/null || echo gone")
    precondition(gone == "gone\n")
    try! await browser.delete(["держать", "заметка.txt", "six.bin", "bad.txt"].map(entry))

    // the server goes away mid-upload: the item fails; after a reconnect «Повторить» finishes it
    let big = local.appending(path: "большой файл.bin")
    try! Data(count: 50_000_000).write(to: big)
    browser.transfers.upload(big, to: home) { _ in .replace }
    let bigID = browser.transfers.items.last!.id
    _ = await waitTransfer(browser.transfers, bigID) { _ in browser.transfers.items.last!.bytesDone > 1_000_000 }
    _ = shell([(compose + ["stop", "-t", "1"]).joined(separator: " ")])
    let failed = await waitTransfer(browser.transfers, bigID) { if case .failed = $0 { true } else { false } }
    precondition(failed.bytesDone < 50_000_000, "finished before the server stopped")
    print("dropped: \(failed.state) at \(failed.bytesDone)")
    // saving in the editor while the connection is gone throws a message the editor shows («Не удалось сохранить: …»)
    do {
        try await browser.writeText("x", to: SFTPEntry(name: "a.txt", path: "\(home)/a.txt", isDirectory: false, isSymlink: false, size: 0, permissions: 0o100644))
        preconditionFailure("writeText without a connection")
    } catch {
        precondition(SFTPBrowser.message(for: error) == "нет соединения с сервером", "\(error)")
    }
    _ = shell([(compose + ["start"]).joined(separator: " ")])
    await login()
    browser.transfers.retry(bigID)
    let retried = await waitTransfer(browser.transfers, bigID, seconds: 300) { $0 == .done }
    precondition(retried.bytesDone == 50_000_000)
    let remoteSize = try! await session.exec("stat -c %s '\(home)/большой файл.bin'")
    precondition(remoteSize == "50000000\n", "retried size: \(remoteSize)")
    _ = try! await session.exec("rm -f '\(home)/большой файл.bin'")
    session.close()
    print("sftp: ok")
}

setvbuf(stdout, nil, _IONBF, 0)
// Citadel logs every SFTP request at info; the drop check makes it log errors on purpose.
LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
checkKeys()
checkPaths()
if CommandLine.arguments.contains("--live") {
    await checkSession()
    await checkSFTP()
}
