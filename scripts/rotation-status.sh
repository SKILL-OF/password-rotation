#!/usr/bin/env bash
# rotation-status.sh — show current rotation index, level, and remaining queue slots
#
# Usage: bash scripts/rotation-status.sh

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"

[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }

if [[ ! -f "$STATE_VAULT" ]]; then
  echo "No rotation state found — queue not yet initialized."
  echo "Run enroll-rotation.sh to add the first slot (index 0 = current credential)."
  exit 0
fi

STATE=$(age -d -i "$AGE_KEY" "$STATE_VAULT" 2>/dev/null) || {
  echo "error: failed to decrypt rotation state" >&2; exit 1
}

CURRENT_INDEX=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['current_index'])")
ACCOUNT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('account','unknown'))")
UPDATED_AT=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('updated_at','unknown'))")

# Count enrolled slots
TOTAL_SLOTS=0
REMAINING=0
for f in "$QUEUE_DIR"/[0-9]*.age; do
  [[ -f "$f" ]] || continue
  n="${f##*/}"; n="${n%.age}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  # skip pattern vaults (named pattern-N.age, not N.age)
  TOTAL_SLOTS=$(( TOTAL_SLOTS + 1 ))
  (( n > CURRENT_INDEX )) && REMAINING=$(( REMAINING + 1 ))
done

# Decrypt current entry for level info
CURRENT_VAULT="$QUEUE_DIR/$CURRENT_INDEX.age"
if [[ -f "$CURRENT_VAULT" ]]; then
  ENTRY=$(age -d -i "$AGE_KEY" "$CURRENT_VAULT" 2>/dev/null)
  CURRENT_LEVEL=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('level','unknown'))")
  CURRENT_CARD=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('card_id','unknown'))")
else
  CURRENT_LEVEL="unknown"
  CURRENT_CARD="unknown"
fi

echo "Rotation status"
echo "  Account:         $ACCOUNT"
echo "  Current index:   $CURRENT_INDEX"
echo "  Current level:   $CURRENT_LEVEL"
echo "  Current card:    $CURRENT_CARD"
echo "  Last rotated:    $UPDATED_AT"
echo "  Total slots:     $TOTAL_SLOTS"
echo "  Remaining slots: $REMAINING"

if (( REMAINING == 0 )); then
  echo ""
  echo "WARNING: no rotation slots remaining. Enroll more slots with enroll-rotation.sh."
elif (( REMAINING == 1 )); then
  echo ""
  echo "NOTICE: only 1 rotation slot remaining. Consider enrolling more."
fi
