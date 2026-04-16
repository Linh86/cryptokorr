# Alpha feedback capture & pilot session workflow

How we turn design-partner sessions into structured product
learnings instead of loose Slack threads. Three parts:

1. [Pilot session checklist](#pilot-session-checklist) — what we do
   before, during, and after each session.
2. [Feedback capture template](#feedback-capture-template) — the
   single form partner reports get filled into.
3. [Post-session workflow](#post-session-workflow) — how a filled
   report becomes product decisions and issues.

Paired with [docs/onboarding.md](onboarding.md) (what partners
start with) and [docs/demo-scenarios.md](demo-scenarios.md) (what
they run).

## Pilot session checklist

One checklist per session. Copy it, date-stamp it, tick as you go.

### 24 hours before

- [ ] Confirm session time + participants with the partner.
- [ ] Staging deployed with the build under test. Note the commit
      sha in the feedback report.
- [ ] `mix bank.demo.reset --confirm` against staging. Verify seed
      dataset is present.
- [ ] `mix bank.smoke.transfer` + `mix bank.smoke.revoke` both PASS.
- [ ] `/v1/health/deep` returns `status: "ok"`.
- [ ] Slack channel ready; Bank team invited.
- [ ] Feedback template copied into the session's tracking document.

### 1 hour before

- [ ] Join the call early and run through the demo scenarios solo
      against the staging env so you're not debugging live.
- [ ] Open two browser windows: `/queue` and `/audit`.
- [ ] Open the adapter logs + Phoenix logs so you can reference
      timings if anyone asks.
- [ ] Have [docs/incident-runbook.md](incident-runbook.md) open in
      a tab.

### During

- [ ] Assign a note-taker (not the driver). The note-taker owns
      filling in the feedback template live — fresh quotes beat
      reconstructed ones.
- [ ] Capture **every verbal reaction**, not just direct feedback.
      "Oh, I didn't expect that" is a signal even without a follow-up.
- [ ] Screenshot anything visual that gets a reaction — positive or
      negative. Attach the screenshot to the report.
- [ ] If something breaks live, note the time and symptom. Recover
      gracefully (see the demo-scenarios fallbacks). Debug later,
      not live.

### Within 24 hours after

- [ ] Fill in the rest of the feedback template.
- [ ] Send a thank-you + next-step note to the partner (template
      below).
- [ ] File tracking issues for every distinct piece of feedback
      worth acting on. Link the feedback report in each issue.
- [ ] Post a short internal recap in `#bank-alerts` (or the team
      channel) with the one-sentence takeaway + links.

### Weekly

- [ ] Read every feedback report from the week together. Look for
      patterns across partners — the same note from two partners in
      the same week is a strong signal.
- [ ] Update the [known limitations table](onboarding.md#known-limitations-in-alpha)
      if anything shifted. Remove items that shipped; add items we
      learned are worse than we thought.

## Feedback capture template

One report per session. Keep it short. The note-taker fills it in
during + right after; the session driver reviews before filing
issues.

```markdown
# Pilot session — <partner> — <YYYY-MM-DD>

## Meta
- Partner      : <name> (<org>)
- Participants : <partner side>, <Bank side>
- Commit sha   : <sha on staging>
- Dataset      : seeded | custom | mixed
- Duration     : <actual minutes>
- Driver       : <name>
- Note-taker   : <name>

## Scenarios run
- [ ] Happy-path payment (docs/demo-scenarios.md#1)
- [ ] Approval-required (docs/demo-scenarios.md#2)
- [ ] Blocked + replay (docs/demo-scenarios.md#3)
- [ ] Emergency pause (ad-hoc)
- [ ] Other: <describe>

## What worked
- <short bullet, ideally a quote>
- <...>

## What felt wrong or surprising
- <bullet, quote if possible>
- <...>

## Direct feature asks
| Ask | Why they want it | Strength (1–5) | Maps to existing issue? |
|-----|------------------|----------------|--------------------------|
|     |                  |                |                          |

## Bugs / breakage
| When | Symptom | Workaround used | Repro? |
|------|---------|-----------------|--------|
|      |         |                 |        |

## Success / failure questions

Answer each with one sentence. These are the questions we should
have clear opinions on after every session.

- Would the partner trust this enough to route real value through
  it next week? Why / why not?
- What was the single most expensive minute in the session (product
  UX or confusion)?
- What would make them reach for Bank instead of their current
  process next time an agent action comes up?
- Is anything in the default policy bundle wrong for their flow?
- Did the audit story land? Specifically — do they believe they
  could reconstruct what happened if something went sideways?

## Verbatim quotes
- <quote — who said it — what it was reacting to>

## Follow-up items
- [ ] Thank-you note sent: <date>
- [ ] Issues filed (links):
- [ ] Internal recap posted: <link>
- [ ] Next session scheduled: <date/ask>
```

## Post-session workflow

### Filing issues from a report

Every actionable bullet becomes exactly one of:

- **Existing issue**: link the quote into the issue as additional
  context. No new issue.
- **New issue**: open it with a one-sentence title, body pasted
  from the report, and a link back to the feedback doc.
- **Explicit no-op**: if we decide not to act, record that decision
  (with reasoning) in the report itself so the next session isn't
  surprised.

Do not batch "we'll look at this later" into an untracked list.
Either track it or decide not to.

### Partner thank-you template

```
Hi <name>,

Thanks for the session today. A few things we took away:
- <takeaway 1>
- <takeaway 2>
- <takeaway 3>

Issues we filed from your feedback:
- <link> — <short summary>
- <link> — <short summary>

We'd like to run a follow-up next <timeframe>. Does <date> work?

Thanks again — this is exactly the kind of input we need to ship
something that isn't toy-shaped.

— <name>
```

### Triage cadence

- **Same week**: bugs that blocked the session or would block a
  next session.
- **Next session**: UX friction the partner called out explicitly.
- **Post-alpha**: infrastructure-level asks (multi-chain,
  multi-account — these land as milestones, not reactions).

### When feedback contradicts itself across partners

Two partners will often want opposite things. Don't average. Note
both in the feedback docs, and explicitly decide which audience we
optimise for — the decision itself is the artefact we want out of
alpha.

## Where this lives

- Per-session reports: `docs/pilots/<YYYY-MM-DD>-<partner>.md`
  (create the file as part of the post-session workflow).
- This template + checklist: the doc you are reading.
- Patterns across partners: captured as comments in the relevant
  product issues, and as bullets in our weekly internal recap.
