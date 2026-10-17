// Direct (Developer ID) build only: launches a system helper, which App Sandbox and App Review rule out.
#if DIRECT
import BigInt
import Foundation
import Observation

enum PasswordsBridgeError: LocalizedError {
    case helperMissing
    case notAllowlisted
    case notPaired
    case wrongPIN
    case timeout
    case status(Int)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing: "На этом Mac нет помощника «Паролей» (нужна macOS 14 или новее)"
        case .notAllowlisted: "macOS пока не разрешает UniBrowser подключаться к «Паролям»"
        case .notPaired: "UniBrowser не подключён к «Паролям»: введите код"
        case .wrongPIN: "Неверный код"
        case .timeout: "«Пароли» не ответили"
        case .status(let code): "«Пароли» вернули ошибку \(code)"
        case .protocolError(let detail): "Ошибка обмена с «Паролями»: \(detail)"
        }
    }
}

/// Bridge to the macOS Passwords app (iCloud Keychain).
///
/// macOS has no public API for a third-party browser to read or save website
/// passwords. The only route is the system helper
/// `PasswordManagerBrowserExtensionHelper`, which the "iCloud Passwords"
/// extension in Chrome, Edge and Firefox talks to over native messaging. The
/// helper has a launch constraint: its parent must be a notarized browser on
/// Apple's allowlist (built from github.com/apple/password-manager-resources),
/// otherwise macOS kills it at once. See docs/passwords.md.
///
/// Session: pair once per app launch with the 6-digit PIN the Passwords app
/// shows (SRP), then send AES-GCM encrypted get/save commands.
@MainActor
@Observable
final class ApplePasswordsProvider: CredentialProvider {
    enum State: Equatable {
        case unknown
        /// The helper binary is not on this Mac (macOS older than 14).
        case helperMissing
        /// macOS killed the helper: UniBrowser is not on Apple's allowlist yet.
        case notAllowlisted
        /// The helper runs; pairing with a PIN is the next step.
        case readyToPair
        /// A PIN is showing in the Passwords dialog; waiting for the user to type it.
        case awaitingPIN
        /// Paired; reads and saves go to the Passwords app.
        case connected
    }

    private(set) var state: State = .unknown
    private(set) var lastError: String?

    @ObservationIgnored private var channel: HelperChannel?
    @ObservationIgnored private var srp = PasswordsSRP()

    private static let protocolVersion = "1.0"
    private static let browserName = "UniBrowser"

    var displayName: String { "Пароли" }

    // MARK: - Connection

    /// Starts the helper and checks that macOS lets it run under UniBrowser.
    func probe() async {
        guard FileManager.default.isExecutableFile(atPath: HelperChannel.helperURL.path) else {
            state = .helperMissing
            return
        }
        let channel = HelperChannel()
        do {
            try channel.start()
            // A refused parent gets the helper killed by the kernel almost immediately.
            try await Task.sleep(for: .seconds(1))
        } catch {}
        if channel.isRunning {
            self.channel = channel
            state = .readyToPair
        } else {
            channel.stop()
            state = .notAllowlisted
        }
    }

    /// Asks the helper for a challenge; the Passwords app then shows a PIN.
    func beginPairing() async {
        lastError = nil
        if channel?.isRunning != true { await probe() }
        guard let channel, state == .readyToPair || state == .awaitingPIN || state == .connected else { return }

        srp = PasswordsSRP()
        let pake: [String: Any] = [
            "TID": srp.username,
            "MSG": 0,
            "A": srp.A.serialize().base64EncodedString(),
            "VER": Self.protocolVersion,
            "PROTO": [1],
        ]
        do {
            let reply = try await channel.request([
                "cmd": 2,
                "msg": ["QID": "m0", "PAKE": try Self.encodePAKE(pake), "HSTBRSR": Self.browserName],
            ])
            let server = try decodePAKE(reply)
            guard "\(server["MSG"] ?? "")" == "1" else { throw PasswordsBridgeError.protocolError("неожиданный ответ") }
            if let code = server["ErrCode"] { throw PasswordsBridgeError.protocolError("код \(code)") }
            guard let b64B = server["B"] as? String, let b64s = server["s"] as? String,
                  let B = Data(base64Encoded: b64B), let s = Data(base64Encoded: b64s)
            else { throw PasswordsBridgeError.protocolError("нет ключа в ответе") }
            try srp.setServerValues(B: BigUInt(B), salt: BigUInt(s))
            state = .awaitingPIN
        } catch {
            lastError = error.localizedDescription
            state = channel.isRunning ? .readyToPair : .notAllowlisted
        }
    }

