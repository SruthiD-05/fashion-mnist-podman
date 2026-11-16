#!/usr/bin/env bash
# Runs the one-shot training container. EPOCHS=2 ./scripts/03-train.sh for a quick run.
set -euo pipefail
cd "$(dirname "$0")/.."
set -x
podman run --name fashion-trainer --rm \
  --network fashion-net \
  -e EPOCHS="${EPOCHS:-5}" -e OFFLINE="${OFFLINE:-false}" \
  --memory 2g \
  -v "$PWD/dataset":/data:Z \
  -v fashion-output:/output \
  localhost/fashion-trainer:1.0
