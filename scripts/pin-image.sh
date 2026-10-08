#!/usr/bin/env bash
# Resolve what each application image should be pinned to, and (unless --dry-run)
# write it into the production overlay.
#
# The registry is the source of truth for what exists: a `sha-<commit>` tag appears
# only after that image's own workflow built it **and its smoke step passed** — the
# publish step runs after the smoke test, by design, and only `release` publishes.
# Which branch a tag came from is deliberately not part of the resolution: the
# newest tagged version of each package is the candidate, and this script's job is to
# turn that into a pinned digest in `manifests/overlays/prod/kustomization.yaml`,
# keeping the tag in the comment beside it, because a bare digest is a fact no human
# can look up.
#
# What it does not do: decide that a change is good. It writes a file.
# .github/workflows/deliver.yml runs this, commits what it wrote as the record, and
# dispatches .github/workflows/deploy.yml, which applies it.
#
# --dry-run prints what would change and exits 1 if anything differs (0 when the
# overlay is already current), so a scheduled job knows whether to open a PR.
set -euo pipefail

mode="write"
case "${1:-}" in
  --dry-run) mode="dry-run" ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

project="${PROJECT_ID:?PROJECT_ID must be set}"
region="${REGION:-asia-east2}"
repository="learn-anything"
overlay="${OVERLAY:-manifests/overlays/prod/kustomization.yaml}"

# The three images this project runs. They are listed here because the pairing is
# what breaks silently: an image that is built but never pinned, or a pin naming a
# package nobody builds any more.
images=(learn-anything-backend learn-anything-frontend learn-anything-sandbox)

plan="$(mktemp)"
trap 'rm -f "$plan"' EXIT

for image in "${images[@]}"; do
  package="$region-docker.pkg.dev/$project/$repository/$image"
  # `--format=json` with no field selection: the digest column gcloud prints for a
  # *tagged* row is empty, and selecting `digest` explicitly drops the field
  # altogether. The unfiltered payload carries the version resource, whose last path
  # segment is the digest.
  gcloud artifacts docker images list "$package" --include-tags \
    --format='json(version,tags,createTime)' --quiet 2>/dev/null |
    python3 -c '
import json, re, sys
rows = []
for r in json.load(sys.stdin):
    tags = str(r.get("tags") or "").strip("\x27\"[]").replace("\x27", "").split(",")
    tags = [t.strip() for t in tags if re.fullmatch(r"sha-[0-9a-f]{40}", t.strip())]
    if tags:
        rows.append((r.get("createTime", ""), tags[0], r["version"]))
if rows:
    created, tag, digest = max(rows)
    print("%s\t%s\t%s\t%s" % ("'"$package"'", tag, digest, created))
' >>"$plan" || true
done

python3 - "$overlay" "$mode" "$plan" <<'PY'
import pathlib
import re
import sys

overlay_path, mode, plan_path = sys.argv[1:4]

wanted = {}
for line in pathlib.Path(plan_path).read_text().splitlines():
    if line.strip():
        package, tag, digest, created = line.split("\t")
        wanted[package] = (tag, digest, created)

lines = pathlib.Path(overlay_path).read_text().splitlines(keepends=True)

# Only inside the `images:` block. The same two-space `- name:` shape appears under
# `configMapGenerator` (the ConfigMaps are called backend-config and
# sandbox-config), and treating those as image pins is how a script quietly
# rewrites something it was never meant to touch.
start = next((i for i, l in enumerate(lines) if l.rstrip() == "images:"), None)
if start is None:
    sys.exit(f"{overlay_path} has no images: block")
block_end = next((i for i in range(start + 1, len(lines)) if re.match(r"^[A-Za-z]", lines[i])), len(lines))
entries = [i for i in range(start + 1, block_end) if re.match(r"^  - name: \S+$", lines[i])]
changes, notes = [], []

for idx in entries:
    name = lines[idx].split(":", 1)[1].strip()
    # The entry runs until the next `- name:` or the end of the images block.
    end = min([i for i in entries if i > idx] + [block_end])
    pin = next((i for i in range(idx + 1, end) if re.match(r"^    digest: sha256:[0-9a-f]{64}", lines[i])), None)
    if pin is None:
        notes.append(f"  {name}: no digest pin in the overlay — not touched")
        continue
    current = re.match(r"^    digest: (sha256:[0-9a-f]{64})", lines[pin]).group(1)
    if name not in wanted:
        notes.append(f"  {name}: nothing published with a sha-<commit> tag — pin left alone")
        continue
    tag, digest, created = wanted[name]
    if digest == current:
        notes.append(f"  {name}: current ({tag})")
        continue
    short = tag.split("-", 1)[1][:8]
    lines[pin] = f"    digest: {digest}  # {tag} (CI, {short}), built {created[:10]}\n"
    changes.append((name, current, digest, tag))

print("candidate images:")
for name, current, digest, tag in changes:
    print(f"  {name}\n      was  {current[:19]}…  ->  now {digest[:19]}…  ({tag})")
for note in notes:
    print(note)

if changes and mode == "write":
    pathlib.Path(overlay_path).write_text("".join(lines))
    print(f"wrote {len(changes)} pin(s) to {overlay_path}")
elif changes:
    print(f"{len(changes)} pin(s) would change ({overlay_path} untouched)")
    sys.exit(1)
else:
    print("already current")
PY
