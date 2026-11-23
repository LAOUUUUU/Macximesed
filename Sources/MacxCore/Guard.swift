import Foundation

// MARK: - Shell history

public enum Shell: String, Sendable {
    case zsh, bash, fish
}

public struct HistoryEntry: Sendable, Equatable {
    public var command: String
    public var date: Date?
    public var file: String
    /// Line in the file where the command starts.
    public var line: Int
}

public struct HistoryFile: Sendable, Equatable {
    public var url: URL
    public var shell: Shell
}

public enum ShellHistory {
    /// Every history file the shells on this Mac write. Terminal keeps one per window or tab in `~/.zsh_sessions`.
    public static func files(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [HistoryFile] {
        var out: [HistoryFile] = []
        let fm = FileManager.default
        func add(_ url: URL, _ shell: Shell) {
            if fm.fileExists(atPath: url.path), !out.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                out.append(HistoryFile(url: url, shell: shell))
            }
        }
        if let h = environment["HISTFILE"], !h.isEmpty {
            let url = URL(fileURLWithPath: (h as NSString).expandingTildeInPath)
            add(url, url.lastPathComponent.contains("bash") ? .bash : .zsh)
        }
        let zdot = environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? home
        add(zdot.appendingPathComponent(".zsh_history"), .zsh)
        add(home.appendingPathComponent(".zsh_history"), .zsh)
        for f in CleanupCatalog.children(of: zdot.appendingPathComponent(".zsh_sessions")) where f.pathExtension == "history" {
            add(f, .zsh)
        }
        add(home.appendingPathComponent(".bash_history"), .bash)
        let fishDir = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
        add(fishDir.appendingPathComponent("fish/fish_history"), .fish)
        return out
    }

    public static func read(_ file: HistoryFile) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file.url) else { return [] }
        switch file.shell {
        case .zsh: return parseZsh(data, file: file.url.path)
        case .bash: return parseBash(String(decoding: data, as: UTF8.self), file: file.url.path)
        case .fish: return parseFish(String(decoding: data, as: UTF8.self), file: file.url.path)
        }
    }

    /// zsh writes `: <start>:<elapsed>;<command>` (extended history) or plain lines. A command that
    /// ends with a backslash continues on the next line. Some bytes are "metafied": 0x83, then the byte XOR 32.
    public static func parseZsh(_ data: Data, file: String) -> [HistoryEntry] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var meta = false
        for b in data {
            if meta {
                bytes.append(b ^ 32)
                meta = false
            } else if b == 0x83 {
                meta = true
            } else {
                bytes.append(b)
            }
        }
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [HistoryEntry] = []
        var i = 0
        while i < lines.count {
            var line = lines[i]
            let start = i
            var date: Date?
            if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                let stamp = line[line.index(line.startIndex, offsetBy: 2)..<semi].split(separator: ":").first.flatMap { Double($0) }
                date = stamp.map { Date(timeIntervalSince1970: $0) }
                line = String(line[line.index(after: semi)...])
            }
            var command = line
            while command.hasSuffix("\\"), i + 1 < lines.count {
                i += 1
                command += "\n" + lines[i]
            }
            if !command.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(HistoryEntry(command: command, date: date, file: file, line: start + 1))
            }
            i += 1
        }
        return out
    }

    /// bash writes one command per line, with `#<epoch>` lines before them when HISTTIMEFORMAT is set.
    public static func parseBash(_ text: String, file: String) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        var pending: Date?
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("#"), let t = Double(line.dropFirst()) {
                pending = Date(timeIntervalSince1970: t)
                continue
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            out.append(HistoryEntry(command: line, date: pending, file: file, line: i + 1))
            pending = nil
        }
        return out
    }

    /// fish writes `- cmd: <command>` then `  when: <epoch>`.
    public static func parseFish(_ text: String, file: String) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("- cmd: ") {
                // fish escapes newlines as "\n" and backslashes as "\\".
                let cmd = String(line.dropFirst(7)).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\")
                out.append(HistoryEntry(command: cmd, date: nil, file: file, line: i + 1))
            } else if line.hasPrefix("  when: "), let t = Double(line.dropFirst(8)), !out.isEmpty {
                out[out.count - 1].date = Date(timeIntervalSince1970: t)
            }
        }
        return out
    }
}

// MARK: - Guard

public struct GuardResult: Sendable, Equatable {
    public var patterns: Set<CommandPattern>
    /// Hidden commands decoded from base64 in the text (and checked too).
    public var decoded: [String]
    /// Downloads in the command that get run: these can be fetched and read first (`macx guard inspect`).
    public var downloads: [DownloadRun] = []
    /// Parts whose effect can't be worked out, such as `eval "$x"` with x unknown.
    public var unknowns: Set<String> = []
    public var isDangerous: Bool { !patterns.isEmpty || !downloads.isEmpty || !unknowns.isEmpty }
    public var needsInspection: Bool { !downloads.isEmpty }
}

public struct HistoryHit: Sendable, Equatable {
    public var entry: HistoryEntry
    public var result: GuardResult
}

