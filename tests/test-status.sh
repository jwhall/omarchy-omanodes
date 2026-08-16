#!/bin/bash
# Tests for backend.sh status: a failing zerotier-cli must fail the whole
# command, and the JSON printed must round-trip as-is (QML parses it
# directly with JSON.parse — the backend does no reshaping).
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

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

fresh
cat > "$FAKE_DIR/networks.json" <<'EOF'
[{"id":"93afae5963b868fd","name":"home_lan","status":"OK","type":"PRIVATE","mac":"fe:78:2e:b0:84:c3","portDeviceName":"ztzlgbmmm6","assignedAddresses":["172.26.161.237/16"]}]
EOF
out="$(bash "$backend" status 2>/dev/null)"; rc=$?
expect "happy path: valid JSON with the network's nwid" \
  '[ "$rc" = 0 ] && printf "%s" "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[0][\"id\"]==\"93afae5963b868fd\""'

fresh
: > "$FAKE_DIR/fail-listnetworks"
bash "$backend" status >/dev/null 2>&1; rc=$?
expect "failing listnetworks fails status" '[ "$rc" != 0 ]'

fresh
: > "$FAKE_DIR/networks.json"
echo "[]" > "$FAKE_DIR/networks.json"
out="$(bash "$backend" status 2>/dev/null)"; rc=$?
expect "empty membership prints an empty JSON array" '[ "$rc" = 0 ] && [ "$out" = "[]" ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
