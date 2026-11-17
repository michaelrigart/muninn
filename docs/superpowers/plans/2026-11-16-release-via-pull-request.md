# Releasing through a pull request Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented — PR #8

**Goal:** `scripts/release` lands its release commit through a pull request it opens, checks and
merges with `--admin`, resumes from every stop point, and ends on `main` with the release branch
gone; it never pushes `main`.

**Architecture:** One bash script, `scripts/release`, gains five functions:
`check_merge_rights`, `undo_release_commit`, `land_release_commit`, `check_release_section` and
`tidy_up`. They are called from today's numbered sections. `scripts/tests/test-release-dry-run`
keeps its scenario style. Its `gh` stub gains a pull-request model that merges in the scenario's
bare origin. A fast build (fake `xcodebuild` plus a pass-through verifier) carries the scenarios
that test git and GitHub flow rather than the build.

**Tech Stack:** bash (3.2-compatible), git ≥ 2.38 (`merge-tree --write-tree` in the stub), `gh`,
`/usr/bin/python3` for `scripts/changelog.py`.

**Spec:** `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`

## Global Constraints

- Bash 3.2-compatible in both files: no `mapfile`, associative arrays, `${x,,}`, `|&`.
- No new dependency. `gh --jq` only *projects* fields into one `|`-separated line per item; every
  decision is made in bash, so the stub can return the projection and the tests exercise the
  script's own logic.
- Name refs in full in every git command that writes or compares a ref (`refs/heads/release/<v>`,
  `refs/tags/<v>`): the branch `release/<v>` and the tag `<v>` must never be confused.
- The script never pushes `refs/heads/main`. Nothing in it may contain `HEAD:main` or `:main`
  except the tap clone's push, which is unchanged.
- Repository-specific names stay in the variables at the top (`repo`, `tap_repo`, `team`) and in
  the existing app, zip and cask names; nothing new is Muninn-specific, because the other repositories copy
  this file.
- The repository is public: no personal or workflow details in code, tests, comments or messages.
- Run `scripts/tests/test-release-dry-run` outside the agent sandbox (`AGENTS.md`: the build
  service and SwiftPM fail inside it). It needs the signing certificate and `brew`.
- Each new or changed case fails with its code reverted; the task report names the revert it ran
  and the case that failed.
- Implementers run only the release suite and `bash -n scripts/release scripts/tests/test-release-dry-run`;
  the controller runs the full set after the last task.

### Messages (exact copy, asserted by tests)

`die` prefixes `release: `. `<v>` is the version, `<R>` the full release-commit id, `<n>` the
pull request number, `<b>` is `release/<v>`.

