// Self-check for separate logins per space (UniBrowser/Models/Space.swift):
//   swiftc -parse-as-library UniBrowser/Models/Space.swift scripts/space_logins_check.swift -o /tmp/space_logins_check && /tmp/space_logins_check
import Foundation

@main
enum SpaceLoginsCheck {
    nonisolated(unsafe) static var failed = false

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failed = true }
    }

    static func main() {
        // Store id derivation.
        let a = UUID(), b = UUID()
        let macA = Space.loginStoreID(a, mode: "mac")
        check("id is stable", macA == Space.loginStoreID(a, mode: "mac"))
        check("id differs per space", macA != Space.loginStoreID(b, mode: "mac"))
        check("id is not the space id itself", macA != a)
        check("iPhone modes never share a store",
              Space.loginStoreID(a, mode: "direct") != Space.loginStoreID(a, mode: "viaMac"))
        // Fixed vector: SHA-256("00000000-0000-0000-0000-000000000001|mac"), halves XORed.
        let fixed = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        check("id matches the documented derivation", Space.loginStoreID(fixed, mode: "mac") == reference(fixed, "mac"))

        // Migration: missing field → first space shared, the rest separate; set values stay.
        // A session saved before the field existed: today's encoding with the key taken out.
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ["A", "B", "C"].map { Space(name: $0, colorHex: "#000000") })) as! [[String: Any]]
        for i in json.indices { json[i]["separateLogins"] = nil }
        var spaces = try! JSONDecoder().decode([Space].self, from: JSONSerialization.data(withJSONObject: json))
        check("old session decodes with the field missing", spaces.allSatisfy { $0.separateLogins == nil })
        Space.migrateSeparateLogins(&spaces)
        check("migration: first shared, others separate", spaces.map(\.separateLogins) == [false, true, true])
        var set = [Space(name: "X", colorHex: "#000000", separateLogins: true), Space(name: "Y", colorHex: "#000000", separateLogins: false)]
        Space.migrateSeparateLogins(&set)
        check("migration keeps values already set", set.map(\.separateLogins) == [true, false])
        check("new spaces start separate", Space(name: "N", colorHex: "#000000").separateLogins == true)
        let roundTrip = try! JSONDecoder().decode([Space].self, from: JSONEncoder().encode(spaces))
        check("field survives encode/decode", roundTrip.map(\.separateLogins) == [false, true, true])

        exit(failed ? 1 : 0)
    }

    /// The same derivation through /usr/bin/shasum, to pin the format.
    static func reference(_ id: UUID, _ mode: String) -> UUID {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/shasum")
        p.arguments = ["-a", "256"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try! p.run()
        input.fileHandleForWriting.write(Data("\(id.uuidString)|\(mode)".utf8))
        try! input.fileHandleForWriting.close()
        p.waitUntilExit()
        let hex = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(64)
        let bytes = stride(from: 0, to: 64, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)! }
        let folded = (0..<16).map { bytes[$0] ^ bytes[$0 + 16] }
        return NSUUID(uuidBytes: folded) as UUID
    }
}
