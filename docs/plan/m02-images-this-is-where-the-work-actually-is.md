# M2 — Images (this is where the work actually is)

← [plan index](./index.md) · [M1](./m01-terraform-foundation.md) · next [M3](./m03-workloads-as-kustomize-base-overlays.md)

No repo has a `Dockerfile`. Add one, plus a build workflow, to each app repo;
each pushes to Artifact Registry and the infra repo consumes digests.

- **Backend**: Python 3.13, `uv sync --frozen --no-dev`, and the **private
  `prompts/` submodule baked into the image at build time** using `PROMPTS_TOKEN`
  as a build secret. Start with `uvicorn main:app --host 0.0.0.0 --port $PORT`.
  Migrations move out of the build (M5).
- **Frontend**: `next build` then `next start`. `NEXT_PUBLIC_*` values are
  **inlined at build time**, so the image is environment-specific: CI passes
  `NEXT_PUBLIC_BACKEND_URL` / `NEXT_PUBLIC_SANDBOX_ORIGIN` as build args per
  environment. A staging image is not the prod image.
- **Sandbox**: Node runtime, `node_modules` and `esbuild`/`typescript` present at
  runtime, and the **`out/slides/harness.js` + `out/slides/vendor/*` artifacts
  baked into the image** (they are gitignored but read from disk on every
  request). The container needs a writable working directory: `/api/compile`
  writes temp files into it.
- Pushing needs no `gcloud`: CI trades its GitHub OIDC token for a federated
  workload-identity access token and `docker login`s to Artifact Registry with it.

**Done when:** three images sit in Artifact Registry, built by CI and not by hand,
and each one starts under a container runtime and answers its own first route
(`/health` for the backend, `/` for the frontend, `/slides/...` or
`/api/compile` for the sandbox).

**Status: all three images exist, each verified by its own workflow, and all three
are pinned in `overlays/prod` by digest.** The backend has a `Dockerfile`, a
`.dockerignore` and `build-image.yml`, and CI builds and pushes it: `main` → an
image tagged `sha-<commit>` in Artifact Registry, and production is pinned to one of
those digests (`dd32533a…`, from `fdb0b377`). Locally it was verified earlier: 48 s
warm build, starts as uid 10001, `/health` answers `{"status":"ok"}`, `prompts/` is
baked in, 17 routes, 495 MB.

For the two Node services, verification moved to CI deliberately: building an amd64
image of those dependency trees on this laptop means qemu plus a proxied `npm ci`,
which took longer than the pipeline it was meant to check. So the gate's second half
became a **smoke step** in each workflow — run the artifact, assert its first route.
That step paid for itself twice, in two bugs nothing else found:

- **`npm ci --omit=dev` ran the package's `prepare` hook, which calls `husky` — a
  devDependency that stage deliberately does not install.** Exit 127, on a command
  nobody asked for. The fix is `--ignore-scripts`; esbuild's postinstall is the one
  hook worth reasoning about, and the answer is that its binary arrives as a
  platform-specific optional dependency, which the smoke step then proves by
  compiling a component for real.
- **The working directory was not writable by the app user.** `COPY --chown` reaches
  the copied paths, not the directory `WORKDIR /app` created, so the sandbox
  started, routed `/api/compile`, and failed writing its own gate fixture:
  `EACCES: permission denied, open '/app/compile-gate-….cjs'`. A container that
  writes at runtime needs its *directory* writable, which is a different claim from
  "its files are owned by the app user".

The workflow order is now build → smoke → **publish**, so an artifact that never
answered a request never gets a tag; the one that had (`sha-d16da99…`, the sandbox
build with the unwritable directory) was deleted from the registry.

The first CI runs failed twice, in ways no local build could have taught:

- **The Workload Identity provider path is `projects/<PROJECT_NUMBER>/…`, not
  `projects/<PROJECT_ID>/…`.** STS answered `invalid_target` and a message saying
  the provider might not exist — it was present and active. The authoritative copy
  of that path is now `terraform output workload_identity_provider_names`, so the
  frontend and sandbox workflows can be written correctly the first time.
- **`docker/login-action` received an empty password** from
  `google-github-actions/auth`'s `access_token` output and failed with "Password
  required". The job mints the token with `gcloud auth print-access-token` from the
  credential file the auth step exports; if that is ever empty again, the error
  names the credential rather than a missing input.

Two things worth keeping straight, because both were nearly got wrong:

- **The pipeline builds images, not the laptop.** For a while production pointed at
  a hand-built amd64 image because CI was not working yet — that was a temporary
  state, it is over, and the three laptop-built tags were deleted from the registry
  so that production cannot point at something no pipeline produced. Local builds
  exist to *verify a Dockerfile*, which is a different thing (and the amd64
  requirement is a fact about the cluster, not a preference: `podman build
  --platform linux/amd64`).
- **`PROMPTS_TOKEN` is set** on `lo-tp/learn-anything-backend` (a read token for
  `lo-tp/learn-anything-prompts`, supplied by you). Without it the job stops at the
  submodule step and says so — which is the behaviour that made the missing secret
  obvious rather than mysterious.

The backend's build does not clone the private `prompts/` submodule itself — that
would need `git` in the image, i.e. an `apt` step, which on this network was most
of the build time. CI initialises the submodule from the pinned commit, the local
build uses the checked-out submodule, and the Dockerfile fails with a named reason
if it is missing.
