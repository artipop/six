import CryptoKit
import Foundation
import Observation
@preconcurrency import Security

/// One certificate six has been told about: the bytes, and enough of what is inside them to put a
/// line on the screen.
nonisolated struct TrustedCertificate: Identifiable, Sendable, Hashable {
    /// The SHA-256 of the DER — the number a certificate authority publishes so that what you
    /// downloaded can be checked against what it meant to publish. It is the identity here too: the
    /// same certificate arriving twice is one row, whatever the file it came in was called.
    let fingerprint: String
    /// The certificate itself, as it is on the wire. `SecCertificate` is not `Sendable` and is not
    /// worth making so — it is three lines to build one from these bytes at the moment of use.
    let der: Data
    /// `SecCertificateCopySubjectSummary`: the common name, or the closest thing this certificate has.
    let name: String
    let notBefore: Date?
    let notAfter: Date?

    var id: String { fingerprint }

    /// A certificate authority's own certificate outlives most things and then does not. An expired
    /// anchor is not an error — nothing breaks by leaving it switched on — but it has stopped
    /// working, and the list should say so rather than let it look like the site's fault.
    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    /// `AB CD EF …`, which is how every authority prints it and therefore how it can be compared.
    var readableFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 2)
            .map { offset -> String in
                let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
                let end = fingerprint.index(start, offsetBy: 2, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
                return String(fingerprint[start..<end]).uppercased()
            }
            .joined(separator: " ")
    }

    init?(der: Data) {
        guard !der.isEmpty,
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        self.der = der
        fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? String(localized: "Certificate")
        let validity = CertificateValidity(der: der)
        notBefore = validity?.notBefore
        notAfter = validity?.notAfter
    }
}

/// Certificates switched on and off as one: a root with the intermediates published beside it, or a
/// single file somebody imported. The bundle is the unit because that is the unit an authority
/// hands out and the unit a person decides about — nobody wants to reason about four rows.
nonisolated struct CertificateBundle: Identifiable, Sendable {
    let id: String
    let name: String
    /// One line under the name: who this is and what it is for.
    let detail: String
    /// Where these certificates are published, so the fingerprints above can be checked against
    /// their source rather than against six.
    let source: URL?
    let certificates: [TrustedCertificate]
    /// Shipped with six (see `BundledCertificates`). It is in the list before anyone adds anything,
    /// and it can be switched off but not removed — there is no file to delete.
    let isBuiltIn: Bool
    /// The file under `Certificates/` an imported bundle was read from.
    let file: URL?
}

/// The certificate authorities six will trust **in addition to** the ones the system already
/// trusts — none of them, until somebody says otherwise.
///
/// ## Why this exists
///
/// A browser trusts what the operating system trusts, and that is the right default: the store
/// Apple ships is audited, watched, and updated without six being involved. But it is not the whole
/// web. Some sites are served under a certificate from an authority the system has never heard of —
/// Russian banks under the Ministry of Digital Development's CA are the case this was written for —
/// and to a browser those are indistinguishable from an attack. Every other browser answers this
/// the same way: it lets the person say "and this one too".
///
/// Apple's own answer is the keychain: import the certificate, find it in Keychain Access, open it,
/// open the trust triangle, set *Secure Sockets Layer* to Always Trust, and type your password.
/// That works, and it changes what **every** app on the machine trusts, forever, with nothing to
/// look at afterwards. six keeps the decision inside six instead: a list you can read, a switch per
/// entry, and a certificate that stops mattering the moment it is switched off.
///
/// ## What being switched on does
///
/// Less than the keychain does, on purpose. An anchor here is not consulted while a chain is
/// checking out normally — `decide(_:)` lets the system judge the chain first, untouched, and only
/// when the system says no does it ask the same question again with these certificates *added* to
/// the system's. So switching one on cannot make an ordinary site validate differently; it can only
/// give a chain that had already failed a second reading. That is a smaller promise than "trusted",
/// and it is the one worth making.
///
/// There is no build flag for this. A "Russian build" would mean two binaries, one of which trusts
/// something the other does not without saying so, and the interesting half of that question —
/// *does this person want it* — cannot be answered at compile time anyway. One build, one list,
/// everything off until asked.
///
/// See [certificates.md](../../docs/certificates.md).
@MainActor
@Observable
final class CertificateStore {
    /// The one instance. Anchors are not per-profile and not per-window — they are what *six*
    /// trusts — and the two places that ask are a navigation decider built deep inside
    /// `BrowserTab.materialize()` and a `URLSession` delegate that lives off the main actor.
    /// Threading a reference down to both would say less about the thing than this does.
    static var shared: CertificateStore?

