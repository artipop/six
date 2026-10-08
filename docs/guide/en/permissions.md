# Site permissions

When a site wants the camera, the microphone, your location or to send notifications, it asks — and
the answer is remembered. It does not ask with a sheet over the whole
application: the question is drawn as a bar **in the tab that asked**. A page
that wants the camera is one tab out of twenty, and stopping the other
nineteen to answer for it would be a browser mistaking a page for itself.

An answer is filed **per site and per profile**. The camera and the microphone
are remembered separately even when a site asks for both: a call asks for both at
once, and a page that later wants only the microphone should not have to ask
again.

## In the address field

**The lock (or globe)** becomes a menu as soon as the site has been answered
about anything: flip an answer, forget the site's choices, or open the whole
list. While there is nothing decided for a site the icon stays plain — a control
that is always there and usually empty teaches people to ignore it.

**The red camera and the red microphone** appear only while a device is actually
in use — each has an icon of its own, so a call shows two. A click mutes that
device alone, another brings it back: you can turn the camera off and stay heard. the page is told it
was muted and the call stays up, which is what the mute button in a call's own
toolbar does. **Blocking** a device from the site menu does stop it — an answer
that only applies to the next call is not an answer.

## The whole list

**Configuration ▸ Privacy ▸ Site Permissions** lists every site with a remembered answer, across
profiles, with a switch per device and an `×` that makes the site ask again.
**Forget All** clears them at once.

A private profile keeps its answers only while it is open and never writes them
down.

## The system asks first

The camera and the microphone are behind macOS's own permission, and the system's
prompt comes **first** — once for the whole application, not once per site. So
the very first request you ever make costs two answers, and every one after it at
most one.

Location goes the other way round: you answer the site first — **Allow** or
**Block** in the bar — and only after the first Allow does macOS ask, once, for
the whole application. With Location Services off for Savoia (System Settings ▸
Privacy & Security ▸ Location Services) a site is told the position is
unavailable, however often it is allowed.

Blocking location from the site's menu takes effect with the next request: a
page already following your position stops when it is reloaded.

## Notifications

A site can ask to send you notifications — but only in answer to something you
did on the page, a button pressed for instance. The question comes in the same
bar: **Allow** or **Block**. An allowed site shows its notifications through
macOS's Notification Centre; before the very first one the system asks, once,
for the whole application. Clicking a notification opens Savoia on the tab that
sent it.

If nothing appears although the site is allowed, look at System Settings ▸
Notifications ▸ Savoia, and at the Focus that is on.

A private profile has no notifications. Neither is there web push — a
notification from a site that is not open: Apple opens that only to its own
apps.

## The page's own dialogs

`alert()`, `confirm()`, `prompt()` and the file picker work as everywhere. A
dialog appears in the tab whose page raised it and names the site, so it is clear
who is asking. Close the tab and its dialogs go with it. While an agent is working
on the page, it may answer too ([agents](/en/agents#what-an-agent-can-do-in-the-browser)).

## Screen sharing

When a site asks to see your screen, macOS opens its own picker: the whole screen
or one window. That choice is the permission, so nothing is remembered — the site
asks again next time, as in any browser. While sharing is on, an indicator shows
in the address field beside the camera and the microphone, and clicking it pauses
the sharing alone.

A tab that is sharing the screen or holding a call is not unloaded from memory,
even when you switch to another.

## What is not there yet

- **web push** — Apple opens it only to its own apps;
- **Apple Pay on sites** — the Apple Pay button is missing or does nothing: a
  page in Savoia is not given the functions it needs. Why is not yet known.

Location and notifications are built on undocumented WebKit functions that any
macOS update could change.
