#!/usr/bin/env bash
# The escalation channel (FACTORY_RULES.md §11): email owner@example.invalid AND Slack.
# Called by factory_notify in config.sh — the whole message arrives on STDIN, argv[1]
# is the target (subject-line routing only).
#
# DELIBERATELY NO `set -e` AND EVERY STEP TOLERATES FAILURE. An escalation must never be
# the thing that fails: by the time this runs, the ledger write in .factory/needs-human.md
# has already happened, and the label + comment on the issue are the durable record — the
# notification is a pointer to them. A dead webhook or a missing key degrades to the
# local feed, never to an error.
#
# Channels, in order:
#   1. local feed  .factory/notifications/feed.log — always, works with the network down
#   2. email       Resend API, from factory@example.invalid to owner@example.invalid
#                  (RESEND_API_KEY read from .env.local at send time; never stored here)
#   3. Slack       incoming webhook, resolved the same way the global slack-notify hook
#                  resolves it: $SLACK_WEBHOOK_URL, then ~/.claude/slack-webhook.env,
#                  then the macOS keychain (claude-code-slack-webhook). Absent → skipped.

TARGET="${1:-factory}"
MSG="$(cat 2>/dev/null)"
[ -n "$MSG" ] || MSG="$TARGET needs a human (no reason given)"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" 2>/dev/null || true

# --- 1. the local feed, always ------------------------------------------------
mkdir -p .factory/notifications 2>/dev/null
{
  printf '%s  %s\n' "$(date -u +%FT%TZ 2>/dev/null)" "$MSG"
  echo
} >> .factory/notifications/feed.log 2>/dev/null

# --- 2. email via Resend ------------------------------------------------------
RESEND_KEY=""
if [ -f ".env.local" ]; then
  RESEND_KEY="$(grep -m1 '^RESEND_API_KEY=' .env.local 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")"
fi
if [ -n "$RESEND_KEY" ] && command -v curl >/dev/null 2>&1; then
  # Build the JSON in python3 so quotes and newlines in the reason cannot break it.
  PAYLOAD="$(MSG="$MSG" TARGET="$TARGET" python3 - <<'PY' 2>/dev/null
import json, os
print(json.dumps({
    "from": "VOX Factory <factory@example.invalid>",
    "to": ["owner@example.invalid"],
    "subject": f"[vox factory] needs a human: {os.environ.get('TARGET','factory')[:80]}",
    "text": os.environ.get("MSG", "") +
            "\n\n--\nThe issue label + comment are the record; this is the pointer."
}))
PY
)"
  if [ -n "$PAYLOAD" ]; then
    curl -s -m 15 -X POST "https://api.resend.com/emails" \
      -H "Authorization: Bearer $RESEND_KEY" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" >/dev/null 2>&1 \
      && echo "EMAIL_SENT owner@example.invalid" \
      || echo "EMAIL_FAILED (recorded in the local feed)"
  fi
else
  echo "EMAIL_SKIPPED no RESEND_API_KEY in .env.local"
fi

# --- 3. Slack -----------------------------------------------------------------
if [ -z "${SLACK_WEBHOOK_URL:-}" ] && [ -f "$HOME/.claude/slack-webhook.env" ]; then
  . "$HOME/.claude/slack-webhook.env" 2>/dev/null
fi
if [ -z "${SLACK_WEBHOOK_URL:-}" ] && command -v security >/dev/null 2>&1; then
  SLACK_WEBHOOK_URL="$(security find-generic-password -s "claude-code-slack-webhook" -w 2>/dev/null || true)"
fi
if [ -n "${SLACK_WEBHOOK_URL:-}" ] && command -v curl >/dev/null 2>&1; then
  SLACK_PAYLOAD="$(MSG="$MSG" python3 - <<'PY' 2>/dev/null
import json, os
print(json.dumps({"text": ":factory: " + os.environ.get("MSG", "")}))
PY
)"
  if [ -n "$SLACK_PAYLOAD" ]; then
    curl -s -m 8 -X POST -H 'Content-type: application/json' \
      -d "$SLACK_PAYLOAD" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 \
      && echo "SLACK_SENT" \
      || echo "SLACK_FAILED (recorded in the local feed)"
  fi
else
  echo "SLACK_SKIPPED no webhook configured (env, ~/.claude/slack-webhook.env, keychain)"
fi

exit 0
