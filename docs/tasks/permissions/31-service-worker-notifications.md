# 31. What a service worker's notification still lacks

Notifications for sites are built ([permissions.md](../../permissions.md#notifications)): a page's
`new Notification()` is a banner, and a service worker's `registration.showNotification()` is one too. The second
kind is shown and little else. This is what is missing.

## Read first

[permissions.md](../../permissions.md#notifications) and `Savoia/Browser/SiteNotifications.swift`. A worker's
notification arrives on the process's shared manager with **no page** (`WKNotificationGetIsPersistent`), so no tab
and no profile come with it.

## What to build

1. **The profile.** Today it is shown when the origin is allowed in *any* profile. `WKNotificationCopyDataStoreIdentifier`
   names the data store, and a profile's store is made from an identifier (`BrowserState.dataStore(for:)`): ask the
   answer of that profile.
2. **`clients.openWindow` from `notificationclick`.** WebKit asks the data store's delegate
   (`_WKWebsiteDataStoreDelegate`, `openWindowFromServiceWorker`); nothing answers, so a click that should open the
   site's page opens nothing unless a tab of the site is already there. It becomes a tab in the store's profile.
3. **The icon.** `WKNotificationCopyIconURL` is there; a `UNNotificationAttachment` wants a file. `icon-fetch` in
   wpt waits for the fetch to pass through the worker.
4. **The test stand's lifetime.** WebKit refuses to `close()` a persistent notification younger than its minimum
   lifetime, which leaves nine wpt subtests counting notifications their own cleanup could not remove. WebKit's
   runner overrides it (`WKWebsiteDataStoreConfigurationSetOverridePersistentNotificationMinimumLifetimeForTesting`);
   Savoia makes its stores with `WKWebsiteDataStore(forIdentifier:)` and has no configuration to set it on. First
   measure that the lifetime is the cause — it is read from WebCore, not seen.

Action buttons (`actions`) are not in WebKit at all and are not part of this.

## Checking it

`./scripts/permissions-wpt.py notifications` — 231 of 369 today. `shownotification`, `registration-association`,
`getnotifications-across-processes` and `icon-fetch` are the files this moves.

By hand: a site that notifies from a worker, with no tab of it open, and a click on the banner.
