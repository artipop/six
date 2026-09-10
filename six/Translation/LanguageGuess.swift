import Foundation

/// What language is this page in, on a front with no language recogniser to ask.
///
/// The Mac has `NLLanguageRecognizer` and asks it; Linux and Windows have nothing, and the answer
/// still has to be *something*, because a browser that makes the reader pick the source language
/// before it will translate anything is a browser nobody uses twice. Firefox carries CLD2 — a
/// C++ library and a megabyte of tables — for this. six carries two hundred lines, and the reason
/// that is enough is the shape of the question here: the candidates are the hundred-odd languages
/// Bergamot has weights for, the text is a thousand characters of body copy rather than a tweet,
/// and `<html lang>` has usually already said the answer. This is the check on that claim and the
/// fallback when the claim is missing — not a general-purpose identifier.
///
/// It works the way the cheap ones do. Script first, because it is nearly free and decides most of
/// the world: a page in Greek or Thai or Hangul is not ambiguous. Where a script carries several
/// languages the letters *that script does not share* separate them — Ukrainian has «і» and «ї»
/// where Russian has neither, Urdu has «ٹ» where Persian does not. What is left is the Latin
/// alphabet and thirty languages in it, and those are told apart by their most common words, which
/// is the oldest trick there is and still the one that works on a paragraph.
nonisolated enum LanguageGuess {
    /// Below this there is nothing to go on and a confident answer would be a lie.
    ///
    /// Deliberately low, because a character is not a unit of information: twenty-four characters
    /// of Chinese is two sentences and twenty-four of German is one word. What keeps a short Latin
    /// sample from being guessed at is further down — eight words and a scoring margin — and this
    /// is only the floor under all of it.
    static let shortest = 24

    /// The page's own claim, checked against its text.
    ///
    /// The claim wins when the two agree and when the text says nothing. The text wins when they
    /// disagree, because a Russian article on a site whose template says `lang="en"` is an ordinary
    /// thing on the web, and the reader is looking at the text.
    static func source(claimed: String, sample: String) -> String? {
        let claim = normalize(claimed)
        let detected = detect(sample)
        switch (claim, detected) {
        case (let claim?, nil): return claim
        case (nil, let detected?): return detected
        case (let claim?, let detected?):
            // A disagreement inside a family is not a disagreement worth acting on. The detector
            // is here to catch a template claiming English over a Russian article; it is not
            // qualified to overrule a page that says it is Norwegian in favour of Danish, and on
            // that question the page is very likely right about itself.
            if claim == detected || family(of: claim) == family(of: detected), family(of: claim) != nil {
                return claim
            }
            return claim == detected ? claim : detected
        case (nil, nil): return nil
        }
    }

    /// `ru-RU` is Russian, `zh-TW` is traditional Chinese, `` is nothing. Region and case are
    /// dropped; script is kept, because for Chinese it is the whole distinction.
    static func normalize(_ tag: String) -> String? {
        let parts = tag.split(separator: "-").map(String.init)
        guard let base = parts.first?.lowercased(), base.count == 2 || base.count == 3 else { return nil }
        if base == "zh" {
            let script = parts.dropFirst().first?.capitalized ?? ""
            if script == "Hant" { return "zh-Hant" }
            if script == "Hans" { return "zh-Hans" }
            // The regions that write traditional characters, and everything else.
            let region = parts.dropFirst().first?.uppercased() ?? ""
            return ["TW", "HK", "MO"].contains(region) ? "zh-Hant" : "zh-Hans"
        }
        if base == "no" { return "nb" }
        return base
    }

    /// Languages close enough that telling them apart from a paragraph is a coin toss — they share
    /// their commonest words, and often their spelling. Used twice: a page's own claim wins inside
    /// one of these, and a scoring tie inside one is settled by order rather than left unanswered.
    ///
    /// The order within a group is by how much of the web is written in each, which is the only
    /// tie-break available once the text itself has said nothing.
    private static let families: [[String]] = [
        ["da", "nb", "nn"],
        ["id", "ms"],
        ["hr", "sr", "bs"],
        ["cs", "sk"],
        ["es", "gl", "ca"],
        ["ru", "be"],
        ["hi", "mr"],
    ]

    private static func family(of language: String) -> Int? {
        families.firstIndex { $0.contains(language) }
    }

    // MARK: The guess

    static func detect(_ text: String) -> String? {
        let sample = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard sample.count >= shortest else { return nil }
        if let byScript = fromScript(sample) { return byScript }
        return fromWords(sample)
    }

    /// The dominant script, and what it settles on its own.
    ///
    /// "Dominant" is measured over letters only: a Greek page carrying an English brand name in
    /// every header is still a Greek page, and punctuation and digits belong to nobody.
    private static func fromScript(_ text: String) -> String? {
        var counts: [Script: Int] = [:]
        var letters = 0
        for scalar in text.unicodeScalars {
            guard let script = Script(scalar) else { continue }
            letters += 1
            counts[script, default: 0] += 1
        }
        guard letters >= 12 else { return nil }
        // Japanese is the one script mixture that is not ambiguous and never dominant: a page of
        // it is roughly half kana and half the same Han characters Chinese is written in, so
        // neither ever reaches the threshold below. Any kana at all settles it.
        if counts[.kana, default: 0] >= 3 { return "ja" }
        guard let (script, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) / Double(letters) > 0.6
        else { return nil }

        switch script {
        case .latin:
            return nil                                  // thirty candidates; the words decide
        case .cyrillic:
            return cyrillic(text)
        case .arabic:
            return arabic(text)
        case .devanagari:
            // Marathi's giveaways are one letter Hindi does not use and the verb every sentence
            // ends in; without them, Hindi is far and away the likelier page.
            return text.contains("ळ") || text.contains("आहे") ? "mr" : "hi"
        case .han:
            return han(text)
        case .kana:
            return "ja"
        case .hangul:
            return "ko"
        case .greek:
            return "el"
        case .hebrew:
            return "he"
        case .bengali:
            return "bn"
        case .gujarati:
            return "gu"
        case .kannada:
            return "kn"
        case .malayalam:
            return "ml"
        case .tamil:
            return "ta"
        case .telugu:
            return "te"
        case .thai:
            return "th"
        }
    }

    /// Six languages share the Cyrillic alphabet here, and every one of them has letters the
    /// others do not — which is the whole method, and why no word list is needed for any of them.
    ///
    /// The weights say how much a letter proves. «ї», «є» and «ґ» are Ukrainian and nothing else,
    /// so they are worth three; «і» is Ukrainian *and* Belarusian, so it is worth one to each and
    /// decides nothing on its own. «ъ» is the one that has to be read the other way round: Russian
    /// spells a handful of words with it and Bulgarian spells a third of its words with it, so it
    /// counts for Bulgarian and a Russian page outscores that on «ы» and «э» long before it matters.
    private static func cyrillic(_ text: String) -> String {
        var score: [String: Int] = [:]
        for character in text.lowercased() {
            switch character {
            case "ї", "є", "ґ": score["uk", default: 0] += 3
            case "і": score["uk", default: 0] += 1; score["be", default: 0] += 1
            case "ў": score["be", default: 0] += 3
            case "ђ", "ћ", "џ", "љ", "њ", "ј": score["sr", default: 0] += 2
            case "ќ", "ѓ", "ѕ": score["mk", default: 0] += 3
            case "ы", "э": score["ru", default: 0] += 2
            case "ъ": score["bg", default: 0] += 1
            default: break
            }
        }
        // Russian is the answer when nothing distinguishing turned up at all: it is most of the
        // Cyrillic web, and it is the one of the six whose alphabet is the plain one.
        return score.max(by: { $0.value < $1.value })?.key ?? "ru"
    }

    /// Arabic script: Arabic, Persian and Urdu. Persian added four letters to the Arabic alphabet
    /// and Urdu added four more on top of those.
    private static func arabic(_ text: String) -> String {
        if text.contains(where: { "ٹڈڑںے".contains($0) }) { return "ur" }
        if text.contains(where: { "پچژگ".contains($0) }) { return "fa" }
        return "ar"
    }

    /// Simplified against traditional, by the characters the reform actually changed. A page that
    /// uses neither set is left as simplified, which is what the majority of the web is.
    private static func han(_ text: String) -> String {
        let traditional = text.reduce(0) { "個們這國會來時發對說學經濟灣為與後點麼".contains($1) ? $0 + 1 : $0 }
        let simplified = text.reduce(0) { "个们这国会来时发对说学经济湾为与后点么".contains($1) ? $0 + 1 : $0 }
        return traditional > simplified ? "zh-Hant" : "zh-Hans"
    }

    // MARK: The Latin alphabet

    /// The most common words of thirty languages, and the letters only some of them have.
    ///
    /// Both halves are needed. Words alone confuse the close pairs — Czech and Slovak, Danish and
    /// Norwegian, Spanish and Galician — because they *share* their most common words; letters
    /// alone confuse anything written without diacritics, which on the web is a great deal. So a
    /// word is worth two and a letter one, and the winner has to be ahead by a margin or the answer
    /// is nothing at all, which the caller reads as "ask the page what it claims".
    private static func fromWords(_ text: String) -> String? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map(String.init)
        guard words.count >= 8 else { return nil }

        var score: [String: Int] = [:]
        for word in words {
            for (language, common) in stopwords where common.contains(word) {
                score[language, default: 0] += 2
            }
        }
        for character in text.lowercased() {
            guard let languages = markers[character] else { continue }
            for language in languages { score[language, default: 0] += 1 }
        }

        let ranked = score.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 4 else { return nil }
        let tied = ranked.filter { $0.value == best.value }.map(\.key)
        if tied.count == 1 { return best.key }

        // Danish against Bokmål, Indonesian against Malay: these tie because they genuinely share
        // the words being counted, and the page is in one of them either way. Answering with the
        // commoner of the two is right far more often than answering with nothing, which would
        // leave the reader to pick a language from a list of a hundred.
        if let group = family(of: tied[0]), tied.allSatisfy({ family(of: $0) == group }) {
            return families[group].first { tied.contains($0) }
        }
        // A tie across families is a real failure to tell — say so and let `<html lang>` answer.
        return nil
    }

    /// Letters that narrow the field. A language is listed under a letter only when the letter is
    /// unusual enough to mean something — `é` is in half of Europe and is in none of these lists.
    private static let markers: [Character: [String]] = [
        "ą": ["pl"], "ę": ["pl"], "ł": ["pl"], "ń": ["pl"], "ś": ["pl"], "ż": ["pl", "mt"], "ź": ["pl"],
        "ř": ["cs"], "ě": ["cs"], "ů": ["cs"],
        "ĺ": ["sk"], "ŕ": ["sk"], "ô": ["sk"],
        "ő": ["hu"], "ű": ["hu"],
        "ă": ["ro"], "ș": ["ro"], "ț": ["ro"], "î": ["ro"],
        "ğ": ["tr"], "ı": ["tr"], "ş": ["tr"],
        "ø": ["da", "nb", "nn"], "æ": ["da", "nb", "nn"],
        "å": ["sv", "da", "nb", "nn"],
        "ñ": ["es", "gl", "eu"], "¿": ["es"], "¡": ["es"],
        "ã": ["pt"], "õ": ["pt", "et"], "ç": ["pt", "ca", "fr", "tr", "sq"],
        "ë": ["sq", "nl"],
        "ħ": ["mt"], "ġ": ["mt"],
        "ð": ["is"], "þ": ["is"], "ý": ["is", "cs", "sk"],
        "ū": ["lt", "lv"], "ė": ["lt"], "į": ["lt"], "ų": ["lt"],
        "ķ": ["lv"], "ļ": ["lv"], "ņ": ["lv"], "ģ": ["lv"],
        "č": ["cs", "sk", "sl", "hr", "bs", "lt", "lv", "sr"],
        "š": ["cs", "sk", "sl", "hr", "bs", "et", "lt", "lv", "sr"],
        "ž": ["cs", "sk", "sl", "hr", "bs", "et", "lt", "lv", "sr"],
        "đ": ["hr", "bs", "sr", "vi"], "ć": ["hr", "bs", "sr", "pl"],
        "ơ": ["vi"], "ư": ["vi"], "ạ": ["vi"], "ệ": ["vi"], "ộ": ["vi"], "ỗ": ["vi"],
        "ä": ["de", "fi", "et", "sv"], "ö": ["de", "fi", "et", "sv", "hu", "tr", "is"],
        "ü": ["de", "hu", "tr", "az", "et"], "ß": ["de"],
        "ə": ["az"], "ĝ": ["eu"],
    ]

    /// Ten to twenty of the commonest words of each language. Chosen for what they *do not* share:
    /// "the" is in the English list and "de" is in four lists, and that is what the margin above is
    /// for.
    private static let stopwords: [String: Set<String>] = [
        "en": ["the", "and", "that", "with", "for", "this", "from", "have", "was", "are", "which", "you", "not", "but"],
        "de": ["der", "die", "das", "und", "ist", "nicht", "mit", "für", "auch", "sich", "dem", "den", "eine", "auf", "werden"],
        "nl": ["het", "een", "van", "niet", "zijn", "dat", "met", "voor", "aan", "door", "worden", "maar", "ook", "deze"],
        "af": ["die", "van", "nie", "wat", "vir", "met", "het", "word", "ook", "hulle", "haar", "hierdie"],
        "fr": ["les", "des", "une", "que", "pour", "dans", "est", "pas", "sur", "avec", "plus", "cette", "aux", "sont"],
        "es": ["que", "los", "las", "una", "por", "con", "para", "más", "como", "pero", "sus", "este", "esta", "está", "son", "del", "muy", "porque", "también", "año", "sin", "un", "el", "la", "al", "es"],
        "ca": ["que", "els", "les", "una", "amb", "per", "són", "aquesta", "això", "però", "més", "seva", "com"],
        "gl": ["que", "dos", "das", "unha", "para", "con", "polo", "esta", "seus", "tamén", "máis", "onde"],
        "pt": ["que", "não", "uma", "com", "para", "por", "mais", "como", "mas", "seus", "está", "são", "pelo", "isso", "dos", "das", "muito", "também", "então", "ser", "ele", "foi", "um", "em", "do", "na", "no", "é", "ao"],
        "it": ["che", "non", "una", "per", "con", "sono", "come", "anche", "della", "nel", "più", "questo", "gli"],
        "ro": ["care", "este", "pentru", "din", "sunt", "mai", "său", "această", "dar", "prin", "fost", "către"],
        "sq": ["dhe", "për", "nga", "një", "është", "janë", "kjo", "por", "shumë", "tij", "sipas"],
        "pl": ["nie", "jest", "się", "który", "przez", "tego", "jako", "oraz", "przy", "tylko", "była", "jego"],
        "cs": ["která", "není", "jsou", "této", "jako", "podle", "také", "byla", "když", "však", "jeho", "pro"],
        "sk": ["ktorá", "sú", "tejto", "ako", "podľa", "aj", "bola", "však", "jeho", "pre", "alebo"],
        "sl": ["je", "ki", "so", "ali", "tudi", "pri", "kot", "svoj", "lahko", "vendar", "zaradi"],
        "hr": ["koji", "koja", "nije", "kao", "prema", "također", "bila", "njegov", "ili", "svoje", "kroz"],
        "bs": ["koji", "koja", "nije", "kao", "prema", "također", "bila", "njegov", "ili", "sve", "što"],
        "sr": ["koji", "koja", "nije", "kao", "према", "takođe", "bila", "njegov", "ili", "sve", "što"],
        "hu": ["hogy", "nem", "egy", "volt", "csak", "meg", "még", "vagy", "mint", "után", "amely"],
        "fi": ["että", "ovat", "sekä", "myös", "mutta", "kun", "hän", "niin", "vain", "jossa", "tämä"],
        "et": ["mis", "kui", "see", "ning", "aga", "oma", "kes", "või", "ka", "olid", "selle"],
        "lt": ["kad", "yra", "bet", "kaip", "tik", "savo", "arba", "buvo", "šis", "taip"],
        "lv": ["kas", "arī", "bet", "kā", "savu", "vai", "bija", "šis", "tikai", "pēc"],
        "tr": ["bir", "için", "olarak", "daha", "kadar", "sonra", "ile", "olan", "değil", "ancak", "gibi"],
        "az": ["bir", "üçün", "olaraq", "daha", "sonra", "ilə", "olan", "deyil", "ancaq", "kimi", "edir"],
        "sv": ["och", "att", "det", "som", "med", "för", "inte", "har", "den", "från", "men", "eller"],
        "da": ["og", "det", "som", "med", "for", "ikke", "har", "den", "fra", "men", "eller", "til", "af", "efter", "blev", "meget", "kun", "sådan", "dette", "hvordan"],
        "nb": ["og", "det", "som", "med", "for", "ikke", "har", "den", "fra", "men", "eller", "til", "være", "av", "etter", "ble", "mye", "bare", "slik", "dette", "hvordan"],
        "nn": ["og", "det", "som", "med", "for", "ikkje", "har", "den", "frå", "men", "eller", "vere", "av", "etter", "vart", "mykje", "berre", "slik", "dette", "korleis"],
        "is": ["og", "sem", "með", "ekki", "hefur", "þau", "þessi", "eða", "til", "frá", "verið"],
        "id": ["yang", "dan", "untuk", "dengan", "tidak", "dari", "pada", "ini", "adalah", "akan", "atau", "bisa", "sudah", "karena", "juga", "kami"],
        "ms": ["yang", "dan", "untuk", "dengan", "tidak", "dari", "pada", "ini", "adalah", "akan", "atau", "boleh", "ialah", "kerana", "sudah", "kami", "daripada"],
        "vi": ["của", "và", "trong", "không", "được", "này", "một", "người", "cho", "với", "những"],
        "eu": ["eta", "dela", "duen", "baina", "bere", "dira", "batzuk", "gero", "horrek", "zuen"],
        "mt": ["biex", "għal", "huwa", "kien", "dan", "tal", "jew", "mhux", "fil", "aktar"],
    ]

    // MARK: Scripts

    /// The scripts worth telling apart. Latin is here so it can be counted and then handed on.
    private enum Script: Hashable {
        case latin, cyrillic, greek, hebrew, arabic, devanagari, bengali, gujarati
        case kannada, malayalam, tamil, telugu, thai, han, kana, hangul

        /// By code point range, which is what a script *is* in Unicode. Only letters are asked
        /// about — a scalar that is not a letter answers nil and is not counted at all.
        init?(_ scalar: Unicode.Scalar) {
            let value = scalar.value
            switch value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: self = .latin
            case 0x400...0x52F: self = .cyrillic
            case 0x370...0x3FF, 0x1F00...0x1FFF: self = .greek
            case 0x590...0x5FF: self = .hebrew
            case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: self = .arabic
            case 0x900...0x97F: self = .devanagari
            case 0x980...0x9FF: self = .bengali
            case 0xA80...0xAFF: self = .gujarati
            case 0xC80...0xCFF: self = .kannada
            case 0xD00...0xD7F: self = .malayalam
            case 0xB80...0xBFF: self = .tamil
            case 0xC00...0xC7F: self = .telugu
            case 0xE00...0xE7F: self = .thai
            case 0x3040...0x30FF: self = .kana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: self = .han
            case 0xAC00...0xD7AF, 0x1100...0x11FF: self = .hangul
            default: return nil
            }
        }
    }
}
