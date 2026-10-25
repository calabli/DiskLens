# DiskLens

A native macOS disk space analyzer: a folder list and a squarified treemap kept in sync, drill-down navigation, and a collection basket that moves items to the Trash in one confirmed step.

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
- `DiskScanner` reads directories breadth-first on one thread per CPU core and stays on the starting volume by default. `snapshot()` returns the tree scanned so far, which the app uses to draw the treemap while the scan runs; node ids in a snapshot stay valid in later snapshots and the final tree.
- Hard links are counted once, by inode. Symlinks are not followed.
- Names live in a `NamePool` of packed UTF-8 bytes, and the per-entry data in `ChunkedArray`s: fixed-size chunks that never move, so a snapshot shares them instead of copying.
- `FileTree` stores the result as flat parallel arrays and rolls sizes up in one pass. Children are sorted largest first. `remove(_:)` takes trashed items out and keeps that order.
- `TreemapLayout` lays out nested folders as squarified blocks, skipping blocks smaller than 3 pt and stopping at 60,000 blocks.

## Tests

```bash
swift test
```
