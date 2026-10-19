// Self-check for Shared/ViaMac/ViaMacAddress.swift (external address and relay setting):
//   swiftc -parse-as-library Shared/ViaMac/ViaMacAddress.swift scripts/via_mac_address_check.swift -o /tmp/via_mac_address_check && /tmp/via_mac_address_check
import Foundation

@main
enum ViaMacAddressCheck {
    nonisolated(unsafe) static var failed = false

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failed = true }
    }

    static func parsed(_ text: String) -> String? {
        ViaMacAddress.parse(text, defaultPort: 47802).map { ViaMacAddress.join($0.host, $0.port) }
    }

    // The ping as an older app knows it, to check old and new decode each other.
    enum OldRequest: Codable { case pair(token: String, deviceName: String), ping }
    enum NewRequest: Codable { case pair(token: String, deviceName: String), ping(path: LinkPath? = nil) }

    static func main() {
        check("IPv4 without port", parsed("93.184.216.34") == "93.184.216.34:47802")
        check("IPv4 with port", parsed(" 93.184.216.34:5000 ") == "93.184.216.34:5000")
        check("name without port", parsed("home.example.net") == "home.example.net:47802")
        check("name with port, case kept lower", parsed("Home.Example.NET:47803") == "home.example.net:47803")
        check("bracketed IPv6 with port", parsed("[2001:db8::1]:5000") == "[2001:db8::1]:5000")
        check("bare IPv6", parsed("2001:db8::1") == "[2001:db8::1]:47802")
        check("empty", parsed("  ") == nil)
        check("port 0", parsed("1.2.3.4:0") == nil)
        check("port too big", parsed("1.2.3.4:70000") == nil)
        check("port not a number", parsed("host:abc") == nil)
        check("scheme rejected", parsed("http://1.2.3.4") == nil)
        check("path rejected", parsed("host/path") == nil)
        check("space inside rejected", parsed("my host") == nil)
        check("isIP literal v4", ViaMacAddress.isIPLiteral("10.0.0.1") && !ViaMacAddress.isIPLiteral("example.com"))

        check("nil relay is n0", ViaMacAddress.customRelay(nil) == nil)
        check("empty relay is n0", ViaMacAddress.customRelay(" ") == nil)
        check("n0 prod relay", ViaMacAddress.customRelay("https://euc1-1.relay.n0.iroh.link./") == nil)
        check("n0 staging relay", ViaMacAddress.customRelay("https://use1-1.staging-relay.n0.iroh.link./") == nil)
        check("own relay kept", ViaMacAddress.customRelay(" https://relay.example.ru ") == "https://relay.example.ru")
        check("look-alike host is custom", ViaMacAddress.customRelay("https://iroh.link.example.ru") == "https://iroh.link.example.ru")
        check("http dev relay", ViaMacAddress.customRelay("http://192.168.1.5:3340") == "http://192.168.1.5:3340")
        check("not a URL", ViaMacAddress.customRelay("relay.example.ru") == nil && !ViaMacAddress.isValidRelay("relay.example.ru"))
        check("bad scheme", !ViaMacAddress.isValidRelay("ftp://relay.example.ru"))
        check("valid relay", ViaMacAddress.isValidRelay("https://relay.example.ru:8443"))

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let newPing = try! encoder.encode(NewRequest.ping(path: .external))
        if case .ping? = try? decoder.decode(OldRequest.self, from: newPing) {
            check("old app reads new ping", true)
        } else {
            check("old app reads new ping", false)
        }
        let oldPing = try! encoder.encode(OldRequest.ping)
        if case .ping(let path)? = try? decoder.decode(NewRequest.self, from: oldPing) {
            check("new app reads old ping", path == nil)
        } else {
            check("new app reads old ping", false)
        }

        if failed { exit(1) }
    }
}
