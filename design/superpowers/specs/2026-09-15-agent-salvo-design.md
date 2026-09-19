# Agent salvo — questions while the subagents work

Date: 2026-09-15
Status: approved design, not yet implemented

## Goal

Learner asks one question per turn, and only at the end of a turn in which Claude edited
tracked files. When Claude delegates work to background subagents, the main conversation goes
quiet: the dev sits and waits for a result they had no hand in producing. That dead time is the
best teaching window a session offers — the decision that produced the delegation is fresh, the
code the agent is about to touch is still unmodified, and nobody is waiting on the dev.

The **agent salvo** fills it. Every time Claude dispatches a subagent, the main conversation
owes the dev a short burst: two questions, then one fill-in exercise cut for them — by another
agent, at their level — which they write and Claude checks. The salvo runs only while at least
one agent is still in flight, and stops the moment the last one returns.

The measure of success is that a session with heavy delegation teaches *more* than one without,
instead of less.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | The salvo is a **third trigger of the existing `learner` skill**, beside the `🎓` quiz and the `🧑‍🏫` coach. One record, one config, one level scale, three channels. |
| 2 | **Bounded burst, not a continuous stream.** `agentSalvoQuestions` questions (default 2), then the exercise, then silence — even if the agent is still working. A loop that refills until the agent returns makes the cost of a delegation unbounded. |
| 3 | **One salvo per dispatched agent**, not per batch and not per stop. Three agents launched together earn three salvos, served one per turn as the dev answers. This is the volume the dev asked for, explicitly. |
| 4 | The salvo is **driven by the existing `Stop` hook**, not by a new blocking hook on `Task`. A `PreToolUse` block would stop the agent from ever starting, which is the opposite of the intent. `Stop` is also where the "one block per turn" discipline already lives. |
| 5 | **In-flight is counted from `Task` tool events**, `PreToolUse` in and `PostToolUse` out, both in the main session. A `SubagentStop` hook reports the subagent's own session, which cannot be matched back to the parent's scratch files. |
| 6 | **No agent in flight, no salvo.** The queue is bounded by the in-flight count, not by a timer: when the last agent returns, the unserved salvos are dropped rather than trailing into work that has resumed. |
| 7 | The exercise is the **existing `fill` style** — real holes in the dev's real code — cut by a **dedicated preparation agent** launched at the start of the salvo, so it is ready by the time the two questions are answered. The existing `// LEARNER-TODO` guardrail covers it unchanged. |
| 8 | The preparation agent is itself a `Task` and would arm a salvo of its own. It is excluded by a **description contract**: its description starts with `learner-prep:`, and the tracker skips those lines. |
| 9 | **No exercise in coach mode.** `coach-gate.sh` would deny the preparation agent's edit, and the barrier is not weakened for the learner's own convenience. In coach mode the salvo is questions only. |
| 10 | The salvo **consumes `.edits`** exactly as the quiz does. Both are questions about recent material; two channels drawing on the same batch would ask the dev about the same hunk twice. |
| 11 | Everything that silences the quiz silences the salvo: no `level`, `enabled: false`, a `disabledPaths` prefix. One `learner_active`, no second switch. |
| 12 | Trigger lines stay **English machine parameters**, like `🎓` and `🧑‍🏫`. What the dev reads is Claude's rendering, under the skill's existing "mirror the dev" rule. Still no language setting. |

## Known limitation, accepted

The salvo fires when the turn ends. If the host runs subagents **synchronously** — the turn does
not end until the agent returns — the salvo lands just *after* the result instead of during the
wait. The questions are still asked and nothing breaks; only the "during" is lost.

No hook fires when a subagent *starts running*, so there is no mechanism that does better from
inside a hook. This is stated here so it is not rediscovered as a bug during implementation.

## 1. The tracker — `hooks/learner-agent-track.sh`

One new POSIX `sh` script, wired twice, distinguished by a flag. It sources
`learner-config.sh`, and exits 0 on every path — it must never fail a `Task` call.

It exits immediately when `jq` is missing, when there is no session id, when `learner_active`
is false, or when `agentSalvo` is false. A dev who turned the salvo off observes no writes and
no measurable cost.

