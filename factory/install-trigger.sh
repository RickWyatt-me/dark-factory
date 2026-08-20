#!/usr/bin/env bash
# Component 2, the last mile. This is the switch that makes the repository unattended.
#
#   bash factory/install-trigger.sh --status        what is armed right now
#   bash factory/install-trigger.sh --verify        prove the scheduler's environment works
#   bash factory/install-trigger.sh --print-plist   show the launchd job it would install
#   bash factory/install-trigger.sh --install       arm it
#   bash factory/install-trigger.sh --remove        disarm it
#
# Everything else in this factory can be run by hand and inspected. This is the one step
# that takes the human out, so it is the last thing you do and the first thing you check
# when something has gone quiet.
#
# ---------------------------------------------------------------------------
# IT POLLS. NOTHING PUSHES.
# ---------------------------------------------------------------------------
# Filing an issue does not trigger a run. There is no webhook and there is not meant to
# be one. A scheduler wakes up on a timer, reads the state, and dispatches at most one
# thing. An issue filed at 09:01 waits until the next tick.
#
# That is deliberate. A push trigger that fails, fails SILENTLY - nothing errors, nothing
# logs, and the factory looks like it had nothing to do. A poll that fails is a poll you
# can see not running. In a system whose defining property is that nobody is watching,
# always prefer the mechanism that fails loudly.
#
# The 30-minute default is also deliberate, and it is slower than feels right. A fast
# loop multiplies the cost of a mistake before you have noticed the mistake.
#
# ---------------------------------------------------------------------------
# ON macOS THE SCHEDULER IS launchd, NOT cron (program decision D7).
# ---------------------------------------------------------------------------
# The precedent on this machine is the OneDrive photo-export loop
# (~/Library/LaunchAgents/com.example.vox-photo-onedrive.plist): a user LaunchAgent with
# a StartInterval and an EXPLICIT PATH. The explicit PATH is the load-bearing part.
# launchd starts jobs with a minimal environment - /usr/bin:/bin:/usr/sbin:/sbin and
# nothing else - so a job that shells out to `gh`, `supabase`, `node`, or `claude`
# (homebrew and ~/.local/bin installs, all of them) dies on "command not found" before
# it can log anything useful. A launchd job dead on PATH looks IDENTICAL to an idle
# factory, which is the one failure mode this whole system exists to avoid. Hence:
#   1. the plist carries the full PATH the factory's scripts were verified against, and
#   2. --install refuses to arm until --verify has proven every binary resolves UNDER
#      THAT EXACT PATH, the GitHub auth works, and the escalation webhook is reachable.
#
# A LaunchAgent (not a LaunchDaemon) on purpose: it runs in Rick's login session, which
# is where the keychain lives - `gh`, `claude`, and the Slack webhook all resolve their
# credentials from it. The cost is honest and documented: the factory ticks only while
# Rick is logged in. A factory that stops because the machine logged out looks exactly
# like one with nothing to do - that caveat is recorded in FACTORY.md.
#
# THE PROGRAM MUST HOLD FULL DISK ACCESS (macOS TCC). Background jobs are refused
# ~/Documents outright - silent exit 126, found live at the first Phase F arming. The
# grant attaches to the launchd job's PROGRAM and covers its children (proven both
# ways with live probes). $FACTORY_TRIGGER_PROGRAM in config.sh names the granted
# binary; when it is a node runtime, the job runs factory/tick.mjs, which immediately
# hands off to the same orchestrator a bash program would run directly.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

INTERVAL_MIN="${FACTORY_INTERVAL_MINUTES:-30}"
TASK_NAME="${FACTORY_TASK_NAME:-dark-factory-$(basename "$ROOT")}"
LOGFILE="$ROOT/factory-orchestrator.log"
ACTION="${1:---status}"

case "$(uname -s 2>/dev/null || echo Windows)" in
  Linux*)   PLATFORM=linux   ;;
  Darwin*)  PLATFORM=macos   ;;
  MINGW*|MSYS*|CYGWIN*|Windows*) PLATFORM=windows ;;
  *)        PLATFORM=unknown ;;
esac

# linux only; macOS is launchd (above)
CRON_LINE="*/$INTERVAL_MIN * * * * cd $ROOT && bash factory/orchestrator.sh >> $LOGFILE 2>&1  # $TASK_NAME"

