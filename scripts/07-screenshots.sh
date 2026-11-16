#!/usr/bin/env bash
# Runs every command from the project report, one screen at a time, so that each
# screen can be captured as a screenshot for the report.
#
#   cd ~/fashion-mnist-podman
#   DOCKER_USER=<your Docker Hub user> ./scripts/07-screenshots.sh      # all steps
#   DOCKER_USER=<your Docker Hub user> ./scripts/07-screenshots.sh 12   # start at step 12
#   (REGISTRY=quay.io/<user> pushes to Quay.io instead of Docker Hub)
#
# For each step the screen is cleared, the commands are printed and run, and the
# script waits for Enter. Take the screenshot of the terminal while it waits,
# and save it as S01.png, S02.png ... (the step number is shown in the banner).
# If gnome-screenshot is installed it also saves the window to ~/fashion-screenshots/.
# The text output of each step is saved to ~/fashion-screenshots/Sxx.txt as well.
#
# WARNING: step 1 removes the containers, volumes, network and secrets of the lab
# (not the images) so that every "create" command can be shown. The model is
# trained again in step 9 (about 4 minutes) and the stack is left running at the end.

cd "$(dirname "$0")/.."
START=${1:-1}
OUT=~/fashion-screenshots
mkdir -p "$OUT"
DB_IMAGE=${DB_IMAGE:-quay.io/sclorg/postgresql-15-c9s:latest}
[ -z "${REGISTRY:-}" ] && [ -n "${DOCKER_USER:-}" ] && REGISTRY=docker.io/$DOCKER_USER
PROMPT="[$USER@$(hostname -s) $(basename "$PWD")]\$"
STEP=0
TITLE=""

banner() {
  STEP=$((STEP + 1)); TITLE="$1"
  [ "$STEP" -lt "$START" ] && return 1
  clear
  printf '\e[1;37;41m  S%02d  %-70s\e[0m\n\n' "$STEP" "$TITLE"
  : > "$OUT/$(printf 'S%02d' "$STEP").txt"
  return 0
}

# run "command line" : prints the prompt + command, then runs it
run() {
  printf '\e[1;32m%s\e[0m \e[1m%s\e[0m\n' "$PROMPT" "$1"
  printf '%s %s\n' "$PROMPT" "$1" >> "$OUT/$(printf 'S%02d' "$STEP").txt"
  eval "$1" 2>&1 | tee -a "$OUT/$(printf 'S%02d' "$STEP").txt"
}

pause() {
  local f; f=$(printf 'S%02d' "$STEP")
  echo
  if command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot -w -f "$OUT/$f.png" >/dev/null 2>&1 && printf '\e[2m(saved %s/%s.png)\e[0m\n' "$OUT" "$f"
  fi
  printf '\e[1;33m>> Take the screenshot of %s now, then press Enter for the next step\e[0m' "$f"
  read -r
}

wait_db() {
  for i in $(seq 1 45); do
    podman exec fashion-db psql -U fashion -d fashion -qAtc 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 2
  done
}

wait_api() {
  for i in $(seq 1 30); do
    curl -sf localhost:8000/healthz >/dev/null 2>&1 && return 0
    sleep 2
  done
}

# ---------------------------------------------------------------- 1. clean start
if banner "Clean start: remove old containers, volumes, network and secrets"; then
  podman-compose down >/dev/null 2>&1
  podman kube down kube/fashion-pod.yaml >/dev/null 2>&1
  podman pod rm -f fashion-pod >/dev/null 2>&1
  run "podman rm -f fashion-api fashion-ui fashion-db fashion-trainer fashion-bg-trainer 2>/dev/null; podman ps -a"
  run "podman volume rm -f fashion-output fashion-db fashion-scratch fashion_fashion-output fashion_fashion-db 2>/dev/null; podman volume ls"
  run "podman network rm fashion-net fashion_fashion-net 2>/dev/null; podman network ls"
  run "podman secret rm api_token db_password 2>/dev/null; podman secret ls"
  pause
fi

