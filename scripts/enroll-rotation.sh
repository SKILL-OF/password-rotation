#!/usr/bin/env bash
# enroll-rotation.sh — enroll one future credential slot into the rotation queue
#
# Run interactively with the human present. Each call adds one queue entry.
# The human simultaneously records a hint on their physical cheat sheet.
#
# Usage: bash scripts/enroll-rotation.sh [--index N] [--level pattern-only|card-and-pattern]
#
# Environment: AGE_KEY, VAULT_DIR (see SKILL.md)

set -euo pipefail

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
QUEUE_DIR="$VAULT_DIR/rotation-queue"
STATE_VAULT="$VAULT_DIR/rotation-state.age"

[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }

INDEX_OVERRIDE=""
LEVEL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index) INDEX_OVERRIDE="$2"; shift 2 ;;
    --level) LEVEL_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$QUEUE_DIR"

# Determine next index
if [[ -n "$INDEX_OVERRIDE" ]]; then
  NEXT_INDEX="$INDEX_OVERRIDE"
else
  # Find highest existing index and add 1
  NEXT_INDEX=0
  for f in "$QUEUE_DIR"/*.age; do
    [[ -f "$f" ]] || continue
    n="${f##*/}"; n="${n%.age}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n >= NEXT_INDEX )) && NEXT_INDEX=$(( n + 1 ))
  done
fi

TARGET_VAULT="$QUEUE_DIR/$NEXT_INDEX.age"
[[ -f "$TARGET_VAULT" ]] && { echo "error: slot $NEXT_INDEX already enrolled: $TARGET_VAULT" >&2; exit 1; }

# Determine level
if [[ -z "$LEVEL_OVERRIDE" ]]; then
  echo ""
  echo "Rotation level for slot $NEXT_INDEX:"
  echo "  1) pattern-only    — same physical card, new pattern"
  echo "  2) card-and-pattern — new physical card + new pattern"
  read -rp "Level [1/2]: " LEVEL_CHOICE
  case "$LEVEL_CHOICE" in
    1) LEVEL="pattern-only" ;;
    2) LEVEL="card-and-pattern" ;;
    *) echo "error: invalid choice" >&2; exit 1 ;;
  esac
else
  LEVEL="$LEVEL_OVERRIDE"
fi

# Get card ID
echo ""
read -rp "Card ID for slot $NEXT_INDEX (e.g. P2E.299): " CARD_ID
[[ "$CARD_ID" =~ ^[A-Z0-9]+\.[0-9]+$ ]] || { echo "error: card ID must be DECK.NUM (e.g. P2E.299)" >&2; exit 1; }

# Get pattern (hidden input — never echoed)
echo ""
echo "Enter the pattern for slot $NEXT_INDEX (emoji sequence, e.g. P2E.299/🟨/🔵/🟤/):"
echo "(input is hidden)"
read -rs PATTERN
echo ""
[[ -n "$PATTERN" ]] || { echo "error: pattern cannot be empty" >&2; exit 1; }

# Encrypt the queue entry
PATTERN_VAULT_NAME="rotation-queue/pattern-$NEXT_INDEX.age"
ENROLLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PUBKEY=$(age-keygen -y "$AGE_KEY" 2>/dev/null)

# Encrypt pattern separately (same convention as card-key-derivation)
printf '%s' "$PATTERN" | age -r "$PUBKEY" -o "$VAULT_DIR/$PATTERN_VAULT_NAME"

# Encrypt queue entry metadata
printf '{"index":%d,"level":"%s","card_id":"%s","pattern_vault":"%s","enrolled_at":"%s"}' \
  "$NEXT_INDEX" "$LEVEL" "$CARD_ID" "$PATTERN_VAULT_NAME" "$ENROLLED_AT" \
  | age -r "$PUBKEY" -o "$TARGET_VAULT"

# Clear sensitive variables
unset PATTERN PUBKEY

echo ""
echo "Slot $NEXT_INDEX enrolled:"
echo "  Index:  $NEXT_INDEX"
echo "  Level:  $LEVEL"
echo "  Card:   $CARD_ID"
echo "  Vault:  $TARGET_VAULT"
echo ""
echo "Now write on your physical cheat sheet:"
echo "  [$NEXT_INDEX] $LEVEL — <your hint here>"
echo ""
echo "The hint is yours alone. It never enters any digital system."
