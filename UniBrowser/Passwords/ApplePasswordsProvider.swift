import Foundation
import Observation

/// Bridge to the macOS Passwords app (iCloud Keychain).
///
/// macOS has no public API for a third-party browser to read or save website
/// passwords. The only route Apple ships is the system helper
/// `PasswordManagerBrowserExtensionHelper`, which the "iCloud Passwords"
/// extension in Chrome, Edge and Firefox talks to over native messaging. Since
/// macOS 15.4 the helper checks the signing identity of the browser that
/// launched it against an allowlist Apple builds from
/// github.com/apple/password-manager-resources
/// (quirks/web-browser-extension-distribution-information.json).
///
/// So this provider works in two stages:
/// 1. `probe()` launches the helper and reports whether it accepts UniBrowser.
/// 2. Once it does, the session (PIN pairing, then get/save requests) runs over
///    `HelperChannel`. That message layer is not written yet; see docs/passwords.md.
@MainActor
@Observable
final class ApplePasswordsProvider: CredentialProvider {
    enum State: Equatable {
        case unknown
        /// The helper binary is not on this Mac (macOS older than 14).
        case helperMissing
        /// The helper started and exited at once: UniBrowser is not on Apple's allowlist yet.
        case notAllowlisted
        /// The helper accepted the connection; pairing is the next step.
        case helperAccepted
        /// Paired with the Passwords app; reads and saves go here.
        case connected
    }

    private(set) var state: State = .unknown

    var displayName: String { "Пароли" }

    func probe() async {
        guard FileManager.default.isExecutableFile(atPath: HelperChannel.helperURL.path) else {
            state = .helperMissing
            return
        }
        let channel = HelperChannel()
        do {
            try channel.start()
            // A refused browser is killed by the helper's launch check almost immediately.
            try await Task.sleep(for: .seconds(1))
            state = channel.isRunning ? .helperAccepted : .notAllowlisted
        } catch {
            state = .notAllowlisted
        }
        channel.stop()
    }

    func credentials(for host: String) async throws -> [Credential] {
        throw CredentialError.notConnected("UniBrowser пока не подключён к приложению «Пароли»")
    }

    func save(_ credential: Credential) async throws {
        throw CredentialError.notConnected("UniBrowser пока не подключён к приложению «Пароли»")
    }
}

/// Native-messaging transport to the Passwords helper: the helper runs as our
/// child process and exchanges JSON messages, each prefixed with its length as
/// a 32-bit little-endian integer, over stdin and stdout.
@MainActor
final class HelperChannel {
    static let helperURL = URL(filePath:
        "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
    )
    /// Origin of Apple's iCloud Passwords extension in the Chrome Web Store;
    /// browsers pass the calling extension's origin as the first argument.
    static let extensionOrigin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var onMessage: (([String: Any]) -> Void)?

    var isRunning: Bool { process.isRunning }

    func start(onMessage: (([String: Any]) -> Void)? = nil) throws {
        self.onMessage = onMessage
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
        try process.run()
    }

    func send(_ message: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func received(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                onMessage?(message)
            }
        }
    }
}
