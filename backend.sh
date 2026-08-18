#!/bin/bash
# zerotier-cli backend for Omanodes, the Omarchy ZeroTier widget.
#
# Unlike NetworkManager's D-Bus/polkit model (see Omawire), zerotier-one's
# local API is authorized by a bearer token in
# /var/lib/zerotier-one/authtoken.secret, mode 0600, owned by the
# zerotier-one system user. zerotier-cli itself reads that file directly, so
# *every* invocation — even a read-only `listnetworks` — needs root, not
# just joins/leaves. This is a real difference from Omawire and means the
# status poll that drives the panel also self-elevates on every tick.
#
# require_root() below execs as root via sudo (interactive terminal) or
# pkexec (GUI, no TTY) — the same pattern omarchy-dns uses. pkexec consults
# polkit, which is silent for an active local session only if this plugin's
# polkit policy (polkit/org.jwhall.omanodes.policy) has been installed — see
# README. Until then, every poll pops an auth dialog, which is unusable for
# a 10-second timer; the policy is not optional in practice.
#
# Both the pkexec and sudo branches exec SYSTEM_BACKEND, a root-owned copy
# installed outside this (user-writable) plugin checkout — never
# self_path(). This matters most for pkexec: polkit's allow_active=yes only
# vouches for physical presence at the session, not for administrative
# trust, so the file named in the policy's org.freedesktop.policykit.exec.path
# must not be writable by the account the policy authorizes. But it also
# matters for sudo — a NOPASSWD sudoers rule (see README) removes the "own
# password" boundary sudo normally provides, and if that rule names the
# user-writable plugin checkout instead of SYSTEM_BACKEND, it reopens the
# exact same hole. Using SYSTEM_BACKEND unconditionally means the script is
# safe regardless of which elevation path (or sudoers scope) the user picks.
#
# Mutating commands (join/leave) serialize on a per-user flock, same
# reasoning as Omawire: the bar builds one widget instance per monitor.
#
# Commands:
#   status              zerotier-cli -j listnetworks, verbatim (a JSON
#                       array) — QML parses it directly with JSON.parse.
#   join <nwid>          join a 16-hex-digit network
#   leave <nwid>          leave a 16-hex-digit network

set -u
set -o pipefail
export LC_ALL=C
umask 077

# Pin the search path once privileged. As root this script resolves
# zerotier-cli, flock, mkdir, stat and id from PATH, so an inherited PATH
# would be an untrusted search path — root running a caller-chosen binary.
# pkexec sanitizes the environment and sudo's stock secure_path covers this
# too, but both are guarantees that live outside the plugin, and the README
# hands users a NOPASSWD rule for this very script; don't depend on them.
# Only the root branch is pinned: below EUID 0 nothing has crossed a
# privilege boundary yet, and the test suite relies on PATH to reach its
# fake zerotier-cli.
if (( EUID == 0 )); then
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export PATH
fi

# Root-owned, non-user-writable copy that the polkit policy's
# org.freedesktop.policykit.exec.path points to. Installed separately (see
# README) — must be kept in sync by re-running that install step whenever
# this script changes.
SYSTEM_BACKEND="/usr/lib/omanodes/backend.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

require_root() {
  # Test-only escape hatch: the test suite runs as a normal user against a
  # fake zerotier-cli and has no real root to elevate to, so a fake `sudo`
  # on PATH that just re-execs this script would recurse forever (EUID never
  # becomes 0). Tests set this instead of faking privilege escalation.
  [ -n "${ZEROTIER_BACKEND_SKIP_ROOT:-}" ] && return
  if (( EUID == 0 )); then
    return
  fi
  [ -x "$SYSTEM_BACKEND" ] ||
    die "$SYSTEM_BACKEND is not installed — see the README's install step"
  if [[ -t 0 ]]; then
    exec sudo "$SYSTEM_BACKEND" "$@"
  else
    exec pkexec "$SYSTEM_BACKEND" "$@"
  fi
}

is_valid_nwid() {
  [[ "$1" =~ ^[0-9a-fA-F]{16}$ ]]
}

RUNTIME_DIR=""
TARGET_UID=""

