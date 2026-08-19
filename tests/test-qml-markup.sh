#!/bin/bash
# Controller-supplied network names reach QML Text elements. QML's default
# `textFormat: Text.AutoText` routes anything Qt::mightBeRichText() accepts to
# the rich-text engine, which resolves `<img src>` URLs from inside the shell
# process — so a crafted name is a zero-interaction outbound request (or local
# file read) triggered by merely displaying the network list.
#
# Two layers are tested here:
#   1. static  — every Text this plugin owns pins textFormat: Text.PlainText,
#                and Service.qml neutralises markup at the model boundary.
#   2. runtime — the real Qt behaviour, against a loopback HTTP server: the
#                unmitigated AutoText case must actually fetch (proving the
#                probe detects a load at all), while the PlainText case and
#                Service.qml's own plain() output must not.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
pass=0 fail=0

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
}

# --- 1. static ---------------------------------------------------------------

# Every `Text {` block in the plugin's own QML must set textFormat explicitly.
# Blocks are delimited by their opening brace's indentation, which is how this
# codebase is formatted throughout.
missing="$(python3 - "$root" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for name in sorted(os.listdir(root)):
    if not name.endswith(".qml"):
        continue
    lines = open(os.path.join(root, name), encoding="utf-8").read().splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)Text\s*\{\s*$", line)
        if not m:
            continue
        indent = len(m.group(1))
        body = []
        for line2 in lines[i + 1:]:
            if re.match(r"^\s{%d}\}" % indent, line2):
                break
            body.append(line2)
        if not any("textFormat:" in b for b in body):
            bad.append("%s:%d" % (name, i + 1))
print("\n".join(bad))
PY
)"
expect "every Text element declares textFormat" '[ -z "$missing" ]'

# Bindings only -- prose in comments may well name Text.AutoText.
expect "declared textFormat is always PlainText" \
  '[ "$(grep -hE "^[[:space:]]*textFormat:" "$root"/*.qml | grep -cv "Text.PlainText")" = 0 ]'

expect "Service.qml sanitises controller fields into the model" \
  'grep -q "name: plain(n.name)" "$root/Service.qml" && grep -q "status: plain(n.status)" "$root/Service.qml"'

expect "Service.qml sanitises backend stderr before display" \
  'grep -q "var value = plain(text)" "$root/Service.qml"'

# --- 2. runtime --------------------------------------------------------------

qmlbin="$(command -v qml6 || command -v qml || true)"
if [ -z "$qmlbin" ]; then
  echo "SKIP runtime rich-text probe (no qml runtime on PATH)"
else
  probe_out="$(python3 "$here/richtext-probe.py" "$root/Service.qml" "$qmlbin" 2>&1)"
  probe_rc=$?
  echo "$probe_out"
  expect "runtime: AutoText/PlainText/plain() probe" '[ "'"$probe_rc"'" = 0 ]'
fi

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
