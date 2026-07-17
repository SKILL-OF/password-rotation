#!/usr/bin/env bash
# rotate-with-platform-change.sh — two-phase credential rotation
#
# Phase 1: Change the password on the platform (GitHub) using the current
#          credential and the next queued credential.
# Phase 2: Advance the rotation vault pointer (only if Phase 1 succeeded).
#
# This script is the orchestrator. It never holds credentials in env vars or
# positional arguments — everything stays in shell-local variables or pipes.
#
# Usage:
#   AGE_KEY=... VAULT_DIR=... bash rotate-with-platform-change.sh [--account ACCOUNT_DIR]
#
#   --account ACCOUNT_DIR   path to the instance account folder containing .env
#                           (default: current directory; must contain GITHUB_USERNAME)
#   --headless-login SCRIPT path to github-headless-login wrapper script
#                           (default: ~/.AWG26/.AO/GitHub/auth/scripts/github-headless-login.sh)
#   --dry-run               parse + verify vaults but do NOT submit to GitHub or advance
#
# Security invariant: credentials travel through anonymous pipes only.
#   assemble-password.sh → pipe → headless-login --mode change-password
#   assemble-slot.sh     → pipe → headless-login (new password, second line)
#
# The platform password change and vault advance are an atomic two-step:
#   If platform change fails → vault is NOT advanced (old password stays active).
#   If vault advance fails after platform change → operator must manually run rotate.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGE_KEY="${AGE_KEY:-$HOME/.aurora-agent/keys/totp-key.txt}"
VAULT_DIR="${VAULT_DIR:-$HOME/.aurora-agent/secrets}"
ACCOUNT_DIR="${ACCOUNT_DIR:-$PWD}"
HEADLESS_LOGIN="${HEADLESS_LOGIN:-$HOME/.AWG26/.AO/GitHub/auth/scripts/github-headless-login.sh}"
# ASSEMBLE_PASSWORD: the instance's current-password assembler (cannot derive via symlink traversal)
ASSEMBLE_PASSWORD="${ASSEMBLE_PASSWORD:-$HOME/.AWG26/.AO/GitHub/auth/scripts/assemble-password.sh}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account)           ACCOUNT_DIR="$2"; shift 2 ;;
    --headless-login)    HEADLESS_LOGIN="$2"; shift 2 ;;
    --assemble-password) ASSEMBLE_PASSWORD="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=true; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Resolve to absolute paths
ACCOUNT_DIR="$(cd "$ACCOUNT_DIR" && pwd)"

export AGE_KEY
export VAULT_DIR

[[ -f "$AGE_KEY" ]] || { echo "error: age key not found: $AGE_KEY" >&2; exit 1; }
[[ -f "$HEADLESS_LOGIN" ]] || { echo "error: headless-login script not found: $HEADLESS_LOGIN" >&2; exit 1; }

# Load account env for GITHUB_USERNAME
if [[ -f "$ACCOUNT_DIR/.env" ]]; then
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Expand leading ~ in values
    val="${val/#\~/$HOME}"
    case "$key" in GITHUB_USERNAME) export "$key"="$val" ;; esac
  done < "$ACCOUNT_DIR/.env"
fi
[[ -n "${GITHUB_USERNAME:-}" ]] || { echo "error: GITHUB_USERNAME not set (missing --account with .env?)" >&2; exit 1; }

echo "=== Rotation: $GITHUB_USERNAME ===" >&2

# Determine current and next rotation indices
STATE_VAULT="$VAULT_DIR/rotation-state.age"
CURRENT_INDEX=-1
if [[ -f "$STATE_VAULT" ]]; then
  STATE=$(age -d -i "$AGE_KEY" "$STATE_VAULT" 2>/dev/null) || {
    echo "error: failed to decrypt rotation-state.age" >&2; exit 1
  }
  CURRENT_INDEX=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_index',-1))" 2>/dev/null) || CURRENT_INDEX=-1
fi
NEXT_INDEX=$(( CURRENT_INDEX + 1 ))
SLOT_VAULT="$VAULT_DIR/rotation-queue/$NEXT_INDEX.age"

[[ -f "$SLOT_VAULT" ]] || {
  echo "error: no rotation slot $NEXT_INDEX queued. Enroll more slots with enroll-card-swap.sh." >&2
  exit 1
}

echo "  Current index: $CURRENT_INDEX → Next index: $NEXT_INDEX" >&2

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] Verifying vaults..." >&2
  # Verify we can decrypt current password
  bash "$ASSEMBLE_PASSWORD" > /dev/null && echo "  Current password vault: OK" >&2 || {
    echo "  error: cannot decrypt current password vault" >&2; exit 1
  }
  # Verify we can decrypt next slot
  bash "$SCRIPT_DIR/assemble-slot.sh" --index "$NEXT_INDEX" > /dev/null && echo "  Next slot vault: OK" >&2 || {
    echo "  error: cannot decrypt slot $NEXT_INDEX" >&2; exit 1
  }
  echo "[dry-run] All vaults readable. Would submit --mode change-password then advance vault." >&2
  exit 0
fi

# Phase 1: change platform password
# We pipe two lines into headless-login: current password (line 1), new password (line 2).
# Use a process substitution to assemble both without ever writing to disk.
echo "--- Phase 1: Changing platform password ---" >&2

CHANGE_OUTPUT=$(
  {
    bash "$ASSEMBLE_PASSWORD"
    bash "$SCRIPT_DIR/assemble-slot.sh" --index "$NEXT_INDEX"
  } | bash "$HEADLESS_LOGIN" --mode change-password
)

if [[ "$CHANGE_OUTPUT" != "ok" ]]; then
  echo "error: headless-login --mode change-password did not return 'ok' (got: ${CHANGE_OUTPUT:0:200})" >&2
  echo "VAULT NOT ADVANCED. Platform password may or may not have changed." >&2
  exit 2
fi

echo "  Platform password changed successfully." >&2

# Phase 2: advance vault pointer
echo "--- Phase 2: Advancing rotation vault ---" >&2
bash "$SCRIPT_DIR/rotate.sh"

echo "=== Rotation complete. Now at index $NEXT_INDEX ===" >&2
