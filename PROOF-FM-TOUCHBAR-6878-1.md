# PROOF — FM-TOUCHBAR-6878-1

Marketplace issue: https://github.com/omacom/omarchy-plugin-marketplace/issues/6878  
Repo: https://github.com/austindixson/omarchy-touchbar  
Blocked commit: `92487b8190e37f0883900a7f04c11be2bf101e2c`  
Finding: HANCORE — `Service.qml` FileView + `apply.sh` uncapped/symlink/FIFO layout load  

Date: 2026-09-28 21:57 PDT (America/Los_Angeles)  
Machine: gHost64s-MacBook-Pro.local (`bdce4c5e-66bd-4033-86c7-b5826993476b`)  
Workdir: `/Users/ghost64/Desktop/PROJECTS/omarchy-touchbar`  
Branch: `fix/marketplace-safe-layout-load`

---

## 1. Claude CLI command + model + version

```text
Claude Code version: 2.1.284 (Claude Code)
Model id:            claude-opus-5-5
Permission mode:     bypassPermissions
```

Exact command (non-interactive):

```bash
cd /Users/ghost64/Desktop/PROJECTS/omarchy-touchbar
/Users/ghost64/.local/bin/claude -p \
  --model claude-opus-5-5 \
  --permission-mode bypassPermissions \
  --allowedTools "Bash,Read,Edit,Write,Glob,Grep" \
  --output-format text \
  "$(cat /tmp/claude-touchbar-6878-prompt.txt)"
```

`--permission-mode bypass` was not used; the CLI flag value is `bypassPermissions` (per `claude -p --help`). Bypass was accepted; `--dangerously-skip-permissions` was not needed.

Claude implemented product edits only (Service.qml, apply.sh, manifest.json, README.md). Coordinator wrote this proof file and ran the repro scripts.

---

## 2. Before / after behavior notes

### Before (main @ 92487b8)

**Service.qml** — `FileView` auto-loaded and watched `file://$HOME/.config/omarchy/touchbar.json` with `watchChanges: true`, no size cap, symlink-following:

```qml
FileView {
  id: overlay
  path: root.overlayUrl
  watchChanges: true
  onFileChanged: { overlay.reload(); root.applyLayout() }
  onLoaded: { if (overlay.text && overlay.text.length > 0) root.applyLayout() }
}
```

**apply.sh** — selected layout with `[[ -f $USER_LAYOUT ]]` then `json.loads(open(layout_path).read())` with no type/size/symlink checks.

| Case | Before behavior |
|---|---|
| FIFO at user path | `[[ -f FIFO ]]` is false → silent fallback to stock (exit 0). **Hang vector is FileView** in the shell, which opens/watches the path. Separately, `python3 open(FIFO)` hangs (repro below, exit 124 / 3s timeout) — the same `open()` risk if LAYOUT ever pointed at a FIFO. |
| Symlink → `/etc/passwd` | Followed; python tried to parse passwd as JSON (traceback, exit 1). |
| Oversized regular file (70 000 bytes) | Fully read into memory then JSON-parse failed (traceback, exit 1); no size cap. |
| Valid small JSON | Succeeded (JSON→toml path). |

Python FIFO hang proof (illustrates `open()` risk cited by HANCORE):

```text
PY_FIFO_EXIT=124
PY_NOTE: python open() on FIFO hung until 3s timeout — this is the apply.sh open() risk if LAYOUT were a FIFO
```

### After (this branch)

