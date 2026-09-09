# Certificates

Some sites are served under a certificate authority the operating system has never heard of, and to a browser those
are indistinguishable from an attack. six carries a list of extra authorities, everything on it switched **off**, and
a switch per entry. `six://settings` ▸ **Privacy** ▸ Certificates

The case it was written for is Russian: since 2022 the western authorities will not issue for a good part of that
internet — banks first of all — and those sites are served under the Ministry of Digital Development's CA instead
(Минцифры, published at [gosuslugi.ru/crt](https://www.gosuslugi.ru/crt)). No Apple machine ships it. `alfabank.ru`
fails the handshake, and the official instructions are to install the certificate into the login keychain, find it in
Keychain Access, open the trust triangle, set *Secure Sockets Layer* to **Always Trust** and type your password.

That works, and it changes what **every** application on the machine trusts, permanently, with nothing to look at
afterwards. This is the same decision kept inside six: a list you can read, a switch you can flip back, and a
certificate that stops mattering the moment it is off.

## What a switch actually does

Less than the keychain does, and the difference is the point.

A site's chain is judged **by the system first**, with the system's own anchors and nothing added
(`ServerTrust.isTrusted`). If it checks out, six answers `.performDefaultHandling` and steps out of the way — WebKit
then does everything it would have done anyway: certificate transparency, its own pinning, its own failure. six
has not touched the ordinary web.

Only a chain the system has already **turned down** is read a second time, and then with the switched-on certificates
*added* to the system's, never in place of them (`SecTrustSetAnchorCertificatesOnly(_, false)` — without that line one
extra anchor would become the only anchor there is, and every other site on the web would fail). The hostname is
checked in the second reading too, so an anchor is an anchor and not a licence to accept a certificate written for
somebody else. Revocation is asked about with `kSecRevocationUseAnyAvailableMethod` and *not* required to answer: on
the networks this feature exists for, an unreachable OCSP responder is the normal case, not the suspicious one.

A chain that fails both readings also gets `.performDefaultHandling` — WebKit is left to fail the navigation the way
it would have anyway. What that *looks* like is the subject of the next section, and for a long time it was nothing at
all.

The cost of that order is one extra trust evaluation per HTTPS connection, and only while something is switched on —
asynchronous, off the main actor, and answered from `trustd`'s cache most of the time. It buys keeping every ordinary
site judged by WebKit alone, which is worth it.

So the promise is smaller than "trusted": switching an authority on cannot make an ordinary site validate differently.
It can only give a chain that had *already* failed a second reading.

## When it fails anyway

`WebPage` has no error page. The one you know from Safari belongs to Safari, and a failed provisional navigation
leaves a `WebPage` exactly as it was — which in a fresh window is white, titled with the host, and silent. six showed
that for every failure it had, including the one it had an answer to: the browser was carrying Минцифры, had it
switched off, and could not say so. It was reported as *"alfabank.ru doesn't open from a Google search"*, which is
what it looks like from the other side.

So two things happen now on a chain that failed both readings.

**The store writes down what it saw.** At the moment of the handshake — the only moment the chain is in hand —
`noteOffer(_:host:)` asks whether any certificate *above the leaf* is byte-for-byte one six carries in a bundle that
is switched **off**, and files the host under that bundle (`CertificateStore.offers`). It is a `Set<Data>` membership
test over two or three certificates: no trust evaluation, no network, and no main-actor work worth measuring, which is
what makes it affordable on the connection every site makes. It happens *before* the `anchors.isEmpty` guard on
purpose — everything switched off is exactly the state this is for.

Nothing is trusted by it. An offer is a sentence and a button.

**The window shows a page** (`PageFailureView`, drawn over the web view). It names the host, says what the system
said, and — when there is an offer — says which authority six is carrying and puts *Trust Russian Trusted CA* next to
*Try Again*. The button is `CertificateStore.setEnabled(_:for:)`, the same call the panel makes, written to the same
setting: a person who says yes here finds the switch where all the others are and can say no again.

`BrowserTab.LoadFailure` is what the two halves meet in. It is set from the navigation feed and cleared by the next
provisional navigation, so a window that succeeds after failing simply stops showing it.

### The feed that used to die with it

`WebPage.navigations` is a **throwing** `AsyncSequence`, and a failed load throws through it. Written as one
`for try await` with a `catch {}` at the end — which is how it was — the loop ended at the first bad address, and the
window stopped observing *every* navigation after that one: no visit written to history, no title kept for the card,
nothing told to the blocker, no scroll put back, and the previous page's capture never cleared. Measured before the
fix: a window sent to a site with an untrusted certificate and then to `example.com` left the second visit out of the
database entirely. `watchNavigations(of:)` now subscribes again after a navigation failure, and only after that one —
a closed page and a dead content process are the page itself ending.

### Where to look

Every failed navigation writes one line under the `load` category, into the file at
`~/Library/Logs/<bundle id>/six.log` and into Console ([logging.md](logging.md)):

```
2026-09-09 14:30:31.108 [load] error: https://alfabank.ru/ failed: The certificate for this
server is invalid. … (NSURLErrorDomain -1202) — six carries ru.trusted-ca, switched off
```

The clause after the dash is the offer, and it is there to tell *six has no answer to this* from *six had one and
never looked*. With DevTools capture on, the same failure is also filed under the window as a console error and a
failed `document` request, so `list_console_messages` and `list_network_requests` carry it over MCP — the one request
page instrumentation can never see, because the page never ran ([devtools.md](devtools.md)).

## Where it is wired in

| | |
|---|---|
| `CertificateStore` | the list, the switches, the imported files, and `decide(_:)` — the answer to one handshake |
| `ServerTrust` | the two evaluations, off the main actor |
| `BundledCertificates` | the authorities six ships, as base64 DER in the source |
| `CertificatesView` | the panel: a row per bundle, fingerprints on demand |
| `PageFailureView` | what a window shows when the load did not happen, and the offer's button |
| `BrowserTab` → `TabNavigationDecider.decideAuthenticationChallengeDisposition(for:)` | a page's own handshakes |
| `Downloads` → `Transfers.urlSession(_:task:didReceive:)` | six fetches downloads itself, so they ask separately |

Both call sites reach the store through `CertificateStore.shared`. Anchors are not per-profile and not per-window —
they are what *six* trusts — and one of the two callers is a `URLSession` delegate that lives off the main actor.

The download half is not an afterthought: `WebPage` has no download delegate, so six rebuilds the request and runs the
transfer on a `URLSession` of its own ([links.md](links.md)). Without the second wiring a bank statement would fail to
download from a site six can perfectly well show.

## No build flag

The obvious shape for this was a "Russian build" — a compile-time switch, one binary for people who need Минцифры and
one for everyone else. It is the wrong shape twice over. Two binaries means one of them trusts something the other
does not without saying so anywhere a person can look; and the interesting half of the question — *does this person
want it* — cannot be answered at compile time anyway. One build, one list, everything off until asked.

## What six ships

Three certificates, all RSA, all in `BundledCertificates.swift` as base64 DER with the fingerprint their authority
publishes written above each one:

| | valid until | SHA-256 |
|---|---|---|
| Russian Trusted **Root** CA | 2032-02-27 | `d26d2d02…ca8ecf31` |
| Russian Trusted **Sub** CA (2022) | 2027-03-06 | `bbbde210…d8b3fd9b` |
| Russian Trusted **Sub** CA (2024) | 2029-07-19 | `21557850…7d88a3f2` |

Both intermediates, because which one a site is under depends on when its certificate was issued, and a server that
does not send its intermediate needs six to already have it. The root alone is enough for a server that does send it —
`alfabank.ru` does.

The bytes are in the source rather than in `Resources/` deliberately: a trust anchor is exactly the kind of thing that
should be readable in a diff and impossible to swap out by dropping a file into the app bundle.

The **GOST**-signed pair published beside these is deliberately absent. Apple's Security framework has no
GOST R 34.10 at all, so those certificates cannot be verified on this platform whatever six does with them; they are
for browsers that ship their own crypto.

## Adding your own

**Add Certificate…** takes a `.pem`, `.crt`, `.cer` or `.der` — one certificate or a whole chain in one file — copies
it into `Application Support/<bundle id>/Certificates/` and switches it on. The copy matters: the file you picked may
be on a volume that goes away, and a trust decision that stops working when a disk is unmounted is a mystery rather
than a setting. **Remove** deletes the copy; a built-in has no file to delete and is switched off instead.

A certificate already in the list is refused by fingerprint, so importing the same file twice does not give you two
rows that disagree.

### Reading the file

PEM is parsed by splitting on `\.isNewline`, not on `"\n"`. A Swift `Character` is a grapheme cluster and CRLF is
**one** of them, so a `"\n"` separator does not match a line ending in a file that has them. The Ministry's own
`.pem` is such a file — the first block LF, the second CRLF — and splitting the other way silently swallowed the
root, leaving a bundle that looked imported and vouched for nothing.

### The dates in the list

Read out of the DER by hand (`CertificateValidity`, ~30 lines of ASN.1: step into two SEQUENCEs, skip up to four
fields, read two `UTCTime`/`GeneralizedTime` values). `SecCertificateCopyValues` would answer it in one call and is
macOS-only; six runs on the phone too, and one code path that works everywhere is worth thirty lines. Nothing here
decides anything — the dates are for the line under the name, and `Security` does the judging. Checked against
`openssl x509 -dates` on all four published certificates, GOST included.

## A trap worth knowing about

`SecTrustEvaluateAsyncWithError` **must be called from the queue it is handed**. Not merely *with* it — the header
says so and Security enforces it with `dispatch_assert_queue`, which is a `SIGTRAP` and no message. Calling it from
wherever the task happened to be running kills the app on the first site that needs this feature. `ServerTrust.evaluate`
does `queue.async { … }` around the call for exactly that reason; it was found by evaluating a real bank's chain from
a command-line tool, not by reading the documentation.

## What is not covered

- **Client certificates.** `decide(_:)` only answers `NSURLAuthenticationMethodServerTrust`; a site asking six to
  *present* a certificate gets default handling, which means the request fails. Some Russian government sites want
  one. Not built.
- **Sites that need GOST ciphersuites**, as opposed to a GOST-signed certificate. Nothing on Apple's platforms speaks
  those, and no list of anchors changes it.
- **The sites six itself fetches** outside a page and outside a download — filter lists, search suggestions, MCP
  registries — which use `URLSession.shared` and are not wired to the store. None of them point anywhere this matters.
- **An offer for an authority six does not carry.** The question is asked by comparing bytes against the bundles that
  are switched off, so a site under some third authority fails with the system's sentence and a pointer to the
  Certificates panel, which is all six honestly knows.
- **Which bundle carried which site.** The panel's "Used for …" line files a host under *every* switched-on bundle
  rather than re-walking the chain to find the one that mattered. With one bundle on, which is the usual case, that is
  exactly right; with three it is a hint. It is in memory only and goes when six quits — it exists to answer *is this
  doing anything*, not to become a second history.
