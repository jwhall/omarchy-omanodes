#!/usr/bin/env python3
"""Runtime probe for the QML rich-text URL-load finding.

Serves a beacon over loopback and renders a hostile "network name" three ways
in a real Qt Quick scene:

  auto   -- the unmitigated default (textFormat unset => Text.AutoText).
            MUST fetch. This is the vulnerability, and it is what proves the
            probe can observe a load at all -- without it, "no request" would
            be indistinguishable from a broken test.
  plain  -- textFormat: Text.PlainText, the fix applied to every Text this
            plugin owns. MUST NOT fetch.
  santz  -- Service.qml's own plain(), extracted from the shipped source and
            rendered as AutoText. This models the shared qs.Ui components
            (PanelToolTip, ConfirmDialog) that are outside this repo and still
            render AutoText. MUST NOT fetch.

Usage: richtext-probe.py <path-to-Service.qml> <qml-binary>
"""
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from urllib.parse import unquote

SERVICE, QMLBIN = sys.argv[1], sys.argv[2]

hits = set()
hits_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with hits_lock:
            hits.add(self.path)
        # A 1x1 GIF, so Qt gets something decodable rather than retrying.
        body = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!"
                b"\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01"
                b"\x00\x00\x02\x02D\x01\x00;")
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def extract_plain(path):
    """Pull the shipped plain() out of Service.qml so the probe tests the real
    implementation rather than a copy that can drift away from it."""
    src = open(path, encoding="utf-8").read()
    start = src.index("  function plain(value) {")
    end = src.index("\n  }\n", start) + len("\n  }\n")
    body = src[start:end]
    assert "replace(" in body, "plain() did not extract cleanly"
    return body


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

plain_fn = extract_plain(SERVICE)

CASES = [
    # (label, path, textFormat binding, text binding, must_fetch)
    ("auto", "/auto.gif", "", "hostile('/auto.gif')", True),
    ("plain", "/plain.gif", "textFormat: Text.PlainText", "hostile('/plain.gif')", False),
    ("santz", "/santz.gif", "", "plain(hostile('/santz.gif'))", False),
]

TEMPLATE = """import QtQuick

Item {{
  id: probeRoot
  width: 600
  height: 200

{plain_fn}
  // A ZeroTier network name as an attacker controlling the controller would
  // set it.
  function hostile(path) {{
    return '<img src="http://127.0.0.1:{port}' + path + '" width="8" height="8">'
  }}

  Text {{
    id: probe
    width: parent.width
    {textformat}
    text: {textexpr}
  }}

  Timer {{
    interval: 2500
    running: true
    onTriggered: Qt.quit()
  }}

  Component.onCompleted: {{
    // Touch the geometry so the text is laid out even though nothing is ever
    // presented to a screen under the offscreen platform; rich-text image
    // resources are resolved during that layout.
    console.log("laid out", probe.implicitWidth, probe.implicitHeight)
  }}
}}
"""

env = dict(os.environ)
env["QT_QPA_PLATFORM"] = "offscreen"
env.setdefault("QT_LOGGING_RULES", "qt.qpa.*=false")

failures = []
for label, path, textformat, textexpr, must_fetch in CASES:
    with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False,
                                     encoding="utf-8") as fh:
        fh.write(TEMPLATE.format(plain_fn=plain_fn, port=port,
                                 textformat=textformat, textexpr=textexpr))
        qml_path = fh.name
    try:
        proc = subprocess.run([QMLBIN, qml_path], env=env, timeout=60,
                              capture_output=True, text=True)
    finally:
        os.unlink(qml_path)
    with hits_lock:
        fetched = path in hits
    ok = fetched == must_fetch
    print("  %-5s textFormat=%-24s fetched=%-5s expected=%-5s %s"
          % (label, textformat or "(default AutoText)", fetched, must_fetch,
             "ok" if ok else "MISMATCH"))
    if not ok:
        failures.append("%s: fetched=%s expected=%s (qml rc=%s stderr=%s)"
                        % (label, fetched, must_fetch, proc.returncode,
                           proc.stderr.strip()[:400]))

# Sanitising must not silently mangle ordinary names: the mitigation is only
# acceptable if the common case round-trips untouched. The results come back
# over the same loopback server rather than console.log, which the `qml` tool
# filters out by default.
FIDELITY = [
    ("home_lan", "home_lan"),
    ("Ops \u2014 EU/West #2 (prod)", "Ops \u2014 EU/West #2 (prod)"),
    ("a & b", "a & b"),
    ("<img src=x>", "\u2039img src=x\u203a"),
    ("na\u0007me", "na me"),
]
FIDELITY_TEMPLATE = """import QtQuick

Item {{
  width: 64
  height: 64

{plain_fn}
  Repeater {{
    model: {cases}
    Image {{
      required property string modelData
      source: "http://127.0.0.1:{port}/fidelity?v=" + encodeURIComponent(plain(modelData))
    }}
  }}

  Timer {{ interval: 2500; running: true; onTriggered: Qt.quit() }}
}}
"""
with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False,
                                 encoding="utf-8") as fh:
    fh.write(FIDELITY_TEMPLATE.format(
        plain_fn=plain_fn, port=port,
        cases=json.dumps([c[0] for c in FIDELITY])))
    fidelity_path = fh.name
try:
    proc = subprocess.run([QMLBIN, fidelity_path], env=env, timeout=60,
                          capture_output=True, text=True)
finally:
    os.unlink(fidelity_path)

with hits_lock:
    seen = {unquote(h.split("?v=", 1)[1])
            for h in hits if h.startswith("/fidelity?v=")}
for src, want in FIDELITY:
    ok = want in seen
    print("  plain(%-30s) -> %-30s %s"
          % (json.dumps(src), json.dumps(want) if ok else "(not produced)",
             "ok" if ok else "MISMATCH"))
    if not ok:
        failures.append("plain(%r) did not produce %r; got one of %r"
                        % (src, want, sorted(seen)))

server.shutdown()
if failures:
    print("  probe failures: " + json.dumps(failures, indent=2))
    sys.exit(1)
sys.exit(0)
