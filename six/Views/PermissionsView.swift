import SwiftUI

/// Every site that was ever answered about the camera, the microphone or the motion sensors — the
/// place to change an answer you are not standing on. Opened from the Privacy menu; the site icon in
/// a window's address field does the same for the one site in front of you.
///
/// Answers given in a private profile are not here, because they were never written down.
struct PermissionsView: View {
    @Environment(SitePermissions.self) private var permissions
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "video.badge.checkmark")
                Text("Site Permissions").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if permissions.sites.isEmpty {
                ContentUnavailableView {
                    Label("No Sites Yet", systemImage: "video.slash")
                } description: {
                    Text("When a site asks for the camera, the microphone or the motion sensors, your answer is remembered here.")
                }
            } else {
                List {
                    ForEach(permissions.sites) { site in
                        SiteRow(site: site, profileName: name(of: site.profileID))
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("macOS asks once for six itself; this list is six asking for each site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget All", role: .destructive) { confirmForgetAll = true }
                    .disabled(permissions.sites.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .confirmationDialog("Forget every site's answer?", isPresented: $confirmForgetAll, titleVisibility: .visible) {
            Button("Forget All", role: .destructive) { permissions.forgetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each site will ask again the next time it needs a device.")
        }
    }

    private func name(of profileID: UUID) -> String {
        browser.profiles.first { $0.id == profileID }?.name ?? ""
    }
}

private struct SiteRow: View {
    let site: SitePermissions.Site
    let profileName: String

    @Environment(SitePermissions.self) private var permissions

    private var origin: String { site.origin }
    private var profileID: UUID { site.profileID }

    var body: some View {
        let decided = permissions.decisions(forOrigin: origin, profileID: profileID)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(string: origin)?.host() ?? origin)
                HStack(spacing: 6) {
                    // The scheme stays visible: `http://example.com` and `https://example.com` are
                    // two sites to the web platform, so they are two rows here.
                    Text(origin).font(.caption2).foregroundStyle(.tertiary)
                    if !profileName.isEmpty {
                        Text(profileName).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            ForEach(SitePermission.allCases) { permission in
                if let allowed = decided[permission] {
                    Toggle(isOn: Binding(
                        get: { allowed },
                        set: { permissions.set($0, permission, forOrigin: origin, profileID: profileID) }
                    )) {
                        Label(permission.label, systemImage: permission.symbol)
                            .labelStyle(.iconOnly)
                    }
                    .toggleStyle(.button)
                    .help(allowed ? "Allowed — click to block" : "Blocked — click to allow")
                }
            }
            Button {
                permissions.forget(origin: origin, profileID: profileID)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Ask again next time")
        }
        .padding(.vertical, 2)
    }
}

extension FocusedValues {
    @Entry var showSitePermissions: FocusAddressBarAction?
}
