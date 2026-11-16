#!/usr/bin/env bash
# The project already ships the dataset (dataset/*.gz) and the Python wheels (wheels/*.whl),
# so the lab only needs the Red Hat UBI registry. Use this script on a machine WITH internet only to
#   - re-download the dataset / wheels (e.g. after changing base/requirements.txt), or
#   - with --images: build all images there and save them to one tar for a lab with NO registry access.
set -euo pipefail
cd "$(dirname "$0")/.."
URL=http://fashion-mnist.s3-website.eu-central-1.amazonaws.com
for f in train-images-idx3-ubyte.gz train-labels-idx1-ubyte.gz t10k-images-idx3-ubyte.gz t10k-labels-idx1-ubyte.gz; do
  [ -s "dataset/$f" ] || curl -fL -o "dataset/$f" "$URL/$f"
done
(cd dataset && sha256sum -c SHA256SUMS)
# Wheels for Linux x86_64 / Python 3.11 (what the UBI python-311 builder uses)
python3 -m pip download -d wheels --only-binary=:all: \
  --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 \
  --python-version 3.11 --implementation cp -r base/requirements.txt
ls wheels
if [ "${1:-}" = "--images" ]; then
  ./scripts/01-build.sh
  mkdir -p offline/images
  podman save -o offline/images/fashion-images.tar --multi-image-archive \
    localhost/fashion-trainer:1.0 localhost/fashion-api:1.0 localhost/fashion-ui:1.0
  ls -lh offline/images/
fi
