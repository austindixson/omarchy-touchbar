#!/bin/bash
# Reproduces the marketplace #9252 bindings.lua I/O checks against apply.sh.
# Needs only bash, python3, coreutils (timeout, mkfifo). Touches no real config.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MARK_B="-- io.github.austindixson.touchbar begin"
MARK_E="-- io.github.austindixson.touchbar end"
ORIGINAL=$'-- user bindings\no.bind("SUPER + X", "Custom", "true")\n'

LAYOUT="$WORK/layout.json"
cat >"$LAYOUT" <<'JSON'
{"buttons":[{"text":"Term","key":"F13","hyprKey":"SUPER + T","command":"omarchy-launch-terminal"}]}
JSON

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

run_apply() {
  # $1 = bindings path. Prints combined output; returns apply.sh exit status
  # (124 means the 5 s timeout fired, i.e. a hang).
  OMARCHY_TOUCHBAR_LAYOUT="$LAYOUT" OMARCHY_TOUCHBAR_BINDINGS="$1" \
    OMARCHY_TOUCHBAR_SKIP_INSTALL=1 timeout 5 bash "$ROOT/apply.sh" 2>&1
}

# 1. Normal update: block appended, mode preserved, no temp files left behind.
dir="$WORK/normal"; mkdir "$dir"
printf '%s' "$ORIGINAL" >"$dir/bindings.lua"; chmod 640 "$dir/bindings.lua"
out=$(run_apply "$dir/bindings.lua"); rc=$?
mode=$(stat -c '%a' "$dir/bindings.lua")
if [[ $rc -eq 0 && $mode == 640 ]] &&
   grep -Fq -- "$MARK_B" "$dir/bindings.lua" && grep -Fq 'SUPER + T' "$dir/bindings.lua" &&
   grep -Fq 'SUPER + X' "$dir/bindings.lua" &&
   [[ $(ls -A "$dir" | wc -l) -eq 1 ]]; then
  pass "normal bindings update (rc=0, mode 640 preserved, no temp leftovers)"
else
  fail "normal bindings update (rc=$rc mode=$mode) $out"
fi

# 1b. Second run replaces the managed block instead of duplicating it.
run_apply "$dir/bindings.lua" >/dev/null
if [[ $(grep -Fc -- "$MARK_B" "$dir/bindings.lua") -eq 1 && $(grep -Fc -- "$MARK_E" "$dir/bindings.lua") -eq 1 ]]; then
  pass "idempotent re-apply (single managed block)"
else
  fail "idempotent re-apply"
fi

# 2. Symlink at the bindings path: refuse, target and link unchanged.
dir="$WORK/symlink"; mkdir "$dir"
printf 'victim-content\n' >"$dir/victim"
ln -s "$dir/victim" "$dir/bindings.lua"
out=$(run_apply "$dir/bindings.lua"); rc=$?
if [[ $rc -ne 0 && $rc -ne 124 && -L "$dir/bindings.lua" &&
      $(cat "$dir/victim") == "victim-content" && $(ls -A "$dir" | wc -l) -eq 2 ]]; then
  pass "symlink refused (rc=$rc, victim unchanged, link intact): ${out##*$'\n'}"
else
  fail "symlink refused (rc=$rc) $out"
fi

# 3. FIFO at the bindings path: refuse under timeout, no hang.
dir="$WORK/fifo"; mkdir "$dir"
mkfifo "$dir/bindings.lua"
start=$SECONDS
out=$(run_apply "$dir/bindings.lua"); rc=$?
elapsed=$((SECONDS - start))
if [[ $rc -ne 0 && $rc -ne 124 && -p "$dir/bindings.lua" ]] && (( elapsed < 5 )); then
  pass "FIFO refused (rc=$rc in ${elapsed}s, no hang): ${out##*$'\n'}"
else
  fail "FIFO refused (rc=$rc elapsed=${elapsed}s) $out"
fi

# 4. Oversized file: refuse, file unchanged.
dir="$WORK/big"; mkdir "$dir"
head -c 300000 /dev/zero | tr '\0' 'a' >"$dir/bindings.lua"
before=$(sha256sum <"$dir/bindings.lua")
out=$(run_apply "$dir/bindings.lua"); rc=$?
after=$(sha256sum <"$dir/bindings.lua")
if [[ $rc -ne 0 && $rc -ne 124 && $before == "$after" && $out == *"too large"* ]]; then
  pass "oversized file refused (rc=$rc, unchanged): ${out##*$'\n'}"
else
  fail "oversized file refused (rc=$rc) $out"
fi

# 5. Missing bindings file: skipped, nothing created (existing behaviour).
dir="$WORK/missing"; mkdir "$dir"
out=$(run_apply "$dir/bindings.lua"); rc=$?
if [[ $rc -eq 0 && $(ls -A "$dir" | wc -l) -eq 0 ]]; then
  pass "missing bindings file skipped (nothing created)"
else
  fail "missing bindings file (rc=$rc) $out"
fi

# 6. Directory at the bindings path: refuse.
dir="$WORK/isdir"; mkdir -p "$dir/bindings.lua"
out=$(run_apply "$dir/bindings.lua"); rc=$?
if [[ $rc -ne 0 && $rc -ne 124 ]]; then
  pass "directory refused (rc=$rc)"
else
  fail "directory refused (rc=$rc) $out"
fi

# 7. #6878 layout guard still active: FIFO layout refused without hanging.
mkfifo "$WORK/layout.fifo"
dir="$WORK/layoutfifo"; mkdir "$dir"
out=$(OMARCHY_TOUCHBAR_LAYOUT="$WORK/layout.fifo" OMARCHY_TOUCHBAR_BINDINGS="$dir/bindings.lua" \
  OMARCHY_TOUCHBAR_SKIP_INSTALL=1 timeout 5 bash "$ROOT/apply.sh" 2>&1); rc=$?
if [[ $rc -ne 0 && $rc -ne 124 ]]; then
  pass "#6878 layout FIFO still refused (rc=$rc)"
else
  fail "#6878 layout FIFO (rc=$rc) $out"
fi

echo
if (( failures )); then echo "RESULT: FAIL ($failures)"; exit 1; fi
echo "RESULT: PASS"
