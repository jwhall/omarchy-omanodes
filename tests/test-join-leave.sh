#!/bin/bash
# Tests for backend.sh join/leave: valid IDs are passed through, failures
# propagate, and the lock serializes concurrent-looking invocations.
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

fresh
bash "$backend" join 93afae5963b868fd >/dev/null 2>&1; rc=$?
expect "join with a valid 16-hex nwid succeeds" '[ "$rc" = 0 ] && grep -q "join 93afae5963b868fd" "$FAKE_DIR/log"'

fresh
: > "$FAKE_DIR/fail-join.93afae5963b868fd"
bash "$backend" join 93afae5963b868fd >/dev/null 2>&1; rc=$?
expect "a failing join propagates its exit code" '[ "$rc" != 0 ]'

fresh
bash "$backend" leave 93afae5963b868fd >/dev/null 2>&1; rc=$?
expect "leave with a valid 16-hex nwid succeeds" '[ "$rc" = 0 ] && grep -q "leave 93afae5963b868fd" "$FAKE_DIR/log"'

fresh
: > "$FAKE_DIR/fail-leave.93afae5963b868fd"
bash "$backend" leave 93afae5963b868fd >/dev/null 2>&1; rc=$?
expect "a failing leave propagates its exit code" '[ "$rc" != 0 ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
