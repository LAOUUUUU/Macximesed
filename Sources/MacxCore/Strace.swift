import Foundation

/// Turns the light chamber's strace output into the events the chamber judge reads. The log comes from the
/// guest, so it's untrusted: anything that doesn't parse is skipped and counted, never followed.
///
/// Expected command: `strace -f -ttt -qq -s 4096 -e trace=execve,openat,rename,renameat,renameat2,connect,clone,clone3,fork,vfork`
/// Lines: `PID EPOCH.MICROS syscall(args) = result`, plus `<unfinished ...>` / `<... name resumed>` pairs and
/// `+++ exited with N +++`.
public enum StraceLog {
    public struct Parsed: Sendable {
        public var events: [ESEvent]
        public var skipped: Int
    }

    public static func parse(_ text: String, maxLineBytes: Int = ChamberLog.maxLineBytes) -> Parsed {
        var events: [ESEvent] = []
        var skipped = 0
        var pending: [Int: String] = [:]
        var parent: [Int: Int] = [:]
        var exe: [Int: String] = [:]

        func process(_ pid: Int) -> ESProcessInfo {
            ESProcessInfo(path: exe[pid] ?? "", pid: pid, ppid: parent[pid], isPlatform: false, teamID: nil, signingID: nil)
        }

        // Any line ending: the VM console writes "\r\n", which Swift sees as a single Character.
        for raw in text.split(whereSeparator: \.isNewline) {
            guard raw.utf8.count <= maxLineBytes, let (pid, time, rest0) = header(raw) else {
                skipped += 1
                continue
            }
            var rest = rest0
            if rest.hasPrefix("+++ exited with") || rest.hasPrefix("+++ killed by") {
                var e = ESEvent(kind: "exit", process: process(pid))
                e.time = time
                events.append(e)
                continue
            }
            if rest.hasPrefix("---") { continue }  // signal notes
            if rest.hasSuffix(" <unfinished ...>") {
                pending[pid] = String(rest.dropLast(" <unfinished ...>".count))
                continue
            }
            if rest.hasPrefix("<... "), let close = rest.range(of: " resumed>") {
                guard let start = pending.removeValue(forKey: pid) else {
                    skipped += 1
                    continue
                }
                rest = start + rest[close.upperBound...]
            }
            guard let call = Call(rest) else {
                skipped += 1
                continue
            }
            var e: ESEvent?
            switch call.name {
            case "clone", "clone3", "fork", "vfork":
                if call.result > 0 { parent[Int(call.result)] = pid }
            case "execve":
                guard call.result == 0, let path = call.string(0) else { break }
                exe[pid] = path
                var x = ESEvent(kind: "exec", process: process(pid))
                x.target = ESProcessInfo(path: path, pid: pid, ppid: parent[pid], isPlatform: false, teamID: nil, signingID: nil)
                x.args = call.strings(1)
                e = x
            case "openat":
                guard call.result >= 0, let path = call.string(1) else { break }
                var o = ESEvent(kind: "open", process: process(pid))
                o.filePath = path
                o.time = time
                events.append(o)
                if (call.args.count > 2 ? call.args[2] : "").contains("O_CREAT") {
                    var c = ESEvent(kind: "create", process: process(pid))
                    c.filePath = path
                    e = c
                }
            case "rename", "renameat", "renameat2":
                guard call.result == 0 else { break }
                let (from, to) = call.name == "rename" ? (call.string(0), call.string(1)) : (call.string(1), call.string(3))
                guard let from, let to else { break }
                var r = ESEvent(kind: "rename", process: process(pid))
                r.sourcePath = from
                r.filePath = to
                e = r
            case "connect":
                guard let endpoint = call.args.count > 1 ? Self.endpoint(call.args[1]) : nil else { break }
                var c = ESEvent(kind: "connect", process: process(pid))
                c.filePath = endpoint
                e = c
            default:
                break
            }
            if var e {
                e.time = time
                events.append(e)
            }
        }
        return Parsed(events: events, skipped: skipped)
    }

