#!/usr/bin/env bash
# Removes everything the lab created (including the database data!).
# Add --images to also delete the images.
cd "$(dirname "$0")/.."
set -x
podman-compose down 2>/dev/null
podman kube down kube/fashion-pod.yaml 2>/dev/null
podman pod rm -f fashion-pod 2>/dev/null
podman rm -f fashion-api fashion-ui fashion-db fashion-trainer fashion-dev-api fashion-dev-ui 2>/dev/null
podman volume rm fashion-output fashion-db fashion_fashion-output fashion_fashion-db 2>/dev/null
podman network rm fashion-net fashion_fashion-net 2>/dev/null
podman secret rm api_token db_password 2>/dev/null
rm -f .env
if [ "${1:-}" = "--images" ]; then
  podman rmi -f $(podman images -q --filter reference='localhost/fashion-*') 2>/dev/null
fi
podman ps -a; podman volume ls; podman network ls
