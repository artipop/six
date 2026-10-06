# 4. A comparison with Safari that does not move by itself

Make the baseline reproducible.

## The problem

`scripts/permissions-wpt.py` takes the newest stable Safari run from wpt.fyi every time, and Safari moves between
runs: eight `storage-access-api` files differ only because its run of 6 October timed out where the run of the 5th
had not. The committed baseline is pieces run against both
([permissions.md](../../permissions.md#compatibility-web-platform-tests)).

## What to build

- The baseline remembers the id of the Safari run it was compared with, and by default the comparison is with that
  run.
- A flag moves to the newest run and prints what moved **in Safari** separately from what moved in Savoia.
- Then one full run and a commit. It takes about an hour, uses the real camera and the system clipboard, and
  holds the display awake by itself. The files that call `getDisplayMedia` stay out unless `--screen`.

## Known

`/etc/hosts` already has wpt's block. The stand is described in
[test-suites.md](../../test-suites.md#the-shared-stand).

## Done when

Two runs a day apart print "nothing moved" unless Savoia changed, and the docs give one number against one named
Safari run.