# --- launchd names (macOS) ----------------------------------------------------
# Reverse-DNS label per the machine's own precedent (com.example.vox-photo-onedrive).
LABEL="com.example.$TASK_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# THE PATH THE JOB RUNS WITH. Everything the factory shells out to must resolve under
# this and nothing else: git/python3/curl/jq/security (system), node/gh/supabase/deno
# (homebrew), claude (~/.local/bin). Verified by --verify before --install will arm.
AGENT_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# The job's program (config.sh: must hold Full Disk Access on macOS) and what it runs:
# a node program fronts the tick via factory/tick.mjs (the FDA carrier); anything else
# runs the orchestrator directly.
TRIGGER_PROGRAM="${FACTORY_TRIGGER_PROGRAM:-/bin/bash}"
case "$(basename "$TRIGGER_PROGRAM")" in
  node*) TRIGGER_ARG="$ROOT/factory/tick.mjs" ;;
  *)     TRIGGER_ARG="$ROOT/factory/orchestrator.sh" ;;
esac

say() { printf '%s\n' "$*"; }

# =============================================================================
# THE REFUSAL. Read this before removing it.
# =============================================================================
# The dial is at 0 until a lap has been proven by hand. Arming a scheduler at 0 gives you
# a cron that wakes up forever and correctly does nothing - which is harmless, and is also
# how people convince themselves the factory is "running" when it has never completed a
# lap. Worse is arming it at 3 on a factory whose gate has never been tested: that is an
# unsupervised code generator nobody has ever checked.
#
# Refusing here is the code version of "the trigger is built last". It is the whole
# argument of this skill expressed as an exit status.
require_dial() {
  if [ "${FACTORY_AUTONOMY:-0}" -lt 1 ]; then
    say "REFUSING: FACTORY_AUTONOMY is ${FACTORY_AUTONOMY:-0}."
    say ""
    say "  A scheduler at level 0 wakes up and does nothing, forever. That is not a"
    say "  factory, it is a cron job with good intentions - and it looks identical to a"
    say "  working one, which is worse."
    say ""
    say "  Prove one lap by hand first:"
    say "     bash factory/orchestrator.sh --dry-run"
    say "     bash factory/run-workflow.sh implement-issue <target>"
    say ""
    say "  Then set FACTORY_AUTONOMY=1 in factory/config.sh (a human commit - the dial"
    say "  is never a factory edit) and run this again."
    exit 1
  fi
}

