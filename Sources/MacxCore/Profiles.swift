import Darwin
import Foundation

/// What a configuration profile can do to the Mac, from its payload types. Since macOS 11 a profile can
/// only be installed through System Settings (the user approves it) or by an MDM, so malware that wants one
/// has to talk the user into it, as ChromeLoader and AdLoad did for forced browser extensions and proxies.
public enum ProfileCapability: String, Codable, Sendable, CaseIterable, Comparable {
    case trustsCertificate, proxy, browserPolicy, privacyGrants, gatekeeper, dns, vpn, contentFilter, loginItems

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var rule: String {
        switch self {
        case .trustsCertificate: "profile-trusts-certificate"
        case .proxy: "profile-proxy"
        case .browserPolicy: "profile-browser-policy"
        case .privacyGrants: "profile-privacy-grants"
        case .gatekeeper: "profile-gatekeeper"
        case .dns: "profile-dns"
        case .vpn: "profile-vpn"
        case .contentFilter: "profile-content-filter"
        case .loginItems: "profile-login-items"
        }
    }

    public var severity: Severity {
        switch self {
        case .trustsCertificate, .proxy, .browserPolicy, .privacyGrants, .gatekeeper: .high
        case .dns, .vpn, .contentFilter, .loginItems: .medium
        }
    }

    public var title: String {
        switch self {
        case .trustsCertificate: "Profile adds a trusted certificate: whoever holds its key can read and change your HTTPS traffic"
        case .proxy: "Profile sends your web traffic through a proxy"
        case .browserPolicy: "Profile forces browser settings or extensions (how ChromeLoader-style adware stays installed)"
        case .privacyGrants: "Profile grants privacy permissions (Full Disk Access, screen recording and so on) to apps"
        case .gatekeeper: "Profile changes Gatekeeper, the check that blocks unsigned apps"
        case .dns: "Profile sets which DNS server looks up every website"
        case .vpn: "Profile sets up a VPN"
        case .contentFilter: "Profile installs a web content filter that sees your traffic"
        case .loginItems: "Profile manages login items and background tasks"
        }
    }

    static let browserDomains: Set<String> = [
        "com.google.Chrome", "com.microsoft.Edge", "com.brave.Browser", "org.mozilla.firefox", "com.apple.Safari",
        "com.operasoftware.Opera", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]

    public static func of(payload p: [String: Any]) -> Set<ProfileCapability> {
        let type = p["PayloadType"] as? String ?? ""
        var out: Set<ProfileCapability> = []
        switch type {
        case "com.apple.security.root", "com.apple.security.pem", "com.apple.security.pkcs1": out.insert(.trustsCertificate)
        case "com.apple.proxy.http.global": out.insert(.proxy)
        case "com.apple.TCC.configuration-profile-policy": out.insert(.privacyGrants)
        case "com.apple.systempolicy.control", "com.apple.systempolicy.managed": out.insert(.gatekeeper)
        case "com.apple.dnsSettings.managed", "com.apple.dnsProxy.managed": out.insert(.dns)
        case "com.apple.vpn.managed", "com.apple.vpn.managed.applayer": out.insert(.vpn)
        case "com.apple.webcontent-filter": out.insert(.contentFilter)
        case "com.apple.servicemanagement", "com.apple.loginitems.managed": out.insert(.loginItems)
        case "com.apple.ManagedClient.preferences":
            if let domains = p["PayloadContent"] as? [String: Any], domains.keys.contains(where: browserDomains.contains) {
                out.insert(.browserPolicy)
            }
        default:
            if browserDomains.contains(type) { out.insert(.browserPolicy) }
        }
        // Proxies can also ride inside network payloads (Wi-Fi, Ethernet, SystemConfiguration).
        if p["Proxies"] != nil || p["ProxyServer"] != nil || p["ProxyPACURL"] != nil
            || ((p["ProxyType"] as? String).map { $0.lowercased() != "none" } ?? false)
        {
            out.insert(.proxy)
        }
        return out
    }
}

public enum ProfileScope: Sendable, Equatable {
    case computer
    case user(String)
}

