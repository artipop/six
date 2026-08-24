import SwiftUI
import WebKit

struct AddressBar: View {
    let tab: BrowserTab
    var isFocused: FocusState<Bool>.Binding

    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.page.url?.scheme == "https" ? "lock.fill" : "globe")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit {
                    tab.navigate(to: text)
                    isFocused.wrappedValue = false
                }
            if tab.page.isLoading {
                ProgressView(value: tab.page.estimatedProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: tab.page.url, initial: true) { _, url in
            if !isFocused.wrappedValue { text = url?.absoluteString ?? "" }
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
            if !focused { text = tab.page.url?.absoluteString ?? "" }
        }
    }
}
