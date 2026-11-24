import CryptoKit
import Foundation

// Sending a bug report: the report text is encrypted on the Mac to the maintainer's public key (HPKE, RFC 9180),
// then posted to a small relay that forwards the opaque file to a private channel. The relay and the channel only
// ever see ciphertext. Design: research/diagnostics-beta/RESEARCH.md.

/// The maintainer's report key. The id byte goes into every report, so the key can be replaced later.
public struct ReportKey: Sendable, Equatable {
    public var id: UInt8
    public var raw: Data

    public var publicKey: Curve25519.KeyAgreement.PublicKey {
        // `raw` is only ever set from a valid key (the initialisers check), so this can't fail.
        try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    public init(id: UInt8, publicKey: Curve25519.KeyAgreement.PublicKey) {
        self.id = id
        raw = publicKey.rawRepresentation
    }

    public init?(id: UInt8, base64: String) {
        guard let data = Data(base64Encoded: base64), let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        else { return nil }
        self.init(id: id, publicKey: key)
    }

    /// Not set up yet: Lao makes the key pair (`macx report-keygen`) and the public half goes here.
    public static let current: ReportKey? = nil
}

/// `MXR1 | key id | encapsulated key (32 bytes) | ciphertext`. The first five bytes are authenticated too.
public enum ReportEnvelope {
    public enum Problem: Error, Equatable { case notAReport, wrongKey }

    static let magic = Data("MXR1".utf8)
    static let info = Data("macx-report-v1".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    public static func seal(_ plaintext: Data, to key: ReportKey) throws -> Data {
        var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: suite, info: info)
        let header = magic + Data([key.id])
        let ciphertext = try sender.seal(plaintext, authenticating: header)
        return header + sender.encapsulatedKey + ciphertext
    }

    public static func open(_ envelope: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey, id: UInt8) throws -> Data {
        let e = Data(envelope)  // indices from 0
        guard e.count > 5 + 32 + 16, e.prefix(4) == magic else { throw Problem.notAReport }
        guard e[4] == id else { throw Problem.wrongKey }
        var recipient = try HPKE.Recipient(
            privateKey: privateKey, ciphersuite: suite, info: info, encapsulatedKey: e.subdata(in: 5..<37))
        return try recipient.open(e.subdata(in: 37..<e.count), authenticating: e.prefix(5))
    }
}

/// Posting a sealed report to the relay. Off until both the relay address and the key are built in.
public struct ReportSending: Sendable {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notSetUp
        case failed(String)
        public var description: String {
            switch self {
            case .notSetUp: "sending isn't set up in this version yet: save or copy the report instead"
            case .failed(let m): "the report couldn't be sent (\(m)); nothing was kept anywhere, so you can try again"
            }
        }
    }

    /// Not set up yet: the relay's https address goes here once it's live.
    public static let defaultEndpoint: URL? = nil

    public var endpoint: URL?
    public var key: ReportKey?

    public init(endpoint: URL? = ReportSending.defaultEndpoint, key: ReportKey? = ReportKey.current) {
        self.endpoint = endpoint
        self.key = key
    }

    public var isAvailable: Bool { endpoint?.scheme == "https" && key != nil }

    /// The relay answers `{"id": "<uuid>"}`. Only an ID-shaped answer is passed on to be shown.
    public static func reportID(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? String,
            id.range(of: "^[0-9a-fA-F-]{8,64}$", options: .regularExpression) != nil
        else { return nil }
        return id
    }

    /// Encrypts and posts the exact report text; returns the report ID to show. Nothing is stored on this Mac.
    public func send(_ text: String, timeout: TimeInterval = 30) throws -> String {
        guard isAvailable, let endpoint, let key else { throw Problem.notSetUp }
        let body = try ReportEnvelope.seal(Data(text.utf8), to: key)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        let session = URLSession(configuration: config)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("macx", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        nonisolated(unsafe) var result: Result<String, Problem> = .failure(.failed("no answer"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, (200..<300).contains(status), let id = Self.reportID(from: data) {
                result = .success(id)
            } else {
                result = .failure(.failed(error?.localizedDescription ?? "HTTP \(status)"))
            }
            done.signal()
        }.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return try result.get()
    }
}