    /// `PID EPOCH.MICROS rest`
    static func header(_ line: Substring) -> (Int, Date, String)? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int(parts[0]), parts[1].contains("."), let t = Double(parts[1]) else { return nil }
        return (pid, Date(timeIntervalSince1970: t), String(parts[2]))
    }

    /// `{sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("1.2.3.4")}` → "1.2.3.4:443"; IPv6 in brackets.
    static func endpoint(_ s: String) -> String? {
        let port = s.range(of: #"port=htons\((\d+)\)"#, options: .regularExpression).map { String(s[$0].dropFirst(11).dropLast()) }
        if s.contains("AF_INET6"), let r = s.range(of: #"inet_pton\(AF_INET6, "[^"]*""#, options: .regularExpression) {
            let ip = s[r].split(separator: "\"")[1]
            return "[\(ip)]:\(port ?? "?")"
        }
        if s.contains("AF_INET"), let r = s.range(of: #"inet_addr\("[^"]*"\)"#, options: .regularExpression) {
            let ip = s[r].split(separator: "\"")[1]
            return "\(ip):\(port ?? "?")"
        }
        return nil
    }

    /// One syscall: `name(arg, arg, ...) = result [ERRNO (text)]`, arguments split at the top level.
    struct Call {
        var name: String
        var args: [String]
        var result: Int64

        init?(_ s: String) {
            guard let open = s.firstIndex(of: "("), let eq = s.range(of: ") = ", options: .backwards) else { return nil }
            name = String(s[..<open])
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            let tail = s[eq.upperBound...]
            guard let r = Int64(tail.prefix { $0 == "-" || $0.isNumber }) else { return nil }
            result = r
            args = Self.split(String(s[s.index(after: open)..<eq.lowerBound]))
        }

        func string(_ i: Int) -> String? { i < args.count ? StraceLog.cString(args[i]) : nil }
        func strings(_ i: Int) -> [String] {
            guard i < args.count, args[i].hasPrefix("["), args[i].hasSuffix("]") else { return [] }
            return Self.split(String(args[i].dropFirst().dropLast())).compactMap(StraceLog.cString)
        }

        /// Splits at commas outside quotes and brackets.
        static func split(_ s: String) -> [String] {
            var out: [String] = []
            var cur = ""
            var depth = 0
            var inQuote = false
            var escaped = false
            for ch in s {
                if inQuote {
                    cur.append(ch)
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inQuote = false }
                    continue
                }
                switch ch {
                case "\"":
                    inQuote = true
                    cur.append(ch)
                case "[", "{", "(":
                    depth += 1
                    cur.append(ch)
                case "]", "}", ")":
                    depth -= 1
                    cur.append(ch)
                case "," where depth == 0:
                    out.append(cur.trimmingCharacters(in: .whitespaces))
                    cur = ""
                default: cur.append(ch)
                }
            }
            let last = cur.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty { out.append(last) }
            return out
        }
    }

    /// A C string literal as strace prints it, with \n \t \" \\ \ooo \xHH escapes; a trailing `...` means cut off.
    static func cString(_ token: String) -> String? {
        var t = Substring(token)
        if t.hasSuffix("...") { t = t.dropLast(3) }
        guard t.count >= 2, t.first == "\"", t.last == "\"" else { return nil }
        let body = Array(t.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: b - 48
            case 97...102: b - 87
            case 65...70: b - 55
            default: nil
            }
        }
        while i < body.count {
            let b = body[i]
            guard b == 92, i + 1 < body.count else {
                bytes.append(b)
                i += 1
                continue
            }
            let n = body[i + 1]
            switch n {
            case 110:
                bytes.append(10)
                i += 2  // \n
            case 116:
                bytes.append(9)
                i += 2  // \t
            case 114:
                bytes.append(13)
                i += 2  // \r
            case 118:
                bytes.append(11)
                i += 2  // \v
            case 102:
                bytes.append(12)
                i += 2  // \f
            case 120:  // \xHH
                var v: UInt8 = 0
                var j = i + 2
                while j < body.count, j < i + 4, let h = hex(body[j]) {
                    v = v &* 16 &+ h
                    j += 1
                }
                bytes.append(v)
                i = j
            case 48...55:  // \ooo
                var v = 0
                var j = i + 1
                while j < body.count, j < i + 4, (48...55).contains(body[j]) {
                    v = v * 8 + Int(body[j] - 48)
                    j += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: v))
                i = j
            default:
                bytes.append(n)
                i += 2  // \" \\ and anything else
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