    /// Every bundle six knows about: the ones it ships, then the ones that were imported.
    private(set) var bundles: [CertificateBundle] = []
    /// Which of them are switched on, by bundle id. Persisted; the certificates themselves are not
    /// stored here — a built-in bundle is in the binary and an imported one is a file on disk.
    private(set) var enabled: Set<String> = []
    /// Sites that would not have loaded without one of these anchors, per bundle, since launch.
    ///
    /// In memory only, and gone when six quits. It exists so the list can answer the question a
    /// person actually has — *is this doing anything?* — without becoming a second history.
    private(set) var usedFor: [String: Set<String>] = [:]

    @ObservationIgnored private let settings: SettingsStore?

    /// Where imported certificates live. One file per bundle, copied in — the file the user picked
    /// may be on a volume that goes away, and a trust decision that stops working when a disk is
    /// unmounted would be a mystery rather than a setting.
    static var folder: URL { AppSupport.folder("Certificates") }

    init(settings: SettingsStore?) {
        self.settings = settings
        enabled = Set(settings?.decode(.trustedCertificates, as: [String].self) ?? [])
        reload()
    }

    // MARK: The list

    /// Reads the built-ins and everything under `Certificates/` again.
    func reload() {
        var found = BundledCertificates.all
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let bundle = Self.read(file) else { continue }
            found.append(bundle)
        }
        bundles = found
        // A bundle whose file was deleted from under us keeps no vote.
        let known = Set(found.map(\.id))
        if !enabled.isSubset(of: known) {
            enabled.formIntersection(known)
            save()
        }
    }

    func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    func setEnabled(_ on: Bool, for id: String) {
        guard on != enabled.contains(id) else { return }
        if on { enabled.insert(id) } else { enabled.remove(id); usedFor[id] = nil }
        save()
    }

    /// The certificates every switched-on bundle carries, as `SecCertificate`. Built on each ask
    /// rather than cached: this is a handful of certificates and it is asked once per failed
    /// handshake, which is not a path anything is waiting on.
    var activeCertificates: [SecCertificate] {
        bundles
            .filter { enabled.contains($0.id) }
            .flatMap(\.certificates)
            .compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) }
    }

    var hasActiveCertificates: Bool {
        bundles.contains { enabled.contains($0.id) && !$0.certificates.isEmpty }
    }

    // MARK: Adding and removing

    enum ImportFailure: LocalizedError {
        case unreadable
        case noCertificates
        case alreadyPresent(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                String(localized: "The file could not be read.")
            case .noCertificates:
                String(localized: "No certificate in this file. six reads PEM (.pem, .crt) and DER (.cer, .der).")
            case .alreadyPresent(let name):
                String(localized: "\(name) is already in the list.")
            }
        }
    }

    /// Copies a certificate file in and switches it on — importing one is already the decision.
    @discardableResult
    func add(contentsOf url: URL) throws -> CertificateBundle {
        // The file may have come from a document picker, which hands back a URL that is readable
        // only inside its scope. Asking on a plain file URL costs nothing and answers false.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportFailure.unreadable }
        let certificates = Self.parse(data)
        guard !certificates.isEmpty else { throw ImportFailure.noCertificates }
        let arriving = Set(certificates.map(\.fingerprint))
        for bundle in bundles where !Set(bundle.certificates.map(\.fingerprint)).isDisjoint(with: arriving) {
            throw ImportFailure.alreadyPresent(bundle.name)
        }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let destination = Self.freeName(for: url.lastPathComponent)
        try data.write(to: destination)
        guard let bundle = Self.read(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportFailure.noCertificates
        }
        bundles.append(bundle)
        enabled.insert(bundle.id)
        save()
        return bundle
    }

    /// Forgets an imported bundle: the switch and the file both. A built-in is switched off instead —
    /// there is nothing to delete, and it will be in the list again next launch either way.
    func remove(_ id: String) {
        guard let bundle = bundles.first(where: { $0.id == id }) else { return }
        guard let file = bundle.file else { return setEnabled(false, for: id) }
        try? FileManager.default.removeItem(at: file)
        bundles.removeAll { $0.id == id }
        enabled.remove(id)
        usedFor[id] = nil
        save()
    }

    private func save() {
        settings?.encode(.trustedCertificates, enabled.sorted(), keepingEmpty: false)
    }

    // MARK: Answering a handshake

    /// WebKit could not make the chain check out and is asking what to do about it.
    ///
    /// The order matters. The system judges first, with its own anchors and nothing added, and if it
    /// is happy the answer is `.performDefaultHandling` — six steps back out and WebKit does
    /// everything it would have done anyway (certificate transparency, its own pinning, the error
    /// page). Only a chain the system has already turned down is asked about again, and then only
    /// with these certificates *added*: `SecTrustSetAnchorCertificatesOnly(_, false)` in
    /// `ServerTrust.retry` is the line that keeps the rest of the web being judged by the rest of
    /// the world.
    ///
    /// A chain that fails both readings also gets `.performDefaultHandling`, which is what puts
    /// WebKit's own failure in front of the person instead of a blank window.
    ///
    /// The cost of that order is one extra trust evaluation per HTTPS connection — and only while
    /// something is switched on, since the guard below leaves an empty list before any work happens.
    /// It is asynchronous, it is off the main actor, and `trustd` caches its answers, which is why
    /// it is worth paying to keep every ordinary site being judged by WebKit alone.
    func decide(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        let anchors = activeCertificates
        guard !anchors.isEmpty else { return (.performDefaultHandling, nil) }
        if await ServerTrust.isTrusted(trust) { return (.performDefaultHandling, nil) }
        guard let accepted = await ServerTrust.retry(trust, host: space.host, adding: anchors) else {
            return (.performDefaultHandling, nil)
        }
        note(space.host)
        return (.useCredential, URLCredential(trust: accepted))
    }

    /// Which switched-on bundle carried the site, for the line under its name. The chain is not
    /// re-walked to find out — a host that needed *any* extra anchor is filed under every bundle
    /// that is on, and with one bundle on (the usual case) that is exactly right.
    private func note(_ host: String) {
        guard !host.isEmpty else { return }
        for bundle in bundles where enabled.contains(bundle.id) {
            usedFor[bundle.id, default: []].insert(host)
        }
    }

    // MARK: Reading files

    /// PEM or DER, one certificate or several. A `.pem` from a certificate authority is usually the
    /// intermediate and the root in one file, and both are wanted.
    static func parse(_ data: Data) -> [TrustedCertificate] {
        var found: [TrustedCertificate] = []
        var seen: Set<String> = []
        for der in pemBlocks(in: data) ?? [data] {
            guard let certificate = TrustedCertificate(der: der), seen.insert(certificate.fingerprint).inserted else { continue }
            found.append(certificate)
        }
        return found
    }

    /// Nil when the bytes are not PEM at all, which is the signal to read them as DER.
    private static func pemBlocks(in data: Data) -> [Data]? {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") else {
            return nil
        }
        var blocks: [Data] = []
        var body: [Substring] = []
        var inside = false
        // `split(whereSeparator: \.isNewline)` rather than splitting on "\n": a Swift `Character`
        // is a grapheme cluster, and CRLF is *one* of them, so a "\n" separator does not match a
        // line ending in a file that has them. The certificates the Ministry publishes are one such
        // file — the first block LF, the second CRLF — and splitting the other way silently swallows
        // the root, leaving a bundle that looks imported and vouches for nothing.
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-----BEGIN CERTIFICATE-----") {
                inside = true
                body = []
            } else if trimmed.hasPrefix("-----END CERTIFICATE-----") {
                inside = false
                if let der = Data(base64Encoded: body.joined(), options: .ignoreUnknownCharacters) {
                    blocks.append(der)
                }
            } else if inside {
                body.append(line[...])
            }
        }
        return blocks
    }

    private static func read(_ file: URL) -> CertificateBundle? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let certificates = parse(data)
        guard !certificates.isEmpty else { return nil }
        let name = certificates.count == 1
            ? certificates[0].name
            : String(localized: "\(certificates[0].name) and \(certificates.count - 1) more")
        return CertificateBundle(id: "file:" + file.lastPathComponent,
                                 name: name,
                                 detail: String(localized: "Imported from \(file.lastPathComponent)"),
                                 source: nil,
                                 certificates: certificates,
                                 isBuiltIn: false,
                                 file: file)
    }

    /// `alfa.pem`, then `alfa 2.pem` — the same rule downloads follow, for the same reason.
    private static func freeName(for suggested: String) -> URL {
        let safe = suggested.replacingOccurrences(of: "/", with: "-")
        let stem = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appending(path: safe.isEmpty ? "certificate.pem" : safe)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = folder.appending(path: name)
            index += 1
        }
        return candidate
    }
}

