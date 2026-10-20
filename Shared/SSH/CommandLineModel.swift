import Foundation

/// The shell's input line, rebuilt from the user's own keystrokes since the last Enter / Ctrl-C / Ctrl-D,
/// and whether the remote side echoes them (it doesn't at a password prompt). Pure; checked by
/// scripts/command_line_check.swift.
struct CommandLineModel {
    /// nil = unknown (cursor keys, Tab, Ctrl-A…, a paste with a newline) until the next Enter.
    private(set) var line: String? = ""
    var isAlternateScreen = false
    /// Our input that hasn't come back yet.
    private var pendingEcho: [UInt8] = []
    /// Something else came back where our input should have: until the next Enter.
    private var echoOff = false
    private var output = OutputState.text
    /// A space in the output that is only an erase if a `\b` (or `\r`, at a line wrap) follows it.
    private var heldSpace = false

    private enum OutputState { case text, escape, csi, osc, oscEscape }

    var showsSuggestions: Bool {
        guard let line, !line.isEmpty else { return false }
        return !isAlternateScreen && !echoOff && pendingEcho.isEmpty
    }

    /// The word under the cursor as typed (quotes and backslashes kept), and whether it's the command:
    /// the first word of the line or after `|`, `;`, `&`.
    var currentWord: (text: String, isFirst: Bool) {
        var word = "", isFirst = true, quote: Character?, escaped = false
        for c in line ?? "" {
            if escaped {
                escaped = false
            } else if let q = quote {
                if c == q { quote = nil } else if c == "\\", q == "\"" { escaped = true }
            } else {
                switch c {
                case "\\": escaped = true
                case "\"", "'": quote = c
                case " ", "\t":
                    if !word.isEmpty { isFirst = false }
                    word = ""
                    continue
                case "|", ";", "&":
                    word = ""
                    isFirst = true
                    continue
                default: break
                }
            }
            word.append(c)
        }
        return (word, isFirst)
    }

    /// The user's keystrokes on their way to the shell. Returns the lines entered that may go to history:
    /// known, echoed, not blank and not starting with a space.
    @discardableResult
    mutating func typed(_ bytes: [UInt8]) -> [String] {
        var entered: [String] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            switch b {
            case 0x0D:
                if let line, !echoOff, pendingEcho.isEmpty, line.first != " ", !line.allSatisfy(\.isWhitespace) {
                    entered.append(line)
                }
                reset()
            case 0x03, 0x04:
                reset()
            case 0x7F, 0x08:
                if line?.isEmpty == false { line?.removeLast() }
            case 0x20..<0x7F:
                guard line != nil else { continue }
                line?.append(Character(Unicode.Scalar(b)))
                pendingEcho.append(b)
            case 0xC2...0xF4:
                let length = b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
                let end = i - 1 + length
                guard line != nil else { continue }
                guard end <= bytes.count, let char = String(bytes: bytes[(i - 1)..<end], encoding: .utf8) else {
                    line = nil
                    continue
                }
                line?.append(contentsOf: char)
                pendingEcho += bytes[(i - 1)..<end]
                i = end
            default:
                line = nil // any other control byte, ESC, a stray UTF-8 byte
            }
        }
        return entered
    }

    /// The terminal's output. While our input is pending it must come back first; escape sequences,
    /// control bytes and the `" \b"` of an erase may come in between.
    mutating func echoed(_ bytes: [UInt8]) {
        for b in bytes {
            switch output {
            case .escape:
                output = b == 0x5B ? .csi : b == 0x5D ? .osc : .text
                continue
            case .csi:
                if (0x40...0x7E).contains(b) { output = .text }
                continue
            case .osc:
                if b == 0x07 { output = .text } else if b == 0x1B { output = .oscEscape }
                continue
            case .oscEscape:
                output = b == 0x5C ? .text : .osc
                continue
            case .text:
                break
            }
            if b == 0x1B {
                output = .escape
                continue
            }
            guard !pendingEcho.isEmpty else { continue }
            if heldSpace {
                heldSpace = false
                if b == 0x08 || b == 0x0D { continue }
                mismatch()
            } else if b == pendingEcho[0] {
                pendingEcho.removeFirst()
            } else if b < 0x20 || b == 0x7F {
                continue
            } else if b == 0x20 {
                heldSpace = true
            } else {
                mismatch()
            }
        }
    }

    /// A suggestion's suffix, sent to the shell as keystrokes.
    mutating func accepted(_ suffix: String) {
        guard line != nil else { return }
        line? += suffix
        pendingEcho += suffix.utf8
    }

    private mutating func reset() {
        line = ""
        pendingEcho = []
        echoOff = false
        heldSpace = false
    }

    private mutating func mismatch() {
        echoOff = true
        pendingEcho = []
    }

    // MARK: - Quoting

    /// What a shell word means, and the quote still open at its end. Nil if it ends in a lone backslash.
    static func unquoted(_ word: String) -> (value: String, quote: Character?)? {
        var value = "", quote: Character?, escaped = false
        for c in word {
            if escaped {
                if quote == "\"", !"$`\"\\".contains(c) { value.append("\\") }
                value.append(c)
                escaped = false
            } else if c == "\\", quote != "'" {
                escaped = true
            } else if let q = quote {
                if c == q { quote = nil } else { value.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else {
                value.append(c)
            }
        }
        return escaped ? nil : (value, quote)
    }

    /// `text` to continue a word whose open quote is `quote` (nil: unquoted, backslash-escaped).
    static func escaped(_ text: String, quote: Character?) -> String {
        switch quote {
        case "'": return text.replacingOccurrences(of: "'", with: "'\\''")
        case "\"": return String(text.flatMap { "$`\"\\".contains($0) ? ["\\", $0] : [$0] })
        default: return String(text.flatMap { " \t\"'\\$`&|;<>()*?[]!#{}".contains($0) ? ["\\", $0] : [$0] })
        }
    }
}