public enum PasteGuard {
    /// Checks a command (typed, pasted or from history). Base64 payloads are decoded and checked as well,
    /// so a disguised `curl | sh` is caught even when the outer command only says `base64 -D | zsh`.
    public static func check(_ text: String) -> GuardResult {
        // Check the text as typed and with simple disguises undone (c""url, $'\x63url', a=cu;$a...).
        let normalized = ShellNormalizer.normalize(text)
        var patterns = CommandPatterns.match(text).union(CommandPatterns.match(normalized))
        let decoded = CommandPatterns.decodedPayloads(in: text)
        for d in decoded {
            patterns.formUnion(CommandPatterns.match(d))
            patterns.formUnion(CommandPatterns.match(ShellNormalizer.normalize(d)))
        }
        let downloads = DownloadRuns.find(in: text)
        if !downloads.isEmpty { patterns.insert(.downloadToShell) }
        // After normalising, a variable that is still `$x` couldn't be resolved from the paste itself.
        var unknowns: Set<String> = []
        if normalized.range(of: ScriptInspector.evalOfVariable, options: .regularExpression) != nil {
            unknowns.insert("runs-unresolved-code")
        }
        return GuardResult(patterns: patterns, decoded: decoded, downloads: downloads, unknowns: unknowns)
    }

    public static func scanHistory(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [HistoryHit] {
        ShellHistory.files(home: home, environment: environment).flatMap { file in
            ShellHistory.read(file).compactMap { entry in
                let r = check(entry.command)
                return r.isDangerous ? HistoryHit(entry: entry, result: r) : nil
            }
        }
        .sorted { ($0.entry.date ?? .distantPast) < ($1.entry.date ?? .distantPast) }
    }
}

// MARK: - zsh hook

/// Wraps zsh's Enter key: a dangerous command is stopped with an explanation, and pressing Enter again
/// on the same command runs it anyway. It lives in its own file, sourced from one marked block in `.zshrc`,
/// so uninstalling removes exactly what was added.
public struct GuardHook: Sendable {
    public var home: URL
    public var macxPath: String
    public var zdotdir: URL?

    public static let beginMarker = "# >>> macximesed paste guard >>>"
    public static let endMarker = "# <<< macximesed paste guard <<<"

    public init(home: URL, macxPath: String, zdotdir: URL? = nil) {
        self.home = home
        self.macxPath = macxPath
        self.zdotdir = zdotdir
    }

    public var zshrc: URL { (zdotdir ?? home).appendingPathComponent(".zshrc") }
    public var script: URL { home.appendingPathComponent(".config/macximesed/guard.zsh") }

    public var isInstalled: Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains(Self.beginMarker)
    }

    public func install() throws {
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        guard !isInstalled else { return }
        var rc = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        if !rc.isEmpty, !rc.hasSuffix("\n") { rc += "\n" }
        rc += "\(Self.beginMarker)\n[ -r \(shellQuote(script.path)) ] && source \(shellQuote(script.path))\n\(Self.endMarker)\n"
        try rc.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    public func uninstall() throws {
        if var rc = try? String(contentsOf: zshrc, encoding: .utf8),
            let start = rc.range(of: Self.beginMarker + "\n"),
            let end = rc.range(of: Self.endMarker + "\n", range: start.upperBound..<rc.endIndex)
        {
            rc.removeSubrange(start.lowerBound..<end.upperBound)
            try rc.write(to: zshrc, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: script)
    }

    var scriptText: String {
        """
        # Macximesed paste guard. Installed by `macx guard install`, removed by `macx guard uninstall`.
        # Before a command runs, macx checks it for download-and-run, hidden base64 code, quarantine
        # stripping and password prompts. A command that downloads code to run is sent to `macx guard inspect`,
        # which reads the script first. Any other flagged command only runs if you type RUN; Enter alone never runs it.
        [[ -o interactive ]] || return 0
        _macx_guard_bin=\(shellQuote(macxPath))

        _macx_guard_accept_line() {
          if [[ -n "$BUFFER" && -x "$_macx_guard_bin" ]]; then
            local out
            out=$(MACX_OWN_RESPONSIBILITY=0 "$_macx_guard_bin" guard check --short -- "$BUFFER" 2>/dev/null)
            local code=$?
            if [[ $code -eq 3 ]]; then
              # It downloads code to run: read it first instead. The original never runs directly.
              BUFFER="${(q)_macx_guard_bin} guard inspect -- ${(q)BUFFER}"
              zle .accept-line
              return 0
            fi
            if [[ $code -eq 2 ]]; then
              # Show why, then ask for a typed RUN on the terminal. Anything else (or Enter) cancels and keeps the line.
              zle -I
              print -r -- "$out"
              local reply=""
              read -r "reply?Type RUN to run it anyway (anything else cancels): " < /dev/tty
              if [[ "$reply" == "RUN" ]]; then
                zle .accept-line
              else
                print -r -- "Not run. The command is still on the line so you can edit it."
                zle reset-prompt
              fi
              return 0
            fi
          fi
          zle .accept-line
        }
        zle -N accept-line _macx_guard_accept_line
        """ + "\n"
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
