# DiskLens

A native macOS disk space analyzer: a folder list and a squarified treemap kept in sync, drill-down navigation, cleanup suggestions, and a collection basket that moves items to the Trash in one confirmed step.

The package has three products: the scan engine (`DiskLensCore`), the SwiftUI app (`DiskLensApp`) and a command-line tool (`disklens`).

## Run the app

```bash
./scripts/build-app.sh
open build/DiskLens.app
```

`open build/DiskLens.app --args --scan ~/Downloads` starts scanning a folder right away.

The bundle is ad-hoc signed. macOS ties Full Disk Access to that signature, so after a rebuild the permission may need to be granted again.

## Command-line tool

```bash
swift build -c release
.build/release/disklens ~ --top 10 --depth 2
```

`--kb` prints only the total in KiB so it can be compared with `du -skx`.

Folders protected by macOS privacy controls are reported as unreadable unless the terminal has Full Disk Access (System Settings → Privacy & Security → Full Disk Access).

## How the scan works

- `DirectoryReader` reads a whole directory per `getattrlistbulk(2)` call and takes each entry's allocated size, the same measure `du` uses.
- `DiskScanner` reads the top three levels breadth-first and the rest depth-first, on 4× as many threads as CPU cores (at most 32), and stays on the starting volume by default. A large scan is limited by small random metadata reads from the SSD, so it gains from many reads in flight. Each subfolder is opened with `openat` relative to its open parent; opening by full path made every thread lock the same top folders. `snapshot()` returns the tree scanned so far, which the app uses to draw the treemap while the scan runs; node ids in a snapshot stay valid in later snapshots and the final tree.
- Hard links are counted once, by inode. Symlinks are not followed.
- Names live in a `NamePool` of packed UTF-8 bytes, and the per-entry data in `ChunkedArray`s: fixed-size chunks that never move, so a snapshot shares them instead of copying.
- `FileTree` stores the result as flat parallel arrays and rolls sizes up in one pass. Children are sorted largest first. `remove(_:)` takes trashed items out and keeps that order.
- `TreemapLayout` lays out nested folders as squarified blocks, skipping blocks smaller than 3 pt and stopping at 60,000 blocks.

## Saved scans and changes

Every finished scan is saved to `~/Library/Caches/app.disklens.DiskLens/Scans` (LZ4-compressed, about 20 MB for 1.6M entries), along with the FSEvents event id taken just before it started. Scanning the same folder again shows the saved result at once and brings it up to date:

- `ChangeJournal` asks FSEvents which folders changed since that event id. macOS keeps this journal even while DiskLens is not running.
- `TreeUpdater` re-reads only those folders: unchanged folders are copied over, and new folders are scanned. The result matches a fresh scan. On a home folder this takes about 1 s instead of about 8 s.
- If the journal cannot tell (history dropped, another volume, the root replaced), DiskLens falls back to a full scan. ⇧⌘R always does a full scan.

`ScanComparison` then lists what grew or shrank by at least 50 MB, naming the most specific folder or file behind each change. A folder that appeared or vanished as a whole is listed as that folder. Each scan's total is appended to `history.json` for the coming space timeline.

`disklens <path> --use-cache` does the same in Terminal and prints the timings.

## Background recording and the space timeline

`DiskLensAgent` runs as a login item (registered with `SMAppService` when the user turns on 后台记录) at background CPU and I/O priority, using about 1% CPU and 11 MB of memory. Every minute it adds to `~/Library/Application Support/app.disklens.DiskLens/activity.sqlite`:

- **Writes per app:** sampled every 10 s from each process's disk-write counter (`proc_pid_rusage`). Helper processes count toward the outermost `.app` they live in. Only the user's own processes are visible, and processes that start and exit between samples are missed.
- **Growth per folder:** a live FSEvents stream (30 s latency) reports changed folders. The agent re-reads each one a single level deep and records the change in size of the files directly inside. Folders are attributed to an owner by path (`FolderOwner`).
- **Used space** of the home folder's volume.

Records are kept for 90 days. The 空间时间线 page charts the daily or hourly change in used space, and for the whole range or a clicked bar it lists the sources of growth (expandable to folders) and the apps that wrote the most.

## Cleanup suggestions

`CleanupAdvisor` turns a scanned tree into suggestions in three tiers: safe to clean (caches and anything rebuilt automatically), review (probably unneeded, check each item), and info only (clean with a command, or not at all). It only ever suggests items inside the home folder, and it reads the tree in memory, so it takes well under a second.

- **Rules:** `Sources/DiskLensCore/Resources/cleanup-rules.json` lists known reclaimable locations, each with a safety tier, what it is, what deleting it means, the apps that own it, and an optional command to use instead of deleting files. Path components may use shell patterns (`*`, `*.dmg`).
- **Inactive projects:** dependency and build folders (`node_modules`, `target`, `Pods`, `.venv`, `.build`…) next to a project manifest, in projects untouched for 90 days. Hidden folders, `~/Library`, app bundles and Go's module cache are never treated as projects.
- **Leftover app data:** folders in `~/Library` named after a bundle identifier whose app is no longer installed, judged by the app folders, LaunchServices and the vendor's other apps.

`disklens ~ --suggest` prints the same suggestions in Terminal.

## Large files

`LargeFileFinder` lists the largest files in a scan. App bundles, photo libraries and disk-image bundles count as one item each; their contents are never listed, because deleting a file inside one breaks it. The app filters the list by size, type, name and time since last use, which comes from Spotlight's `kMDItemLastUsedDate` and falls back to the modification time.

## Tests

```bash
swift test
```
