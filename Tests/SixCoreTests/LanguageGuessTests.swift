import Foundation
import Testing

@testable import SixCore

/// What language a page is in, guessed from a paragraph of it.
///
/// Every sample below is one ordinary sentence of body copy — deliberately, because that is what
/// `TranslationScript.plan` hands back and it is the only input this ever sees. A detector that
/// needs a page to be sure of itself would be no use here.
///
/// The point of the suite is not the score. It is that the close pairs stay pinned: Ukrainian
/// against Russian, Bulgarian against both, Danish against Bokmål, Indonesian against Malay,
/// Portuguese against Spanish. Each of those was wrong at some point while this was being written,
/// and each was wrong in a way that reads as "translation picked the wrong language" rather than as
/// anything to do with detection.
struct LanguageGuessTests {

    /// One sentence per language, and the answer it has to give.
    static let samples: [(String, String)] = [
        ("en", "The quick brown fox jumps over the lazy dog. This is a paragraph of ordinary English prose, and it is long enough that a detector should have no trouble with it at all."),
        ("ru", "Это обычный абзац русского текста, который написан для того, чтобы проверить, как работает определение языка на странице, и он достаточно длинный."),
        ("uk", "Це звичайний абзац українського тексту, який написаний для того, щоб перевірити, як працює визначення мови на сторінці, і він досить довгий."),
        ("bg", "Това е обикновен абзац на български език, който е написан, за да се провери как работи откриването на езика на страницата."),
        ("sr", "Ово је обичан пасус на српском језику, који је написан да би се проверило како ради откривање језика на страници."),
        ("de", "Dies ist ein ganz normaler Absatz auf Deutsch, der geschrieben wurde, um zu prüfen, wie die Spracherkennung auf der Seite funktioniert."),
        ("fr", "Ceci est un paragraphe ordinaire en français, qui a été écrit pour vérifier comment fonctionne la détection de la langue sur cette page."),
        ("es", "Este es un párrafo corriente en español, que ha sido escrito para comprobar cómo funciona la detección del idioma en esta página."),
        ("pt", "Este é um parágrafo comum em português, que foi escrito para verificar como funciona a detecção do idioma nesta página."),
        ("it", "Questo è un paragrafo ordinario in italiano, che è stato scritto per verificare come funziona il rilevamento della lingua su questa pagina."),
        ("nl", "Dit is een gewone alinea in het Nederlands, die is geschreven om te controleren hoe de taalherkenning op deze pagina werkt."),
        ("pl", "To jest zwykły akapit w języku polskim, który został napisany, aby sprawdzić, jak działa wykrywanie języka na tej stronie."),
        ("cs", "Toto je obyčejný odstavec v češtině, který byl napsán, aby se ověřilo, jak funguje rozpoznávání jazyka na této stránce."),
        ("sv", "Detta är ett vanligt stycke på svenska, som har skrivits för att kontrollera hur språkidentifieringen fungerar på den här sidan."),
        ("da", "Dette er et almindeligt afsnit på dansk, som er skrevet for at kontrollere, hvordan sproggenkendelsen fungerer på denne side."),
        ("fi", "Tämä on tavallinen kappale suomeksi, joka on kirjoitettu sen tarkistamiseksi, miten kielentunnistus toimii tällä sivulla."),
        ("tr", "Bu, bu sayfada dil algılamanın nasıl çalıştığını kontrol etmek için yazılmış sıradan bir Türkçe paragraftır ve yeterince uzundur."),
        ("hu", "Ez egy hétköznapi bekezdés magyar nyelven, amelyet azért írtak, hogy ellenőrizzék, hogyan működik a nyelvfelismerés ezen az oldalon."),
        ("ro", "Acesta este un paragraf obișnuit în limba română, care a fost scris pentru a verifica modul în care funcționează detectarea limbii pe această pagină."),
        ("el", "Αυτή είναι μια συνηθισμένη παράγραφος στα ελληνικά, η οποία γράφτηκε για να ελεγχθεί πώς λειτουργεί η ανίχνευση γλώσσας σε αυτήν τη σελίδα."),
        ("he", "זוהי פסקה רגילה בעברית, שנכתבה כדי לבדוק כיצד פועל זיהוי השפה בדף הזה, והיא ארוכה מספיק."),
        ("ar", "هذه فقرة عادية باللغة العربية، وقد كتبت للتحقق من كيفية عمل اكتشاف اللغة في هذه الصفحة، وهي طويلة بما فيه الكفاية."),
        ("fa", "این یک پاراگراف معمولی به زبان فارسی است که برای بررسی نحوه کار تشخیص زبان در این صفحه نوشته شده است."),
        ("ja", "これはページ上の言語検出がどのように機能するかを確認するために書かれた、ごく普通の日本語の段落です。"),
        ("ko", "이것은 이 페이지에서 언어 감지가 어떻게 작동하는지 확인하기 위해 작성된 평범한 한국어 단락입니다."),
        ("zh-Hans", "这是一个普通的中文段落，用来检查这个页面上的语言检测是如何工作的，它足够长了。"),
        ("zh-Hant", "這是一個普通的中文段落，用來檢查這個頁面上的語言檢測是如何運作的，它足夠長了。"),
        ("th", "นี่คือย่อหน้าภาษาไทยธรรมดา ซึ่งเขียนขึ้นเพื่อตรวจสอบว่าการตรวจจับภาษาบนหน้านี้ทำงานอย่างไร"),
        ("hi", "यह हिंदी में एक सामान्य पैराग्राफ है, जिसे यह जांचने के लिए लिखा गया है कि इस पृष्ठ पर भाषा का पता लगाना कैसे काम करता है।"),
        ("vi", "Đây là một đoạn văn thông thường bằng tiếng Việt, được viết để kiểm tra xem việc phát hiện ngôn ngữ trên trang này hoạt động như thế nào."),
        ("id", "Ini adalah paragraf biasa dalam bahasa Indonesia, yang ditulis untuk memeriksa bagaimana deteksi bahasa pada halaman ini bekerja."),
    ]

