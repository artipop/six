#if os(macOS)
import AppKit
#endif
import SwiftUI
import WebKit

/// The extensions panel: what is installed, what each one can and cannot do here, and the way in —
/// a folder or an archive, since `WKWebExtension` only takes an unpacked extension.
struct ExtensionsView: View {
    @Environment(ExtensionStore.self) private var extensions
    @Environment(\.dismiss) private var dismiss
    @State private var pending: PendingInstall?
    @State private var failure: String?

    /// An extension read but not yet adopted — the dialog between picking a file and running it.
    struct PendingInstall: Identifiable {
        let id = UUID()
        let ext: WKWebExtension
        let compatibility: ExtensionCompatibility
        let staged: (folder: URL, id: String)
        let origin: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                Text("Extensions").font(.headline)
                Spacer()
                Button("Install…", action: pickExtension)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if extensions.installed.isEmpty {
                ContentUnavailableView {
                    Label("No Extensions", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Install one from a folder, a .zip, a .crx or an .xpi. Extensions from the App Store belong to their own apps and cannot be adopted.")
                } actions: {
                    Button("Install…", action: pickExtension)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(extensions.installed) { record in
                        ExtensionRow(record: record)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            Text("Extensions run per profile and never in a private window. What works in six and what does not is measured — a content script runs, but an extension cannot message it or inject anything more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .sheet(item: $pending) { install in
            InstallSheet(install: install) { adopted in
                if adopted { extensions.adopt(install.ext, staged: install.staged, origin: install.origin) }
                pending = nil
            }
        }
        .alert("Could not install", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func pickExtension() {
        #if os(iOS)
        // TODO: the phone wants `.fileImporter` here; a modal panel is a Mac thing.
        failure = String(localized: "Installing an extension from a file is not available on this device yet.")
        #elseif os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ExtensionInstaller.acceptedTypes
        panel.allowsOtherFileTypes = false
        panel.message = String(localized: "Choose an unpacked extension folder, or a .zip / .crx / .xpi archive.")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let (ext, compatibility, staged) = try await extensions.inspect(url)
                pending = PendingInstall(ext: ext, compatibility: compatibility, staged: staged, origin: url.lastPathComponent)
            } catch {
                failure = error.localizedDescription
            }
        }
        #endif
    }

    private var sheetSize: CGSize {
        let screen = Platform.screenSize
        return CGSize(width: (screen.width * 0.36).rounded(), height: (screen.height * 0.56).rounded())
    }
}

private struct ExtensionRow: View {
    @Environment(ExtensionStore.self) private var extensions
    let record: InstalledExtension

    var body: some View {
        let verdict = extensions.compatibility[record.id]
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { record.isEnabled },
                set: { extensions.setEnabled($0, for: record.id) }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name)
                    if !record.version.isEmpty {
                        Text(record.version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let verdict {
                    Label(verdict.summary, systemImage: verdict.symbol)
                        .font(.caption)
                        .foregroundStyle(verdict.verdict == .full ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                if let error = extensions.errors[record.id] {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
                Text("From \(record.origin)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                if let url = extensions.optionsPageURL(for: record) {
                    Button("Open Options Page") { extensions.browser?.newTab(url: url) }
                }
                #if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.folder]) }
                #endif
                Divider()
                Button("Remove", role: .destructive) { extensions.remove(record.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }
}

/// The one moment where saying what will not work is worth something: before it is installed.
private struct InstallSheet: View {
    let install: ExtensionsView.PendingInstall
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = install.ext.icon(for: CGSize(width: 32, height: 32)) {
                    Image(platform: icon).resizable().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.title)
                }
                VStack(alignment: .leading) {
                    Text(install.ext.displayName ?? "Extension").font(.headline)
                    Text([install.ext.displayVersion, "manifest v\(Int(install.ext.manifestVersion))"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let description = install.ext.displayDescription, !description.isEmpty {
                Text(description).font(.callout)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label(install.compatibility.summary, systemImage: install.compatibility.symbol)
                        .foregroundStyle(install.compatibility.verdict == .full ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                    ForEach(install.compatibility.details, id: \.self) { detail in
                        Text("• \(detail)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !permissions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("It will be granted").font(.caption).foregroundStyle(.secondary)
                    Text(permissions).font(.caption)
                }
            }
            if !hosts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On these sites").font(.caption).foregroundStyle(.secondary)
                    Text(hosts).font(.caption)
                }
            }

            Text("From \(install.origin). Nothing checks who made it — an extension can read and change the pages it is given.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Install") { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var permissions: String {
        install.ext.requestedPermissions.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var hosts: String {
        install.ext.requestedPermissionMatchPatterns.map(\.description).sorted().joined(separator: ", ")
    }
}

/// The extensions' own buttons, in the top bar: one per enabled extension with an action, drawn for
/// the focused window because that is the tab an extension acts on.
struct ExtensionActionBar: View {
    @Environment(ExtensionStore.self) private var extensions
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        let actions = tab.map { extensions.actions(for: $0) } ?? []
        // Reading the revision here is what redraws a badge or an icon the extension changed.
        let _ = extensions.actionRevision
        HStack(spacing: 6) {
            ForEach(actions, id: \.record.id) { pair in
                ExtensionActionButton(record: pair.record, action: pair.action, tab: tab)
            }
        }
    }
}

private struct ExtensionActionButton: View {
    @Environment(ExtensionStore.self) private var extensions
    let record: InstalledExtension
    let action: WKWebExtension.Action
    let tab: BrowserTab?
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            guard let tab else { return }
            extensions.performAction(record, for: tab, anchor: frame)
        } label: {
            ZStack(alignment: .topTrailing) {
                if let icon = action.icon(for: CGSize(width: 16, height: 16)) {
                    Image(platform: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                }
                if !action.badgeText.isEmpty {
                    Text(action.badgeText)
                        .font(.system(size: 8))
                        .padding(.horizontal, 3)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(!action.isEnabled || tab == nil)
        .help(action.label ?? record.name)
        .background {
            #if os(macOS)
            // The popup is WebKit's own `NSPopover`; all six has to do is say where it points.
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, rect in
                    guard let window = NSApp.mainWindow, let content = window.contentView else { return }
                    let flipped = NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                    frame = flipped
                }
            }
            #endif
        }
    }
}

extension FocusedValues {
    @Entry var showExtensions: FocusAddressBarAction?
}
