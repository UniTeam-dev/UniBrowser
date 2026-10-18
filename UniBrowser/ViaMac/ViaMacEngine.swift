import Foundation
import IrohLib
import Network

/// The networking half of ViaMacHost: an iroh endpoint that accepts paired
/// phones and serves their SOCKS, control and sync streams.
actor ViaMacEngine {
    struct Address: Sendable {
        var id: String
        var relayURL: String?
    }

    private let host: ViaMacHost
    private var endpoint: Endpoint?
    private var connections: [String: [Connection]] = [:]
    /// One live mirror stream per phone.
    private var syncChannels: [String: SyncChannel] = [:]

    init(host: ViaMacHost) {
        self.host = host
    }

    func start(secretKey: Data) async throws -> Address {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            secretKey: secretKey,
            alpns: [ViaMacProtocol.alpn, ViaMacProtocol.legacyAlpn]
        ))
        self.endpoint = endpoint
        // Waits for the home relay so the QR can carry it; offline, the id alone is enough.
        _ = try? await withTimeout(10) { await endpoint.online() }

        Task.detached { [weak self] in
            while let incoming = await endpoint.acceptNext() {
                Task.detached { await self?.serve(incoming) }
            }
        }
        return Address(id: endpoint.id().description, relayURL: endpoint.addr().relayUrl())
    }

    func stop() async {
        for channel in syncChannels.values { await channel.close() }
        syncChannels = [:]
        for connection in connections.values.flatMap({ $0 }) {
            try? connection.close(errorCode: 0, reason: Data("stopped".utf8))
        }
        connections = [:]
        try? await endpoint?.close()
        endpoint = nil
    }

    func disconnect(deviceID: String) {
        for connection in connections[deviceID] ?? [] {
            try? connection.close(errorCode: 2, reason: Data("unpaired".utf8))
        }
        connections[deviceID] = nil
        syncChannels[deviceID] = nil
    }

    func broadcast(_ message: SyncMessage, except deviceID: String? = nil) async {
        for (id, channel) in syncChannels where id != deviceID {
            try? await channel.write(message)
        }
    }

    func send(_ message: SyncMessage, to deviceID: String) async {
        try? await syncChannels[deviceID]?.write(message)
    }

    /// Like `send`, but says whether the message went out.
    func sendChecked(_ message: SyncMessage, to deviceID: String) async -> Bool {
        guard let channel = syncChannels[deviceID] else { return false }
        return (try? await channel.write(message)) != nil
    }

    private func register(_ connection: Connection, deviceID: String) {
        connections[deviceID, default: []].append(connection)
    }

    private func unregister(_ connection: Connection, deviceID: String) -> Bool {
        connections[deviceID]?.removeAll { $0.stableId() == connection.stableId() }
        if connections[deviceID]?.isEmpty == true { connections[deviceID] = nil }
        return connections[deviceID] == nil
    }

    private func addSync(_ channel: SyncChannel, deviceID: String) {
        syncChannels[deviceID] = channel
    }

    private func removeSync(_ channel: SyncChannel, deviceID: String) -> Bool {
        guard syncChannels[deviceID] === channel else { return false }
        syncChannels[deviceID] = nil
        return true
    }

    // MARK: - Serving a phone

    private nonisolated func serve(_ incoming: Incoming) async {
        guard let connection = try? await incoming.accept().connect() else { return }
        let deviceID = connection.remoteId().description
        // An iPhone with an older UniBrowser: tell it why instead of failing to decode its messages.
        if connection.alpn() != ViaMacProtocol.alpn {
            let message = "Обновите UniBrowser на iPhone: эта версия не умеет связываться с Mac."
            // Its pairing screen shows a control reply's error; any other stream just ends.
            if let stream = try? await withTimeout(10, { try await connection.acceptBi() }) {
                let reader = StreamReader(stream.recv())
                if (try? await reader.readByte()) == StreamKind.control.rawValue {
                    _ = try? await reader.readToEnd(limit: ViaMacProtocol.maxControlMessage)
                    await ControlChannel.reply(.failure(message), on: stream.send())
                    try? await Task.sleep(for: .seconds(1)) // lets the reply arrive before the close
                }
            }
            try? connection.close(errorCode: 3, reason: Data(message.utf8))
            return
        }

        if !(await host.isPaired(deviceID)) {
            guard await Self.pair(connection, deviceID: deviceID, host: host) else {
                try? connection.close(errorCode: 1, reason: Data("not paired".utf8))
                return
            }
        }

        await register(connection, deviceID: deviceID)
        await host.deviceConnected(deviceID)
        while let stream = try? await connection.acceptBi() {
            Task.detached { await self.handle(stream, deviceID: deviceID) }
        }
        if await unregister(connection, deviceID: deviceID) {
            await host.deviceDisconnected(deviceID)
        }
    }

    /// An unknown phone gets one chance: its first stream must carry the QR's token.
    private static func pair(_ connection: Connection, deviceID: String, host: ViaMacHost) async -> Bool {
        guard let stream = try? await withTimeout(30, { try await connection.acceptBi() }) else { return false }
        let reader = StreamReader(stream.recv())
        guard (try? await reader.readByte()) == StreamKind.control.rawValue,
              let body = try? await reader.readToEnd(limit: ViaMacProtocol.maxControlMessage),
              case .pair(let token, let deviceName)? = try? JSONDecoder().decode(ControlRequest.self, from: body)
        else {
            await ControlChannel.reply(.failure("Сначала отсканируйте QR-код на Mac."), on: stream.send())
            return false
        }
        guard await host.redeem(token: token, deviceName: deviceName, deviceID: deviceID) else {
            await ControlChannel.reply(.failure("Код устарел или уже использован. Покажите на Mac новый."), on: stream.send())
            return false
        }
        await ControlChannel.reply(ControlResponse(ok: true, macName: await host.macName), on: stream.send())
        return true
    }

    private nonisolated func handle(_ stream: BiStream, deviceID: String) async {
        let reader = StreamReader(stream.recv())
        guard let kind = try? await reader.readByte() else { return }
        switch StreamKind(rawValue: kind) {
        case .socks:
            await SocksServer.serve(reader, stream.send())
        case .control:
            let response: ControlResponse
            if let body = try? await reader.readToEnd(limit: ViaMacProtocol.maxControlMessage),
               let request = try? JSONDecoder().decode(ControlRequest.self, from: body) {
                response = await Self.answer(request, host: host)
            } else {
                response = .failure("Непонятный запрос.")
            }
            await ControlChannel.reply(response, on: stream.send())
        case .sync:
            await serveSync(SyncChannel(send: stream.send(), reader: reader), deviceID: deviceID)
        case nil:
            try? await stream.send().reset(errorCode: 1)
        }
    }

    /// The live mirror: hello and the merged answer, then changes both ways
    /// until the phone goes away.
    private nonisolated func serveSync(_ channel: SyncChannel, deviceID: String) async {
        guard case .hello(let session, let base, let saved, let bookmarks)? = try? await channel.next() else { return }
        await addSync(channel, deviceID: deviceID)
        for reply in await host.hello(session: session, base: base, savedPasswords: saved, bookmarks: bookmarks, from: deviceID) {
            try? await channel.write(reply)
        }
        await host.syncStarted(deviceID)
        while let message = try? await channel.next() {
            await host.received(message, from: deviceID)
        }
        if await removeSync(channel, deviceID: deviceID) {
            await host.syncEnded(deviceID)
        }
    }

    private static func answer(_ request: ControlRequest, host: ViaMacHost) async -> ControlResponse {
        switch request {
        case .pair:
            // Already paired: the phone is just re-confirming.
            return ControlResponse(ok: true, macName: await host.macName)
        case .open(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return .failure("Можно открыть только веб-страницу.")
            }
            await host.open(url)
            return ControlResponse(ok: true)
        }
    }
}

