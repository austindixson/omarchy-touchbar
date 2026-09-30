# PROOF-FM-TOUCHBAR-9252-1

Marketplace issue: [omacom/omarchy-plugin-marketplace#9252](https://github.com/omacom/omarchy-plugin-marketplace/issues/9252)
Blocked tip: `f059592f941bfd034def39eba9f58aed6171efef`
Plugin version: **1.1.2 -> 1.1.3** (`manifest.json`)

## Finding

`apply.sh` read and rewrote `~/.config/hypr/bindings.lua` with `os.path.isfile()`, an unbounded `open(...).read()`, then a truncating `open(..., "w")`. A symlink at that path redirected the write to another file; a FIFO or huge file could stall or exhaust the process.

## Fix (`apply.sh`)

- **Read:** `os.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)`, then `fstat` on the opened fd. Only a regular file of at most 262144 bytes (256 KiB) is accepted; the read loop is itself capped at limit + 1 bytes. Symlink, FIFO, directory, device, oversized, or non-UTF-8 content exits non-zero with a message and writes nothing. A missing file is skipped, as before.
- **Write:** exclusive temp file in the same directory (`O_CREAT | O_EXCL | O_NOFOLLOW`, random name, initially 0600), `fchmod` to the original file's mode, write, `fsync`, verify the destination is still the same regular file (`lstat` device and inode), then `os.replace`, then a best-effort directory `fsync`. The temp file is removed on any failure. `rename` replaces a symlink at the destination rather than writing through it.
- **Not regressed (#6878):** `Service.qml` still has no `FileView`; the shell layout checks (`validate_layout_file`, 64 KiB cap, symlink/FIFO refusal) and the fd-level layout re-check are unchanged. Test 7 below re-checks the layout FIFO refusal.

## Reproduce

Needs bash, python3, coreutils. Uses temp dirs only; no real config is touched.

```bash
git checkout <this PR branch>
bash tests/test-bindings-io.sh
```

## Result (this branch)

```text
PASS  normal bindings update (rc=0, mode 640 preserved, no temp leftovers)
PASS  idempotent re-apply (single managed block)
PASS  symlink refused (rc=1, victim unchanged, link intact): apply.sh: cannot open bindings safely: /tmp/tmp.XXXXXX/symlink/bindings.lua: Too many levels of symbolic links
PASS  FIFO refused (rc=1 in 0s, no hang): apply.sh: bindings must be a regular file: /tmp/tmp.XXXXXX/fifo/bindings.lua
PASS  oversized file refused (rc=1, unchanged): apply.sh: bindings too large (max 262144 bytes): /tmp/tmp.XXXXXX/big/bindings.lua
PASS  missing bindings file skipped (nothing created)
PASS  directory refused (rc=1)
PASS  #6878 layout FIFO still refused (rc=1)

RESULT: PASS
```

| Requirement | Result |
|---|---|
| Normal bindings update (block added, mode 640 kept, re-apply idempotent, no temp leftovers) | PASS |
| Symlink at bindings.lua path: refuse, destination unchanged, link intact | PASS |
| FIFO at that path: refuse under `timeout 5`, no hang (0 s) | PASS |
| Oversized file (300000 bytes > 262144): refuse, file unchanged | PASS |
| Directory at path refused; missing file skipped | PASS |
| #6878 layout FIFO still refused | PASS |

## Baseline (same test against `apply.sh` at f059592)

```text
PASS  normal bindings update (rc=0, mode 640 preserved, no temp leftovers)
PASS  idempotent re-apply (single managed block)
FAIL  symlink refused (rc=0) 
FAIL  FIFO refused (rc=0 elapsed=0s) 
FAIL  oversized file refused (rc=0) 
PASS  missing bindings file skipped (nothing created)
FAIL  directory refused (rc=0) 
PASS  #6878 layout FIFO still refused (rc=1)

RESULT: FAIL (4)
```

The old script followed the symlink and rewrote the target, accepted oversized and directory paths without refusing, and had no bound on the read.
