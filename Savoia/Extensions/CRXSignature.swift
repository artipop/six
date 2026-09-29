#if os(macOS)
import Foundation
import CryptoKit
import Security

/// What a `.crx` file's own signature says about it. `docs/extensions.md` flagged this as the one
/// unchecked thing about installing from a file — a `.crx` is a zip behind a small header
/// (`ExtensionInstaller`), and nothing read that header for anything but the manifest inside.
///
/// This verifies **internal consistency**, not authorship: that the id Chrome's CRX3 format claims
/// for the file is the hash of an embedded public key, and that key's signature covers the header
/// and the archive that follows. It says the file was not corrupted or edited after signing and is
/// self-consistent about its own identity — it does not say who holds that key, because CRX3 never
/// asked that question either: Chrome accepts a self-signed `.crx` from anyone, the same as this
/// does. A `.zip` or an `.xpi` carries none of this and is `.notSigned`, not `.invalid` — there is
/// nothing here to have failed.
///
/// The format: `"Cr24"`, a version (3), a header length, then that many bytes of a small protobuf
/// message (`CrxFileHeader` in Chromium's `crx3.proto`) ahead of the zip archive itself.
/// `ProtoField.list(in:)` below reads exactly the two wire types that schema uses — a varint to
/// skip and a length-delimited blob to keep — rather than pull in a general protobuf runtime for
/// three fixed message shapes that have not changed since CRX3 shipped.
nonisolated enum CRXSignature {
    enum Verdict: Equatable {
        /// A valid proof was found; the id is Chrome's own 32-letter form (`a`–`p` per nibble).
        case verified(extensionID: String)
        /// No CRX3 header at all — a plain `.zip`/`.xpi`, or a CRX2 file this does not read.
        case notSigned
        case malformed(String)
        /// A CRX3 header was present and no proof in it verified — the one outcome worth a warning
        /// rather than a shrug, since it means the archive changed after it was signed.
        case invalid
    }

    static func verify(contentsOf url: URL) -> Verdict {
        guard let data = try? Data(contentsOf: url) else { return .malformed("could not read the file") }
        return verify(data)
    }

    static func verify(_ data: Data) -> Verdict {
        guard data.count > 12 else { return .notSigned }
        let magic = data.subdata(in: data.startIndex..<data.index(data.startIndex, offsetBy: 4))
        guard magic.elementsEqual(Array("Cr24".utf8)) else { return .notSigned }
        let version = readUInt32LE(data, at: 4)
        guard version == 3 else { return .malformed("crx version \(version), not 3") }
        let headerLength = Int(readUInt32LE(data, at: 8))
        let headerStart = data.index(data.startIndex, offsetBy: 12)
        guard let headerEnd = data.index(headerStart, offsetBy: headerLength, limitedBy: data.endIndex) else {
            return .malformed("header length runs past the end of the file")
        }
        let header = data.subdata(in: headerStart..<headerEnd)
        let archive = data.subdata(in: headerEnd..<data.endIndex)

        let headerFields = ProtoField.list(in: header)
        guard let signedHeaderData = headerFields.first(number: 4)?.bytes else {
            return .malformed("no signed_header_data in the crx header")
        }
        guard let crxID = ProtoField.list(in: signedHeaderData).first(number: 1)?.bytes else {
            return .malformed("signed_header_data has no crx_id")
        }

        // What every proof actually signs: a fixed magic string, the length-prefixed
        // `signed_header_data` exactly as it sat in the header, and the archive bytes after it —
        // never the header's own length prefix, which is not itself covered by any proof.
        var signedPayload = Data("CRX3 SignedData\0".utf8)
        signedPayload.append(littleEndianBytes(UInt32(signedHeaderData.count)))
        signedPayload.append(signedHeaderData)
        signedPayload.append(archive)

        for proof in headerFields.all(number: 2) { // sha256_with_rsa
            guard let key = ProtoField.list(in: proof.bytes).first(number: 1)?.bytes,
                  let signature = ProtoField.list(in: proof.bytes).first(number: 2)?.bytes,
                  matches(key: key, crxID: crxID),
                  verifyRSA(publicKeySPKI: key, signature: signature, data: signedPayload)
            else { continue }
            return .verified(extensionID: chromeID(from: crxID))
        }
        for proof in headerFields.all(number: 3) { // sha256_with_ecdsa
            guard let key = ProtoField.list(in: proof.bytes).first(number: 1)?.bytes,
                  let signature = ProtoField.list(in: proof.bytes).first(number: 2)?.bytes,
                  matches(key: key, crxID: crxID),
                  verifyECDSA(publicKeySPKI: key, signature: signature, data: signedPayload)
            else { continue }
            return .verified(extensionID: chromeID(from: crxID))
        }
        return .invalid
    }

    /// Chrome's own id ties the file to a specific key: the id is the first half of the key's own
    /// SHA-256, so a proof whose key does not hash to the claimed id is not this file's proof no
    /// matter what it signs — a mismatch here means a header edited to point at a different key,
    /// which a per-proof signature check alone would not catch.
    private static func matches(key: Data, crxID: Data) -> Bool {
        Data(SHA256.hash(data: key)).prefix(crxID.count) == crxID
    }

    /// The 32-letter form Chrome shows for an extension id — each nibble as `a`–`p` rather than
    /// `0`–`f`, so an id never looks like it could be read as a number.
    private static func chromeID(from bytes: Data) -> String {
        var letters = ""
        for byte in bytes {
            letters.append(Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))))
            letters.append(Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 0xF))))
        }
        return letters
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let four = data.subdata(in: start..<data.index(start, offsetBy: 4))
        return four.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: Verification

    /// CryptoKit reads a P-256 key straight from its X.509 SubjectPublicKeyInfo DER — the one case
    /// here that needed no ASN.1 of its own.
    private static func verifyECDSA(publicKeySPKI: Data, signature: Data, data: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKeySPKI),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return key.isValidSignature(sig, for: SHA256.hash(data: data))
    }

    /// `SecKeyCreateWithData` for `kSecAttrKeyTypeRSA` wants the bare PKCS#1 `RSAPublicKey`
    /// (modulus, exponent) — not the SubjectPublicKeyInfo CRX3 actually carries, which wraps that
    /// same structure in an algorithm identifier. `PKCS1.unwrap` strips exactly that wrapper.
    private static func verifyRSA(publicKeySPKI: Data, signature: Data, data: Data) -> Bool {
        guard let pkcs1 = PKCS1.unwrap(spki: publicKeySPKI) else { return false }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, &error)
    }
}

