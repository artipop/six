import Foundation
import Testing

@testable import SixCore

/// Reading Mozilla's model registry: which version, and which way round.
///
/// Both halves have failed quietly rather than loudly. Picking the wrong version gets a model that
/// loads and translates worse; picking a route the wrong way round translates English into English
/// and looks like the engine doing nothing. Neither throws, which is why they are tested.
struct BergamotCatalogTests {

    /// A registry in the shape the real one has, small enough to read.
    ///
    /// `ru-en` carries four versions, two of them pre-releases — that is not invented, it is what
    /// the real collection looks like for every pair that has been shipped more than once.
    /// `en-ja` uses the split vocabulary, `mt-en` has no reverse direction, and `xx-en` is missing
    /// its weights entirely.
    static let models = """
    { "data": [
      \(record("model.ruen.intgemm.alphas.bin", "model", "ru", "en", "2.1", 31_561_787)),
      \(record("lex.50.50.ruen.s2t.bin", "lex", "ru", "en", "2.1", 4_397_908)),
      \(record("vocab.ruen.spm", "vocab", "ru", "en", "2.1", 952_371)),
      \(record("model.ruen.intgemm.alphas.bin", "model", "ru", "en", "1.9", 1)),
      \(record("lex.50.50.ruen.s2t.bin", "lex", "ru", "en", "1.9", 1)),
      \(record("vocab.ruen.spm", "vocab", "ru", "en", "1.9", 1)),
      \(record("model.ruen.intgemm.alphas.bin", "model", "ru", "en", "2.1a1", 2)),
      \(record("lex.50.50.ruen.s2t.bin", "lex", "ru", "en", "2.1a1", 2)),
      \(record("vocab.ruen.spm", "vocab", "ru", "en", "2.1a1", 2)),
      \(record("model.ende.intgemm.alphas.bin", "model", "en", "de", "1.0", 30_000_000)),
      \(record("lex.50.50.ende.s2t.bin", "lex", "en", "de", "1.0", 4_000_000)),
      \(record("vocab.ende.spm", "vocab", "en", "de", "1.0", 800_000)),
      \(record("model.enja.intgemm.alphas.bin", "model", "en", "ja", "1.0", 30_000_000)),
      \(record("lex.50.50.enja.s2t.bin", "lex", "en", "ja", "1.0", 4_000_000)),
      \(record("srcvocab.enja.spm", "srcvocab", "en", "ja", "1.0", 400_000)),
      \(record("trgvocab.enja.spm", "trgvocab", "en", "ja", "1.0", 400_000)),
      \(record("model.mten.intgemm.alphas.bin", "model", "mt", "en", "1.0", 30_000_000)),
      \(record("vocab.mten.spm", "vocab", "mt", "en", "1.0", 800_000)),
      \(record("vocab.xxen.spm", "vocab", "xx", "en", "1.0", 800_000))
    ] }
    """

    static let wasm = """
    { "data": [
      { "name": "bergamot-translator", "release": "v0.6.0", "version": "3.0",
        "attachment": { "hash": "aa", "size": 4960506, "filename": "bergamot-translator.wasm",
                        "location": "main-workspace/translations-wasm/new.wasm" } },
      { "name": "bergamot-translator", "release": "v0.5.0", "version": "2.0",
        "attachment": { "hash": "bb", "size": 4956176, "filename": "bergamot-translator.wasm",
                        "location": "main-workspace/translations-wasm/old.wasm" } },
      { "name": "fasttext-wasm", "release": "v0.9.2", "version": "1.0",
        "attachment": { "hash": "cc", "size": 953921, "filename": "fasttext_wasm.wasm",
                        "location": "main-workspace/translations-wasm/ft.wasm" } }
    ] }
    """

    static func record(_ name: String, _ kind: String, _ from: String, _ to: String,
                       _ version: String, _ size: Int) -> String {
        """
        { "name": "\(name)", "fileType": "\(kind)", "fromLang": "\(from)", "toLang": "\(to)",
          "version": "\(version)",
          "attachment": { "hash": "\(name)-\(version)", "size": \(size),
                          "filename": "\(name)", "location": "main-workspace/translations-models/\(name).\(version)" } }
        """
    }

    static func catalogue(release: String = "v0.6.0") throws -> BergamotCatalog {
        try BergamotCatalog.decode(root: nil, wasm: Data(wasm.utf8), models: Data(models.utf8),
                                   release: release)
    }

