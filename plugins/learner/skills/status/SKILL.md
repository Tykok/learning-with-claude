---
description: Read-only summary of the dev's learning record — current level, Learner version, coach status, and the broad themes still to improve. Use for "learner status", "my level", "what should I improve", "mon niveau", "ce que je dois améliorer", "où j'en suis".
allowed-tools: Read, Grep, Bash
---

# Status mode

`learner status` — read-only: no quiz, no config write, no data-file update.

1. Level and version: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present), and
   `cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/learner/VERSION" 2>/dev/null` — unless this
   skill's own base directory (visible in your context when it loaded) contains `/plugins/`,
   in which case report the version as `plugin-managed` instead: a plugin install never
   creates that file, and Claude Code's own `/plugin` command is the source of truth for which
   version is installed.
2. Open weak spots: read the `To improve` sections of the recap (see
   `../learner/references/data.md` for paths). If nothing is recorded, say so and suggest
   `learner quiz`.
3. Print one line for the level and version, then one line for coach status — on/off, the
   current cycle if a coach session is running, and the delegated globs read from
   `$TMPDIR/claude-learner-<session-id>.coach-scope` when that file exists — then, if
   `pilotEnabled`, one line with Pilot's profile, weakest axis and live manoeuvre from
   `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/pilot.md` (not a second dashboard) — then a
   handful of bullets: broad competency themes grouped by domain, skipping anything already under
   `Mastered`. Summarise; never dump the file. No tables, no history.

Levels are in `../learner/SKILL.md` § Levels; config keys in that same file § Config.