# =============================================================================
# THE ENVIRONMENT PROOF. --install will not arm until this passes.
# =============================================================================
# Every check runs with PATH pinned to $AGENT_PATH - the plist's PATH, not this shell's -
# so what is proven is the environment the scheduled job actually gets. HOME and the
# keychain are left as-is because launchd provides those to a user agent; PATH is the
# one thing it strips.
verify_environment() {
  local missing=0 b
  say "verifying the scheduler's environment (PATH as the launchd job will see it):"
  say "  PATH=$AGENT_PATH"
  say ""
  for b in git node python3 gh supabase claude deno curl jq security; do
    local found
    found="$(env PATH="$AGENT_PATH" sh -c "command -v $b" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      say "  OK       $b -> $found"
    else
      say "  MISSING  $b - the job would die on this, silently"
      missing=$((missing + 1))
    fi
  done

  # gh must be AUTHENTICATED, not merely installed: state.py fails closed to "stopped"
  # when it cannot read labels, so an expired token turns the factory into a quiet no-op.
  if env PATH="$AGENT_PATH" gh auth status >/dev/null 2>&1; then
    say "  OK       gh auth - authenticated"
  else
    say "  MISSING  gh auth - not authenticated; every tick would read as 'stopped'"
    missing=$((missing + 1))
  fi

  # The escalation channel's Slack half (config.sh factory_notify -> notify-vox.sh).
  # Email degrades to the local feed without it, but an unattended factory with no
  # phone-reachable channel is not the factory that was accepted.
  if [ -n "${SLACK_WEBHOOK_URL:-}" ] \
     || [ -f "$HOME/.claude/slack-webhook.env" ] \
     || security find-generic-password -s "claude-code-slack-webhook" -w >/dev/null 2>&1; then
    say "  OK       slack webhook - resolvable (env, file, or keychain)"
  else
    say "  MISSING  slack webhook - escalations would be email + local feed only"
    missing=$((missing + 1))
  fi

  # RESEND_API_KEY for the email half, read the way notify-vox.sh reads it.
  if [ -f "$ROOT/.env.local" ] && grep -q '^RESEND_API_KEY=' "$ROOT/.env.local" 2>/dev/null; then
    say "  OK       resend key - present in .env.local"
  else
    say "  MISSING  resend key - no RESEND_API_KEY in .env.local; email escalation dead"
    missing=$((missing + 1))
  fi

  # macOS TCC: a launchd job cannot read ~/Documents (or Desktop/Downloads) unless its
  # PROGRAM has been granted Full Disk Access - and the denial is exit 126 with no
  # prompt, which looks exactly like an idle factory. Found live at the Phase F arming:
  # the very first tick died on it, and even /usr/bin/python3 (the OneDrive loop's
  # interpreter) probes blocked. So the proof is run IN a launchd context, not guessed:
  # a throwaway RunAtLoad job, programmed with THE SAME BINARY the real job uses, tries
  # to read one byte of the repo. Fix when it fails: point FACTORY_TRIGGER_PROGRAM at a
  # binary that holds Full Disk Access (System Settings -> Privacy & Security).
  if [ "$PLATFORM" = "macos" ]; then
    if [ ! -x "$TRIGGER_PROGRAM" ]; then
      say "  MISSING  trigger program - $TRIGGER_PROGRAM does not exist or is not"
      say "           executable (FACTORY_TRIGGER_PROGRAM in factory/config.sh)"
      missing=$((missing + 1))
    fi
    local probe_label="com.example.dark-factory-verify-probe"
    local probe_plist="$HOME/Library/LaunchAgents/$probe_label.plist"
    local probe_out; probe_out="$(mktemp -t factory-tcc-probe)"
    rm -f "$probe_out"
    local probe_flag probe_script
    case "$(basename "$TRIGGER_PROGRAM")" in
      node*)
        probe_flag="-e"
        probe_script="require('fs').readFileSync('$ROOT/MISSION.md'); require('fs').writeFileSync('$probe_out','OK')" ;;
      *)
        probe_flag="-c"
        probe_script="head -c 1 \"$ROOT/MISSION.md\" &gt;/dev/null &amp;&amp; printf OK &gt; \"$probe_out\"" ;;
    esac
    cat > "$probe_plist" <<PROBE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$probe_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TRIGGER_PROGRAM</string>
    <string>$probe_flag</string>
    <string>$probe_script</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PROBE
    launchctl bootout "gui/$(id -u)/$probe_label" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$probe_plist" >/dev/null 2>&1 || true
    local waited=0
    while [ ! -s "$probe_out" ] && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited+1)); done
    launchctl bootout "gui/$(id -u)/$probe_label" >/dev/null 2>&1 || true
    rm -f "$probe_plist"
    if [ -s "$probe_out" ]; then
      say "  OK       launchd repo access - $(basename "$TRIGGER_PROGRAM") reads this repo as a scheduled job"
    else
      say "  MISSING  launchd repo access - macOS privacy (TCC) blocks background jobs"
      say "           from this folder. The job's program ($TRIGGER_PROGRAM)"
      say "           must hold Full Disk Access. Point FACTORY_TRIGGER_PROGRAM at a"
      say "           granted binary, or grant this one in System Settings ->"
      say "           Privacy & Security -> Full Disk Access."
      missing=$((missing + 1))
    fi
    rm -f "$probe_out"
  fi

  say ""
  if [ "$missing" -gt 0 ]; then
    say "VERIFY_FAILED: $missing problem(s). Fix them before arming - a scheduled job"
    say "  that dies on its environment looks exactly like a factory with nothing to do."
    return 1
  fi
  say "VERIFY_OK: every binary resolves under the job's PATH; gh is authenticated;"
  say "  both escalation channels are reachable; a launchd job can read the repo."
  return 0
}

# The plist, generated - never hand-edited in ~/Library. WorkingDirectory means
# orchestrator.sh's own `git rev-parse --show-toplevel` resolves; RunAtLoad means
# arming produces one immediate, observable tick in the log (proof of life - the
# dial and the stop button decide whether that tick does anything).
plist_body() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$TRIGGER_PROGRAM</string>
    <string>$TRIGGER_ARG</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$ROOT</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$AGENT_PATH</string>
  </dict>

  <key>StartInterval</key>
  <integer>$((INTERVAL_MIN * 60))</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>AbandonProcessGroup</key>
  <true/>
  <!-- Load-bearing, found live at the first armed dispatch: the tick backgrounds the
       runner and exits, and without this key launchd kills the job's whole process
       group at that exit - the lap died SIGTERM (143) seconds after DISPATCH. Cron
       never did this; launchd does, by default. -->

  <key>StandardOutPath</key>
  <string>$LOGFILE</string>
  <key>StandardErrorPath</key>
  <string>$LOGFILE</string>

  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