### 1.1 `--start` (PreToolUse, matcher `Task`)

Reads the hook payload on stdin. Emits nothing and decides nothing: the agent must launch
exactly as it would have.

1. `DESC=$(jq -r '.tool_input.description // ""')`. When `DESC` starts with `learner-prep:`,
   exit 0 without recording — decision 8. Match the prefix literally, after stripping leading
   whitespace only.
2. Append one line to `$TMPDIR/claude-learner-<sid>.agents`:
   `<epoch><TAB><description>`. The description is flattened to one line (newlines and tabs to
   spaces) and truncated to 200 characters, so one line always means one agent.
3. Increment `$TMPDIR/claude-learner-<sid>.agents-dispatched`.

### 1.2 `--end` (PostToolUse, matcher `Task`)

The `Task` result has come back, so one agent is no longer in flight.

1. Remove the **first** line of `.agents` (FIFO; the pairing of a specific `PostToolUse` to a
   specific `PreToolUse` is not available, and only the count matters).
2. When `.agents` is now empty or absent: delete `.agents`, `.agents-dispatched` and
   `.agents-served`. The batch is over and the next dispatch starts a fresh count.

`--end` does not check `agentSalvo`: a dev who turns the key off mid-session must still have
the counters drained rather than frozen at a stale value.

### 1.3 Counters

| File | Meaning | Reset |
|------|---------|-------|
| `.agents` | One line per agent currently in flight | Emptied by `--end`, deleted when it hits zero |
| `.agents-dispatched` | Agents dispatched in the current batch | Deleted when `.agents` empties |
| `.agents-served` | Salvos already served against that batch | Deleted when `.agents` empties |

A batch is "the run of dispatches between two moments where nothing is in flight". Its three
files are born and die together.

## 2. The Stop-hook branch — `hooks/learner-quiz.sh`

The salvo branch is inserted **between** the `LEARNER-TODO` guardrail and the quiz trigger. The
guardrail keeps absolute priority: a broken tree is fixed before anything is asked.

After the existing `learner_active` / `stop_hook_active` checks, and **before** the
`[ -s "$STATE" ] || exit 0` early exit — a salvo is owed even when this turn edited nothing,
which is the normal case for a turn that only dispatched agents:

```
INFLIGHT   = number of lines in .agents          (0 when absent)
DISPATCHED = .agents-dispatched                  (0 when absent)
SERVED     = .agents-served                      (0 when absent)

if agentSalvo and INFLIGHT > 0 and SERVED < DISPATCHED:
    SERVED++            → .agents-served
    consume .edits      (decision 10)
    block with the 🤖 trigger
    exit
# otherwise fall through to the existing quiz trigger, unchanged
```

The salvo branch sits **before** the quiz's per-session question counter (`.count`) is
incremented, and does not touch it: that counter drives the synthesis cadence of the quiz
channel, and a salvo is not a quiz question. A session heavy on delegation must not have its
synthesis questions pulled forward by salvos it never counted.

`SERVED < DISPATCHED` bounds the batch at one salvo per agent; `INFLIGHT > 0` stops the queue
the moment the last agent returns. Both conditions are needed: the first alone would keep
serving after the work resumed, the second alone would serve one salvo per turn without limit.

### 2.1 The trigger line

```
🤖 Learner salvo (level: S, questions: 2, blanks: 2, styles: auto, agent 2/3, coach: off) — task: <most recent in-flight description> — files: a.kt b.kt
```

- `level`, `styles`, `blanks` resolve exactly as the quiz trigger resolves them.
- `questions` is `agentSalvoQuestions`.
- `agent <SERVED>/<DISPATCHED>` — the salvo's rank in the batch, so the skill can vary its angle
  rather than asking three near-identical questions.
- `coach: on|off` — from `learner_coach_active`. It decides whether the exercise runs
  (decision 9), and the skill must not have to work it out for itself.
- `task:` — the description of the most recently dispatched agent still in flight (the last line
  of `.agents`), which is the delegation the dev just watched Claude make.
- `files:` — the consumed `.edits`, same `sort -u | head -n 20` treatment as the quiz. Empty is
  normal and is not an error; the salvo has three other sources of material.

