# Releasing through a pull request — design

**Date:** 2026-11-16
**Status:** In progress — PR #8
**Canonical for:** the release flow (`scripts/release` and `scripts/tests/test-release-dry-run`) of
Muninn, Hulder, Linger, Tafl and Skald. Their ports reference this document by repository and path.
**Supersedes in part:** the distribution design
(`docs/superpowers/specs/2026-11-03-muninn-distribution-design.md`): its anti-goal "The release
script pushes to `main` only its own release commit, plus the tag", and the recovery of an unpushed
release commit by a push to `main`.

## Why

Since 2026-11-14 the default branch of each of the five repositories changes only through a pull
request. Two GitHub rulesets hold it:

- `deletion`, `non_fast_forward` and `pull_request` (0 approvals, merge method `merge` only), with
  no bypass;
- `update` ("Restrict updates"), which only the Repository admin role bypasses, and only by
  merging a pull request. `gh` asks for that bypass with `gh pr merge --admin`.

A direct push of `main` is refused for everyone, the maintainer included. `scripts/release` pushes
its "Release <version>" commit straight to `main`, so every release now fails at that push.
Tafl's first release under the rules failed there on 2026-11-16 (GH013, "Changes must be made
through a pull request") and was finished by hand: a branch `release/<version>`, a pull request,
`gh pr merge --merge --admin --match-head-commit <sha>`, then `scripts/release --version <version>`
on the release commit (michaelrigart/tafl PR #3; the tag is on the release commit, the merge
commit's second parent).

## Goals

- One run of `scripts/release` from the maintainer's terminal cuts and finishes a release: it puts
  the release commit on a release branch, opens its pull request, checks it, merges it, tags the
  release commit, publishes, updates the cask, and ends on `main`, level with origin, with the
  release branch gone.
- `--version <version>` resumes from every point a run can stop.
- A run whose `gh` cannot merge stops before it creates anything, and says why.
- `--dry-run` creates nothing anywhere: no branch, commit, push, pull request, merge, tag or
  release. It still builds, verifies and packages.
- The five repositories keep one script, differing only in names.

## Non-goals

- Changing the rulesets, or the tap: `michaelrigart/homebrew-tap` has no rulesets, and the cask
  commit keeps going straight to its `main`.
- Waiting for CI on the release pull request. The rulesets require no status checks; CI runs on
  the pull request and on `main` as for any change, and nothing waits for it.
- Building before the merge (see Approaches).

## Anti-goals

- The script never pushes `main`, and needs no bypass other than the admin merge every change uses.
- It merges only a pull request it has checked: from this repository's `release/<version>` into
  `main`, its head the release commit, changing only `CHANGELOG.md`, and pinned to that commit with
  `--match-head-commit`.
- No force push. It deletes only its own release branch, only after the merge, and only where the
  branch still points at the release commit.

## Approaches

- **A. One command does it all** — chosen by the maintainer on 2026-11-16.
- **B. Two commands, the maintainer merging by hand in between** — rejected: two steps where one
  does, and a release half done between them.
- **C. Keep pushing `main`, with a bypass for the script** — rejected: anything holding the
  maintainer's git credentials could then update `main`, which is what the rules close.

Within A, building and verifying before the merge would leave less behind when a build fails. It is
not taken *(design call)*: the build would be of a commit not yet on `main`, and it adds a stop
point to resume from. The order stays as now: the release commit lands, then the build.

## Design

### Names

- Branch: `release/<version>`, created from `main` at origin's `main`.
- Release commit: "Release <version>", changing only `CHANGELOG.md`, as now.
- Pull request: base `main`, head `release/<version>`, title "Release <version>", body the
  version's changelog section; ready for review.
- Merge: `gh pr merge <number> --repo <repo> --merge --admin --match-head-commit <release commit>`,
  with GitHub's default merge commit message.
- Tag: the release commit, as Tafl's.

### Checks before anything is created

As now (clean tree, `origin`, `gh` signed in, signing identity, Xcode, xcodegen, the changelog,
the tag, `main` level with origin for a new release), plus:

1. **The token can merge.** `gh auth status --active --hostname github.com --json hosts` gives the
   active account's login, token source and scopes. The scopes must include `repo` or
   `public_repo`. Anything else is refused, a fine-grained token among them: `gh` cannot read its
   rights, and one without Contents write cannot merge.
2. **The account is an admin.** `gh api repos/<repo> --jq .permissions.admin` is `true`. This
   alone is not enough: GitHub reports the account's role whatever its token may do, so a token
   limited to pull requests still reads as admin. Hence check 1.
3. **New release:** `release/<version>` exists neither locally nor on origin.

The refusal names the login, the token's source and what is missing, and says to run from a shell
where `gh` uses a login with the `repo` scope (`gh auth login`, with `GH_TOKEN` unset).

A dry run makes checks 1 and 2 and prints a note instead of refusing: it refuses only what it needs
itself (signing identity, Xcode, xcodegen, `gh` signed in), as now.

### A new release

1. Checks.
2. `git switch -c release/<version>`, `scripts/changelog.py release`, commit "Release <version>".
   If the commit fails (a signing failure, say), the script puts back what it changed: it restores
   `CHANGELOG.md` if it is still exactly what the script wrote, switches back to `main` and deletes
   the branch it created, then says nothing was released and to run it again. If `CHANGELOG.md`
   was edited meanwhile, it changes nothing and says what is left. From the commit on, every
   failure prints the resume command.
3. **Land the release commit** (shared with resume, below): push the branch, open the pull
   request, check it, merge it, confirm the release commit is on origin's `main`.
4. Build, verify, package, tag, publish and update the cask, as now.
5. Tidy up (below), then print "Released <version>: <url>".

### Landing the release commit

With `R` the release commit (HEAD), after `git fetch origin main`:

0. **Changelog unchanged on `main`.** `CHANGELOG.md` must be the same on origin's `main` as on
   `R`'s parent. Otherwise refuse, before any push or merge: merging would file the newer entries
   under this version, although neither the build nor the release notes have them, and Git merges
   such a change without a conflict. The refusal gives the commands to abandon this version (close
   its pull request if there is one, delete `release/<version>` on origin and locally, switch to
   `main` and fast-forward it) and says to cut a new release.
1. **Branch on origin.** `release/<version>` absent: push `R` to it
   (`git push origin <R>:refs/heads/release/<version>`, no upstream). At `R`: nothing to do.
   Elsewhere: refuse; the script does not merge what it did not cut.
2. **Pull request.** `gh pr list --repo <repo> --head release/<version> --base main --state all`,
   ignoring cross-repository pull requests:
   - one open: use it;
   - none open, one closed unmerged: refuse, saying to reopen it to resume (the script does not
     overrule a close);
   - none open, one merged: refuse; that contradicts `R` not being on `main`;
   - none: `gh pr create`.
3. **Check** with `gh pr view`: open, base `main`, not cross-repository, head `R`, and its files
   exactly `CHANGELOG.md`. A failure names what differs and says the pull request stays open and
   unmerged.
4. **Merge** as under Names. A refusal shows `gh`'s message and stops there.
5. `git fetch origin main`: `R` must now be an ancestor of origin's `main`.

**Before the tag,** in every run that is about to tag, whether it merged or resumes an untagged
release: the version's section of `CHANGELOG.md` on origin's `main` must equal its section on `R`
(`scripts/changelog.py notes <version>` on both). GitHub's merge pins the head, not the base, so a
change merged into `main` between step 0 and step 4 can still put entries under this version that
the release lacks. Step 0 avoids that in the usual case; this check catches the rest. On a mismatch
the run stops before tagging, shows both sections, and says to correct `CHANGELOG.md` on `main`
through a pull request, then resume. A tagged release is not checked again: later edits of its
section on `main` are allowed.

### Resume

Resume starts from HEAD, as now: a failed run leaves HEAD on `release/<version>` at the release
commit, and the script does not move it until it tidies up. Elsewhere, the refusal says which
commit to check out.

| A run stopped | What is left | `--version <version>` |
|---|---|---|
| after the commit, before the push | local `release/<version>` at `R` | lands `R` from step 1, then continues |
| after the push, before the pull request | the branch on origin | lands from step 2 |
| with the pull request open | an open pull request | uses it: checks, merges, continues |
| after the merge, before the tag | `R` on `main`, untagged | as now: `R` must be the one "Release <version>" commit on origin's `main`; then the section check before the tag |
| after the tag (release, asset, cask) | the tag, maybe a release | as now: each step is skipped if done |
| at tidy-up | everything published | not needed: the message gives the commands |
| any of the first three, then `main` changed `CHANGELOG.md` | as above | refuses for good, with the commands to abandon the version |

When HEAD is not on origin's `main`, it must be a release commit that can land: message "Release
<version>", one parent, that parent on origin's `main`, changing `CHANGELOG.md` and nothing else.
The checks are those of today's recovery, with one change: the parent no longer has to be the tip
of origin's `main` *(design call)*. A merge commit absorbs a `main` that moved, so the release is
still exactly the commit that was cut, as long as the move left `CHANGELOG.md` alone (landing,
step 0). A move that touched it ends this version: the run refuses with the commands to abandon it,
and the next release is cut afresh.

The search for the one "Release <version>" commit on origin's `main` skips merge commits
(`--no-merges`), so a repository that titles merge commits after the pull request does not count
two.

The recovery path that pushed an unpushed release commit to `main` goes: that commit lands through
its pull request.

### What a failure says

- Before the release commit: nothing is left, the refusal says why (as now); a failed commit
  is undone as described under "A new release".
- From the release commit on: each failure names where it stopped and ends with
  `resume with: scripts/release --version <version>`.
- A rejected push of the release branch no longer rolls the commit back *(design call)*: the commit
  and its local branch stay, and the retry is the resume. Today's `reset --keep` and its
  "CHANGELOG.md has local edits" branch go with it.
- Tidy-up failures (below) do not ask for a resume.

### Tidy-up

After publishing, in every real run, resumes included:

1. `git fetch origin main`, `git switch main`, then `git merge --ff-only` to origin's `main`. A
   local `main` with commits origin's lacks is left as it is.
2. Delete the local `release/<version>` if it points at `R`.
3. Delete `release/<version>` on origin if it points at `R`, with a lease on `R`
   (`git push --force-with-lease=refs/heads/release/<version>:<R> origin :refs/heads/release/<version>`),
   so a branch moved in the meantime is not deleted; a branch already gone is fine.

A step that fails, or finds a branch pointing elsewhere, is reported with the command to finish by
hand; the run then exits 1 with "released <version>, but …", and no resume hint. A dry run does no
tidy-up.

### Dry run

It builds, verifies and packages as now, never switches branch, and writes nothing to git or
GitHub. Its last line becomes "Dry run: nothing committed, branched, pushed, merged, tagged or
published."

### Tests

`scripts/tests/test-release-dry-run` stays the one suite. Each new or changed case fails with its
code reverted.

- **The `gh` stub** gains `auth status --json` (scopes and token source from the scenario), `api
  repos/<repo>` (admin or not), and `pr create`, `pr list`, `pr view` and `pr merge` over pull
  requests it keeps in the scenario's stub folder. `pr merge` checks `--merge`, `--admin` and that
  `--match-head-commit` is the head, then merges in the scenario's bare origin as GitHub would: a
  merge commit with the release commit as second parent. Switches make `pr create` or `pr merge`
  fail, or `pr view` report other files or another head.
- **A `date` stub** fixes the version for the case where `release/<version>` already exists.
- **Cases,** replacing those that assert a push of `main` (d, e, f, f2, f3, g1 to g9):
  - a new release lands through a pull request: one pull request, base `main`, head the release
    commit, merged with `--merge --admin --match-head-commit`; origin's `main` is a merge commit
    whose second parent is the release commit; the tag is on the release commit; it ends on
    `main` level with origin, without `release/<version>` locally or on origin; resuming it
    afterwards changes nothing;
  - refusals before anything is created: a token without `repo`/`public_repo` (no commit, no
    branch, nothing on origin, no `gh` write), an account that is not an admin, an existing
    `release/<version>`;
  - the dry run notes a token that cannot merge and still exits 0, with no branch anywhere;
  - every stop point of the table, each resumed to the end: a rejected branch push, a failed
    `pr create`, a failed `pr merge` (the resume uses the open pull request, creating no second),
    a build failure after the merge;
  - the pull request check refuses other files and another head, merging nothing;
  - origin's `release/<version>` elsewhere, a closed pull request, a cross-repository one: refused
    or ignored as above;
  - today's resume validations (another file, another message, two commits, an empty commit, a
    tag elsewhere, the dry run) kept against the new path; a `main` that moved since the release
    commit without touching `CHANGELOG.md` lands through a merge commit; one that added a
    changelog entry is refused before any push or merge, with the commands to abandon the version;
  - a merge commit titled "Release <version>" does not count as a second release commit;
  - a changelog entry merged into `main` between the check and the merge (the stub's `pr merge`
    adds one first) stops the run before the tag, with nothing tagged or published; after `main`'s
    changelog is corrected, the resume tags and publishes;
  - a failing release commit (a failing `pre-commit` hook) leaves `main` checked out, no
    `release/<version>`, and `CHANGELOG.md` unchanged; with `CHANGELOG.md` edited by the hook, it
    leaves things as they are and says so;
  - tidy-up: a local `main` with an extra commit is left and reported, exit 1 without a resume
    hint.
