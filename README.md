# DiskLens

A native macOS disk space analyzer. This repository currently holds milestone M0: the scan engine (`DiskLensCore`) and a command-line tool (`disklens`) used to check its speed and accuracy.

## Build and run

```bash
swift build -c release
.build/release/disklens ~ --top 10 --depth 2
```

`--kb` prints only the total in KiB so it can be compared with `du -skx`.

Folders protected by macOS privacy controls are reported as unreadable unless the terminal has Full Disk Access (System Settings → Privacy & Security → Full Disk Access).

## How the scan works

- `DirectoryReader` reads a whole directory per `getattrlistbulk(2)` call and takes each entry's allocated size, the same measure `du` uses.
- `Scanner` reads directories on one thread per CPU core and stays on the starting volume by default.
- Hard links are counted once, by inode. Symlinks are not followed.
- `FileTree` stores the result as flat parallel arrays and rolls sizes up in one pass. Children are sorted largest first.

## Tests

```bash
swift test
```