When `agentSalvoQuestions` is `0` and the exercise is off (coach mode, or `agentSalvoFill:
false`), the salvo has nothing to ask: **do not block**. Fall through to the quiz instead.

## 3. The protocol — `skills/learner/references/agent-salvo.md`

New reference, read on a `🤖` trigger, as `hook-quiz.md` is read on `🎓`. The trigger carries
parameters; this file carries the protocol.

It does not restate what already exists. It **points at**: `references/data.md` for the data
files, `hook-quiz.md` § *Never hand the answer over* for the questioning rule, `hook-quiz.md`
§ *The `fill` protocol* for the exercise mechanics, and `SKILL.md`'s level table for
calibration. Duplication here is how the three channels drift apart.

### 3.1 Order of operations

1. **Launch the preparation agent first** (§4), unless `coach: on` or `agentSalvoFill` is
   false. It works while the dev answers, which is the whole reason the exercise is last.
2. **Read `memory.md`.** Open weak spots pull question selection, same spaced repetition as the
   quiz and the coach.
3. **Ask `questions` questions, one at a time**, waiting for each answer and giving brief
   feedback before the next. Never two at once.
4. **Run the exercise** when the preparation agent has reported (§4.3).
5. **Record** every answer in `memory.md` and `recap.md` per `references/data.md` § *After every
   answer*, with `salvo` in the `Style` column.

### 3.2 Material, in order of preference

All four are in scope; the order is what to reach for first when several apply.

1. **The delegated task** — from `task:` on the trigger. Why this slice was split off, what its
   output has to satisfy, which failure mode it invites. This is the material the other channels
   cannot reach, and it is fresh for exactly as long as the agent runs.
2. **The branch diff** — `git diff` against the branch base, as `references/quiz.md` resolves it.
3. **The code the agent is about to touch** — read it *now*, before it changes: current
   invariants, what the change could break, what the callers assume.
4. **Open weak spots** — a `To improve` entry from `memory.md`, even unrelated to the task.

At `agent 2/3` and `3/3`, prefer a source the earlier salvos of the same batch did not use.

### 3.3 Interaction with the other channels

A coach challenge in progress wins: finish it, record the answer, then the salvo. This mirrors
`references/coach.md` § *A quiz block landing mid-challenge* and is stated there as well, so
neither file has to be read to understand the other.

## 4. The preparation agent

### 4.1 Dispatch

Launched by the main conversation at step 1 of §3.1, with a description that **starts with
`learner-prep:`** — the anti-recursion contract of decision 8. Getting this wrong arms a salvo
for the preparation agent itself, which arms another one, and so on; the contract is stated in
`agent-salvo.md`, in `learner-agent-track.sh`'s header comment, and in the test suite.

Its prompt carries: the level letter, `blanks`, the candidate files, and the descriptions of
the agents currently in flight.

### 4.2 Its mission

Pick **one** short function among the candidates and cut `blanks` holes in it as
`// LEARNER-TODO: <hint>` comments, calibrated to the level, per `hook-quiz.md` § *The `fill`
protocol* steps 1–3. Report the file, the function, and nothing else.

Three constraints on the choice:

- **Outside the in-flight agents' scope.** It is handed their descriptions and must avoid a file
  they plausibly touch. Two writers on one function is a merge conflict dressed up as a lesson.
- **Committed code, preferred.** A function already in `HEAD` can be restored from git if
  anything goes wrong, which an uncommitted one cannot.
- **Never reveal the answer** — not in its report, not in a hint that names the construct. The
  main conversation must be able to paste the report to the dev without spoiling the exercise.

### 4.3 When it reports

The main conversation tells the dev the file and the function, asks them to write the missing
code **in the file**, and waits. Feedback, restoration and verification follow `hook-quiz.md`
§ *The `fill` protocol* steps 5–7 — including the rule that a turn never ends with a
`// LEARNER-TODO` surviving.

### 4.4 When it fails

It finds no suitable function, it errors, or the dev has already started answering something
else: say one line and end the salvo on the questions. A missing exercise is not worth a retry
loop, and the guardrail already covers a half-cut file.

## 5. Config

