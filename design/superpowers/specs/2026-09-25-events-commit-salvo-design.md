# Events: `commit` and `dirty`, and the salvo on the log

Date: 2026-09-25
Status: approved design, not yet implemented

## Goal

Two gaps keep `events.jsonl` from giving the Learner IDE panel all it needs:

1. **No file version.** The panel's detail view can open a question's file *as it was* and diff
   it with the current file (learner-ide, `design/superpowers/specs/2026-09-24-panel-design.md`
   § 5, decision 11). It only offers that when `question.asked` carries the commit the question
   was asked at, and says the question's files matched that commit. No event carries either
   today, so the actions stay hidden.
2. **The salvo is invisible.** `references/agent-salvo.md` records answers in `memory.md` and
   `recap.md` but never emits `question.asked`, so a salvo question never shows up in an IDE and
   its answer has no id to close.

Success: a question asked in a clean git checkout carries `commit` and `dirty: false`, and a
salvo question appears in the IDE, is closed by its answer, and gets abandoned like any other
when the session ends.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | `commit` and `dirty` are computed by `learner-event.sh asked` itself. The model passes nothing new. |
| 2 | `dirty` compares blobs and never calls `git status`: the `HEAD:<file>` blob against `git hash-object --no-filters --stdin` of the working file. So no git child can run a program the repo configures (fsmonitor, clean filter, submodule recursion), and nothing writes the index. |
| 3 | Whenever there is any doubt, `dirty` is `true`. `true` only hides the panel's revision actions, so a false positive is safe. A false negative would show a wrong "as it was". |
| 4 | Any git failure leaves the question intact: `asked` still writes its event, prints its id and exits 0. |
| 5 | The schema change is additive. It stays `v: 1`, and readers already ignore unknown fields. |
| 6 | The salvo emits the same events as the hook quiz, and `agent-salvo.md` points to `data.md` instead of restating it. |
| 7 | A salvo question that touches no file emits no event, so no `files` value is ever invented. |
| 8 | No `channel` field. A salvo question looks like any other in the IDE. It can be added later without breaking an event. |

## 1. `commit` and `dirty` (producer)

`cmd_asked` already resolves `root` (`learner_repo_root`). When `root` is non-empty:

- **`commit`** is `git -C "$root" rev-parse --verify -q --end-of-options 'HEAD^{commit}'`. The
  output has to match `^[0-9a-f]{40}([0-9a-f]{24})?$`, which covers SHA-1 and SHA-256. If the
  command fails (unborn branch) or the output does not match, both `commit` and `dirty` are
  left out.
- **`dirty`** is a JSON boolean, present exactly when `commit` is. It is `true` when, for any
  file in `--files`, one of these holds:
  - the path is absolute, or has a `..` segment (it is never read outside `root`);
  - `$root/<file>` is missing, is not a regular file, or cannot be read;
  - `git rev-parse --verify -q --end-of-options "<commit>:<file>"` fails, so the file is absent
    at that commit (untracked, newly added);
  - that blob differs from `git hash-object --no-filters --stdin < "$root/<file>"`.

  Otherwise it is `false`. A change that is staged but not committed still reads as dirty,
  because the comparison is against `HEAD` and not the index. A file under a filter, LFS or
  eol conversion always reads dirty. That is the accepted cost of decision 2.
- **Every git child** runs with `GIT_NO_LAZY_FETCH=1`, `GIT_ALLOW_PROTOCOL=` (empty),
  `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`, plus `-c protocol.allow=never`. A missing
  object in a partial clone then errors, and so reads as dirty or no commit; it never triggers
  a fetch. `hash-object` runs without `-w`. The revision is looked up against the commit
  already resolved, not a second read of `HEAD`, so a commit landing between the two calls
  cannot mix states.
- Outside git (`root` empty), neither field is written.

The event gains the fields at top level:

```json
{"v":1,"type":"question.asked", …, "commit":"3f2a…","dirty":false}
```

## 2. Schema (`contract/events.schema.json`)

- `properties.commit`: `{"type": "string", "pattern": "^[0-9a-f]{40}([0-9a-f]{24})?$"}`.
- `properties.dirty`: `{"type": "boolean"}`.
- `"dependentRequired": {"dirty": ["commit"], "commit": ["dirty"]}`: the two fields always come
  together.
- The `description` of each field says that it appears only on `question.asked`, is absent
  outside git and on an unborn branch, and has the fail-closed meaning of `dirty`.

The learner-ide repo re-vendors this schema in its own PR (PR 3): it adds a fixture with both
fields and updates panel spec § 5, where `dirty` now reads "differs from `HEAD` by blob
comparison" rather than `git status --porcelain`.

## 3. The salvo on the log (`references/agent-salvo.md`)

This is a documentation change only. `learner-event.sh` is untouched.

- **§ Order of operations, step 3.** Each question, as it goes out, emits
  `learner-event.sh asked` in the same turn, per `data.md` § *`events.jsonl`*, *When the
  question goes out*:
  - `--style` is the real format of the question (`code` or `architecture`), and
    `--mode granular`.
  - `--files` holds the files the question is about. For a question on the diff or on edited
    files, those come from the trigger's `files:`. For a question on the delegated task, they
    are the files that task targets. For a question on a weak spot, they are the file(s) in
    this repo the question quotes or is grounded in — a `memory.md` entry names a concept,
    never a file.
  - With no file at all, no event is emitted (decision 7).
- **§ When it reports (the exercise).** The exercise emits
  `asked --style fill --anchor FILE:LINE` when it is handed to the dev. The line is the first
  `LEARNER-TODO`, the same rule as the hook quiz. The holes are already cut by then, so
  `dirty` is `true` and the panel opens the current file. That is expected: the version "as
  it was" would be the file with its holes.
- **§ Order of operations, step 5.** The answer closes the question with `answered` or
  `skipped`, using the id that `asked` printed, per `data.md` § *After every answer*.
- **No other change.** A question left open when the session ends is closed by the existing
  `SessionEnd` hook (`abandoned`). A queued salvo emits one event per question it actually
  asks.

## 4. Tests (`test.sh`)

Producer, each in a scratch repo:

- outside git → neither `commit` nor `dirty`;
- unborn branch → neither;
- a clean tracked file → `commit` equals `git rev-parse HEAD` and `dirty` is `false`;
- modified, staged-only, untracked, deleted, `../x` and absolute path → `dirty: true`;
- several files, one of them dirty → `true`;
- a repo whose `.git/config` sets `core.fsmonitor` and a `filter.x.clean` (with a matching
  `.gitattributes`) to a script that creates a marker file → after `asked`, the marker does
  not exist;
- a failing git (`PATH` with a `git` stub that exits 1) → the event is still written, without
  `commit`, and `asked` exits 0;
- the schema fixture (`LEARNER_SCHEMA_CHECK`) includes an `asked` event with both fields.

Salvo, as text checks on `agent-salvo.md`:

- it names `learner-event.sh asked`, `--style fill`, `--anchor` and `answered`;
- it points to `data.md` § `events.jsonl`;
- it does not restate the `HOOKS=` resolution block.

## Out of scope

- The coach channel, which does not emit events today.
- A `channel` field (decision 8).
- The pre-existing `test.sh` hang, where the zsh recipe test pulls every ```` ```bash ```` block
  of `coach.md` into `zsh -c`, and a stray backtick fence starts an interactive `bash` when stdin
  is a terminal. It is noted for a separate fix.
