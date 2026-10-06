# 9. Why Savoia has no `PaymentRequest`

Establish the cause. **Fix nothing without Artem's decision.**

## Measured

`PaymentRequest` and `ApplePaySession` are `undefined` on an https page in Savoia — and equally with the blocker's
page scripts off (`AdvancedRules`, [page-scripts.md](../../page-scripts.md)). Seven wpt files,
`permissions-policy/payment-*` and `reporting/payment-reporting`, differ from Safari on it.

## Guesses, none checked

- The region of the Apple ID — Apple Pay does not work for Artem at all.
- A limit WebKit puts on an app that is not Safari (an entitlement).
- The user scripts that are still installed.

## How to tell them apart

- A minimal app, twenty-five lines, with a `WKWebView` and not one user script: if it is `undefined` there too, it
  is not Savoia.
- Safari on this same Mac: Artem opens a page and reads `typeof PaymentRequest` — ask him.
- WebKit's source on `shouldEnableApplePayAPIs`: read it on the web, do not go by memory.

## Done when

The cause is named and backed by a measurement, with what it would take for Apple Pay to work — or that it cannot
on this Mac.