public struct ConfigurationProfile: Sendable, Equatable {
    public var scope: ProfileScope
    public var identifier: String
    public var name: String
    public var organization: String?
    public var uuid: String?
    public var installDate: String?
    /// "verified", "unsigned" and so on, as `profiles` reports it.
    public var verification: String?
    public var payloadTypes: [String]
    public var capabilities: Set<ProfileCapability>
}

/// Installed configuration profiles, from `profiles show -output stdout-xml`. As root that covers the
/// computer level and every user; without root, only the current user's.
public enum ConfigurationProfiles {
    public struct Scan: Sendable {
        public var profiles: [ConfigurationProfile]
        public var managedByMDM: Bool
        public var note: String?
    }

    public static func parse(_ data: Data) throws -> [ConfigurationProfile] {
        guard let top = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var out: [ConfigurationProfile] = []
        for (level, value) in top.sorted(by: { $0.key < $1.key }) {
            let scope: ProfileScope = level.lowercased() == "_computerlevel" ? .computer : .user(level)
            for p in value as? [[String: Any]] ?? [] {
                guard let id = p["ProfileIdentifier"] as? String else { continue }
                let payloads = p["ProfileItems"] as? [[String: Any]] ?? []
                out.append(
                    ConfigurationProfile(
                        scope: scope, identifier: id, name: p["ProfileDisplayName"] as? String ?? id,
                        organization: p["ProfileOrganization"] as? String, uuid: p["ProfileUUID"] as? String,
                        installDate: (p["ProfileInstallDate"] as? String) ?? (p["ProfileInstallDate"] as? Date).map { "\($0)" },
                        verification: p["ProfileVerificationState"] as? String,
                        payloadTypes: payloads.compactMap { $0["PayloadType"] as? String },
                        capabilities: payloads.reduce(into: []) { $0.formUnion(ProfileCapability.of(payload: $1)) }))
            }
        }
        return out
    }

    public static func items(_ profiles: [ConfigurationProfile], managedByMDM: Bool) -> [PersistenceItem] {
        profiles.map { p in
            let path: String
            switch p.scope {
            case .computer: path = "profile:\(p.identifier)"
            case .user(let u): path = "profile:\(u)/\(p.identifier)"
            }
            let detail = [
                p.organization.map { "From: \($0)" }, p.installDate.map { "Installed: \($0)" }, p.verification.map { "Signature: \($0)" },
                "Payloads: \(p.payloadTypes.joined(separator: ", "))",
            ].compactMap { $0 }.joined(separator: "\n")
            let fingerprint = ([p.identifier, p.uuid ?? "", p.verification ?? ""] + p.payloadTypes.sorted()).joined(separator: "|")
            var item = PersistenceItem(
                kind: .configurationProfile, path: path, label: p.name, program: nil, arguments: [],
                runsAsRoot: p.scope == .computer, runAtLoad: true, keepAlive: false, signature: nil, teamID: nil,
                contentHash: sha256(Data(fingerprint.utf8)), detail: detail)
            item.profileCapabilities = p.capabilities.sorted()
            item.managedByMDM = managedByMDM
            return item
        }
    }

    public static func current(runner: CommandRunner = ProcessRunner(timeout: 20), isRoot: Bool = geteuid() == 0) -> Scan {
        let status = (try? runner.run("/usr/bin/profiles", ["status", "-type", "enrollment"])) ?? ""
        let mdm = status.split(separator: "\n").contains { $0.hasPrefix("MDM enrollment: Yes") }
        let args = isRoot ? ["show", "-all", "-output", "stdout-xml"] : ["show", "-output", "stdout-xml"]
        let note = isRoot ? nil : "only your own configuration profiles were checked; computer-wide ones need sudo: sudo macx persist"
        do {
            let profiles = try parse(Data(try runner.run("/usr/bin/profiles", args).utf8))
            return Scan(profiles: profiles, managedByMDM: mdm, note: note)
        } catch {
            return Scan(profiles: [], managedByMDM: mdm, note: "configuration profiles couldn't be listed (\(error)).")
        }
    }
}
