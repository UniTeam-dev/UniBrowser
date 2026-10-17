import Foundation

struct Credential: Hashable, Identifiable, Sendable {
    var host: String
    var username: String
    var password: String

    var id: String { "\(host)\u{1F}\(username)" }
}

enum CredentialError: LocalizedError {
    case notConnected(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConnected(let reason): reason
        case .keychain(let status): SecCopyErrorMessageString(status, nil) as String? ?? "Ошибка связки ключей \(status)"
        }
    }
}

/// Where logins come from and go to.
@MainActor
protocol CredentialProvider: AnyObject {
    /// Shown in the UI: "Пароли" or "Связка ключей UniBrowser".
    var displayName: String { get }
    func credentials(for host: String) async throws -> [Credential]
    func save(_ credential: Credential) async throws
}

/// UniBrowser's own keychain items; in the Direct build, Apple Passwords when
/// that bridge is connected, so logins move over once Apple allows it.
@MainActor
final class PasswordsService: CredentialProvider {
    let fallback = KeychainCredentialProvider()
    #if DIRECT
    let apple = ApplePasswordsProvider()
    #endif

    private var active: CredentialProvider {
        #if DIRECT
        if apple.state == .connected { return apple }
        #endif
        return fallback
    }

    var displayName: String { active.displayName }

    func credentials(for host: String) async throws -> [Credential] {
        try await active.credentials(for: host)
    }

    func save(_ credential: Credential) async throws {
        try await active.save(credential)
    }
}
