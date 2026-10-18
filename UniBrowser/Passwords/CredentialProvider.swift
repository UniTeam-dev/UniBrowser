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

/// Where logins live. Only one store is used at a time, so a login never ends up in both.
enum PasswordStorage: String {
    /// UniBrowser's own keychain items.
    case builtIn
    /// The Passwords app (iCloud Keychain), once Apple allowlists UniBrowser.
    case apple
}

/// Reads and saves logins in the store the user picked. With Apple Passwords
/// picked but not connected, nothing falls back to the built-in store.
@MainActor
@Observable
final class PasswordsService: CredentialProvider {
    let builtIn = KeychainCredentialProvider()
    let apple = ApplePasswordsProvider()

    var storage: PasswordStorage {
        didSet { UserDefaults.standard.set(storage.rawValue, forKey: Self.storageKey) }
    }

    private static let storageKey = "passwords.storage"

    init() {
        storage = UserDefaults.standard.string(forKey: Self.storageKey).flatMap(PasswordStorage.init) ?? .builtIn
    }

    /// macOS lets UniBrowser run the Passwords helper, so Apple Passwords can be picked.
    var isAppleAvailable: Bool {
        [.readyToPair, .awaitingPIN, .connected].contains(apple.state)
    }

    private var active: CredentialProvider {
        storage == .apple ? apple : builtIn
    }

    var displayName: String { active.displayName }

    func credentials(for host: String) async throws -> [Credential] {
        try await active.credentials(for: host)
    }

    func save(_ credential: Credential) async throws {
        try await active.save(credential)
    }
}