    @Test(arguments: LanguageGuessTests.samples)
    func readsOneSentenceOfEach(_ sample: (String, String)) {
        #expect(LanguageGuess.detect(sample.1) == sample.0)
    }

    /// Below the floor there is no answer, and that is the answer. `nil` here is what sends the
    /// caller back to `<html lang>`, so a confident guess from four words would be worse than none.
    @Test func saysNothingAboutNothing() {
        #expect(LanguageGuess.detect("") == nil)
        #expect(LanguageGuess.detect("Hello") == nil)
        #expect(LanguageGuess.detect("   \n  ") == nil)
        // Long enough to pass the floor, and still nothing a word list can score.
        #expect(LanguageGuess.detect("2024 — 12345 67890 ... !!! ??? 42 42 42 42 42") == nil)
    }

    @Test func normalizesTheTagsPagesActuallyWrite() {
        #expect(LanguageGuess.normalize("ru-RU") == "ru")
        #expect(LanguageGuess.normalize("EN") == "en")
        #expect(LanguageGuess.normalize("pt-BR") == "pt")
        #expect(LanguageGuess.normalize("") == nil)
        #expect(LanguageGuess.normalize("x") == nil)
        // Norwegian claims `no` far more often than `nb`, and there is no `no` model.
        #expect(LanguageGuess.normalize("no") == "nb")
        // Chinese is the one where the script is the language, and a region stands in for it.
        #expect(LanguageGuess.normalize("zh") == "zh-Hans")
        #expect(LanguageGuess.normalize("zh-CN") == "zh-Hans")
        #expect(LanguageGuess.normalize("zh-Hant") == "zh-Hant")
        #expect(LanguageGuess.normalize("zh-TW") == "zh-Hant")
        #expect(LanguageGuess.normalize("zh-HK") == "zh-Hant")
    }

    /// The whole reason the claim is checked at all: a site whose template says English, carrying
    /// an article that is not.
    @Test func theTextOverrulesALyingTemplate() {
        let russian = Self.samples[1].1
        #expect(LanguageGuess.source(claimed: "en", sample: russian) == "ru")
        #expect(LanguageGuess.source(claimed: "", sample: russian) == "ru")
        #expect(LanguageGuess.source(claimed: "ru", sample: russian) == "ru")
    }

    /// …and the limit of that rule. Danish and Bokmål are told apart by a margin of two words on a
    /// good day; a page that says which one it is knows better than this does.
    @Test func aClaimSurvivesADisagreementInsideItsOwnFamily() {
        let danish = Self.samples.first { $0.0 == "da" }!.1
        #expect(LanguageGuess.source(claimed: "nb", sample: danish) == "nb")
        #expect(LanguageGuess.source(claimed: "nn", sample: danish) == "nn")
        // Across families it still loses: this is not a licence for any claim at all.
        #expect(LanguageGuess.source(claimed: "fi", sample: danish) == "da")
    }

    /// With nothing to read, the claim is all there is.
    @Test func theClaimStandsWhenThereIsNoTextToCheckItAgainst() {
        #expect(LanguageGuess.source(claimed: "en", sample: "Hi") == "en")
        #expect(LanguageGuess.source(claimed: "", sample: "Hi") == nil)
    }
}
