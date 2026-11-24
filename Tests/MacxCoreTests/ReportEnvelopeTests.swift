import CryptoKit
import Foundation
import Testing

@testable import MacxCore

@Suite("Bug report: encryption to the maintainer's key")
struct ReportEnvelopeTests {
    let secret = Curve25519.KeyAgreement.PrivateKey()
    var key: ReportKey { ReportKey(id: 1, publicKey: secret.publicKey) }

    @Test func sealsAndOpensWithTheRightKey() throws {
        let text = Data("Macximesed bug report (format 1)\nhello".utf8)
        let sealed = try ReportEnvelope.seal(text, to: key)
        #expect(sealed.prefix(4) == Data("MXR1".utf8))
        #expect(sealed[4] == 1)  // key id, so the key can be rotated
        #expect(sealed.count == 4 + 1 + 32 + text.count + 16)  // header, encapsulated key, ciphertext, tag
        #expect(sealed.range(of: Data("hello".utf8)) == nil)  // nothing readable in it
        #expect(try ReportEnvelope.open(sealed, with: secret, id: 1) == text)
    }

    @Test func aWrongKeyOrAChangedByteFails() throws {
        let sealed = try ReportEnvelope.seal(Data("x".utf8), to: key)
        #expect(throws: (any Error).self) { try ReportEnvelope.open(sealed, with: Curve25519.KeyAgreement.PrivateKey(), id: 1) }
        var flipped = sealed
        flipped[flipped.count - 1] ^= 1
        #expect(throws: (any Error).self) { try ReportEnvelope.open(flipped, with: secret, id: 1) }
        var otherID = sealed
        otherID[4] = 2  // the header is authenticated too
        #expect(throws: (any Error).self) { try ReportEnvelope.open(otherID, with: secret, id: 1) }
        #expect(throws: ReportEnvelope.Problem.notAReport) { try ReportEnvelope.open(Data("junk".utf8), with: secret, id: 1) }
    }

    @Test func keysAreReadFromBase64() throws {
        let b64 = secret.publicKey.rawRepresentation.base64EncodedString()
        let k = try #require(ReportKey(id: 3, base64: b64))
        #expect(k.publicKey.rawRepresentation == secret.publicKey.rawRepresentation)
        #expect(ReportKey(id: 3, base64: "not a key") == nil)
    }

    /// Until the maintainer sets up the relay and key, sending is off and the app and CLI say so.
    @Test func sendingNeedsBothTheEndpointAndTheKey() {
        #expect(!ReportSending(endpoint: nil, key: key).isAvailable)
        #expect(!ReportSending(endpoint: URL(string: "https://relay.example/report"), key: nil).isAvailable)
        #expect(!ReportSending(endpoint: URL(string: "http://relay.example/report"), key: key).isAvailable)  // https only
        #expect(ReportSending(endpoint: URL(string: "https://relay.example/report"), key: key).isAvailable)
    }

    @Test func theRelaysAnswerGivesTheReportID() {
        #expect(
            ReportSending.reportID(from: Data(#"{"id":"0b7c3f1e-0000-4000-8000-000000000000"}"#.utf8))
                == "0b7c3f1e-0000-4000-8000-000000000000")
        #expect(ReportSending.reportID(from: Data(#"{"id":"<script>"}"#.utf8)) == nil)  // only an ID-shaped answer is shown
        #expect(ReportSending.reportID(from: Data("oops".utf8)) == nil)
    }
}