/// Judging a server's chain, off the main actor.
///
/// Everything here is a wrapper over `Security`, and the only reason it is not inline in
/// `CertificateStore` is that evaluating trust can go to the network — an OCSP responder, an issuer
/// named in the certificate — and a window is on screen waiting for it.
nonisolated enum ServerTrust {
    /// `SecTrustEvaluateAsyncWithError` calls back here; the work itself happens in `trustd`.
    private static let queue = DispatchQueue(label: "org.deffun.six.trust", qos: .userInitiated)

    /// Does this chain check out on its own — the system's anchors, untouched, nothing added?
    static func isTrusted(_ trust: SecTrust) async -> Bool {
        await evaluate(trust)
    }

    /// A second reading of a chain the system turned down: the same certificates, judged again with
    /// `anchors` **added** to the system's own. Hands back a trust to answer the challenge with, or
    /// nil if it does not check out this way either.
    ///
    /// The evaluation happens on a copy. The original belongs to WebKit and is what it will judge
    /// for itself if this comes back nil, so it is left exactly as it was found.
    static func retry(_ trust: SecTrust, host: String, adding anchors: [SecCertificate]) async -> SecTrust? {
        guard !anchors.isEmpty, !host.isEmpty,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !chain.isEmpty
        else { return nil }
        // The hostname is checked here too (`SecPolicyCreateSSL(true, host)`): an anchor six was
        // told to trust is an anchor, not a licence to accept a certificate written for somebody else.
        var policies: [SecPolicy] = [SecPolicyCreateSSL(true, host as CFString)]
        // Revocation the way a browser does it: ask, and believe a "revoked" — but do not refuse to
        // load because a responder could not be reached, which on the networks this feature exists
        // for is most of them. `kSecRevocationRequirePositiveResponse` is deliberately not set.
        if let revocation = SecPolicyCreateRevocation(kSecRevocationUseAnyAvailableMethod) {
            policies.append(revocation)
        }
        var copy: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policies as CFArray, &copy) == errSecSuccess,
              let copy else { return nil }
        guard SecTrustSetAnchorCertificates(copy, anchors as CFArray) == errSecSuccess else { return nil }
        // *Added to*, not *instead of*. Without this line the anchors set above would be the only
        // ones there are, and switching a single certificate on would break every other site.
        guard SecTrustSetAnchorCertificatesOnly(copy, false) == errSecSuccess else { return nil }
        return await evaluate(copy) ? copy : nil
    }

    private static func evaluate(_ trust: SecTrust) async -> Bool {
        await withCheckedContinuation { continuation in
            // On the queue, not merely *with* it. `SecTrustEvaluateAsyncWithError` asserts that it
            // was called from the queue it is handed — `dispatch_assert_queue` inside Security, a
            // SIGTRAP and no message — so calling it from wherever the task happened to be running
            // kills the app on the first site that needs this. Found by evaluating a real bank's
            // chain from a command-line tool; it is not a warning, it is a trap.
            queue.async {
                // The callback runs exactly once when this returns `errSecSuccess`, and not at all
                // when it does not — which is what makes resuming in both places safe.
                let status = SecTrustEvaluateAsyncWithError(trust, queue) { _, isTrusted, _ in
                    continuation.resume(returning: isTrusted)
                }
                if status != errSecSuccess { continuation.resume(returning: false) }
            }
        }
    }
}

