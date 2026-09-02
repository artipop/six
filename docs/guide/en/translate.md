# Translating a page

Translation runs **on the machine**, through what the system already has: no key,
no quota, and nothing sent to anybody. A language pack is downloaded once and
then works offline.

| | |
|---|---|
| `⌘⇧L` | translate the page |
| `⌥⇧T` | translate the selection |
| **View ▸ Translate Page / Translate Selection…** | the same thing |

The control lives in the address field, because that is where you go to *ask* for
a translation. When a page is not in your language, it offers itself.

## While it works

A bar appears above the page — not six pixels at the end of a long address, but a
sentence where the page is:

| | |
|---|---|
| **Downloading `<language>` — this continues in the background** | the system is missing a language pack. It reports no byte count, so the bar does not invent one |
| **Translating into `<language>`…** | in progress, with how much of it is done |
| the error, with its reason | and a **Try Again** button |

**Stop** ends it. The bar goes when there is nothing left to say: a finished
translation is visible in the address field and speaks for itself.

## The original and the translation

**Show Original** and **Show Translation** flip the page back and forth. The
translation is not thrown away — it is a toggle, not a stop.

**Always Translate `<language>`** remembers the decision for that language.

## What it will not do

- if the system has not got the language, VI says so and where to add it: System
  Settings › General › Language & Region › Translation Languages;
- a pair the system does not have at all is reported as such;
- a page with nothing to translate yet (still loading) says so;
- sometimes the page's language cannot be told — then pick it yourself through
  **Translate to…**.
