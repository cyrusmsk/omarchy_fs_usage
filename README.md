# omarchy_fs_usage — Disk Usage · btdu

An Omarchy-flavored graphical front-end for [btdu], the sampling disk
usage profiler for btrfs, built with the D Qt (QML) bindings.

It drives the real `btdu` CLI tool headlessly (`btdu --headless
--auto-mount --export=…`) and browses the result in an ncdu-style UI.
The top level shows what the official tree of largest items shows —
subvolumes (`@`, `@home`, …), the `<UNUSED>` "dark matter", orphaned
subvolumes — plus the opaque buckets (`<METADATA>`, `<SYSTEM>`), all
merged across block group profiles (attribution shown in the row
description). Below that it's the plain file tree, with per-row
share-of-space bars.

![screenshot](screenshot.png)

## Omarchy integration

* **Theme** — colors are read at startup from the active Omarchy theme
  (`~/.local/state/omarchy/current/theme.name` → `colors.toml`, with the
  `~/.config/omarchy/themes/<slug>/` overlay winning key by key), so the
  app follows `omarchy theme set …` like the rest of the desktop.
* **Privileges** — btdu needs root to read raw btrfs metadata; the app
  elevates via `pkexec` (polkit), which asks for your password in the
  standard Omarchy auth dialog.
* **Typography** — the Omarchy monospace font, rounded cards and the
  theme's accent colors, in the spirit of the Omarchy shell widgets.

## Building

```
dub build
./omarchy_fs_usage
```

The `btdu` binary is located at runtime, in this order:

1. `$FSU_FAKE_BTDU` (test double, see below)
2. `$BTDU_PATH`
3. `$PATH` (e.g. `sudo pacman -S btdu` if packaged)
4. a build in the dub package cache
   (`cd ~/.dub/packages/btdu/<ver>/btdu && dub build -b release`)

## Using — keyboard and mouse

Rows, popups and buttons answer to both: click a folder to open it, a
file to select it (details panel follows), or drive everything from
the keyboard, in the spirit of ncdu/btdu:

| keys | action |
|---|---|
| `Tab` / `Shift+Tab` | move between controls (target, scan, depth, options, list, …) |
| `↑` `↓` · `PgUp` `PgDn` · `Home` `End` | move the selection |
| `→` · `Enter` · `Space` | open the selected folder |
| `←` · `Backspace` | go up one level |
| `g` / `G` | first / last row |
| `/` | filter the current level by name |
| `n` | toggle size/name sort |
| `m` · `s` · `o` | filesystem picker · sample depth · scan options |
| `i` | toggle the own/shared details panel |
| `r` | rescan (applies the scan options) |
| `Esc` | close popup · leave the filter |
| `?` / `F1` | this help, in-app |

* Pick a btrfs filesystem (`m` lists the mounted ones) and a sampling
  depth (20k = quick look, 200k ≈ 1 % resolution, …), then scan (`r` or
  `Space` on the call-to-action). First results land after a second or so.
* Special rows carry one-line explanations of what btrfs uses that
  space for (`<UNUSED>` is the "dark matter" reclaimable by balance or
  defragmentation).
* The details panel (`i`) shows the selected row's exclusive ("own") vs
  shared split and where else those extents are stored (CoW clones and
  snapshots) — needs expert mode + shared-path attribution, see below.
* **Offline browsing**: start with a previously exported scan instead of
  sampling live — `omarchy_fs_usage --import results.json` (or
  `BTDU_IMPORT=results.json`). This needs no root privileges.

## Scan options — the btrfs-specific knobs (`o`)

Beyond the sample budget, the options popup exposes btdu's advanced
flags (applied with `logic.setScanOptions`, take effect on the next scan):

* **physical space (`-p`)** — on-disk bytes after compression and CoW
  instead of logical size. This is the number that matters when the disk
  is nearly full.
* **expert metrics (`-x`)** — per-row exclusive vs shared extents:
  how much of a subvolume is really its own, and how much is shared
  with snapshots or reflink clones. On by default.
