# 7. Geolocation for sites

A tab is a `WKWebView` of Savoia's own, and the
permission question is one more method of its UI delegate, `PageDelegate`.

Build geolocation in Savoia.

## Read first

[permissions.md](../../permissions.md#geolocation-and-notifications-webkits-c-api-one-header-for-both) and
[permissions.md](../../permissions.md#what-savoia-still-cannot-ask-for). In short: the permission
question is public (`WKUIDelegate` `requestGeolocationPermissionFor`, macOS 27), and the position has to be
supplied by the app through C functions WebKit exports and the SDK does not declare
(`WKContextGetGeolocationManager`, `WKGeolocationManagerSetProvider`, `WKGeolocationPositionCreate`). The
direction is chosen: a bridging header from WebKit's open headers, and a `CLLocationManager` of Savoia's own. The
last attempt (`e64dd24`, taken back out) got as far as "Allow" and a page that waited forever.

The delegate to add the method to is `Savoia/Browser/PageDelegate.swift`, beside the camera and microphone question.

## Order

1. **A position reaches a page at all.** Measure this before building the rest. The first unproven step is getting
   a `WKContextRef` out of the process pool.
2. **`SitePermission.location`**, the question in the bar, the row in settings. `sitePermissions` decodes its list
   whole, and one unknown case forgets every answer — it needs a migration or a decoder that tolerates what it
   does not know.
3. Interface strings through the String Catalog, Russian and English; the guide in both languages.

The system's own location prompt for the app appears once. Tell Artem before it does.

## Checking it in the test suite

`./scripts/permissions-wpt.py geolocation`. Today it is 94/131 with 16 files in harness error — and Safari on
wpt.fyi is exactly the same, because safaridriver cannot do what the tests ask. **So the bar here is not "the same
as Safari" but the absolute number.** The tests ask testdriver for three things, and the runner refuses all three:

- `set_permission({name: 'geolocation'})`, 13 calls — add it to `testdriver_set_permission`
  (`Savoia/Tools/TestDriver.swift`);
- `bidi.permissions.set_permission`, 9 calls — the same thing under another action name; see `act()` in
  `scripts/permissions-wpt.py`;
- `bidi.emulation.set_geolocation_override` — a stand-in position: under `SAVOIA_TESTDRIVER` the provider hands
  that out instead of CoreLocation's. Without it the tests get Artem's real address and cannot agree.

## Done when

- The 16 files are no longer harness errors, and each remaining failure has a named cause.
- The baseline is updated.
- One check by hand: Artem opens a map and presses "my location" — prepare the build.
- [permissions.md](../../permissions.md) and [todo.md](../../todo.md) no longer list it as not built.
