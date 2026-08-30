import Foundation

/// Domain names as they are written — and the reason a browser cannot simply always write them.
///
/// A host on the wire is ASCII. `кто.рф` travels as `xn--j1ail.xn--p1ai`, and that ACE form is what
/// WebKit hands back in `URL.host()`, so an address field that prints the URL prints the machine's
/// spelling of it. Nobody types `xn--`; showing it is the browser admitting it did not understand
/// its own address.
///
/// **The reason nobody decodes it unconditionally.** `аpple.com` — Cyrillic `а`, Latin everything
/// else — is a different host from `apple.com` and looks exactly like it. So the rule here is the
/// one every browser converged on: a label is shown as written only when reading it cannot mislead.
/// Three tests, and a label that fails any of them is left in its ACE form, as is the whole host
/// around it — half a name in Cyrillic beside half in `xn--` is its own kind of lie.
///
/// 1. **It round-trips.** Decode, encode again, and the result must be the ACE label we started
///    from. Punycode has more than one encoding for the same string; only the canonical one is a
///    name, and the rest are ways of writing a name that isn't yours.
/// 2. **It is one script.** Latin, or Cyrillic, or Greek — never two of them in one label, which is
///    the whole homograph attack. Digits and the hyphen belong to all of them, and the two scripts
///    that genuinely mix (Han with kana, Han with Hangul) are allowed as a pair because Japanese and
///    Korean names are written that way.
/// 3. **It is letters.** Marks and combining accents are part of a name; invisible characters,
///    direction overrides, punctuation and emoji are not, and neither is anything from a script this
///    doesn't know — being conservative costs an unfamiliar name its accents, and being permissive
///    costs somebody their bank.
///
/// The encoder exists for the first test rather than for encoding: `URL(string:)` already converts a
/// typed `кто.рф` into its ACE form, so nothing here has to. It is deliberately not built on that —
/// verification through the same component that produced the value proves nothing, and this file is
/// in `SixCore`, which builds where Foundation's IDNA support is another platform's promise.
public enum IDN {

    // MARK: What to show

