import Foundation

/// An SSH tab's address: `unibrowser-ssh://<lowercase host id>`. Never loaded by a web view.
extension URL {
    static func ssh(_ hostID: UUID) -> URL {
        URL(string: "unibrowser-ssh://\(hostID.uuidString.lowercased())")!
    }

    /// The saved host this SSH tab opens; nil for any other URL.
    var sshHostID: UUID? {
        guard scheme == "unibrowser-ssh", let host = host() else { return nil }
        return UUID(uuidString: host)
    }
}