/// A minimal SOCKS5 server (no auth, CONNECT only). Authentication already
/// happened at the iroh layer: only paired phones get this far. Host names
/// are resolved here on the Mac, so names from its local network resolve.
enum SocksServer {
    static func serve(_ reader: StreamReader, _ send: SendStream) async {
        var tcp: NWConnection?
        do {
            let greeting = try await reader.read(2)
            guard greeting[0] == 5 else { throw ViaMacError.socks(1) }
            _ = try await reader.read(Int(greeting[1]))
            try await send.writeAll(buf: Data([5, 0]))

            let request = try await reader.read(4)
            guard request[0] == 5 else { throw ViaMacError.socks(1) }
            guard request[1] == 1 else { throw ViaMacError.socks(7) }

            let target: NWEndpoint.Host
            switch request[3] {
            case 1:
                guard let address = IPv4Address(try await reader.read(4)) else { throw ViaMacError.socks(8) }
                target = .ipv4(address)
            case 3:
                let length = Int(try await reader.readByte())
                let name = String(decoding: try await reader.read(length), as: UTF8.self)
                target = .name(name, nil)
            case 4:
                guard let address = IPv6Address(try await reader.read(16)) else { throw ViaMacError.socks(8) }
                target = .ipv6(address)
            default:
                throw ViaMacError.socks(8)
            }
            let portBytes = try await reader.read(2)
            let portNumber = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
            guard let port = NWEndpoint.Port(rawValue: portNumber) else { throw ViaMacError.socks(8) }

            let connection = NWConnection(host: target, port: port, using: .tcp)
            tcp = connection
            do {
                try await connection.startAndWaitReady(timeout: 15)
            } catch {
                throw ViaMacError.socks(5)
            }
            try await send.writeAll(buf: reply(0))
            await StreamPipe.run(connection, reader, send)
        } catch {
            tcp?.cancel()
            var code: UInt8 = 1
            if case ViaMacError.socks(let socksCode) = error { code = socksCode }
            try? await send.writeAll(buf: reply(code))
            try? await send.finish()
        }
    }

    private static func reply(_ code: UInt8) -> Data {
        Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0])
    }
}
