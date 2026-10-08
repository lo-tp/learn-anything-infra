# M7 — Secrets to pods

← [plan index](./index.md) · [M6](./m06-one-public-surface-three-hostnames-real-certificates.md) · next [M8](./m08-prove-it-then-let-it-use-the-real-llm.md)

Terraform owns which secrets exist; CI reads them from Secret Manager and applies
rendered `Secret` objects at deploy time. No always-on sync controller. Required:
`JWT_SECRET` (backend + frontend, one value), `SANDBOX_SERVICE_TOKEN` (backend +
sandbox, one value, both ends fail secure), the DB credential, and
`OPENAI_API_KEY` / `OPENAI_BASE_URL` / `LLM_MODEL`. `PROMPTS_TOKEN` stays
build-time only and never reaches a pod.

**Done when:** no secret value appears in this repo or in any image, and both
shared pairs match across services (an `MISMATCH` here shows up as 401s from
`/slides/{id}` and 401 sign-ins, so verify it in [M8](./m08-prove-it-then-let-it-use-the-real-llm.md)).

**Status: done (2026-10-08, ~00:50 local), including the first real CI apply.**

- `.github/workflows/deploy.yml` is the pipeline form of `make deploy`: WIF →
  `deploy-ci` → cluster credentials through application default credentials →
  render the Secret objects → `scripts/deploy.sh` (migrations, workloads, rollout)
  → fail if `kubectl diff` against the rendered overlay is not empty. No secret is
  stored in GitHub; there is no sync controller; the reconcile happens at deploy
  time, by whoever deploys.
  The first green run (54s, on the push that added it) says the parts in its own
  log: `control plane reachable as deploy-ci@learn-anything-510905…`, four Secrets
  `unchanged` with the M8 entries named as skipped, `migration Job
  migrate-4cf283528e5f-4428bd already completed; not re-running it`, three
  deployments `unchanged`, then `no drift` and the three digests it is serving.
  An apply that changed nothing, performed by a pipeline: the right outcome for a
  push that changed no manifest.
- `.github/workflows/pin-image.yml` closes the loop M6 left open: the registry is
  asked what it holds (newest `sha-<commit>` version, which in those repositories
  means built by CI **and smoke-passed**, because publish runs after the smoke
  step), and a newer one becomes a pull request on one reused branch. It applies
  nothing. Merging, in the UI, is what deploys. Its steady-state path is the one
  that has run: authenticate, compare, find the pins current, say so, open nothing.
  **The pull-request path is unexercised** — it needs a newer published image, and
  inventing one to test it would have been a fake pin in the registry. It gets
  tested by the first real one, and the failure mode if it is broken is visible:
  the job says which branch it took.
- Both halves of the Done-when are now commands. `make secrets-check` compares the
  renderer's mapping against `terraform output secret_names` — 6/6 agree. Live
  output of `make secret-hygiene`: every Secret Manager entry absent from all four
  repositories **and from the filesystem of the running images**, and
  `JWT_SECRET` (backend/frontend) and `SANDBOX_SERVICE_TOKEN` (backend/sandbox)
  equal to each other and to Secret Manager, as hashes of what the containers hold.
  The three M8 entries report as empty/placeholder, which is what they are.

What it took, in the order the failures arrived:

- **A pipeline can hold a GKE credential with no gcloud login.** The plugin form
  works — `gke-gcloud-auth-plugin --use_application_default_credentials=true`, the
  *same* flag that sidesteps the `private_key_id` crash AGENTS.md documents, because
  there ADC really is a service-account key. Verified before writing the workflow:
  `deploy-ci` reads the cluster, dry-run-applies the whole prod overlay, and reads
  Secret Manager. The test key was then deleted.
- **GitHub runners have no `gke-gcloud-auth-plugin` and cannot be given one that
  way.** The component manager is disabled in the image's gcloud, and the package it
  names (`google-cloud-cli-gke-gcloud-auth-plugin`) is not in any configured apt
  repository — `Unable to locate package`, twice, in six seconds each. So the
  kubeconfig carries a token: `scripts/ci-kubeconfig.sh` writes either the exec form
  (plugin present, tokens minted on demand) or the token form (an access token
  minted once, which outlives the job that uses it). Both forms are tested here, the
  second by moving the laptop's plugin binary aside.
- **The runner's gcloud has its component manager disabled**, and names the fix
  verbatim: `sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin`. Three
  pushes to learn, because my first version hid the tool's output.
- **Two YAML traps in workflow files, both rejected before any step ran** — a run
  that fails in 0 seconds with no log at all. An unquoted step name containing
  `Deploy: ` is a mapping inside a mapping; a multi-line commit message inside a
  `run: |` block scalar has lines starting at column 1, which ends the scalar.
  Parse the file (`ruby -ryaml -e …`) before pushing it: GitHub's own report of
  these two mistakes is a failed run with no log and no reason.
- **Roles belong to the service account, not to a repository.** `deploy-ci` already
  held `container.developer` and `secretmanager.secretAccessor` (granted in [M1](./m01-terraform-foundation.md) for
  the deploy step that did not exist yet), so adding this repository to the WIF
  list gave it those powers instantly — and the three image pipelines can now apply
  workloads too. `image_repositories` is renamed `ci_repositories` to stop the
  variable implying a scope the grant does not have.
- **gcloud exits non-zero when a Secret payload is empty**, so `set -e` ended the
  renderer before it could say which kind of empty it was. `OPENAI_BASE_URL` and
  `LLM_MODEL` are now *skipped while empty* rather than rendered as `""`: the
  backend passes an empty base URL to the client, which is a worse failure than an
  unset variable.
- **One key entry on `deploy-ci` refuses to be deleted**: `GET` returns 200, `DELETE`
  and `disable` return `NOT_FOUND`, repeatedly. Its private half is held by nothing
  in this project (grep over the credential locations finds no match), so nothing
  can authenticate with it. Recorded rather than chased; worth one look at the M10
  checkpoint to confirm it is gone.

Deferred to M8 by design: `openai-api-key` still holds its placeholder and
`openai-base-url` / `llm-model` are empty. M7's renderer path for them exists and
is exercised; the values are the human step at the start of M8, after which
`make secret-hygiene` is re-run — the pair checks are the part M8's own
"Done when" depends on.
