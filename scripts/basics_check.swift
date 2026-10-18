// Self-check for Shared/Basics (download file names, zoom steps and per-site memory):
//   swiftc -parse-as-library Shared/Basics/PageZoom.swift Shared/Basics/Downloads.swift scripts/basics_check.swift -o /tmp/basics_check && /tmp/basics_check
import Foundation

@main
enum BasicsCheck {
    static func main() {
        // Unique download names.
        let dir = URL(filePath: "/tmp/dl", directoryHint: .isDirectory)
        func name(_ suggested: String, taken: [String] = []) -> String {
            Downloads.uniqueFileURL(in: dir, suggested: suggested) { taken.contains($0.lastPathComponent) }.lastPathComponent
        }
        precondition(name("report.pdf") == "report.pdf")
        precondition(name("report.pdf", taken: ["report.pdf"]) == "report (1).pdf")
        precondition(name("report.pdf", taken: ["report.pdf", "report (1).pdf"]) == "report (2).pdf")
        precondition(name("README", taken: ["README"]) == "README (1)")
        precondition(name("src.tar.gz", taken: ["src.tar.gz"]) == "src (1).tar.gz")
        precondition(name("my.notes.txt", taken: ["my.notes.txt"]) == "my.notes (1).txt")
        precondition(name("../../etc/passwd") == "_.._etc_passwd")
        precondition(name(".bashrc") == "bashrc")
        precondition(name("") == "download")
        precondition(name("a:b.txt") == "a_b.txt")
        precondition(Downloads.uniqueFileURL(in: dir, suggested: "x.zip") { _ in false }.deletingLastPathComponent().path == "/tmp/dl")

        // Zoom steps.
        precondition(PageZoom.step(from: 1, up: true) == 1.1)
        precondition(PageZoom.step(from: 1, up: false) == 0.85)
        precondition(PageZoom.step(from: 3, up: true) == 3)
        precondition(PageZoom.step(from: 0.5, up: false) == 0.5)
        precondition(PageZoom.step(from: 1.2, up: true) == 1.25) // off-grid (pinch) snaps to the next step
        precondition(PageZoom.step(from: 1.2, up: false) == 1.1)
        precondition(PageZoom.label(1.1) == "110\u{00A0}%")
        precondition(PageZoom.label(0.85) == "85\u{00A0}%")

        // Per-site memory.
        let defaults = UserDefaults(suiteName: "basics_check")!
        defaults.removePersistentDomain(forName: "basics_check")
        precondition(PageZoom.level(for: "a.ru", in: defaults) == 1)
        PageZoom.setLevel(1.25, for: "a.ru", in: defaults)
        precondition(PageZoom.level(for: "a.ru", in: defaults) == 1.25)
        precondition(PageZoom.level(for: "b.ru", in: defaults) == 1)
        precondition(PageZoom.level(for: nil, in: defaults) == 1)
        PageZoom.setLevel(1, for: "a.ru", in: defaults)
        precondition(defaults.dictionary(forKey: "pageZoomByHost")?["a.ru"] == nil, "100 % forgets the site")
        defaults.removePersistentDomain(forName: "basics_check")

        print("basics_check: OK")
    }
}
