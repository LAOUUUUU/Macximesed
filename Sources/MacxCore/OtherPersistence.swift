import Foundation

/// Places code can be set to run beyond launchd, login items, cron and shell files. Everything here is
/// readable without root. Things with almost no legitimate use (authorization plugins, login hooks,
/// non-Apple PAM modules) are flagged by `PersistenceRules`; things that are normally fine (app, system,
/// kernel and browser extensions) are listed so a baseline shows when a new one appears.
public enum OtherPersistence {
    public static func scan(
        _ roots: PersistenceRoots, signatures: SignatureChecking = GuardedSignatureChecker(),
        runner: CommandRunner = ProcessRunner(timeout: 20)
    ) -> [PersistenceItem] {
        let sys = roots.system
        var items: [PersistenceItem] = []
        let fm = FileManager.default

        func item(
            _ kind: PersistenceKind, _ url: URL, label: String? = nil, program: String? = nil, detail: String? = nil,
            root: Bool = false, signature: SignatureInfo? = nil, team: String? = nil
        ) -> PersistenceItem {
            let content = (try? Data(contentsOf: url)) ?? Data(url.path.utf8)
            return PersistenceItem(
                kind: kind, path: url.path, label: label ?? url.lastPathComponent, program: program, arguments: [], runsAsRoot: root,
                runAtLoad: true, keepAlive: false, signature: signature, teamID: team, contentHash: sha256(content), detail: detail)
        }

        // Authorization plugins: loaded by the login window, with access to the password being typed.
        for b in CleanupCatalog.children(of: sys.appendingPathComponent("Library/Security/SecurityAgentPlugins"))
        where b.pathExtension == "bundle" {
            items.append(item(.authorizationPlugin, b, root: true, signature: signatures.check(b.path)))
        }

        // periodic(8) scripts and the *.local hooks, all run as root.
        var periodic: [URL] = []
        for base in ["etc/periodic", "usr/local/etc/periodic"] {
            for dir in ["daily", "weekly", "monthly"] {
                periodic += CleanupCatalog.children(of: sys.appendingPathComponent("\(base)/\(dir)"))
            }
        }
        periodic += ["etc/daily.local", "etc/weekly.local", "etc/monthly.local", "etc/periodic.conf.local"]
            .map { sys.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        for f in periodic {
            let text = (try? String(contentsOf: f, encoding: .utf8)).map { String($0.prefix(8000)) }
            items.append(item(.periodicScript, f, detail: text, root: true))
        }

        // StartupItems: retired by Apple (10.10), still tried by old malware and by attack kits.
        for f in CleanupCatalog.children(of: sys.appendingPathComponent("Library/StartupItems")) where !f.lastPathComponent.hasPrefix(".") {
            items.append(item(.startupItem, f, root: true))
        }

        // /etc/cron.*: macOS doesn't run these, but a script dropped there means someone tried.
        for dir in ["cron.hourly", "cron.daily", "cron.weekly", "cron.monthly"] {
            for f in CleanupCatalog.children(of: sys.appendingPathComponent("etc/\(dir)")) where !f.lastPathComponent.hasPrefix(".") {
                let text = (try? String(contentsOf: f, encoding: .utf8)).map { String($0.prefix(8000)) }
                items.append(item(.periodicScript, f, detail: text, root: true))
            }
        }

        // The main sudoers file needs root to read; then any change shows in a diff and weakening is flagged.
        let sudoers = sys.appendingPathComponent("etc/sudoers")
        if let text = try? String(contentsOf: sudoers, encoding: .utf8) {
            let weak = sudoersWeakening(text)
            items.append(
                item(.sudoersFile, sudoers, label: "sudoers", detail: weak.isEmpty ? nil : weak.joined(separator: "\n"), root: true))
        }

        // sudoers.d: names are readable, contents need root.
        for f in CleanupCatalog.children(of: sys.appendingPathComponent("etc/sudoers.d")) where !f.lastPathComponent.hasPrefix(".") {
            items.append(item(.sudoersFile, f, root: true))
        }

        // PAM: macOS's own modules are named pam_*.so and load from /usr/lib/pam. Anything else is reported.
        for f in CleanupCatalog.children(of: sys.appendingPathComponent("etc/pam.d")) {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.hasPrefix("#") {
                guard let module = pamModule(in: line), !isStandardPAMModule(module) else { continue }
                items.append(
                    item(
                        .pamModule, f, label: "\(f.lastPathComponent): \(module)", program: module.hasPrefix("/") ? module : nil,
                        detail: line, root: true))
            }
        }

        // at(1) jobs.
        for f in CleanupCatalog.children(of: sys.appendingPathComponent("private/var/at/jobs")) where !f.lastPathComponent.hasPrefix(".") {
            items.append(item(.atJob, f, root: true))
        }

        // Kernel extensions installed outside the system volume.
        for k in CleanupCatalog.children(of: sys.appendingPathComponent("Library/Extensions")) where k.pathExtension == "kext" {
            items.append(item(.kernelExtension, k, root: true, signature: signatures.check(k.path)))
        }

        // Login and logout hooks (com.apple.loginwindow), and extensions macOS manages.
        if sys.path == "/" {
            let defaults = UserDefaults(suiteName: "com.apple.loginwindow")
            var hooks: [String: String] = [:]
            for key in ["LoginHook", "LogoutHook"] { if let v = defaults?.string(forKey: key) { hooks[key] = v } }
            items += loginHooks(defaultsOutput: hooks)
            if let out = try? runner.run("/usr/bin/pluginkit", ["-mAvvv"]) {
                items += appExtensions(pluginkitOutput: out, signatures: signatures)
            }
            if let out = try? runner.run("/usr/bin/systemextensionsctl", ["list"]) { items += systemExtensions(output: out) }
        }
        items += browserExtensions(home: roots.home)
        return items
    }

    // MARK: Parsers

    /// The module in a pam.d line: `type control module [args]`, where control may be `[ ... ]`.
    /// Lines that make sudo weaker: credentials cached forever, shared across terminals, or no password at all.
    public static func sudoersWeakening(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            guard !line.hasPrefix("#") else { return false }
            let l = line.lowercased().replacingOccurrences(of: " ", with: "")
            return l.contains("timestamp_timeout=-1") || l.contains("!tty_tickets") || l.contains("nopasswd:all")
                || (l.hasPrefix("all") && l.contains("nopasswd"))
        }
    }

