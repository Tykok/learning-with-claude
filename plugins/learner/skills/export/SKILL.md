---
description: Push the learning recap into a Notion database. Use for "learner export", "exporter vers Notion", "export my learning record to Notion".
allowed-tools: Read, Grep, Bash, mcp__claude_ai_Notion, mcp__notionApi, mcp__notion
---

# Export mode

`learner export [notion-page-url]` — push the recap into a Notion database, one row per
competency theme. Read-only over the learning record: this mode never quizzes, never edits
config, and never rewrites `memory.md` or `recap.md`.

Mirror the dev's language in everything you print, as everywhere else in this skill. The
schema below is fixed English on purpose — it is the key the upsert matches on, and it
cannot depend on the language one dev happens to work in.

Read `references/export.md` and follow it. It holds the Notion database schema, the
mapping from the recap to its rows, the idempotency rules and the failure cases.
