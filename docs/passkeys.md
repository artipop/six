# Passkeys and passwords — plan

*Not built yet. Tracked in [todo.md](todo.md).*

Goal: on any site, "Sign in with a passkey" opens the system sheet — Touch ID, iCloud Keychain passkeys, a security
key, or the QR flow to a phone — and saved passwords autofill the way they do in Safari. Nothing six-specific in the
UI; the work is making WebKit's WebAuthn reach the platform authenticator from *our* process.

## What decides everything: the entitlements

WebKit implements WebAuthn (`navigator.credentials.create/get`) itself, but in a third-party app it only talks to the
platform authenticator when the app carries Apple's browser entitlements:

| entitlement | what it unlocks | how to get it |
|---|---|---|
| `com.apple.developer.web-browser` | the app is a web browser: default-browser candidacy, and the base for the rest | request form on developer.apple.com (Apple approves) |
| `com.apple.developer.web-browser.public-key-credential` | WebAuthn in `WKWebView` uses the system passkey UI and iCloud Keychain; also unlocks `ASAuthorizationWebBrowserPublicKeyCredentialManager` | same request, granted together |

Both are managed capabilities: they need the Developer Program, an App ID with the capability, and a provisioning
profile — a plain ad-hoc Debug signature won't carry them. Until they are granted `PublicKeyCredential` is either
absent from the page or fails, which is what six most likely does today.

## Phases

### 0. Measure (an afternoon)

- Open <https://webauthn.io> and <https://passkeys.io> in six; note what `navigator.credentials` does with the
  current signature. Also test `ASWebAuthenticationSession`-free password autofill: does the Passwords app offer
  anything in our `WebPage`?
- Check `WebPage.Configuration` / `WKWebViewConfiguration` for anything credential-related in the macOS 27 SDK
  (`grep -i "credential\|webAuthn\|passkey"` in the WebKit swiftinterface) — the new SwiftUI `WebPage` may expose
  more than `WKWebView` did.

### 1. Paperwork (start now, it is the long pole)

- Developer Program membership for the team, an explicit App ID for `org.deffun.six`.
- Submit the web-browser entitlement request; the form asks what the browser is and for a build to look at.
  Meanwhile, keep building unsigned.
- Once granted: capability on the App ID, Developer ID / development profile with both entitlements, add them to
  `six.entitlements`, sign the Debug build with the profile (`CODE_SIGN_STYLE = Manual` or automatic with the team
  set). Sandbox stays off — the browser entitlement does not require it.

### 2. Passkeys through WebKit (the real thing)

- With the entitlements, WebKit shows the system sheet on `create()`/`get()` with no code from us. Verify: platform
  passkey (Touch ID), iCloud Keychain sync, security key over USB/NFC, cross-device (QR → iPhone), conditional UI
  (`mediation: "conditional"` — passkeys offered inside the username field's autofill).
- Six-specific care:
  - the sheet is anchored to the *window*; a passkey request from a column that is a placeholder card (no live
    `WebView`, see [layout.md](layout.md)) or from an agent-driven background window must be surfaced — focus that
    column first, or refuse with a clear message in the transcript;
  - the overview (⌥O) must not swallow the sheet;
  - profiles: passkeys live in iCloud Keychain, not in the `WKWebsiteDataStore`, so they are *not* per profile. That
    matches Safari and is fine; document it.

### 3. Passwords

- With the browser entitlement, password autofill from iCloud Keychain/Passwords works in `WKWebView` the way it does
  in Safari (verify on macOS 27 — this changed across releases). If not, the fallback is the **Passwords app
  extension** route Apple offers Chrome/Firefox, which is a browser extension API we don't have; realistically, this
  half depends on the entitlement.
- Saving new passwords: WebKit prompts to save when it recognises a login form; make sure the prompt is not hidden
  behind our chrome.

### 4. Fallback if Apple says no

- `ASAuthorizationController` with `ASAuthorizationPlatformPublicKeyCredentialProvider` works *without* the browser
  entitlement — but only for relying parties whose associated domains include our app, i.e. not for arbitrary
  sites. Useful for nothing here except a six account, if one ever exists.
- Bridging WebAuthn ourselves (a JS shim over `navigator.credentials` that calls the app, which talks CTAP2 to a
  USB key) is possible for hardware keys only, and is a project of its own. Not planned.
- So the honest answer without the entitlement is "passkeys don't work in six"; the plan is to get the entitlement.

## Open questions

- Does the macOS 27 `WebPage` API ship any WebAuthn hooks of its own (delegate for the request, so we could at least
  route it to a focused column)? Phase 0 answers this.
- Whether the conditional-UI autofill works with our custom start page and address field — it targets `<input
  autocomplete="webauthn">` inside the page, so it should, but the field focus dance in `WindowChrome` may interfere.
