#!/usr/bin/env bash
# PostgreSQL + API + UI as three containers on a user-defined network (DNS by container name).
set -euo pipefail
cd "$(dirname "$0")/.."
DB_IMAGE=${DB_IMAGE:-quay.io/sclorg/postgresql-15-c9s:latest}
set -x
# 1. Database: password comes from the podman secret as an environment variable
podman run -d --name fashion-db \
  --network fashion-net \
  -e POSTGRESQL_USER=fashion \
  -e POSTGRESQL_DATABASE=fashion \
  --secret db_password,type=env,target=POSTGRESQL_PASSWORD \
  -v fashion-db:/var/lib/pgsql/data \
  --restart on-failure \
  "$DB_IMAGE"
set +x
echo ">> waiting for PostgreSQL to create the fashion database (first start takes ~10 s)"
for i in $(seq 1 45); do
  podman exec fashion-db psql -U fashion -d fashion -qAtc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
set -x
podman exec fashion-db pg_isready
# 2. Load schema + reference data (podman cp + podman exec)
podman cp db/init.sql fashion-db:/tmp/init.sql
podman exec fashion-db psql -U fashion -d fashion -q -f /tmp/init.sql
# 3. API: password comes from the same podman secret, as a file
podman run -d --name fashion-api \
  --network fashion-net \
  -p 8000:8000 \
  -e APP_ENV=lab \
  -e DB_HOST=fashion-db \
  --secret api_token \
  --secret db_password \
  -v fashion-output:/output:ro \
  --health-cmd 'python -c "import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:8000/healthz\", timeout=4)"' \
  --health-interval 30s \
  --restart on-failure \
  localhost/fashion-api:1.0
# 4. Web UI
podman run -d --name fashion-ui \
  --network fashion-net \
  -p 8080:8080 \
  localhost/fashion-ui:1.0
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
