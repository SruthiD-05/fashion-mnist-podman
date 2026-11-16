#!/usr/bin/env bash
# Builds the 4 images. --format docker keeps the HEALTHCHECK instruction.
# The base image uses ubi-minimal + python3.11 RPM when the UBI RPM repo is reachable,
# otherwise it falls back to ubi9/python-311 as the runtime stage (bigger, same result).
set -euo pipefail
cd "$(dirname "$0")/.."
V=${VERSION:-1.0}
UBI_REPO=https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/appstream/os/repodata/repomd.xml
if [ -z "${RUNTIME_IMAGE:-}" ]; then
  if curl -sf -m 10 -o /dev/null "$UBI_REPO"; then
    RUNTIME_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
  else
    echo ">> UBI RPM repo not reachable: using ubi9/python-311 as the runtime stage"
    RUNTIME_IMAGE=registry.access.redhat.com/ubi9/python-311:latest
  fi
fi
PIP_OPTS="--no-index --find-links=/wheels"     # bundled wheels, no PyPI needed
ls wheels/*.whl >/dev/null 2>&1 || { echo ">> wheels/ is empty: installing from PyPI"; PIP_OPTS=""; }
set -x
podman build --format docker --build-arg VERSION="$V" \
  --build-arg RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  --build-arg PIP_OPTS="$PIP_OPTS" \
  -f base/Containerfile    -t localhost/fashion-base:"$V"    .
podman build --format docker --build-arg VERSION="$V" \
  -f trainer/Containerfile -t localhost/fashion-trainer:"$V" .
podman build --format docker --build-arg VERSION="$V" \
  -f api/Containerfile     -t localhost/fashion-api:"$V"     .
podman build --format docker --build-arg VERSION="$V" \
  -f ui/Containerfile      -t localhost/fashion-ui:"$V"      .
for i in base trainer api ui; do podman tag localhost/fashion-$i:"$V" localhost/fashion-$i:latest; done
podman images --filter reference='localhost/fashion-*'
