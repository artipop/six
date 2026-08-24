import SwiftUI
import WebKit

/// Arc-style sidebar: profile switcher on top, the selected profile's tabs below.
struct SidebarView: View {
    @Environment(BrowserState.self) private var browser
    @State private var isAddingProfile = false

    var body: some View {
        VStack(spacing: 0) {
            ProfileSwitcher(isAddingProfile: $isAddingProfile)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            List(selection: Binding(
                get: { browser.selectedTabID },
                set: { if let id = $0 { browser.selectTab(id) } }
            )) {
                ForEach(browser.tabs(in: browser.selectedProfileID)) { tab in
                    TabRow(tab: tab)
                        .tag(tab.id)
                        .contextMenu {
                            Button("Close Tab") { browser.closeTab(tab.id) }
                        }
                }
            }
            .listStyle(.sidebar)

            Button {
                browser.newTab()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .sheet(isPresented: $isAddingProfile) {
            NewProfileSheet()
        }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    @Environment(BrowserState.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack {
            Image(systemName: tab.page.isLoading ? "circle.dotted" : "globe")
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
            Spacer()
            if hovering {
                Button { browser.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct ProfileSwitcher: View {
    @Environment(BrowserState.self) private var browser
    @Binding var isAddingProfile: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(browser.profiles) { profile in
                let selected = profile.id == browser.selectedProfileID
                Button {
                    browser.selectProfile(profile.id)
                } label: {
                    Circle()
                        .fill(profile.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                        }
                        .overlay {
                            Text(String(profile.name.prefix(1)))
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        }
                }
                .buttonStyle(.plain)
                .help(profile.name)
                .contextMenu {
                    Button("Delete Profile", role: .destructive) { browser.removeProfile(profile.id) }
                        .disabled(browser.profiles.count == 1)
                }
            }
            Button { isAddingProfile = true } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New Profile")
            Spacer()
            Text(browser.selectedProfile.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct NewProfileSheet: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = Color.purple

    var body: some View {
        Form {
            TextField("Name", text: $name)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Create") {
                    browser.addProfile(name: name, colorHex: color.hexString)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }
}

private extension Color {
    var hexString: String {
        let resolved = resolve(in: EnvironmentValues())
        let r = Int((resolved.red * 255).rounded()), g = Int((resolved.green * 255).rounded()), b = Int((resolved.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
