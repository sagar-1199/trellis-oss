---
title: Guide
type: guide
updated: 2026-07-02
---

# 🌱 How to use Trellis

Trellis = one brain over all your projects + a safe loop that does the work.
You drive it with the `trellis` command from any terminal.

## The easy way — the menu
Open a terminal and type:
```
trellis
```
A menu appears — just **press a number**:
```
  1) New task     2) Run     3) Ask
  4) Status       5) Metrics 6) Retro  ...
```
That's the whole thing. `2` (Run) builds the next task and opens a PR; `3` (Ask) answers
questions. Everything below is the same actions as typed commands, if you prefer.

## One-time
- Open a **new terminal** so `trellis` works (test: type `trellis` → the menu shows).
- Optional: open the vault in **Obsidian** (`Open folder as vault` → `~/Desktop/trellis`)
  to browse the project graph — but you don't need it to operate Trellis.

## The mental model — two things you ever do
| You want… | Command |
|---|---|
| **An answer / to understand something** | `trellis ask` |
| **A change made (→ PR)** | `trellis run` |

Everything else (`add`, `status`, `metrics`, `retro`) just supports those two.

---

## Ask (get details, read-only, no PR)
```
trellis ask booking            # interactive: opens a chat about that project, ask anything
trellis ask                    # whole-vault: "which projects touch the appointments API?"
trellis ask booking "where is the payment intent created?"   # one-shot (quote the question!)
```
- Interactive (no question) is best for digging + follow-ups. Exit with Ctrl-D or `/exit`.
- One-shot: **always quote** the question (zsh treats `?`/`*` as wildcards otherwise).

## Make a change (→ PR)
```
trellis add                    # describe the task (title, which project, acceptance)
trellis run                    # clarifies with you if unclear, then builds + opens a PR
```
- `trellis run` will **ask you clarifying questions** in the terminal if the task isn't clear.
  Answer them, finish with a single `.` on its own line — it then builds automatically.
- Review the PR on GitHub and **merge it yourself** (Trellis never merges).
- Add tasks straight into `backlog.md` if you prefer editing the file (or via `trellis add`).

## See what's going on
```
trellis status                 # pending / blocked tasks + recent activity
trellis preview                # dry-run: what the loop WOULD do, changes nothing
trellis metrics                # accepted-change rate + PR outcomes (the report card)
```

## Make it smarter over time
```
trellis retro                  # learns from your merges/escalations → lessons into pages,
                               # proposes gate tweaks for you to approve (never auto-applied)
```
Run this every so often after you've merged some PRs.

---

## The typical loop
```
trellis add        →  describe it
trellis run        →  answer any questions;  it builds + opens a PR
(review & merge the PR on GitHub)
trellis metrics    →  occasionally, watch the accepted-change rate
trellis retro      →  occasionally, bank the lessons
```

## Handy tips
- **Cross-engine review** (less bias): `QA_AGENT=codex trellis run`
- **Use Codex instead of Claude**: `AGENT=codex trellis run`
- **Cap a run**: `MAX_ITERATIONS=1 trellis run`
- **Force clarification on every task**: `REQUIRE_SPEC=1 trellis run`
- **All commands**: `trellis help`

## Safety (always on)
- Every change → its own branch + PR. **You merge.** Trellis never does.
- It won't touch `.env`, secrets, `auth/`, `payments/`, migrations, or `db-backups/`.
- `high`-trust projects (production apps, payments, sensitive data) are PR-only, hands-off paths.
- Blocked/failed tasks are marked `[!]` with a note in `loop/runs/ESCALATED-*.md`.
- Keep an eye on the **accepted-change rate** — below 50% means it's making review work,
  not saving it.
