#!/usr/bin/env bash
# init-rotation-state.sh — initialize rotation-state.age for a new account
#
# Creates slot 0 (the current credential) and the rotation-state pointer.
# Run once before using enroll-rotation.sh or enroll-card-swap.sh.
#
# Usage:
#   bash scripts/init-rotation-state.sh --account aurora-thesean --card P2E.299

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"
ACTIVE_PATTERN_VAULT="${ACTIVE_PATTERN_VAULT:-$VAULT_DIR/gh-pattern.age}"

ACCOUNT=""
CARD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) ACCOUNT="$2"; shift 2 ;;
    --card)    CARD_ID="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$ACCOUNT" ]] || { echo "error: --account required" >&2; exit 1; }
[[ -n "$CARD_ID" ]] || { echo "error: --card required" >&2; exit 1; }
[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }
[[ -f "$ACTIVE_PATTERN_VAULT" ]] || { echo "error: active pattern vault not found" >&2; exit 1; }

if [[ -f "$STATE_VAULT" ]]; then
  echo "error: rotation-state.age already exists — delete it first if you want to reinitialize" >&2
  exit 1
fi

mkdir -p "$QUEUE_DIR"
PUBKEY=$(age-keygen -y "$AGE_KEY" 2>/dev/null)
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Slot 0 = current credential (copy pattern vault into queue)
cp "$ACTIVE_PATTERN_VAULT" "$VAULT_DIR/rotation-queue/pattern-0.age"

printf '{"index":0,"level":"initial","card_id":"%s","pattern_vault":"rotation-queue/pattern-0.age","enrolled_at":"%s"}' \
  "$CARD_ID" "$NOW" \
  | age -r "$PUBKEY" -o "$QUEUE_DIR/0.age"

# Initialize state pointing at slot 0
printf '{"current_index":0,"account":"%s","card_id":"%s","updated_at":"%s","last_reason":"initial"}' \
  "$ACCOUNT" "$CARD_ID" "$NOW" \
  | age -r "$PUBKEY" -o "$STATE_VAULT"

# Write active card ID file
printf '%s\n' "$CARD_ID" > "$VAULT_DIR/active-card-id"

unset PUBKEY

echo "Rotation state initialized:"
echo "  Account: $ACCOUNT"
echo "  Slot 0:  $CARD_ID (current)"
echo "  State:   $STATE_VAULT"
