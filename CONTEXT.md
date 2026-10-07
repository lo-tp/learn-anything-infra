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
