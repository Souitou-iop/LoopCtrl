#!/bin/sh
# Run every task under both arms, counterbalanced: rep pairs alternate AB, BA,
# AB, … so drift (battery, heat, app caches, network) hits both arms equally.
#   sh tools/skill-ab/run_matrix.sh "T1 T2 T4" 3
# Runs one at a time — the phone has one UI queue.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tasks=${1:-"T1 T2 T3 T4 T5"}; reps=${2:-3}
for t in $tasks; do
    i=1
    while [ "$i" -le "$reps" ]; do
        if [ $((i % 2)) -eq 1 ]; then order="A B"; else order="B A"; fi
        for arm in $order; do sh "$here/run_one.sh" "$t" "$arm" "$i"; done
        i=$((i + 1))
    done
done
python3 -I "$here/score.py"
