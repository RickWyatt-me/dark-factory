#!/usr/bin/env bash
# sync-from-source.sh — re-extract the engine from a pinned commit of a source repo.
#
# The standalone dark-factory repo is built from a PINNED git commit of the
# source repo (VOX today). When the source moves (e.g. a machinery batch lands),
# re-syncing is this one command — cheap and repeatable by design:
#
#   scripts/sync-from-source.sh <source-repo-path> <commit-sha>
#
# It extracts the engine paths byte-identical from the given commit into this
# repo and records the pin in ENGINE_PIN. It never writes to the source repo
# (git archive is read-only).
#
# Governance templates are NOT synced: they are hand-derived from the source
# governance files, which contain product content that must never be copied
# into this repo. Instead, ENGINE_PIN records a hash per source governance
# file; when a hash changes between pins, the script flags that file so a
# human re-derives the corresponding template against the source repo.
set -euo pipefail

SRC="${1:?usage: sync-from-source.sh <source-repo-path> <commit-sha>}"
SHA="${2:?usage: sync-from-source.sh <source-repo-path> <commit-sha>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Engine paths copied byte-identical (same top-level layout as the source repo,
# so an import is a plain copy of these directories).
ENGINE_PATHS=(factory harness)

# Source files the templates are derived from — hash-tracked, never copied.
TEMPLATE_SOURCES=(MISSION.md FACTORY_RULES.md FACTORY.md CLAUDE.md .factory/README.md)

FULL_SHA="$(git -C "$SRC" rev-parse "${SHA}^{commit}")"

echo "== sync-from-source: $SRC @ $FULL_SHA =="

# 1. Engine: replace wholesale so deletions in the source propagate.
for p in "${ENGINE_PATHS[@]}"; do
  rm -rf "${REPO_ROOT:?}/$p"
done
git -C "$SRC" archive "$FULL_SHA" "${ENGINE_PATHS[@]}" | tar -x -C "$REPO_ROOT"

# 1b. Scrub real-world identifiers the export boundary forbids carrying.
# The engine copy is byte-identical EXCEPT the substitutions in
# scripts/scrub.local.tsv — a git-ignored, maintainer-machine-only file, so
# the identifiers being removed never live in this repo themselves (that was
# audit finding #1: an in-repo scrub table ships everything it scrubs).
# Format documented in scripts/scrub.example.tsv. Keep the table minimal:
# account/project identifiers and personally-named credential references.
# Source-shaped *names* (notify-vox.sh, ~/.vox-factory) are documented in
# ADAPTERS.md, not rewritten.
SCRUB_FILE="$REPO_ROOT/scripts/scrub.local.tsv"
if [[ ! -f "$SCRUB_FILE" ]]; then
  echo "!! Missing $SCRUB_FILE (git-ignored, per-machine)." >&2
  echo "   Create it from scripts/scrub.example.tsv before syncing." >&2
  exit 1
fi
FORBIDDEN=""
while IFS=$'\t' read -r kind a b; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  case "$kind" in
    S)
      export SCRUB_LIT="$a" SCRUB_REP="$b"
      files="$(grep -rlF "$SCRUB_LIT" "$REPO_ROOT/factory" "$REPO_ROOT/harness" 2>/dev/null || true)"
      [[ -z "$files" ]] && continue
      while IFS= read -r f; do
        perl -pi -e 's/\Q$ENV{SCRUB_LIT}\E/$ENV{SCRUB_REP}/g' "$f"
      done <<< "$files"
      ;;
    F)
      FORBIDDEN="${FORBIDDEN:+$FORBIDDEN|}$a"
      ;;
    *)
      echo "!! Unrecognized record kind '$kind' in $SCRUB_FILE" >&2; exit 1
      ;;
  esac
done < "$SCRUB_FILE"

# 1c. Forbidden-pattern check: if upstream introduced an identifier the table
# doesn't cover, fail the sync loudly instead of shipping it.
if [[ -n "$FORBIDDEN" ]] && hits=$(grep -rEin "$FORBIDDEN" "$REPO_ROOT/factory" "$REPO_ROOT/harness"); then
  echo "!! FORBIDDEN identifiers survived the scrub — extend $SCRUB_FILE and re-run:" >&2
  echo "$hits" >&2
  exit 1
fi

# 2. Compare governance-source hashes against the previous pin.
OLD_PIN="$REPO_ROOT/ENGINE_PIN"
declare -a changed=()
for p in "${TEMPLATE_SOURCES[@]}"; do
  if git -C "$SRC" cat-file -e "$FULL_SHA:$p" 2>/dev/null; then
    new_hash="$(git -C "$SRC" rev-parse "$FULL_SHA:$p")"
    old_hash="$(grep -F "template_source $p " "$OLD_PIN" 2>/dev/null | awk '{print $3}' || true)"
    if [[ -n "$old_hash" && "$old_hash" != "$new_hash" ]]; then
      changed+=("$p")
    fi
  fi
done

# 3. Record the new pin.
{
  # Basename only — the full local path identifies the maintainer's machine.
  echo "source_repo: $(basename "$SRC")"
  echo "commit: $FULL_SHA"
  echo "synced_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for p in "${TEMPLATE_SOURCES[@]}"; do
    if git -C "$SRC" cat-file -e "$FULL_SHA:$p" 2>/dev/null; then
      echo "template_source $p $(git -C "$SRC" rev-parse "$FULL_SHA:$p")"
    fi
  done
} > "$REPO_ROOT/ENGINE_PIN"

echo
echo "== git status after sync =="
git -C "$REPO_ROOT" status --short | head -50
echo
if ((${#changed[@]})); then
  echo "!! Governance sources changed since the last pin — re-derive templates for:"
  printf '   - %s\n' "${changed[@]}"
else
  echo "Governance sources unchanged since the last pin; templates need no re-derivation."
fi
echo "Pin recorded in ENGINE_PIN. Review the diff, then commit."
