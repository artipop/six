import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @State private var showAgentPanel = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showAgentPanel: $showAgentPanel)
            NiriStripView()
                .overlay(alignment: .bottom) {
                    if !browser.layout.isOverview {
                        AssistantBar()
                    }
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .inspector(isPresented: $showAgentPanel) {
            AgentPanel()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 700)
        }
        .tint(browser.selectedProfile.color)
        .navigationTitle(browser.selectedTab?.title ?? "six")
        .focusedSceneValue(\.toggleAgentPanel, FocusAddressBarAction { showAgentPanel.toggle() })
        .onKeyPress(.escape) {
            guard browser.layout.isOverview else { return .ignored }
            browser.exitOverview()
            return .handled
        }
    }
}

/// Slim bar in the (hidden) title bar area: profiles on the left, workspace position on the right.
private struct TopBar: View {
    @Binding var showAgentPanel: Bool
    @Environment(BrowserState.self) private var browser
    @State private var isAddingProfile = false

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 10) {
            Color.clear.frame(width: 68, height: 1) // room for the window buttons
            ProfileSwitcher(isAddingProfile: $isAddingProfile)
            Spacer(minLength: 12)
            WorkspaceStepper()
            Button { browser.toggleOverview() } label: {
                Image(systemName: layout.isOverview ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
            }
            .buttonStyle(.borderless)
            .help("Overview (⌥O)")
            Button { showAgentPanel.toggle() } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Agent panel (⌘⇧A)")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $isAddingProfile) { NewProfileSheet() }
    }
}

/// The workspace indicator with a chevron on each side, so the vertical stack is reachable by mouse.
private struct WorkspaceStepper: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 6) {
            Button { browser.focusWorkspace(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!layout.canFocusWorkspace(-1))
                .help("Workspace above (⌥↑)")
            WorkspacePips()
            Button { browser.focusWorkspace(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!layout.canFocusWorkspace(1))
                .help("Workspace below (⌥↓)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Vertical position in the workspace stack — niri's workspace indicator, laid out horizontally.
private struct WorkspacePips: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 4) {
            ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                let current = index == layout.focusedWorkspaceIndex
                Capsule()
                    .fill(current ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.quaternary))
                    .frame(width: current ? 20 : 8, height: 6)
                    .overlay {
                        if workspace.isEmpty && !current {
                            Capsule().strokeBorder(.tertiary, lineWidth: 1)
                        }
                    }
                    .onTapGesture { browser.focusWorkspace(at: index) }
                    .help(workspace.isEmpty ? "Empty workspace" : "\(workspace.columns.count) window(s)")
            }
        }
        .animation(NiriLayout.switchAnimation, value: layout.focusedWorkspaceIndex)
    }
}

private struct ProfileSwitcher: View {
    @Environment(BrowserState.self) private var browser
    @Binding var isAddingProfile: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(browser.profiles) { profile in
                let selected = profile.id == browser.selectedProfileID
                Button {
                    browser.selectProfile(profile.id)
                } label: {
                    Circle()
                        .fill(profile.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                        }
                        .overlay {
                            Text(String(profile.name.prefix(1)))
                                .font(.system(size: 9, weight: .bold))
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

// MARK: - Focus plumbing for ⌘L

struct FocusAddressBarAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var focusAddressBar: FocusAddressBarAction?
}