    /// Finishes pairing with the PIN the user read from the Passwords dialog.
    func submitPIN(_ pin: String) async {
        guard let channel, state == .awaitingPIN else { return }
        lastError = nil
        do {
            let M = try srp.proof(pin: pin)
            let reply = try await channel.request([
                "cmd": 2,
                "msg": [
                    "QID": "m2",
                    "HSTBRSR": Self.browserName,
                    "PAKE": try Self.encodePAKE(["TID": srp.username, "MSG": 2, "M": M.base64EncodedString()]),
                ],
            ])
            let server = try decodePAKE(reply)
            guard "\(server["MSG"] ?? "")" == "3" else { throw PasswordsBridgeError.protocolError("неожиданный ответ") }
            switch "\(server["ErrCode"] ?? "0")" {
            case "0": break
            case "1": throw PasswordsBridgeError.wrongPIN
            case let code: throw PasswordsBridgeError.protocolError("код \(code)")
            }
            guard let hamk = (server["HAMK"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let expected = srp.expectedServerProof(for: M),
                  BigUInt(hamk) == BigUInt(expected)
            else { throw PasswordsBridgeError.protocolError("помощник не подтвердил ключ") }
            state = .connected
        } catch {
            let message = error.localizedDescription
            // The helper issues a new code per attempt: request one and keep the sheet up.
            if case PasswordsBridgeError.wrongPIN = error {
                await beginPairing()
            } else {
                state = .readyToPair
            }
            lastError = message
        }
    }

    func cancelPairing() {
        if state == .awaitingPIN { state = .readyToPair }
    }

    // MARK: - CredentialProvider

    func credentials(for host: String) async throws -> [Credential] {
        let data = try await secureRequest(
            cmd: 5,
            qid: "CmdGetPassword4LoginName",
            url: host,
            body: ["ACT": 2, "URL": host, "USR": ""]
        )
        return try Self.entries(from: data).compactMap { entry in
            guard let username = entry["USR"] as? String,
                  let password = entry["PWD"] as? String
            else { return nil }
            return Credential(host: host, username: username, password: password)
        }
    }

    func save(_ credential: Credential) async throws {
        let data = try await secureRequest(
            cmd: 6,
            qid: "CmdSetPassword4LoginName_URL",
            url: nil,
            body: [
                "ACT": 4, "URL": "", "USR": "", "PWD": "",
                "NURL": credential.host, "NUSR": credential.username, "NPWD": credential.password,
            ]
        )
        let status = data["STATUS"] as? Int ?? 0
        guard status == 0 else { throw PasswordsBridgeError.status(status) }
    }

    // MARK: - Wire

    private func secureRequest(cmd: Int, qid: String, url: String?, body: [String: Any]) async throws -> [String: Any] {
        guard state == .connected, let channel else { throw PasswordsBridgeError.notPaired }
        let sdata = try srp.encrypt(body).base64EncodedString()
        let payload = try JSONSerialization.data(withJSONObject: [
            "QID": qid,
            "SMSG": ["TID": srp.username, "SDATA": sdata],
        ])
        var message: [String: Any] = [
            "cmd": cmd, "tabId": 0, "frameId": 0,
            "payload": String(decoding: payload, as: UTF8.self),
        ]
        if let url { message["url"] = url }

        let reply: [String: Any]
        do {
            reply = try await channel.request(message)
        } catch {
            if !channel.isRunning { state = .readyToPair; self.channel = nil }
            throw error
        }
        guard let replyPayload = reply["payload"] as? [String: Any] else {
            throw PasswordsBridgeError.protocolError("нет данных")
        }
        var smsg = replyPayload["SMSG"]
        if let text = smsg as? String {
            smsg = try JSONSerialization.jsonObject(with: Data(text.utf8))
        }
        guard let smsg = smsg as? [String: Any],
              smsg["TID"] as? String == srp.username,
              let sdataReply = (smsg["SDATA"] as? String).flatMap({ Data(base64Encoded: $0) })
        else {
            // The helper forgot us (for example after sleep): pair again.
            state = .readyToPair
            throw PasswordsBridgeError.notPaired
        }
        return try srp.decrypt(sdataReply)
    }

    private func decodePAKE(_ reply: [String: Any]) throws -> [String: Any] {
        guard let payload = reply["payload"] as? [String: Any],
              let pake = payload["PAKE"] as? String,
              let data = Data(base64Encoded: pake),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PasswordsBridgeError.protocolError("нет PAKE в ответе") }
        guard object["TID"] as? String == srp.username else {
            throw PasswordsBridgeError.protocolError("ответ для другой сессии")
        }
        return object
    }

    private static func encodePAKE(_ object: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }

    /// Entries come as an `Entries` array or as `Entry_0` … `Entry_n` keys.
    /// Status 3 means "nothing saved for this site".
    private static func entries(from data: [String: Any]) throws -> [[String: Any]] {
        let status = data["STATUS"] as? Int ?? 100
        if status == 3 { return [] }
        guard status == 0 else { throw PasswordsBridgeError.status(status) }
        if let list = data["Entries"] as? [[String: Any]] { return list }
        return data
            .filter { $0.key.hasPrefix("Entry_") }
            .sorted { (Int($0.key.dropFirst(6)) ?? 0) < (Int($1.key.dropFirst(6)) ?? 0) }
            .compactMap { $0.value as? [String: Any] }
    }
}

/// Native-messaging transport to the Passwords helper: the helper runs as our
/// child process and exchanges JSON messages, each prefixed with its length as
/// a 32-bit little-endian integer, over stdin and stdout. One request at a time.
@MainActor
final class HelperChannel {
    static let helperURL = URL(filePath:
        "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
    )
    /// Origin of Apple's iCloud Passwords extension; browsers pass the calling
    /// extension's origin as the first argument.
    static let extensionOrigin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var pending: CheckedContinuation<[String: Any], Error>?
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var busy = false

    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.executableURL = Self.helperURL
        process.arguments = [Self.extensionOrigin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            Task { @MainActor in self.received(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.fail(PasswordsBridgeError.notAllowlisted) }
        }
        try process.run()
    }

    func request(_ message: [String: Any], timeout: Duration = .seconds(30)) async throws -> [String: Any] {
        // Serialize requests: the helper answers in order and replies carry no request id.
        if busy { await withCheckedContinuation { queue.append($0) } }
        busy = true
        defer {
            busy = false
            if !queue.isEmpty { queue.removeFirst().resume() }
        }

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.fail(PasswordsBridgeError.timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            do {
                try send(message)
            } catch {
                pending = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        fail(PasswordsBridgeError.timeout)
    }

    private func send(_ message: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    private func fail(_ error: Error) {
        pending?.resume(throwing: error)
        pending = nil
    }

    private func received(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            // The helper also pushes unsolicited events (state changes); only a reply resolves a request.
            if message["payload"] != nil || message["error"] != nil {
                if let error = message["error"] {
                    fail(PasswordsBridgeError.protocolError("\(error)"))
                } else {
                    // Caller and reader are both @MainActor; the dictionary never crosses threads.
                    nonisolated(unsafe) let reply = message
                    pending?.resume(returning: reply)
                    pending = nil
                }
            }
        }
    }
}
#endif
