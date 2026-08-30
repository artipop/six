import Foundation
import Testing

@testable import SixCore

/// What the address field is allowed to show for a host that travelled as ASCII.
///
/// Two halves, and the second one is the point. Decoding punycode is arithmetic and either right or
/// wrong; deciding *whether* to decode is a judgement about what a person will read, and it is the
/// half that a refactor can quietly loosen without anything failing to compile. Every case below
/// that expects the `xn--` form back is a homograph the field must not draw.
struct IDNTests {

    // MARK: The arithmetic, RFC 3492

    @Test func decodesAndEncodesTheSameLabels() {
        let pairs = [
            ("j1ail", "кто"),
            ("p1ai", "рф"),
            ("mnchen-3ya", "münchen"),
            ("bcher-kva", "bücher"),
            ("b1agh1afp", "привет"),
            ("wgv71a119e", "日本語"),
            ("eckwd4c7c", "ドメイン"),
            ("3e0b707e", "한국"),
            ("hxajbheg2az3al", "παράδειγμα")
        ]
        for (ace, name) in pairs {
            #expect(IDN.punycodeDecoded(ace) == name)
            #expect(IDN.punycodeEncoded(name) == ace)
        }
    }

    @Test func refusesLabelsThatAreNotPunycode() {
        #expect(IDN.punycodeDecoded("") == nil)
        #expect(IDN.punycodeDecoded("!!") == nil)
        // A delimiter with nothing after it decodes to its own basic part — arithmetically correct,
        // and refused a line higher up: see `refusesAnEncodingWithNothingToEncode`.
        #expect(IDN.punycodeDecoded("j1ail-") == "j1ail")
    }

    // MARK: Names shown as they are written

    @Test func showsAWholeNameInOneScript() {
        #expect(IDN.displayHost("xn--j1ail.xn--p1ai") == "кто.рф")
        #expect(IDN.displayHost("xn--mnchen-3ya.de") == "münchen.de")
        #expect(IDN.displayHost("xn--wgv71a119e.jp") == "日本語.jp")
        #expect(IDN.displayHost("XN--J1AIL.XN--P1AI") == "кто.рф")
    }

    @Test func leavesOrdinaryHostsAlone() {
        #expect(IDN.displayHost("example.com") == "example.com")
        #expect(IDN.displayHost("localhost") == "localhost")
        #expect(IDN.displayHost("") == "")
    }

    // MARK: Names that are costumes

    /// `аpple.com` with a Cyrillic `а`: the attack the rule exists for.
    @Test func refusesALabelOfTwoScripts() {
        #expect(IDN.displayHost("xn--pple-43d.com") == "xn--pple-43d.com")
    }

    /// One bad label takes the whole host down with it — `кто.xn--pple-43d` would read as a name
    /// that had merely been spelled oddly in one place.
    @Test func refusesTheWholeHostWhenOneLabelFails() {
        #expect(IDN.displayHost("xn--j1ail.xn--pple-43d") == "xn--j1ail.xn--pple-43d")
    }

    /// Not a script this knows how to judge, and not letters at all.
    @Test func refusesWhatIsNotAName() {
        #expect(IDN.displayHost("xn--ls8h.la") == "xn--ls8h.la") // 💩.la
        #expect(IDN.displayHost("xn--nonsense-that-is-not-punycode") == "xn--nonsense-that-is-not-punycode")
    }

    /// An ACE label that decodes to plain ASCII: the prefix is the only thing hiding what it says,
    /// and taking it off is how `xn--pple-43d-` gets to be read as `apple` in a field.
    @Test func refusesAnEncodingWithNothingToEncode() {
        #expect(IDN.displayHost("xn--xn--pple-43d-") == "xn--xn--pple-43d-")
        #expect(IDN.displayHost("xn--j1ail-") == "xn--j1ail-")
    }

    // MARK: The address as a whole

    @Test func rewritesOnlyTheHostOfAURL() throws {
        let url = try #require(URL(string: "https://xn--j1ail.xn--p1ai/%D0%BF%D1%83%D1%82%D1%8C?q=1"))
        #expect(IDN.displayURL(url) == "https://кто.рф/%D0%BF%D1%83%D1%82%D1%8C?q=1")
    }

    @Test func leavesAnAddressWithNothingToDecodeExactlyAsItIs() throws {
        let url = try #require(URL(string: "https://example.com/a?b=c#d"))
        #expect(IDN.displayURL(url) == "https://example.com/a?b=c#d")
    }
}
