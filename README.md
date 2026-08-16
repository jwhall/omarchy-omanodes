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

### Install the polkit policy (required)

```bash
sudo install -Dm644 polkit/org.jwhall.omanodes.policy \
  /usr/share/polkit-1/actions/org.jwhall.omanodes.policy
sudo sed -i "s|@PLUGIN_DIR@|$(readlink -f .)|" \
  /usr/share/polkit-1/actions/org.jwhall.omanodes.policy
```

Run that from inside this plugin's directory (`~/.config/omarchy/plugins/jwhall.omanodes`
by default) — the `sed` step fills in the absolute path to `backend.sh` so
polkit knows to scope the exemption to this script specifically, not to
`pkexec` in general. Use `readlink -f .`, not `pwd`: `backend.sh`'s own
`self_path()` resolves through symlinks (`readlink -f "${BASH_SOURCE[0]}"`)
before invoking `pkexec`, so if `~/.config/omarchy` (or this plugin
directory) is itself a symlink — common with dotfiles managers — `pwd`
captures the symlinked view path while pkexec is actually invoked with the
resolved physical path. Those must match exactly or polkit silently falls
back to the generic, always-prompts `org.freedesktop.policykit.exec`
action instead of this scoped one (check `journalctl -u polkit` for that
action name if the panel keeps prompting after installing the policy). If
you move the plugin directory afterward, re-run the `sed` step with the
new path.

The policy grants `allow_active=yes`: an active local graphical session runs
the backend without a password, the same trust level NetworkManager's own
polkit rules give an active session for network control. It does **not**
grant passwordless root generally — only for this one script.

If you'd rather not install a system-wide polkit action, the alternative is
a `sudo` `NOPASSWD` rule scoped to `zerotier-cli` in `/etc/sudoers.d/`
(`visudo -f /etc/sudoers.d/zerotier-widget`) — but note `backend.sh` only
takes the `sudo` branch when stdin is a TTY, which the panel's background
`Process` invocations are not, so this path only helps if you also adjust
`require_root()` or invoke the backend from a terminal yourself.

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
- `$XDG_RUNTIME_DIR/omarchy-omanodes.<uid>.lock` — a per-user `flock` so
  concurrent join/leave clicks (one widget instance per monitor) serialize
  instead of racing. Private, gone at reboot.
- No files outside of that lock; no state is persisted between sessions —
  network membership itself is `zerotier-one`'s own state, not this
  plugin's.

## Tests

`tests/` runs `backend.sh` against a fake `zerotier-cli` on `PATH`, plus a
manual checklist (`tests/checklist.md`) for what needs a real `zerotier-one`
service and a real polkit prompt:

```bash
bash tests/run.sh
```

## Uninstall

```bash
omarchy plugin remove jwhall.omanodes
sudo rm -f /usr/share/polkit-1/actions/org.jwhall.omanodes.policy
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
