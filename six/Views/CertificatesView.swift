import SwiftUI
import UniformTypeIdentifiers

/// What six trusts on top of what the machine trusts, and the switch for each one.
///
/// Opened from the Privacy menu. Everything here starts off; see `CertificateStore` for what
/// switching one on actually does, and [certificates.md](../../docs/certificates.md) for why the
/// answer is not "put it in the keychain".
struct CertificatesView: View {
    @Environment(CertificateStore.self) private var certificates
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var failure: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                Text("Certificates").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            List {
                Section {
                    ForEach(certificates.bundles) { bundle in
                        BundleRow(bundle: bundle,
                                  isExpanded: expanded.contains(bundle.id),
                                  toggleDetail: { toggle(bundle.id) })
                    }
                } header: {
                    Text("Extra Certificate Authorities")
                } footer: {
                    Text("A site is checked against the system's certificate authorities first. These are only consulted for a site the system has already turned down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Text("Trust here belongs to six alone — nothing else on this machine is affected, and switching one off takes it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Certificate…") { importing = true }
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.x509Certificate, .data]) { result in
            guard case .success(let url) = result else { return }
            do {
                try certificates.add(contentsOf: url)
            } catch {
                failure = error.localizedDescription
            }
        }
        .alert("Could not add the certificate", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Relative to the screen, like the rest of the layout.
    private var sheetSize: CGSize {
        let screen = Platform.screenSize
        return CGSize(width: (screen.width * 0.36).rounded(), height: (screen.height * 0.56).rounded())
    }
}

private struct BundleRow: View {
    @Environment(CertificateStore.self) private var certificates
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let bundle: CertificateBundle
    let isExpanded: Bool
    let toggleDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { certificates.isEnabled(bundle.id) },
                    set: { certificates.setEnabled($0, for: bundle.id) }
                ))
                .labelsHidden()
                VStack(alignment: .leading, spacing: 3) {
                    Text(bundle.name)
                    Text(bundle.detail).font(.caption).foregroundStyle(.secondary)
                    if let used = certificates.usedFor[bundle.id], !used.isEmpty {
                        Label(hosts(used), systemImage: "lock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if expired {
                        Label("Expired — it can no longer vouch for anything", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Menu {
                    if let source = bundle.source {
                        // six is a browser; the page these came from opens in it like any other.
                        Button("Open the Publisher's Page") {
                            browser.newTab(url: source)
                            dismiss()
                        }
                        Button("Copy Address") { Platform.copy(source.absoluteString) }
                    }
                    Button(isExpanded ? "Hide Details" : "Show Details", action: toggleDetail)
                    if !bundle.isBuiltIn {
                        Divider()
                        Button("Remove", role: .destructive) { certificates.remove(bundle.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if isExpanded {
                // The fingerprint is the whole point of showing anything: it is the one field that
                // can be compared against what the authority published, which is the only way to
                // know that what is switched on is what was meant to be switched on.
                ForEach(bundle.certificates) { certificate in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(certificate.name).font(.caption)
                        Text(certificate.readableFingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let validity = validity(of: certificate) {
                            Text(validity)
                                .font(.caption2)
                                .foregroundStyle(certificate.isExpired ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        }
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleDetail)
    }

    private var expired: Bool {
        !bundle.certificates.isEmpty && bundle.certificates.allSatisfy(\.isExpired)
    }

    private func validity(of certificate: TrustedCertificate) -> String? {
        guard let notAfter = certificate.notAfter else { return nil }
        let until = notAfter.formatted(date: .abbreviated, time: .omitted)
        return certificate.isExpired
            ? String(localized: "Expired \(until)")
            : String(localized: "Valid until \(until)")
    }

    /// The sites this bundle carried since launch, newest names last — three, then a count, because
    /// the row is one line and the question it answers is only "is this doing anything".
    private func hosts(_ used: Set<String>) -> String {
        let sorted = used.sorted()
        guard sorted.count > 3 else { return String(localized: "Used for \(sorted.joined(separator: ", "))") }
        let shown = sorted.prefix(3).joined(separator: ", ")
        return String(localized: "Used for \(shown) and \(sorted.count - 3) more")
    }
}

extension FocusedValues {
    @Entry var showCertificates: FocusAddressBarAction?
}
