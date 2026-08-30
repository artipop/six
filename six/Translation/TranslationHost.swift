#if canImport(Translation) && canImport(SwiftUI)
import SwiftUI
import Translation

/// The view half of the download path, and nothing else.
///
/// `AppleTranslator` translates without any view at all for a pair whose model is already on the
/// machine. What it cannot do alone is *ask for* a model: `.translationTask` owns that, because the
/// framework puts up the download prompt itself and needs a view to put it over. So the store arms
/// a direction, this carries a task for it, and the closure hands the session back.
///
/// `armedPairs` is empty almost always — on a Mac with its languages downloaded this modifier is a
/// `ForEach` over nothing for the life of the app. It is mounted once, on the root, because
/// `ContentView` is mounted once: on macOS six is a `Window`, not a `WindowGroup`.
///
/// It goes in `background` rather than in a zero-sized corner on purpose. The framework's download
/// alert anchors to this view, and a 0 × 0 anchor puts a system alert in the corner of the screen.
private struct TranslationHost: ViewModifier {
    let translator: AppleTranslator

    func body(content: Content) -> some View {
        content.background {
            ForEach(translator.armedPairs) { pair in
                Color.clear
                    .translationTask(translator.configuration(for: pair)) { session in
                        await translator.serve(pair, session)
                    }
            }
        }
    }
}

extension View {
    /// Mount once, on the root of a window.
    func translationHost(_ translator: AppleTranslator) -> some View {
        modifier(TranslationHost(translator: translator))
    }
}
#endif
