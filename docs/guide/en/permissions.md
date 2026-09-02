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

**The red camera or microphone** appears only while a device is actually in use.
One click mutes, another lets the page see and hear again: the page is told it
was muted and the call stays up, which is what the mute button in a call's own
toolbar does. **Blocking** a device from the site menu does stop it — an answer
that only applies to the next call is not an answer.

## The whole list

**Settings ▸ Privacy ▸ Site Permissions** lists every site with a remembered answer, across
profiles, with a switch per device and an `×` that makes the site ask again.
**Forget All** clears them at once.

A private profile keeps its answers only while it is open and never writes them
down.

## The system asks first

The camera and the microphone are behind macOS's own permission, and the system's
prompt comes **first** — once for the whole application, not once per site. So
the very first request you ever make costs two answers, and every one after it at
most one.

## The page's own dialogs

`alert()`, `confirm()`, `prompt()` and the file picker work as everywhere. That
is worth saying out loud: a browser built on these APIs answers all four with
"no" by default, which means quietly not being able to upload a file. Here they
are real.

## What is not there yet

- **screen sharing** (`getDisplayMedia`);
- **geolocation** — the application has the system permission, but the public API
  through which a page could ask for it does not exist yet for this way of
  drawing pages;
- **web push**.

All three run into the same thing and will arrive together with it.
