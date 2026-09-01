# Certificates

Some sites are served under a certificate authority the operating system has never heard of, and to a browser those
are indistinguishable from an attack. six carries a list of extra authorities, everything on it switched **off**, and
a switch per entry. **Privacy → Certificates…**

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
then does everything it would have done anyway: certificate transparency, its own pinning, its own error page. six
has not touched the ordinary web.

Only a chain the system has already **turned down** is read a second time, and then with the switched-on certificates
*added* to the system's, never in place of them (`SecTrustSetAnchorCertificatesOnly(_, false)` — without that line one
extra anchor would become the only anchor there is, and every other site on the web would fail). The hostname is
checked in the second reading too, so an anchor is an anchor and not a licence to accept a certificate written for
somebody else. Revocation is asked about with `kSecRevocationUseAnyAvailableMethod` and *not* required to answer: on
the networks this feature exists for, an unreachable OCSP responder is the normal case, not the suspicious one.

A chain that fails both readings also gets `.performDefaultHandling`, which is what puts WebKit's own failure in front
of you instead of a blank window.

The cost of that order is one extra trust evaluation per HTTPS connection, and only while something is switched on —
asynchronous, off the main actor, and answered from `trustd`'s cache most of the time. It buys keeping every ordinary
site judged by WebKit alone, which is worth it.

So the promise is smaller than "trusted": switching an authority on cannot make an ordinary site validate differently.
It can only give a chain that had *already* failed a second reading.

## Where it is wired in

| | |
|---|---|
| `CertificateStore` | the list, the switches, the imported files, and `decide(_:)` — the answer to one handshake |
| `ServerTrust` | the two evaluations, off the main actor |
| `BundledCertificates` | the authorities six ships, as base64 DER in the source |
| `CertificatesView` | the panel: a row per bundle, fingerprints on demand |
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
- **Which bundle carried which site.** The panel's "Used for …" line files a host under *every* switched-on bundle
  rather than re-walking the chain to find the one that mattered. With one bundle on, which is the usual case, that is
  exactly right; with three it is a hint. It is in memory only and goes when six quits — it exists to answer *is this
  doing anything*, not to become a second history.
