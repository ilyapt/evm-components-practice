#!/usr/bin/env bash
# Author tooling: verify a task's tests against the private reference solution
# kept in .reference/<task>/starter.sol (git-ignored, never published).
#
#   scripts/check-reference.sh 001-eip712-typed-data   # one task
#   scripts/check-reference.sh                         # every task with a reference
#
# For each task it checks two things: the untouched starter does not pass the
# tests, and the reference solution does. The task's starter is never modified:
# the reference run happens in a scratch copy of the task directory, with its
# own build output, so several checks can run at once.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"

tasks=("$@")
if [ ${#tasks[@]} -eq 0 ]; then
    tasks=($(ls -d .reference/*/ 2>/dev/null | xargs -n1 basename))
fi

status=0
for task in "${tasks[@]}"; do
    ref=".reference/$task/starter.sol"
    if [ ! -f "$ref" ]; then echo "[$task] no reference"; status=1; continue; fi
    if [ ! -f "$task/starter.sol" ]; then echo "[$task] no starter"; status=1; continue; fi

    scratch=".reference/.scratch/$task"
    rm -rf "$scratch" && mkdir -p "$scratch"
    cp -R "$task" "$scratch/task"
    out="$scratch/out"; cache="$scratch/cache"

    if forge test --root "$root" --match-path "$scratch/task/*" -o "$out" --cache-path "$cache" >/dev/null 2>&1; then
        echo "[$task] FAIL: tests pass with the untouched starter"
        status=1
    fi
    cp "$ref" "$scratch/task/starter.sol"
    if forge test --root "$root" --match-path "$scratch/task/*" -o "$out" --cache-path "$cache" >/dev/null 2>&1; then
        echo "[$task] ok: reference passes"
    else
        echo "[$task] FAIL: reference does not pass"
        forge test --root "$root" --match-path "$scratch/task/*" -o "$out" --cache-path "$cache" -vv 2>&1 | tail -60
        status=1
    fi
    rm -rf "$scratch"
done
exit $status
