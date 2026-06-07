---
name: git-mirror-sync
description: >
  Sync a git branch from an upstream source remote (e.g., origin) to a GitHub mirror remote.
  Use this skill whenever the user wants to: sync code from origin/upstream to a GitHub mirror,
  push local commits to a GitHub mirror, compare local vs GitHub differences before pushing,
  or push a large commit history in batches to avoid the 2GB GitHub push limit.
  This skill handles the full workflow: identifying remotes, estimating push size,
  choosing between single push and batched push, and verifying the result.
  Trigger on phrases like "sync to github", "push to mirror", "push in batches",
  "origin to github", "sync code from origin", "push remaining commits",
  or any request involving pushing a large git history to GitHub.
compatibility:
  - git >= 2.20
  - bash
---

# Git Mirror Sync Skill

Synchronize a branch from an upstream source remote to a GitHub mirror remote, handling large histories with automatic batch push when needed.

## When this skill is useful

This skill solves a common problem: you have a git repo with two remotes — an upstream source (e.g., `origin` on a hosting platform like Gitee/AtomGit/GitLab) and a GitHub mirror. You need to push code from the upstream remote's branch to the GitHub mirror. When the commit history is large (hundreds of thousands of commits), GitHub's 2GB push limit can block a single `git push`. This skill detects the size and chooses the right strategy.

## How it works

```
Identify remotes → fetch & update tracking → count pending commits
→ estimate pack transfer size → if < 2GB: single push
→ if ≥ 2GB: batch push via incremental commits → verify
```

---

## Workflow

### Step 1: Identify remotes and branch

Run `git remote -v` to understand the remote setup. The skill expects:

- An **upstream/source remote** (the repo you pull from) — typically named `origin`
- A **GitHub mirror remote** — typically named `github`

If the user didn't specify the branch, use `git branch --show-current` to determine the current branch.

**Edge cases to handle:**
- If only one remote exists, ask the user which remote is the mirror
- If the remote names differ from `origin`/`github`, adapt accordingly (e.g., `upstream`/`mirror`)
- If no GitHub remote exists, suggest adding one: `git remote add github git@github.com:<user>/<repo>.git`

### Step 2: Fetch and update remote tracking

```bash
git fetch <mirror-remote> <branch>
```

This ensures the local tracking ref (e.g., `github/OLK-6.6`) is up to date with the actual remote state. Without this step, the commit count estimate will be stale.

### Step 3: Count pending commits

```bash
# Count total pending commits
git rev-list --count <mirror-remote>/<branch>..<branch>
```

This tells you how many commits need to be pushed. A large number (e.g., 100k+) suggests a large transfer, but the real factor is the object data size.

Also show the user a summary of what will be pushed:

```bash
echo "--- Last commit on mirror ---"
git log --oneline -1 <mirror-remote>/<branch>
echo "--- Local HEAD ---"
git log --oneline -1 <branch>
echo "--- Pending commits ---"
git rev-list --count <mirror-remote>/<branch>..<branch>
```

### Step 4: Estimate transfer pack size

This is the critical step for deciding the push strategy. Generate the actual pack that would be sent and check its size:

```bash
git pack-objects --all-progress-implied --stdout --revs <<<"<mirror-remote>/<branch>..<branch>" 2>/dev/null | wc -c
```

The result is in bytes. The GitHub push limit is **2 GB** (2,147,483,648 bytes).

**Why this works:** `git pack-objects` generates the exact compressed pack data that would be transferred. This is more accurate than counting objects or checking repo size, because it accounts for:
- Delta compression against objects the remote already has
- Actual wire format size

### Step 5: Choose push strategy

#### Strategy A: Single push (size < 2GB)

If the estimated pack size is under 2GB, do a single push:

```bash
git push <mirror-remote> <branch>:<branch>
```

Use a generous timeout (e.g., 7200000ms = 2 hours) since large pushes take time.

#### Strategy B: Batch push (size ≥ 2GB)

If the estimated pack size is ≥ 2GB, use incremental batch pushing.

