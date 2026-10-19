import Foundation
import IrohLib
import Network

/// The phone's iroh endpoint and its link to the paired Mac, plus the
/// loopback SOCKS port that WKWebView's proxy setting points at.
///
/// Route: WKWebView → 127.0.0.1:47801 → one iroh stream per connection →
/// SOCKS server in UniBrowser on the Mac → the Mac's network.
actor ViaMacClient {
    private var endpoint: Endpoint?
    /// The relay the endpoint was bound with; nil: n0's.
    private var endpointRelay: String?
    private var connection: Connection?
    private var listener: NWListener?
    /// The connect in progress; the next one waits for it.
    private var lastConnect: Task<Connection, Error>?

    // MARK: - Endpoint and loopback port

    /// The phone's endpoint, bound with the Mac's own relay when it has one, so that
    /// Mac never depends on n0's relays; rebound when the relay changes.
    private func boundEndpoint(relay: String?) async throws -> Endpoint {
        if let endpoint, endpointRelay == relay { return endpoint }
        if let old = endpoint {
            disconnect()
            endpoint = nil
            try? await old.close()
        }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            secretKey: ViaMacIdentity.secretKey(),
            alpns: [ViaMacProtocol.alpn],
            relayMode: try relay.map { try RelayMode.customFromUrls(urls: [$0]) }
        ))
        self.endpoint = endpoint
        endpointRelay = relay
        return endpoint
    }

    /// `ip:port` for every A/AAAA record of `address` («host[:port]»), resolved now, so a
    /// home IP that changes behind a DDNS name keeps working. Empty if it doesn't resolve.
    static func resolve(_ address: String?) async -> [String] {
        guard let address, let (host, port) = ViaMacAddress.parse(address, defaultPort: ViaMacAddress.defaultPort) else { return [] }
        if ViaMacAddress.isIPLiteral(host) { return [ViaMacAddress.join(host, port)] }
        let resolved = try? await withTimeout(5) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_DGRAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [String]() }
            defer { freeaddrinfo(list) }
            var out: [String] = []
            var next = list
            while let info = next?.pointee {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.ai_addr, info.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    // A scoped (link-local) address isn't a valid iroh address.
                    if !ip.contains("%") { out.append(ViaMacAddress.join(ip, port)) }
                }
                next = info.ai_next
            }
            return out
        }
        return Array(Set(resolved ?? [])).sorted()
    }

    /// Opens the loopback SOCKS port and returns once it listens. Connections
    /// arriving while the Mac is unreachable are dropped, so those pages fail
    /// instead of loading direct. iOS defuncts a suspended app's listeners, so
    /// MacRelay closes the port on going to the background and opens it again
    /// on return; a port that fails is dropped and reopened on the next start.
    func startLocalProxy(port: NWEndpoint.Port) async throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // 127.0.0.1 only: on every interface, anyone on the phone's Wi-Fi could use the Mac's network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] local in
            Task { await self?.forward(local) }
        }
        self.listener = listener
        let once = ResumeOnce<Void>()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                once.set(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        once.resume(with: .success(()))
                    case .failed(let error), .waiting(let error):
                        once.resume(with: .failure(error))
                        Task { await self?.dropListener(listener) }
                    case .cancelled:
                        once.resume(with: .failure(CancellationError()))
                    default:
                        break
                    }
                }
                listener.start(queue: .global())
            }
        } catch {
            dropListener(listener)
            throw error
        }
    }

    func stopLocalProxy() {
        listener.map(dropListener)
    }

    private func dropListener(_ dead: NWListener) {
        dead.cancel()
        if listener === dead { listener = nil }
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

    /// Connects to the Mac; reuses a live connection to it. Calls run one after
    /// another: pairing from the QR link while the app becomes active would
    /// otherwise bind two endpoints with the same identity and race to set
    /// `connection`.
    func connect(macID: String, relayURL: String?, addresses: [String]) async throws -> Connection {
        let previous = lastConnect
        let attempt = Task {
            _ = await previous?.result
            return try await self.connectNow(macID: macID, relayURL: relayURL, addresses: addresses,
                                             ownRelay: ViaMacAddress.customRelay(relayURL))
        }
        lastConnect = attempt
        return try await attempt.value
    }

    private func connectNow(macID: String, relayURL: String?, addresses: [String], ownRelay: String?) async throws -> Connection {
        if let connection, connection.closeReason() == nil, endpointRelay == ownRelay {
            if connection.remoteId().description == macID { return connection }
            disconnect()
        }
        let endpoint = try await boundEndpoint(relay: ownRelay)
        // The Mac's own addresses go with the relay: where one is reachable (same Wi-Fi, an open
        // NAT) the link doesn't depend on the relay, which some networks throttle to a trickle.
        let address = EndpointAddr(id: try EndpointId.fromString(s: macID),
                                   relayUrl: relayURL.flatMap { ViaMacAddress.isValidRelay($0) ? $0 : nil }, addresses: addresses)
        let connection: Connection
        do {
            connection = try await withTimeout(20) {
                try await endpoint.connect(addr: address, alpn: ViaMacProtocol.alpn)
            }
        } catch ViaMacError.timeout {
            throw ViaMacError.timeout
        } catch {
            // A quick refusal may mean the Mac runs an older UniBrowser: it still speaks the old protocol.
            if let old = try? await withTimeout(10, { try await endpoint.connect(addr: address, alpn: ViaMacProtocol.legacyAlpn) }) {
                try? old.close(errorCode: 0, reason: Data("outdated".utf8))
                throw ViaMacError.outdatedMac
            }
            throw error
        }
        self.connection = connection
        return connection
    }

    /// First contact: proves to the Mac that this phone scanned its QR code.
    func pair(with payload: PairingPayload, addresses: [String], deviceName: String) async throws -> ControlResponse {
        guard payload.expires > .now else { throw ViaMacError.pairingExpired }
        let connection = try await connect(macID: payload.macID, relayURL: payload.relayURL, addresses: addresses)
        let response = try await withTimeout(20) {
            try await ControlChannel.request(.pair(token: payload.token, deviceName: deviceName), over: connection)
        }
        guard response.ok else {
            disconnect()
            throw ViaMacError.rejected(response.error ?? "Mac отклонил сопряжение.")
        }
        return response
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

    /// A round trip to the Mac over a fresh stream. An older Mac answers `ping` as an
    /// unknown request, which still proves the link; a Mac that doesn't know this
    /// phone answers with the reason and hangs up.
    func ping(path: LinkPath?, timeout: Double) async throws -> ControlResponse {
        guard let connection, connection.closeReason() == nil else { throw ViaMacError.notConnected }
        let response = try await withTimeout(timeout) { try await ControlChannel.request(.ping(path: path), over: connection) }
        if !response.ok, (try? await withTimeout(2, { await connection.closed() })) != nil {
            throw ViaMacError.rejected(response.error ?? "Mac отклонил подключение.")
        }
        return response
    }

    /// Waits until the current connection closes and returns why.
    func waitUntilClosed() async -> String {
        guard let connection else { return "нет соединения" }
        let reason = await connection.closed()
        if self.connection?.stableId() == connection.stableId() { self.connection = nil }
        return reason
    }

    /// Via a relay server, or direct: to one of `external` (the Mac's external address,
    /// resolved) or otherwise (same Wi-Fi or a punched-through NAT).
    func currentPath(external: [String]) -> LinkPath? {
        guard let connection, connection.closeReason() == nil else { return nil }
        guard let selected = connection.paths().first(where: { $0.isSelected }) else { return nil }
        if selected.isRelay { return .relay }
        return external.contains(selected.remoteAddr) ? .external : .direct
    }

    func disconnect() {
        try? connection?.close(errorCode: 0, reason: Data("bye".utf8))
        connection = nil
    }
}
