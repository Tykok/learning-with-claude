# Sync mode — protocol

## 1. `sync push`

```bash
sh "$HOOKS/learner-sync.sh" push
```

A push snapshots `memory.md`, `recap.md`, `libs.md` and the global `learner.json` — the whole
record, not just the parts a question can pick, so a defect the coach found and a library it
already covered survive a machine switch exactly like a weak spot does.

| `error` | What to say |
|---------|-------------|
| `jq-missing` / `gh-missing` | Name the missing tool and stop. |
| `gh-unauthenticated` | `gh auth login`, then re-run. |
| `empty-record` | There is nothing recorded yet — run `learner quiz` first. |
| `remote-ahead` | The other machine pushed since the last sync: run `learner sync pull` first. Do not retry the push. |
| `needs-pull` | Either this machine is pointed at a gist it has never pulled, or its `libs.md` now holds fewer rows than the base manifest's `counts.libsRows` — step 4's union below was skipped on the last pull. Run `learner sync pull` and do the union before retrying. |
| `needs-create-ok` | Ask for the gist, see below. |
| `needs-events-ok` | The gist exists but has never been allowed to carry `events.jsonl`: ask, see below. |
| `gh-create` / `gh-push` | GitHub refused. Report it; nothing was written locally. |

On `needs-create-ok`, ask the dev before anything is created, and include the warning — it is
the one thing they cannot undo once the link exists:

> A secret gist is unlisted, not private: anyone who has the URL can read it without a GitHub
> account. The snapshot carries your repo names, file names, the wording of your weak spots and
> the libraries the coach has already covered, plus `pushedFrom` (the `machine_name` you set in the plugin options, if any),
> `learner.json`'s `disabledPaths` (absolute local paths) and `events.jsonl` (the text of
> every question you were asked and each repo's absolute path). Create it?

Only on an explicit yes:

```bash
sh "$HOOKS/learner-sync.sh" push --create-ok
```

On `needs-events-ok` — a gist created before the event log existed — nothing was pushed. Ask
the dev before the log leaves the machine, with this warning:

> The gist is unlisted, not private: anyone who has the URL can read it. From now on it would
> also carry `events.jsonl` (the text of every question you were asked and each repo's absolute
> path). Upload it?

Only on an explicit yes:

```bash
sh "$HOOKS/learner-sync.sh" push --events-ok
```

The answer is recorded, so later pushes do not ask again. On a no, stop: the push does not go
without the log. A dev who empties `events.jsonl` has the gist copy deleted on the next push.

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
`recap.md` and `libs.md` are yours to write:

1. Read `recap.base`, the local `recap.local` and `recap.remote`.
2. Merge the `To improve` and `Mastered` sections, per §3.
3. Write `recap.local` as: your merged theme sections, then the `Session history` heading, its
   header row and separator, then the contents of `recap.historyMerged` **pasted verbatim**.
   Never re-sort or re-word a history row: the script already merged them, and the `Theme`
   cells are what `learner export` counts.
4. Read the local `libs.local` and `libs.remote`, then union the rows by `(Library, Angle
   covered)`: keep a pair present on either side, and when both logged the same pair, keep the
   more recent `Seen` date. There is no `libs.base`: a row is only ever added, never removed
   (per `data.md`), so unlike the theme sections there is no "dropped here or added there"
   question for a base to settle. Never drop a row silently anyway: an angle the coach already
   covered would otherwise look asked-for again, and the dev gets the same question on two
   machines. An empty `libs.remote` after a successful pull is trustworthy, not ambiguous: the
   script fails the pull outright (`gh-fetch`) if the manifest declared rows that did not arrive,
   so empty here means the remote gist genuinely has none — it predates this feature, or its
   ledger really is empty. This step is the one the next push checks: `libs.md` shorter than the
   base manifest's `counts.libsRows` makes `push` refuse with `needs-pull`, because a skipped
   union here would otherwise replace the remote's rows with nothing, `ok:true` and with no base
   copy of `libs.md` left to notice it afterwards.
5. Close the pull:

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
(`unpushed.memoryLines`, `unpushed.historyRows`) — `libs.md` has no count of its own here yet, so
if the dev asks specifically about a library row, check `libs.md` by eye rather than inventing a
figure. `remoteAhead: true` → say a pull is due before the next push. `hasBase: false` → say the
next pull will union both sides, **and** that a pull is required before the next push: `push`
itself will refuse with `needs-pull` until then, since without a base there is nothing to check a
push's safety against. `no-gist` → nothing is set up yet; `learner sync push` creates it.

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
