import Citadel
import Crypto
import Foundation
import NIO
import NIOSOCKS
import NIOSSH
import Observation

/// One SSH tab's connection: login with host-key check, the PTY shell, `exec`, SFTP and keepalive.
/// Citadel/NIO work runs off the main actor in `SSHConnection`; state and output come back here.
@MainActor
@Observable
final class SSHSession {
    enum State: Equatable {
        case idle, connecting
        /// The server's key is new (`previous` nil) or differs from the trusted one. Answer with `answerHostKey`.
        case hostKeyPrompt(KnownHost, previous: KnownHost?)
        case connected, failed(String), closed
    }

    private(set) var state: State = .idle
    private(set) var cwd: String?
    /// The shell reported `cwd` itself (OSC 7) on this connection. Before that `cwd` is only the login folder,
    /// and a `cd` would go unnoticed.
    private(set) var cwdFromShell = false
    /// Raw terminal output; may split UTF-8 sequences between calls.
    @ObservationIgnored var onOutput: (([UInt8]) -> Void)?

    @ObservationIgnored private let host: SSHHost
    @ObservationIgnored private let secret: SSHSecret
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private let route: SSHRoute
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var input: AsyncStream<PTYInput>.Continuation?
    @ObservationIgnored private var keepalive: Task<Void, Never>?
    /// In flight or done, so concurrent callers share one SFTP channel.
    @ObservationIgnored private var sftpTask: Task<SFTPClient, Error>?
    @ObservationIgnored private var size = (cols: 80, rows: 24)
    /// Bumped by every login and teardown; a login that finds it changed is stale and closes what it opened.
    @ObservationIgnored private var attempt = 0

    init(host: SSHHost, secret: SSHSecret, knownHosts: KnownHostsStore, route: SSHRoute) {
        self.host = host
        self.secret = secret
        self.knownHosts = knownHosts
        self.route = route
    }

    /// Returns once connected, failed, or waiting for `answerHostKey`.
    func connect(cols: Int, rows: Int) async {
        switch state {
        case .connecting, .connected: return
        default: break
        }
        size = (cols, rows)
        state = .connecting
        await open()
    }

    /// Trusting stores the key and logs in again: Citadel gives the whole login 10 s, too short to wait for the user.
    /// For a changed key the UI asks twice before calling this with `true`.
    func answerHostKey(trust: Bool) {
        guard case .hostKeyPrompt(let key, _) = state else { return }
        guard trust else { state = .closed; return }
        knownHosts.trust(key)
        state = .connecting
        Task { await open() }
    }

