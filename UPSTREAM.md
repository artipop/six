# Upstream: two Linux regressions that keep SQLiteData from building

Found while bringing six's storage layer up on Linux ([docs/storage.md](docs/storage.md)). Neither is
six's bug and neither is in a package six imports — both arrive through `SQLiteData`, which depends on
`Sharing` unconditionally. Both are **regressions**: the immediately preceding release of each builds
clean on the same toolchain.

six works around them by seeding its `Package.resolved` from the app's own, which holds the graph at
the last good versions. That is a workaround, not a fix, and it makes `swift package update` a
Linux-breaking command in this repo — hence these two reports.

Environment for everything below:

```
Swift version 6.3.3 (swift-6.3.3-RELEASE)   Target: aarch64-unknown-linux-gnu
Ubuntu 24.04.4 LTS, aarch64
docker.io/library/swift:6.3.3-noble
```

---

## 1. pointfreeco/swift-sharing — 2.10.0 does not build on Linux

**Title:** `2.10.0 fails to build on Linux: no such module 'Foundation.NSData'`

### Summary

`swift-sharing` 2.10.0 does not compile on Linux. `Sources/Sharing/Internal/Deprecations.swift`
imports the `Foundation.NSData` *submodule*, which exists only where Foundation is a Clang module —
on Linux, Foundation is a Swift module and has no submodules, so the import fails outright.

2.9.1, 2.8.2 and 2.5.2 all build clean on the same toolchain, so this is a regression rather than a
platform limitation.

The repository's CI declares a Linux job on Swift 6.3
(`.github/workflows/ci.yml`, `linux: container: swift:${{ matrix.swift }}`, matrix `swift: ['6.3']`),
which suggests the job is not catching this.

### Steps to reproduce

```sh
docker run --rm swift:6.3.3-noble bash -c '
  git clone -q --depth 1 --branch 2.10.0 https://github.com/pointfreeco/swift-sharing /tmp/s
  cd /tmp/s && swift build'
```

### Actual

```
/tmp/s/Sources/Sharing/Internal/Deprecations.swift:2:18: error: no such module 'Foundation.NSData'
error: emit-module command failed with exit code 1
```

The source, unchanged on `main` at the time of writing:

```swift
// Sources/Sharing/Internal/Deprecations.swift
#if canImport(Foundation)
  package import Foundation.NSData
#endif
```

`canImport(Foundation)` is true on Linux, so the guard does not protect the submodule import — the
condition tests the wrong thing.

### Expected

Builds, as 2.9.1 does. Swapping the branch in the command above to `2.9.1`, `2.8.2` or `2.5.2` gives
`Build complete` with zero errors.

### Suggested fix

`import Foundation` rather than the submodule, or guard the submodule import on a Clang-module
Foundation (`#if canImport(Darwin)`) instead of on `canImport(Foundation)`.

---

## 2. pointfreeco/combine-schedulers — 1.2.1 does not build on Linux

**Title:** `1.2.1 fails to build on Linux under Swift 6.3: missing import of CoreFoundation`

### Summary

`Sources/CombineSchedulers/Internal/Lock.swift` uses `pthread_mutex_t` and `pthread_mutexattr_t` in
the non-Darwin branch under a bare `import Foundation`. Swift 6.3's `MemberImportVisibility` rejects
that: the types come from `CoreFoundation`, which the file never imports.

1.2.0 builds clean on the same toolchain, so this is a regression.

Two things make it awkward downstream: the diagnostic is an *error* rather than a warning because the
package selects its own Swift language mode, so neither `-Xswiftc -Wwarning -Xswiftc
MemberImportVisibility` nor `-Xswiftc -swift-version -Xswiftc 5` on the consumer's command line
reaches it.

### Steps to reproduce

```sh
docker run --rm swift:6.3.3-noble bash -c '
  git clone -q --depth 1 --branch 1.2.1 https://github.com/pointfreeco/combine-schedulers /tmp/c
  cd /tmp/c && swift build'
```

### Actual

Six errors, the first being:

```
/tmp/c/Sources/CombineSchedulers/Internal/Lock.swift:53:19: error: initializer 'init()' is not
available due to missing import of defining module 'CoreFoundation' [#MemberImportVisibility]

51 |     init() {
52 |       var attr = pthread_mutexattr_t()
53 |       var mutex = pthread_mutex_t()
   |                   `- error: ...
```

### Expected

Builds, as 1.2.0 does.

### Suggested fix

One line, in the `#else` branch that already exists:

```diff
 #else
+  import CoreFoundation
   import Foundation
```

Confirmed: applying exactly this to the checkout clears all six errors, and the build then proceeds
past the package.

---

## What this costs downstream

`SQLiteData` depends on `Sharing` unconditionally (target dependency, not trait-gated), so any package
that uses SQLiteData on Linux resolves into both of these. six uses none of the layer that pulls
`Sharing` in — no `@FetchAll`, no `@Fetch`, no `@Shared`, only `@Table`, `#sql` and `defaultDatabase` —
and still cannot build without pinning around them.

Unrelated but worth knowing for anyone else arriving here:
[sqlite-data#459](https://github.com/pointfreeco/sqlite-data/pull/459) is an open Linux-support PR for
SQLiteData itself, covering CloudKit gating in its tests and its GRDB floor. It does not touch either
of the packages above, so merging it would not by itself make SQLiteData build on Linux.
