#!/usr/bin/env python3
"""
Trellis history harvester.

Mines past Claude Code conversation transcripts (~/.claude/projects/**/*.jsonl)
and distills the high-signal parts — your intents, the conversation titles, the
branch worked on, dates — into compact markdown under sources/history/, grouped
by project. Raw transcripts are never modified; this only reads them, so no
context is lost (the raw .jsonl remain the source of truth and are referenced).

Usage:
    python3 loop/harvest.py            # harvest into sources/history/
    CLAUDE_PROJECTS=/path python3 loop/harvest.py

It maps each session to a Trellis project page by matching the session's working
directory against the `path:` in projects/*.md. Sessions whose project has no
page yet are still captured (filed by folder) and listed in _unmapped.md so you
can promote them into real project pages later.
"""
import os, sys, json, glob, re
from collections import Counter, defaultdict
from datetime import datetime

HOME = os.path.expanduser("~")
VAULT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROJECTS_DIR = os.path.join(VAULT, "projects")
OUT_DIR = os.path.join(VAULT, "sources", "history")
CLAUDE_PROJECTS = os.environ.get("CLAUDE_PROJECTS", os.path.join(HOME, ".claude", "projects"))

MAX_INTENTS_PER_SESSION = 20
MAX_INTENT_LEN = 280

# Skip non-human / boilerplate user text
SKIP_PREFIXES = ("<command-name>", "<command-message>", "<local-command",
                 "Caveat:", "[Request interrupted", "<system-reminder>",
                 "This session is being continued", "<command-args>")

# Redact secret-like tokens before anything is written to the vault.
REDACT_PATTERNS = [
    re.compile(r"sk-ant-[A-Za-z0-9_-]{6,}"),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"AIza[0-9A-Za-z_-]{35}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),  # JWT
    # key=value style secrets
    re.compile(r"(?i)\b([A-Z0-9_]*(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE[_-]?KEY)[A-Z0-9_]*)\s*[:=]\s*\S+"),
]

def redact(s):
    s = REDACT_PATTERNS[-1].sub(r"\1=[REDACTED]", s)
    for p in REDACT_PATTERNS[:-1]:
        s = p.sub("[REDACTED]", s)
    return s

