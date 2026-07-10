# Trellis — operating contract

> This file is the **single source of truth** for any AI agent operating Trellis
> (Claude Code, Codex, etc.). `CLAUDE.md` just imports this file. Read this fully
> before doing anything.

Trellis is **one Obsidian vault that is the shared brain for many software
projects**, plus an **autonomous loop** that drains a backlog across those
projects. The vault is plain markdown + git. The loop is plain bash. Nothing here
depends on a specific AI vendor, a database, or the cloud.

There are two ways Trellis is used:

1. **Dispatch mode (interactive).** A human opens an agent here and says what they
   want ("booking widget is broken on mobile"). You read the wiki, route to the
   right project, do the work *in that project's folder*, then write back what you
   learned. See **Operations → Dispatch**.
2. **Plan mode (interactive).** `loop/plan.sh` clarifies a task *with the human* —
   it asks questions, then writes `specs/<id>.md`. Run before the loop so it builds in
   sync with intent. (`REQUIRE_SPEC=1` makes the loop refuse un-specced tasks.)
3. **Loop mode (autonomous).** `loop/loop.sh` (v2) works one backlog task at a time
   in a fresh context + isolated worktree: install deps → implement → verify gate →
   test-tamper check → **a separate adversarial reviewer** → fix-retry → branch+PR
   (with a full, experienced-dev PR description + diffstat). Follows `specs/<id>.md`
   when present. See `loop/README.md` and `loop/LOOP_PROMPT.md`.

---

## Layout

```
projects/<repo>.md   one page per real code project = a top-level entity.
                     Holds: path, stack, run + VERIFY command, trust tier,
                     architecture notes, gotchas, decisions, current focus.
concepts/<x>.md      cross-cutting knowledge shared by multiple projects
                     (e.g. a shared booking flow). These are the graph edges
                     that make context compound between repos.
sources/             raw docs / PRDs dropped in by the human. READ ONLY, never edit.
sources/history/     distilled past Claude Code conversations (per project), produced
                     by loop/harvest.py. LOCAL-ONLY (gitignored). Raw material to
                     ingest into project pages — see Operations → Ingest history.
index.md             catalog of every page (Dataview dashboards + static fallback).
hot.md               ~500-word warm-context cache, rewritten at the end of a session.
log.md               append-only, grep-parseable record of every operation.
backlog.md           the ONE human-written task list the loop drains.
specs/<id>.md        per-task specs written in PLAN mode (loop/plan.sh) by clarifying
                     intent with the human; the loop treats these as authoritative.
loop/                the autonomous loop (bash, agent-agnostic). See loop/README.
```

The **real project repos live elsewhere on disk** (e.g. `~/code/your-app`).
They are immutable "raw sources" from the vault's point of view — project pages
*point at* them and distill their knowledge; the vault never copies their code.

---

## The 10 rules (do not violate)

1. **Never edit `sources/`.** It is the immutable input. Treat real repos as
   read-only too, except when a task explicitly sends you in to change code.
2. **Update `index.md`** whenever you create or delete a page.
3. **Append to `log.md`** after every operation. Never edit past entries.
4. **Use `[[wikilinks]]` by page title** for all internal references — never raw
   paths in body text. (Filenames are kebab-case; titles are Title Case.)
5. **Every page has complete frontmatter** (see below).
6. **Contradiction = note, don't overwrite.** When new info conflicts with a page,
   update it AND record the contradiction citing both sources. Never silently
   delete what was there.
7. **Facts vs interpretation.** Keep project/source pages factual. Put opinions,
   strategy, and synthesis in concept pages and mark inferences as inferred.
8. **Search the wiki first** (read `index.md`, then the 3-5 relevant pages). Only
   open a real repo when the wiki can't answer.
9. **Prefer updating an existing page over creating a new one.** Avoid fragments.
10. **Keep `index.md` entries to one line.** The index is a map, not the territory.

---

## Frontmatter (required on every project & concept page)

```yaml
---
title: Example App
type: project            # project | concept | source
path: /Users/you/code/example-app   # project pages only — absolute path
trust: high              # project pages only: safe | standard | high  (see Trust tiers)
verify: "npm run test && npm run eslint"   # project pages only: the loop's gate
status: active           # active | paused | archived | needs-scan
tags: [web, api]
related: ["[[Example Concept]]"]
updated: 2026-06-28
---
```

