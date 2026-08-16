#!/bin/bash
# zerotier-cli backend for Omanode, the Omarchy ZeroTier widget.
#
# Unlike NetworkManager's D-Bus/polkit model (see Omawire), zerotier-one's
# local API is authorized by a bearer token in
# /var/lib/zerotier-one/authtoken.secret, mode 0600, owned by the
# zerotier-one system user. zerotier-cli itself reads that file directly, so
# *every* invocation — even a read-only `listnetworks` — needs root, not
# just joins/leaves. This is a real difference from Omawire and means the
# status poll that drives the panel also self-elevates on every tick.
#
# require_root() below execs the script back into itself as root via sudo
# (interactive terminal) or pkexec (GUI, no TTY) — the same pattern
# omarchy-dns uses. pkexec consults polkit, which is silent for an active
# local session only if this plugin's polkit policy
# (polkit/org.jwhall.omanode.policy) has been installed — see README. Until
# then, every poll pops an auth dialog, which is unusable for a 10-second
# timer; the policy is not optional in practice.
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

die() { printf '%s\n' "$*" >&2; exit 1; }

self_path() {
  readlink -f "${BASH_SOURCE[0]}"
}

require_root() {
  # Test-only escape hatch: the test suite runs as a normal user against a
  # fake zerotier-cli and has no real root to elevate to, so a fake `sudo`
  # on PATH that just re-execs this script would recurse forever (EUID never
  # becomes 0). Tests set this instead of faking privilege escalation.
  [ -n "${ZEROTIER_BACKEND_SKIP_ROOT:-}" ] && return
  if (( EUID == 0 )); then
    return
  fi
  if [[ -t 0 ]]; then
    exec sudo "$(self_path)" "$@"
  else
    exec pkexec "$(self_path)" "$@"
  fi
}

is_valid_nwid() {
  [[ "$1" =~ ^[0-9a-fA-F]{16}$ ]]
}

RUNTIME_DIR=""

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
ensure_runtime_dir() {
  [ -n "$RUNTIME_DIR" ] && return 0
  local target_uid dir mode owner
  if (( EUID == 0 )); then
    target_uid="${SUDO_UID:-${PKEXEC_UID:-}}"
    [ -n "$target_uid" ] || die "Cannot determine the invoking user"
  else
    target_uid="$EUID"
  fi
  dir="${XDG_RUNTIME_DIR:-/run/user/$target_uid}"
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
}

lock() {
  need flock
  ensure_runtime_dir
  exec 9>>"$RUNTIME_DIR/omarchy-omanode.$(id -u).lock" || die "Cannot open the lock file"
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
