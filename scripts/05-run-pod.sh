#!/usr/bin/env bash
# Same app as a pod: containers share one network namespace (talk over localhost).
# The pod also joins fashion-net, so its API can still reach the fashion-db container by name.
set -euo pipefail
cd "$(dirname "$0")/.."
set -x
podman pod create --name fashion-pod -p 8081:8080 \
  --network fashion-net --add-host fashion-api:127.0.0.1
podman run -d --pod fashion-pod --name fashion-pod-api \
  -e APP_ENV=pod -e DB_HOST=fashion-db \
  --secret api_token --secret db_password \
  -v fashion-output:/output:ro \
  localhost/fashion-api:1.0
podman run -d --pod fashion-pod --name fashion-pod-ui localhost/fashion-ui:1.0
podman pod ps
podman ps --pod --filter pod=fashion-pod