- The unchanged groups (b, c, d2, h, i, the zap and `.noindex` checks) stay as they are.

### Documentation

- README, "Releasing": the release commit goes through a pull request that the script opens and
  merges as admin; `gh` must use a login with the `repo` scope of an admin account; where a failed
  run leaves things and how `--version` resumes.
- `AGENTS.md`: the release line says it pushes a release branch and merges its pull request, and
  the distribution pointer gains this spec.
- The distribution spec gains one line under its header pointing here for the release flow; its
  text is not rewritten.
- No `CHANGELOG.md` entry: nothing changes for users.

## Ports

- Hulder, Linger, Tafl and Skald each carry the same change on a branch `fix/release-via-pr`. Each port
  records a short spec in its own repository that names this one as canonical, by forge link
  (`https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`)
  and path, and lists only its own differences; and a plan of its own.
- Allowed differences: names (repository, app, zip, cask, tap commit message, temp folders) and
  Muninn's zap cases, which stay Muninn's.
- **Linger** has the older release script that the distribution design left alone (its non-goal
  "Bringing Linger's release script … up to Hulder's newer versions"). It lacks the recovery and
  the untagged-resume guard this change rewrites, the handling of incomplete assets and the
  tap's downgrade guard. **Decided by the maintainer on 2026-11-16:** all release scripts resemble
  each other as much as possible, so Linger takes the shared script and test whole, renamed,
  without the zap cases, together with anything the shared script calls that Linger's lacks. That
  lifts the non-goal for the release script. Rejected: porting only the pull-request flow onto
  Linger's script, which would keep two scripts.
- **Skald**, added by the maintainer on 2026-11-16, has the shared script and test, but only on
  `feat/skald-v1`, whose pull request into `main` is still open. Its port branches from
  `feat/skald-v1` and its pull request targets that branch, so the fix reaches `main` with
  Skald v1.
- All five pull requests are opened before any is merged; Muninn's merges first.

## Residual

- `gh pr merge` straight after `gh pr create` may meet a pull request whose mergeability GitHub has
  not computed yet. That stops at "pull request open", and the resume merges it. Tafl's manual
  release did not meet it.
- The scope check is a proxy: a fine-grained token with Contents write could merge but is
  refused, because its rights cannot be read.
- The script cannot tell a deliberate close of the pull request from an accidental one; it refuses
  either way.
- A change merged into `main` in the seconds between the changelog check and the merge is caught
  before the tag, not prevented: `main`'s changelog then needs a correcting pull request.

## Acceptance

1. `scripts/tests/test-release-dry-run` passes on the maintainer's Mac, every case.
2. `scripts/release --dry-run` passes there and creates nothing on git or GitHub.
3. After the merge, the next real release, run by the maintainer, lands, tags and publishes in one
   run and ends on `main` level with origin, with no `release/<version>` left.
