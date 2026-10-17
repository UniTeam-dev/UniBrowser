import Foundation

/// Imports a CSV exported from the Passwords app (Title,URL,Username,Password,Notes,…).
/// Columns are matched by header name, so the order and extra columns don't matter.
enum PasswordCSV {
    /// Parsed credentials, skipping rows without a host or password.
    static func credentials(from text: String) -> [Credential] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let lower = header.map { $0.lowercased() }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { lower.firstIndex(of: $0) }.first }
        guard let urlColumn = column(["url", "website", "address"]),
              let passwordColumn = column(["password"]) else { return [] }
        let userColumn = column(["username", "user", "login", "email"])

        return rows.dropFirst().compactMap { fields in
            guard fields.count > max(urlColumn, passwordColumn) else { return nil }
            let password = fields[passwordColumn]
            guard !password.isEmpty, let host = host(from: fields[urlColumn]) else { return nil }
            let username = userColumn.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
            return Credential(host: host, username: username, password: password)
        }
    }

    private static func host(from field: String) -> String? {
        let raw = field.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: withScheme)?.host()?.lowercased()
    }

    /// Minimal RFC 4180 parser: quoted fields may hold commas, newlines and "" escapes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