PLIST
}

status_macos() {
  if [ -f "$PLIST" ]; then
    say "plist:    $PLIST (present)"
  else
    say "plist:    $PLIST (absent)"
  fi
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    say "ARMED (launchd): $LABEL, every $INTERVAL_MIN minutes"
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null \
      | grep -E "state =|last exit code|runs =" | sed 's/^[[:space:]]*/    /' || true
    say "    force a tick now:  launchctl kickstart gui/$(id -u)/$LABEL"
  else
    say "NOT ARMED - launchd job $LABEL is not loaded"
  fi
  # A leftover cron entry from the template era would double-dispatch against launchd.
  if crontab -l 2>/dev/null | grep -qF "$TASK_NAME"; then
    say "WARNING: a cron entry named $TASK_NAME also exists - remove it; two schedulers"
    say "  ticking one factory race the dispatcher's lock on every overlap."
  fi
  [ -f "$FACTORY_STOP_FILE" ] && say "STOP:     $FACTORY_STOP_FILE is PRESENT - every tick exits at the stop button"
}

install_macos() {
  require_dial
  say "environment proof first (--install refuses without it):"
  say ""
  verify_environment || exit 1
  say ""
  mkdir -p "$HOME/Library/LaunchAgents"
  plist_body > "$PLIST"
  if command -v plutil >/dev/null 2>&1 && ! plutil -lint -s "$PLIST" >/dev/null 2>&1; then
    rm -f "$PLIST"
    say "REFUSING: the generated plist failed plutil -lint; nothing was armed."
    exit 1
  fi
  # bootout first so re-install is idempotent; a job that is not loaded exits non-zero
  # and that is fine.
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  say "ARMED (launchd): $LABEL, every $INTERVAL_MIN minutes (one tick fires immediately)"
  say ""
  say "Log:   $LOGFILE"
  say "Tick:  launchctl kickstart gui/$(id -u)/$LABEL   (force one now)"
  say "Stop:  touch $FACTORY_STOP_FILE   (checked before anything else, every tick)"
  say "       or label any open issue factory:stop (works from a phone, fails closed)"
  say ""
  say "NOTE: a LaunchAgent runs only while this user is logged in. A factory that"
  say "  stopped because the session ended looks exactly like one with nothing to do -"
  say "  check --status first, always."
}

remove_macos() {
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  say "DISARMED: launchd job $LABEL removed ($PLIST deleted)"
}

status_linux() {
  if crontab -l 2>/dev/null | grep -qF "$TASK_NAME"; then
    say "ARMED (cron):"
    crontab -l 2>/dev/null | grep -F "$TASK_NAME" | sed 's/^/    /'
  else
    say "NOT ARMED - no cron entry named $TASK_NAME"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl list-timers 2>/dev/null | grep -q "$TASK_NAME"; then
    say "ARMED (systemd timer): $TASK_NAME.timer"
  fi
}

status_windows() {
  if schtasks //Query //TN "$TASK_NAME" >/dev/null 2>&1; then
    say "ARMED (Task Scheduler): $TASK_NAME"
    schtasks //Query //TN "$TASK_NAME" //FO LIST 2>/dev/null | grep -iE "Status|Next Run|Schedule" | sed 's/^/    /'
  else
    say "NOT ARMED - no scheduled task named $TASK_NAME"
  fi
}

install_linux() {
  require_dial
  if crontab -l 2>/dev/null | grep -qF "$TASK_NAME"; then
    say "already armed; removing the old entry first"
    remove_linux
  fi
  { crontab -l 2>/dev/null || true; printf '%s\n' "$CRON_LINE"; } | crontab -
  say "ARMED: every $INTERVAL_MIN minutes"
  say "  $CRON_LINE"
  say ""
  say "Log:  $LOGFILE"
  say "Stop: touch $FACTORY_STOP_FILE   (checked before anything else, every tick)"
}

remove_linux() {
  crontab -l 2>/dev/null | grep -vF "$TASK_NAME" | crontab - || true
  say "DISARMED: cron entry $TASK_NAME removed"
}