| Where | Text |
|---|---|
| merge rights, refusal | `gh cannot merge the release pull request as <login>: <problems>; run from a shell where gh uses a login with the repo scope (gh auth login), with GH_TOKEN unset` |
| merge rights, dry run | `Note: a real release would stop here: gh cannot merge the release pull request as <login>: <problems>.` |
| problem, scope | `its token (from <source>) has neither the repo nor the public_repo scope` |
| problem, role | `<login> is not an admin of <repo>` (problems joined by `; `) |
| problem, lookup | `could not read <login>'s permissions on <repo>` (a failed `gh api repos/<repo>`) |
| branch exists | `<b> already exists; wait a minute, or resume it with --version <v>` |
| commit failed, undone | `the release commit failed, so nothing was released; CHANGELOG.md and main are as they were; run scripts/release again` |
| commit failed, left | `the release commit failed and CHANGELOG.md changed after the script wrote it, so nothing was undone: you are on <b>, with the script's CHANGELOG.md staged and your edits in the working tree; save your edits, then run: git restore --staged --worktree CHANGELOG.md && git switch main && git branch -D <b>` |
| resume hint (trap) | `release: stopped; resume with: scripts/release --version <v>` |
| push failed | `the push of <b> failed` |
| origin branch elsewhere | `origin's <b> is at <sha>, not the release commit <R>; the script merges only the commit it cut; if that branch is not needed, delete it (git push origin --delete <b>) and resume` |
| closed PR | `pull request #<n> for <b> was closed without merging; reopen it to resume (gh pr reopen <n> --repo <repo>), or abandon <v>:` + abandon commands |
| merged PR, R not on main | `pull request #<n> for <b> is merged, but the release commit <R> is not on origin/main` (no resume hint: a resume cannot get past it) |
| PR check | `pull request #<n> is not the release commit alone (<problems>); it stays open and unmerged` |
| PR check problems | `it is <state>, not OPEN`; `its base is <base>, not main`; `it comes from another repository`; `its head is <sha>, not <R>`; `its files are <list>, not only CHANGELOG.md` |
| merge failed | `merging pull request #<n> failed; it stays open` |
| merged, not on main | `pull request #<n> is merged, but origin/main does not contain <R>` |
| changelog moved (step 0) | `origin/main changed CHANGELOG.md after the release commit was cut, so merging it would file those changes under <v>; abandon <v> and cut a new release:` + abandon commands (no resume hint) |
| section check | `the <v> section of CHANGELOG.md on origin/main differs from the release commit's:` + `diff -u` of the two, then `correct CHANGELOG.md on main through a pull request, then resume` |
| resume validation | `HEAD is not on origin/main, and it is not a 'Release <v>' commit that can land (<problems>); check out the release commit, or a commit on origin/main` |
| validation problems | `its message is '<m>', not 'Release <v>'`; `it has <k> parents, not one`; `its parent is not on origin/main`; `it changes nothing, not CHANGELOG.md`; `it changes <files>, not only CHANGELOG.md` |
| resume from main, release branch exists | `CHANGELOG.md has no section for <v> here; the release commit is on <b>: run git switch <b>, then resume with scripts/release --version <v>` (no resume hint) |
| tidy-up | `release: released <v>, but could not tidy up:` then one indented line per problem |
| dry run, last line | `Dry run: nothing committed, branched, pushed, merged, tagged or published.` |

Abandon commands are printed one per line, indented by two spaces, each only when it applies:
`gh pr close <n> --repo <repo>` (a pull request is open), `git push origin --delete <b>` (the
branch is on origin), `git switch main`, `git pull --ff-only`, `git branch -D <b>` (the branch
exists locally), `scripts/release`.

## Review Focus

- An older `gh` without `auth status --json`: the run refuses with "gh is not signed in", never an
  unbound variable or a half-parsed line. Test in Task 1 (stub prints an error and exits 1).
- A `gh pr create` that prints a warning line before the URL: the number comes from the last line
  matching `/pull/<digits>$`. Test in Task 2 (stub prints a warning first).
- A failed `git fetch` after the merge: the run stops with the resume hint, and the resume finishes
  the release. Covered by Task 4's resume of a stop after the merge.
- Ctrl-C or any failure between the commit and the push: the trap prints the resume hint, because
  `committed=1` is set right after the commit. Task 2's rejected-push case asserts it.
- A resume from a detached HEAD at the release commit: it ends on `main`. Test in Task 6.

---

### Task 1: Merge-rights pre-check, and hooks the suite can rely on

**Depends on:** none

**Files:**
- Modify: `scripts/release` (section 1, Checks)
- Test: `scripts/tests/test-release-dry-run` (gh stub; `new_scenario`; groups a and b)

**Interfaces:**
- Produces: `check_merge_rights` in `scripts/release` (no arguments; uses `repo`, `dry_run`; dies
  or prints the note). Stub files `$STUB_DIR/gh-state` (default `success`), `gh-login` (default
  `release-test`), `token-source` (default `keyring`), `scopes` (default `gist, read:org, repo`),
  `not-admin`, `auth-fails`. Read-only calls in `gh_writes`' filter: `auth status`, `api repos/`.

- [x] **Step 1: Make the suite's hooks independent of the global `core.hooksPath`.** In
  `new_scenario`, after the bare clone: `git --git-dir="$bare" config core.hooksPath "$bare/hooks"`.
  Run the suite outside the sandbox: groups f, f2, f3 and g9 now pass on a machine whose global
  config sets `core.hooksPath`. Revert check: without the line they fail there.

