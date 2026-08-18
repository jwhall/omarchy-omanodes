# Manual checklist

Things the fake `zerotier-cli` cannot prove — verify by hand against a real
`zerotier-one` service.

- **Real join against a controller.** `zerotier-cli join <nwid>` on a
  private network returns success immediately even before the controller
  authorizes the member — `status` stays `ACCESS_DENIED` until it does (or
  forever, if nobody authorizes it). Confirm the panel shows that status
  honestly rather than implying membership completed.
- **The real pkexec/polkit prompt flow.** With the polkit policy
  (`polkit/org.jwhall.omanodes.policy`) *not* installed: confirm every
  status poll pops a pkexec dialog (expected — this is why the policy isn't
  optional). With the policy installed and an active local session: confirm
  no prompt appears at all, for both reads (status) and joins/leaves.
- **`zerotier-one.service` not running.** Stop it
  (`sudo systemctl stop zerotier-one`) and confirm the panel surfaces a
  clear error (bar icon turns urgent, `lastError` reads something
  actionable) rather than hanging or showing a stale, silently-wrong list.
  Restart it and confirm the next poll recovers.
- **sudo path vs pkexec path.** `require_root()` picks `sudo` when stdin is
  a TTY and `pkexec` otherwise. Quickshell's `Process` invocation has no
  TTY, so it should always take the `pkexec` branch in practice — confirm
  that's actually what happens (e.g. via `ps` while a poll is in flight),
  since a `sudo` invocation with no TTY and no cached credentials would just
  hang or fail depending on `askpass` configuration.
- **Leave/rejoin round-trip on a real private network.** Leave a network the
  controller previously authorized, then rejoin with the same node ID and
  confirm whether it reauthorizes automatically (most controllers remember
  prior members) or requires manual re-approval — the README should not
  overpromise here since it depends on the controller, not this plugin.
- **Multiple monitors.** With the bar widget instantiated once per monitor
  (as Omarchy does), confirm the flock actually prevents two simultaneous
  join/leave clicks on different monitors from racing.
- **`ensure_runtime_dir()` under real elevation.** Fakes can't set `EUID`,
  so the `SUDO_UID`/`PKEXEC_UID` fallback that resolves the *invoking*
  user's runtime dir once root (see the comment above
  `ensure_runtime_dir()`) is untested by `tests/run.sh`. Verified manually
  via `pkexec backend.sh <cmd>` after the fix for the "A private
  XDG_RUNTIME_DIR is required" bug (join/leave failed under pkexec because
  it strips `XDG_RUNTIME_DIR`, and the old code fell back to root's own
  `/run/user/0`, which doesn't exist) — confirm this keeps working after
  any future change to `require_root()`/`ensure_runtime_dir()`.
- **Root ignores a caller-supplied `XDG_RUNTIME_DIR`.** Same `EUID`
  limitation: `tests/run.sh` only ever exercises the unprivileged branch,
  where honouring `XDG_RUNTIME_DIR` is correct. Verify by hand that the root
  branch does not: `sudo XDG_RUNTIME_DIR=/tmp/decoy /usr/lib/omanodes/backend.sh
  join <nwid>` (with `/tmp/decoy` a 0700 dir you own) must create its lock
  under `/run/user/<your uid>/`, and leave `/tmp/decoy` empty.
- **Root runs with a pinned `PATH`.** Put a fake `zerotier-cli` earlier in
  `PATH` than `/usr/bin` and confirm an elevated invocation still runs the
  real one — e.g. `sudo PATH=/tmp/evil:$PATH /usr/lib/omanodes/backend.sh status`
  should return real network JSON, not the fake's output. (`pkexec` and
  sudo's `secure_path` would each stop this on a stock system; the point is
  that the script no longer depends on either.)
