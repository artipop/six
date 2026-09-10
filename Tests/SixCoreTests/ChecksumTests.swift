import Foundation
import Testing

@testable import SixCore

/// SHA-256 against the vectors everyone checks a SHA-256 against.
///
/// Worth having for the ordinary reason a hand-written hash is worth testing — it is arithmetic
/// with a published right answer — and for one specific to how it is used: `BergamotStore` refuses
/// a download whose digest disagrees, so a hash that is subtly wrong does not corrupt anything, it
/// makes translation impossible and says the model did not arrive intact. That failure would be
/// read as a network problem for a long time.
struct ChecksumTests {

    @Test func matchesTheStandardVectors() {
        #expect(Checksum.sha256(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Checksum.sha256(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Checksum.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// The padding rule is where a hand-written SHA-256 goes wrong, and it goes wrong exactly at
    /// the block boundary: 55 bytes still fits its length word into the last block, 56 does not and
    /// costs a whole extra one, and 64 is a full block with nothing but padding after it.
    @Test func handlesTheBlockBoundary() {
        // 55 and 56 are the pair that matters: the second one no longer has room for its length
        // word and costs an extra block. 64 is a full block followed by one of pure padding.
        #expect(Checksum.sha256(Data(repeating: 0x61, count: 55)) ==
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(Checksum.sha256(Data(repeating: 0x61, count: 56)) ==
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(Checksum.sha256(Data(repeating: 0x61, count: 64)) ==
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")

        // And no two lengths may hash alike, which is what a padding bug actually produces.
        let sizes = [54, 55, 56, 57, 63, 64, 65, 119, 120, 128]
        var digests = Set<String>()
        for size in sizes {
            let digest = Checksum.sha256(Data(repeating: 0x61, count: size))
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            digests.insert(digest)
        }
        #expect(digests.count == sizes.count)
    }

    /// A million 'a' — the fourth of the classic vectors, and the one that exercises the streaming
    /// path where a caller's chunks do not land on 64-byte boundaries.
    @Test func hashesALongMessageInPieces() {
        var data = Data()
        data.append(contentsOf: [UInt8](repeating: 0x61, count: 1_000_000))
        #expect(Checksum.sha256(data) ==
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func hashesAFileWithoutReadingItWhole() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "six-checksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        // Larger than the one-megabyte read the implementation uses, so more than one chunk is
        // hashed and the leftover between them matters.
        let data = Data((0..<(1 << 21)).map { UInt8($0 % 251) })
        try data.write(to: url)
        #expect(try Checksum.sha256(ofFileAt: url) == Checksum.sha256(data))
    }
}
