# libsmctrl-toolkit

A base image with GPU TPC-partitioning tooling prebuilt, so downstream images
can `FROM` it instead of rebuilding these from source. It has no `CMD` and
runs nothing on its own beyond its `ENTRYPOINT` (nvdebug bootstrap, see
below) — it exists to be `FROM`'d.

## Tools included

| Tool | Source | What it does | In image as |
|---|---|---|---|
| [libsmctrl](https://github.com/sarah-e-c/libsmctrl) | `blackwell` branch of a personal fork, carrying the Blackwell/RTX 50-series `QMDV05_00` TPC-masking patch on top of upstream rtsrv.cs.unc.edu/libsmctrl | Low-level API for masking which GPU TPCs a CUDA stream/kernel can use | `/opt/libsmctrl/libsmctrl.so`, `/opt/libsmctrl/libsmctrl.h` |
| [maskmaster](https://github.com/sarah-e-c/maskmaster) | `main`, built with hardware discovery (`DISCOVERY=1`) | Higher-level mask-packing/topology-discovery helpers built on top of libsmctrl | `/opt/maskmaster/c/libmaskmaster.so`, `/opt/maskmaster/c/maskmaster.h` |
| [nvdebug](http://rtsrv.cs.unc.edu/cgit/cgit.cgi/nvdebug.git) | `master` | Out-of-tree kernel module providing `/proc/gpu0/*`, which `mm_discover`/libsmctrl's info functions read | `/opt/nvdebug` (source only — built/loaded at container start, see "Runtime requirement") |

This list is expected to grow — the point of renaming this from
`smctrl-maskmaster-base` to `libsmctrl-toolkit` is to have a home for more
libsmctrl-adjacent tools without implying it's just libsmctrl + maskmaster.

Also present:
- `LD_LIBRARY_PATH=/opt/maskmaster/c:/opt/libsmctrl`
- `ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]`, which builds/loads
  nvdebug against the host kernel, then execs the downstream image's `CMD`

## Using it

```dockerfile
FROM ghcr.io/sarah-e-c/libsmctrl-toolkit:latest
COPY . /opt/myapp
RUN cd /opt/myapp && make MM_DIR=/opt/maskmaster/c SM_DIR=/opt/libsmctrl
CMD ["/opt/myapp/myapp"]
```

## Runtime requirement

Anything built against libsmctrl's masking functions needs the `nvdebug`
kernel module loaded on the **host** (it provides `/proc/gpu0/*`, which
`mm_discover`/libsmctrl's info functions read).

The image carries nvdebug source at `/opt/nvdebug` and an `ENTRYPOINT`
(`docker-entrypoint.sh`) that builds and `insmod`s it against the host's
running kernel on container start, if it isn't already loaded. This works
because a container shares the host kernel — `insmod` from inside a
privileged container loads the module into the host, not a sandboxed copy. A
prebuilt `.ko` can't be baked into the image itself, since kernel modules are
ABI-locked to the exact kernel they're built against.

For this to work, run downstream containers with the host's kernel headers
and `/proc/gpu0` bind-mounted in, plus `--privileged --pid=host` (bind-mounting
a path under `/proc` is rejected by runc, and `CAP_SYS_MODULE` for `insmod`
requires `--privileged`):

```
docker run --gpus all --privileged --pid=host \
    -v /lib/modules:/lib/modules:ro \
    -v /usr/src:/usr/src:ro \
    ...
```

If the host's kernel headers aren't available in the container, or you'd
rather manage it yourself, load nvdebug on the host before starting the
container and the entrypoint will detect it and skip its own build:

```
sudo insmod /path/to/nvdebug/nvdebug.ko
```

## Example: tester subimage

`tester/` is a worked example of a downstream image: a small tiled-SGEMM
benchmark (`bench.cu`) that calls `mm_discover`/`mm_pack` and
`libsmctrl_set_global_mask` to time matmuls under increasing TPC masks,
writing `results.csv`. It's self-contained (its own `Dockerfile`, `Makefile`,
source) and only depends on this base image being built or pulled first.

```
docker build -t smctrl-tester-example -f tester/Dockerfile tester
docker run --gpus all --privileged --pid=host \
    -v /lib/modules:/lib/modules:ro \
    -v /usr/src:/usr/src:ro \
    smctrl-tester-example
```

See `tester/Dockerfile` for the `BASE_IMAGE` and `SM_ARCH` build args (e.g. to
build against a local base image instead of the published GHCR one, or target
a non-Blackwell GPU architecture).

## Publishing to GitHub Container Registry

The image is self-contained (no host path dependencies), so once this
directory is pushed as its own GitHub repo (`sarah-e-c/libsmctrl-toolkit`) it
can build and push to GHCR:

```
docker build -t ghcr.io/sarah-e-c/libsmctrl-toolkit:latest .
echo "$GITHUB_TOKEN" | docker login ghcr.io -u sarah-e-c --password-stdin
docker push ghcr.io/sarah-e-c/libsmctrl-toolkit:latest
```

`GITHUB_TOKEN` needs `write:packages` scope (a classic PAT, or the default
`GITHUB_TOKEN` in a GitHub Actions workflow with `packages: write`
permission). A starter workflow is at
`.github/workflows/publish.yml` — it builds and pushes to GHCR on every push
to `main`, tagged `latest` and with the short commit SHA.

Consider tagging versions (`:v1`, matching a git tag) alongside `:latest`
once this is public, since `libsmctrl`/`maskmaster`/`nvdebug` are cloned
fresh from their default branches at build time and could otherwise drift
under `:latest` between builds.

Two things worth knowing before publishing broadly:
- The image ships an `ENTRYPOINT` (see above) that attempts to build and
  `insmod` a kernel module at container start. That's unusual for a "base"
  image and means anyone `docker run`-ing it directly (not just `FROM`-ing
  it) needs `--privileged` and the bind mounts described above, or the
  entrypoint just logs a warning and continues.
- `org.opencontainers.image.licenses` in the `Dockerfile` is a placeholder —
  none of libsmctrl/maskmaster/nvdebug currently carry a LICENSE file in the
  versions this clones; confirm licensing before a public push. GHCR
  packages default to private for repos that aren't public, so also check
  the package's visibility setting after the first push if you want it
  pullable without auth.

## Status

Renamed from `smctrl-maskmaster-base`. Not yet pushed to GitHub — this
directory is self-contained (no path deps outside itself) specifically to
make that move easy.
