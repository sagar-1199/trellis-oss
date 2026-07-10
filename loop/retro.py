#!/usr/bin/env python3
"""
Trellis retro — measurement backbone for self-improvement.

Reads loop/metrics.jsonl (one record per loop task), reconciles each PR's real
outcome via `gh` (merged / merged-with-edits / closed / open), computes the metric
that actually matters — the ACCEPTED-CHANGE RATE — and writes a dated report under
loop/retro/. The agent reflection pass (retro.sh) turns the report into lessons.

  python3 retro.py                # reconcile, print stats, write report
  python3 retro.py --no-report    # reconcile + print only (this is `trellis metrics`)
"""
import os, sys, json, subprocess
from collections import Counter
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
VAULT = os.path.abspath(os.path.join(HERE, ".."))
METRICS = os.path.join(HERE, "metrics.jsonl")
RETRO_DIR = os.path.join(HERE, "retro")

def gh_json(url, fields):
    try:
        out = subprocess.run(["gh", "pr", "view", url, "--json", fields],
                             capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout)
    except Exception:
        return None

def reconcile(rec):
    """Fill merge_state / merged / edited / review_comments for a pass record with a PR."""
    url = rec.get("pr_url") or ""
    if rec.get("outcome") != "pass" or not url.startswith("http"):
        return rec
    if rec.get("merge_state") in ("MERGED", "CLOSED"):   # terminal — don't re-query
        return rec
    d = gh_json(url, "state,commits,reviews")
    if not d:
        rec["merge_state"] = rec.get("merge_state", "UNKNOWN"); return rec
    rec["merge_state"] = d.get("state", "OPEN")           # OPEN | MERGED | CLOSED
    commits = d.get("commits", []) or []
    # "edited" = a human added commits that aren't the loop's own trellis(...) commit
    human = [c for c in commits if not (c.get("messageHeadline", "").startswith("trellis("))]
    rec["n_commits"] = len(commits)
    rec["edited"] = bool(human)
    rec["review_comments"] = sum(1 for r in (d.get("reviews") or []) if (r.get("body") or "").strip())
    return rec

def main():
    no_report = "--no-report" in sys.argv
    if not os.path.exists(METRICS):
        print("No metrics yet (loop/metrics.jsonl). Run some tasks with `trellis run` first.")
        return
    recs = []
    for ln in open(METRICS, encoding="utf-8", errors="ignore"):
        ln = ln.strip()
        if not ln: continue
        try: recs.append(json.loads(ln))
        except json.JSONDecodeError: pass

    changed = False
    for r in recs:
        before = json.dumps(r, sort_keys=True)
        reconcile(r)
        if json.dumps(r, sort_keys=True) != before: changed = True
    if changed:  # persist reconciled state
        with open(METRICS, "w", encoding="utf-8") as fh:
            for r in recs: fh.write(json.dumps(r) + "\n")

    total = len(recs)
    passed = [r for r in recs if r.get("outcome") == "pass"]
    escalated = [r for r in recs if r.get("outcome") == "escalated"]
    with_pr = [r for r in passed if (r.get("pr_url") or "").startswith("http")]
    merged = [r for r in with_pr if r.get("merge_state") == "MERGED"]
    merged_clean = [r for r in merged if not r.get("edited")]
    closed = [r for r in with_pr if r.get("merge_state") == "CLOSED"]
    open_ = [r for r in with_pr if r.get("merge_state") in ("OPEN", "UNKNOWN", None)]
    resolved = len(merged) + len(closed)
    acc_rate = (len(merged) / resolved * 100) if resolved else None
    clean_rate = (len(merged_clean) / len(merged) * 100) if merged else None

    print("=== Trellis metrics ===")
    print(f"tasks run:        {total}")
    print(f"  built (PR/commit): {len(passed)}   escalated: {len(escalated)}")
    print(f"PRs opened:       {len(with_pr)}   merged: {len(merged)}  (clean: {len(merged_clean)}, edited: {len(merged)-len(merged_clean)})  closed: {len(closed)}  open: {len(open_)}")
    if acc_rate is not None:
        flag = "  [below 50% — the loop is doing review work it should save]" if acc_rate < 50 else ""
        print(f"ACCEPTED-CHANGE RATE: {acc_rate:.0f}%  (merged / resolved){flag}")
    else:
        print("ACCEPTED-CHANGE RATE: n/a (no PRs merged or closed yet)")
    if clean_rate is not None:
        print(f"MERGED-WITHOUT-EDITS: {clean_rate:.0f}%  (the real quality signal)")

    if no_report:
        return

    os.makedirs(RETRO_DIR, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(RETRO_DIR, f"RETRO-{stamp}.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"# Trellis retro — {stamp}\n\n")
        fh.write("## Metrics\n")
        fh.write(f"- tasks: {total} (built {len(passed)}, escalated {len(escalated)})\n")
        fh.write(f"- PRs: opened {len(with_pr)}, merged {len(merged)} (clean {len(merged_clean)}, edited {len(merged)-len(merged_clean)}), closed {len(closed)}, open {len(open_)}\n")
        fh.write(f"- **accepted-change rate: {acc_rate:.0f}%**\n" if acc_rate is not None else "- accepted-change rate: n/a\n")
        fh.write(f"- merged-without-edits: {clean_rate:.0f}%\n\n" if clean_rate is not None else "\n")
        fh.write("## Escalations (learn the root cause; write it to the project page)\n")
        for r in escalated:
            fh.write(f"- **{r.get('repo')}** — {r.get('title')}\n  - reason: {r.get('reason','')}\n")
        if not escalated: fh.write("- none\n")
        fh.write("\n## Merged-with-edits / closed PRs (what did the human change, and why?)\n")
        for r in merged + closed:
            if r.get("edited") or r.get("merge_state") == "CLOSED":
                fh.write(f"- **{r.get('repo')}** — {r.get('title')}  ({r.get('merge_state')}, {r.get('review_comments',0)} review comments)\n  - {r.get('pr_url')}\n")
        fh.write("\n## Proposed improvements (NOT applied — for human approval)\n")
        fh.write("<!-- The retro agent fills this in. It may auto-write lessons to project pages,\n")
        fh.write("     but must only PROPOSE changes to gates / LOOP_PROMPT / QA_PROMPT / trust tiers here. -->\n")
    print(f"\nReport: {os.path.relpath(path, VAULT)}")

if __name__ == "__main__":
    main()
