#!/bin/sh
# Freeze the two SKILL.md variants being compared, so every run of an arm reads
# byte-identical text even if SKILL.md changes later.
#   A = the skill before the rewrite (574ad33), B = the working-tree SKILL.md.
#   sh tools/skill-ab/prepare.sh [A_REV] [B_FILE]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
mkdir -p "$here/skills"
git -C "$root" show "${1:-574ad33}:SKILL.md" > "$here/skills/SKILL.A.md"
cp "${2:-$root/SKILL.md}" "$here/skills/SKILL.B.md"
wc -c "$here/skills/SKILL.A.md" "$here/skills/SKILL.B.md"
