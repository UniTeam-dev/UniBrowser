import Foundation

/// An SSH tab's address: `unibrowser-ssh://<lowercase host id>`. Never loaded by a web view.
extension URL {
    static let sshScheme = "unibrowser-ssh"

    /// True for any URL in the SSH tab scheme (case-insensitive), valid host or not. Web content, extensions and typed input must never open these.
    var isSSHScheme: Bool { scheme?.lowercased() == Self.sshScheme }

    static func ssh(_ hostID: UUID) -> URL {
        URL(string: "\(sshScheme)://\(hostID.uuidString.lowercased())")!
    }

    /// The saved host this SSH tab opens; nil for any other URL.
    var sshHostID: UUID? {
        guard isSSHScheme, let host = host() else { return nil }
        return UUID(uuidString: host)
    }
}
