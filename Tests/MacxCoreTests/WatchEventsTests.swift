import Foundation
import Testing

@testable import MacxCore

/// The events added after the first five, in the layout of Apple's ESMessage.h (eslogger's JSON follows it).
@Suite("Live watch: XProtect, privacy, accounts, remote access")
struct WatchEventsTests {
    let rules = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: [:]))
    let settings = proc("/System/Applications/System Settings.app/Contents/MacOS/System Settings", pid: 300, platform: true)
    let xprotect = proc("/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect", pid: 77, platform: true)
    let stranger = proc("/Users/v/Library/Application Support/.helper/run", pid: 900, platform: false)
    let signedApp = proc("/Applications/Tool.app/Contents/MacOS/Tool", pid: 950, platform: false, team: "ABCDE12345")

    func alerts(_ name: String, by process: String, _ body: String) -> [WatchAlert] {
        rules.evaluate(ESEvent.parse(event(name, process: process, body: body))!)
    }

    // MARK: XProtect

    @Test func xprotectFindingMalwareIsCriticalAndFreezesNothing() throws {
        let a = alerts(
            "xp_malware_detected", by: xprotect,
            #"{"signature_version":"5300","malware_identifier":"MACOS.AMOS.A","incident_identifier":"X1","detected_path":"/Users/v/Downloads/Installer.app","detected_executable":"/Users/v/Downloads/Installer.app/Contents/MacOS/Installer"}"#
        )
        let x = try #require(a.first { $0.rule == "xprotect-detected" })
        #expect(x.severity == .critical)
        #expect(x.title.contains("MACOS.AMOS.A"))
        #expect(x.detail?.hasPrefix("/Users/v/Downloads/Installer.app") == true)  // first line: the file, for the case
        #expect(x.pid == nil)  // XProtect itself is never frozen
    }

    @Test func xprotectRemovingItIsHighAndFailingIsCritical() {
        let ok = alerts(
            "xp_malware_remediated", by: xprotect,
            #"{"malware_identifier":"MACOS.AMOS.A","action_type":"path_delete","success":true,"remediated_path":"/Users/v/.x/loader"}"#)
        #expect(ok.first?.rule == "xprotect-remediated")
        #expect(ok.first?.severity == .high)
        #expect(ok.first?.pid == nil)
        let failed = alerts(
            "xp_malware_remediated", by: xprotect,
            #"{"malware_identifier":"MACOS.AMOS.A","success":false,"result_description":"busy","remediated_path":"/Users/v/.x/loader"}"#)
        #expect(failed.first?.severity == .critical)
    }

    // MARK: Privacy permissions

    func tcc(
        _ service: String, identity: String, identityType: Int = 0, update: Int = 1, right: Int = 2, reason: Int = 3, by process: String
    )
        -> [WatchAlert]
    {
        alerts(
            "tcc_modify", by: process,
            #"{"service":"\#(service)","identity":"\#(identity)","identity_type":\#(identityType),"update_type":\#(update),"right":\#(right),"reason":\#(reason),"instigator":\#(process)}"#
        )
    }

    @Test func youGrantingFullDiskAccessIsMedium() {
        let a = tcc("kTCCServiceSystemPolicyAllFiles", identity: "dev.macximesed.macx", by: settings)
        #expect(a.first?.rule == "privacy-granted")
        #expect(a.first?.severity == .medium)
        #expect(a.first?.title.contains("Full Disk Access") == true)
        #expect(a.first?.detail?.contains("dev.macximesed.macx") == true)
    }

    @Test func aProgramGrantingAccessWithoutYourClickIsHigh() {
        let a = tcc("kTCCServiceAccessibility", identity: "com.evil.helper", reason: 4, by: stranger)
        #expect(a.first?.severity == .high)
    }

    @Test func accessForSomethingInAHiddenFolderIsHigh() {
        let a = tcc(
            "kTCCServiceScreenCapture", identity: "/Users/v/Library/Application Support/.helper/run", identityType: 1, by: settings)
        #expect(a.first?.severity == .high)
    }

    @Test func takingAccessAwayOrOtherServicesSayNothing() {
        #expect(tcc("kTCCServiceSystemPolicyAllFiles", identity: "x", right: 0, by: settings).isEmpty)  // denied
        #expect(tcc("kTCCServiceSystemPolicyAllFiles", identity: "x", update: 3, by: settings).isEmpty)  // deleted
        #expect(tcc("kTCCServiceCamera", identity: "us.zoom.xos", by: settings).isEmpty)
        #expect(tcc("ListenEvent", identity: "com.x", by: settings).first?.title.contains("Input Monitoring") == true)
    }

    // MARK: Profiles

    @Test func aProfileInstalledByHandIsMediumAndByMDMLow() {
        let byHand = alerts(
            "profile_add", by: settings,
            #"{"is_update":false,"profile":{"identifier":"com.x.policy","uuid":"U","install_source":1,"organization":"X","display_name":"Browser Helper","scope":"System"}}"#
        )
        #expect(byHand.first?.rule == "profile-added")
        #expect(byHand.first?.severity == .medium)
        #expect(byHand.first?.detail?.contains("sudo macx persist") == true)
        let mdm = alerts(
            "profile_add", by: settings,
            #"{"is_update":false,"profile":{"identifier":"com.corp","install_source":0,"display_name":"Corp","scope":"System"}}"#)
        #expect(mdm.first?.severity == .low)
    }

    // MARK: Accounts

    @Test func newUsersAndDeletedUsersAreHigh() {
        #expect(
            alerts("od_create_user", by: settings, #"{"error_code":0,"user_name":"support","node_name":"/Local/Default"}"#).first?.severity
                == .high)
        #expect(
            alerts("od_delete_user", by: settings, #"{"error_code":0,"user_name":"v","node_name":"/Local/Default"}"#).first?.severity
                == .high)
        // Failed attempts (error_code set) are left alone.
        #expect(alerts("od_create_user", by: settings, #"{"error_code":5000,"user_name":"x"}"#).isEmpty)
    }

    func adminAdd(by process: String) -> [WatchAlert] {
        alerts(
            "od_group_add", by: process,
            #"{"error_code":0,"group_name":"admin","member":{"member_type":0,"member_value":{"name":"support"}},"node_name":"/Local/Default","instigator":\#(process)}"#
        )
    }

    @Test func aNewAdminIsHighFromSettingsAndCriticalFromAStranger() throws {
        let fromSettings = try #require(adminAdd(by: settings).first)
        #expect(fromSettings.rule == "account-made-admin")
        #expect(fromSettings.severity == .high)
        #expect(fromSettings.detail?.contains("support") == true)
        let fromStranger = try #require(adminAdd(by: stranger).first)
        #expect(fromStranger.severity == .critical)
        #expect(fromStranger.pid == 900)  // the program that did it is the one frozen
    }

    @Test func otherGroupsArentAlerts() {
        let a = alerts(
            "od_group_add", by: settings,
            #"{"error_code":0,"group_name":"_lpadmin","member":{"member_type":0,"member_value":{"name":"v"}}}"#)
        #expect(a.isEmpty)
    }

    @Test func passwordChangesAreMediumFromMacOSAndHighOtherwise() {
        let body = #"{"error_code":0,"account_type":0,"account_name":"v","node_name":"/Local/Default"}"#
        #expect(alerts("od_modify_password", by: settings, body).first?.severity == .medium)
        #expect(alerts("od_modify_password", by: stranger, body).first?.severity == .high)
    }

    // MARK: Gatekeeper, injection, remote access

    @Test func openAnywayIsMediumAndCriticalForKnownMalware() throws {
        let hex = String(repeating: "ab", count: 32)
        let body = #"{"file_type":1,"file":{"file":{"path":"/Users/v/Downloads/Setup.app"}},"sha256":"\#(hex)"}"#
        let plain = alerts("gatekeeper_user_override", by: settings, body)
        #expect(plain.first?.rule == "gatekeeper-override")
        #expect(plain.first?.severity == .medium)
        #expect(plain.first?.detail?.hasPrefix("/Users/v/Downloads/Setup.app") == true)

        let feed = try HashFeed.parse(
            Data(#"{"schema":1,"generated":"2026-11-24T00:00:00Z","entries":[{"sha256":"\#(hex)","family":"AMOS","source":"t"}]}"#.utf8))
        let known = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: [:]), feed: feed)
            .evaluate(ESEvent.parse(event("gatekeeper_user_override", process: settings, body: body))!)
        #expect(known.first?.severity == .critical)
        #expect(known.first?.title.contains("AMOS") == true)
    }

    @Test func openAnywayReadsAHashGivenAsBytes() {
        let bytes = Array(repeating: "171", count: 32).joined(separator: ",")
        let body = #"{"file_type":0,"file":{"file_path":"/Users/v/Downloads/x.app"},"sha256":[\#(bytes)]}"#
        let a = alerts("gatekeeper_user_override", by: settings, body)
        #expect(a.first?.detail?.contains(String(repeating: "ab", count: 32)) == true)
        #expect(a.first?.detail?.hasPrefix("/Users/v/Downloads/x.app") == true)
    }

    @Test func codeInjectionIsCriticalForUnsignedHighForSignedAndQuietForApple() {
        let target = proc("/Applications/Safari.app/Contents/MacOS/Safari", pid: 400, platform: true)
        let body = #"{"target":\#(target)}"#
        let unsigned = alerts("remote_thread_create", by: stranger, body)
        #expect(unsigned.first?.rule == "code-injection")
        #expect(unsigned.first?.severity == .critical)
        #expect(unsigned.first?.pid == 900)
        #expect(unsigned.first?.detail?.contains("Safari") == true)
        #expect(alerts("remote_thread_create", by: signedApp, body).first?.severity == .high)
        #expect(alerts("remote_thread_create", by: settings, body).isEmpty)
    }

    @Test func screenSharingIsHighAndSSHLoginsMedium() {
        let share = alerts(
            "screensharing_attach", by: settings,
            #"{"success":true,"source_address_type":1,"source_address":"203.0.113.9","authentication_type":"password","authentication_username":"v","session_username":"v","existing_session":true}"#
        )
        #expect(share.first?.rule == "screen-sharing")
        #expect(share.first?.severity == .high)
        #expect(share.first?.detail?.contains("203.0.113.9") == true)
        #expect(share.first?.pid == nil)
        #expect(alerts("screensharing_attach", by: settings, #"{"success":false,"source_address":"203.0.113.9"}"#).isEmpty)

        let ssh = alerts(
            "openssh_login", by: settings, #"{"success":true,"result_type":0,"source_address":"100.101.1.2","username":"v","has_uid":true}"#
        )
        #expect(ssh.first?.rule == "ssh-login")
        #expect(ssh.first?.severity == .medium)
        #expect(alerts("openssh_login", by: settings, #"{"success":false,"source_address":"1.2.3.4","username":"root"}"#).isEmpty)
    }

    @Test func theWatchSubscribesToTheNewEvents() {
        for e in [
            "xp_malware_detected", "xp_malware_remediated", "tcc_modify", "profile_add", "od_create_user", "od_delete_user",
            "od_group_add", "od_modify_password", "gatekeeper_user_override", "remote_thread_create", "screensharing_attach",
            "openssh_login",
        ] {
            #expect(WatchRules.events.contains(e), "\(e)")
        }
        #expect(!WatchRules.events.contains("open"))
    }
}

@Suite("Only events this Mac's eslogger knows")
struct SupportedEventsTests {
    @Test func unknownEventsAreLeftOutSoEsloggerStillStarts() {
        // macOS 15.0 has no tcc_modify; asking for it would stop eslogger from starting at all.
        let listed = "exec\ncreate\nrename\ndeleteextattr\nbtm_launch_item_add\nxp_malware_detected\nopenssh_login\n"
        let picked = WatchRules.supportedEvents(listOutput: listed)
        #expect(picked == ["exec", "create", "rename", "deleteextattr", "btm_launch_item_add", "xp_malware_detected", "openssh_login"])
    }

    @Test func noListMeansTheOriginalFive() {
        #expect(WatchRules.supportedEvents(listOutput: nil) == ["exec", "create", "rename", "deleteextattr", "btm_launch_item_add"])
        #expect(WatchRules.supportedEvents(listOutput: "") == ["exec", "create", "rename", "deleteextattr", "btm_launch_item_add"])
    }

    @Test func theRealListOnThisMacHasTheBasics() {
        let out = ProcessRunner.capture("/usr/bin/eslogger", ["--list-events"])?.stdout
        let picked = WatchRules.supportedEvents(listOutput: out)
        #expect(picked.starts(with: ["exec", "create", "rename", "deleteextattr", "btm_launch_item_add"]))
    }
}
