#!/usr/bin/env bash
# notify-rotation.sh — re-send the notification for the currently active rotation index
#
# Use when the human may have missed the original notification.
# Reads current state from vault and re-fires via the configured channel.
#
# Usage: bash scripts/notify-rotation.sh [--reason TEXT]

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"
ROTATION_NOTIFY="${ROTATION_NOTIFY:-file-drop}"
ROTATION_NOTIFY_REPO="${ROTATION_NOTIFY_REPO:-}"
ROTATION_NOTIFY_FILE="${ROTATION_NOTIFY_FILE:-$HOME/.aurora-agent/.rotation-notification}"

REASON="re-notification requested"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) REASON="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }
[[ -f "$STATE_VAULT" ]] || { echo "error: rotation state not found" >&2; exit 1; }

STATE=$(age -d -i "$AGE_KEY" "$STATE_VAULT" 2>/dev/null) || {
  echo "error: failed to decrypt rotation state" >&2; exit 1
}

CURRENT_INDEX=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['current_index'])")
ACCOUNT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('account','unknown'))")
UPDATED_AT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('updated_at','unknown'))")
LAST_REASON=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_reason','unknown'))")

ENTRY_VAULT="$QUEUE_DIR/$CURRENT_INDEX.age"
LEVEL="unknown"
if [[ -f "$ENTRY_VAULT" ]]; then
  ENTRY=$(age -d -i "$AGE_KEY" "$ENTRY_VAULT" 2>/dev/null)
  LEVEL=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('level','unknown'))")
fi

REMAINING=0
for f in "$QUEUE_DIR"/[0-9]*.age; do
  [[ -f "$f" ]] || continue
  n="${f##*/}"; n="${n%.age}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  (( n > CURRENT_INDEX )) && REMAINING=$(( REMAINING + 1 ))
done

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NOTIFICATION="ROTATION NOTIFICATION (re-sent)
Index:        $CURRENT_INDEX
Level:        $LEVEL
Account:      $ACCOUNT
Activated at: $UPDATED_AT
Original reason: $LAST_REASON
Re-sent at:   $NOW
Re-sent reason: $REASON
Remaining:    $REMAINING slot(s) after current

Look up index $CURRENT_INDEX on your physical cheat sheet to recover manual login access."

if [[ "$ROTATION_NOTIFY" == "file-drop" || "$ROTATION_NOTIFY" == "both" ]]; then
  printf '%s\n' "$NOTIFICATION" > "$ROTATION_NOTIFY_FILE"
  echo "Notification written to: $ROTATION_NOTIFY_FILE"
fi

if [[ "$ROTATION_NOTIFY" == "github-issue" || "$ROTATION_NOTIFY" == "both" ]]; then
  if [[ -z "$ROTATION_NOTIFY_REPO" ]]; then
    echo "WARNING: ROTATION_NOTIFY_REPO not set — skipping GitHub issue" >&2
  else
    gh issue create \
      --repo "$ROTATION_NOTIFY_REPO" \
      --title "Rotation re-notification: index $CURRENT_INDEX ($LEVEL)" \
      --body "$NOTIFICATION" \
      --label "rotation" 2>/dev/null \
      && echo "GitHub issue created in $ROTATION_NOTIFY_REPO" \
      || echo "WARNING: failed to create GitHub issue" >&2
  fi
fi