# ---------------------------------------------------------------- 2. lab check
if banner "Lab environment: Podman, rootless, SELinux"; then
  run "cat /etc/redhat-release"
  run "podman version | head -8"
  run "podman info --format 'rootless={{.Host.Security.Rootless}}  cgroup={{.Host.CgroupsVersion}}  storage={{.Store.GraphDriverName}}'"
  run "getenforce"
  run "skopeo --version; podman-compose --version 2>/dev/null | tail -1"
  pause
fi

# ---------------------------------------------------------------- 3. registry
if banner "Registries: inspect a remote UBI image with skopeo, pull it"; then
  run "grep -E '^unqualified-search-registries' /etc/containers/registries.conf"
  run "skopeo inspect docker://registry.access.redhat.com/ubi9/python-311 | head -12"
  run "podman pull registry.access.redhat.com/ubi9/python-311:latest | tail -3"
  pause
fi

# ---------------------------------------------------------------- 4. build
if banner "Build the base and trainer images (multi-stage Containerfile)"; then
  run "cat base/Containerfile | grep -E '^(FROM|LABEL|USER|RUN|COPY|ENV)' | head -16"
  run "podman build --format docker -f base/Containerfile -t localhost/fashion-base:1.0 . 2>&1 | tail -6"
  run "podman build --format docker -f trainer/Containerfile -t localhost/fashion-trainer:1.0 . 2>&1 | tail -6"
  pause
fi

if banner "Build the API and UI images"; then
  run "podman build --format docker -f api/Containerfile -t localhost/fashion-api:1.0 . 2>&1 | tail -6"
  run "podman build --format docker -f ui/Containerfile -t localhost/fashion-ui:1.0 . 2>&1 | tail -6"
  run "podman images --filter reference='localhost/fashion-*'"
  pause
fi

if banner "Image layers, labels, tagging and the build cache"; then
  run "podman history localhost/fashion-api:1.0 | head -12"
  run "podman image inspect localhost/fashion-base:1.0 --format '{{json .Labels}}'"
  run "podman tag localhost/fashion-api:1.0 localhost/fashion-api:latest"
  run "podman build --format docker -f api/Containerfile -t localhost/fashion-api:1.0 . 2>&1 | grep -E 'STEP|Using cache' | head -10"
  pause
fi

# ---------------------------------------------------------------- 7. network
if banner "User-defined network with DNS"; then
  run "podman network create fashion-net"
  run "podman network inspect fashion-net --format '{{.Name}} driver={{.Driver}} dns={{.DNSEnabled}} subnet={{range .Subnets}}{{.Subnet}}{{end}}'"
  run "podman network ls"
  pause
fi

