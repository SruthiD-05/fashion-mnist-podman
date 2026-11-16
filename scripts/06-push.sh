#!/usr/bin/env bash
# Tags and pushes images.  REGISTRY=quay.io/<user> ./scripts/06-push.sh
set -euo pipefail
: "${REGISTRY:?set REGISTRY, e.g. REGISTRY=quay.io/myuser}"
set -x
for i in trainer api ui; do
  podman tag localhost/fashion-$i:1.0 "$REGISTRY/fashion-$i:1.0"
  podman push "$REGISTRY/fashion-$i:1.0"
done
skopeo inspect "docker://$REGISTRY/fashion-api:1.0" | head -20
