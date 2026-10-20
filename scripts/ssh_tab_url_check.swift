// Self-check for Shared/SSH/SSHTabURL.swift:
//   swiftc -parse-as-library Shared/SSH/SSHTabURL.swift scripts/ssh_tab_url_check.swift -o /tmp/ssh_tab_url_check && /tmp/ssh_tab_url_check
import Foundation

@main
enum SSHTabURLCheck {
    static func main() {
        let id = UUID()
        let url = URL.ssh(id)
        precondition(url.scheme == "unibrowser-ssh", "scheme")
        precondition(url.absoluteString == "unibrowser-ssh://\(id.uuidString.lowercased())", "host is the lowercase id")
        precondition(url.sshHostID == id, "round trip")
        precondition(URL(string: "unibrowser-ssh://\(id.uuidString.uppercased())")!.sshHostID == id, "uppercase id parses")
        precondition(URL(string: "https://x")!.sshHostID == nil, "web URL is not SSH")
        precondition(URL(string: "https://\(id.uuidString)")!.sshHostID == nil, "id under another scheme is not SSH")
        precondition(URL(string: "unibrowser-ssh://not-a-uuid")!.sshHostID == nil, "malformed host")
        precondition(URL(string: "unibrowser-ssh:")!.sshHostID == nil, "no host")
        print("ssh tab url: ok")
    }
}