| Case | After behavior |
|---|---|
| FIFO at `OMARCHY_TOUCHBAR_LAYOUT` | Fail closed in <1s, exit 1, stderr: must be a regular file. No hang. |
| Oversized (>65536) | Fail closed, exit 1, stderr: too large (max 65536 bytes). |
| Symlink → `/etc/passwd` or large file | Refuse, exit 1, stderr: refusing symlink (marketplace #6878). |
| Valid small JSON regular file | exit 0 with `OMARCHY_TOUCHBAR_SKIP_INSTALL=1`. |
| Missing user layout | Validate + use stock layout; exit 0. |

Policy documented in code/README:

- Cap: **64 KiB (65536 bytes)**
- Symlinks: **refused outright** (no resolve-and-follow)
- Non-regular (FIFO/dir/device): **refused** without opening for read
- Bash checks use `[[ -L ]]` / `[[ -e ]]` / `[[ -f ]]` + `stat` only; Python re-checks via `O_NOFOLLOW | O_NONBLOCK` + `fstat` + capped `read`
- `Service.qml`: **FileView removed**; layout applied only when `apply.sh` runs
- Privilege allowlist (`system_bin` for install/systemctl/pkexec/sudo/bash) **unchanged**
- Version: **1.1.1 → 1.1.2** (`manifest.json`)

---

## 3. Deterministic repro scripts (must pass)

Environment: macOS (Darwin), bash, python3. Wall-clock timeout via `subprocess.run(..., timeout=3)` (no `timeout`/`gtimeout` on this host).

```bash
PROOF_DIR=$(mktemp -d /tmp/touchbar-proof-XXXXXX)
cd /Users/ghost64/Desktop/PROJECTS/omarchy-touchbar
export OMARCHY_TOUCHBAR_SKIP_INSTALL=1
export OMARCHY_TOUCHBAR_BINDINGS="$PROOF_DIR/bindings.lua"

run_to() { # usage: run_to SECS cmd...
  python3 - "$1" "${@:2}" <<'TO'
import subprocess, sys
secs=float(sys.argv[1]); cmd=sys.argv[2:]
try:
    raise SystemExit(subprocess.run(cmd, timeout=secs).returncode)
except subprocess.TimeoutExpired:
    print(f"TIMEOUT after {secs}s", file=sys.stderr); raise SystemExit(124)
TO
}
```

### 3a. FIFO — expect quick fail, NOT hang

```bash
mkfifo "$PROOF_DIR/fifo.json"
export OMARCHY_TOUCHBAR_LAYOUT="$PROOF_DIR/fifo.json"
run_to 3 ./apply.sh
# Observed:
# FIFO_EXIT=1
# stderr: apply.sh: user layout must be a regular file (not FIFO/dir/device): .../fifo.json
# file(1): fifo (named pipe)
```

### 3b. Oversized regular file — expect fail closed

```bash
python3 -c "open('$PROOF_DIR/oversize.json','w').write('x'*70000)"
export OMARCHY_TOUCHBAR_LAYOUT="$PROOF_DIR/oversize.json"
run_to 3 ./apply.sh
# Observed:
# OVER_EXIT=1
# stderr: apply.sh: user layout too large (max 65536 bytes): ... (70000 bytes)
# stat: Regular File 70000
```

### 3c. Symlink refuse

```bash
ln -sf /etc/passwd "$PROOF_DIR/link-passwd.json"
export OMARCHY_TOUCHBAR_LAYOUT="$PROOF_DIR/link-passwd.json"
run_to 3 ./apply.sh
# SYMLINK_EXIT=1
# stderr: apply.sh: refusing symlink user layout (marketplace #6878): ...

ln -sf "$PROOF_DIR/big.bin" "$PROOF_DIR/link-big.json"   # big.bin = 200000 bytes
export OMARCHY_TOUCHBAR_LAYOUT="$PROOF_DIR/link-big.json"
run_to 3 ./apply.sh
# SYMLINK2_EXIT=1
# stderr: apply.sh: refusing symlink user layout (marketplace #6878): ...
```

### 3d. Valid small JSON — apply succeeds (skip install)

```bash
cp ./layout.json "$PROOF_DIR/good.json"
export OMARCHY_TOUCHBAR_LAYOUT="$PROOF_DIR/good.json"
run_to 5 ./apply.sh
# GOOD_EXIT=0
# stat: Regular File 1415 ; file(1): JSON data
```

### Result table (2026-09-28 PDT)

| Test | Exit | Pass? |
|---|---:|---|
| FIFO | 1 (not 124) | PASS — quick fail |
| Oversized 70000 | 1 | PASS |
| Symlink → /etc/passwd | 1 | PASS |
| Symlink → large file | 1 | PASS |
| Valid small JSON | 0 | PASS |
| Missing user → stock | 0 | PASS |

Proof scratch dir used: `/tmp/touchbar-proof-ExbwGH`

---

## 4. Diff summary + commit SHA

Files changed by Claude (product):

```text
 README.md     | 12 +++++++++++-
 Service.qml   | 23 +++++-----------------
 apply.sh      | 62 ++++++++++++++++++++++++++++++++++++++++++++++++++++++-----
 manifest.json |  2 +-
 4 files changed, 74 insertions(+), 25 deletions(-)
```

Plus this proof file: `PROOF-FM-TOUCHBAR-6878-1.md`

Commit SHA: recorded in Firstmate FM-TOUCHBAR-6878-1 report and `git rev-parse` of the pushed branch tip (self-referential SHA omitted from blob to avoid amend loops).

---

## 5. Key snippets of the fixed checks

### Service.qml — FileView removed

```qml
  // No FileView on ~/.config/omarchy/touchbar.json (marketplace #6878).
  // FileView follows symlinks and has no size cap, so a FIFO or huge file at
  // that predictable path could stall or exhaust the shell. The layout is
  // applied only when apply.sh runs; apply.sh validates the file first.
```

### apply.sh — validate_layout_file

```bash
MAX_LAYOUT_BYTES=65536

validate_layout_file() {
  local path=$1
  local label=${2:-layout}
  local size
  if [[ -L $path ]]; then
    echo "apply.sh: refusing symlink $label (marketplace #6878): $path" >&2
    return 1
  fi
  if [[ ! -e $path ]]; then
    echo "apply.sh: $label not found: $path" >&2
    return 1
  fi
  if [[ ! -f $path ]]; then
    echo "apply.sh: $label must be a regular file (not FIFO/dir/device): $path" >&2
    return 1
  fi
  size=$(stat -c '%s' -- "$path" 2>/dev/null || stat -f '%z' -- "$path" 2>/dev/null) || size=
  if [[ ! $size =~ ^[0-9]+$ ]]; then
    echo "apply.sh: cannot stat $label: $path" >&2
    return 1
  fi
  if (( size > MAX_LAYOUT_BYTES )); then
    echo "apply.sh: $label too large (max $MAX_LAYOUT_BYTES bytes): $path ($size bytes)" >&2
    return 1
  fi
}
```

### apply.sh — Python defense in depth

```python
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
# fstat → must be S_ISREG; read at most max_bytes+1; reject if over cap
```

Privilege helpers (`system_bin`, `run_as_root`, `OMARCHY_TOUCHBAR_SKIP_INSTALL`) left intact.

---

## 6. Git / marketplace

- Branch pushed: `fix/marketplace-safe-layout-load`
- Prefer PR → merge to `main` (prior pattern: PR #1 for 1.1.1 harden)
- Do **not** comment on marketplace #6878 from this task — Firstmate retargets after proof
