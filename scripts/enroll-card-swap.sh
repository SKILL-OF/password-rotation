#!/usr/bin/env bash
# enroll-card-swap.sh — enroll the current active pattern on a different card as the next rotation slot
#
# Reads the current pattern vault, strips the card prefix, re-prefixes with a new card ID,
# and enrolls it as the next queue entry. The pattern never appears in any process argument,
# log, or LLM context — it stays in shell variables within this process only.
#
# Usage:
#   bash scripts/enroll-card-swap.sh --card P2E.1
#   bash scripts/enroll-card-swap.sh --card P2E.299 --level pattern-only
#
# Use --level pattern-only when the card is the same as the current active card.
# Use --level card-and-pattern (default) when swapping to a different card.
#
# Environment: AGE_KEY, VAULT_DIR, ACTIVE_PATTERN_VAULT (see SKILL.md)

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"
ACTIVE_PATTERN_VAULT="${ACTIVE_PATTERN_VAULT:-$VAULT_DIR/gh-pattern.age}"

NEW_CARD_ID=""
LEVEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)  NEW_CARD_ID="$2"; shift 2 ;;
    --level) LEVEL="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$NEW_CARD_ID" ]] || { echo "error: --card required (e.g. P2E.1)" >&2; exit 1; }
[[ "$NEW_CARD_ID" =~ ^[A-Z0-9]+\.[0-9]+$ ]] || { echo "error: card ID must be DECK.NUM" >&2; exit 1; }
[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }
[[ -f "$ACTIVE_PATTERN_VAULT" ]] || { echo "error: active pattern vault not found: $ACTIVE_PATTERN_VAULT" >&2; exit 1; }

# Determine level by comparing new card against the PREVIOUS queue entry's card
# (not current active state, which may be stale during bulk enrollment)
if [[ -z "$LEVEL" ]]; then
  PREV_CARD=""
  # Find highest existing queue slot and read its card_id
  MAX_IDX=-1
  for f in "$QUEUE_DIR"/[0-9]*.age; do
    [[ -f "$f" ]] || continue
    n="${f##*/}"; n="${n%.age}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > MAX_IDX )) && MAX_IDX="$n"
  done
  if (( MAX_IDX >= 0 )); then
    PREV_ENTRY=$(age -d -i "$AGE_KEY" "$QUEUE_DIR/$MAX_IDX.age" 2>/dev/null) || true
    PREV_CARD=$(echo "$PREV_ENTRY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('card_id',''))" 2>/dev/null) || true
  fi
  if [[ "$PREV_CARD" == "$NEW_CARD_ID" ]]; then
    LEVEL="pattern-only"
  else
    LEVEL="card-and-pattern"
  fi
fi

mkdir -p "$QUEUE_DIR"

PUBKEY=$(age-keygen -y "$AGE_KEY" 2>/dev/null)

# Determine next index
NEXT_INDEX=0
for f in "$QUEUE_DIR"/[0-9]*.age; do
  [[ -f "$f" ]] || continue
  n="${f##*/}"; n="${n%.age}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  (( n >= NEXT_INDEX )) && NEXT_INDEX=$(( n + 1 ))
done

TARGET_VAULT="$QUEUE_DIR/$NEXT_INDEX.age"
PATTERN_VAULT_NAME="rotation-queue/pattern-$NEXT_INDEX.age"
ENROLLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Decrypt current pattern, strip old card prefix, prepend new card ID
# Pattern format: DECK.NUM/emoji/emoji/...  or  /emoji/emoji/...
CURRENT_PATTERN=$(age -d -i "$AGE_KEY" "$ACTIVE_PATTERN_VAULT" 2>/dev/null) || {
  echo "error: failed to decrypt active pattern vault" >&2; exit 1
}
DECK_CODE="${NEW_CARD_ID%.*}"
EMOJI_PART="${CURRENT_PATTERN#*/}"          # strip everything up to and including first /
NEW_PATTERN="${DECK_CODE}/${NEW_CARD_ID#*.}/${EMOJI_PART}"
# Normalize: if emoji part already starts with the new deck prefix, don't double-add
# Pattern stored as: P2E/299/🟨/🔵/... → but card-key-derivation expects P2E.299/🟨/🔵/...
# Actually store as card-key-derivation expects: DECK_CODE + "/" + emoji sequence
# Let card-key-derivation assemble-password.sh handle card number via CARD_ID env
NEW_PATTERN="${DECK_CODE}/${EMOJI_PART}"

# Encrypt new pattern as next queue slot
printf '%s' "$NEW_PATTERN" | age -r "$PUBKEY" -o "$VAULT_DIR/$PATTERN_VAULT_NAME"

# Encrypt queue entry metadata
printf '{"index":%d,"level":"%s","card_id":"%s","pattern_vault":"%s","enrolled_at":"%s"}' \
  "$NEXT_INDEX" "$LEVEL" "$NEW_CARD_ID" "$PATTERN_VAULT_NAME" "$ENROLLED_AT" \
  | age -r "$PUBKEY" -o "$TARGET_VAULT"

unset CURRENT_PATTERN NEW_PATTERN EMOJI_PART PUBKEY

echo "Enrolled rotation slot $NEXT_INDEX:"
echo "  Card:  $NEW_CARD_ID"
echo "  Level: $LEVEL"
echo "  Vault: $TARGET_VAULT"
