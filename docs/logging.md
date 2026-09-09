# The log

Where six says what happened, and where to read it back.

Until this existed, every diagnostic in six was `FileHandle.standardError.write(…)` — forty-five of them, in the
shape `[six] blocking: …`. That is a fine shape and it goes nowhere: a Mac app is started by LaunchServices, not by a
shell, so file descriptor 2 has nobody on the other end. Everything six had to say about a failed save, a refused
extension or a certificate that did not check out was written into the dark, and the only way to read the browser was
to launch it from a terminal — which means quitting the browser you were trying to explain.

## The three places it goes

| | where | what it is for |
|---|---|---|
| **the unified log** | `os.Logger`, subsystem = the bundle identifier | Console.app, `log stream`, live |
| **a file** | `~/Library/Logs/<bundle id>/six.log` | after the fact: attach it, `tail -f` it, read it post-crash |
| **standard error** | only when `isatty(2)` | the workflow this repo already had, unchanged |

One call, `Log.info(.blocking, "…")`, reaches all three. The categories are the ones the old prefixes already named —
`app`, `ui`, `pages`, `links`, `browser`, `load`, `blocking`, `certificates`, `extensions`, `bookmarks`, `embed`,
`storage`, `profiles`, `history`, `documents`, `devtools`, `mcp`, `acp`, `keys` — and they are a user interface of a
kind, since Console.app groups by them. Keep the list short enough to read in a filter menu.

### Reading it

```sh
tail -f ~/Library/Logs/org.deffun.six.dev/six.log     # the dev build; drop `.dev` for the real one

/usr/bin/log stream --predicate 'subsystem == "org.deffun.six"'          # live, errors and above
/usr/bin/log show --last 1h --info --debug \
    --predicate 'subsystem == "org.deffun.six"' --style compact          # everything, after the fact
```

`--info --debug` is not optional if you want `Log.info` and `Log.debug` back: `log show` gives you default level and
above unless you ask. **`log` is a zsh builtin in this repo's shell** — write `/usr/bin/log`, or the command dies with
`too many arguments` and no hint as to why.

`six://settings` ▸ **Develop** ▸ Log names the path, reveals it in Finder, and opens Console.

### Three levels, and nothing to configure

`error`, `info`, `debug`, and all three go to all three places. What keeps the tracers quiet is the environment
variable their call site already checks — `SIX_UI_DEBUG`, `SIX_LINKS_TRACE`, `SIX_MCP_TRACE`, `SIX_ACP_TRACE`,
`SIX_PAGE_CACHE_DEBUG` — which is where that decision was already being made and the only place that knows what it
costs. The level is what a *reader* filters on: Console's level menu, `log show --debug`, a `grep` over the file.

A browser with a logging configuration of its own is a browser with a second thing to get wrong.

## The file

Opened once, appended from one serial queue, rotated at **4 MB** to `six.previous.log` with one generation kept. The
queue rather than a lock because these calls come from every actor six has and none of them should wait on a disk; the
cost is that a crash can lose the last few lines, which is exactly why the same line went to the unified log first,
where it is already durable.

It appends across launches. "What happened just before it died" is the question a log exists to answer, and truncating
on start answers it with nothing.

### It is not private

The file records addresses — the one that failed to load is the point of the line — and it sits in the user's own
Library beside a history database and a state snapshot that hold far more. It rotates, so it is bounded; delete it
like any other file. The unified log is marked `.public` for the same reason: an entry that reads `<private>` is not a
diagnostic.

## What deliberately still writes to stderr

Three programs, not the browser: `six --mcp` (`MCPStdioBridge`), `six --probe` (`MCPProbe`), and the table
`SIX_KEY_SELFTEST=1` prints (`KeySelfTest.report`). For a command-line tool stderr **is** the interface — it is being
read by the shell that started it — and routing it through a log file would be sending the answer somewhere else.

## Where it lives

| | |
|---|---|
| `six/Data/Log.swift` | `Log`, the categories, and `LogFile` — the queue, the handle, the rotation |
| `AppSupport.logs` | `~/Library/Logs/<bundle id>` on Apple, `$XDG_STATE_HOME/six` on Linux |
| `SettingsPageView` → Develop ▸ Log | the path, Reveal in Finder, Open Console |

`Log` is in **SixCore**, listed in `Package.swift`, because the files with the most to say when something goes wrong —
`SnapshotStore`, `SettingsStore`, `ProfileStore`, `History`, `StatePersistence` — are all in that target. `os.Logger`
is behind `#if canImport(os)`; the file half is Foundation and Dispatch, which both fronts have.

A log is deliberately **not** under `AppSupport.root`. It is not application *support*: it is not backed up with the
browser's data, it is not migrated, and deleting it costs nothing — which is the distinction the two folders exist to
draw.
