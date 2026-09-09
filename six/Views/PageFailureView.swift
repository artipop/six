import SwiftUI

/// What a window shows when the page did not load.
///
/// It used to show nothing. `WebPage` has no error page of its own — the one you know from Safari
/// belongs to Safari, not to WebKit — so a failed provisional navigation left the window exactly as
/// it was: white, titled with the host, and completely silent about why. Reported as "alfabank.ru
/// doesn't open from a Google search", which is what it looks like from the other side.
///
/// The interesting half is the certificate case. A good part of the Russian internet is served
/// under an authority no Apple machine ships, six *carries* that authority, and it is switched off
/// until somebody says otherwise (`CertificateStore`). So the browser knew the answer and had no
/// way of saying it. When the chain that failed was signed by a bundle six is carrying, this page
/// names it and offers the switch — the same switch as the one in the Certificates panel, written
/// to the same place, so the decision can be read and taken back where the others live.
struct PageFailureView: View {
    let tab: BrowserTab
    let failure: BrowserTab.LoadFailure

    @Environment(CertificateStore.self) private var certificates

    /// The bundle six would have needed, if it is still switched off. Read from the store rather
    /// than from the failure so that switching it on anywhere makes this page stop offering it.
    private var offered: CertificateBundle? {
        guard failure.offeredCertificateBundle != nil else { return nil }
        return certificates.offeredBundle(for: failure.host)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: offered != nil ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("This page didn’t open")
                        .font(.title2.weight(.semibold))
                    Text(failure.host.isEmpty ? (failure.url?.absoluteString ?? "") : failure.host)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let offered {
                        Button {
                            tab.trustOfferedCertificate()
                        } label: {
                            Text("Trust \(offered.name)")
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    }
                    Button(action: tab.retryFailedLoad) {
                        Text("Try Again")
                    }
                    #if os(macOS)
                    Button {
                        tab.load(BuiltInPage.settings.url)
                    } label: {
                        Text("Certificates")
                    }
                    .buttonStyle(.link)
                    .opacity(failure.isCertificateProblem ? 1 : 0)
                    .disabled(!failure.isCertificateProblem)
                    #endif
                }
                .controlSize(.large)
                // The system's own sentence, kept but demoted: it is the thing to paste into a
                // search or a bug report, and the thing nobody wants first.
                Text(verbatim: "\(failure.message) (\(failure.code))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Sized against the window, not in points: a column on a 5K display is not the column
            // this was written in, and a fixed measure is a hairline there.
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var explanation: String {
        if let offered {
            // The whole point of the page, in one sentence: six has it, and it is off.
            return String(localized: """
                This site’s certificate was issued by \(offered.name), an authority six carries and \
                does not trust until you say so. Nothing else on the web is affected by turning it on.
                """)
        }
        if failure.isCertificateProblem {
            return String(localized: """
                This site’s certificate could not be traced back to an authority this Mac trusts. If \
                you have the authority’s certificate, add it under Certificates in settings.
                """)
        }
        return String(localized: "six could not reach this address.")
    }
}
