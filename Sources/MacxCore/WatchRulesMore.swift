import Foundation

/// The rare, serious events: XProtect, privacy permissions, profiles, accounts, Gatekeeper overrides, code injection
/// and remote access. Levels are in research/watch-events/RESEARCH.md. What macOS's own tools did on your click starts
/// at medium or lower, and the event's process is only named (and so frozen on critical) when it's the one acting.
extension WatchRules {
    /// The privacy permissions a stealer or remote-control tool wants, by TCC service name (with or without the
    /// `kTCCService` prefix).
    static let sensitiveServices: [String: String] = [
        "SystemPolicyAllFiles": "Full Disk Access", "Accessibility": "Accessibility", "ScreenCapture": "Screen Recording",
        "ListenEvent": "Input Monitoring", "PostEvent": "control of your keyboard and mouse",
    ]

    func evaluateMore(_ e: ESEvent) -> [WatchAlert] {
        let f = e.fields
        let h = home.standardizedFileURL.path
        var out: [WatchAlert] = []
        /// `by` is the process the alert is about (frozen on critical); nil when no process should be.
        func add(_ rule: String, _ sev: Severity, _ title: String, _ detail: [String?], by: ESProcessInfo?) {
            out.append(
                WatchAlert(
                    rule: rule, severity: sev, title: title,
                    detail: detail.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n  "),
                    pid: by?.pid, processPath: by?.path))
        }
        let ok = (f["error_code"] ?? "0") == "0"
        let actor = e.instigator ?? e.process
        let byMacOS = actor?.isPlatform ?? false

        switch e.kind {
        case "xp_malware_detected":
            let name = f["malware_identifier"] ?? "unknown malware"
            add(
                "xprotect-detected", .critical, "Apple's XProtect found malware: \(name)",
                [f["detected_path"], f["detected_executable"].map { "Program: \($0)" }, f["signature_version"].map { "XProtect \($0)" }],
                by: nil)

        case "xp_malware_remediated":
            let name = f["malware_identifier"] ?? "unknown malware"
            if f["success"] == "true" {
                add(
                    "xprotect-remediated", .high, "XProtect removed malware (\(name)). You were infected: check what it touched",
                    [f["remediated_path"], "macx incident list · macx persist"], by: nil)
            } else {
                add(
                    "xprotect-remediated", .critical, "XProtect found malware (\(name)) and couldn't remove it",
                    [f["remediated_path"], f["result_description"]], by: nil)
            }

        case "tcc_modify":
            let raw = f["service"] ?? ""
            let service = raw.hasPrefix("kTCCService") ? String(raw.dropFirst("kTCCService".count)) : raw
            // Granted (allowed, limited, added) on a new or changed entry only.
            guard let label = Self.sensitiveServices[service], ["1", "2"].contains(f["update_type"] ?? ""),
                ["2", "3", "4"].contains(f["right"] ?? "")
            else { break }
            let identity = f["identity"] ?? "?"
            let yourClick = ["2", "3"].contains(f["reason"] ?? "")  // answered a prompt, or switched it on in Settings
            let hiddenProgram = f["identity_type"] == "1" && Self.isHiddenOrTemp(identity, home: h)
            let quiet = yourClick && !hiddenProgram
            add(
                "privacy-granted", quiet ? .medium : .high,
                quiet
                    ? "\(label) was given to \(identity). If that wasn't you, switch it off in Privacy & Security"
                    : "\(label) was given to \(identity) without your click, or to a program in a hidden folder",
                [identity, actor.map { "Changed by: \($0.path)" }], by: quiet || byMacOS ? nil : actor)

        case "profile_add":
            let name = f["profile.display_name"] ?? f["profile.identifier"] ?? "a profile"
            let managed = f["profile.install_source"] == "0"
            add(
                "profile-added", managed ? .low : .medium,
                managed ? "Your organisation's management installed a profile: \(name)" : "A configuration profile was installed: \(name)",
                [
                    f["profile.identifier"], f["profile.organization"].map { "From: \($0)" },
                    managed ? nil : "See what it can do: sudo macx persist",
                ], by: nil)

        case "od_create_user" where ok:
            add(
                "account-created", .high, "A new user account was created: \(f["user_name"] ?? "?")", [f["node_name"]],
                by: byMacOS ? nil : actor)

        case "od_delete_user" where ok:
            add(
                "account-deleted", .high, "A user account was deleted: \(f["user_name"] ?? "?")", [f["node_name"]],
                by: byMacOS ? nil : actor)

        case "od_group_add" where ok && f["group_name"] == "admin":
            let who = f["member.member_value.name"] ?? f["member.member_value.uuid"] ?? "?"
            add(
                "account-made-admin", byMacOS ? .high : .critical, "An account was made an administrator: \(who)",
                [who, actor.map { "By: \($0.path)" }], by: byMacOS ? nil : actor)

        case "od_modify_password" where ok:
            add(
                "password-changed", byMacOS ? .medium : .high,
                byMacOS
                    ? "The password of \(f["account_name"] ?? "an account") was changed. If that wasn't you, change it again now"
                    : "A program changed the password of \(f["account_name"] ?? "an account")",
                [actor.map { "By: \($0.path)" }], by: byMacOS ? nil : actor)

        case "gatekeeper_user_override":
            let path = f["file.file.path"] ?? f["file.file_path"] ?? f.first { $0.key.hasSuffix("path") }?.value ?? "?"
            let hash = f["sha256"]?.lowercased()
            if let hash, let feed, let known = try? feed.lookup(sha256: hash) {
                add(
                    "gatekeeper-override", .critical, "You opened known malware past Gatekeeper: \(known)", [path, "SHA-256 \(hash)"],
                    by: nil)
            } else {
                add(
                    "gatekeeper-override", .medium,
                    "Gatekeeper's block was overridden (Open Anyway). Stealer installers ask you to do exactly this",
                    [path, hash.map { "SHA-256 \($0)" }, "Check it: macx check \(path)"], by: nil)
            }

        case "remote_thread_create":
            guard let injector = e.process, !injector.isPlatform else { break }
            let target = e.target?.path ?? "another program"
            add(
                "code-injection", injector.isUnsignedThirdParty ? .critical : .high,
                "A program started code inside \((target as NSString).lastPathComponent)",
                [target, "Injected by: \(injector.path)"], by: injector)

        case "screensharing_attach" where f["success"] == "true":
            add(
                "screen-sharing", .high, "Someone connected to your screen from \(f["source_address"] ?? "somewhere")",
                [
                    f["source_address"], f["authentication_username"].map { "Signed in as: \($0)" },
                    f["viewer_appleid"].map { "Apple Account: \($0)" },
                ], by: nil)

        case "openssh_login" where f["success"] == "true":
            add(
                "ssh-login", .medium, "SSH login as \(f["username"] ?? "?") from \(f["source_address"] ?? "?")",
                [f["source_address"]], by: nil)

        default:
            break
        }
        return out
    }
}
