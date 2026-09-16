# Sync mode

`learner sync <push|pull|status|use>` — carry the learning record between machines through
one private gist. The record is the raw state: `memory.md`, `recap.md` and the global
`learner.json`. This mode never quizzes and never edits settings.

Mirror the dev's language in everything you print, as everywhere else in this skill.

Every mechanical step is done by the shipped script, never by hand:

```bash
HOOKS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
sh "$HOOKS/learner-sync.sh" <subcommand> [args]
```

Never call `gh` yourself, and never edit `sync.json` or `sync-base/` by hand: the script owns
the agreement between the two sides, and a file written around it makes the next merge lie.
The script prints one JSON object; you turn it into one or two sentences in the dev's language.

If the script is not there (`learner-sync.sh` missing), say so in one line — the install is
older than this skill, run `learner update` — and stop.

## 1. `sync push`

```bash
sh "$HOOKS/learner-sync.sh" push
```

| `error` | What to say |
|---------|-------------|
| `jq-missing` / `gh-missing` | Name the missing tool and stop. |
| `gh-unauthenticated` | `gh auth login`, then re-run. |
| `empty-record` | There is nothing recorded yet — run `learner quiz` first. |
| `remote-ahead` | The other machine pushed since the last sync: run `learner sync pull` first. Do not retry the push. |
| `needs-pull` | This machine is pointed at a gist it has never pulled — run `learner sync pull` first, then retry the push. |
| `needs-create-ok` | Ask for the gist, see below. |
| `gh-create` / `gh-push` | GitHub refused. Report it; nothing was written locally. |

On `needs-create-ok`, ask the dev before anything is created, and include the warning — it is
the one thing they cannot undo once the link exists:

> A secret gist is unlisted, not private: anyone who has the URL can read it without a GitHub
> account. The snapshot carries your repo names, file names and the wording of your weak spots,
> plus `pushedFrom` (this machine's hostname) and `learner.json`'s `disabledPaths` (absolute
> local paths). Create it?

Only on an explicit yes:

```bash
sh "$HOOKS/learner-sync.sh" push --create-ok
```

On success report the action (`created` / `updated`) and the URL.

## 2. `sync pull`

```bash
sh "$HOOKS/learner-sync.sh" pull          # or: pull <gist-url> when the dev gives one
```

Naming a gist that differs from the one already recorded repoints this machine at it and clears
`sync-base/` first, exactly like `sync use` — the old base described agreement with the old
gist, and merging against it here would read the new remote's absent lines as deletions.

| `error` | What to say |
|---------|-------------|
| `no-gist` | Nothing recorded and nothing found. Ask for the gist URL: `learner sync pull <url>`. Never guess. |
| `ambiguous-gist` | Several gists carry the marker. Ask which URL. |
| `gh-fetch` | The gist could not be read, or answered with less than its own manifest promised. Nothing was written. |
| `schema-too-new` | The snapshot comes from a newer learner — run `learner update`, then retry. |
| `no-work-dir` | `pull-finish` was given a path that is not a live pull work directory. Re-run `learner sync pull` from scratch — never invent or reuse a work-dir path. |
| *anything else* (`work-dir`, `backup-dir`, `merge`, `config-merge`, `write`, `base-dir`, `sync-json`) | These can fire **after** `memory.md` has already been rewritten in place. Say plainly that the local record may already be merged, point the dev at the most recent folder under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/backups/` (named by UTC timestamp) to compare or restore from, and do **not** run `pull-finish` — that would lock the interrupted state in as agreed.|

On success the script has already merged `memory.md` and `learner.json`, and taken a backup.
`recap.md` is yours to write, from the four paths it hands back in `recap`:

1. Read `recap.base`, the local `recap.local` and `recap.remote`.
2. Merge the `To improve` and `Mastered` sections, per §3.
3. Write `recap.local` as: your merged theme sections, then the `Session history` heading, its
   header row and separator, then the contents of `recap.historyMerged` **pasted verbatim**.
   Never re-sort or re-word a history row: the script already merged them, and the `Theme`
   cells are what `learner export` counts.
4. Close the pull:

```bash
sh "$HOOKS/learner-sync.sh" pull-finish <work>
```

`<work>` is the `work` path from the pull output. Until it runs, the two sides are not recorded
as agreeing — which is exactly right if you stopped halfway. If you could not write `recap.md`,
say so and do **not** call `pull-finish`.

Report: what came in, the backup directory, and that `learner sync push` is what sends this
machine's own additions back.

## 3. Merging the themes

`firstSync: true` in the pull output means there is no base: treat every theme on both sides as
an addition and keep them all.

Otherwise, per theme, against `recap.base`:

- Identical once case and whitespace are normalised: one entry.
- Present on one side only: added if the base does not have it (keep it), deleted if the base
  does (drop it) — the same rule the script applies to `memory.md` lines.
- Under `To improve` on one side and `Mastered` on the other: the base decides. If both sides
  moved it, keep the side whose most recent `Session history` row naming that theme is more
  recent — a mastery from three weeks ago must not erase yesterday's revision.
- **Near-duplicates** ("Gestion des erreurs" and "Error and exception handling"): keep both,
  and list them in your summary as worth merging by hand. Never rename or fold one into the
  other on your own: the `Theme` cells of every history row point at the exact text, and
  `learner export` matches its Notion pages on it. The dev can ask for the merge explicitly;
  then rewrite the `Theme` cells in the same pass.

## 4. `sync status`

```bash
sh "$HOOKS/learner-sync.sh" status
```

Read-only. Report the gist URL, `lastPush` / `lastPull`, and what is not pushed
(`unpushed.memoryLines`, `unpushed.historyRows`). `remoteAhead: true` → say a pull is due
before the next push. `hasBase: false` → say the next pull will union both sides, **and** that a
pull is required before the next push: `push` itself will refuse with `needs-pull` until then,
since without a base there is nothing to check a push's safety against. `no-gist` → nothing is
set up yet; `learner sync push` creates it.

## 5. `sync use`

```bash
sh "$HOOKS/learner-sync.sh" use <gist-url-or-id>
```

Points this machine at an existing gist and clears `sync-base/`. Use it when the dev already
has a gist from another machine. Say that the next pull will union both sides, since there is
no agreed base with this gist yet — and that `push` will refuse with `needs-pull` until that
pull has run, for the same reason.

## Files

Per-dev state, never inside a repo:

- `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/sync.json` — gist id, `lastPush`, `lastPull`.
- `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/sync-base/` — the last agreed state.
- `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/backups/<timestamp>/` — the pre-pull backup.