    /// The host as it should be read, or the ACE form when reading it would be a lie.
    public static func displayHost(_ host: String) -> String {
        guard host.lowercased().contains("xn--") else { return host }
        var shown: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            let label = String(label)
            guard label.lowercased().hasPrefix(acePrefix) else {
                shown.append(label)
                continue
            }
            let ace = String(label.dropFirst(acePrefix.count))
            // Every step is a veto over the whole host, not just this label.
            guard let decoded = punycodeDecoded(ace.lowercased()),
                  punycodeEncoded(decoded) == ace.lowercased(),
                  decoded.precomposedStringWithCanonicalMapping == decoded,
                  isReadable(decoded)
            else { return host }
            shown.append(decoded)
        }
        return shown.joined(separator: ".")
    }

    /// The address with its host in the spelling `displayHost` allows, and everything else untouched.
    ///
    /// For the field while it is being edited: what is in it there is the thing that will be
    /// navigated to when Return is pressed, so the path and the query stay exactly as they are —
    /// only the host, which round-trips through `URL(string:)` unchanged, is rewritten.
    public static func displayURL(_ url: URL) -> String {
        let text = url.absoluteString
        guard let host = url.host(percentEncoded: false) else { return text }
        let shown = displayHost(host)
        guard shown != host, let range = text.range(of: host) else { return text }
        return text.replacingCharacters(in: range, with: shown)
    }

    // MARK: Is this a name or a costume?

    /// Scripts that may appear in one label. Everything not listed is `nil` — unknown, and unknown
    /// is not shown decoded.
    private enum Script: Hashable {
        case common // digits, the hyphen: at home in every name
        case latin, cyrillic, greek, armenian, hebrew, arabic, thai, georgian, devanagari
        case han, kana, hangul
    }

    /// The combinations a single label is allowed to be made of. `common` is added to each.
    private static let allowedScripts: [Set<Script>] = [
        [.latin], [.cyrillic], [.greek], [.armenian], [.hebrew], [.arabic], [.thai], [.georgian],
        [.devanagari],
        // Japanese is Han and kana in one word; Korean is Han and Hangul. Neither is a mixture in
        // the sense the rule is about.
        [.han, .kana], [.han, .hangul]
    ]

    private static func isReadable(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        // An ACE label that decodes to plain ASCII is a name that had no reason to be encoded, and
        // the reason to encode it anyway is that `xn--pple-43d` reads as `apple` once the prefix is
        // taken off it. Punycode is for names ASCII cannot hold; anything else stays as it arrived.
        guard label.unicodeScalars.contains(where: { !$0.isASCII }) else { return false }
        var scripts: Set<Script> = []
        for scalar in label.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter,
                 .nonspacingMark, .spacingMark, .decimalNumber:
                break
            case .dashPunctuation where scalar == "-":
                break
            default:
                return false // invisible characters, direction overrides, emoji, punctuation
            }
            guard let script = script(of: scalar) else { return false }
            if script != .common { scripts.insert(script) }
        }
        return allowedScripts.contains { scripts.isSubset(of: $0) }
    }

    private static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x30...0x39, 0x2D: return .common // ASCII digits and the hyphen
        case 0x41...0x5A, 0x61...0x7A: return .latin
        case 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x300...0x36F: return .common // combining marks: they belong to the letter they sit on
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x530...0x58F: return .armenian
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F: return .arabic
        case 0x900...0x97F: return .devanagari
        case 0xE00...0xE7F: return .thai
        case 0x10A0...0x10FF, 0x1C90...0x1CBF: return .georgian
        case 0x3040...0x30FF, 0x31F0...0x31FF: return .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: return .hangul
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return .han
        default: return nil
        }
    }

    // MARK: Punycode, RFC 3492

    private static let acePrefix = "xn--"
    private static let base = 36
    private static let tmin = 1
    private static let tmax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 0x80

    /// One label's extended part — what follows `xn--` — as the string it stands for.
    public static func punycodeDecoded(_ input: String) -> String? {
        var output: [Unicode.Scalar] = []
        let code = Array(input.unicodeScalars)
        var start = 0
        // Everything before the last delimiter is literal, and only if it is all ASCII.
        if let delimiter = code.lastIndex(of: "-") {
            for scalar in code[..<delimiter] {
                guard scalar.isASCII else { return nil }
                output.append(scalar)
            }
            start = delimiter + 1
        }
        var n = initialN
        var i = 0
        var bias = initialBias
        var index = start
        while index < code.count {
            let previous = i
            var weight = 1
            var k = base
            while true {
                guard index < code.count, let digit = digit(code[index]) else { return nil }
                index += 1
                guard digit <= (Int.max - i) / weight else { return nil }
                i += digit * weight
                let t = threshold(k, bias)
                if digit < t { break }
                guard weight <= Int.max / (base - t) else { return nil }
                weight *= (base - t)
                k += base
            }
            let length = output.count + 1
            bias = adapt(i - previous, length, firstTime: previous == 0)
            guard i / length <= Int.max - n else { return nil }
            n += i / length
            i %= length
            guard let value = UInt32(exactly: n), let scalar = Unicode.Scalar(value) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        guard !output.isEmpty else { return nil }
        return String(String.UnicodeScalarView(output))
    }

    /// The inverse, and the only reason it is here: a decoded label is trusted only if encoding it
    /// again produces the label that was on the wire.
    public static func punycodeEncoded(_ input: String) -> String? {
        let code = Array(input.unicodeScalars)
        var output = code.filter(\.isASCII)
        let basic = output.count
        var handled = basic
        if basic > 0 { output.append("-") }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < code.count {
            guard let m = code.map({ Int($0.value) }).filter({ $0 >= n }).min() else { return nil }
            guard (m - n) <= (Int.max - delta) / (handled + 1) else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for scalar in code {
                let value = Int(scalar.value)
                if value < n {
                    guard delta < Int.max else { return nil }
                    delta += 1
                }
                guard value == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = threshold(k, bias)
                    if q < t { break }
                    output.append(character(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(character(q))
                bias = adapt(delta, handled + 1, firstTime: handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func threshold(_ k: Int, _ bias: Int) -> Int {
        if k <= bias + tmin { return tmin }
        if k >= bias + tmax { return tmax }
        return k - bias
    }

    private static func adapt(_ delta: Int, _ count: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= (base - tmin)
            k += base
        }
        return k + (((base - tmin + 1) * delta) / (delta + skew))
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x41...0x5A: return Int(scalar.value) - 0x41 // A-Z
        case 0x61...0x7A: return Int(scalar.value) - 0x61 // a-z
        case 0x30...0x39: return Int(scalar.value) - 0x30 + 26 // 0-9
        default: return nil
        }
    }

    private static func character(_ digit: Int) -> Unicode.Scalar {
        Unicode.Scalar(UInt32(digit < 26 ? digit + 0x61 : digit - 26 + 0x30)) ?? "?"
    }
}
