#!/usr/bin/env bash
# assemble-slot.sh — decrypt a specific rotation queue slot and assemble its password
#
# Outputs the assembled password to stdout (for piping into github-headless-login
# --mode change-password as the NEW password line). Does NOT advance the vault.
#
# Usage:
#   bash scripts/assemble-slot.sh [--index N]
#   bash scripts/assemble-slot.sh           # uses next pending index
#
# Environment: AGE_KEY, VAULT_DIR, CARDS_SUBDIR (same as card-key-derivation)

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"
CARDS_SUBDIR="${CARDS_SUBDIR:-cards}"

INDEX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index) INDEX="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }

# Determine index: explicit or next pending
if [[ -z "$INDEX" ]]; then
  CURRENT_INDEX=-1
  if [[ -f "$STATE_VAULT" ]]; then
    STATE=$(age -d -i "$AGE_KEY" "$STATE_VAULT" 2>/dev/null) || true
    CURRENT_INDEX=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_index',-1))" 2>/dev/null) || CURRENT_INDEX=-1
  fi
  INDEX=$(( CURRENT_INDEX + 1 ))
fi

SLOT_VAULT="$QUEUE_DIR/$INDEX.age"
[[ -f "$SLOT_VAULT" ]] || { echo "error: rotation slot $INDEX not found at $SLOT_VAULT" >&2; exit 1; }

# Decrypt the queue entry metadata to get card_id and pattern_vault path
ENTRY=$(age -d -i "$AGE_KEY" "$SLOT_VAULT" 2>/dev/null) || {
  echo "error: failed to decrypt slot $INDEX" >&2; exit 1
}
CARD_ID=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin)['card_id'])" 2>/dev/null)
PATTERN_VAULT_REL=$(echo "$ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin)['pattern_vault'])" 2>/dev/null)
PATTERN_VAULT="$VAULT_DIR/$PATTERN_VAULT_REL"

[[ -f "$PATTERN_VAULT" ]] || { echo "error: pattern vault not found: $PATTERN_VAULT" >&2; exit 1; }

# Export variables and call card-key-derivation assemble-password
export AGE_KEY
export VAULT_DIR
export CARD_ID
# Override pattern vault path (relative to VAULT_DIR) for this slot
export PATTERN_VAULT="$PATTERN_VAULT_REL"
export CARDS_SUBDIR

# Call the class skill directly (not the instance wrapper) so our CARD_ID/PATTERN_VAULT
# overrides are not clobbered by the instance's active-card-id file.
exec ~/.local/lib/skills/card-key-derivation/scripts/assemble-password.sh
