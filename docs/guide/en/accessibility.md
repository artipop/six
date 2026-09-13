# The accessibility overlay

**View ▸ Accessibility Overlay** (`⌥⌘A`) draws over the page what macOS
accessibility knows about it — what a person using VoiceOver hears. Every
element gets a box in the colour of its kind, and a label: what it is called
and what can be done with it.

These are the [agent's](/en/agents) eyes, made visible. When an agent asks VI
what is on a page, this is the list it gets — numbered buttons, fields, headings
and regions with their actions. With the overlay on, you can see exactly what it
was shown.

## What is on the screen

| colour | kind | what it is |
|---|---|---|
| green | **Controls** | buttons, links, checkboxes, switches, pop-up lists — and any element the page made pressable |
| blue | **Fields** | somewhere to type |
| dashed purple | **Landmarks** | the large parts of a page: banner, navigation, main content, search, a dialog |
| orange | **Headings** | section headings |
| teal | **Images** | pictures |
| grey | **Text** | the runs of text between the elements |
| red | no name | a control or a field that has no name |

A label reads `button “Save” ▸ press`: the role in your system's language, the
name, and the actions — `press`, `type` (enter text), `increment` /
`decrement`, `pick`.

**A red box** is the most useful thing here. It is a button or a field the page
never gave a name. An agent can find it but cannot tell what it does — and
neither can a person using a screen reader.

## The panel in the corner

In the window's bottom-left corner: how many elements were read and how many
milliseconds it took. The kind names in it are switches — pressing one hides or
shows that kind. **Text** and **Images** start off, or the boxes around every
paragraph would cover everything else.

⟳ (**Read Again**) reads the page again at once; × hides the overlay.

## How it works

The overlay shows **only the part of the page on screen**, and only in the
**focused window**: the tree is read from what is displayed. While you scroll,
the boxes fade; once the page stops, it is read again. A page that changed
without scrolling is read again within a few seconds, or press ⟳.

## The permission

To read this tree VI needs the **Accessibility** permission. The first time the
overlay is turned on, macOS asks for it. If you said no, the panel has an
**Open Privacy & Security** button — turn VI on under **Accessibility** there.

::: tip Why this permission
The page lives in a process of its own, and macOS lets one application read
another's interface only with this permission — even when the "other" is its
own page. VI uses it for nothing but this overlay and an agent's questions about
the page.
:::

The overlay is Mac-only for now.
