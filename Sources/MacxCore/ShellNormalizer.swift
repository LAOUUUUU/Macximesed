import Foundation

/// Undoes the simple tricks used to hide a command from people and pattern checks: split quoting
/// (`c""url`), backslashes (`c\url`), ANSI-C strings (`$'\x63url'`), variables set earlier in the
/// same paste (`a=cu; $a...`), `$(printf '\x..')` and `echo '...' | rev`. It never runs anything.
/// Whitespace and operators are kept as typed; only words are rewritten, and a word that needs
/// quoting after rewriting is put back in double quotes.
public enum ShellNormalizer {
    public static func normalize(_ text: String, depth: Int = 0) -> String {
        var vars: [String: String] = [:]
        var out = normalizeWords(Array(text), vars: &vars, depth: depth)
        out = undoRev(out)
        return out
    }

    // MARK: Words

    static let operators: Set<Character> = ["|", ";", "&", "<", ">", "(", ")", "\n"]

    static func normalizeWords(_ chars: [Character], vars: inout [String: String], depth: Int) -> String {
        var out = ""
        var i = 0
        var commandStart = true
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" {
                out.append(c)
                i += 1
                continue
            }
            if c == "<", i + 1 < chars.count, chars[i + 1] == "(" {
                // Process substitution: keep it, normalise what's inside.
                let (inner, end) = balanced(chars, from: i + 1)
                out += "<(" + normalize(String(inner), depth: depth + 1) + ")"
                i = end
                commandStart = false
                continue
            }
            if operators.contains(c) {
                out.append(c)
                if [";", "|", "&", "\n", "("].contains(c) { commandStart = true }
                i += 1
                continue
            }
            let (word, needsQuotes, end) = readWord(chars, from: i, vars: vars, depth: depth)
            i = end
            if commandStart, let eq = word.firstIndex(of: "="), word[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                !word[..<eq].isEmpty
            {
                vars[String(word[..<eq])] = String(word[word.index(after: eq)...])
                out += word  // still at command start: assignments can be followed by more
                continue
            }
            out += needsQuotes ? "\"" + word + "\"" : word
            commandStart = false
        }
        return out
    }

    /// Reads one shell word, joining quoted pieces, and returns its plain text.
    static func readWord(_ chars: [Character], from start: Int, vars: [String: String], depth: Int) -> (String, Bool, Int) {
        var word = ""
        var quoted = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || operators.contains(c) && !(c == "(" && word.hasSuffix("$")) { break }
            switch c {
            case "\\":
                if i + 1 < chars.count {
                    if chars[i + 1] != "\n" { word.append(chars[i + 1]) }
                    i += 2
                } else {
                    i += 1
                }
            case "'":
                quoted = true
                var j = i + 1
                while j < chars.count, chars[j] != "'" {
                    word.append(chars[j])
                    j += 1
                }
                i = j + 1
            case "\"":
                quoted = true
                var j = i + 1
                var inner: [Character] = []
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count, ["\"", "\\", "$", "`"].contains(chars[j + 1]) {
                        inner.append(chars[j + 1])
                        j += 2
                        continue
                    }
                    if chars[j] == "$", j + 1 < chars.count, chars[j + 1] == "(" {
                        let (sub, end) = balanced(chars, from: j + 1)
                        inner += Array(substitute(String(sub), depth: depth))
                        j = end
                        continue
                    }
                    inner.append(chars[j])
                    j += 1
                }
                word += expandVariables(String(inner), vars: vars)
                i = j + 1
            case "$":
                if i + 1 < chars.count, chars[i + 1] == "'" {
                    // ANSI-C quoting.
                    quoted = true
                    var j = i + 2
                    var raw = ""
                    while j < chars.count, chars[j] != "'" {
                        if chars[j] == "\\", j + 1 < chars.count {
                            raw.append(chars[j])
                            raw.append(chars[j + 1])
                            j += 2
                            continue
                        }
                        raw.append(chars[j])
                        j += 1
                    }
                    word += decodeEscapes(raw)
                    i = j + 1
                } else if i + 1 < chars.count, chars[i + 1] == "(" {
                    let (sub, end) = balanced(chars, from: i + 1)
                    word += substitute(String(sub), depth: depth)
                    i = end
                } else {
                    let (name, end) = variableName(chars, from: i + 1)
                    if let name, let value = vars[name] {
                        word += value
                    } else {
                        word += String(chars[i..<end])
                    }
                    i = end
                }
            case "`":
                var j = i + 1
                var sub = ""
                while j < chars.count, chars[j] != "`" {
                    sub.append(chars[j])
                    j += 1
                }
                word += substitute(sub, depth: depth)
                i = j + 1
            default:
                word.append(c)
                i += 1
            }
        }
        let needsQuotes = quoted && word.contains { $0 == " " || $0 == "\t" || operators.contains($0) }
        return (word, needsQuotes, i)
    }

    /// `$(printf 'FMT')` and `$(echo -e 'TEXT')` with literal text become their output; anything else
    /// stays as `$(...)` with its inside normalised.
    static func substitute(_ inner: String, depth: Int) -> String {
        let n = depth < 3 ? normalize(inner, depth: depth + 1) : inner
        // Evaluate printf/echo on the raw text: normalising first would eat the backslash escapes.
        let words = ShellWords.split(inner)
        if let first = words.first, first == "printf", words.count == 2, !words[1].contains("%") {
            return decodeEscapes(words[1])
        }
        if let first = words.first, first == "echo", words.count >= 2 {
            let flags = words.dropFirst().prefix { $0.hasPrefix("-") }
            let rest = words.dropFirst(1 + flags.count)
            if flags.contains(where: { $0.contains("e") }) { return decodeEscapes(rest.joined(separator: " ")) }
            if flags.isEmpty || flags.allSatisfy({ $0 == "-n" }) { return rest.joined(separator: " ") }
        }
        return "$(" + n + ")"
    }

    static func expandVariables(_ s: String, vars: [String: String]) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "$" {
                let (name, end) = variableName(chars, from: i + 1)
                if let name, let v = vars[name] {
                    out += v
                    i = end
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    static func variableName(_ chars: [Character], from start: Int) -> (String?, Int) {
        guard start < chars.count else { return (nil, start) }
        if chars[start] == "{" {
            var j = start + 1
            var name = ""
            while j < chars.count, chars[j] != "}" {
                name.append(chars[j])
                j += 1
            }
            let valid = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            return (valid ? name : nil, min(j + 1, chars.count))
        }
        var j = start
        var name = ""
        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
            name.append(chars[j])
            j += 1
        }
        return (name.isEmpty ? nil : name, j)
    }

    /// Backslash escapes as in `$'...'`, `printf` and `echo -e`: \xHH, \NNN (octal), \n, \t, \\, \', \".
    static func decodeEscapes(_ s: String) -> String {
        let chars = Array(s)
        var bytes: [UInt8] = []
        var i = 0
        func digits(_ allowed: (Character) -> Bool, max: Int) -> String {
            var d = ""
            while i < chars.count, d.count < max, allowed(chars[i]) {
                d.append(chars[i])
                i += 1
            }
            return d
        }
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else {
                bytes += Array(String(c).utf8)
                i += 1
                continue
            }
            let e = chars[i + 1]
            i += 2
            switch e {
            case "x":
                let d = digits({ $0.isHexDigit }, max: 2)
                if let v = UInt8(d, radix: 16) { bytes.append(v) } else { bytes += Array("\\x".utf8) }
            case "0"..."7":
                i -= 1
                let d = digits({ ("0"..."7").contains($0) }, max: 3)
                if let v = UInt8(d, radix: 8) { bytes.append(v) }
            case "n": bytes.append(0x0A)
            case "t": bytes.append(0x09)
            case "r": bytes.append(0x0D)
            case "\\": bytes.append(0x5C)
            case "'": bytes.append(0x27)
            case "\"": bytes.append(0x22)
            default: bytes += Array("\\\(e)".utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The matching close paren for the open paren at `open`, skipping quoted text. Returns the inside and the index after `)`.
    static func balanced(_ chars: [Character], from open: Int) -> ([Character], Int) {
        var depth = 0
        var i = open
        var quote: Character?
        var inner: [Character] = []
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\", q == "\"", i + 1 < chars.count {
                    inner.append(c)
                    inner.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "(" {
                depth += 1
                if depth == 1 {
                    i += 1
                    continue
                }
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return (inner, i + 1) }
            }
            inner.append(c)
            i += 1
        }
        return (inner, chars.count)
    }

    /// `echo "TEXT" | rev` becomes `echo "<TEXT reversed>"`.
    static func undoRev(_ s: String) -> String {
        guard s.contains("rev"),
            let re = try? NSRegularExpression(pattern: #"echo\s+(["']?)(.+?)\1\s*\|\s*rev\b"#)
        else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let all = Range(m.range, in: out), let body = Range(m.range(at: 2), in: out) else { continue }
            out.replaceSubrange(all, with: "echo \"" + String(out[body].reversed()) + "\"")
        }
        return out
    }
}

/// Splits shell text the way the shell would, with quotes removed. Used on already-normalised text.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 1
                } else {
                    current.append(c)
                }
            } else if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c == "\\", i + 1 < chars.count {
                current.append(chars[i + 1])
                inWord = true
                i += 1
            } else if c == " " || c == "\t" || c == "\n" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(c)
                inWord = true
            }
            i += 1
        }
        if inWord { words.append(current) }
        return words
    }

    /// Splits into simple commands at top-level `;`, `&&`, `||`, `&` and newlines, keeping pipelines
    /// together. Quotes and parentheses are respected.
    public static func commands(_ text: String) -> [String] {
        splitTopLevel(text) { chars, i in
            let c = chars[i]
            if c == ";" || c == "\n" { return 1 }
            if c == "&" { return i + 1 < chars.count && chars[i + 1] == "&" ? 2 : 1 }
            if c == "|", i + 1 < chars.count, chars[i + 1] == "|" { return 2 }
            return 0
        }
    }

    /// Splits one command into pipeline stages at top-level single `|`.
    public static func pipeline(_ command: String) -> [String] {
        splitTopLevel(command) { chars, i in
            chars[i] == "|" && !(i + 1 < chars.count && chars[i + 1] == "|") && !(i > 0 && chars[i - 1] == "|") ? 1 : 0
        }
    }

    static func splitTopLevel(_ text: String, separator: ([Character], Int) -> Int) -> [String] {
        let chars = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == "\\", q == "\"", i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "'" || c == "\"" { quote = c }
            if c == "(" { depth += 1 }
            if c == ")" { depth = max(0, depth - 1) }
            if depth == 0 {
                let n = separator(chars, i)
                if n > 0 {
                    parts.append(current)
                    current = ""
                    i += n
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