**The principle:** Instead of pushing the branch tip directly (which requires the remote to receive all objects at once), push intermediate commits one batch at a time. Each push only sends the objects for that batch's commits, staying under the limit.

**Batch push algorithm:**

```
1. Get all first-parent commit hashes (oldest first):
   git log --reverse --first-parent --format="%H" <branch>

2. Divide into batches of ~3000 first-parent commits each

3. For each batch:
   a. Take the last commit hash in the batch
   b. git push <mirror-remote> <hash>:refs/heads/<branch>
   c. If it fails, retry with half the batch size

4. Final push to update branch ref to actual HEAD:
   git push <mirror-remote> <branch>:refs/heads/<branch>
```

The skill bundles `scripts/push-batches.sh` which implements this algorithm. Use it when the estimated size is ≥ 2GB:

```bash
bash <skill-path>/scripts/push-batches.sh <mirror-remote> <branch> [batch-size]
```

Default batch size is 3000 commits. If the initial push still fails, the script automatically halves the batch size and retries.

**Why first-parent commits matter:** When you push a specific commit hash, git sends all objects reachable from that commit. Using first-parent history ensures each batch includes all its ancestor commits (including merges), while keeping each batch's delta small since the remote already has the previous batch's objects.

### Step 6: Verify

After the push completes, verify success:

```bash
# Check the mirror remote has been updated
git fetch <mirror-remote> <branch>
git log --oneline -1 <mirror-remote>/<branch>
git log --oneline -1 <branch>
```

The two should match. If they don't, investigate and retry.

Also check for any unpushed commits as a final sanity check:

```bash
git rev-list --count <mirror-remote>/<branch>..<branch>
# Should output 0
```

---

## Practical examples

### Example 1: Small sync (single push)

```
User: "Sync our OLK-6.6 branch from origin to github"

1. git remote -v
   → origin = https://xxx, github = git@github.com:user/repo

2. git fetch github OLK-6.6

3. git rev-list --count github/OLK-6.6..OLK-6.6 → 5000 commits

4. Pack size estimate → 150 MB

5. git push github OLK-6.6:OLK-6.6  (single push, < 2GB)

6. Verify: git fetch github && git log --oneline -1 github/OLK-6.6 matches HEAD
```

### Example 2: Large history (batch push)

```
User: "Push this repo to our GitHub mirror, it has 200k+ commits"

1. git remote -v
   → origin = https://xxx, github = git@github.com:user/repo

2. git fetch github main

3. git rev-list --count github/main..main → 165841 commits

4. Pack size estimate → 2.8 GB → exceeds 2GB limit

5. bash <skill-path>/scripts/push-batches.sh github main 3000
   (pushes in batches of ~3000 first-parent commits)

6. Verify: git fetch github && git log --oneline -1 github/main matches HEAD
```

### Example 3: First-time mirror setup

```
User: "Set up a GitHub mirror for this repo and push everything"

1. git remote -v → only "origin" exists

2. git remote add github git@github.com:user/repo.git

3. Proceed with sync (fetch → estimate → push)
```

---

## Safety checks and edge cases

- **Authentication:** Before pushing, verify SSH access: `ssh -T git@github.com`. If authentication fails, stop and tell the user.
- **Remote doesn't exist:** If the mirror remote doesn't exist, create it with `git remote add`.
- **No new commits:** If `git rev-list --count` returns 0, there's nothing to push. Inform the user.
- **Branch mismatch:** If the mirror remote doesn't have the branch yet (first push), the tracking ref won't exist. In this case, skip the count estimate and do a single push — the pack size will be the full repo size.
  ```bash
  # Check if remote branch exists
  git ls-remote --heads <mirror-remote> <branch> | wc -l
  # If 0, it's a first push — use single push
  ```
- **Push failure in batch mode:** The bundled script retries with a smaller batch size. If it keeps failing, report the error and the last successful commit index.
- **Uncommitted local changes:** The skill only pushes committed history. If there are uncommitted changes, note them to the user but don't commit — that's outside the skill's scope.