def load_project_paths():
    """slug -> abspath, from projects/*.md frontmatter `path:`"""
    out = {}
    for f in glob.glob(os.path.join(PROJECTS_DIR, "*.md")):
        slug = os.path.splitext(os.path.basename(f))[0]
        try:
            txt = open(f, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        m = re.search(r'(?m)^path:\s*(.+?)\s*$', txt)
        if m:
            p = m.group(1).strip().strip('"').strip("'")
            if p:
                out[slug] = os.path.normpath(os.path.expanduser(p))
    return out

def texts_from_content(content):
    """Yield plain text blocks authored by the human (skip tool_result/meta)."""
    if isinstance(content, str):
        yield content; return
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                yield b.get("text", "")

def parse_session(path):
    cwds, branches, intents, titles, times = Counter(), set(), [], [], []
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError:
        return None
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = o.get("type")
            if o.get("cwd"):
                cwds[o["cwd"]] += 1
            if o.get("gitBranch"):
                branches.add(o["gitBranch"])
            if o.get("timestamp"):
                times.append(o["timestamp"])
            if t == "ai-title":
                title = o.get("title") or o.get("message") or o.get("text")
                if isinstance(title, str) and title.strip():
                    titles.append(title.strip())
            elif t == "user":
                msg = o.get("message", {})
                if msg.get("role") != "user":
                    continue
                for txt in texts_from_content(msg.get("content")):
                    txt = (txt or "").strip()
                    if not txt or txt.startswith(SKIP_PREFIXES):
                        continue
                    txt = re.sub(r"\s+", " ", txt)
                    txt = redact(txt)
                    if len(txt) > MAX_INTENT_LEN:
                        txt = txt[:MAX_INTENT_LEN].rstrip() + "…"
                    intents.append(txt)
    if not cwds and not intents:
        return None
    cwd = cwds.most_common(1)[0][0] if cwds else None
    times.sort()
    # dedupe intents preserving order
    seen, dedup = set(), []
    for i in intents:
        k = i[:80].lower()
        if k in seen:
            continue
        seen.add(k); dedup.append(i)
    return {
        "file": path,
        "cwd": cwd,
        "branches": sorted(branches),
        "title": titles[-1] if titles else None,
        "intents": dedup,
        "start": times[0][:10] if times else "????-??-??",
        "end": times[-1][:10] if times else "",
        "n_intents": len(dedup),
    }

IGNORE_CWD = re.compile(r"/(loop/runs/wt-|\.git/)|^/private/tmp|^/tmp")
def is_ignored(cwd):
    """Skip non-project working dirs: ephemeral worktrees, tmp, and the home/Desktop roots."""
    if not cwd:
        return True
    c = cwd.rstrip("/")
    if IGNORE_CWD.search(cwd):
        return True
    if c in (HOME.rstrip("/"), os.path.join(HOME, "Desktop")):
        return True
    return False

def match_project(cwd, proj_paths):
    if not cwd:
        return None
    cwd = os.path.normpath(cwd)
    best = None
    for slug, p in proj_paths.items():
        if cwd == p or cwd.startswith(p + os.sep):
            if best is None or len(p) > len(proj_paths[best]):
                best = slug
    return best

def write_history(slug, label, sessions):
    sessions.sort(key=lambda s: s["start"], reverse=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, slug + ".md")
    title = label.replace("-", " ").title()
    lines = [
        "---", f"title: History — {title}", "type: source",
        "tags: [history, harvested]", f"updated: {datetime.now().strftime('%Y-%m-%d')}",
        "---", "",
        f"# Conversation history — {label}", "",
        f"> Harvested from past Claude Code sessions ({len(sessions)} sessions). "
        "Distilled intents only; raw transcripts remain the source of truth at the "
        "paths shown. An agent should *ingest* this into the project page (durable "
        "decisions/gotchas) per AGENTS.md → Operations → Ingest history.", "",
    ]
    for s in sessions:
        head = s["title"] or (s["intents"][0][:80] if s["intents"] else "(untitled session)")
        rng = s["start"] + (f" → {s['end']}" if s["end"] and s["end"] != s["start"] else "")
        lines.append(f"## {rng} — {head}")
        if s["branches"]:
            lines.append(f"*branch(es):* `" + "`, `".join(s["branches"]) + "`")
        picked = s["intents"]
        if len(picked) > MAX_INTENTS_PER_SESSION:
            head = MAX_INTENTS_PER_SESSION // 2
            tail = MAX_INTENTS_PER_SESSION - head
            picked = picked[:head] + [f"…({len(picked) - MAX_INTENTS_PER_SESSION} middle turns omitted)…"] + picked[-tail:]
        for it in picked:
            lines.append(f"- {it}")
        extra = s["n_intents"] - MAX_INTENTS_PER_SESSION
        if extra > 0:
            lines.append(f"- …(+{extra} more turns)")
        lines.append(f"\n<sub>transcript: `{s['file']}`</sub>\n")
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    return path

def main():
    if not os.path.isdir(CLAUDE_PROJECTS):
        print(f"No transcript store at {CLAUDE_PROJECTS}", file=sys.stderr); sys.exit(1)
    proj_paths = load_project_paths()
    files = glob.glob(os.path.join(CLAUDE_PROJECTS, "**", "*.jsonl"), recursive=True)
    print(f"Scanning {len(files)} transcript(s) from {CLAUDE_PROJECTS}…")

    by_slug = defaultdict(list)      # mapped to a vault project
    by_folder = defaultdict(list)    # not mapped — keep by cwd basename
    unmapped_dirs = Counter()
    for f in files:
        s = parse_session(f)
        if not s:
            continue
        if is_ignored(s["cwd"]):
            continue
        slug = match_project(s["cwd"], proj_paths)
        if slug:
            by_slug[slug].append(s)
        else:
            base = os.path.basename(s["cwd"].rstrip("/")) if s["cwd"] else "_unknown"
            key = "other-" + re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")
            by_folder[key].append(s)
            if s["cwd"]:
                unmapped_dirs[s["cwd"]] += 1

    written = []
    for slug, sess in sorted(by_slug.items()):
        written.append(write_history(slug, slug, sess))
        print(f"  ✓ {slug:32s} {len(sess):3d} sessions  → sources/history/{slug}.md")
    for key, sess in sorted(by_folder.items()):
        written.append(write_history(key, key.replace("other-", ""), sess))
        print(f"  • {key:32s} {len(sess):3d} sessions  (no project page yet)")

    # _unmapped index so nothing is silently dropped
    if unmapped_dirs:
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(os.path.join(OUT_DIR, "_unmapped.md"), "w", encoding="utf-8") as fh:
            fh.write("---\ntitle: History — unmapped folders\ntype: source\n---\n\n")
            fh.write("# Folders with history but no Trellis project page\n\n")
            fh.write("Add a `projects/<slug>.md` (with the matching `path:`) to fold these in.\n\n")
            for d, n in unmapped_dirs.most_common():
                fh.write(f"- `{d}` — {n} sessions\n")
        print(f"  → {len(unmapped_dirs)} unmapped folder(s) listed in sources/history/_unmapped.md")
    else:
        # everything mapped: drop the stale index so it can't claim otherwise
        stale = os.path.join(OUT_DIR, "_unmapped.md")
        if os.path.exists(stale):
            os.remove(stale)

    print(f"\nDone. {len(written)} history file(s) in sources/history/.")
    print("Next: have an agent ingest these into project pages (AGENTS.md → Ingest history).")

if __name__ == "__main__":
    main()
