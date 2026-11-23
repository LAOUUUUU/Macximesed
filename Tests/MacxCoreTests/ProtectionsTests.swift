import Testing
@testable import MacxCore

@Suite("Protection status parsing")
struct ProtectionsTests {
    @Test func sipEnabled() {
        #expect(Protections.parseSIP("System Integrity Protection status: enabled.\n") == .on)
    }

    @Test func sipDisabled() {
        #expect(Protections.parseSIP("System Integrity Protection status: disabled.\n") == .off)
    }

    @Test func sipCustomConfigurationCountsAsPartial() {
        let out = """
        System Integrity Protection status: unknown (Custom Configuration).

        Configuration:
        \tFilesystem Protections: disabled
        """
        #expect(Protections.parseSIP(out) == .partial)
    }

    @Test func gatekeeper() {
        #expect(Protections.parseGatekeeper("assessments enabled\n") == .on)
        #expect(Protections.parseGatekeeper("assessments disabled\n") == .off)
    }

    @Test func fileVault() {
        #expect(Protections.parseFileVault("FileVault is On.\n") == .on)
        #expect(Protections.parseFileVault("FileVault is Off.\n") == .off)
        #expect(Protections.parseFileVault("Encryption in progress: Percent completed = 40\n") == .partial)
    }

    @Test func firewall() {
        #expect(Protections.parseFirewall("Firewall is enabled. (State = 1)\n") == .on)
        #expect(Protections.parseFirewall("Firewall is enabled. (State = 2)\n") == .on)
        #expect(Protections.parseFirewall("Firewall is disabled. (State = 0)\n") == .off)
    }

    @Test func garbageIsUnknown() {
        #expect(Protections.parseSIP("") == .unknown)
        #expect(Protections.parseGatekeeper("weird") == .unknown)
        #expect(Protections.parseFileVault("") == .unknown)
        #expect(Protections.parseFirewall("") == .unknown)
    }

    @Test func checkUsesRunnerAndMarksFailuresUnknown() throws {
        let runner = FakeRunner(outputs: [
            "/usr/bin/csrutil": "System Integrity Protection status: enabled.\n",
            "/usr/sbin/spctl": "assessments enabled\n",
            "/usr/bin/fdesetup": "FileVault is On.\n",
        ])
        let p = Protections.check(using: runner)
        #expect(p.sip == .on)
        #expect(p.gatekeeper == .on)
        #expect(p.fileVault == .on)
        #expect(p.firewall == .unknown)
    }
}

struct FakeRunner: CommandRunner {
    var outputs: [String: String]
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        guard let out = outputs[executable] else { throw CommandError.failed(executable, 1) }
        return out
    }
}
