#!/usr/bin/env python3
"""M8's acceptance run: drive one complete learning session through the public
surface, and report it as a table.

The point is the *path*, not the model. With `MOCK_LLM=1` the backend answers its
LLM-dependent phases from canned responses and runs on in-memory SQLite
(`DATABASE_URL` ignored), so a green run here proves the parts this repository owns
all work together: DNS, TLS, the balancer's host routing, the probes, the auth
cookie crossing `api.` → `learn.`, and — the part that has never been exercised
end to end — the sandbox fetching a slide from the backend with its service
principal and serving it into an iframe. A red run in *real* mode (placeholder
key) is equally useful: it shows the walk is sensitive to the LLM actually being
reachable, which is what makes the mock pass worth anything.

Written as a command rather than a checklist because M8 will be re-run: after the
real key lands, and again after any change to the surface.

Usage:
  scripts/acceptance.py [--goal TEXT] [--api URL] [--frontend URL] [--sandbox URL]
                        [--allow-fail PHASE] [--timeout SECONDS]

`--allow-fail` makes an LLM-phase failure an expected outcome instead of a crash
(use it for the real-mode control run); the platform steps are always checked.
"""

from __future__ import annotations

import argparse
import json
import http.cookiejar
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

DEFAULTS = {
    "api": "https://api.lotp.xyz",
    "frontend": "https://learn.lotp.xyz",
    "sandbox": "https://sandbox.lotp.xyz",
}


class Api:
    """A cookie jar and a request method. The cookie is the whole point: the
    backend sets it on `api.` for the parent domain and the browser (here, this
    script) is expected to carry it — that is the M6 cross-subdomain rule."""

    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method: str, path: str, body: dict | None = None, headers: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("content-type", "application/json")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        started = time.monotonic()
        try:
            with self.opener.open(req, timeout=120) as resp:
                raw = resp.read()
                return resp.status, parse(raw), (time.monotonic() - started) * 1000
        except urllib.error.HTTPError as e:
            raw = e.read()
            return e.code, parse(raw), (time.monotonic() - started) * 1000
        except Exception as e:  # noqa: BLE001 — a transport failure is a result too
            return 0, {"detail": f"{type(e).__name__}: {e}"}, (time.monotonic() - started) * 1000


def parse(raw: bytes):
    try:
        return json.loads(raw or b"null")
    except json.JSONDecodeError:
        return {"_raw": (raw or b"").decode("utf-8", "replace")[:400]}


