#!/usr/bin/env bash
# The internal TestFlight build road — the factory's second sanctioned exit
# (FACTORY_RULES §2 item 11, territory expansion, Rick 2026-08-18).
#
# What it does: when merged origin/develop has moved past the pointer AND the
# range touches the device-visible surface, cut ONE local build (mirroring the
# /testflight-build skill's preview lane: prebuild → xcodebuild archive → dSYMs
# → export/upload via the ASC key → test notes) and advance the pointer. Ranges
# that never touch the device surface advance the pointer without building —
# the pointer means "processed up to here", exactly like deploy.sh's.
#
# Coalescing is structural: this runs only from the tick's IDLE/HELD tails
# (never post-merge), so N merged laps since the last quiet moment produce one
# build covering all of them.
#
# Hard limits, by design:
#   - INTERNAL/PREVIEW ONLY. This road never merges to main, never touches the
#     production lane, never submits for review. External release is Rick's,
#     permanently (MISSION).
#   - Builds MERGED origin/develop only, from the main checkout. A dirty or
#     diverged checkout HOLDS (TF_HELD, retry next tick) — never builds local
#     work, never stashes anything.
#   - Non-gating: a failed build parks a notification and leaves the pointer
#     unmoved; it never blocks a lap, a merge, or a deploy.
#   - The lap's gate already ran jest/tsc/eslint on everything in the range —
#     the skill's pre-build test phase is deliberately not repeated here.
#
# Modes: (none) | --dry-run | --seed <sha>
set -u

ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
. factory/config.sh

STATE_DIR=".factory/testflight"
POINTER="$STATE_DIR/CURRENT"     # the develop sha the TF lane last processed
HISTORY="$STATE_DIR/HISTORY"     # append-only: <utc> <action> <from> <to> <detail>
LOGS="$STATE_DIR/logs"
MT_QUEUE="$STATE_DIR/MT-QUEUE.md"
BUILD_DIR="${FACTORY_TF_BUILD_DIR:-$HOME/.vox-factory/testflight}"   # iCloud shield
mkdir -p "$STATE_DIR" "$LOGS" "$BUILD_DIR"

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGS/$RUN_TS.log"
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

MODE="${1:-}"
case "$MODE" in ""|--dry-run|--seed) ;; *) echo "TF_REFUSED unknown arg: $MODE"; exit 1;; esac

# Kill switch + stop button, before anything else.
if [ "${FACTORY_TF_ENABLED:-1}" != "1" ]; then echo "TF_DISABLED FACTORY_TF_ENABLED=0"; exit 0; fi
if [ -f "$FACTORY_STOP_FILE" ] && [ "$MODE" != "--dry-run" ]; then echo "TF_STOPPED .factory/STOP"; exit 2; fi

# Single writer.
if ! mkdir "$STATE_DIR/.lock" 2>/dev/null; then echo "TF_BUSY another build owns the lock"; exit 0; fi
trap 'rmdir "$STATE_DIR/.lock" 2>/dev/null' EXIT INT TERM

if [ "$MODE" = "--seed" ]; then
  SEED_SHA="${2:-}"
  [ -f "$POINTER" ] && { echo "TF_REFUSED pointer already exists: $(cat "$POINTER")"; exit 1; }
  git rev-parse --verify --quiet "$SEED_SHA^{commit}" >/dev/null || { echo "TF_REFUSED not a commit: $SEED_SHA"; exit 1; }
  FULL="$(git rev-parse "$SEED_SHA")"
  echo "$FULL" > "$POINTER"
  echo "$(date -u +%FT%TZ) seed - $FULL -" >> "$HISTORY"
  echo "TF_SEEDED sha=$FULL"; exit 0
fi

[ -f "$POINTER" ] || { echo "TF_REFUSED no baseline. Seed: bash factory/tf-build.sh --seed <sha>"; exit 1; }
BASE_SHA="$(cat "$POINTER")"

git fetch --quiet origin "$FACTORY_BASE_BRANCH" || { log "TF_REFUSED fetch failed — never build against a stale view"; exit 1; }
TARGET_SHA="$(git rev-parse "origin/$FACTORY_BASE_BRANCH")"

[ "$BASE_SHA" = "$TARGET_SHA" ] && { echo "TF_NOOP already level at $TARGET_SHA"; exit 0; }
git merge-base --is-ancestor "$BASE_SHA" "$TARGET_SHA" || {
  log "TF_REFUSED pointer $BASE_SHA is not an ancestor of origin/$FACTORY_BASE_BRANCH"
  factory_notify "testflight" "testflight pointer $BASE_SHA is not an ancestor of origin/$FACTORY_BASE_BRANCH - re-seed after inspecting"; exit 1; }

