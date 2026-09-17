---
description: Carry the learning record — memory.md, recap.md and the global learner.json — between machines through one private gist. Covers "sync push", "sync pull", "sync status", "sync use <gist>". Use for "learner sync", "synchroniser ma progression", "sauvegarder ma progression", "récupérer ma progression", "back up my learning record".
allowed-tools: Read, Write, Edit, Grep, Bash
---

# Sync mode

`learner sync <push|pull|status|use>` — carry the learning record between machines through
one private gist. The record is the raw state: `memory.md`, `recap.md` and the global
`learner.json`. This mode never quizzes and never edits settings.

Mirror the dev's language in everything you print, as everywhere else in this skill.

Every mechanical step is done by the shipped script, never by hand:

```bash
# A plugin install keeps the hooks beside the skills, under the plugin root; a personal
# install copies them into the config directory. Try the plugin layout first and fall back,
# or sync reports itself missing on a plugin install and sends the dev to update an
# install that is already current.
HOOKS="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/hooks"
[ -f "$HOOKS/learner-sync.sh" ] || HOOKS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
sh "$HOOKS/learner-sync.sh" <subcommand> [args]
```

Never call `gh` yourself, and never edit `sync.json` or `sync-base/` by hand: the script owns
the agreement between the two sides, and a file written around it makes the next merge lie.
The script prints one JSON object; you turn it into one or two sentences in the dev's language.

If the script is not there (`learner-sync.sh` missing), say so in one line — the install is
older than this skill, run `learner update` — and stop.

Read `references/sync.md` and follow it. It holds the four subcommands, the gist
layout, the three-way merge against the last agreed base, the backup taken before
every pull, and the consent rules for what leaves the machine.