install_windows() {
  require_dial
  # A LAUNCHER FILE, not an inline command, and this is not tidiness.
  #
  # `schtasks /TR` is capped at 261 characters. An inline `bash -lc "cd <root> && ..."`
  # blows that on any repo more than a couple of directories deep, and schtasks reports
  # it as a flat ERROR with no task created - so the factory is simply never scheduled
  # while everything upstream says it succeeded. Same 260-ish Windows ceiling that has
  # already broken `git worktree add` in a real factory; it turns up in a different
  # costume every time.
  #
  # Writing a launcher keeps /TR down to one path, and has the side benefit that you can
  # run the launcher by hand to see exactly what the scheduler will do.
  local LAUNCHER="$ROOT/factory/tick.cmd"
  local BASH_EXE; BASH_EXE="$(cygpath -w "$(command -v bash)" 2>/dev/null || command -v bash)"
  local WROOT;    WROOT="$(cygpath -w "$ROOT" 2>/dev/null || echo "$ROOT")"
  local WLOG;     WLOG="$(cygpath -w "$LOGFILE" 2>/dev/null || echo "$LOGFILE")"
  {
    printf '@echo off\r\n'
    printf 'REM Generated by factory/install-trigger.sh. One tick of the dispatcher.\r\n'
    printf 'REM Run this by hand to see exactly what the scheduler runs.\r\n'
    printf '"%s" -lc "cd \x27%s\x27 && bash factory/orchestrator.sh" >> "%s" 2>&1\r\n' \
      "$BASH_EXE" "$ROOT" "$WLOG"
  } > "$LAUNCHER"

  local WLAUNCH; WLAUNCH="$(cygpath -w "$LAUNCHER" 2>/dev/null || echo "$LAUNCHER")"
  if [ "${#WLAUNCH}" -gt 250 ]; then
    say "REFUSING: the launcher path is ${#WLAUNCH} characters and schtasks caps /TR at 261."
    say "  Move the repo somewhere shallower, or schedule it by hand. Failing here is"
    say "  better than a task that silently never gets created."
    exit 1
  fi

  schtasks //Create //TN "$TASK_NAME" //SC MINUTE //MO "$INTERVAL_MIN" //F \
    //TR "$WLAUNCH" >/dev/null
  say "ARMED: Task Scheduler task '$TASK_NAME', every $INTERVAL_MIN minutes"
  say ""
  say "Log:  $LOGFILE"
  say "Stop: touch $FACTORY_STOP_FILE   (checked before anything else, every tick)"
  say ""
  say "NOTE: a task registered this way runs only while you are logged in unless you"
  say "  reconfigure it to run whether or not the user is logged on. A factory that"
  say "  stops overnight because the session ended looks exactly like one with nothing"
  say "  to do."
}

remove_windows() {
  schtasks //Delete //TN "$TASK_NAME" //F >/dev/null 2>&1 || true
  say "DISARMED: scheduled task $TASK_NAME removed"
}

case "$ACTION" in
  --status)
    say "repo:     $ROOT"
    say "dial:     FACTORY_AUTONOMY=${FACTORY_AUTONOMY:-0}"
    say "interval: every $INTERVAL_MIN minutes"
    say "platform: $PLATFORM"
    say ""
    case "$PLATFORM" in
      macos)   status_macos ;;
      linux)   status_linux ;;
      windows) status_windows ;;
      *)       say "unknown platform - install a timer by hand, see references/setup.md" ;;
    esac
    ;;
  --verify)
    verify_environment
    ;;
  --print-plist)
    if [ "$PLATFORM" != "macos" ]; then
      say "--print-plist is macOS-only (this platform schedules via $PLATFORM)"
      exit 2
    fi
    plist_body
    ;;
  --install)
    case "$PLATFORM" in
      macos)   install_macos ;;
      linux)   install_linux ;;
      windows) install_windows ;;
      *) say "unknown platform. On linux the line to schedule is:"; say "  $CRON_LINE"; exit 1 ;;
    esac
    ;;
  --remove)
    case "$PLATFORM" in
      macos)   remove_macos ;;
      linux)   remove_linux ;;
      windows) remove_windows ;;
      *) say "unknown platform - remove the timer by hand" ;;
    esac
    ;;
  *)
    say "usage: bash factory/install-trigger.sh [--status|--verify|--print-plist|--install|--remove]"
    exit 2 ;;
esac
