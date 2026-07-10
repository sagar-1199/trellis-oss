#!/usr/bin/env bash
# Trellis PLAN mode — clarify a task WITH you, then write specs/<id>.md.
# Script-driven Q&A: the agent asks questions (headless), you type answers here, the
# script writes the spec and returns — no interactive session to exit. Building then
# continues automatically (when invoked by `trellis run`).
#
#   ./plan.sh                 # clarify the top pending backlog task
#   ./plan.sh booking         # clarify the top pending task matching "booking"
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
cd "$TRELLIS_DIR"; mkdir -p specs

frontmatter(){ awk -v k="$1" '/^---[[:space:]]*$/{n++;next} n==1&&$0~"^"k":"{sub("^"k":[[:space:]]*","");gsub(/^"|"$/,"");print;exit}' "$2"; }
slugify(){ echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-40; }
parse_backlog(){
  local f="$TRELLIS_DIR/backlog.md" line pri repo title accept started=0 incmt=0 infence=0
  flush(){ [ "$started" = 1 ] && [ -n "$repo" ] && printf '%s\t%s\t%s\t%s\n' "$pri" "$repo" "$title" "$accept"; }
  while IFS= read -r line; do
    case "$line" in '```'*) [ "$infence" = 1 ] && infence=0 || infence=1; continue;; esac
    [ "$infence" = 1 ] && continue
    case "$line" in *'<!--'*) incmt=1;; esac
    if [ "$incmt" = 1 ]; then case "$line" in *'-->'*) incmt=0;; esac; continue; fi
    if [[ $line =~ ^-\ \[\ \]\  ]]; then
      flush; pri=999 repo="" title="" accept="" started=1
      [[ $line =~ \(priority::\ *([0-9]+)\) ]] && pri="${BASH_REMATCH[1]}"
      [[ $line =~ \(repo::\ *([^\)]+)\) ]] && repo="$(echo "${BASH_REMATCH[1]}" | tr -d ' ')"
      title="$(printf '%s' "${line#- \[ \] }" | sed -E 's/\([a-z]+:: *[^)]*\)//g; s/^ *//; s/ *$//')"
    elif [[ $line =~ ^-\ \[.\]\  ]]; then flush; started=0
    elif [[ $started == 1 && $line =~ ^[[:space:]]+-\ accept::\ ?(.*)$ ]]; then accept="${BASH_REMATCH[1]}"; fi
  done < "$f"; flush
}

sel="${1:-}"
task="$(parse_backlog | sort -t"$(printf '\t')" -k1,1n | { [ -n "$sel" ] && grep -i "$sel" || cat; } | head -1)"
[ -z "$task" ] && { echo "No pending task to plan (add one with: trellis add)."; exit 0; }
IFS=$'\t' read -r pri repo title accept <<<"$task"
page="$TRELLIS_DIR/projects/$repo.md"
path=""; [ -f "$page" ] && path="$(frontmatter path "$page")"
id="$(slugify "$repo-$title")"; spec="specs/$id.md"
pagetext="(no project page)"; [ -f "$page" ] && pagetext="$(sed -n '1,70p' "$page")"

echo "PLAN | [$repo] $title"
echo "Clarifying with $AGENT before building..."; echo

qa=""
for round in 1 2; do
  ask="You are clarifying a coding task BEFORE an autonomous agent implements it. Inspect
the repo at '$path' if useful.

TASK: $title
REPO: $repo  (path: $path)
DRAFT ACCEPTANCE: $accept
PROJECT PAGE:
$pagetext
PRIOR Q&A (if any):
$qa

If you now have enough to write an unambiguous spec, output exactly:
READY
Otherwise output exactly:
QUESTIONS
1. <question>
2. <question>
(only the 2-4 MOST important). Output nothing else."
  out="$(printf '%s' "$ask" | WORKDIR="${path:-$TRELLIS_DIR}" run_reviewer 2>/dev/null)"
  [ -z "$out" ] && { echo "(planner gave no output — proceeding from the draft)"; break; }
  printf '%s\n' "$out" | grep -q '^READY' && { echo "Task is clear enough — writing the spec."; break; }
  echo "Clarifying questions:"; printf '%s\n' "$out" | sed '/^QUESTIONS/d'
  echo; echo "Type your answers (finish with 'done' or '.' on its own line):"
  ans=""; while IFS= read -r l; do
    case "$l" in .|done|DONE|Done) break ;; esac
    ans="$ans$l"$'\n'
  done
  qa="$qa
[Round $round] $out
[Your answers] $ans"
  echo
done

echo "Writing spec..."
specprompt="Write a concise, unambiguous implementation spec as MARKDOWN ONLY (no preamble,
no code fences around the whole thing). Use these sections:
## Goal
## In scope
## Out of scope
## Acceptance criteria   (checkable bullets)
## Files likely touched
## Constraints & notes

TASK: $title
REPO: $repo  (path: $path)
DRAFT ACCEPTANCE: $accept
CLARIFICATION:
$qa

Output only the markdown spec."
spec_md="$(printf '%s' "$specprompt" | WORKDIR="${path:-$TRELLIS_DIR}" run_reviewer 2>/dev/null)"
if [ -n "$spec_md" ]; then
  printf '%s\n' "$spec_md" > "$TRELLIS_DIR/$spec"
  echo "Spec written: $spec"
else
  echo "Could not produce a spec."; exit 1
fi