    func send(_ bytes: [UInt8]) { input?.yield(.bytes(bytes)) }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        input?.yield(.resize(cols: cols, rows: rows))
    }

    /// From OSC 7.
    func setCwd(_ path: String) {
        cwd = path
        cwdFromShell = true
    }

    /// Runs a command on its own channel; stdout only. Throws on a non-zero exit.
    func exec(_ command: String) async throws -> String {
        guard let connection else { throw SSHClientError.channelCreationFailed }
        return try await connection.exec(command)
    }

    /// Opened once per connection, on the same connection; a failed open is tried again by the next call.
    func sftp() async throws -> SFTPClient {
        guard let connection else { throw SSHClientError.channelCreationFailed }
        let task = sftpTask ?? Task { try await connection.openSFTP() }
        sftpTask = task
        do {
            return try await task.value
        } catch {
            if sftpTask == task { sftpTask = nil }
            throw error
        }
    }

    func close() {
        teardown()
        state = .closed
    }

    // MARK: - Connection

    private func open() async {
        attempt += 1
        let mine = attempt
        let check = HostKeyCheck { [weak self] key in await self?.accept(hostKey: key, attempt: mine) ?? false }
        let connection: SSHConnection
        do {
            connection = try await SSHConnection.open(host: host, secret: secret, route: route, hostKeyCheck: check)
        } catch {
            // A host-key prompt, `close()` or a newer login already set the state.
            if mine == attempt, state == .connecting { state = .failed(message(for: error)) }
            return
        }
        let cwd = (try? await connection.exec("pwd"))?.trimmingCharacters(in: .newlines)
        guard mine == attempt, state == .connecting else { connection.close(); return }
        self.connection = connection
        self.cwd = cwd
        cwdFromShell = false
        startPTY(connection)
        startKeepalive(connection)
        state = .connected
    }

    private func startPTY(_ connection: SSHConnection) {
        let (stream, continuation) = AsyncStream.makeStream(of: PTYInput.self)
        input = continuation
        let size = size
        Task { [weak self] in
            var refused = false
            do {
                try await connection.runPTY(cols: size.cols, rows: size.rows, input: stream) { [weak self] bytes in
                    await self?.deliver(bytes)
                }
            } catch {
                refused = true
            }
            // The shell exited, the server refused the PTY, or the connection dropped.
            guard let self, self.connection === connection else { return }
            if !connection.client.isConnected {
                lost()
            } else if refused {
                teardown()
                state = .failed("Сервер не открыл терминал")
            } else {
                close()
            }
        }
    }

    private func deliver(_ bytes: [UInt8]) { onOutput?(bytes) }

    /// Citadel 0.12.1 has no client keepalive: `true` every 30 s, two misses in a row drop the connection.
    private func startKeepalive(_ connection: SSHConnection) {
        keepalive = Task { [weak self] in
            var misses = 0
            while misses < 2 {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                misses = await connection.ping() ? 0 : misses + 1
            }
            guard let self, self.connection === connection else { return }
            lost()
        }
    }

    private func lost() {
        teardown()
        state = .failed("Соединение потеряно")
    }

    private func teardown() {
        attempt += 1
        keepalive?.cancel()
        keepalive = nil
        input?.finish()
        input = nil
        sftpTask = nil
        connection?.close()
        connection = nil
    }

    private var hostPort: String {
        host.address.contains(":") ? "[\(host.address)]:\(host.port)" : "\(host.address):\(host.port)"
    }

    /// `line` is "<type> <base64>". Unknown or changed keys turn into a prompt and fail this login.
    private func accept(hostKey line: String, attempt: Int) -> Bool {
        guard attempt == self.attempt, state == .connecting else { return false }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let blob = Data(base64Encoded: parts[1]) else { return false }
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let key = KnownHost(hostPort: hostPort, keyType: parts[0], fingerprintSHA256: fingerprint, publicKey: line, addedAt: .now)
        switch knownHosts.check(hostPort: hostPort, publicKey: line) {
        case .trusted: return true
        case .unknown: state = .hostKeyPrompt(key, previous: nil)
        case .changed(let previous): state = .hostKeyPrompt(key, previous: previous)
        }
        return false
    }

    private func message(for error: Error) -> String {
        switch error {
        case is NoMacLink:
            return "Нет связи с Mac"
        case let error as SSHKeyError:
            return error.errorDescription ?? "\(error)"
        case SSHClientError.allAuthenticationOptionsFailed, SSHClientError.unsupportedPrivateKeyAuthentication:
            // Citadel doesn't expose the server's methods (its only call sees NIOSSH's initial "all"), so a
            // keyboard-interactive-only server lands here too and can't get its own message.
            // Citadel 0.12.1 signs RSA only with ssh-rsa (SHA-1), which OpenSSH ≥ 8.8 refuses.
            if host.auth == .key, (try? SSHKeys.parse(secret.privateKey ?? "", passphrase: secret.passphrase))?.publicKeyType == "ssh-rsa" {
                return "Сервер отклонил RSA-ключ (подпись SHA-1). Используйте ключ ed25519"
            }
            return "Сервер не принял пароль или ключ"
        case ChannelError.connectTimeout:
            return "Сервер не ответил за 15 с"
        case let error as NIOConnectionError where error.connectionErrors.isEmpty:
            return "Не удалось найти \(host.address)"
        case let error as NIOConnectionError
            where error.connectionErrors.contains { ($0.error as? IOError)?.errnoCode == ECONNREFUSED }:
            return "Сервер \(host.address):\(host.port) отклонил подключение"
        default:
            return "Не удалось подключиться: \(error)"
        }
    }
}

private enum PTYInput: Sendable {
    case bytes([UInt8])
    case resize(cols: Int, rows: Int)
}

/// The SOCKS proxy (the paired Mac) can't be reached or can't open the target.
private struct NoMacLink: Error {}

private struct HostKeyNotTrusted: Error {}

private struct HostKeyCheck: NIOSSHClientServerAuthenticationDelegate {
    let accept: @Sendable (String) async -> Bool

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        Task {
            if await accept(line) {
                validationCompletePromise.succeed()
            } else {
                validationCompletePromise.fail(HostKeyNotTrusted())
            }
        }
    }
}

/// Citadel's `SSHClient` isn't `Sendable`; its work runs on its NIO event loop.
private final class SSHConnection: @unchecked Sendable {
    let client: SSHClient

    private init(client: SSHClient) { self.client = client }

    static func open(host: SSHHost, secret: SSHSecret, route: SSHRoute, hostKeyCheck: HostKeyCheck) async throws -> SSHConnection {
        let auth: SSHAuthenticationMethod = host.auth == .key
            ? try SSHKeys.parse(secret.privateKey ?? "", passphrase: secret.passphrase).authenticationMethod(username: host.username)
            : .passwordBased(username: host.username, password: secret.password ?? "")
        var address = host.address, port = host.port
        if case .socks(let proxyHost, let proxyPort) = route {
            port = try await socksRelay(proxyHost: proxyHost, proxyPort: proxyPort, target: host.address, targetPort: host.port)
            address = "127.0.0.1"
        }
        return SSHConnection(client: try await SSHClient.connect(
            host: address, port: port, authenticationMethod: auth, hostKeyValidator: .custom(hostKeyCheck),
            reconnect: .never, connectTimeout: .seconds(15)))
    }

