# Omanodes — ZeroTier networks in the Omarchy bar

List, join, leave and inspect [ZeroTier](https://www.zerotier.com/) networks
from the [Omarchy](https://github.com/basecamp/omarchy) bar.

This is an unofficial third-party widget. It is not affiliated with,
endorsed by, or connected to ZeroTier, Inc.

Everything goes through `zerotier-cli`, the same tool the `zerotier-one`
service ships. This plugin does not talk to the ZeroTier Central API or any
network controller directly — it only reflects what your local node knows
about its own memberships.

## Requirements

- **`zerotier-one`** — installed and running (`systemctl status zerotier-one`).
- **`polkit`** — for privilege escalation (see below). Present by default on
  Omarchy/most desktop distros.

## Why this needs root, and what that means for you

`zerotier-cli` authorizes itself against the local `zerotier-one` service by
reading `/var/lib/zerotier-one/authtoken.secret`, which is mode `0600`,
owned by the `zerotier-one` system user. Only root can read it. That means
**every** call this plugin makes — including the read-only status poll that
drives the panel, not just joining or leaving — needs root.

`backend.sh` self-elevates via `pkexec` (or `sudo` in a terminal), the same
pattern Omarchy's own `omarchy-dns` uses. Without more configuration this
pops a polkit authentication dialog on every call — and the panel polls
every `refreshIntervalSec` (10s by default), so **you must install the
bundled polkit policy** below, or the widget will be unusable (a password
prompt every few seconds).

### Install the polkit policy and backend (required)

```bash
sudo install -Dm755 backend.sh /usr/lib/omanodes/backend.sh
sudo install -Dm644 polkit/org.jwhall.omanodes.policy \
  /usr/share/polkit-1/actions/org.jwhall.omanodes.policy
```

The policy grants `allow_active=yes`: an active local graphical session runs
the backend without a password, the same trust level NetworkManager's own
polkit rules give an active session for network control. That trust level
covers *physical presence at the session*, not administrative privilege —
so the script it authorizes must live somewhere that active-but-unprivileged
user can't write to. That's why the policy points at
`/usr/lib/omanodes/backend.sh` (root-owned, installed by the command above)
rather than at this plugin's own checkout under
`~/.config/omarchy/plugins/`, which the same user owns. It does **not**
grant passwordless root generally — only for that one root-owned script.

If you update the plugin (which changes `backend.sh`), re-run the
`install -Dm755 backend.sh ...` step to refresh the system copy — the
policy's exemption always runs whatever is currently installed at
`/usr/lib/omanodes/backend.sh`, not the plugin checkout's copy.

If you'd rather not install a system-wide polkit action, the alternative is
a `sudo` `NOPASSWD` rule in `/etc/sudoers.d/`
(`visudo -f /etc/sudoers.d/omanodes`), scoped to the installed root-owned
backend and to the exact three commands it accepts:

```
Cmnd_Alias OMANODES = /usr/lib/omanodes/backend.sh status, \
                      /usr/lib/omanodes/backend.sh join [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f], \
                      /usr/lib/omanodes/backend.sh leave [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]
youruser ALL=(root) NOPASSWD: OMANODES
```

(The 16 repeated character classes are sudo's glob syntax for "exactly 16
lowercase hex digits" — sudo has no counted-repeat form. `zerotier-cli`
prints network IDs in lowercase; add `A-F` to the classes if you type them
uppercase.)

**Do not** write the rule as `NOPASSWD: /usr/bin/zerotier-cli` (or any
unbounded command). Passwordless `zerotier-cli` with no argument bound hands
the account its entire root command surface — `zerotier-cli set ...` and
friends reconfigure the node, and an unbounded rule is a standing
passwordless-root primitive rather than the three operations this widget
needs. Likewise, never point the rule at `backend.sh` inside the plugin
checkout: `NOPASSWD` removes the password boundary that normally makes a
user-writable target safe under `sudo`, so it must name the root-owned
`/usr/lib/omanodes/backend.sh` — which is also what `require_root()` execs.

Note that `backend.sh` only takes the `sudo` branch when stdin is a TTY,
which the panel's background `Process` invocations are not, so this path
only helps if you also adjust `require_root()` or invoke the backend from a
terminal yourself.

## Install

```bash
omarchy plugin add https://github.com/jwhall/omarchy-omanodes.git
omarchy plugin enable jwhall.omanodes right
```

Then install the polkit policy as described above — the plugin will load
without it, but the panel will be unusable until you do.

## Using it

**In the bar:** left click opens and closes the panel, middle click
refreshes.

**In the panel:**

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the cursor |
| `Enter` | leave the selected network (asks first), or open the join prompt from the header |
| `n` | join a network by ID |
| `l` | leave the selected network (asks first) |
| `i` | show network info |
| `r` | refresh |
| `Esc` | close |

Hovering (or moving the keyboard cursor to) a network row reveals two
buttons: a leave/join toggle and an info button that opens the network's
detail window.

**Joining and leaving are not "connect/disconnect."** ZeroTier has no
concept of temporarily pausing a network while staying a member —
`zerotier-cli` only supports `join` and `leave`. Leaving a `PRIVATE` network
removes your authorization on its controller; rejoining may require the
controller to re-approve you (instant if it remembers you, not guaranteed
otherwise). The row button and the confirmation dialog say "Leave", not
"Disconnect", on purpose.

**Network info** shows what this host's local ZeroTier service knows about
one network: name, ID, type, status, this host's assigned address(es), MAC,
and the local interface name. It does **not** show other members of the
network. `zerotier-cli` on a regular member node has no way to list a
network's other members or their assigned addresses — that data lives only
on the network's controller (ZeroTier Central, or a self-hosted controller's
own API), which this plugin does not talk to.

## Settings

| Key | Default | Range |
| --- | --- | --- |
| `refreshIntervalSec` | `10` | 2–3600 |

```bash
omarchy bar set jwhall.omanodes refreshIntervalSec 30
```

Raising this reduces both polkit prompt frequency (if you haven't installed
the policy) and the load of a background elevated call running constantly —
but it also means the panel's list is stale for longer after a change made
outside the widget (`zerotier-cli join ...` from a terminal, another host
approving your membership, etc.).

## IPC

```bash
omarchy-shell jwhall.omanodes open      # also: close, show, hide
omarchy-shell jwhall.omanodes refresh
omarchy-shell jwhall.omanodes status    # "N network(s) joined"
omarchy-shell jwhall.omanodes join 93afae5963b868fd
omarchy-shell jwhall.omanodes leave 93afae5963b868fd
```

## What it touches

- **`zerotier-cli -j listnetworks` / `join` / `leave`** — every call
  self-elevates to root via `pkexec`/`sudo`; see above.
- `$XDG_RUNTIME_DIR/omarchy-omanodes.<uid>.lock.d` — a per-user `flock` so
  concurrent join/leave clicks (one widget instance per monitor) serialize
  instead of racing. Private, gone at reboot.
- No files outside of that lock; no state is persisted between sessions —
  network membership itself is `zerotier-one`'s own state, not this
  plugin's.

## Tests

`tests/` runs `backend.sh` against a fake `zerotier-cli` on `PATH`, checks
the QML side against controller-supplied text (see below), and keeps a
manual checklist (`tests/checklist.md`) for what needs a real `zerotier-one`
service and a real polkit prompt:

```bash
bash tests/run.sh
```

`tests/test-qml-markup.sh` needs Qt's `qml` runtime (`qt6-declarative`) for
its runtime half and skips that part if it is missing; the static half always
runs.

## Untrusted text from the controller

A network's `name` is set on the ZeroTier controller, not on this host, so it
is untrusted input to the widget. QML's default `textFormat: Text.AutoText`
sends anything Qt recognises as markup to the rich-text engine, which resolves
`<img src>` and `<a href>` URLs from inside the shell process — so a crafted
name could make simply opening the panel fetch a remote URL or read a local
file.

Two layers close that off:

- every `Text` element in this plugin pins `textFormat: Text.PlainText`, and
- `Service.plain()` neutralises `<`/`>` and control characters at the single
  point where controller data (and backend stderr) enters the model, which
  also covers the shared `qs.Ui` components this widget hands text to
  (`PanelToolTip`, `ConfirmDialog`) — those live outside this repo and still
  render `AutoText`.

`tests/richtext-probe.py` proves both in a real Qt scene against a loopback
HTTP server: the unmitigated `AutoText` case must fetch the beacon (otherwise
the probe is not measuring anything), while the `PlainText` case and
`plain()`'s output must not.

## Uninstall

```bash
omarchy plugin remove jwhall.omanodes
sudo rm -f /usr/share/polkit-1/actions/org.jwhall.omanodes.policy
sudo rm -f /usr/lib/omanodes/backend.sh
```

Your ZeroTier network memberships are unaffected — they belong to
`zerotier-one`, not this widget. Leave a network with `zerotier-cli leave
<nwid>` if you want it gone too.

## License

MIT — see [LICENSE](LICENSE).

## Trademarks

"ZeroTier" and the ZeroTier logo are trademarks of ZeroTier, Inc. This
plugin's bundled icon (`assets/zerotier-logo.png`) is ZeroTier's mark, used
solely to identify the service this widget controls. This widget is an
independent third-party tool: it is neither affiliated with nor endorsed by
ZeroTier, Inc. The MIT licence above covers this widget's own code and
grants no rights in ZeroTier's trademarks or logo — do not redistribute the
icon outside this widget's stated purpose without ZeroTier, Inc.'s
permission.
