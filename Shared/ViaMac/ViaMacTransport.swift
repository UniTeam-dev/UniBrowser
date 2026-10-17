import Foundation
import IrohLib
import Network
import Security

/// The device's iroh identity, kept in the Keychain so the Mac and the phone
/// recognise each other across launches.
enum ViaMacIdentity {
    private static let service = "app.unibrowser.via-mac"
    private static let account = "endpoint-secret-key"

    static func secretKey() -> Data {
        if let existing = load() { return existing }
        let key = SecretKey.generate().toBytes()
        save(key)
        return key
    }

    private static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    private static func save(_ key: Data) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
        ]
        SecItemDelete(item as CFDictionary)
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Buffered reads over an iroh receive stream, for parsing the stream-kind
/// byte and the SOCKS handshake before the raw copy starts.
final class StreamReader: @unchecked Sendable {
    // Used by one task at a time: the parser first, then StreamPipe.
    let recv: RecvStream
    private var buffer = Data()

    init(_ recv: RecvStream) {
        self.recv = recv
    }

    func read(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await recv.read(sizeLimit: 64 * 1024)
            if chunk.isEmpty { throw ViaMacError.unexpectedEnd }
            buffer.append(chunk)
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    func readByte() async throws -> UInt8 {
        try await read(1)[0]
    }

    /// The next bytes available, or nil once the peer finished the stream.
    func next() async throws -> Data? {
        if !buffer.isEmpty {
            let out = buffer
            buffer = Data()
            return out
        }
        let chunk = try await recv.read(sizeLimit: 64 * 1024)
        return chunk.isEmpty ? nil : chunk
    }

    func readToEnd(limit: UInt32) async throws -> Data {
        var out = buffer
        buffer = Data()
        out.append(try await recv.readToEnd(sizeLimit: limit))
        return out
    }
}

enum StreamPipe {
    /// Copies bytes both ways between a TCP connection and an iroh stream
    /// until both directions end, or tears both down when either side fails.
    static func run(_ tcp: NWConnection, _ reader: StreamReader, _ send: SendStream) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    while let chunk = try await tcp.receiveChunk() {
                        if !chunk.isEmpty { try await send.writeAll(buf: chunk) }
                    }
                    try await send.finish()
                    return true
                } catch {
                    try? await send.reset(errorCode: 1)
                    return false
                }
            }
            group.addTask {
                do {
                    while let chunk = try await reader.next() {
                        try await tcp.sendAsync(chunk)
                    }
                    tcp.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    return true
                } catch {
                    return false
                }
            }
            for await clean in group where !clean {
                tcp.cancel()
                try? await reader.recv.stop(errorCode: 1)
                break
            }
        }
        tcp.cancel()
    }
}

/// Sends and receives one control message on a fresh stream.
enum ControlChannel {
    static func request(_ request: ControlRequest, over connection: Connection) async throws -> ControlResponse {
        let stream = try await connection.openBi()
        var message = Data([StreamKind.control.rawValue])
        message.append(try JSONEncoder().encode(request))
        try await stream.send().writeAll(buf: message)
        try await stream.send().finish()
        let reply = try await stream.recv().readToEnd(sizeLimit: ViaMacProtocol.maxControlMessage)
        return try JSONDecoder().decode(ControlResponse.self, from: reply)
    }

    static func reply(_ response: ControlResponse, on send: SendStream) async {
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? await send.writeAll(buf: data)
        try? await send.finish()
    }
}

/// The `sync` stream: 4-byte big-endian length, then one JSON `SyncMessage`.
/// Frames go out whole and in call order; one task reads with `next()`.
/// Space pictures travel only when they change: a `session` whose pictures
/// match the last ones sent goes as `sessionKeepingImages`, and the other end
/// puts back the pictures it last received.
actor SyncChannel {
    private let send: SendStream
    nonisolated let reader: StreamReader
    /// The write in flight; the next frame waits for it so frames never interleave.
    private var lastWrite: Task<Void, Error>?
    private var sentImages: [UUID: Data]?
    private var receivedImages: [UUID: Data] = [:]

    init(send: SendStream, reader: StreamReader) {
        self.send = send
        self.reader = reader
    }

    /// Opens the stream from the phone's side.
    static func open(over connection: Connection) async throws -> SyncChannel {
        let stream = try await connection.openBi()
        let send = stream.send()
        try await send.writeAll(buf: Data([StreamKind.sync.rawValue]))
        return SyncChannel(send: send, reader: StreamReader(stream.recv()))
    }

    func write(_ message: SyncMessage) async throws {
        var message = message
        switch message {
        case .hello(let session, _, _):
            sentImages = session.spaceImages
        case .session(let session):
            let images = session.spaceImages
            if images == sentImages {
                message = .sessionKeepingImages(session.withoutImages())
            } else {
                sentImages = images
            }
        default:
            break
        }
        let body = try JSONEncoder().encode(message)
        let length = UInt32(body.count)
        var frame = Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        frame.append(body)
        let previous = lastWrite
        let write = Task { [send] in
            _ = await previous?.result
            try await send.writeAll(buf: frame)
        }
        lastWrite = write
        try await write.value
    }

    /// The next message; throws once the stream ends.
    func next() async throws -> SyncMessage {
        let header = try await reader.read(4)
        let length = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length <= ViaMacProtocol.maxSyncFrame else { throw ViaMacError.frameTooLarge }
        let message = try JSONDecoder().decode(SyncMessage.self, from: try await reader.read(Int(length)))
        switch message {
        case .hello(let session, _, _), .session(let session):
            receivedImages = session.spaceImages
            return message
        case .sessionKeepingImages(let session):
            return .session(session.withImages(receivedImages))
        default:
            return message
        }
    }

    func close() async {
        try? await send.finish()
    }
}

/// Resumes a continuation exactly once, whichever callback gets there first.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<T, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

extension NWConnection {
    /// Starts the connection and returns once it is ready.
    func startAndWaitReady(timeout seconds: Double) async throws {
        let once = ResumeOnce<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.set(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(()))
                case .failed(let error), .waiting(let error): once.resume(with: .failure(error))
                case .cancelled: once.resume(with: .failure(CancellationError()))
                default: break
                }
            }
            start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(with: .failure(ViaMacError.timeout))
            }
        }
    }

    /// The next received bytes; empty when nothing arrived yet, nil once the peer closed.
    func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// Runs `operation`, failing with `ViaMacError.timeout` if it takes longer than
/// `seconds`. iroh calls ignore task cancellation, so a late operation is left
/// to finish on its own instead of being awaited.
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        once.set(continuation)
        Task {
            do { once.resume(with: .success(try await operation())) } catch { once.resume(with: .failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(with: .failure(ViaMacError.timeout))
        }
    }
}