- [x] **Step 2: Write the failing tests.** The stub's `auth status` prints
  `<gh-state>|<gh-login>|<token-source>|<scopes>` (exit 1 with `unknown flag: --json` on stderr
  when `auth-fails` exists); `api repos/<repo>` prints `false` when `not-admin` exists, else
  `true`. Cases:

```bash
# group b, after b7
printf 'gist, read:org\n' >"$STUB_DIR/scopes"; printf 'GH_TOKEN\n' >"$STUB_DIR/token-source"
run_release
expect_refused "b8: a token without the repo scope" "has neither the repo nor the public_repo scope"
expect "b8: names the token's source" contains "$output" "(from GH_TOKEN)"
expect "b8: says how to run it" contains "$output" "with GH_TOKEN unset"
expect "b8: no release branch" test -z "$(git -C "$clone" branch --list 'release/*')"
printf 'public_repo\n' >"$STUB_DIR/scopes"; touch "$STUB_DIR/not-admin"
run_release
expect_refused "b9: an account that is not an admin" "release-test is not an admin of $repo"
rm "$STUB_DIR/not-admin" "$STUB_DIR/scopes" "$STUB_DIR/token-source"
touch "$STUB_DIR/auth-fails"; run_release
expect_refused "b10: a gh without auth status --json" "gh is not signed in"
rm "$STUB_DIR/auth-fails"
```

  Two pins of today's new-release checks, shared by every port: b1 expects the full
  `a new release must be cut from main`. New b3b: a second clone of the bare origin (hooks path
  `/dev/null`) pushes an empty commit to `main`; a new release from the now-behind clone is
  refused with `main is not level with origin/main`, and nothing is created. Both pass at once;
  their revert check removes the refusal they pin.

  Group a gains a2, a dry run with `scopes` = `gist`: exits 0, output contains
  `Note: a real release would stop here: gh cannot merge the release pull request as release-test`,
  and nothing is written (the same "no new tag/commit/origin untouched/gh not asked to write"
  expects as a, on a fresh scenario `dry-scope`).

- [x] **Step 3: Run the suite; b8–b10 and a2 fail.**

- [x] **Step 4: Implement `check_merge_rights`.** Replace `gh auth status >/dev/null 2>&1 || die …`
  with one call:
  `gh auth status --active --hostname github.com --json hosts --jq '.hosts["github.com"][0] | [.state, .login, .tokenSource, (.scopes // "")] | join("|")'`,
  split on `|` with `IFS='|' read -r`. A failed call or a state other than `success` keeps
  today's `gh is not signed in; run: gh auth login`. Scopes match when `, <scopes>, ` contains
  `, repo, ` or `, public_repo, `. Then `gh api "repos/$repo" --jq .permissions.admin` must print
  `true`. Problems join with `; `; a real run dies with the refusal, a dry run echoes the note and
  goes on. Call it where the old `gh auth status` line was, so it runs before the signing and
  Xcode checks.

- [x] **Step 5: Run the suite outside the sandbox; all cases pass.** Revert check on b8, b9, b10, a2.

- [x] **Step 6: Commit** `Refuse a release whose gh cannot merge the release pull request`.

### Task 2: A new release lands through its pull request

