import Foundation

/// How an SSH tab reaches its server: straight, or through the paired Mac's SOCKS port (iPhone).
enum SSHRoute: Sendable {
    case direct
    case socks(host: String, port: Int)

    /// For the tab's status line.
    var label: String {
        switch self {
        case .direct: "Напрямую"
        case .socks: "Через Mac"
        }
    }
}
