// Self-check for UniBrowser/Passwords/PasswordCSV.swift:
//   swiftc -parse-as-library UniBrowser/Passwords/PasswordCSV.swift scripts/csv_check.swift -o /tmp/csv_check && /tmp/csv_check
import Foundation

// Minimal stand-in for the app's Credential type so the parser can be checked in isolation.
struct Credential: Hashable { var host: String; var username: String; var password: String }

@main
enum CSVCheck {
    static func main() {
        // Apple Passwords export header, with quoted fields holding a comma and a newline.
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        Example,https://example.com/login,ilja,"p@ss,word","note, line1\nline2",
        Bank,bank.example,,hunter2,,
        NoPass,https://skip.example,bob,,,
        """

        let creds = PasswordCSV.credentials(from: csv)
        assert(creds.count == 2, "expected 2, got \(creds.count)")

        let example = creds.first { $0.host == "example.com" }
        assert(example?.username == "ilja", "username \(String(describing: example?.username))")
        assert(example?.password == "p@ss,word", "password \(String(describing: example?.password))")

        let bank = creds.first { $0.host == "bank.example" }  // host derived from scheme-less URL
        assert(bank?.username == "", "bank username should be empty")
        assert(bank?.password == "hunter2")

        assert(!creds.contains { $0.host == "skip.example" }, "rows without a password are skipped")

        // Column order and extra columns don't matter.
        let reordered = "password,url\nsecret,https://x.example/"
        assert(PasswordCSV.credentials(from: reordered).first?.password == "secret")

        // No usable columns → nothing.
        assert(PasswordCSV.credentials(from: "a,b\n1,2").isEmpty)

        print("CSV checks passed")
    }
}
