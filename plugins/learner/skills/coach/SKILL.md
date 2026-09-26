---
description: Coach mode — the dev writes the code, Claude challenges it with one to three questions sized to the diff — one or two together, three asked one at a time — plus an optional confirmation of a good decision, library teaching, findings and leads — never a patch. Covers "coach on"/"coach off", "coach delegate <glob>", "coach review". Also the protocol to follow on a 🧑‍🏫 Coach trigger line from the change watcher. Use for "learner coach", "mode coach", "passe en mode coach", "challenge-moi", "délègue-moi".
allowed-tools: Read, Grep, Write(~/.claude/learner/**), Edit(~/.claude/learner/**), Write(~/.claude/learner.json), Edit(~/.claude/learner.json), Write(.claude/learner.local.json), Edit(.claude/learner.local.json), Bash(sh *learner-event.sh *), Bash(sh *coach-watch.sh *), Bash(git diff *), Bash(git merge-base *), Bash(git rev-parse *), Bash(git show *), Bash(git status *), Bash(mkdir -p *learner), Bash(date *), Bash(grep -n *), Bash(cat *), Bash(ls -dt *), Bash(jq -e *)
---

# Coach mode — the dev writes, you challenge

Read on a `🧑‍🏫 Coach (…)` trigger, and on `learner coach review`. Read
`../learner/references/data.md` once for the data-file rules; do not restate them here.

**Language: mirror the dev**, exactly as everywhere else in this skill. The trigger line is an
English machine parameter list — it is not what the dev reads.

Read `references/coach.md` before answering a trigger or a `coach` subcommand, and follow it.
It holds the session-id resolution, the on-trigger protocol, the per-level register, the
delegation and off-cadence-review commands, and what to do on the idle line.
