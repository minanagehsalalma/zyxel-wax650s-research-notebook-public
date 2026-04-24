# 11 - LLM-Assisted Methodology

This project is a useful example of how an LLM coding agent can help embedded research when the workflow is evidence-driven.

## What Worked

The useful pattern was:

1. Static map first.
2. Build the smallest live lab that answers one question.
3. Preserve every positive and negative result as an artifact.
4. Keep claims handler-specific.
5. Re-run narrow live tests when a claim depended on runtime state.
6. Package only the results that survived both static and dynamic checks.

The LLM helped by:

- keeping a running memory and task board
- generating repeatable curl and browser probes
- comparing guest/admin/no-cookie lanes
- turning noisy traces into narrower next questions
- hardening report language after reviewer pushback
- preserving dead ends so they were not repeated

## What Needed Discipline

The risky failure mode was overclaiming. Several branches looked exciting before evidence narrowed them:

- open redirect to XSS
- social-login `fb_user` acceptance to auth bypass
- parser mismatch to completed guest-to-root compromise
- static DOM sink to live XSS

The process stayed useful because each jump was forced through a live proof requirement.

## Reusable Pattern

For future firmware work:

- maintain a `memory` file with the latest true state
- keep a compact state JSON for agent handoff
- save every live run under named artifact directories
- separate static proof, live proof, and interpretation
- create helper scripts only after the manual path is understood
- treat failed probes as first-class artifacts

## LLM Ingestion Notes

This repo is intentionally organized for future LLM ingestion:

- numbered chapters give narrative order
- artifact summaries preserve raw observations without huge logs
- helper scripts show the reproducibility model
- boundaries are stated explicitly in each finding chapter
- excluded material is documented so future agents do not search for raw firmware here