/// The two wire types Chromium's `crx3.proto` uses (varint and length-delimited) and nothing past
/// them — `CrxFileHeader`, `AsymmetricKeyProof` and `SignedData` have not grown a fixed32/fixed64
/// field, a map, or a nested `oneof` since CRX3 shipped, and a general decoder would read a lot of
/// wire format this file never needs to answer three fixed questions.
nonisolated private struct ProtoField {
    let number: Int
    let bytes: Data

    static func list(in data: Data) -> [ProtoField] {
        var result: [ProtoField] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let (tag, afterTag) = varint(data, at: index) else { break }
            let number = Int(tag >> 3)
            let wireType = tag & 0x7
            switch wireType {
            case 0: // varint value: not a shape any field here carries, so only skipped
                guard let (_, after) = varint(data, at: afterTag) else { return result }
                index = after
            case 2: // length-delimited: bytes, a string, or a nested message — same thing to us
                guard let (length, afterLength) = varint(data, at: afterTag),
                      let end = data.index(afterLength, offsetBy: Int(length), limitedBy: data.endIndex)
                else { return result }
                result.append(ProtoField(number: number, bytes: data.subdata(in: afterLength..<end)))
                index = end
            default:
                return result // fixed32/fixed64: not present in this schema
            }
        }
        return result
    }

    private static func varint(_ data: Data, at index: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = index
        while i < data.endIndex {
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            i = data.index(after: i)
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

nonisolated private extension Array where Element == ProtoField {
    func first(number: Int) -> ProtoField? { first { $0.number == number } }
    func all(number: Int) -> [ProtoField] { filter { $0.number == number } }
}

/// Just enough ASN.1 to get from a SubjectPublicKeyInfo to the `RSAPublicKey` it wraps: walk two
/// nested `SEQUENCE`s, skip the algorithm identifier, and take a `BIT STRING`'s content past its
/// one leading "unused bits" byte (always `0x00` for a DER key). Not a parser for ASN.1 in general —
/// there is exactly one shape of input this ever sees.
nonisolated private enum PKCS1 {
    static func unwrap(spki: Data) -> Data? {
        var reader = spki[...]
        guard let outer = readElement(&reader, expectedTag: 0x30) else { return nil } // SEQUENCE
        var outerContent = outer[...]
        guard readElement(&outerContent, expectedTag: 0x30) != nil else { return nil } // AlgorithmIdentifier, skipped
        guard let bitString = readElement(&outerContent, expectedTag: 0x03) else { return nil } // BIT STRING
        guard bitString.first == 0 else { return nil } // "0 unused bits" — always true for a DER key
        return bitString.dropFirst()
    }

    /// One TLV: the tag byte, DER's short- or long-form length, then that many bytes — advancing
    /// `reader` past all of it and handing back just the content.
    private static func readElement(_ reader: inout Data.SubSequence, expectedTag: UInt8) -> Data? {
        guard let tag = reader.first, tag == expectedTag else { return nil }
        reader = reader.dropFirst()
        guard let first = reader.first else { return nil }
        reader = reader.dropFirst()
        let length: Int
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 4, reader.count >= byteCount else { return nil }
            var value = 0
            for _ in 0..<byteCount {
                value = (value << 8) | Int(reader.first!)
                reader = reader.dropFirst()
            }
            length = value
        }
        guard reader.count >= length else { return nil }
        let content = reader.prefix(length)
        reader = reader.dropFirst(length)
        return Data(content)
    }
}
#endif
