// Compiles every bundled blocklist the way the apps do, in a throwaway store, so a rule
// WebKit rejects fails here and not on a user's first launch. Run from the repo root:
//   swiftc -parse-as-library scripts/blocklist_check.swift -o /tmp/blocklist_check && /tmp/blocklist_check
import Foundation
import WebKit

@main
enum BlocklistCheck {
    @MainActor static func main() async {
        let dir = URL(filePath: "Shared/Site/Blocklists")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let lists = files.filter { $0.lastPathComponent.hasPrefix("blocklist-") }.sorted { $0.path < $1.path }
        assert(!lists.isEmpty, "no blocklists in \(dir.path)")
        let temp = FileManager.default.temporaryDirectory.appending(path: "blocklist-check-\(UUID())")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let store = WKContentRuleListStore(url: temp) else { fatalError("no store") }
        for file in lists {
            let json = try! String(contentsOf: file, encoding: .utf8)
            let start = Date()
            do {
                _ = try await store.compileContentRuleList(forIdentifier: file.lastPathComponent, encodedContentRuleList: json)
                print("\(file.lastPathComponent): ok in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            } catch {
                print("\(file.lastPathComponent): \(error)")
                exit(1)
            }
        }
    }
}
