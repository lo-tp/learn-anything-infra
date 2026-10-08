# The local container machine (podman)

Reached when a **local** image build or pull is needed. Nothing in the deployment
depends on it: images are built and smoke-tested in CI, so this file is about the
laptop, not the platform. If you are here to change what runs in the cluster, go back to [AGENTS.md](../../AGENTS.md).

Images on this machine are built and run with **podman**. Do not reach for
`docker` — there may be no daemon, and podman is what holds the local images and
the dev containers (the backend repo's Compose Postgres, `learn-anything-db`).

## Pulling fails selectively, and the fix is inside the VM

The podman VM is a separate network from the laptop, and it hits the same wall the
"Network" section of AGENTS.md describes: from inside the VM,
`registry-1.docker.io`, `mirror.gcr.io` and `asia-east2-docker.pkg.dev` all time
out while `storage.googleapis.com` answers — so the failure looks selective rather
than total. The laptop's proxy **is** reachable from the VM as
`host.containers.internal:6152`, so the pull path is fixed by giving the unit that
does the pulling a proxy, inside the VM:

```sh
podman machine ssh 'mkdir -p ~/.config/systemd/user/podman.service.d && \
  printf "[Service]\nEnvironment=HTTP_PROXY=http://host.containers.internal:6152\nEnvironment=HTTPS_PROXY=http://host.containers.internal:6152\nEnvironment=NO_PROXY=localhost,127.0.0.1,host.containers.internal\n" \
  > ~/.config/systemd/user/podman.service.d/proxy.conf && \
  systemctl --user daemon-reload && systemctl --user restart podman'
```

The **user** unit is the one that matters: the macOS client talks to
`podman.service` in the VM's user session, and a drop-in on the system unit changes
nothing. `systemctl --user restart podman` leaves running containers alone;
`podman machine restart` does not.

Whether the drop-in is in place is one lookup, not a note kept here:
`podman machine ssh test -f ~/.config/systemd/user/podman.service.d/proxy.conf`.

## Sizing, when a local build is needed

The shipped 2 GiB is too small for a real dependency tree:

```sh
podman machine stop
podman machine set --cpus 8 --memory 12288
podman machine start
# and back again when finished:
podman machine stop && podman machine set --cpus 5 --memory 2048 && podman machine start
```

Which size the machine is now is also a lookup: `podman machine ls --format
'{{.Name}} {{.CPUs}}cpu {{.Memory}}GiB'`.

A machine restart stops running containers, and any container whose restart policy
is `no` stays down. Check first
(`podman inspect -f '{{.HostConfig.RestartPolicy.Name}}' <name>`), then start them
again after.

Disk given back to the VM does not shrink on its own: a qcow2 file grows and stays.
Inside the VM, `sudo fstrim -v /`; on the host, the size to watch is
`~/.local/share/containers/podman/machine/applehv/*.raw`.

## Building the backend image locally

It needs read access to the private prompts repository, which the build takes as a
**mounted secret**, never a build arg (a build arg lands in the image history):

```sh
gh auth token > /tmp/prompts_token   # must be able to read lo-tp/learn-anything-prompts
cd ../python/learn-anything-backend
podman build --secret id=prompts_token,src=/tmp/prompts_token -t learn-anything-backend:local .
```

CI takes the same value from the repository secret `PROMPTS_TOKEN`.

## CI is not affected by any of this

GitHub runners have ordinary internet and use Docker + Buildx, so Dockerfiles stay
plain — `# syntax=docker/dockerfile:1`, BuildKit `RUN --mount=type=secret`, no
podman-specific syntax. Podman is the local verification path only.
