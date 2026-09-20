# Development notes

## Repository layout

```
source/main.d        app entry, autotest drivers (KeyBot/ClickBot/CompareBot)
source/logic.d       QObject controller exposed to QML (scans, views, tabs)
source/btdu.d        btdu discovery, headless ScanJob, JSON export parsing
source/theme.d       Omarchy theme reader (colors.toml -> JSON)
source/main.qml      the UI (browse / insights / compare tabs)
source/minimal.qml   minimal QML for isolation runs
testdata/            fake btdu + canned exports (root-free testing)
```

## Building against dqt

The app builds against upstream dqt (`tim-dlang/dqt` master) via a git
dependency in `dub.json` — no `path` override — and synthesizes its
test input with the upstream QTest bindings (`dqt:test`: `mousePress` /
`mouseRelease` / `mouseMove`, `keyClick`), i.e. the same
`QWindowSystemInterface` pipeline as real devices.

One packaging caveat: dqt emits some C++-mangled method bodies as
global symbols — notably every `Q*Event::clone()` from
`Q_DECL_EVENT_COMMON` — and the dynamic linker otherwise resolves Qt's
own cross-DSO calls to them (executable interposition). In particular
Qt's `QQuickDeliveryAgent::clonePointerEvent` (libQt6Quick) ends up
"cloning" pointer events with D code, which corrupts the heap on the
first press into a Flickable (proven with gdb: a breakpoint on our
binary's `QMouseEvent::clone()` fires from inside `clonePointerEvent`).
Hence `dub.json` links with `-Wl,--exclude-libs,ALL`, localizing the
static-archive symbols so Qt binds its own implementations; internal
references still bind locally. Without the flag the click probe below
aborts in `QQuickFlickable::filterPointerEvent`; with it, clicks
navigate.

D-side lifetime follows upstream's documented model (dqt README,
"Memory management"): every D `QObject` Qt can call back into (`Logic`,
the test drivers, the `objectCreated` delegate) is kept in a GC-visible
local for the whole `app.exec()` run, so the collector never frees what
C++ still references.

## Pointer handling in the QML

List rows use `TapHandler`/`HoverHandler` (Qt's pointer handlers)
rather than `MouseArea`, and row navigation is deferred with
`Qt.callLater`: never destroy ListView delegates while Qt Quick is
still delivering a pointer event, or the Flickable press-filtering
machinery walks stale pointers (the crash class of QTBUG-91272 —
clicking rows to expand a folder used to take the app down with it).

## Automated tests

The keyboard interface is the supported path and is fully drivable
without root, using the fake btdu in `testdata/` (a shell stand-in that
replays canned JSON exports — `basic.json`, `expert.json`,
`expert-seenas.json` — chosen by the flags the app passes, so the
advanced-options plumbing is exercised too):

```sh
FSU_FAKE_BTDU=$PWD/testdata/fake-btdu.sh FSU_AUTOTEST=1 ./omarchy_fs_usage
```

starts a scan through the whole worker/polling/parse/render pipeline,
then moves the selection, drills in/out with `Return`/`Space`/`Left`/
`Backspace`, queries the details of a snapshot-shared row and reports
`KEYTEST-OK`. Useful variants:

* `BTDU_IMPORT=testdata/expert-seenas.json FSU_AUTOTEST=1 …` — the same
  keyboard walk over an offline import (no scan, no root).
* `BTDU_IMPORT=testdata/basic.json FSU_AT_COMPARE=1 …` — the
  advanced-tabs probe: loads `testdata/baseline.json` as the compare
  baseline and checks the grown/shrunk/new/deleted deltas, the snapshot
  estimator, the dark-matter figure and the row delta annotations, then
  flips through the tabs with `2`/`3`/`1` and reports `CMPTEST-OK`.
  (`FSU_AT_BASELINE=…` overrides the baseline path.)
* `FSU_AT_CLICKS=1 FSU_AT_YS=0,1,2 …` — the click probe: synthesizes
  real-pipeline mouse presses on the rows (via `dqt:test`) and reports
  `AUTOTEST-OK` when it survived. `FSU_AT_CLICKS=1` enables the probe;
  the click count comes from the `FSU_AT_YS` row-index list (or
  `FSU_AT_FIXED=y1,y2,…` for raw coordinates).
* `FSU_MINIMAL=1` — load a minimal QML instead of the full UI.
* `FSU_RAW=1` — de-glued pump: no Qt timers, no signal connections,
  just manual `processEvents` and injected clicks.
* Run under `MALLOC_CHECK_=3 MALLOC_PERTURB_=165` to have glibc abort
  on the first heap misuse instead of crashing later.
