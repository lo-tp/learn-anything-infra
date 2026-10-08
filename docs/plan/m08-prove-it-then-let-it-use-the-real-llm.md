# M8 — Prove it, then let it use the real LLM

← [plan index](./index.md) · [M7](./m07-secrets-to-pods.md) · next [M9](./m09-cutover-then-render-goes-away.md)

Acceptance runs with `MOCK_LLM=1` first: tables are created at startup,
`DATABASE_URL` is ignored, and no token is spent. That is the cheapest possible
end-to-end test of ingress, TLS, DNS, probes and the sandbox fetch.

Then point production at the real endpoint and **complete one session on it**:
wall-clock per step, written down here. Inference is outside the platform budget by
your instruction; it is still inside your wallet, and `MAX_PROBE_QUESTIONS=10` /
`MAX_MATERIAL_ATTEMPTS=3` mean one session is not one API call. Tokens are not
measured — see the decision recorded under Status.

**Done when (amended 2026-10-08, on the two points recorded under Status):** a
full learning session completes in a browser at `learn.lotp.xyz` against the real
LLM, and its wall-clock is recorded here.

**Status: open, and the first finding is that the cluster had no way to reach a
model at all.** The control run (the acceptance walk against a backend still
holding a placeholder key) is what showed it, and the acceptance driver that ran it
is now `scripts/acceptance.py` (`--allow-fail` makes the expected real-mode
failure a result rather than a crash).

- **No egress, and it looked like the familiar problem.** From a pod:
  `api.openai.com` never completed a TCP connection (timeout at 20 s),
  `storage.googleapis.com` answered in 0.1 s, and `example.com`, `github.com`,
  `ipinfo.io` all timed out. The cause is this repository's own shape —
  `enable_private_nodes = true` with no Cloud NAT in the VPC — not the
  mainland-China black-holing AGENTS.md documents. A cloud service that is not
  Google's was unreachable, which the LLM plan quietly assumed away.
  Fixed as code: a Cloud Router and a Cloud NAT gateway over all subnetwork ranges
  (`AUTO_ONLY`, `min_ports_per_vm = 4`). Its price is not asserted here; the
  pricing page is linked in `gcp/network.tf` and M10 reads the line from the bill.
- **The balancer's 30-second backend timeout is a functional limit, not a tuning
  knob.** A still-running request came back as Google's HTML 502 at 30.8 s while
  the pod kept working. `manifests/base/backend-config.yaml` now carries one
  field — `timeoutSec`, attached to the backend Service by annotation. It went in at
  120 s and you set it to **600 s**: the API accepts up to 2³¹−1 seconds and bills
  nothing for the value, so the cost of a longer ceiling is held request capacity
  (a synchronous phase occupies a worker for its whole life, at one replica that is
  a queue) and the retries that get to live long enough to happen — inference, the
  only part that is money. The limits that bind before it are the app's own client
  timeouts, which are defaults in code this repo does not own. (The
  health-check `BackendConfig`s M6 deleted stay deleted: that field is ignored here,
  this one is the documented mechanism for timeouts.)
- **Two contract facts the walk taught, both now written into the script rather
  than remembered:** the cookie is set by `/auth/login`, not by
  `/auth/register` (the frontend makes both calls); and pydantic's email validator
  rejects a `.invalid` address, so the throwaway learner uses `example.com`.
- **What M8 still needs from you, and it cannot be derived from this repo: which
  endpoint.** The backend's local `.env` points at `http://192.168.200.54:1919/v1`
  with model `qwen3.8-flash-next-iq3_xxs` — a machine on your LAN, unreachable
  from a VPC in `asia-east2`. Whatever production uses has to be reachable from
  the cluster (now possible, via NAT) and is three Secret Manager values:
  `openai-api-key`, `openai-base-url`, `llm-model`. Render's values are not in
  `render.yaml` (`sync: false`), so the dashboard is the only place they exist.
- **No token instrumentation, decided rather than omitted (2026-10-08).** The
  backend constructs `ChatOpenAI` in `core/llm.py` and nothing downstream keeps
  `usage_metadata`, so tokens-per-session is not measurable inside the app today —
  and it will not be made measurable now. Inference is outside the platform budget
  by your instruction, so the number would be curiosity, not a control; if it ever
  matters, the provider's own usage dashboard says it without a line of code in the
  product. What M8 records is wall-clock, which `scripts/acceptance.py` already
  prints per step.
- **No staging surface, decided (2026-10-08).** The original Done-when named a
  staging hostname because it was written before the pod floor was known: a second
  public environment is a second address and forwarding rule plus four more pods at
  Autopilot's billing floor — roughly doubling the pod line, which is over the
  credit's ceiling. So the real-LLM session runs on **production**, which is already
  public and already the thing being cut over to. `overlays/staging/` stays
  apply-able and deliberately not running (M6's finding), and if staging ever gets
  a surface it will be because there is traffic to protect from a change, not
  because a milestone asked for one.
