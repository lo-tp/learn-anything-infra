# The merge into `release` is the approval

Pushing to an application repository's `release` branch now delivers end to end: the
image is built, smoke-tested, published, pinned in
`manifests/overlays/prod/kustomization.yaml`, and deployed by
`.github/workflows/deliver.yml`. **The pull request that used to sit between
"published" and "shipped" is gone**, and the decision that used to live in it —
should this reach production? — is the merge of `main` into `release`. That merge is
the one human act in the path, and `release` is protected (merge-only, no
force-push, `check` green) so it can only mean promotion.

Nothing about the *evidence* required to ship got weaker. A commit that reaches
production has passed: lint, typecheck and unit tests on `main`; the same checks
again on `release`; an image build; a smoke step that runs the artifact and asserts
its first route; a migration Job that either succeeds or stops the deploy; a rollout
gated by readiness probes; a `kubectl diff` that must come back empty; and a curl of
the public surfaces from outside the cluster. What changed is *when a human is in the
loop* — before the change, on a diff of the `images:` block — rather than whether
the change was tested.

## Considered options

- **Keep the pin pull request; merge it by hand.** Rejected on what it cost in
  practice: a gate that is always approved is a ritual, and this one was already
  failing at its own first step — the repository setting "Allow GitHub Actions to
  create and approve pull requests" was off, so the pin workflow could not open the
  pull request it existed to open, and the real act had become `make pin-images`
  plus a commit by hand. A gate that is bypassed routinely describes the process,
  not the intent.
- **Publish images from `main` as well, and let a human promote afterwards.**
  Rejected because it puts the decision in two places: `main` would produce
  artifacts that may never be intended for production, and "newest published image"
  would stop meaning "newest approved one".
- **Manual approval via a protected GitHub environment.** Kept as a one-line option
  rather than the design: `deploy.yml` could require an environment review, which
  would put the human back in front of the deploy without a pull request. It is
  refused for now for the same reason as the pin PR — the decision is already made
  by the merge — but it is the cheapest way to put a brake back if a bad release
  ever needs one.
- **Deploy on every push to any branch.** Rejected: it makes reachability a function
  of activity instead of intent, and it would let an experiment reach production.

## Consequences

- The record moves. `git diff` of the `images:` block is still what production runs,
  but it is now authored by the deploy bot as a commit on `main` that *names the run
  that built it*. Reading the record is a `git show`, not a review.
- **Rollback is a git act, not a dashboard act**: `git revert` the pin commit, push
  it, and `deploy.yml` runs again against the previous digests. Migrations are
  forward-only, so a rollback that crosses a migration is a fix-forward, not a
  revert — the same constraint as before, now with less ceremony around it.
- Deploys become more frequent and smaller, which is the point: a change that
  reaches production alone is a change whose cause is known.
- The scheduled reconciliation run stays in the configuration as a safety net, and is
  **not claimed as behaviour**: no `schedule`-event run exists in this repository's
  history (checked 2026-10-08 — 16 `push`, 7 `workflow_dispatch`, zero `schedule`,
  including the daily pin cron that preceded this workflow, which also never fired).
  Until one appears, the hand-off dispatch is the only trigger known to work, and the
  fallback is a person: `gh workflow run deliver.yml`, or `make pin-images` followed by
  `make deploy` from a laptop.
- One path to production, not two: the pin job *dispatches* `deploy.yml` explicitly,
  because a push made with `GITHUB_TOKEN` starts no workflows. The laptop path
  (`make deploy`) still exists and does the identical thing through a different
  identity.
- **One credential exists because of a GitHub limit, not a preference:** each
  application repository holds a repository secret, `DELIVERY_TOKEN` — a
  fine-grained PAT whose only permission is starting workflows in this repository.
  It is there because `workflow_run` does not cross repositories: that was tested
  (a completed run in another repository produced nothing here, on `release` and on
  the default branch alike), not read. Without the secret the application workflow
  warns and exits successfully rather than failing a build whose image already
  shipped — but then nothing delivers it by itself. **The token is load-bearing, not
  an optimisation**, which is the difference between this note and the first draft of
  it: the schedule it leans on has never run.
- Two deliveries cannot overlap: both jobs hold a `concurrency` group. A rejected
  pin push means `main` moved while the job ran, and the job replays its decision
  rather than merging it.
