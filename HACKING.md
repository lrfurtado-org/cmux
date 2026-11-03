# Hacking on this fork

Notes for `lrfurtado/cmux`, a fork of `manaflow-ai/cmux`. They cover one-off
DEV builds made in GitHub Actions, so you don't need a local Xcode setup.

## How the fork is set up

The fork's `main` has only three workflows. The other upstream workflows were
deleted in commit `4d0d164149`.

| Workflow | Purpose |
| --- | --- |
| `.github/workflows/reload-build.yml` | Builds a tagged DEV app (`cmux DEV <tag>`) from any ref and uploads it as an artifact. Runs only on demand (`workflow_dispatch`). |
| `.github/workflows/resolve-dispatch-ref.yml` | Called by `reload-build.yml` to resolve the `ref` input to a commit. |
| `.github/workflows/reload-build-retry.yml` | Fork-only. Reruns a `reload-build` whose macOS job never got a runner (see below). |

Nothing runs on push or pull request. The only scheduled job is the retry
check, which does nothing unless a build is waiting for a runner. None of
them need secrets. Because the repo owner isn't `manaflow-ai`, jobs run on GitHub-hosted
runners (`macos-26`, `ubuntu-24.04`).

GitHub only lets you dispatch workflows that exist on the default branch.
Keep these files on `main`. Your feature branches don't need them.

## Prerequisites

- The `gh` CLI, logged in with access to `lrfurtado/cmux` (`gh auth status`).
- Actions enabled on the fork. Do this once at
  <https://github.com/lrfurtado/cmux/actions>. Check it with:

  ```bash
  gh workflow list --repo lrfurtado/cmux
  # reload-build                  active  ...
  # Resolve manual workflow ref   active  ...
  ```

## Build a branch

1. Commit and push the branch you want to build. The build runs on the pushed
   commit, not on your working tree.

   ```bash
   git push -u origin <branch>
   ```

2. Start the build. Dispatch on `main` and pass your branch as `ref`. Build
   caches are scoped to the dispatch ref, so dispatching on `main` lets later
   runs reuse them.

   ```bash
   gh workflow run reload-build.yml --repo lrfurtado/cmux --ref main \
     -f tag=<tag> \
     -f ref=<branch> \
     -f platform=macos \
     -f backend_mode=local \
     -f nonce=<tag>-1
   ```

   Inputs:

   | Input | Value |
   | --- | --- |
   | `tag` | Short name for the build, such as `ignore-mdm`. The app becomes `cmux DEV <tag>`, with bundle ID `com.cmuxterm.app.debug.<tag>`. Use lowercase letters, digits and `-`. |
   | `ref` | A branch, tag or SHA. If empty, the dispatch ref (`main`) is built. |
   | `platform` | `macos`, or `ios` for an iOS simulator archive. |
   | `backend_mode` | `local`. `remote` needs a registered private backend URL (`backend_url`), which only the upstream team has. |
   | `nonce` | Optional. It appears in the run title (`reload-build <tag> <platform> <nonce>`), which helps you find the run. |
   | `runner` | Leave it as `auto`. On this fork it resolves to `macos-26`. |

3. Find the run and follow it.

   ```bash
   gh run list --repo lrfurtado/cmux --workflow reload-build.yml --limit 3
   gh run watch <run-id> --repo lrfurtado/cmux
   ```

   GitHub-hosted macOS runners can sit in the queue for a while. A cold build,
   with no SPM or DerivedData cache, takes much longer than a later one.

### When no macOS runner is free

Hosted `macos-26` runners are often at capacity. If no runner picks up the
`build` job within about 15 minutes, GitHub cancels it with "The job was not
acquired by Runner of type hosted even after multiple attempts". No workflow
setting changes that wait. `timeout-minutes` only limits how long a job runs
after it starts.

`.github/workflows/reload-build-retry.yml` handles this. Every 20 minutes it
looks at the latest `reload-build` run. If the build job was cancelled before
running any step, it reruns the failed jobs, up to 40 attempts. It never
retries a build that started and then failed. You can also run it by hand:

```bash
gh workflow run reload-build-retry.yml --repo lrfurtado/cmux --ref main
# or rerun a run yourself:
gh run rerun <run-id> --repo lrfurtado/cmux --failed
```

GitHub may delay scheduled runs, and it pauses schedules after 60 days with
no repository activity.

## Download and run the app

The artifact is named `reload-<tag>-macos` and holds `app.zip`. It's kept for
only 1 day, so download it soon after the run finishes.

```bash
mkdir -p ~/cmux-builds/<tag> && cd ~/cmux-builds/<tag>
gh run download <run-id> --repo lrfurtado/cmux -n reload-<tag>-macos
ditto -x -k app.zip .
open -n "cmux DEV <tag>.app"
```

If you downloaded the zip in a browser instead of with `gh`, remove the
quarantine flag before opening it:

```bash
xattr -dr com.apple.quarantine "cmux DEV <tag>.app"
```

A tagged DEV build has its own bundle ID, socket and settings domain, so it
runs next to your installed `/Applications/cmux.app` without touching it.
Don't use a Release build or the `com.cmuxterm.app` bundle ID for testing.

## Testing with MDM policies ignored

On an MDM-enrolled Mac, DEV builds also follow profiles that target
`com.cmuxterm.app`. To make a DEV build ignore them, do one of these:

- Launch with the flag:

  ```bash
  open -n "cmux DEV <tag>.app" --args --ignore-managed-policy
  ```

- Or set the key in `~/.config/cmux/cmux.json`. Every DEV build reads this
  file, so the setting applies to all of them:

  ```json
  { "app": { "ignoreManagedPolicy": true } }
  ```

The setting is read once at launch. Stable, nightly, rc and staging builds
ignore both the flag and the key. While the bypass is on, the app logs a
warning, which you can check with:

```bash
log show --last 5m --predicate 'subsystem == "com.cmuxterm.app" && category == "ManagedPolicy"'
```

The bundled `cmux` CLI still enforces its own checks (for example
`cmux vm push`/`pull` under `DisableFileTransfer`).

## Syncing main from upstream

Upstream still has its full set of workflows, so merging upstream `main` will
conflict in `.github/workflows/`. Keep the deletions:

```bash
git remote add upstream https://github.com/manaflow-ai/cmux.git   # once
git switch main
git fetch upstream
git merge upstream/main
# Remove every workflow upstream added or changed, except the ones we keep.
git ls-files .github/workflows | grep -vxE '\.github/workflows/(reload-build|reload-build-retry|resolve-dispatch-ref)\.yml' \
  | xargs -r git rm -q
git commit
git push origin main
```

If upstream changes `reload-build.yml` or `resolve-dispatch-ref.yml`, take
upstream's version of both.

Keep feature branches based on upstream code, not on fork-only commits, so
they can still go upstream as PRs without the workflow deletions.
