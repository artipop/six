# Certificates

Some sites are served under a certificate authority macOS has never heard of, and
to a browser such a site is indistinguishable from an attack. The commonest case
is Russian: since 2022 the western authorities will not issue for a good half of
that internet — banks first of all — and those sites are served under the
**Ministry of Digital Development's** CA instead. No Apple machine ships it, and
`alfabank.ru` simply does not open.

The official way to fix it is to install the certificate into the login keychain
and mark it *Always Trust* by hand. That works, and it changes what **every
application on the machine** trusts, permanently, with nothing to look at
afterwards.

VI keeps the same decision inside itself: **Settings ▸ Privacy ▸ Certificates** — a list
you can read, a switch you can flip back, and a certificate that stops mattering
the moment it is off.

**Everything on the list is off until you turn it on.**

## What a switch actually does

Less than the keychain does, and that is the point.

A site's chain is **judged by the system first**, with the system's own anchors
and nothing added. If it checks out, VI steps out of the way and WebKit does
everything it would have done anyway. The ordinary web is not touched at all.

**Only a chain the system has already turned down is read a second time** — and
then the switched-on certificates are *added* to the system's, never put in their
place. The hostname is checked in the second reading too: an anchor stays an
anchor and does not become a licence to accept a certificate written for somebody
else.

Hence the promise, and it is smaller than "trusted":

> turning an authority on **cannot** make an ordinary site validate differently.
> It can only give a second reading to a chain that has **already** failed.

Trust stays inside VI. Nothing else on the machine gets it, and the switch takes
it back.

## When a site does not open

The window used to simply stay white. `WebPage` has no error page of its own —
the one you know from Safari belongs to Safari — so the browser said nothing,
including in the case where it had the answer: the Ministry's certificates were
inside it, switched off, with nowhere to say so.

Now the window shows a page: which address it was, what the system said, and —
when the site's certificate was issued by an authority VI **carries and has not
switched on** — which one, and a **Trust Russian Trusted CA** button next to
**Try Again**.

That button is the same switch as the one in **Settings ▸ Privacy ▸
Certificates**, written to the same place. Saying yes here is not saying yes
somewhere off to the side: the list stays the same list, and it can be switched
off there.

If the authority is one VI does not carry, the page says only what it honestly
knows: the chain could not be traced, and your own certificate can be added in
settings.

## What is already on the list

Three Ministry certificates: the root and two intermediates (2022 and 2024) —
which one a site needs depends on when its certificate was issued, and a server
that does not send its own intermediate needs us to have it already.

Each row says what it is, how long it is valid, and, on demand, the fingerprint
you can check against the published one. An expired one is labelled as such:
*expired — it can no longer vouch for anything*.

The **"Used for …"** line answers whether what you switched on is doing anything
at all. It is a hint for the session, not a second history: it is forgotten on
quit.

## Your own certificate

**Add Certificate…** takes a `.pem`, `.crt`, `.cer` or `.der` — one certificate
or a whole chain in one file — copies it in and switches it on. The copy matters:
the file may have been on a volume that goes away, and a trust decision that
stops working when a disk is unmounted is a mystery rather than a setting.

**Remove** deletes the copy; a built-in one has no file to delete and is switched
off instead. The same certificate will not be added twice — it is recognised by
its fingerprint.

## What this does not cover

- **Client certificates** — where a site asks the browser to present one. Some
  Russian government sites want that; not built.
- **GOST ciphersuites**, as opposed to a GOST-signed certificate. No Apple
  platform speaks them, and no list of anchors changes that. For the same reason
  the Ministry's GOST-signed pair is deliberately absent: there is nothing on
  this platform that could verify it.