    static func pamModule(in line: String) -> String? {
        var rest = Substring(line)
        guard let typeEnd = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        rest = rest[typeEnd...].drop(while: { $0 == " " || $0 == "\t" })
        // `include` and `substack` name another pam.d file, not a module.
        if rest.hasPrefix("include") || rest.hasPrefix("substack") { return nil }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            rest = rest[rest.index(after: close)...]
        } else {
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            rest = rest[end...]
        }
        return rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    static func isStandardPAMModule(_ module: String) -> Bool {
        if module.hasPrefix("/") { return module.hasPrefix("/usr/lib/pam/pam_") }
        return module.hasPrefix("pam_") && !module.contains("/")
    }

    public static func loginHooks(defaultsOutput: [String: String]) -> [PersistenceItem] {
        defaultsOutput.sorted { $0.key < $1.key }.map { key, value in
            PersistenceItem(
                kind: .loginHook, path: "com.apple.loginwindow \(key)", label: key, program: value, arguments: [], runsAsRoot: true,
                runAtLoad: true, keepAlive: false, signature: nil, teamID: nil, contentHash: sha256("\(key)=\(value)"), detail: value)
        }
    }

    /// `pluginkit -mAvvv` blocks: `[+|-|!|=] bundle.id(version)` then `Key = value` lines. Apple's own
    /// (anything under /System) are left out. `-` means the user turned it off.
    public static func appExtensions(pluginkitOutput: String, signatures: SignatureChecking) -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        var current: (id: String, flag: String, fields: [String: String])?
        func flush() {
            guard let c = current, let path = c.fields["Path"], !path.hasPrefix("/System/") else { return }
            let state = c.flag == "-" ? "disabled" : "enabled"
            out.append(
                PersistenceItem(
                    kind: .appExtension, path: path, label: c.id, program: path, arguments: [], runsAsRoot: false, runAtLoad: c.flag != "-",
                    keepAlive: false, signature: signatures.check(path), teamID: nil,
                    contentHash: sha256("\(c.id)|\(path)|\(state)"), detail: "\(c.fields["SDK"] ?? "unknown type"), \(state)"))
        }
        let header = try? NSRegularExpression(pattern: #"^\s*([+\-!=]?)\s*(\S+)\(([^)]*)\)\s*$"#)
        for raw in pluginkitOutput.split(separator: "\n").map(String.init) {
            if let m = header?.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                let f = Range(m.range(at: 1), in: raw), let id = Range(m.range(at: 2), in: raw)
            {
                flush()
                current = (String(raw[id]), String(raw[f]), [:])
            } else if let eq = raw.range(of: " = "), current != nil {
                let key = raw[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                current?.fields[key] = String(raw[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return out
    }

    /// `systemextensionsctl list` rows: enabled, active, team ID, `bundle.id (version)`, name, [state].
    public static func systemExtensions(output: String) -> [PersistenceItem] {
        output.split(separator: "\n").compactMap { line -> PersistenceItem? in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 6, cols[3].contains(" ("), !cols[2].isEmpty, cols[2] != "teamID" else { return nil }
            let bundle = String(cols[3].prefix { $0 != " " })
            return PersistenceItem(
                kind: .systemExtension, path: bundle, label: cols[4], program: nil, arguments: [], runsAsRoot: true,
                runAtLoad: cols[0] == "*", keepAlive: false, signature: nil, teamID: cols[2], contentHash: sha256(String(line)),
                detail: "\(cols[3]) \(cols[5])")
        }
    }

    /// Extensions in Chrome-family browsers (per profile) and user-installed add-ons in Firefox-family ones.
    public static func browserExtensions(home: URL) -> [PersistenceItem] {
        let fm = FileManager.default
        var out: [PersistenceItem] = []
        let support = home.appendingPathComponent("Library/Application Support")
        let chromium = ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Chromium", "Vivaldi", "Arc/User Data"]
        for browser in chromium {
            let base = support.appendingPathComponent(browser)
            for profile in CleanupCatalog.children(of: base) {
                for ext in CleanupCatalog.children(of: profile.appendingPathComponent("Extensions")) {
                    guard let version = CleanupCatalog.children(of: ext).last,
                        let data = try? Data(contentsOf: version.appendingPathComponent("manifest.json")),
                        let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    var name = manifest["name"] as? String ?? ext.lastPathComponent
                    if name.hasPrefix("__MSG_") { name = ext.lastPathComponent }  // localised name: the ID is the stable fact
                    let perms = (manifest["permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
                    out.append(
                        PersistenceItem(
                            kind: .browserExtension, path: ext.path, label: name, program: nil, arguments: [], runsAsRoot: false,
                            runAtLoad: true, keepAlive: false, signature: nil, teamID: nil, contentHash: sha256(data),
                            detail: "\(browser) \(profile.lastPathComponent), version \(manifest["version"] as? String ?? "?")"
                                + (perms.isEmpty ? "" : ", permissions: \(perms.prefix(8).joined(separator: ", "))")))
                }
            }
        }
        for browser in ["Firefox", "zen", "LibreWolf", "Waterfox"] {
            for profile in CleanupCatalog.children(of: support.appendingPathComponent("\(browser)/Profiles")) {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent("extensions.json")),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let addons = json["addons"] as? [[String: Any]]
                else { continue }
                for a in addons where a["location"] as? String == "app-profile" {
                    let id = a["id"] as? String ?? "?"
                    let name = (a["defaultLocale"] as? [String: Any])?["name"] as? String ?? id
                    out.append(
                        PersistenceItem(
                            kind: .browserExtension, path: profile.appendingPathComponent("extensions/\(id)").path, label: name,
                            program: nil,
                            arguments: [], runsAsRoot: false, runAtLoad: (a["active"] as? Bool) ?? true, keepAlive: false, signature: nil,
                            teamID: nil, contentHash: sha256("\(id)|\(a["version"] as? String ?? "")"),
                            detail: "\(browser) \(profile.lastPathComponent), version \(a["version"] as? String ?? "?")"))
                }
            }
        }
        _ = fm
        return out
    }
}