`safe`/`standard`/`high` and `verify` are what make the loop both useful and
non-destructive. A project with `status: needs-scan` has not been fully read yet —
deepen its page before letting the loop touch it.

---

## Trust tiers (govern what the loop may do)

- **safe** — experiments, previews, throwaway. Loop may open a branch + PR freely.
- **standard** — real but low-blast-radius. Branch + PR; small, reviewed changes.
- **high** — production, money, customer/patient data, secrets. **Branch + PR only,
  never push to a default branch, never merge.** Off-limits paths (never edit):
  `**/auth/**`, `**/payment*/**`, `**/billing/**`, `.env*`, `**/*.pem`,
  `**/*secret*`, `**/migrations/**`, `**/db-backups/**`, service-account JSON keys,
  CI workflow files. If a task seems to require touching these, stop and leave it
  for a human.

The default for **every** project, regardless of tier, is **branch + PR; the human
merges.** The loop never writes to a default branch.

---

## Operations

### Dispatch (interactive routing)
1. Read `hot.md` then `index.md`. Identify which project the request is about.
2. Read that `projects/<repo>.md` for context, the repo path, and gotchas.
3. Do the work *in the repo at its `path`*. Respect its trust tier.
4. When done: **crystallize** — update the project page (new gotchas, decisions,
   current focus), append a line to `log.md`, and refresh `hot.md`.

### Ingest (a new source doc lands in `sources/`)
1. Read it fully. 2. Read `index.md` for context. 3. Summarize back to the human
and confirm before writing. 4. Update/create the relevant project & concept pages
(one source usually touches several). 5. Flag contradictions (rule 6). 6. Update
`index.md`. 7. Append to `log.md`.

### Ingest history (recover scattered context from past conversations)
The human's past Claude Code sessions are a record of decisions, gotchas, and
half-finished threads. To capture them:
1. Run `python3 loop/harvest.py` — it distills `~/.claude/projects/**/*.jsonl` into
   `sources/history/<project>.md` (secrets redacted; raw transcripts left untouched).
2. For a project, read its `sources/history/<slug>.md` and **merge the durable facts**
   into `projects/<slug>.md` — architecture, decisions + the *why*, gotchas, sensitive
   areas, and unfinished threads. Distinguish **extracted** (stated in the history)
   from **inferred** (your reading). Follow rules 6 (contradiction = note) and 9
   (update, don't fragment). Do **not** copy the whole digest in; distill.
3. Append a `## [date] ingest-history | <project>` line to `log.md`.
Folders without a project page yet are listed in `sources/history/_unmapped.md` —
add a `projects/<slug>.md` (with the right `path:`) to fold them in.

### Query / Ask (answer a question — NOT every interaction is a PR)
Read-only. Driven from the CLI by `trellis ask [project]`:
- `trellis ask <project>` — answer about one project using its page + recent
  conversation history + the actual repo (cite files). No edits, no branch, no PR.
- `trellis ask` — answer across the whole vault (index + project/concept pages);
  read a project's repo if named.
Offer to file a valuable answer as a concept page; otherwise stay read-only.

### Health & Lint (keep the vault honest)
- **Health** (deterministic, cheap, run often): `loop/health.sh` checks broken
  `[[links]]`, orphan pages, and index/disk drift. Run this *first*.
- **Lint** (semantic, costs tokens, run every ~10 ingests): look for
  contradictions, stale claims (page `updated` older than the repo's last commit),
  and missing pages. Write findings to `log.md`; fix only the safe ones.

---

## Agent-agnostic & local rules (keep it portable)

- All durable instructions live **here**, in `AGENTS.md`. `CLAUDE.md` is a one-line
  import. Don't add vendor-specific config (`.claude/` commands, hooks, MCP) into
  the *core* — keep logic in markdown (instructions) and `loop/*.sh` (orchestration).
- The loop calls agents through `loop/config.sh`. Swapping engine = one env var
  (`AGENT=claude` or `AGENT=codex`). Don't hardcode an engine anywhere else.
- Search baseline is **ripgrep**; if the `obsidian` CLI is present use it for vault
  search/frontmatter, but never depend on it. Never depend on a running app/daemon
  or any cloud service for the core loop.