Three keys, added to `LEARNER_DEFAULTS` in `hooks/learner-config.sh` and to the table in
`SKILL.md`, validated by the same rules as their neighbours.

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `agentSalvo` | bool | `true` | Run a salvo while a subagent is in flight |
| `agentSalvoQuestions` | int ≥ 0 | `2` | Questions asked before the exercise |
| `agentSalvoFill` | bool | `true` | Cut a `fill` exercise at the end of the salvo |

`agentSalvoQuestions` accepts `0` — exercise only — which is why its floor is 0 and not 1, and
why §2.1's "nothing to ask" case exists.

`agentSalvo` defaults to **true**: the salvo costs nothing in a session that dispatches no
agent, and a learner plugin whose best teaching window is opt-in will stay off.

## 6. Cleanup

`hooks/learner-cleanup.sh` removes the three new files with the rest:
`.agents`, `.agents-dispatched`, `.agents-served`.

## 7. Wiring and packaging

Both hook files change together — one without the other ships a half-working feature to half the
users:

- `hooks/hooks.json` (plugin install) — a `PreToolUse` entry with matcher `Task` calling
  `learner-agent-track.sh --start`, and a `PostToolUse` entry with matcher `Task` calling it
  with `--end`. The existing `Write|Edit` entries are left alone; a separate matcher block is
  clearer than widening theirs, and `--start`/`--end` must not see `Write` events.
- `hooks/settings.snippet.json` (curl / clone / brew / apt install) — the same two entries,
  with the `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` path form that file uses.

`install.sh` copies the new script (its hook list, currently ending `coach-gate.sh
coach-watch.sh`), and `uninstall.sh` removes it from both the project and config-dir lists.

## 8. Documentation

- `README.md` — a short section after *Coach mode*, on the same footing: what the salvo is, the
  three keys, and the accepted limitation from § *Known limitation*.
- `docs/usage.html` — the salvo beside the quiz and the coach, including the `learner-prep:`
  contract as user-visible behaviour (the dev will see that agent launch).
- `docs/config.html` — the three keys in the settings table.

The site is hand-written HTML sharing one stylesheet and is checked by guards in `test.sh`; the
new rows must satisfy them.

## 9. Testing

Added to `test.sh`, offline and in seconds, driving the scripts directly with crafted stdin
payloads — no session, no agent, no network.

| # | Test |
|---|------|
| 1 | `--start` on a normal `Task` payload appends one line and increments `.agents-dispatched` |
| 2 | `--start` on a `learner-prep:` description records **nothing** — the anti-recursion contract |
| 3 | `--start` is a no-op when `agentSalvo` is false, when `enabled` is false, and under a `disabledPaths` prefix |
| 4 | `--end` removes one line; three starts and three ends leave all three files gone |
| 5 | `--end` drains the counters even when `agentSalvo` is false |
| 6 | A description containing newlines and tabs still records exactly one line |
| 7 | Stop hook with one agent in flight blocks with a `🤖` line carrying `agent 1/1`, the level, and the task description |
| 8 | Stop hook serves exactly three salvos for three dispatched agents, then falls through to the quiz |
| 9 | Stop hook with `.agents` empty serves **no** salvo, even with `.agents-dispatched` left at 3 |
| 10 | The salvo consumes `.edits`, so the next Stop with no new edits does not re-ask |
| 11 | `coach: on` appears on the trigger line when the coach regime is active |
| 12 | `agentSalvoQuestions: 0` with the exercise off falls through to the quiz rather than blocking |
| 13 | The `LEARNER-TODO` guardrail still wins over a pending salvo |
| 14 | A malformed config (`agentSalvoQuestions: "many"`) falls back to the default rather than emitting an empty count |

## 10. Out of scope

- A session-wide cap on salvos. The in-flight bound is the cap; a second one would need a third
  counter and a story about what happens when it is hit mid-batch.
- Detecting that an agent has *started* rather than been dispatched. No hook reports it.
- Pairing a specific `PostToolUse` to its `PreToolUse`. Only the count is used, so the FIFO
  removal in §1.2 is sufficient and a correlation id would be dead weight.
- Any change to `coach-gate.sh`. The gate stays as strict as it is; the salvo adapts to it.