/// The two dates inside a certificate, read out of the DER by hand.
///
/// `SecCertificateCopyValues` would answer this in one call and is macOS-only; six runs on the phone
/// too, and one code path that works everywhere is worth thirty lines. Nothing here decides
/// anything — the dates are for the line under the name, and `Security` does the judging.
private nonisolated struct CertificateValidity {
    let notBefore: Date?
    let notAfter: Date?

    /// `Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version?, INTEGER serial,
    /// SEQUENCE signature, SEQUENCE issuer, SEQUENCE validity, … } … }` — so: step into two
    /// sequences, skip up to four fields, and the next sequence is the one with the dates in it.
    init?(der: Data) {
        var reader = DERReader(bytes: [UInt8](der))
        guard let certificate = reader.enterSequence() else { return nil }
        var body = DERReader(bytes: certificate)
        guard let tbsBytes = body.enterSequence() else { return nil }
        var tbs = DERReader(bytes: tbsBytes)
        // The version is optional and tagged `[0]`; when it is absent the serial number is first.
        if tbs.peekTag() == 0xA0 { _ = tbs.skip() }
        guard tbs.skip(), tbs.skip(), tbs.skip(), // serial, signature algorithm, issuer
              let validity = tbs.enterSequence() else { return nil }
        var dates = DERReader(bytes: validity)
        notBefore = dates.readTime()
        notAfter = dates.readTime()
        if notBefore == nil, notAfter == nil { return nil }
    }
}

