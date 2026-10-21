import Foundation

extension URLProtectionSpace {
    /// Basic, Digest and NTLM: the ones that need a login dialog (server trust and client certificates don't).
    var isHTTPAuth: Bool {
        [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
            .contains(authenticationMethod)
    }

    /// The dialog's text: the site, the server's realm and a note after a wrong password.
    func loginPrompt(failed: Bool) -> String {
        var lines = ["\(`protocol` ?? "https")://\(host)" + ([80, 443].contains(port) ? "" : ":\(port)")]
        if let realm, !realm.isEmpty { lines.append(realm) }
        if failed { lines.append("Неверное имя пользователя или пароль.") }
        if receivesCredentialSecurely == false { lines.append("Соединение не защищено: пароль уйдёт открытым текстом.") }
        return lines.joined(separator: "\n")
    }
}