**Depends on:** Task 1 (the stub's read-only calls and `gh_writes`)

**Files:**
- Modify: `scripts/release` (sections 1 to 3 and 7, the trap)
- Test: `scripts/tests/test-release-dry-run` (stub pull requests, fast build, groups d, e, f)

**Interfaces:**
- Consumes: `check_merge_rights` (Task 1).
- Produces, in `scripts/release`: globals `branch` (`release/<v>`, set with the version),
  `release_commit`, `pr_number`, flags `committed` (replaces `pushed`) and `published`;
  `land_release_commit` (no arguments; uses `release_commit`, `branch`, `version`, `repo`,
  `work/notes.md`; sets `pr_number`; returns only on success). The trap prints the resume hint
  when the status is non-zero, `committed` is 1 and `published` is 0.
- Produces, in the test: `STUB_BARE` (exported by `new_scenario`); stub pull requests as
  `$STUB_DIR/prs/<n>` files of `key=value` lines (`head`, `base`, `state`, `cross`, `head_oid`
  once merged or closed), numbered from `$STUB_DIR/next-pr` (starts at 1); switches
  `pr-create-fails`, `pr-merge-fails`, `pr-view-files`, `pr-view-head`, `before-merge` (an
  executable run before the stub merges), `merge-subject`, `create-warning`; helpers
  `pr_field <n> <key>`, `fast_build` (a PATH directory) and `new_scenario <name> --fast`;
  `origin_merged <R>` (true when origin's `main` is a merge commit whose second parent is `R`).

- [x] **Step 1: Extend the stub.** Projections it prints, matching the script's `--jq` exactly:
  - `pr list --head <b> --base <base> …`: one `<n>|<state>|<cross>` line per stored pull request
    with that head and base.
  - `pr view <n> …`: `<state>|<base>|<head oid>|<cross>|<files>`. The head oid is the bare
    branch's tip while open, else `head_oid`. The files are `git diff --name-only` from the merge
    base with `main` to the head, comma-joined. `pr-view-files` and `pr-view-head` replace them.
  - `pr create --repo --base --head --title --body-file`: fails when `pr-create-fails` exists,
    when the head branch is not on the bare origin, or when an open one has the same head and
    base. Otherwise it stores the pull request, prints `Warning: 1 uncommitted change` first when
    `create-warning` exists, and prints `https://github.com/michaelrigart/muninn/pull/<n>`.
  - `pr merge <n> --repo … --merge --admin --match-head-commit <sha>`: exit 99 without each of the
    three flags; exit 1 when `pr-merge-fails` exists or the head is not `<sha>`. It runs
    `before-merge` if present, then `merge-tree --write-tree main <head>` (exit 1 on conflict) and
    `commit-tree -p main -p <head>` with the subject `Merge pull request #<n> from <owner>/<b>`
    (or `merge-subject`), then `update-ref refs/heads/main`. It records `state=MERGED` and
    `head_oid`.

  Author and committer for `commit-tree` come from `GIT_AUTHOR_*`/`GIT_COMMITTER_*` set inside
  the stub. `gh_writes` keeps filtering reads, now also `pr list` and `pr view`.

- [x] **Step 2: Add the fast build.** `$work/fast-build/xcodebuild` answers `-version`, and
  for a build writes `build/dd.noindex/Build/Products/Release/Muninn.app/Contents/Info.plist`
  under the current directory. `new_scenario <name> --fast` writes `#!/bin/sh\nexit 0\n` to the
  clone's `scripts/verify-app` before the snapshot commit. A scenario that runs with `fast_build`
  at any point, in its first run or in a later resume, is created with `--fast`. That covers e,
  f, f2, f3, f4 and f5 here, and the publishing scenarios of Tasks 4 to 6. The failing build and
  the rejecting hooks work the same in such a scenario. Scenarios that check the real build
  (a, d) never use it.

- [x] **Step 3: Write the failing tests.** Rewrite d's push assertions:

```bash
R="$(git --git-dir="$bare" rev-parse "refs/tags/$v^{commit}")"
calls="$(cat "$STUB_DIR/calls.log")"
expect "d: the tag is a 'Release <version>' commit" test "$(git --git-dir="$bare" log -1 --format=%s "$R")" == "Release $v"
expect "d: origin's main merges the release commit" origin_merged "$R"
expect "d: opens one pull request from release/<version> into main" test "$(ls "$STUB_DIR/prs" | wc -l | tr -d ' ')" -eq 1 -a "$(pr_field 1 head)" == "release/$v" -a "$(pr_field 1 base)" == main
expect "d: titles it after the release" contains "$calls" "--title Release $v"
expect "d: merges it as admin, pinned to the release commit" contains "$calls" "pr merge 1 --repo $repo --merge --admin --match-head-commit $R"
expect "d: never pushes main" lacks "$(cat "$dir/pushes.log")" "refs/heads/main"
```

  `pushes.log` comes from a `pre-receive` hook that `new_scenario` installs in every bare origin:
  it appends each `<old> <new> <ref>` line it reads and accepts. The rejecting hooks of f and g
  replace it. Each scenario truncates `$dir/pushes.log` right before `run_release`, so its own
  setup pushes are not counted. Also:
  - **e** (created with `--fast`; its first run uses the failing build, which stops the run
    after the merge): fails;
    prints `resume with: scripts/release --version $v`; origin's `main` merges the release commit;
    no tag; the clone is still on `release/$v` at the release commit.
  - **f** (rejected branch push): fails; says `the push of release/$v failed` and the resume hint;
    origin unchanged; nothing built; no tag; `gh` not asked to write; HEAD is the `Release $v`
    commit on `release/$v`; the tree is clean.
  - **f2** (`pr-create-fails`): fails with the resume hint; `release/$v` is on origin at the
    release commit; no pull request; `main` unchanged.
  - **f3** (`pr-merge-fails`): fails with `merging pull request #1 failed; it stays open` and the
    resume hint; pull request 1 is `OPEN`; `main` unchanged.
  - **f4** (`pr-view-files` = `AGENTS.md,CHANGELOG.md`, then `pr-view-head` = another commit):
    each fails with `pull request #1 is not the release commit alone`, naming the files or the
    head; no `pr merge` call is logged; `main` unchanged.
  - **f5** (`create-warning`): the run merges pull request 1. This is the Review Focus case.

  Today's f2 and f3 (the `reset --keep` cases) are deleted with the code they test.

- [x] **Step 4: Run the suite; the new d, e and f cases fail.**

- [x] **Step 5: Implement.**
  - Section 2: set `branch="release/$version"` with the version.
  - Section 3, new release: `git switch -q -c "$branch"`, then `changelog.py release`,
    `git add`, `git commit` as today, `release_commit="$(git rev-parse HEAD)"`, `committed=1`.
  - Write `$work/notes.md` from `CHANGELOG.md` before landing, not after.
  - Remove the `git push … HEAD:main` and its `reset --keep` branch.
  - `land_release_commit`, in this order:
    1. **Reads.** Origin's branch with `git ls-remote origin "refs/heads/$branch"`; the pull
       requests with
       `gh pr list --repo "$repo" --head "$branch" --base main --state all --json number,state,isCrossRepository --jq '.[] | [.number, .state, .isCrossRepository] | map(tostring) | join("|")'`,
       using the first `OPEN` line whose cross field is `false`. Task 4 adds the refusals that use
       these reads.
    2. **Branch.** Push with `git push -q origin "$release_commit:refs/heads/$branch"` when origin
       has no branch.
    3. **Pull request.** Create one when none is open: `gh pr create --repo "$repo" --base main
       --head "$branch" --title "Release $version" --body-file "$work/notes.md"`, taking the
       number from the last output line matching `/pull/[0-9]+$`.
    4. **Check.** `gh pr view "$pr_number" --repo "$repo" --json state,baseRefName,headRefOid,isCrossRepository,files --jq '[.state, .baseRefName, .headRefOid, (.isCrossRepository | tostring), ([.files[].path] | join(","))] | join("|")'`,
       testing every field against the table's problems.
    5. **Merge** as the spec says.
    6. **Confirm.** `git fetch -q origin main`, then `git merge-base --is-ancestor`.
  - The tag stays `git tag "$version"` on HEAD, which is the release commit.

- [x] **Step 6: Run the suite outside the sandbox; all cases pass.** g1 and g9 still test today's
  recovery push, which Task 4 replaces. Revert check on d's merge assertions, f, f3 and f4.

- [x] **Step 7: Commit** `Land a new release commit through its pull request`.

### Task 3: Undo a failed release commit; refuse an existing release branch

**Depends on:** Task 2 (the branch creation in section 3)

**Files:**
- Modify: `scripts/release` (section 2's new-release checks, section 3)
- Test: `scripts/tests/test-release-dry-run` (new group k; b11)

**Interfaces:**
- Consumes: `branch`, `committed` (Task 2).
- Produces: `undo_release_commit` (no arguments; uses `branch`, `written`, the hash of the
  `CHANGELOG.md` the script wrote; always dies).

- [x] **Step 1: Write the failing tests.**
  - **k1:** `git -C "$clone" config core.hooksPath "$dir/commit-hooks"` with a `pre-commit` that
    exits 1. The run fails with the "commit failed, undone" text and no resume hint. The clone is
    on `main` at its old commit, `CHANGELOG.md` is unchanged and the tree is clean; there is no
    `release/*` branch locally or on origin and no tag; `gh` is not asked to write.
  - **k2:** the `pre-commit` appends a line to `CHANGELOG.md` and exits 1. The run fails with the
    "left" text, still on `release/<v>`, and `CHANGELOG.md` keeps the appended line.
  - **b11:** a `date` stub in a PATH directory prints `20260303-0303` for `+%Y%m%d-%H%M` and
    passes anything else to `/bin/date`. With `release/20260303-0303` pushed to origin: refused
    with `release/20260303-0303 already exists`, nothing created. Then with it only local: the
    same.

- [x] **Step 2: Run; k1, k2 and b11 fail.**

- [x] **Step 3: Implement.** For a real new release, after the tag check, refuse when
  `refs/heads/$branch` exists locally or `git ls-remote origin "refs/heads/$branch"` prints
  anything. In section 3, record `written="$(git hash-object CHANGELOG.md)"` after
  `changelog.py release`, and call `undo_release_commit` when `git commit` fails. When the hash
  still matches, it runs `git restore --source=HEAD --staged --worktree CHANGELOG.md`,
  `git switch -q main` and `git branch -q -D "$branch"`, then dies with the "undone" text.
  Otherwise it dies with the "left" text.

- [x] **Step 4: Run outside the sandbox; all pass.** Revert check on k1, k2, b11.

- [x] **Step 5: Commit** `Undo a failed release commit and refuse an existing release branch`.

### Task 4: Resume lands through the pull request

**Depends on:** Task 2 (`land_release_commit`, the stub's pull requests)

**Files:**
- Modify: `scripts/release` (section 1's resume branch, section 3's resume path,
  `land_release_commit`)
- Test: `scripts/tests/test-release-dry-run` (group g; resumes of e, f, f2, f3)

**Interfaces:**
- Consumes: `land_release_commit`, `committed`, stub pull requests, `fast_build`.
- Produces: the flag `land` (replaces `recover`); test helpers `seed_pr <n> <b> <state> <cross>`
  (writes a stub pull request) and `release_on_branch <v>` (on a fresh `main` level with origin,
  creates `release/<v>` with a `Release <v>` commit made by `changelog.py release`).

- [x] **Step 1: Write the failing tests.** Group g is rewritten around `release_on_branch`:
  - **g1:** a valid unpushed release commit, fast build: exits 0; it lands through pull request 1;
    origin's `main` merges it; the tag is on it.
  - **g2, g3, g6:** another file, another message, an empty commit: refused with today's
    substrings. Nothing on origin, no pull request, nothing built.
  - **g4:** two local commits: refused with `its parent is not on origin/main`.
  - **g5:** `main` moved by a commit that leaves `CHANGELOG.md` alone, fast build: exits 0;
    origin's `main` merges the release commit, and the other commit is an ancestor of origin's
    `main`.
  - **g7:** dry run: no push, no `pr` call in `calls.log`, HEAD unchanged.
  - **g8:** a tag elsewhere: refused before any push; `gh` is not asked to write (`gh_writes`
    empty).
  - **g9:** origin's `release/<v>` at another commit: refused with
    `origin's release/$v is at`; `gh` is not asked to write (the landing's `pr list` read is
    allowed).
  - **g10:** `seed_pr 5 release/$v CLOSED false` and the branch on origin: refused with
    `pull request #5 for release/$v was closed without merging` and
    `gh pr reopen 5 --repo $repo`; no `pr create`.
  - **g11:** `seed_pr 5 release/$v OPEN true`, fast build: the cross-repository one is ignored;
    the run creates its own pull request and merges that one, never number 5.
  - **g12:** `seed_pr 5 release/$v MERGED false` while HEAD is not on `main`: refused with
    `is merged, but the release commit`.
  - **Resumes, fast build, `--version $v` after the stop:** e merges nothing again and tags;
    f pushes the branch, then opens and merges pull request 1; f2 opens pull request 1 and merges
    it; f3 merges pull request 1 and opens no second one (`pr create` absent from `calls.log` since
    the stop). Each exits 0, and the cask has the version.

- [x] **Step 2: Run; the rewritten g cases and the resumes fail.**

- [x] **Step 3: Implement.** Replace the recovery block with the validation the spec gives,
  joining problems with `; ` into the "resume validation" text and setting `land=1`. The
  untagged search is skipped when `land` is 1. In section 3, a resume with `land` set sets
  `committed=1` and calls `land_release_commit`. A resume without `land` sets `committed=1` after
  the tag checks. In `land_release_commit`'s reads, refuse an origin branch elsewhere, then a
  closed pull request (no open one), then a merged one, all before any write. Remove the
  `git push -q origin HEAD:main` recovery and its `pushed` flag.

- [x] **Step 4: Run outside the sandbox; all pass.** Revert check on g4, g5, g9, g10, g11 and f3's
  resume.

- [x] **Step 5: Commit** `Resume a release through its pull request`.

### Task 5: Changelog guards

**Depends on:** Task 4 (the reads in `land_release_commit`, the resume path)

**Files:**
- Modify: `scripts/release` (`land_release_commit`, the untagged search, before the build)
- Test: `scripts/tests/test-release-dry-run` (g13, group j, h6)

**Interfaces:**
- Consumes: `land_release_commit`, `pr_number`, `land`.
- Produces: `abandon_commands` (prints the indented abandon lines from the reads) and
  `check_release_section` (no arguments; uses `version`, `work/notes.md`; runs its own
  `git fetch -q origin main` and reads `FETCH_HEAD` right after it).

- [x] **Step 1: Write the failing tests.**
  - **g13:** `release_on_branch`, then a commit on origin's `main` that adds
    `- Later entry merged after the cut.` under `Unreleased`: refused with
    `origin/main changed CHANGELOG.md after the release commit was cut`, lists `git switch main`
    and `scripts/release`, and has no resume hint. No push; `gh` is not asked to write (the
    landing's `pr list` read is allowed).
  - **j1:** a new release, fast build, with `before-merge` pushing that same later entry onto the
    bare `main`. The run fails with `the $v section of CHANGELOG.md on origin/main differs`; no
    tag; no `release create`.
  - **j2:** the bare `main` is then corrected: the later entry moved back under `Unreleased`.
    `--version $v`, fast build, exits 0, tags the release commit and updates the cask.
  - **h6:** `on_main_with_section`, then a side commit merged into `main` with `--no-ff` and the
    subject `Release $v`, pushed. With HEAD detached at the release commit and the failing build,
    it goes on to the build, without `2 'Release`.

- [x] **Step 2: Run; g13, j1, j2 and h6 fail.**

- [x] **Step 3: Implement.** In `land_release_commit`, after the reads and their refusals:
  `git fetch -q origin main`, then if
  `! git diff --quiet "$release_commit^" FETCH_HEAD -- CHANGELOG.md`, set `committed=0` and die
  with the step-0 text and `abandon_commands`. The closed-PR refusal also prints
  `abandon_commands`. Add `--no-merges` to the untagged search's `git log`.
  `check_release_section` runs in a real run when the version is untagged, after landing or after
  the resume checks, before the build. It writes `git show FETCH_HEAD:CHANGELOG.md` to
  `$work/main-changelog.md`, runs `changelog.py notes "$version" --file` on it, and compares the
  result with `$work/notes.md` using `cmp -s`. On a difference it prints `diff -u` and dies.

- [x] **Step 4: Run outside the sandbox; all pass.** Revert check on each of the four.

- [x] **Step 5: Commit** `Refuse a release whose changelog section would differ on main`.

### Task 6: Tidy up after publishing; the dry run's last line

**Depends on:** Task 2 (`release_commit`, `branch`, `published`); Task 4 (resume paths reach it)

**Files:**
- Modify: `scripts/release` (end of section 7; the dry run's last line)
- Test: `scripts/tests/test-release-dry-run` (groups a, d; new group l)

**Interfaces:**
- Consumes: `release_commit`, `branch`, `version`, `published`.
- Produces: `tidy_up` (no arguments; returns non-zero after printing the tidy-up text when
  anything is left).

- [x] **Step 1: Write the failing tests.**
  - **d:** the clone ends on `main`, equal to origin's `main`. There is no `release/$v` locally
    or on origin. The output has `Released $v:`. d's retry of the finished release now starts
    with `git -C "$clone" checkout --quiet --detach "$R"`, because the resume runs from the
    release commit and tidy-up left the clone on `main`'s merge commit. The retry's existing
    "changes nothing" expects stay, and it ends on `main` again, level with origin. This is the
    Review Focus case of a resume from a detached HEAD.
  - **a:** the last line is the new dry-run line; no `release/*` branch locally or on origin.
  - **l1:** a new release, fast build, whose `before-merge` gives the clone's local `main` a
    commit origin lacks: `git -C "$clone" commit-tree main^{tree} -p main -m Local`, then
    `update-ref refs/heads/main`. Expectations: exits 1; `released $v, but could not tidy up`; no
    resume hint; the release and the cask are published.
  - **l2:** a new release, fast build, with a stub switch `after-release-create` (an executable
    the stub runs after `release create`) that moves origin's `release/<v>` to a new commit.
    Expectations: exits 1; reports `release/$v` left on origin; that branch still exists.

- [x] **Step 2: Run; d, a, l1 and l2 fail.**

- [x] **Step 3: Implement `tidy_up`** as the spec's three steps.
  - Delete the remote branch with
    `git push -q --force-with-lease="refs/heads/$branch:$release_commit" origin ":refs/heads/$branch"`,
    and only when `ls-remote` shows it at `release_commit`.
  - Delete the local branch with `git branch -q -d` when it points at `release_commit`.
  - Collect each problem as a line saying what is left and the command to finish it.
  - In section 7, set `published=1` and print `Released …`; then, when `tidy_up` fails, exit 1.

- [x] **Step 4: Run outside the sandbox; all pass.** Revert check on d's end state, l1 and l2.

- [x] **Step 5: Commit** `Return to main and delete the release branch after a release`.

### Task 7: Documentation

**Depends on:** Tasks 1–6

**Files:**
- Modify: `README.md` ("Releasing"), `AGENTS.md` (the Release command line; "Releases and CI"),
  `docs/superpowers/specs/2026-11-03-muninn-distribution-design.md` (one header line)

- [x] **Step 1: README.** Rewrite the "Releasing" paragraph. The release commit goes on
  `release/<version>`; the script opens its pull request, checks it changes only `CHANGELOG.md`,
  merges it as admin, tags the release commit and publishes. `gh` must use a login with the
  `repo` (or `public_repo`) scope on an admin account. A failed run leaves you on the release
  branch, and `--version <version>` resumes it. `--dry-run` creates nothing.
- [x] **Step 2: AGENTS.md.** The Release line becomes "(it needs the signing certificate and a
  `gh` login that can merge as admin; it pushes a release branch and merges its pull request,
  never `main`)". Under "Releases and CI", add
  `Release flow: docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md.`
- [x] **Step 3: Distribution spec.** Add under its `**Canonical for:**` line:
  `**Release flow:** superseded in part on 2026-11-16 by docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md (the release commit lands through a pull request).`
- [x] **Step 4:** `rg -n 'HEAD:main|pushes to .main' README.md AGENTS.md scripts/release` finds
  nothing but the tap push.
- [x] **Step 5: Commit** `Describe releasing through a pull request`.
