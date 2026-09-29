#if os(macOS)
import SwiftUI

/// The microphone beside a text field. The final text is appended to `text` and never sent.
struct DictationButton: View {
    @Binding var text: String
    /// Which field this is, so the draft and the failure show up beside the one that asked.
    let owner: String
    @State private var asksForModel = false

    private var store: DictationStore { .shared }

    var body: some View {
        Button(action: press) { icon }
            .buttonStyle(.plain)
            .help(help)
            .alert("Download the speech model?", isPresented: $asksForModel) {
                Button("Download") { start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Dictation runs on this Mac and needs a 470 MB model.")
            }
            .popover(isPresented: failureShown, arrowEdge: .bottom) {
                if case .failed(let message) = store.state {
                    Text(message).padding(12).frame(maxWidth: 280)
                }
            }
    }

    @ViewBuilder
    private var icon: some View {
        switch store.isActive(owner) ? store.state : .idle {
        case .listening:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .scaleEffect(1 + CGFloat(store.level) * 0.35)
                .animation(.easeOut(duration: 0.1), value: store.level)
        case .loading(let fraction):
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.mini)
        case .finishing:
            ProgressView().controlSize(.mini)
        case .idle, .failed:
            Image(systemName: "mic").foregroundStyle(.secondary)
        }
    }

    private var help: LocalizedStringKey {
        store.isActive(owner) && store.state == .listening ? "Stop dictation" : "Dictate"
    }

    private var failureShown: Binding<Bool> {
        Binding {
            if case .failed = store.state { return store.owner == owner }
            return false
        } set: { shown in
            if !shown { store.dismissFailure() }
        }
    }

    private func press() {
        if !store.isActive(owner), !store.isModelDownloaded {
            asksForModel = true
        } else {
            start()
        }
    }

    private func start() {
        store.toggle(owner: owner) { spoken in
            let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
            text += separator + spoken
        }
    }
}

/// What is being heard, in grey, until the final pass replaces it.
struct DictationDraft: View {
    let owner: String

    var body: some View {
        let store = DictationStore.shared
        if store.isActive(owner), !store.draft.isEmpty {
            Text(store.draft)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1...4)
        }
    }
}
#endif
