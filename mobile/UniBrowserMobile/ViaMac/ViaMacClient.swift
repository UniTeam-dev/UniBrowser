import Foundation
import IrohLib
import Network

/// The phone's iroh endpoint and its link to the paired Mac, plus the
/// loopback SOCKS port that WKWebView's proxy setting points at.
///
/// Route: WKWebView → 127.0.0.1:47801 → one iroh stream per connection →
/// SOCKS server in UniBrowser on the Mac → the Mac's network.
actor ViaMacClient {
    enum Path: Sendable {
        case direct
        case relay
    }

    private var endpoint: Endpoint?
    private var connection: Connection?
    private var listener: NWListener?

    // MARK: - Endpoint and loopback port

    private func boundEndpoint() async throws -> Endpoint {
        if let endpoint { return endpoint }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            secretKey: ViaMacIdentity.secretKey(),
            alpns: [ViaMacProtocol.alpn]
        ))
        self.endpoint = endpoint
        return endpoint
    }

    /// Starts the loopback SOCKS port once. Connections arriving while the Mac
    /// is unreachable are dropped, so those pages fail instead of loading direct.
    func startLocalProxy(port: NWEndpoint.Port) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] local in
            Task { await self?.forward(local) }
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private func forward(_ local: NWConnection) async {
        local.start(queue: .global())
        guard let connection else {
            local.cancel()
            return
        }
        do {
            let stream = try await connection.openBi()
            try await stream.send().writeAll(buf: Data([StreamKind.socks.rawValue]))
            await StreamPipe.run(local, StreamReader(stream.recv()), stream.send())
        } catch {
            local.cancel()
        }
    }

    // MARK: - Connection to the Mac

    /// Connects to the Mac; reuses a live connection.
    func connect(macID: String, relayURL: String?) async throws -> Connection {
        if let connection, connection.closeReason() == nil { return connection }
        let endpoint = try await boundEndpoint()
        let address = EndpointAddr(id: try EndpointId.fromString(s: macID), relayUrl: relayURL, addresses: [])
        let connection = try await withTimeout(20) {
            try await endpoint.connect(addr: address, alpn: ViaMacProtocol.alpn)
        }
        self.connection = connection
        return connection
    }

    /// First contact: proves to the Mac that this phone scanned its QR code.
    func pair(with payload: PairingPayload, deviceName: String) async throws -> String {
        guard payload.expires > .now else { throw ViaMacError.pairingExpired }
        let connection = try await connect(macID: payload.macID, relayURL: payload.relayURL)
        let response = try await withTimeout(20) {
            try await ControlChannel.request(.pair(token: payload.token, deviceName: deviceName), over: connection)
        }
        guard response.ok else {
            disconnect()
            throw ViaMacError.rejected(response.error ?? "Mac отклонил сопряжение.")
        }
        return response.macName ?? payload.macName
    }

    /// Opens the live mirror stream on the current connection.
    func openSync() async throws -> SyncChannel {
        guard let connection, connection.closeReason() == nil else { throw ViaMacError.notConnected }
        return try await withTimeout(20) { try await SyncChannel.open(over: connection) }
    }

    func request(_ request: ControlRequest) async throws -> ControlResponse {
        guard let connection, connection.closeReason() == nil else { throw ViaMacError.notConnected }
        let response = try await withTimeout(20) {
            try await ControlChannel.request(request, over: connection)
        }
        guard response.ok else { throw ViaMacError.rejected(response.error ?? "Mac не выполнил запрос.") }
        return response
    }

    /// Waits until the current connection closes and returns why.
    func waitUntilClosed() async -> String {
        guard let connection else { return "нет соединения" }
        let reason = await connection.closed()
        if self.connection?.stableId() == connection.stableId() { self.connection = nil }
        return reason
    }

    /// Direct (same Wi-Fi or punched-through NAT) or via a relay server.
    func currentPath() -> Path? {
        guard let connection, connection.closeReason() == nil else { return nil }
        let selected = connection.paths().first { $0.isSelected }
        return selected?.isRelay == true ? .relay : .direct
    }

    func disconnect() {
        try? connection?.close(errorCode: 0, reason: Data("bye".utf8))
        connection = nil
    }
}
