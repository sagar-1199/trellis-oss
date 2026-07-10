# Trellis loop

Agent-agnostic, fully-local automation. Three things live here:

| File | What it does |
|---|---|
| `config.sh` | The only engine-specific file. `AGENT=claude` (default) or `AGENT=codex`. Also: `DRY_RUN`, `MAX_ITERATIONS`, `REQUIRE_SPEC`, denylist, permission flags. |
| `plan.sh` | **PLAN mode** — interactive. Asks you clarifying questions about a task, then writes `../specs/<id>.md` that the loop follows. Run before `loop.sh`. |
| `loop.sh` | The dispatcher (BUILD mode). Drains `../backlog.md`, one task per fresh agent context, in an isolated git worktree, gated by each project's `verify` command, opening a branch + PR with a full description. |
| `build_prompt.sh` | Assembles each iteration's prompt (instructions + task + project page). |
| `LOOP_PROMPT.md` | Tool-neutral iteration instructions. |
| `health.sh` | Deterministic vault checks (broken links, orphans, missing verify gates). No tokens. |
| `harvest.py` | Mines past Claude Code conversations → `../sources/history/` (secrets redacted). |

## Daily use

**Dispatch (interactive).** Just open an agent in the vault root and say what you
want — it routes via the wiki. No script needed.

**Recommended flow: PLAN (you, interactive) → BUILD (autonomous).**
```bash
# 1. add a task to ../backlog.md  (see the format at the top of that file)
# 2. CLARIFY it with the agent — it asks you questions, then writes specs/<id>.md:
./plan.sh                 # top task   (or: ./plan.sh <keyword>)
# 3. preview, then run — the loop follows the spec and opens a PR with a full description:
./loop.sh                 # DRY-RUN preview, no changes
DRY_RUN=0 ./loop.sh
```
Enforce planning for every task with `REQUIRE_SPEC=1` (the loop holds any task that
has no `specs/<id>.md` and tells you to run `./plan.sh`).

**Autonomous loop (skip planning).**
```bash
# 1. add tasks to ../backlog.md  (see the format at the top of that file)
# 2. preview what the loop would do — safe, no changes:
./loop.sh
# 3. run it for real:
DRY_RUN=0 ./loop.sh
# variants:
DRY_RUN=0 AGENT=codex ./loop.sh         # use Codex instead of Claude
DRY_RUN=0 MAX_ITERATIONS=3 ./loop.sh    # cap to 3 tasks this run
```

**Harvest past conversations into the vault.**
```bash
python3 harvest.py            # writes ../sources/history/<project>.md
./health.sh                   # sanity-check the vault any time
```

## What each task goes through (v2)
```
fresh worktree → install deps (npm ci / pnpm --frozen-lockfile) + copy .env
  → implement (fresh agent)
  → guardrails: off-limits paths + diff size (files AND lines)
  → verify gate (build/lint/tests)            ← deterministic, runs first
  → test-tamper check (reject edits to existing tests — anti reward-hacking)
  → adversarial reviewer (fresh, defaults to FAIL, rejects scope creep)  [QA=1]
  → if gate or reviewer fails: feed findings to a fresh fixer, retry (≤ MAX_FIX_ATTEMPTS)
  → stuck (same diff twice) or out of attempts → escalate to human (mark task [!])
  → all pass → commit → push → PR (never merges)
```

## Knobs (env vars; all have safe defaults)
| Var | Default | Meaning |
|---|---|---|
| `DRY_RUN` | `1` | `1` previews, `0` runs for real |
| `AGENT` | `claude` | implementer engine (`claude`/`codex`) |
| `QA` | `1` | run the adversarial reviewer gate |
| `QA_AGENT` | `=AGENT` | reviewer engine — **set to a *different* engine** (e.g. `QA_AGENT=codex`) to avoid self-preference bias |
| `MAX_ITERATIONS` | `10` | max tasks per run |
| `MAX_FIX_ATTEMPTS` | `3` | implement→gate→review retries per task |
| `MAX_DIFF_FILES` / `MAX_DIFF_LINES` | `40` / `600` | scope guards |
| `JIT_HISTORY` | `1` | include the repo's raw conversation digest in each task's prompt (extra context on top of the curated project page) |
| `JIT_HARVEST` | `1` | refresh that history (re-run `harvest.py`) at the start of a real run |

Per-task/project you can also set a **`setup::`** command (in `backlog.md` or the
project page frontmatter `setup:`) to override the auto-detected dependency install.

## Safety model (see ../concepts/trust-tiers.md)
- `DRY_RUN=1` by default — nothing happens until `DRY_RUN=0`.
- Every change lands on a `trellis/<task>` branch + PR. **Never** writes to a default
  branch, never merges.
- Off-limits paths (auth/payments/.env/.pem/secrets/migrations/db-backups/CI) or an
  oversized diff → the whole task is discarded.
- A task is marked done only when **verify passes AND the adversarial reviewer
  approves**. Stuck/failed tasks are marked `[!]` (blocked) with an `ESCALATED-*.md`
  note, and skipped on future runs until a human looks.
- Projects with no git remote get a local branch + commit (no PR).
- `CI=true` and `HUSKY=0` are exported so headless installs/commands don't hang.

## Requirements
- `git`, `bash`, `python3` (for harvest). `gh` (GitHub CLI, authed) for PRs.
- Whichever agent CLI you point `AGENT` at (`claude` or `codex`), able to run headless.

## Prerequisites checklist before `DRY_RUN=0`
1. `gh auth status` is green (for PRs).
2. The target project's `projects/<slug>.md` has a correct `path:` and a real
   `verify:` command (run `./health.sh` to find pages missing a gate).
3. You've previewed with `./loop.sh` and the chosen task + prompt look right.
