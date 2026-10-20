import Foundation

/// The add / edit server form's fields, as typed. `build` checks them and gives the host and secret to save;
/// both apps' forms use it, so the rules and messages are the same everywhere.
struct SSHHostDraft {
    var name = ""
    var address = ""
    var port = "22"
    var username = ""
    var auth = SSHHost.Auth.password
    var viaMac = false
    var password = ""
    /// Pasted, imported or generated key text; ignored while `storedKey` is kept.
    var key = ""
    var passphrase = ""
    /// The edited host's saved key (and its passphrase), kept as it is. Nil when there is none or it is being replaced.
    var storedKey: SSHSecret?

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Throws `Invalid` with the message to show, or the key's `SSHKeyError`.
    func build(id: UUID) throws -> (host: SSHHost, secret: SSHSecret) {
        let address = address.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { throw Invalid(message: "Укажите адрес сервера.") }
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            throw Invalid(message: "Порт — число от 1 до 65535.")
        }
        guard !username.isEmpty else { throw Invalid(message: "Укажите пользователя.") }

        var secret = SSHSecret()
        if auth == .password {
            secret.password = password
        } else if let storedKey {
            secret.privateKey = storedKey.privateKey
            secret.passphrase = storedKey.passphrase
        } else {
            let pem = SSHKeys.normalized(key)
            guard !pem.isEmpty else { throw Invalid(message: "Вставьте или импортируйте приватный ключ.") }
            _ = try SSHKeys.parse(pem, passphrase: passphrase)
            secret.privateKey = pem
            if SSHKeys.isEncrypted(pem) { secret.passphrase = passphrase }
        }
        let host = SSHHost(id: id, name: name.trimmingCharacters(in: .whitespaces), address: address,
                           port: port, username: username, auth: auth, viaMac: viaMac)
        return (host, secret)
    }
}
