# Site permissions

When a site wants the camera, the microphone or the motion sensors, it asks — and
the answer is remembered. It does not ask with a sheet over the whole
application: the question is drawn as a bar **in the window that asked**. A page
that wants the camera is one column out of twenty, and stopping the other
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

## On Windows and Linux

The question is the same there — a bar in the window that asked, with **Block**
and **Allow** — and the answers go into the same table, per site and per profile.
The whole list: on Linux, the camera button in the toolbar; on Windows, **⋯ ▸ Site
permissions** at the right end of the bar. `Delete` on a row forgets the answer,
and the site asks again.

::: warning On Windows the question does not come yet
And it is not six. The WebKit the Windows version runs on today (Playwright's
build) is compiled without the camera and the microphone for pages —
`navigator.mediaDevices` is not there, so a site has nothing to ask with. The bar,
the answer and the list are ready, and will work with the first engine that has
them.
:::

## The page's own dialogs

`alert()`, `confirm()`, `prompt()` and the file picker work as everywhere. That
is worth saying out loud: a browser built on these APIs answers all four with
"no" by default, which means quietly not being able to upload a file. Here they
are real.

On Windows a dialog comes up as a small window over the browser, and its title
says which site is asking; `Enter` answers **OK**, `Esc` answers **Cancel**. A
second page asking waits its turn. Uploading a whole folder does not work there
yet: the page is told the choice was cancelled.

## Screen sharing

When a site asks to see your screen, macOS opens its own picker: the whole screen
or one window. That choice is the permission, so nothing is remembered — the site
asks again next time, as in any browser. While sharing is on, an indicator shows
in the address field beside the camera and the microphone, and clicking it pauses
the sharing alone.

A window that is sharing the screen or holding a call is not unloaded from
memory, even when you scroll the row away from it.

## What is not there yet

- **geolocation** — WebKit now lets a browser answer the permission question, but
  does not hand it the coordinates through public API. So a site is refused at
  once rather than left waiting;
- **site notifications** — a site is refused at once, with no question shown.
  WebKit lets a browser both ask and show them only through undocumented
  functions;
- **web push** — Apple opens it only to its own apps.

Geolocation and notifications can be done, but through undocumented WebKit
functions that any macOS update could change.