RANGE_FILES="$(git diff --name-only "$BASE_SHA..$TARGET_SHA")"

# The device-visible surface. Tests are excluded: a test-only range changes
# nothing a device can show. ios/ and android/ are gitignored prebuild output.
TF_PATHS="${FACTORY_TF_PATHS:-src/ modules/ assets/ app.config.ts app.json babel.config.js metro.config.js}"
DEVICE_FILES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    src/test/*|*__tests__*|*.test.ts|*.test.tsx) continue ;;
  esac
  for p in $TF_PATHS; do
    case "$f" in "$p"*) DEVICE_FILES="$DEVICE_FILES$f"$'\n'; break ;; esac
  done
done <<< "$RANGE_FILES"

if [ -z "$DEVICE_FILES" ]; then
  [ "$MODE" = "--dry-run" ] && { echo "TF_DRY_RUN would advance to $TARGET_SHA (no device-visible files)"; exit 0; }
  echo "$TARGET_SHA" > "$POINTER"
  echo "$(date -u +%FT%TZ) advance $BASE_SHA $TARGET_SHA no-device-surface" >> "$HISTORY"
  echo "TF_NOOP_APP advanced=$TARGET_SHA (range touches no device-visible file)"; exit 0
fi
N_FILES="$(echo "$DEVICE_FILES" | grep -c . || true)"
log "TF_RANGE $BASE_SHA..$TARGET_SHA device_files=$N_FILES"
[ "$MODE" = "--dry-run" ] && { echo "TF_DRY_RUN would build $TARGET_SHA ($N_FILES device files)"; exit 0; }

# The build runs from the MAIN checkout (node_modules + pods live here; a bare
# worktree would re-install the world). It must be exactly merged develop.
DIRTY="$(git status --porcelain)"
[ -n "$DIRTY" ] && { log "TF_HELD checkout dirty — a session is mid-work; retry next tick"; exit 0; }
CUR_BRANCH="$(git branch --show-current)"
[ "$CUR_BRANCH" = "$FACTORY_BASE_BRANCH" ] || { log "TF_HELD checkout on '$CUR_BRANCH', not $FACTORY_BASE_BRANCH; retry next tick"; exit 0; }
git merge-base --is-ancestor HEAD "$TARGET_SHA" || { log "TF_HELD local $FACTORY_BASE_BRANCH has unpushed commits; retry next tick"; exit 0; }
git merge --ff-only "$TARGET_SHA" >>"$LOG" 2>&1 || { log "TF_HELD cannot fast-forward to $TARGET_SHA"; exit 0; }

fail_build() {
  log "TF_BUILD_FAILED $1 (log: $LOG)"
  factory_notify "testflight" "TestFlight MT build FAILED at: $1 | range $BASE_SHA..$TARGET_SHA ($N_FILES device files). Pointer unmoved - the next idle tick retries. Log: $LOG"
  exit 1
}

# --- build number: ASC highest + 1 when ours is not already past it ----------
ASC_KEY_ID="${FACTORY_TF_ASC_KEY_ID:-YOUR_ASC_KEY_ID}"
ASC_ISSUER="${FACTORY_TF_ASC_ISSUER:-YOUR_ASC_ISSUER_ID}"
ASC_KEY_PATH="${FACTORY_TF_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
ASC_APP_ID="${FACTORY_TF_ASC_APP_ID:-YOUR_ASC_APP_ID}"
[ -f "$ASC_KEY_PATH" ] || fail_build "ASC key missing at $ASC_KEY_PATH"

ASC_TOKEN="$(python3 - "$ASC_KEY_ID" "$ASC_ISSUER" "$ASC_KEY_PATH" <<'PY'
import sys, time, jwt
kid, iss, path = sys.argv[1:4]
print(jwt.encode({"iss": iss, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
                 open(path).read(), algorithm="ES256", headers={"kid": kid}))
PY
)" || fail_build "ASC token mint"
ASC_HIGHEST="$(curl -sf -H "Authorization: Bearer $ASC_TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$ASC_APP_ID&sort=-version&limit=1&fields%5Bbuilds%5D=version" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["attributes"]["version"] if d else 0)')" \
  || fail_build "ASC highest-build query"
case "$ASC_HIGHEST" in ''|*[!0-9]*) fail_build "ASC highest-build answer not numeric: '$ASC_HIGHEST'";; esac
LOCAL_NUM="$(grep -o "buildNumber: '[0-9]*'" app.config.ts | grep -o '[0-9]*')"
[ -n "$LOCAL_NUM" ] || fail_build "cannot read buildNumber from app.config.ts"
if [ "$LOCAL_NUM" -le "$ASC_HIGHEST" ]; then
  NEW_NUM=$((ASC_HIGHEST + 1))
  sed -i '' "s/buildNumber: '$LOCAL_NUM'/buildNumber: '$NEW_NUM'/" app.config.ts || fail_build "build number edit"
  git add app.config.ts
  git commit -q -m "chore: bump build number to $NEW_NUM (was $LOCAL_NUM, ASC highest $ASC_HIGHEST) [factory tf-build]" || fail_build "bump commit"
  git push -q origin "$FACTORY_BASE_BRANCH" || { git reset -q --hard "$TARGET_SHA"; fail_build "bump push (raced a merge; retry next tick)"; }
  TARGET_SHA="$(git rev-parse HEAD)"
else
  NEW_NUM="$LOCAL_NUM"
fi
log "TF_BUILD_NUMBER $NEW_NUM (ASC highest was $ASC_HIGHEST)"

# --- the build (the skill's preview lane, non-interactive) -------------------
ARCHIVE="$BUILD_DIR/VOX-$RUN_TS.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-$RUN_TS"
log "TF_PREBUILD"
npx expo prebuild --platform ios >>"$LOG" 2>&1 || fail_build "expo prebuild"
log "TF_ARCHIVE (this is the long step)"
SENTRY_ALLOW_FAILURE=true xcodebuild \
  -workspace ios/VOX.xcworkspace -scheme "${FACTORY_TF_SCHEME:-VOX}" \
  -configuration Release -sdk iphoneos \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="${FACTORY_TF_TEAM_ID:-YOUR_APPLE_TEAM_ID}" >>"$LOG" 2>&1
grep -q "ARCHIVE SUCCEEDED" "$LOG" || fail_build "xcodebuild archive"
./scripts/install-prebuilt-dsyms.sh "$ARCHIVE" >>"$LOG" 2>&1 || fail_build "dSYM install"
cat > "$BUILD_DIR/ExportOptions-$RUN_TS.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${FACTORY_TF_TEAM_ID:-YOUR_APPLE_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>upload</string>
</dict></plist>
PLIST
log "TF_EXPORT_UPLOAD"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions-$RUN_TS.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER" >>"$LOG" 2>&1
grep -q "EXPORT SUCCEEDED" "$LOG" || fail_build "export/upload"

# Test notes ride in the background (the setter waits for ASC processing) —
# never gates the pointer. Notes carry the range so MT knows what changed.
SUBJECTS="$(git log --format='%s' "$BASE_SHA..$TARGET_SHA" | grep -v '^chore: bump build number' | head -12)"
python3 scripts/testflight-set-test-notes.py \
  --build-version "$NEW_NUM" \
  --notes "FACTORY MT BUILD (develop @ ${TARGET_SHA:0:7}) — merged laps needing device MT:
$SUBJECTS" --log "$LOGS/notes-$RUN_TS.log" >>"$LOG" 2>&1 &

# MANDATORY per the skill: restore Debug pods so the next dev build works.
npx expo prebuild --platform ios >>"$LOG" 2>&1 || log "TF_WARN debug-pods restore failed — run 'npx expo prebuild --platform ios' by hand"

echo "$TARGET_SHA" > "$POINTER"
echo "$(date -u +%FT%TZ) build $BASE_SHA $TARGET_SHA build=$NEW_NUM files=$N_FILES" >> "$HISTORY"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

# --- MT bookkeeping: label the range's issues + queue rows (fail-soft) -------
{
  echo ""
  echo "## Build $NEW_NUM — $(date -u +%F) — develop @ ${TARGET_SHA:0:7}"
  echo "$SUBJECTS" | sed 's/^/- [ ] MT: /'
} >> "$MT_QUEUE"
for ISSUE in $(git log --format='%s' "$BASE_SHA..$TARGET_SHA" | grep -oE '#[0-9]+' | tr -d '#' | sort -u); do
  gh issue edit "$ISSUE" --add-label factory:needs-mt >>"$LOG" 2>&1 || log "TF_WARN could not label #$ISSUE needs-mt"
done

log "TF_BUILD_OK build=$NEW_NUM range=$BASE_SHA..$TARGET_SHA"
factory_notify "testflight" "TESTFLIGHT MT BUILD $NEW_NUM uploaded (internal track, develop @ ${TARGET_SHA:0:7}). Device-MT queue ($N_FILES device files in range): $(echo "$SUBJECTS" | tr '\n' ';') Queue file: $MT_QUEUE"
exit 0