# Mirrors Omawire's ensure_runtime_dir: refuse anything but a private,
# current-user XDG_RUNTIME_DIR rather than falling back to /tmp.
#
# require_root() re-execs this script as root via sudo/pkexec, and both
# strip most of the caller's environment for security — XDG_RUNTIME_DIR
# does not survive. So once EUID is 0, "the current user" for the purposes
# of finding the runtime dir means the *invoking* user, which sudo exposes
# as $SUDO_UID and pkexec as $PKEXEC_UID (both are set by those tools
# specifically so a privileged process can recover this). Falling back to
# EUID (0) here would look for /run/user/0, which is root's own runtime
# dir — normally absent, which is exactly the "XDG_RUNTIME_DIR is required"
# failure this plugin's leave/join actions were hitting.
#
# As root the directory is derived from that uid and the environment's
# XDG_RUNTIME_DIR is ignored outright, rather than merely preferred-then-
# validated. $XDG_RUNTIME_DIR is caller-supplied, and a caller-supplied
# path is what root then mkdir()s into; the ownership and mode checks below
# bound that but do not remove the caller from the decision, and they are
# checks on a path that can still be swapped afterwards. Root should not be
# taking directions about where to write from the account it is acting for,
# especially with a NOPASSWD sudoers rule (SETENV, env_keep) in the picture.
# /run/user/<uid> is the correct answer for that uid by definition, and its
# parent /run/user is root-owned, so the directory itself cannot be swapped.
ensure_runtime_dir() {
  [ -n "$RUNTIME_DIR" ] && return 0
  local target_uid dir mode owner
  if (( EUID == 0 )); then
    target_uid="${SUDO_UID:-${PKEXEC_UID:-}}"
    # Now that this uid is concatenated into a path, insist it is a plain
    # number: sudo and pkexec both set it, but a bare-root invocation could
    # carry a forged one in from anywhere.
    [[ "$target_uid" =~ ^[0-9]+$ ]] || die "Cannot determine the invoking user"
    dir="/run/user/$target_uid"
  else
    target_uid="$EUID"
    dir="${XDG_RUNTIME_DIR:-/run/user/$target_uid}"
  fi
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] ||
    die "A private XDG_RUNTIME_DIR is required for ZeroTier state"
  owner="$(stat -Lc '%u' -- "$dir" 2>/dev/null)" ||
    die "Cannot inspect XDG_RUNTIME_DIR"
  [ "$owner" = "$target_uid" ] ||
    die "XDG_RUNTIME_DIR is not owned by the invoking user"
  mode="$(stat -Lc '%a' -- "$dir" 2>/dev/null)" ||
    die "Cannot inspect XDG_RUNTIME_DIR"
  case "$mode" in
    ''|*[!0-7]*) die "XDG_RUNTIME_DIR has unsafe permissions" ;;
  esac
  [ $((8#$mode & 0077)) -eq 0 ] ||
    die "XDG_RUNTIME_DIR has unsafe permissions"
  RUNTIME_DIR="$dir"
  TARGET_UID="$target_uid"
}

# The lock lives inside the invoking user's runtime dir, so the user controls
# that path while this function usually runs as root. A regular file opened
# with `>>` would follow a symlink planted there, letting an unprivileged
# active session make root create or touch any path on the system
# (/etc/nologin being the classic). bash has no O_NOFOLLOW redirection, so
# instead the lock is a *directory*: `mkdir` never follows a final symlink,
# and flock's fd is opened read-only (`<`), which creates nothing even if the
# path is swapped between the mkdir and the open. The post-open check on
# /dev/fd/9 confirms what was actually opened is still a directory.
lock() {
  need flock
  ensure_runtime_dir
  local d="$RUNTIME_DIR/omarchy-omanodes.$TARGET_UID.lock.d"
  mkdir -m 0700 "$d" 2>/dev/null
  [ -d "$d" ] && [ ! -L "$d" ] || die "Cannot open the lock file"
  exec 9<"$d" || die "Cannot open the lock file"
  [ -d /dev/fd/9 ] || die "Cannot open the lock file"
  flock -w 30 9 || die "Another ZeroTier operation is already running"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

cmd_status() {
  need zerotier-cli
  exec zerotier-cli -j listnetworks
}

cmd_join() {
  local nwid="$1"
  is_valid_nwid "$nwid" || die "Invalid network ID: $nwid"
  need zerotier-cli
  zerotier-cli join "$nwid" || die "Could not join network $nwid"
}

cmd_leave() {
  local nwid="$1"
  is_valid_nwid "$nwid" || die "Invalid network ID: $nwid"
  need zerotier-cli
  zerotier-cli leave "$nwid" || die "Could not leave network $nwid"
}

case "${1:-}" in
  status) require_root "$@"; cmd_status ;;
  join) require_root "$@"; lock; cmd_join "${2:-}" ;;
  leave) require_root "$@"; lock; cmd_leave "${2:-}" ;;
  *) die "Usage: backend.sh status|join <nwid>|leave <nwid>" ;;
esac
