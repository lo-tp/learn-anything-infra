# M6 — One public surface, three hostnames, real certificates

← [plan index](./index.md) · [M5](./m05-migrations-as-a-gate.md) · next [M7](./m07-secrets-to-pods.md)

One global Application Load Balancer, one static IP, one Google-managed
certificate covering `learn.`/`api.`/`sandbox.lotp.xyz` (plus the staging hosts).
Ingress routes by Host header. The sandbox's `/api/compile` is **never routed**:
it stays a ClusterIP Service the backend calls directly
([CONTEXT.md → public surface](../../CONTEXT.md)).

Then the records. **The zone never moves and the nameservers are never changed**:
`blog.lotp.xyz` and everything else you already have stay exactly where they are.
The set of records we need lives in this repo as a variable, and
`terraform output dns_records` prints it as rows to type into Namecheap —
A records for `learn.`, `api.`, `sandbox.` and the staging hosts, all to the one
static IP. Google issues the certificate only once those records resolve, so this
is a gate, not a formality.

**Done when:** `curl -I https://` works on all three hosts with a valid cert, the
sign-in cookie works from `learn.` to `api.` (same-site, cross-origin), the
records typed into Namecheap match `terraform output dns_records` line for line,
and `https://blog.lotp.xyz` still serves from GitHub Pages — unchanged because
nothing near it was touched.

**Status: done, and every clause of that gate was executed (2026-10-08, ~00:45
local).** Three A records at TTL 300 point at the reserved address; the managed
certificate is `Active` and its SANs cover all three names; `make dns-check`
exits 0. Through the public surface: `http://api.lotp.xyz/health` → 301 → `https`
→ 200; `learn.` sends an anonymous visitor to `/en/login?next=%2F` and gives a
signed-in one **200 at `/en`** with real UI text; `sandbox./slides/x` is 200 with
`Sec-Fetch-Dest: iframe` and 403 without (that app's own gate, working on the
public host); `sandbox./api/compile` is a URL-map miss, which is the "never
routed" rule holding; `blog.lotp.xyz` is untouched GitHub Pages. The session
crosses surfaces because the backend now writes the cookie for `.lotp.xyz`
(`COOKIE_DOMAIN`), verified end to end: `#HttpOnly_.lotp.xyz` in the jar,
`/auth/me` → the user, signed-in `GET /` → 200.

What it took, none of it visible in a `kubectl get ingress`:

- **Programming the balancer took ~35 minutes, and the reason was in the
  events, not the status.** `Error syncing to GCP: … networkEndpointGroups/
  k8s1-…-kube-system-default-http-backend … was not found`: the controller was
  waiting on the NEG for GKE's own catch-all backend. It fixed itself by creating
  that NEG; `ADDRESS: <empty>` told me nothing.
- **`ingress.kubernetes.io/force-ssl-redirect` is an nginx-ingress spelling; this
  controller ignores it.** The URL map carried no `httpsRedirect` with it in
  place. `spec.tls` without a `secretName` is worse than useless — it produced
  `Error syncing to GCP: secret "" does not exist`. The mechanism that works is a
  **FrontendConfig** with `redirectToHttps.enabled: true`, attached by annotation;
  the redirect then appears on the target HTTP proxy (not in the URL map's path
  matchers, so checking there misleads you).
- **The load balancer's health check is derived once, at NEG creation — and
  afterwards only a BackendConfig moves it.** GKE generates the check for a NEG
  **from the workload's readiness probe** where it can — one backend's check says
  so in its description — and a default connect check otherwise. M6's three
  BackendConfigs, correctly annotated and present before the balancer was created,
  left the generated checks as they were, and the probes were the honest single
  definition: the frontend's readiness path was `/en/login` rather than `/` (the
  root is a redirect; passing on a 307 proves a socket, not a page), and the
  sandbox's is HTTP on a static page instead of TCP.
  Both clauses were found incomplete on 2026-10-09 (#158): the frontend deleted
  its sign-in page, the probe moved to `/api/health`, and the check created on
  2026-10-07 kept asking for `/en/login` — the probe is *not* the definition
  after creation, which is how the pods read Ready while every URL 502'd. A
  BackendConfig attached to the Service by port (`frontend-health`) updated the
  existing check's `requestPath` within seconds. The definition is now declared
  in the manifest rather than inferred: `frontend-health` in
  `manifests/base/frontend.yaml`, paired with the readiness probe above it and
  with `app/api/health/route.ts` in the frontend repository — three places that
  are one fact about one URL.
- **A woken tier answers 502 for 1–4 minutes after its pod is Ready.** The NEG
  attaches to the backend service after the endpoint exists. Twice observed (a
  rollout, then a scale-up), which is a fact for the scale-from-zero work still
  open: wake latency is not only scheduling, it is the URL map catching up.
- **Waking a third tier can fail outright.** With backend and database resident,
  the frontend pod came back `Insufficient memory` with the cluster autoscaler in
  backoff after 16 failed scale-ups; deleting the pending pod got it scheduled
  onto its own Autopilot node. Two things follow: three tiers awake is not one
  node, and "delete the stuck pod" is the unstick.
- **Staging does not have a public surface, on purpose.** An address holds exactly
  one global forwarding rule, so a second environment is a second address and a
  second forwarding rule — a second monthly line — not another host block on this
  one. Terraform declares those six names but separates *pointed* from *held*
  (`dns_records` vs `dns_records_deferred`), because a record that resolves to an
  address with no rule behind it looks exactly like a broken deploy. Whether
  staging is worth the line is an M9 decision, and by then M10's checkpoints will
  have priced the first one.

**For M10's first checkpoint, the list of SKUs to read in the bill now includes the
public surface**: a global static address in use, and *two* global forwarding rules
(one per target proxy, HTTP and HTTPS) on that one address, plus the data
processed through them. None of that is in the earlier cost notes, and none of it
is a per-pod number, so it will not show up in the requests table this plan has
been watching.