/// Just enough DER to walk the front of a certificate: tag, length, value, and two of X.509's ways
/// of writing a date.
private nonisolated struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func peekTag() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    /// The contents of the next element, or nil if what is there is not the tag asked for.
    private mutating func next(tag wanted: UInt8? = nil) -> ArraySlice<UInt8>? {
        guard index < bytes.count else { return nil }
        let tag = bytes[index]
        if let wanted, tag != wanted { return nil }
        var cursor = index + 1
        guard cursor < bytes.count else { return nil }
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            // A long form: the low seven bits say how many bytes the length itself takes. Four is
            // more than any certificate needs and is where this stops trying.
            let count = length & 0x7F
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        index = cursor + length
        return bytes[cursor..<(cursor + length)]
    }

    /// Steps over the next element, whatever it is.
    mutating func skip() -> Bool {
        next() != nil
    }

    /// The contents of the next element, when it is a SEQUENCE.
    mutating func enterSequence() -> [UInt8]? {
        next(tag: 0x30).map(Array.init)
    }

    /// `UTCTime` (`YYMMDDHHMMSSZ`, two-digit year) or `GeneralizedTime` (`YYYYMMDDHHMMSSZ`).
    mutating func readTime() -> Date? {
        guard let tag = peekTag(), tag == 0x17 || tag == 0x18, let value = next() else { return nil }
        let text = String(decoding: value, as: UTF8.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // RFC 5280: two-digit years below 50 are 20xx, the rest are 19xx, and the formatter's own
        // pivot is not that rule.
        formatter.dateFormat = tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        if tag == 0x17 { formatter.twoDigitStartDate = Date(timeIntervalSince1970: -631_152_000) } // 1950-01-01
        return formatter.date(from: text)
    }
}