# ---------------------------------------------------------------- 8. storage + secrets
if banner "Named volumes, bind mount with rootless UID mapping, secrets"; then
  run "podman volume create fashion-output"
  run "podman volume create fashion-db"
  run "podman volume ls"
  run "podman unshare cat /proc/self/uid_map"
  run "podman unshare chown -R 1001:0 dataset && ls -ln dataset | head -5"
  mkdir -p secrets
  [ -s secrets/api_token.txt ]   || openssl rand -hex 16 > secrets/api_token.txt
  [ -s secrets/db_password.txt ] || openssl rand -hex 12 > secrets/db_password.txt
  chmod 600 secrets/*.txt
  echo "DB_PASSWORD=$(cat secrets/db_password.txt)" > .env; chmod 600 .env
  run "podman secret create api_token secrets/api_token.txt"
  run "podman secret create db_password secrets/db_password.txt"
  run "podman secret ls"
  run "podman secret inspect db_password --format '{{.Spec.Name}} driver={{.Spec.Driver.Name}} created={{.CreatedAt}}'"
  pause
fi

# ---------------------------------------------------------------- 9. train
if banner "Train the CNN in a one-shot container (about 4 minutes)"; then
  run "podman run --name fashion-trainer --rm --network fashion-net -e EPOCHS=5 --memory 2g -v ./dataset:/data:Z -v fashion-output:/output localhost/fashion-trainer:1.0 2>&1 | grep -E 'STEP|^  (train:|trainable|epoch [0-9]+/|TEST ACCURACY)|\\[(OK |BAD)\\]|saved to'"
  pause
fi

if banner "Export the results from the fashion-output volume"; then
  run "mkdir -p ~/fashion-results && podman volume export fashion-output | tar -x -C ~/fashion-results"
  run "ls -l ~/fashion-results"
  run "python3 -c \"import json; m=json.load(open('$HOME/fashion-results/metrics.json')); print({k: v for k, v in m.items() if not isinstance(v, (list, dict))})\""
  pause
fi

if banner "Detached container: logs, stats and wait (quick run on a scratch volume)"; then
  run "podman volume create fashion-scratch"
  run "podman run -d --name fashion-bg-trainer -e EPOCHS=1 -e TRAIN_LIMIT=3000 -v ./dataset:/data:Z -v fashion-scratch:/output localhost/fashion-trainer:1.0"
  sleep 6
  run "podman ps --filter name=fashion-bg-trainer"
  run "podman stats --no-stream fashion-bg-trainer"
  run "podman logs fashion-bg-trainer | head -8"
  run "podman wait fashion-bg-trainer"
  run "podman rm fashion-bg-trainer; podman volume rm fashion-scratch"
  pause
fi

# ---------------------------------------------------------------- 12. database
if banner "PostgreSQL database container (password from a podman secret)"; then
  run "podman run -d --name fashion-db --network fashion-net -e POSTGRESQL_USER=fashion -e POSTGRESQL_DATABASE=fashion --secret db_password,type=env,target=POSTGRESQL_PASSWORD -v fashion-db:/var/lib/pgsql/data --restart on-failure $DB_IMAGE"
  wait_db
  run "podman logs fashion-db 2>&1 | tail -5"
  run "podman exec fashion-db pg_isready"
  run "podman inspect fashion-db --format '{{.Config.Env}}' | tr ' ' '\n' | grep -i -E 'POSTGRES|PASS'"
  pause
fi

if banner "Load the schema with podman cp and podman exec psql"; then
  run "podman cp db/init.sql fashion-db:/tmp/init.sql"
  run "podman exec fashion-db psql -U fashion -d fashion -q -f /tmp/init.sql"
  run "podman exec fashion-db psql -U fashion -d fashion -c '\\dt'"
  run "podman exec fashion-db psql -U fashion -d fashion -c 'SELECT * FROM fashion_classes'"
  pause
fi

# ---------------------------------------------------------------- 14. api + ui
if banner "Run the API (secrets, health check, restart policy) and the UI"; then
  run "podman run -d --name fashion-api --network fashion-net -p 8000:8000 -e APP_ENV=lab -e DB_HOST=fashion-db --secret api_token --secret db_password -v fashion-output:/output:ro --health-cmd 'python -c \"import urllib.request; urllib.request.urlopen(\\\"http://127.0.0.1:8000/healthz\\\", timeout=4)\"' --health-interval 30s --restart on-failure localhost/fashion-api:1.0"
  run "podman run -d --name fashion-ui --network fashion-net -p 8080:8080 localhost/fashion-ui:1.0"
  wait_api
  run "podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
  pause
fi

if banner "Container DNS and port mapping"; then
  run "podman exec fashion-ui curl -s http://fashion-api:8000/api/info | python3 -m json.tool | head -20"
  run "podman exec fashion-api python -c \"import socket; print('fashion-db ->', socket.gethostbyname('fashion-db'))\""
  run "podman port fashion-ui"
  run "podman port fashion-api"
  pause
fi

if banner "REST API: health, predict, token-protected reload, health check"; then
  run "curl -s localhost:8000/healthz; echo"
  run "curl -s localhost:8000/api/info | python3 -m json.tool | grep -E 'model_loaded|app_env|database|uid|token'"
  IMG=test-images/08-sneaker.png
  [ -f "$IMG" ] || IMG=$(ls ~/fashion-results/*.png | head -1)
  run "curl -s -F file=@$IMG localhost:8000/api/predict | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop(\"preprocessed\"); print(json.dumps(d, indent=1))'"
  run "curl -s -o /dev/null -w 'reload without token -> HTTP %{http_code}\n' -X POST localhost:8000/api/reload"
  run "curl -s -o /dev/null -w 'reload with token    -> HTTP %{http_code}\n' -X POST -H \"X-API-Token: \$(cat secrets/api_token.txt)\" localhost:8000/api/reload"
  run "podman healthcheck run fashion-api && echo healthy"
  pause
fi

if banner "Web UI: open http://localhost:8080 in Firefox"; then
  echo "Open Firefox at http://localhost:8080, wait for the accuracy and sample images,"
  echo "click 'New random images' once, then take a screenshot of the browser (S$(printf '%02d' $STEP))."
  echo "Upload one image from test-images/ in 'Classify your own image' and take a second"
  echo "screenshot (save it as S$(printf '%02d' $STEP)b.png)."
  (command -v firefox >/dev/null && firefox http://localhost:8080 >/dev/null 2>&1 &)
  pause
fi

if banner "Predictions stored in PostgreSQL"; then
  curl -s 'localhost:8000/api/samples?n=12' >/dev/null
  run "podman exec fashion-db psql -U fashion -d fashion -Atc 'SELECT count(*) FROM predictions'"
  run "podman exec fashion-db psql -U fashion -d fashion -c 'SELECT id, source, predicted, true_label, round(confidence::numeric,3) AS conf FROM predictions ORDER BY id DESC LIMIT 8'"
  run "podman exec fashion-db psql -U fashion -d fashion -c 'SELECT * FROM accuracy_by_category'"
  run "curl -s localhost:8000/api/stats | python3 -m json.tool | head -15"
  pause
fi

if banner "Persistence: delete and re-create the database container, then back up"; then
  run "podman exec fashion-db psql -U fashion -d fashion -Atc 'SELECT count(*) FROM predictions'"
  run "podman rm -f fashion-db"
  run "podman run -d --name fashion-db --network fashion-net -e POSTGRESQL_USER=fashion -e POSTGRESQL_DATABASE=fashion --secret db_password,type=env,target=POSTGRESQL_PASSWORD -v fashion-db:/var/lib/pgsql/data --restart on-failure $DB_IMAGE"
  wait_db
  run "podman exec fashion-db psql -U fashion -d fashion -Atc 'SELECT count(*) FROM predictions'   # same number"
  run "podman exec fashion-db pg_dump -U fashion fashion > ~/fashion-db-backup.sql && ls -l ~/fashion-db-backup.sql"
  pause
fi

# ---------------------------------------------------------------- 20. lifecycle
if banner "Container lifecycle: stop, start, restart, pause, unpause"; then
  run "podman stop fashion-ui"
  run "podman ps -a --filter name=fashion-ui --format '{{.Names}} {{.Status}}'"
  run "podman start fashion-ui"
  run "podman restart fashion-api"
  run "podman pause fashion-api"
  run "podman ps --filter name=fashion-api --format '{{.Names}} {{.Status}}'"
  run "podman unpause fashion-api"
  run "podman ps --filter name=fashion-api --format '{{.Names}} {{.Status}}'"
  pause
fi

if banner "Container lifecycle: kill, exit code, remove and re-create"; then
  run "podman kill fashion-ui"
  run "podman inspect fashion-ui --format '{{.State.ExitCode}}'"
  run "podman rm -f fashion-ui"
  run "podman run -d --name fashion-ui --network fashion-net -p 8080:8080 localhost/fashion-ui:1.0"
  run "podman top fashion-api"
  pause
fi

# ---------------------------------------------------------------- 22. troubleshooting
if banner "Troubleshooting: disconnect the API from the network"; then
  wait_api
  run "podman network disconnect fashion-net fashion-api"
  run "curl -s localhost:8000/api/info | python3 -m json.tool | grep database"
  run "podman network connect fashion-net fashion-api"
  sleep 2
  run "curl -s localhost:8000/api/info | python3 -m json.tool | grep database"
  run "podman stop fashion-db"
  run "curl -s localhost:8000/api/info | python3 -m json.tool | grep database"
  run "podman start fashion-db"
  pause
fi

if banner "Troubleshooting: logs, events and inspect"; then
  run "podman logs --tail 6 fashion-api"
  run "podman events --since 10m --until now --filter container=fashion-api --format '{{.Time}} {{.Status}} {{.Name}}' | tail -8"
  run "podman inspect fashion-api --format 'restart={{.HostConfig.RestartPolicy.Name}} health={{.State.Health.Status}} user={{.Config.User}}'"
  run "podman exec fashion-api id"
  pause
fi

# ---------------------------------------------------------------- 24. pods + kube
if banner "Pods: API and UI sharing one network namespace"; then
  run "podman pod create --name fashion-pod -p 8081:8080 --network fashion-net --add-host fashion-api:127.0.0.1"
  run "podman run -d --pod fashion-pod --name fashion-pod-api -e APP_ENV=pod -e DB_HOST=fashion-db --secret api_token --secret db_password -v fashion-output:/output:ro localhost/fashion-api:1.0"
  run "podman run -d --pod fashion-pod --name fashion-pod-ui localhost/fashion-ui:1.0"
  sleep 8
  run "podman pod ps"
  run "podman ps --pod --filter pod=fashion-pod --format 'table {{.Names}}\t{{.Status}}\t{{.PodName}}'"
  run "curl -s localhost:8081/api/info | python3 -m json.tool | grep app_env"
  pause
fi

if banner "Kubernetes YAML: generate kube, kube play, kube down"; then
  run "podman generate kube fashion-pod > ~/fashion-pod-generated.yaml && head -20 ~/fashion-pod-generated.yaml"
  run "podman pod rm -f fashion-pod"
  run "podman kube play kube/fashion-pod.yaml"
  sleep 8
  run "curl -s localhost:8082/api/info | python3 -m json.tool | grep app_env"
  run "podman kube down kube/fashion-pod.yaml"
  pause
fi

# ---------------------------------------------------------------- 26. compose
if banner "podman-compose: the whole stack from compose.yaml"; then
  podman rm -f fashion-api fashion-ui fashion-db >/dev/null 2>&1
  run "podman-compose config | head -25"
  run "EPOCHS=1 podman-compose up -d 2>&1 | tail -8"
  sleep 10
  run "podman-compose ps"
  pause
fi

if banner "podman-compose: logs and down"; then
  run "podman-compose logs trainer 2>&1 | grep -E 'STEP|TEST ACCURACY' | head -8"
  run "podman-compose down 2>&1 | tail -6"
  run "podman volume ls"
  pause
fi

# ---------------------------------------------------------------- 28. registry push
if banner "Push the images to the Docker Hub registry"; then
  if [ -z "${REGISTRY:-}" ]; then
    [ -n "${DOCKER_USER:-}" ] || read -rp "Docker Hub user name: " DOCKER_USER
    REGISTRY=docker.io/$DOCKER_USER
  fi
  run "podman login ${REGISTRY%%/*} -u ${REGISTRY#*/}"
  for i in base trainer api ui; do
    run "podman tag localhost/fashion-$i:1.0 $REGISTRY/fashion-$i:1.0"
  done
  for i in base trainer api ui; do
    run "podman push $REGISTRY/fashion-$i:1.0 2>&1 | tail -2"
  done
  pause
fi

if banner "Verify the registry: skopeo inspect, pull, save and load"; then
  run "skopeo inspect docker://$REGISTRY/fashion-api:1.0 | head -14"
  run "podman rmi $REGISTRY/fashion-api:1.0"
  run "podman pull $REGISTRY/fashion-api:1.0 | tail -2"
  run "podman images --filter reference='$REGISTRY/*'"
  run "podman save -o ~/fashion-api.tar localhost/fashion-api:1.0 && ls -lh ~/fashion-api.tar"
  run "podman load -i ~/fashion-api.tar | tail -1"
  pause
fi

# ---------------------------------------------------------------- 30. leave it running
if banner "Final state: stack running again for the demo"; then
  podman rm -f fashion-api fashion-ui fashion-db >/dev/null 2>&1
  podman network exists fashion-net || podman network create fashion-net >/dev/null
  ./scripts/04-run-network.sh >/dev/null 2>&1
  wait_api
  run "podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
  run "curl -s localhost:8000/healthz; echo"
  pause
fi

clear
echo "Done. Screenshots/text output are in $OUT"
ls "$OUT"
echo
echo "Images pushed to $REGISTRY/fashion-{base,trainer,api,ui}:1.0"
