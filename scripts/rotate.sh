#!/usr/bin/env bash
# rotate.sh — advance to the next queue entry and activate it
#
# Activates the next credential slot: updates rotation-state.age and symlinks
# the appropriate pattern/card vaults into place. Notifies the human via the
# configured channel. Does NOT trigger re-authentication — caller handles that.
#
# Usage:
#   bash scripts/rotate.sh [--reason TEXT] [--dry-run]
#
# Environment: AGE_KEY, VAULT_DIR, ROTATION_NOTIFY, ROTATION_NOTIFY_REPO,
#              ROTATION_NOTIFY_FILE (see SKILL.md)

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"
ROTATION_NOTIFY="${ROTATION_NOTIFY:-file-drop}"
ROTATION_NOTIFY_REPO="${ROTATION_NOTIFY_REPO:-}"
ROTATION_NOTIFY_FILE="${ROTATION_NOTIFY_FILE:-$HOME/.aurora-agent/.rotation-notification}"

DRY_RUN=false
REASON="unspecified"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --reason)  REASON="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }
[[ -f "$STATE_VAULT" ]] || { echo "error: rotation state not found — run enroll-rotation.sh first" >&2; exit 1; }

PUBKEY=$(age-keygen -y "$AGE_KEY" 2>/dev/null)

STATE=$(age -d -i "$AGE_KEY" "$STATE_VAULT" 2>/dev/null) || {
  echo "error: failed to decrypt rotation state" >&2; exit 1
}

CURRENT_INDEX=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['current_index'])")
ACCOUNT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('account','unknown'))")
NEXT_INDEX=$(( CURRENT_INDEX + 1 ))

NEXT_VAULT="$QUEUE_DIR/$NEXT_INDEX.age"
[[ -f "$NEXT_VAULT" ]] || {
  echo "error: no queue entry for index $NEXT_INDEX — queue exhausted" >&2
  echo "  Enroll more slots with enroll-rotation.sh" >&2
  exit 1
}

ENTRY=$(age -d -i "$AGE_KEY" "$NEXT_VAULT" 2>/dev/null) || {
  echo "error: failed to decrypt queue entry $NEXT_INDEX" >&2; exit 1
}

LEVEL=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])")
CARD_ID=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin)['card_id'])")
PATTERN_VAULT=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin)['pattern_vault'])")

# Count remaining after this rotation
REMAINING=0
for f in "$QUEUE_DIR"/[0-9]*.age; do
  [[ -f "$f" ]] || continue
  n="${f##*/}"; n="${n%.age}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  (( n > NEXT_INDEX )) && REMAINING=$(( REMAINING + 1 ))
done

echo "Rotation plan:"
echo "  $CURRENT_INDEX → $NEXT_INDEX"
echo "  Level:   $LEVEL"
echo "  Card:    $CARD_ID"
echo "  Reason:  $REASON"
echo "  Remaining after rotation: $REMAINING"

if $DRY_RUN; then
  echo ""
  echo "(dry-run — no changes made)"
  exit 0
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Activate: point the live pattern vault at the new entry's pattern
# Convention: the "active" pattern vault is VAULT_DIR/gh-pattern.age (or account-scoped name)
# We copy (not symlink) to avoid the active vault being a pointer into the queue
ACTIVE_PATTERN_VAULT="$VAULT_DIR/gh-pattern.age"
cp "$VAULT_DIR/$PATTERN_VAULT" "$ACTIVE_PATTERN_VAULT"

# Update rotation state
printf '{"current_index":%d,"account":"%s","updated_at":"%s","last_reason":"%s"}' \
  "$NEXT_INDEX" "$ACCOUNT" "$NOW" "$REASON" \
  | age -r "$PUBKEY" -o "$STATE_VAULT"

unset PUBKEY ENTRY STATE

echo "Rotation complete: index $NEXT_INDEX active"

# Notify human
NOTIFICATION="ROTATION ACTIVATED
Index:     $NEXT_INDEX
Level:     $LEVEL
Card:      $CARD_ID
Reason:    $REASON
Account:   $ACCOUNT
Time:      $NOW
Remaining: $REMAINING slot(s) after this one

Look up index $NEXT_INDEX on your physical cheat sheet to recover manual login access.
$(if (( REMAINING <= 1 )); then echo "
ACTION REQUIRED: queue is nearly exhausted. Enroll more slots soon."; fi)"

if [[ "$ROTATION_NOTIFY" == "file-drop" || "$ROTATION_NOTIFY" == "both" ]]; then
  printf '%s\n' "$NOTIFICATION" > "$ROTATION_NOTIFY_FILE"
  echo "  Notification written to: $ROTATION_NOTIFY_FILE"
fi

if [[ "$ROTATION_NOTIFY" == "github-issue" || "$ROTATION_NOTIFY" == "both" ]]; then
  if [[ -z "$ROTATION_NOTIFY_REPO" ]]; then
    echo "  WARNING: ROTATION_NOTIFY_REPO not set — skipping GitHub issue" >&2
  else
    gh issue create \
      --repo "$ROTATION_NOTIFY_REPO" \
      --title "Rotation activated: index $NEXT_INDEX ($LEVEL)" \
      --body "$NOTIFICATION" \
      --label "rotation" 2>/dev/null \
      && echo "  GitHub issue created in $ROTATION_NOTIFY_REPO" \
      || echo "  WARNING: failed to create GitHub issue" >&2
  fi
fi
