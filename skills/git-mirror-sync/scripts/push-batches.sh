#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# push-batches.sh - Push OLK-6.6 branch to GitHub in small commit batches
#
# GitHub has a 2GB push limit. This script splits the push into batches
# of ~3000 first-parent commits each, so each push only sends incremental
# objects and stays well under the limit.
#
# Usage: bash scripts/push-batches.sh [remote] [branch] [batch_size]
#   remote     - git remote name (default: github)
#   branch     - branch to push (default: OLK-6.6)
#   batch_size - commits per batch (default: 3000)

set -euo pipefail

REMOTE="${1:-github}"
BRANCH="${2:-OLK-6.6}"
BATCH="${3:-3000}"
STATE_FILE="/tmp/git-push-${BRANCH}.state"

echo "=== Pushing $BRANCH to $REMOTE in batches of $BATCH commits ==="

# Get all first-parent commit hashes (oldest first)
COMMITS_FILE=$(mktemp)
git log --reverse --first-parent --format="%H" "$BRANCH" > "$COMMITS_FILE"
TOTAL=$(wc -l < "$COMMITS_FILE")
echo "Total first-parent commits: $TOTAL"

# Resume from last pushed batch
LAST_PUSHED=0
if [ -f "$STATE_FILE" ]; then
    LAST_PUSHED=$(cat "$STATE_FILE")
    echo "Resuming from batch ending at commit #$LAST_PUSHED"
fi

BATCH_NUM=$(( (LAST_PUSHED + BATCH - 1) / BATCH + 1 ))
START_IDX=$(( LAST_PUSHED + 1 ))

while [ "$START_IDX" -le "$TOTAL" ]; do
    END_IDX=$(( START_IDX + BATCH - 1 ))
    [ "$END_IDX" -gt "$TOTAL" ] && END_IDX="$TOTAL"

    COMMIT_HASH=$(sed -n "${END_IDX}p" "$COMMITS_FILE")

    echo ""
    echo "=== Batch $BATCH_NUM: commits $START_IDX..$END_IDX / $TOTAL ==="
    echo "=== Pushing commit $COMMIT_HASH (at index $END_IDX) ==="

    if git push "$REMOTE" "$COMMIT_HASH:refs/heads/$BRANCH" 2>&1; then
        echo "$END_IDX" > "$STATE_FILE"
        echo "=== Batch $BATCH_NUM OK ==="
    else
        echo ""
        echo "!!! Push failed at batch $BATCH_NUM (commit $END_IDX / $TOTAL) !!!"
        echo "Retrying with smaller batch..."
        # Retry with half the batch size
        RETRY_END=$(( START_IDX + BATCH / 2 - 1 ))
        if [ "$RETRY_END" -ge "$END_IDX" ]; then
            echo "Still failing. Stopping. State at commit #$(( START_IDX - 1 ))"
            rm -f "$COMMITS_FILE"
            exit 1
        fi
        RETRY_HASH=$(sed -n "${RETRY_END}p" "$COMMITS_FILE")
        echo "Retrying with commit $RETRY_HASH (index $RETRY_END)..."
        if git push "$REMOTE" "$RETRY_HASH:refs/heads/$BRANCH" 2>&1; then
            echo "$RETRY_END" > "$STATE_FILE"
            END_IDX=$RETRY_END
        else
            echo "Retry also failed. Stopping at commit #$(( START_IDX - 1 ))"
            rm -f "$COMMITS_FILE"
            exit 1
        fi
    fi

    BATCH_NUM=$(( BATCH_NUM + 1 ))
    START_IDX=$(( END_IDX + 1 ))
done

# Final push: point the branch to the real HEAD
echo ""
echo "=== Final push: setting $BRANCH to HEAD ==="
git push "$REMOTE" "$BRANCH:refs/heads/$BRANCH" 2>&1

rm -f "$COMMITS_FILE" "$STATE_FILE"
echo ""
echo "=== Done! Successfully pushed $BRANCH to $REMOTE ==="
