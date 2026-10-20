// Self-check for Shared/SSH/CommandLineModel.swift and Shared/SSH/CommandHistory.swift:
//   swiftc -parse-as-library Shared/SSH/CommandLineModel.swift Shared/SSH/CommandHistory.swift scripts/command_line_check.swift -o /tmp/command_line_check && /tmp/command_line_check
import Foundation

@main
@MainActor
enum CommandLineCheck {
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Typed and echoed back like a shell would.
    static func type(_ s: String, into m: inout CommandLineModel) -> [String] {
        let saved = m.typed(bytes(s))
        m.echoed(bytes(s))
        return saved
    }

    static func main() async {
        // printable input, echo, words
        var m = CommandLineModel()
        precondition(m.line == "" && !m.showsSuggestions, "starts empty, nothing to suggest")
        _ = type("ls -l", into: &m)
        precondition(m.line == "ls -l", "line: \(m.line ?? "nil")")
        precondition(m.currentWord == ("-l", false), "word: \(m.currentWord)")
        precondition(m.showsSuggestions, "echoed line shows suggestions")
        _ = type(" ", into: &m)
        precondition(m.currentWord == ("", false), "after a space: \(m.currentWord)")

        // backspace removes one character, multi-byte too; echo of the erase ("\b \b" or "\b\e[K") is fine
        m = CommandLineModel()
        _ = type("lé", into: &m)
        _ = m.typed([0x7F])
        m.echoed(bytes("\u{8} \u{8}"))
        precondition(m.line == "l" && m.showsSuggestions, "backspace: \(m.line ?? "nil")")
        _ = m.typed([0x08])
        m.echoed(bytes("\u{8}\u{1B}[K"))
        precondition(m.line == "", "^H: \(m.line ?? "nil")")
        // typing ahead of the echo: "a", erase, "b" echoed in one chunk
        _ = m.typed(bytes("a")); _ = m.typed([0x7F]); _ = m.typed(bytes("b"))
        precondition(!m.showsSuggestions, "nothing echoed yet")
        m.echoed(bytes("a\u{8} \u{8}b"))
        precondition(m.line == "b" && m.showsSuggestions, "type-ahead echo: \(m.line ?? "nil") \(m.showsSuggestions)")

        // first word, also after | ; &&
        m = CommandLineModel()
        _ = type("gi", into: &m)
        precondition(m.currentWord == ("gi", true), "first: \(m.currentWord)")
        _ = type("t log | gr", into: &m)
        precondition(m.currentWord == ("gr", true), "after pipe: \(m.currentWord)")
        _ = type("ep x; l", into: &m)
        precondition(m.currentWord == ("l", true), "after ;: \(m.currentWord)")
        _ = type("s \"a b|c", into: &m)
        precondition(m.currentWord == ("\"a b|c", false), "quoted | and space stay in the word: \(m.currentWord)")

        // cursor keys and other control input: unknown until Enter
        m = CommandLineModel()
        _ = type("ls", into: &m)
        _ = m.typed([0x1B, 0x5B, 0x44])
        precondition(m.line == nil && !m.showsSuggestions, "ESC [ D: \(m.line ?? "nil")")
        _ = m.typed(bytes("x"))
        precondition(m.line == nil, "stays unknown")
        precondition(m.typed(bytes("\r")) == [] && m.line == "", "Enter resets; an unknown line is not saved")
        _ = m.typed([0x09])
        precondition(m.line == nil, "Tab: unknown")
        _ = m.typed([0x03])
        precondition(m.line == "", "^C resets")
        _ = m.typed(bytes("echo a\nb"))
        precondition(m.line == nil, "paste with a newline: unknown")
        _ = m.typed([0x04])
        precondition(m.line == "", "^D resets")

        // Enter saves an echoed line
        m = CommandLineModel()
        _ = type("git status", into: &m)
        precondition(m.typed(bytes("\r")) == ["git status"], "saved on Enter")
        precondition(m.line == "", "reset after Enter")

        // no echo (password prompt): no suggestions, not saved
        m = CommandLineModel()
        _ = type("sudo ls", into: &m)
        precondition(m.typed(bytes("\r")) == ["sudo ls"], "the command itself is saved")
        m.echoed(bytes("\r\n[sudo] password for test: "))
        _ = m.typed(bytes("secret"))
        precondition(m.line == "secret" && !m.showsSuggestions, "not echoed: hidden")
        precondition(m.typed(bytes("\r")) == [], "password not saved")
        // typed ahead of the prompt: the prompt arrives instead of the echo
        _ = type("sudo -k; sudo ls", into: &m)
        _ = m.typed(bytes("\r"))
        _ = m.typed(bytes("hunter2"))
        m.echoed(bytes("\r\n[sudo] password for test: "))
        precondition(!m.showsSuggestions, "echo mismatch: hidden")
        m.echoed(bytes("hunter2"))
        precondition(!m.showsSuggestions, "echo stays off until Enter")
        precondition(m.typed(bytes("\r")) == [], "mismatched line not saved")
        _ = type("ls", into: &m)
        precondition(m.showsSuggestions, "echo on again after Enter")

        // leading space: not saved
        m = CommandLineModel()
        _ = type(" export TOKEN=x", into: &m)
        precondition(m.typed(bytes("\r")) == [], "leading space not saved")
        _ = type("   ", into: &m)
        precondition(m.typed(bytes("\r")) == [], "blank line not saved")

        // alternate screen
        m = CommandLineModel()
        _ = type("ls", into: &m)
        m.isAlternateScreen = true
        precondition(!m.showsSuggestions, "alternate screen hides")
        m.isAlternateScreen = false
        precondition(m.showsSuggestions, "back on the main screen")

        // accepting a suggestion; its echo is expected like typed input
        m = CommandLineModel()
        _ = type("ls ~/.bash", into: &m)
        m.accepted("rc")
        precondition(m.line == "ls ~/.bashrc", "accepted: \(m.line ?? "nil")")
        precondition(!m.showsSuggestions, "waits for the echo of the suffix")
        m.echoed(bytes("rc"))
        precondition(m.showsSuggestions && m.currentWord == ("~/.bashrc", false), "accepted echo: \(m.currentWord)")

        // quoting
        precondition(CommandLineModel.unquoted("\"тест п")! == ("тест п", "\""), "double")
        precondition(CommandLineModel.unquoted("тест\\ п")! == ("тест п", nil), "backslash")
        precondition(CommandLineModel.unquoted("'a b")! == ("a b", "'"), "single")
        precondition(CommandLineModel.unquoted("~/\"x y\"/z")! == ("~/x y/z", nil), "closed quote")
        precondition(CommandLineModel.unquoted("a\\") == nil, "trailing backslash")
        precondition(CommandLineModel.escaped("апка/", quote: "\"") == "апка/", "plain in quotes")
        precondition(CommandLineModel.escaped("a b$\"", quote: "\"") == "a b\\$\\\"", "double-quote specials")
        precondition(CommandLineModel.escaped("a!b", quote: "\"") == "a\"\\!\"b", "! closes the double quote")
        precondition(CommandLineModel.unquoted("\"x a\"\\!\"b")! == ("x a!b", "\""), "and reads back with the quote open")
        precondition(CommandLineModel.escaped("апка 1/", quote: nil) == "апка\\ 1/", "space escaped")
        precondition(CommandLineModel.escaped("x'y", quote: "'") == "x'\\''y", "single quote in single quotes")

        // history: newest first, unique, leading space ignored, capped, saved to disk
        let file = FileManager.default.temporaryDirectory.appending(path: "command_line_check-\(UUID().uuidString)/h.json")
        let history = CommandHistory(fileURL: file)
        await history.loaded()
        for line in ["git status", "ls", "git log", "git status", "gist"] { history.add(line) }
        history.add(" git secret")
        precondition(history.matches(prefix: "gi", limit: 8) == ["gist", "git status", "git log"], "matches: \(history.matches(prefix: "gi", limit: 8))")
        precondition(history.matches(prefix: "gi", limit: 2) == ["gist", "git status"], "limit")
        for i in 0..<2100 { history.add("cmd \(i)") }
        precondition(history.matches(prefix: "", limit: 5000).count == 2000, "capped at 2000")
        precondition(history.matches(prefix: "cmd ", limit: 1) == ["cmd 2099"], "newest kept")
        history.flush()
        let reloaded = CommandHistory(fileURL: file)
        precondition(reloaded.matches(prefix: "", limit: 1) == [], "empty until read")
        await reloaded.loaded()
        precondition(reloaded.matches(prefix: "", limit: 5000) == history.matches(prefix: "", limit: 5000), "persisted")
        // a line added before the file is read joins the saved ones as the newest, and the save keeps both
        let early = CommandHistory(fileURL: file)
        early.add("cmd 5")
        await early.loaded()
        precondition(early.matches(prefix: "cmd ", limit: 2) == ["cmd 5", "cmd 2099"] && early.matches(prefix: "", limit: 5000).count == 2000, "merged")
        early.flush()
        let again = CommandHistory(fileURL: file)
        await again.loaded()
        precondition(again.matches(prefix: "", limit: 5000) == early.matches(prefix: "", limit: 5000), "merge saved")
        precondition(CommandHistory(fileURL: nil).matches(prefix: "", limit: 8) == [], "in memory")
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())

        print("command line: ok")
    }
}