def backend_mode(api_url: str) -> str:
    """Ask the cluster which mode the running backend thinks it is in.

    Not inferred from behaviour (canned answers could mean anything) and not
    remembered from whoever set it last: read from the Deployment that is live.
    Tolerates a machine with no kubeconfig configured — the run is still valid,
    it just cannot say which mode it tested.
    """
    try:
        out = subprocess.run(
            ["kubectl", "get", "deploy/backend", "-n", "learn-anything",
             "-o", "jsonpath={.spec.template.spec.containers[0].env}"],
            capture_output=True, text=True, timeout=60, check=True,
        ).stdout
    except Exception as e:  # noqa: BLE001
        return f"unknown (could not read the Deployment: {type(e).__name__})"
    for item in json.loads(out or "[]"):
        if item.get("name") == "MOCK_LLM":
            return f"MOCK_LLM={item.get('value', '')!r}"
    return "MOCK_LLM unset (real endpoint)"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--goal", default="I want to learn how postgres indexes work well enough to explain them to a colleague")
    p.add_argument("--allow-fail", action="store_true",
                   help="expect the LLM-dependent phases to fail (the real-mode control run)")
    p.add_argument("--timeout", type=int, default=240, help="seconds to wait for material generation")
    for name, url in DEFAULTS.items():
        p.add_argument(f"--{name}", default=url)
    args = p.parse_args()

    api = Api(args.api)
    rows: list[tuple[str, str, str, str]] = []
    failed, notes = [], []

    def step(label: str, status: int, ms: float, detail: str = "", ok: bool | None = None) -> bool:
        good = 200 <= status < 300 if ok is None else ok
        rows.append((label, str(status), f"{ms:.0f} ms", "ok" if good else detail[:70] or "failed"))
        if not good:
            failed.append(f"{label}: HTTP {status} {detail[:200]}")
        return good

    print(f"acceptance against {args.api}")
    print(f"backend mode: {backend_mode(args.api)}")
    print(f"goal: {args.goal!r}\n")

    # 1. The three hostnames answer, over TLS, through the one balancer.
    st, body, ms = api.call("GET", "/health")
    step("GET api/health", st, ms, str(body))
    st, body, ms = Api(args.frontend).call("GET", "/en/login")
    step("GET frontend/en/login", st, ms, str(body)[:80])

    # 2. A learner. Registered rather than reused: the run must not depend on
    # anything a previous run left behind.
    # `.invalid` would be the correct RFC 2606 choice and pydantic's email
    # validator rejects it ("the part after the @ sign should end with a
    # valid TLD"), so the run uses example.com — reserved too, and accepted.
    email = f"acceptance-{uuid.uuid4().hex[:10]}@example.com"
    password = "acceptance-run-42!"
    st, body, ms = api.call("POST", "/auth/register", {"email": email, "password": password})
    step("POST auth/register", st, ms, str(body)[:120], ok=(st in (201, 409)))
    # Sign in explicitly: the API sets the cookie on `/auth/login`, not on
    # registration — the frontend does the same two calls, and a test that
    # assumed otherwise would be asserting a contract nobody wrote.
    st, body, ms = api.call("POST", "/auth/login", {"email": email, "password": password})
    step("POST auth/login (sets the cookie)", st, ms, str(body)[:120])
    st, body, ms = api.call("GET", "/auth/me")
    if step("GET auth/me (cookie carried back to api.)", st, ms, str(body)[:120]):
        if body.get("email") != email:
            failed.append(f"auth/me returned the wrong identity: {body}")

    # 3. Clarify. The session is created and immediately asked to narrow itself.
    st, body, ms = api.call("POST", "/sessions", {"goal": args.goal})
    session_id = body.get("session_id") if isinstance(body, dict) else None
    if not step("POST sessions (create + first clarify)", st, ms, str(body)[:160]):
        print_report(rows, failed, notes)
        return 1
    phase = body.get("phase")
    answers = [
        "I want to be able to explain it accurately, with the trade-offs.",
        "I have used the product a bit but never looked at how it works inside.",
    ]
    for i in range(4):
        if phase != "clarifying":
            break
        st, body, ms = api.call("POST", f"/sessions/{session_id}/clarify", {"answer": answers[i % len(answers)]})
        step(f"POST clarify #{i + 1}", st, ms, str(body)[:120])
        phase = body.get("phase", phase)

    # 4. Probe. Answer each question with the option the API marks correct — this
    # is a platform test, not a knowledge test.
    asked = 0
    while phase == "probing" and asked < 12:
        st, body, ms = api.call("POST", f"/sessions/{session_id}/probe", {})
        step(f"POST probe (question {asked + 1})", st, ms, str(body)[:120])
        questions = body.get("questions") or ([body] if body.get("id") else [])
        if not questions:
            break
        answers = [{"question_id": q["id"], "selected_index": q.get("correct_index", 0)} for q in questions]
        asked += len(questions)
        st, body, ms = api.call("POST", f"/sessions/{session_id}/probe", {"answers": answers})
        step(f"POST probe answers ({asked} answered)", st, ms, str(body)[:120])
        phase = body.get("phase", phase)
        if not questions:
            break

    # 5. Plan.
    st, body, ms = api.call("POST", f"/sessions/{session_id}/plan/generate", {})
    step("POST plan/generate", st, ms, str(body)[:160])
    phase = body.get("phase", phase)
    for _ in range(20):
        if phase in ("reviewing", "generating", "executing", "complete"):
            break
        st, body, ms = api.call("GET", f"/sessions/{session_id}")
        if st != 200:
            break
        phase = body.get("phase")
        time.sleep(2)
    st, body, ms = api.call("POST", f"/sessions/{session_id}/plan/approve", {})
    approved = step("POST plan/approve (starts material generation)", st, ms, str(body)[:160],
                    ok=(200 <= st < 300 or st == 409))
    if st == 409:
        notes.append(f"plan/approve refused: {str(body)[:200]} (phase was {phase})")

    # 6. Materials: the background generation that calls the sandbox to compile.
    slide_ids: list[str] = []
    if approved:
        deadline = time.monotonic() + args.timeout
        last = {}
        while time.monotonic() < deadline:
            st, body, ms = api.call("GET", f"/sessions/{session_id}/materials")
            last = body if isinstance(body, dict) else {}
            slides = last.get("slides") or last.get("materials") or []
            if isinstance(slides, list):
                slide_ids = [s.get("slide_id") or s.get("id") for s in slides if isinstance(s, dict)]
                slide_ids = [s for s in slide_ids if s]
            if slide_ids:
                step(f"GET sessions/materials ({len(slide_ids)} slide(s) ready)", st, ms, str(last)[:120])
                break
            time.sleep(5)
        else:
            step("GET sessions/materials (waited for slides)", 0, 0, f"no slides within {args.timeout}s: {str(last)[:200]}")

    # 7. The slide itself, then the same slide through the sandbox's iframe gate.
    #    The sandbox does not hold the content: it fetches it from the backend as
    #    its own principal, which is why a 200 here is evidence about the token
    #    pair M7 checks, not just about HTTP.
    if slide_ids:
        st, body, ms = api.call("GET", f"/slides/{slide_ids[0]}")
        content = body.get("content", "") if isinstance(body, dict) else ""
        step(f"GET slides/{slide_ids[0][:24]} (backend serves JSX)", st, ms, str(body)[:120])
        if st == 200 and len(content) < 40:
            failed.append(f"slide content implausibly short: {content[:80]!r}")
        st, body, ms = Api(args.sandbox).call(
            "GET", f"/slides/{slide_ids[0]}", headers={"Sec-Fetch-Dest": "iframe"})
        step(f"GET sandbox/slides/… (iframe fetch, internal call)", st, ms, str(body)[:120])
    elif args.allow_fail:
        notes.append("no slides: expected in this mode (--allow-fail)")
    else:
        failed.append("no slide ids to fetch: the material phase never produced content")

    # 8. The rule M6 set: /api/compile is not a public route.
    st, _, ms = Api(args.sandbox).call("POST", "/api/compile", {"code": "export default function X(){return <p>hi</p>}"})
    step("POST sandbox/api/compile (must NOT be public)", st, ms, "routed! it should be a URL-map miss",
         ok=(st == 404 or st == 405))

    print_report(rows, failed, notes)
    return 1 if failed else 0


def print_report(rows, failed, notes) -> None:
    print(f"{'step':<52} {'http':>5} {'time':>9}  result")
    for label, status, ms, result in rows:
        print(f"{label:<52} {status:>5} {ms:>9}  {result}")
    total = sum(float(r[2].split()[0]) for r in rows)
    print(f"\n{len(rows)} steps, {len(failed)} failed, {total:.0f} ms of request time (wall clock includes polling waits)")
    for n in notes:
        print(f"note: {n}")
    if failed:
        print("\nfailures:")
        for f in failed:
            print(f"  - {f}")
        print("M8's first clause is not met: something on the path is broken, and the line above says which.")
    else:
        print("all checked steps passed: the public surface serves a session end to end")


if __name__ == "__main__":
    sys.exit(main())
