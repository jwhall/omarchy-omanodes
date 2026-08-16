#!/bin/bash
# Input validation: join/leave must reject anything that is not exactly 16
# hex characters before it ever reaches zerotier-cli — a network ID rides on
# argv, and a malformed one must fail loudly, not get silently mangled or
# (worse) passed through as an unintended shell word.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
export ZEROTIER_BACKEND_SKIP_ROOT=1
pass=0 fail=0

fresh() {
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR"
  : > "$FAKE_DIR/log"
}

expect() {
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

for bad in "" "short" "toolong0123456789" "93afae5963b868fZ" "93afae59 3b868fd" "; rm -rf /"; do
  fresh
  bash "$backend" join "$bad" >/dev/null 2>&1; rc=$?
  expect "join rejects invalid nwid: '$bad'" \
    '[ "$rc" != 0 ] && ! grep -q "zerotier-cli join" "$FAKE_DIR/log"'
done

for bad in "" "short" "toolong0123456789"; do
  fresh
  bash "$backend" leave "$bad" >/dev/null 2>&1; rc=$?
  expect "leave rejects invalid nwid: '$bad'" \
    '[ "$rc" != 0 ] && ! grep -q "zerotier-cli leave" "$FAKE_DIR/log"'
done

fresh
bash "$backend" >/dev/null 2>&1; rc=$?
expect "no command prints usage and fails" '[ "$rc" != 0 ]'

fresh
bash "$backend" bogus >/dev/null 2>&1; rc=$?
expect "unknown command fails" '[ "$rc" != 0 ]'

# The lock: a second join for the same network while the fake zerotier-cli
# is mid-invocation should not run concurrently. Modeled after Omawire's
# flock coverage — flock -w 30 9 is exercised implicitly by every join/leave
# test above; here we just confirm the lock file gets created.
fresh
bash "$backend" join 93afae5963b868fd >/dev/null 2>&1
expect "join creates the per-user lock file" '[ -f "$FAKE_DIR/omarchy-omanodes.$(id -u).lock" ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
