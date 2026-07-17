---
name: password-rotation
description: Manages a pre-enrolled queue of future credentials and advances through it autonomously on trigger. Notifies the credential holder of the new active index via a configured channel. Agnostic to credential source, vault format, and target platform.
scope: any agent that holds a credential that may be leaked, expired, or scheduled for rotation
trigger: when a credential leak is detected, an expiry threshold is crossed, or a rotation is manually requested
---

# password-rotation

Maintains a numbered queue of future credentials, pre-enrolled at setup time with human participation.
When a rotation trigger fires, the agent advances the queue index, activates the next credential,
and notifies the human of the new index. The human maps index → credential via a physical cheat sheet
prepared during setup — no secret material travels over the notification channel.

## Concepts

**Queue entry** — one future credential slot, stored encrypted in the vault:
```json
{"index": 2, "level": "pattern-only", "card_id": "P2E.299", "pattern_vault": "rotation-queue/2.age", "enrolled_at": "2026-07-17T00:00:00Z"}
```

**Level** — what changes relative to the previous entry:
- `pattern-only` — same physical card, new pattern; cheaper to enroll, sufficient for most leaks
- `card-and-pattern` — new physical card and new pattern; required when card content is compromised

**Rotation index** — pointer to the currently active queue entry, stored in `rotation-state.age`.
The human's physical cheat sheet maps each index to a hint they can use to manually log in
if the agent queue is exhausted or unavailable.

**Notification channel** — how the agent tells the human which index is now active.
Configured per instance; built-in options: `github-issue`, `file-drop`, or both.
The notification contains only: index, level, reason, timestamp — no credential material.

## Scripts

```bash
# Setup (run with human present, once per rotation slot)
bash scripts/enroll-rotation.sh      # enroll one future queue entry interactively

# Status
bash scripts/rotation-status.sh      # show current index, level, remaining slots

# Rotation (autonomous — no human needed at rotation time)
bash scripts/rotate.sh               # advance to next queue entry, notify human
bash scripts/rotate.sh --dry-run     # preview what would change without doing it

# Notification
bash scripts/notify-rotation.sh      # re-send notification for current index (if human missed it)
```

## Vault layout

```
$VAULT_DIR/
  rotation-state.age          # {"current_index": N, "account": "...", "updated_at": "..."}
  rotation-queue/
    0.age                     # initial credential (enrolled at setup)
    1.age                     # first rotation slot
    2.age                     # second rotation slot
    ...
```

Each queue entry vault decrypts to JSON with `card_id`, `pattern_vault` (filename), `level`, `enrolled_at`.
The pattern itself is stored in a separate vault file referenced by `pattern_vault` — same convention
as `SKILL-OF/card-key-derivation`.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `AGE_KEY` | `~/.aurora-agent/keys/totp-key.txt` | Age private key |
| `VAULT_DIR` | `~/.aurora-agent/secrets` | Vault root |
| `ROTATION_NOTIFY` | `file-drop` | Notification channel (`github-issue`, `file-drop`, `both`) |
| `ROTATION_NOTIFY_REPO` | — | GitHub repo for issue notifications (e.g. `aurora-thesean/rotation-log`) |
| `ROTATION_NOTIFY_FILE` | `~/.aurora-agent/.rotation-notification` | File drop path |

## Human setup protocol

At enrollment time, for each rotation slot:

1. Agent runs `enroll-rotation.sh` — prompts for card ID, pattern, and level
2. Human physically marks their cheat sheet: `[N] level — hint`
3. Repeat for all N slots
4. Human stores cheat sheet with their physical cards

The cheat sheet hint is human-chosen and never enters the vault or any digital system.
Only the index number is communicated at rotation time — the human looks up index N on their sheet.

## Notification format

```
ROTATION ACTIVATED
Index:   3
Level:   pattern-only
Reason:  LLM context leak detected
Account: aurora-thesean
Time:    2026-07-17T01:23:45Z
Remaining slots: 2

Look up index 3 on your physical cheat sheet to recover manual login access.
```

## Coupling

- Reads vault entries in `SKILL-OF/card-key-derivation` format (age-encrypted JSON)
- Writes new pattern vault using `card-key-derivation` enrollment conventions
- Does not call `github-headless-login` directly — rotation activates the vault;
  the caller is responsible for triggering re-auth afterward
