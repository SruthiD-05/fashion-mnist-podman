#!/usr/bin/env bash
# Creates the network, named volumes, secrets and dataset bind-mount directory.
# Safe to run again: existing items are kept, secrets are re-created from secrets/*.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
set -x
podman network exists fashion-net    || podman network create fashion-net
podman volume  exists fashion-output || podman volume create fashion-output
podman volume  exists fashion-db     || podman volume create fashion-db
mkdir -p dataset secrets
[ -s secrets/api_token.txt ]   || openssl rand -hex 16 | tr -d '\n' > secrets/api_token.txt
[ -s secrets/db_password.txt ] || openssl rand -hex 12 | tr -d '\n' > secrets/db_password.txt
chmod 600 secrets/*.txt
for s in api_token db_password; do
  podman secret exists $s && podman secret rm $s
  podman secret create $s secrets/$s.txt
done
# podman-compose reads variables from .env (used for the database password)
echo "DB_PASSWORD=$(cat secrets/db_password.txt)" > .env
chmod 600 .env
# Rootless: container UID 1001 is not your host UID, so give it the bind-mount dir
podman unshare chown -R 1001:0 dataset