* **shared-path attribution (`--export-seen-as`)** — records which other
  paths reference each shared extent; the details panel lists them
  ("also stored under …"). On by default.
* **seed (`--seed`)** — fixed random seed, for reproducible scans.
* **stop conditions (`--min-resolution`, `--max-time`)** — e.g. `1%`,
  `10MiB`, `30s`.
* **sampling focus (`--prefer`, `--ignore`)** — comma-separated path
  patterns to spend samples on (or skip), e.g. `@home`. Setting these
  drops `--auto-mount` (btdu rejects the combination).

The stats card badges the active modes (`physical`, `expert`); each
export also records the filesystem UUID.

## Notes on pointer handling

List rows use `TapHandler`/`HoverHandler` (Qt's pointer handlers) rather
than `MouseArea`, and row navigation is deferred with `Qt.callLater`:
never destroy ListView delegates while Qt Quick is still delivering a
pointer event, or the Flickable press-filtering machinery walks stale
pointers (the crash class of QTBUG-91272 — clicking rows to expand a
folder used to take the app down with it).

The app builds against upstream dqt (`tim-dlang/dqt` master, via a git
dependency in `dub.json` — no `path` override) and synthesizes its test
input with the upstream QTest bindings (`dqt:test`: `mousePress` /
`mouseRelease` / `mouseMove`, `keyClick`), i.e. the same
`QWindowSystemInterface` pipeline as real devices.

D-side lifetime is handled the way upstream documents it (README
"Memory management"): every D `QObject` Qt can call back into
(`Logic`, the `KeyBot`/`ClickBot` drivers, the `objectCreated`
delegate) is kept in a GC-visible local for the whole `app.exec()`
run, so the collector never frees what C++ still references.

One packaging caveat, also on the D side: dqt emits some C++-mangled
method bodies as global symbols — notably every `Q*Event::clone()`
from `Q_DECL_EVENT_COMMON` — and the dynamic linker otherwise resolves
Qt's own cross-DSO calls to them (executable interposition). In
particular Qt's `QQuickDeliveryAgent::clonePointerEvent` (libQt6Quick)
ends up "cloning" pointer events with D code, which corrupts the heap
on the first press into a Flickable (proven with gdb: the breakpoint
on our binary's `QMouseEvent::clone()` fires from inside
`clonePointerEvent`). Hence `dub.json` links with
`-Wl,--exclude-libs,ALL`, localizing the static-archive symbols so Qt
binds its own implementations; our internal references still bind
locally. Verified: without the flag the click probe below aborts in
`QQuickFlickable::filterPointerEvent`; with it, clicks navigate.

## Automated tests

The keyboard interface is the supported path and is fully drivable
without root, using the fake btdu in `testdata/` (a shell stand-in
that replays canned JSON exports — `basic.json`, `expert.json`,
`expert-seenas.json` — chosen by the flags the app passes, so the
advanced-options plumbing is exercised too):

```
FSU_FAKE_BTDU=$PWD/testdata/fake-btdu.sh FSU_AUTOTEST=1 ./omarchy_fs_usage
```

starts a scan through the whole worker/polling/parse/render pipeline,
then moves the selection, drills in/out with `Return`/`Space`/`Left`/
`Backspace`, queries the details of a snapshot-shared row and reports
`KEYTEST-OK`. Useful variants:

* `BTDU_IMPORT=testdata/expert-seenas.json FSU_AUTOTEST=1 …` — the same
  keyboard walk over an offline import (no scan, no root).
* `FSU_AT_CLICKS=1 FSU_AT_YS=0,1,2 …` — the click probe:
  synthesizes real-pipeline mouse presses on the rows (via the upstream
  QTest bindings in `dqt:test`) and reports `AUTOTEST-OK` when it
  survived. Clicks now navigate like the keyboard does.
* `FSU_MINIMAL=1` — load a minimal QML instead of the full UI.
* Run under `MALLOC_CHECK_=3 MALLOC_PERTURB_=165` to have glibc abort on
  the first heap misuse instead of crashing later.

[btdu]: https://github.com/CyberShadow/btdu
