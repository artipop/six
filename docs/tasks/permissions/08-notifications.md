# 8. Site notifications

Build the Notification API for sites. Web Push is not part of it: `webpushd` demands a private entitlement, and
that is recorded as out of reach.

## Read first

[todo.md](../../todo.md#geolocation-and-notifications-webkits-c-api-one-header-for-both). Measured in a throwaway
app: with a persistent data store and a real click, the private delegate method
`_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` is called, the page gets `granted`, and
`new Notification()` reaches the UI process and goes no further — there is no provider. The provider is installed
through C functions (`WKContextGetNotificationManager`, `WKNotificationManagerSetProvider`,
`…DidShowNotification`, `…DidClickNotification`, `…DidCloseNotifications`). Private profiles stay without
notifications, as in Safari.

If [geolocation](07-geolocation.md) is done, the header, the `WKContextRef` and the delegate proxy are shared — do
not duplicate them. If it is not, build the shared part so that it fits both.

## Order

1. A banner appears from `new Notification()` on a real page.
2. A `SitePermission` for notifications (the same decoder trap as geolocation's), and the answer to
   `notificationPermissions` from `SitePermissions`.
3. Shown through `UserNotifications`; a click on the banner goes back to the page and brings its tab forward.
4. Strings in Russian and English, the guide in both.

Service-worker notifications come after, separately.

## What is possible now that was not

A real click. `requestPermission()` needs a user gesture, and `evaluate_javascript` is no longer one — use
`testdriver_click` (`SAVOIA_TESTDRIVER=1`) or the agent's `click`. Then check the line in AGENTS.md about
"`denied` in milliseconds" again, and correct it if it has gone stale.

The system's own notification prompt for the app appears once. Tell Artem before it does.

## Checking it in the test suite

`./scripts/permissions-wpt.py notifications`. Today 187/343 with 16 files in harness error, and Safari on wpt.fyi
is the same — **the bar is the absolute number, not "the same as Safari"**. The tests call
`set_permission({name: 'notifications'})` 16 times and the runner refuses: add it.

Under `SAVOIA_TESTDRIVER` the provider must tell WebKit "shown" and "closed" without posting a banner to the
system, or a run buries Artem under a hundred notifications.

## Done when

- `event-onshow`, `event-onclose`, `shownotification`, `tag` and `instance` are no longer harness errors, and
  each remaining failure has a named cause.
- The baseline is updated.
- A check by hand on a site with notifications (Mattermost) — prepare the build and say what to press.
