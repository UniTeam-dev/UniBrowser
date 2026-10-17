// Self-check for UniBrowser/DevTools/LineDiff.swift:
//   swiftc -parse-as-library UniBrowser/DevTools/LineDiff.swift scripts/line_diff_check.swift -o /tmp/line_diff_check && /tmp/line_diff_check
import Foundation

@main
enum LineDiffCheck {
    static func render(_ before: String, _ after: String) -> String {
        LineDiff.lines(before, after).map { line in
            (line.kind == .same ? " " : line.kind == .removed ? "-" : "+") + line.text
        }.joined(separator: "\n")
    }

    static func main() {
        let cases: [(String, String, String)] = [
            (".a {\n  color: red;\n}", ".a {\n  color: blue;\n  margin: 0;\n}", " .a {\n-  color: red;\n+  color: blue;\n+  margin: 0;\n }"),
            ("", ".b {\n}", "+.b {\n+}"),
            ("<p>x</p>", "", "-<p>x</p>"),
            ("a\nb\nc", "a\nc", " a\n-b\n c"),
        ]
        var failed = false
        for (before, after, expected) in cases {
            let ok = render(before, after) == expected
            print("\(ok ? "PASS" : "FAIL") \(before.debugDescription) → \(after.debugDescription)")
            if !ok { print(render(before, after)); failed = true }
        }
        exit(failed ? 1 : 0)
    }
}
