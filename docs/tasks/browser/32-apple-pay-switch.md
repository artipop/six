# 32. Apple Pay: the switch WebKit keeps off for an app

A page in Savoia has no `PaymentRequest` and no `ApplePaySession`, so a shop's Apple Pay button is absent or dead
and six wpt files differ from Safari ([permissions.md](../../permissions.md#compatibility-web-platform-tests)).
Why is known now, and what is left is one sitting with a card.

## What is measured

8 October 2026, a bare `WKWebView` in a program of forty lines, a page loaded with an `https://` base address
(`isSecureContext` true) that writes `typeof PaymentRequest` and `typeof ApplePaySession` into its own title, so
nothing is run to read it:

| the view | both |
|---|---|
| bare | `undefined` |
| a user script in the page's world, or in a world of its own | `undefined` |
| a non-persistent data store; an application name in the user agent | `undefined` |
| after a call into an earlier page | `undefined` |
| `_setApplePayEnabled:` with `true` on the configuration, or on its `WKPreferences` | `function` |

So nothing Savoia does to its views hides them: WebKit gives them to no app's view unless the app asks, and the
asking is SPI. Safari asks.

## What is not known

Whether a payment can be made. The interfaces being there says nothing about the sheet: `canMakePayments()`, the
merchant validation a shop does against Apple, and whether the system's payment sheet comes up for an app without
the entitlement Safari has (`com.apple.developer.in-app-payments` belongs to an app's own merchant id, and a
browser has no merchant). A button that appears and then fails is worse than one that is absent.

## What to do

1. Set the switch in `BrowserTab.materialize`, behind `responds(to:)`, on a branch.
2. Over `Savoia --mcp`: `typeof PaymentRequest`, then `ApplePaySession.canMakePayments()` and
   `new PaymentRequest([{supportedMethods: 'https://apple.com/apple-pay', data: {…}}], …).canMakePayment()`.
3. With Artem and a card: Apple's own demo (`applepaydemo.apple.com`) to the sheet and through it. A page API that
   wants a person is refused over `--mcp` (AGENTS.md), so the last step is a hand's.
4. The six wpt files, against the baseline (`scripts/permissions-wpt.py payment`).

Done when the sheet has been seen to complete a payment and the switch is on, or it has been seen to fail and
[todo.md](../../todo.md) says "not built" with the reason. An automation tab and a private window get whatever an
ordinary tab gets unless the measurement says otherwise.