    /// Citadel only adds its handlers to a channel it connects itself (`connect(on:)` touches the pipeline off
    /// the event loop), so it connects to this one-shot loopback port, which pipes through the SOCKS proxy.
    /// Any failure up to the proxy reaching the target is `NoMacLink`.
    private static func socksRelay(proxyHost: String, proxyPort: Int, target: String, targetPort: Int) async throws -> Int {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let ready = loop.makePromise(of: Void.self)
        loop.scheduleTask(in: .seconds(15)) { ready.fail(ChannelError.connectTimeout(.seconds(15))) }
        do {
            let proxy = try await ClientBootstrap(group: loop)
                .connectTimeout(.seconds(15))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            SOCKSClientHandler(targetAddress: .domain(target, port: targetPort)), SOCKSRelay(ready))
                    }
                }
                .connect(host: proxyHost, port: proxyPort).get()
            do {
                try await ready.futureResult.get()
            } catch {
                proxy.close(promise: nil)
                throw error
            }
            let listener: Channel
            do {
                listener = try await ServerBootstrap(group: loop)
                    .childChannelInitializer { child in
                        child.eventLoop.makeCompletedFuture {
                            // A second connection in the same accept loop is closed, never piped.
                            guard try proxy.pipeline.syncOperations.handler(type: SOCKSRelay.self).connect(child) else {
                                child.close(promise: nil)
                                return
                            }
                            try child.pipeline.syncOperations.addHandler(Forward(peer: proxy))
                        }
                    }
                    .bind(host: "127.0.0.1", port: 0).get()
            } catch {
                proxy.close(promise: nil)
                throw error
            }
            // Nobody came: drop both.
            loop.scheduleTask(in: .seconds(15)) { if listener.isActive { listener.close(promise: nil); proxy.close(promise: nil) } }
            return listener.localAddress?.port ?? 0
        } catch {
            throw NoMacLink()
        }
    }

    func exec(_ command: String) async throws -> String {
        String(buffer: try await client.executeCommand(command))
    }

    func openSFTP() async throws -> SFTPClient { try await client.openSFTP() }

    func close() { Task { try? await client.close() } }

    /// `true` within 10 s.
    func ping() async -> Bool {
        let (results, result) = AsyncStream.makeStream(of: Bool.self)
        Task { result.yield((try? await self.client.executeCommand("true")) != nil) }
        Task { try? await Task.sleep(for: .seconds(10)); result.yield(false) }
        for await ok in results { return ok }
        return false
    }

    /// Until the shell exits or the connection drops. Throws only if the PTY couldn't be opened:
    /// Citadel ends the stream with `CommandFailed` when the shell exits non-zero, which is a normal end.
    func runPTY(cols: Int, rows: Int, input: AsyncStream<PTYInput>, output: @escaping @Sendable ([UInt8]) async -> Void) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color", terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        var started = false
        do {
            try await client.withPTY(request) { inbound, outbound in
                started = true
                try await Self.pipe(inbound, outbound, input: input, output: output)
            }
        } catch where started {}
    }

    private static func pipe(_ inbound: TTYOutput, _ outbound: TTYStdinWriter, input: AsyncStream<PTYInput>,
                             output: @escaping @Sendable ([UInt8]) async -> Void) async throws {
        // Only wraps the NIO channel, which is thread-safe.
        nonisolated(unsafe) let writer = outbound
        let writing = Task {
            for await item in input {
                switch item {
                case .bytes(let bytes): try? await writer.write(ByteBuffer(bytes: bytes))
                case .resize(let cols, let rows): try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                }
            }
        }
        defer { writing.cancel() }
        for try await chunk in inbound {
            switch chunk {
            case .stdout(let buffer), .stderr(let buffer): await output(Array(buffer.readableBytesView))
            }
        }
    }
}

/// On the proxy channel after `SOCKSClientHandler`: completes `ready` once the proxy reached the target,
/// then holds what the server sends until `connect` gives it the relay's accepted channel.
private final class SOCKSRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let ready: EventLoopPromise<Void>
    private var peer: Channel?
    private var pending: [ByteBuffer] = []

    init(_ ready: EventLoopPromise<Void>) { self.ready = ready }

    /// False if a peer is already connected.
    func connect(_ peer: Channel) -> Bool {
        guard self.peer == nil else { return false }
        self.peer = peer
        for buffer in pending { peer.write(buffer, promise: nil) }
        peer.flush()
        pending = []
        return true
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let peer { peer.writeAndFlush(buffer, promise: nil) } else { pending.append(buffer) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SOCKSProxyEstablishedEvent { ready.succeed() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready.fail(ChannelError.ioOnClosedChannel)
        peer?.close(promise: nil)
    }
}

/// The relay's accepted side: everything goes to the proxy channel.
private final class Forward: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel

    init(peer: Channel) { self.peer = peer }

    /// One connection per relay. (Closing it from the child initializer kills the child.)
    func channelActive(context: ChannelHandlerContext) {
        context.channel.parent?.close(promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }
}