    // MARK: Versions

    @Test func takesTheNewestReleaseAndNeverAPreRelease() throws {
        let catalogue = try Self.catalogue()
        let russian = try #require(catalogue.models.first { $0.from == "ru" && $0.to == "en" })
        #expect(russian.version == "2.1")
        // Three files at that version and nothing from the other three builds: weights and a
        // shortlist from different builds load happily and then translate nonsense.
        #expect(russian.files.count == 3)
        #expect(russian.files.allSatisfy { $0.version == "2.1" })
        #expect(russian.bytes == 31_561_787 + 4_397_908 + 952_371)
    }

    @Test func comparesVersionsAsNumbersAndNotAsText() {
        #expect(BergamotCatalog.isOlder("1.9", than: "1.10"))
        #expect(BergamotCatalog.isOlder("1.9", than: "2.1"))
        #expect(!BergamotCatalog.isOlder("2.1", than: "2.1"))
        #expect(!BergamotCatalog.isOlder("2.1", than: "1.9"))
        #expect(BergamotCatalog.isRelease("2.1"))
        #expect(!BergamotCatalog.isRelease("2.1a1"))
        #expect(!BergamotCatalog.isRelease(""))
    }

    @Test func dropsAPairWithNoWeights() throws {
        let catalogue = try Self.catalogue()
        #expect(!catalogue.models.contains { $0.from == "xx" })
    }

    @Test func keepsASplitVocabulary() throws {
        let catalogue = try Self.catalogue()
        let japanese = try #require(catalogue.models.first { $0.from == "en" && $0.to == "ja" })
        #expect(Set(japanese.files.map(\.kind)) == ["model", "lex", "srcvocab", "trgvocab"])
    }

    // MARK: The engine

    @Test func takesTheEngineTheVendoredGlueBelongsTo() throws {
        #expect(try Self.catalogue(release: "v0.6.0").wasm.location.hasSuffix("new.wasm"))
        #expect(try Self.catalogue(release: "v0.5.0").wasm.location.hasSuffix("old.wasm"))
        #expect(throws: BergamotError.noEngine("v9.9.9")) {
            try Self.catalogue(release: "v9.9.9")
        }
    }

    @Test func fallsBackToTheKnownAttachmentHost() throws {
        #expect(try Self.catalogue().attachments == BergamotCatalog.fallbackAttachments)
    }

    // MARK: Routing

    @Test func usesOneModelWhenThereIsOne() throws {
        let route = try Self.catalogue().route(from: "ru", to: "en")
        #expect(route.map(\.from) == ["ru"])
        #expect(route.map(\.to) == ["en"])
    }

    /// Every pair Mozilla trains has English at one end, so anything else is two models and a round
    /// trip through it.
    @Test func pivotsThroughEnglish() throws {
        let route = try Self.catalogue().route(from: "ru", to: "de")
        #expect(route.count == 2)
        #expect(route[0].from == "ru" && route[0].to == "en")
        #expect(route[1].from == "en" && route[1].to == "de")
    }

    @Test func hasNoRouteWhenAHalfIsMissing() throws {
        let catalogue = try Self.catalogue()
        // Maltese goes to English and comes back from nowhere.
        #expect(catalogue.route(from: "en", to: "mt").isEmpty)
        #expect(catalogue.route(from: "mt", to: "de").isEmpty)
        #expect(catalogue.route(from: "ru", to: "ru").isEmpty)
    }

    @Test func offersEverythingReachableFromALanguage() throws {
        let catalogue = try Self.catalogue()
        #expect(catalogue.targets(from: "ru") == ["de", "en", "ja"])
        #expect(catalogue.targets(from: "en") == ["de", "ja"])
        // Maltese reaches English and, through it, everything English reaches.
        #expect(catalogue.targets(from: "mt") == ["de", "en", "ja"])
        #expect(catalogue.sources == ["en", "mt", "ru"])
    }

    /// The folder a model is cached in has to change when the model does, or a new version is
    /// quietly read from the old one's files forever.
    @Test func namesACacheFolderAfterTheVersion() throws {
        let russian = try #require(try Self.catalogue().models.first { $0.from == "ru" })
        #expect(russian.folder == "ru-en@2.1")
    }
}
