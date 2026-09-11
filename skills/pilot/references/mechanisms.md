# Mechanisms — the advice corpus

One entry per known mechanism behind low delegation scores. `references/brief.md` cites
**exactly one** of these per weekly brief — the one whose observable matches the axis that
is weakest this week — never more than one, and never as a lecture. Two sentences of
mechanism, one counter-move, done.

Every entry below states only what its source actually measured. Where a source gives a
number, that number is copied verbatim from the spec's §5.1 and its Sources section — never
paraphrased, never rounded differently, never invented. Where no source in this corpus
attaches a number to a mechanism, this file says so explicitly rather than dressing a
plausible-sounding figure up as evidence. A corpus that overstates its evidence is worse
than no corpus, because the developer it is quoted at can and will check the link.

## Cognitive debt

**What it does:** MIT Media Lab's *Your Brain on ChatGPT: Accumulation of Cognitive Debt*
study measured 54 subjects with EEG: LLM writers showed the weakest neural connectivity,
and recalled ~17% of their own text at 24h, against ~46% unaided. The debt is the gap
between producing text and retaining it.

**Observable:** `cl_lines` far above `dev_lines` on the `writing` axis.

**Counter-move:** write the first draft yourself, then let Claude critique it.

**Source:** [MIT Media Lab, *Your Brain on ChatGPT*](https://www.media.mit.edu/publications/your-brain-on-chatgpt/) · [brainonllm.com](https://www.brainonllm.com/) · [a documented discussion of the study's limitations](https://www.transparencycoalition.ai/news/learn-about-the-this-is-your-brain-on-chatgpt-study-results-limitations-risks-and-more)

## Order of entry

**What it does:** The same study also found that writing unaided first, then bringing in
the LLM, led to better retention than opening the LLM first. Order of entry matters as
much as whether the tool is used at all.

**Observable:** when in the session Claude was opened relative to the dev's own first pass
at the problem — not a counter this repo currently records per-prompt, so this one is read
from the transcript's shape (was there dev-authored reasoning before the first prompt to
Claude, or did the first prompt open cold on the problem).

**Counter-move:** brain-first — never open Claude on a problem you have not first tried to
state or sketch yourself, even badly.

**Source:** [MIT Media Lab, *Your Brain on ChatGPT*](https://www.media.mit.edu/publications/your-brain-on-chatgpt/) — same study as cognitive debt, above; only the order-of-entry finding itself is stated here, not the session design behind it.

## Metacognitive laziness

**What it does:** the more fluent an output reads, the less it gets challenged — and the
longer that goes on, the rustier the ability to judge that output becomes. This is a
description of a pattern across the cognitive-offloading literature, not a single study
with its own headline figure, so no percentage is attached to it here.

**Observable:** `contradiction` scoring 0 across sessions — every first draft accepted as
final, nothing named from the output that reads as a doubt.

**Counter-move:** predict the diff before reading it, so there is something concrete on
the page to compare the fluent output against, rather than judging it against a vague
sense of "looks right".

**Source:** [UCL School of Management — AI and cognitive offloading](https://www.mgmt.ucl.ac.uk/news/long-reads-1-ai-and-cognitive-offloading) · [APA Monitor — how AI is reshaping human skills and thinking](https://www.apa.org/monitor/2026/07-08/ai-job-skills-thinking)

## Generation effect

**What it does:** self-produced material is retained better than material only read —
a well-established finding in memory research generally, predating and independent of any
LLM-specific study in this corpus. No number from the sources below is attached to it, and
none should be invented for it.

**Observable:** the `writing` axis itself — `dev_lines` near zero against a large
`cl_lines`, meaning almost nothing in the session was self-produced.

**Counter-move:** write the signature or the skeleton yourself, even when Claude will fill
in the body — the generation step is what the effect is about, not the proportion of the
final file.

**Source:** general memory-research finding; no dedicated study is cited in this corpus for
the number, and this entry deliberately carries none.

## Automation bias

**What it does:** an aid that is usually right stops being monitored — correctness earns
trust, and trust quietly displaces checking. No session count or percentage from the
sources below is asserted for this one either; it is named as a mechanism, not measured
as a rate.

**Observable:** no objection anywhere across N consecutive sessions.

**Counter-move:** a quota of one argued objection per session, regardless of whether
Claude turns out to be right — the point is keeping the monitoring muscle in use, not
manufacturing disagreement.

**Source:** [UCL School of Management — AI and cognitive offloading](https://www.mgmt.ucl.ac.uk/news/long-reads-1-ai-and-cognitive-offloading) · [APA Monitor — how AI is reshaping human skills and thinking](https://www.apa.org/monitor/2026/07-08/ai-job-skills-thinking)

## Confidence without competence

**What it does:** confidence in one's own judgement rises with AI assistance while the
underlying competence does not move with it — a gap self-report cannot see from the
inside, which is exactly why Pilot never asks for a self-rating to compare against its own
index (see the spec's out-of-scope list). This mechanism is not something a manoeuvre
fixes directly; it is the shape of the whole problem Pilot measures.

**Observable:** drift between axes — most visibly a `direction` or `verification` score
that stays flat or drops while the dev's own sense of how a session went (never itself
recorded by Pilot) would very likely say otherwise.

**Counter-move:** none of its own. This is the gap Pilot's index exists to make visible;
naming it is the intervention.

**Source:** [Confidence Without Competence in AI-Assisted Knowledge Work](https://arxiv.org/pdf/2604.09444)

## Time pressure

**What it does:** less available time produces blunter, less-considered delegation — a
rushed prompt skips the constraint `direction` scores for, and a rushed review skips the
naming `verification` scores for.

**Observable:** high `burst` (several prompts in a short window) paired with low `pw_med`
(short prompts even by this dev's own baseline).

**Counter-move:** name the deadline to Claude instead of silently absorbing it into a
worse prompt — "I have twenty minutes, ship the narrow fix" is a constraint, not a
confession.

**Source:** [Effects of LLM Use on Critical Thinking Under Time Constraints](https://arxiv.org/pdf/2603.08849)
