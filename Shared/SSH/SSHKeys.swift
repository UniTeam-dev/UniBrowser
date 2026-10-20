import Citadel
import Crypto
import Foundation
import NIOSSH

/// A private key ready for Citadel authentication.
enum SSHKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(Insecure.RSA.PrivateKey)

    func authenticationMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let key): .ed25519(username: username, privateKey: key)
        case .rsa(let key): .rsa(username: username, privateKey: key)
        }
    }

    var publicKeyType: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .rsa: "ssh-rsa"
        }
    }
}

enum SSHKeyError: LocalizedError, Equatable {
    case needsPassphrase, wrongPassphrase, puttyFormat, legacyPEM
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .needsPassphrase: "Ключ защищён паролем — введите парольную фразу."
        case .wrongPassphrase: "Неверная парольная фраза."
        case .puttyFormat: "Формат PuTTY (.ppk) не поддерживается. Конвертируйте ключ: ssh-keygen -p -f <файл>"
        case .legacyPEM: "Старый формат PEM не поддерживается. Конвертируйте ключ: ssh-keygen -p -f <файл>"
        case .unsupported(let type): "Тип ключа не поддерживается: \(type). Нужен ed25519 или RSA."
        }
    }
}

enum SSHKeys {
    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"

    /// Unencrypted header of an openssh-key-v1 container.
    private struct Header { let encrypted: Bool; let type: String; let publicBlob: [UInt8] }

    static func parse(_ text: String, passphrase: String?) throws -> SSHKey {
        let h = try header(text)
        guard h.type == "ssh-ed25519" || h.type == "ssh-rsa" else { throw SSHKeyError.unsupported(h.type) }
        var secret: Data?
        if h.encrypted {
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.needsPassphrase }
            secret = Data(passphrase.utf8)
        }
        do {
            return h.type == "ssh-ed25519"
                ? .ed25519(try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: secret))
                : .rsa(try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: secret))
        } catch {
            throw h.encrypted ? SSHKeyError.wrongPassphrase : SSHKeyError.unsupported(h.type)
        }
    }

    /// Pasted or imported key text: trimmed, LF line endings, one trailing newline, as the parser and server-side tools expect.
    static func normalized(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return t.isEmpty ? "" : t + "\n"
    }

    static func isEncrypted(_ text: String) -> Bool { (try? header(text).encrypted) ?? false }

    /// OpenSSH PEM of a fresh ed25519 key (no passphrase, no comment).
    static func generateEd25519() -> String { Curve25519.Signing.PrivateKey().makeSSHRepresentation() }

    /// `<type> <base64> <comment>`, same as `ssh-keygen -y` plus a comment.
    static func publicKeyLine(_ text: String, passphrase: String?, comment: String) throws -> String {
        let key = try parse(text, passphrase: passphrase)
        return "\(key.publicKeyType) \(Data(try header(text).publicBlob).base64EncodedString()) \(comment)"
    }

    private static func header(_ text: String) throws -> Header {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("PuTTY-User-Key-File") { throw SSHKeyError.puttyFormat }
        guard t.hasPrefix(begin), t.hasSuffix(end) else {
            throw t.contains("-----BEGIN ") ? SSHKeyError.legacyPEM : SSHKeyError.unsupported("?")
        }
        let b64 = t.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(b64)) else { throw SSHKeyError.unsupported("?") }
        let bytes = [UInt8](data)
        let magic = Array("openssh-key-v1\0".utf8)
        guard bytes.starts(with: magic) else { throw SSHKeyError.unsupported("?") }
        var pos = magic.count
        func string() -> [UInt8]? {
            guard pos + 4 <= bytes.count else { return nil }
            let n = bytes[pos..<pos + 4].reduce(0) { $0 << 8 | Int($1) }
            guard pos + 4 + n <= bytes.count else { return nil }
            defer { pos += 4 + n }
            return Array(bytes[pos + 4..<pos + 4 + n])
        }
        guard let cipher = string(), string() != nil, string() != nil, pos + 4 <= bytes.count else { throw SSHKeyError.unsupported("?") }
        pos += 4 // number of keys
        guard let blob = string(), blob.count >= 4 else { throw SSHKeyError.unsupported("?") }
        let n = blob[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let typeEnd = min(4 + n, blob.count)
        return Header(encrypted: cipher != Array("none".utf8), type: String(decoding: blob[4..<typeEnd], as: UTF8.self), publicBlob: blob)
    }
}
