# Learn Anything — Infrastructure

The context in which Learn Anything runs. It owns the shape of the environment
the product's services occupy: where they are hosted, how they are reached, what
they are allowed to see of each other, and what happens to the data.

## Language

**Surface**:
One of the named public entry points of the product, each with its own hostname.
The set of surfaces is small, fixed, and declared here; anything not on it is not
reachable from a browser.
_Avoid_: endpoint, route, URL, deployment.

**Public surface**:
The single load-balanced entry point through which every browser request arrives.
Everything a service offers to other services stays behind it.
_Avoid_: gateway, edge, front door.

**Internal call**:
A request between two of our own services. It never traverses a surface, and it
carries the identity of the calling service.
_Avoid_: API call, back-end call, private API.

**Service principal**:
A non-human caller of the backend that is not a signed-in User: the Sandbox,
which fetches shared content on its own behalf. A distinct principal from the
User, scoped to internal calls only.
_Avoid_: service account, API key, client, bot.

**Sandbox** (the service):
The running service that serves learning content to an embedded frame and
compiles content on request for the backend. It is a deployed part of production;
the claim that it is only a development host is stale.
_Avoid_: host app, dev server, preview.

**Foreign record**:
A DNS record under a domain we share with something we do not operate. We
preserve it through any change and never edit it.
_Avoid_: legacy record, someone else's problem.

**Cutover**:
The moment a surface stops being served by the previous host and starts being
served by this one. The previous host is retired only after a cutover has been
observed to hold.
_Avoid_: migration, launch, switch.

**Turn-off order**:
The documented order in which services are stopped when spend runs ahead of the
budget — the deliberate, pre-chosen sequence that keeps the product partly
alive rather than all of it dead.
_Avoid_: kill list, degradation mode.

**Publish**:
To send a built image to Artifact Registry under its `sha-<commit>` tag. A build
workflow publishes only *after* that image has passed its smoke test, so a tag in
the registry is evidence the artifact answered a request.
_Avoid_: upload, ship, push-to-cloud (the tag is pushed; the image is published).

**Smoke test** (of an image):
The CI step that runs the built artifact and asserts its first route — `/health`,
the redirect to a sign-in page, `/api/compile`. It is the image's contract written
as a step, not a manual check someone performs afterwards: a build that succeeds
proves the compiler ran, not that the image can serve anything.
_Avoid_: health check (that is the Kubernetes probe), sanity check, e2e.

**Pin** (noun and verb):
The exact image an environment runs — a digest, written in that overlay's `images:`
block, named as the base names it. The tag and build date live in the comment
beside it, because a bare digest is a fact no human can look up. The pin block is
the record of what production runs, and `git diff` of it is the approval. A pin is
something only an apply can change, which is why a pipeline proposes one as a pull
request instead of moving a tag.
_Avoid_: latest, version (a version is what the app reports; a pin is what the
cluster runs), tag (a tag can move under a deploy; a pin cannot).

**Replica floor**:
The minimum number of replicas a tier is pinned to in a given environment. It is a
deployment decision, and it is the unit in which Autopilot cost is paid — so
"make it cheaper" and "make it available" are the same number, written in two
places. The production floor for the three application tiers is 1
(`manifests/overlays/prod/replica-floor.yaml`).
_Avoid_: warm standby, always-on (that is the consequence, not the setting).

**Billing floor**:
Autopilot's per-pod minimum — 0.25 vCPU and 1 GiB — charged whether the container
asks for that or less. Not the same thing as a replica floor: lowering requests
below the billing floor saves nothing, which is why an idle-looking pod is not a
cheap pod.
_Avoid_: pod size, request (the request is what the container asks for; the floor
is what the platform charges).
