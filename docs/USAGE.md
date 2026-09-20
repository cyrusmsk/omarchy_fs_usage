# Using omarchy_fs_usage

Rows, popups and buttons answer to both keyboard and mouse: click a
folder to open it, a file to select it (the details panel follows), or
drive everything from the keyboard, in the spirit of ncdu/btdu.

## Keyboard

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
| `1` `2` `3` / `t` | browse · insights · compare tabs / cycle tabs |
| `c` | compare tab: sort by change vs current size |

## First scan

* Pick a btrfs filesystem (`m` lists the mounted ones) and a sampling
  depth (20k = quick look, 200k ≈ 1% resolution, …), then scan (`r` or
  `Space` on the call-to-action). First results land after a second or
  so and sharpen the longer btdu is allowed to run.
* Special rows carry one-line explanations of what btrfs uses that
  space for (`<UNUSED>` is the "dark matter" reclaimable by balance or
  defragmentation).
* The details panel (`i`) shows the selected row's exclusive ("own") vs
  shared split and where else those extents are stored (CoW clones and
  snapshots) — needs expert mode + shared-path attribution, below.

## Scan options — the btrfs-specific knobs (`o`)

Beyond the sample budget, the options popup exposes btdu's advanced
flags (applied with `logic.setScanOptions`, take effect on the next
scan):

* **physical space (`-p`)** — on-disk bytes after compression and CoW
  instead of logical size. This is the number that matters when the
  disk is nearly full.
* **expert metrics (`-x`)** — per-row exclusive vs shared extents: how
  much of a subvolume is really its own, and how much is shared with
  snapshots or reflink clones. On by default.
* **shared-path attribution (`--export-seen-as`)** — records which
  other paths reference each shared extent; the details panel lists
  them ("also stored under …"). On by default.
* **seed (`--seed`)** — fixed random seed, for reproducible scans.
* **stop conditions (`--min-resolution`, `--max-time`)** — e.g. `1%`,
  `10MiB`, `30s`.
* **sampling focus (`--prefer`, `--ignore`)** — comma-separated path
  patterns to spend samples on (or skip), e.g. `@home`. Setting these
  drops `--auto-mount` (btdu rejects the combination).

The stats card badges the active modes (`physical`, `expert`); each
export also records the filesystem UUID.

## Insights tab (`2`)

The btdu concepts that classic analyzers get wrong, read off the
current scan:

* **Sampling accuracy** — samples collected, current resolution,
  budget, seed and stop conditions. Results land instantly and sharpen
  the longer btdu runs (≈100 samples give ≈1% resolution).
* **Snapshot sizes** — snapshot-like rows (snapshot dirs, date-named
  rows, deleted subvolumes still holding extents) with their exclusive
  ("new") sizes. With fixed-length lexicographically-ordered snapshot
  names each row reads as the data that snapshot introduced. Needs
  expert mode (`-x`) for the exclusive split.
* **Unreachable "dark matter"** — space no longer covered by live file
  extents (overwritten content inside old extents); rewrite or
  defragment the files to reclaim it.
* **Compression** — logical scans cannot see compression or CoW
  sharing; the panel says which mode the scan used and the metadata
  overhead, and points at the physical option (`o`) for real disk cost.

## Compare tab (`3`)

Track disk usage changes over time, the way `btdu --compare` does,
computed client-side against a saved baseline:

1. `save current scan…` stores the finished scan's export anywhere.
2. Keep using the disk, then rescan (or import a newer export).
3. `open baseline…` loads the old export: the tab lists what grew
   (`▲`) or shrank (`▼`), including new and deleted paths, and every
   browse row gains a `±delta` annotation.

For accurate deltas use the same sampling parameters (seed, budget)
for both runs — deterministic sampling compares apples to apples.

## Offline browsing

Start with a previously exported scan instead of sampling live —
`omarchy_fs_usage --import results.json` (or `BTDU_IMPORT=results.json`).
This needs no root privileges.
