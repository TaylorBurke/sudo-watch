# Releasing

How a change reaches users of the Omarchy plugin without leaving the
marketplace listing unverified for longer than necessary. Follow it in order.

## Why this exists

The marketplace verifies **one exact commit**, and for an update that commit
must be this repository's **current default-branch HEAD**. The request form says
"the current repository HEAD SHA when publishing a newer commit", and the
marketplace refuses a mismatch as `update-upstream-changed`. Two consequences:

- A change cannot be reviewed on a branch first. The moment `master` moves, the
  new HEAD is unverified until a maintainer approves it.
- So the gap between "merged" and "verified" cannot be zero. The goal is to make
  it as short as possible: do everything that can be done *before* merging, then
  open the verification request immediately after.

History, for scale: the first listing ([#7534][first]) was approved in about a
day. Merging the test suite moved `master` ahead of the verified commit, and the
re-verification ([#8379][second]) took about nine days, nearly all of it waiting
for the automated baseline and a maintainer.

[first]: https://github.com/omacom/omarchy-plugin-marketplace/issues/7534
[second]: https://github.com/omacom/omarchy-plugin-marketplace/issues/8379

## Rules

1. **Batch changes.** Every update, even a docs-only one, goes into the manual
   review queue, because the baseline scans the whole tree rather than the diff.
   One release is cheaper than several.
2. **Nothing lands on `master` except a release.** Work on a branch and open a
   PR. No drive-by docs or CI commits to `master`.
3. **Freeze before merging.** After the pre-merge checks pass, add no more
   commits. Anything pushed to `master` while a verification request is pending
   invalidates it (`update-upstream-changed`).
4. **Never merge before CI is green.**

## Steps

### 1. Pre-merge checks (on the PR branch, clean tree)

These are the marketplace's own checks, run locally. They are read-only and post
nothing. [`omakit`](https://github.com/mtolhuys/omakit) is a third-party tool;
read it before running, or run it from a checkout instead of installing it
globally:

```sh
git clone --depth 1 https://github.com/mtolhuys/omakit ~/.local/share/omakit
node ~/.local/share/omakit/bin/omakit pin          # one-time: caches the marketplace checks (~23 MB)
node ~/.local/share/omakit/bin/omakit verify .     # baseline for this commit
node ~/.local/share/omakit/bin/omakit inspect .    # what reviewers will look at
node ~/.local/share/omakit/bin/omakit submit . --category System --tags security,notifications,audio --offline
```

`omakit` only reads committed `HEAD` (unless `--allow-dirty`), so commit first.
Expected: `review-required` with `blocksApproval false`. The `privilege`
capability is a false positive from the word "sudo" in the plugin's name; the
others (`remote-build`, `package-manager`, `service-management`, `installer`)
describe the optional standalone systemd install. `submit --offline` skips the
check that the commit is the default-branch HEAD; that one only passes after
the merge.

Also: `bats tests/` passes locally, and the PR's CI is green.

### 2. Merge

After owner approval, merge the PR. Any merge method is fine, because the
request in step 3 names whatever SHA `master` ends up at. Do not merge anything
else until step 4 is done.

### 3. Open the verification request immediately

On the [marketplace tracker][tracker], new issue "Verify or update a listed
plugin":

- **Verification action:** `Verify and publish a newer upstream commit`
- **Plugin ID:** `taylorburke.sudo-watch`
- **Repository URL:** `https://github.com/TaylorBurke/sudo-watch`
- **Target commit:** the full 40-character `git rev-parse origin/master`

[tracker]: https://github.com/omacom/omarchy-plugin-marketplace/issues/new/choose

Confirm first with `omakit submit .` (online, no `--offline`): the
default-branch-HEAD check should now pass. If `master` has moved since you read
the SHA, update the issue to the current full SHA.

### 4. Wait, and watch

```sh
node ~/.local/share/omakit/bin/omakit watch https://github.com/omacom/omarchy-plugin-marketplace/issues/<number> .
```

Do not push to `master` meanwhile. The bot posts "Ready for verified update
review" after validation, and a maintainer then applies `approved-and-verified`.
If nothing moves for 2 to 3 days, comment on the issue politely asking for a
look. Last time the first automated attempt reported "Verification could not
complete" and nothing happened until a maintainer commented a week later.

### 5. After approval

- Tag the verified commit (`git tag v<version> <sha> && git push origin v<version>`).
- Run `omakit audit`; this plugin should no longer show as drifted.
- Unblock the next batch of work (for example #4).

## Checklist

- [ ] Changes batched into one PR; nothing else queued for `master`
- [ ] `omakit verify` / `inspect` / `submit --offline` reviewed on the final commit
- [ ] `bats tests/` and PR CI green
- [ ] Owner approval; branch frozen
- [ ] Merged; verification issue opened with the exact `master` SHA
- [ ] No pushes to `master` until verified
- [ ] Tagged; `omakit audit` clean
