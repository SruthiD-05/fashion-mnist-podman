# Fashion Item Classifier on Podman — DO188 lab guide

**Problem statement:** identify clothing categories from images.
Load the Fashion-MNIST dataset, build and train a CNN, evaluate accuracy on the test set, and show sample predictions with true labels.

You do all of it with containers in your Red Hat lab (RHEL + Podman, rootless, SELinux enforcing, CPU only). Every step uses a DO188 concept, and the table at the end maps each concept to the step where it shows up.

**Built for a lab that can only reach the Red Hat registry.** The CNN is written in plain NumPy (forward pass, backpropagation and the Adam optimizer, in `common/fmnist.py`), so no PyTorch/TensorFlow download is needed. The project ships the Fashion-MNIST dataset (`dataset/*.gz`, 30 MB) and every Python package as wheels (`wheels/*.whl`, 38 MB). The images are built from UBI images plus those bundled files, with no PyPI and no internet.

Tested result: **90.55 % test accuracy after 5 epochs** (about 3.5 minutes on 4 CPUs).

> **Already did the lab with the first version (no database)?** Your trained model is kept in the `fashion-output` volume, so you don't need to train again. Extract the new bundle over the old folder, then run:
> ```bash
> ./scripts/01-build.sh                       # rebuild: the API now has a database driver
> ./scripts/02-prepare.sh                     # adds the fashion-db volume, db_password secret, .env
> podman rm -f fashion-api fashion-ui         # old containers
> ./scripts/04-run-network.sh                 # database + API + UI
> ```
> Then read parts 7a and 8 ("More container commands") for the new material.

---

## 0. What you will build

```
                          podman network: fashion-net  (DNS by container name)
 ┌──────────────────────┐   ┌──────────────────────┐        ┌──────────────────────┐
 │ fashion-trainer      │   │ fashion-api          │ <----- │ fashion-ui           │ <-- browser
 │ (one-shot job)       │   │ Flask + gunicorn     │ /api/  │ UBI nginx, port 8080 │     http://localhost:8080
 │ loads Fashion-MNIST  │   │ port 8000            │        │ static page + proxy  │
 │ trains CNN, evaluates│   │ secrets: api_token,  │        └──────────────────────┘
 │ writes PNG + metrics │   │          db_password │
 └─────────┬────────────┘   └───┬─────────────┬────┘
   /data   │  /output   /output │ (read-only) │ SQL :5432 (saves every prediction)
   ▼       ▼                    ▼             ▼
 ./dataset          fashion-output        ┌──────────────────────┐
 (bind mount, :Z)   (named volume)        │ fashion-db           │
                                          │ PostgreSQL 15 sclorg │
                                          │ secret: db_password  │
                                          └─────────┬────────────┘
                                                    ▼ /var/lib/pgsql/data
                                              fashion-db (named volume)
```

Four images you build, all on Red Hat Universal Base Images (UBI), plus Red Hat's ready-made PostgreSQL image:

| Image | Built from | Purpose |
|---|---|---|
| `localhost/fashion-base:1.0` | **multi-stage**: `ubi9/python-311` (builder) → `ubi9/ubi-minimal` (runtime) | Python 3.11 + NumPy/Matplotlib/Flask + shared CNN code |
| `localhost/fashion-trainer:1.0` | `fashion-base` | Steps 1–4 of the problem statement; writes results |
| `localhost/fashion-api:1.0` | `fashion-base` | REST API that serves predictions |
| `localhost/fashion-ui:1.0` | `ubi9/nginx-122` | Web page showing accuracy, sample predictions, prediction history and charts |
| `quay.io/sclorg/postgresql-15-c9s` (pulled, not built) | Red Hat Software Collections (same as `rhel9/postgresql-15`) | Database that stores every prediction |

Project layout:

```
fashion-mnist-podman/
├── README.md                 ← this guide
├── common/fmnist.py          ← dataset loader + CNN model (shared)
├── base/Containerfile        ← multi-stage base image
├── base/requirements.txt
├── trainer/Containerfile, train.py
├── api/Containerfile, app.py, db.py
├── db/init.sql               ← database schema + reference data (loaded with podman cp/exec)
├── ui/Containerfile, index.html, nginx-api.conf
├── compose.yaml              ← podman-compose version of the whole stack
├── kube/fashion-pod.yaml     ← podman kube play
├── openshift/fashion-app.yaml← optional OpenShift deployment
├── scripts/00-…99-*.sh       ← shortcuts for each part (they print every command)
├── offline/                  ← helper for labs without internet
├── reference-results/        ← my tested run (90.55%) and a UI screenshot, to compare with yours
├── dataset/                  ← Fashion-MNIST .gz files (bundled) + SHA256SUMS
├── wheels/                   ← all Python packages as wheels (bundled, used by the build)
└── .containerignore
```

> Every part below gives the exact commands. The `scripts/` do the same thing if you want a shortcut, but type the commands yourself at least once: that is the point of the lab.

---

## 1. Get the project into the lab

Copy `fashion-mnist-podman.tar.gz` to the lab machine (for example, `scp fashion-mnist-podman.tar.gz student@workstation:~`), then:

```bash
cd ~
tar xzf fashion-mnist-podman.tar.gz
cd fashion-mnist-podman
chmod +x scripts/*.sh offline/*.sh
```

All the commands below are run from `~/fashion-mnist-podman` as your normal user (**rootless Podman, never sudo**).

## 2. Check the lab machine

```bash
./scripts/00-check-lab.sh
```

It shows the Podman version, whether you are rootless, SELinux mode, CPU/RAM/disk, which hosts the lab can reach, and checks the bundled dataset files against their checksums.

* **UBI registry OK** → you can do the whole lab. PyPI and the dataset URL failing is expected and fine.
* **UBI RPM repo FAIL** → also fine; the base build then uses `ubi9/python-311` for its runtime stage (see part 4).
* **UBI registry FAIL** → read [section 14, Offline lab](#14-offline-lab) first.

You need about **3 GB of free disk** and **1 GB of free RAM**. Training takes about 40 seconds per epoch on 4 CPUs (roughly 1.5 minutes on a 2-CPU lab VM).

---

## 3. Podman basics (warm-up)

```bash
podman version
podman info | less                    # rootless? storage? registries?
cat /etc/containers/registries.conf   # unqualified-search-registries

# Find and inspect images without pulling them
skopeo list-tags docker://registry.access.redhat.com/ubi9/python-311 | tail -5
skopeo inspect docker://registry.access.redhat.com/ubi9/python-311 | head -30

# Pull the base images the Containerfiles use
podman pull registry.access.redhat.com/ubi9/python-311:latest
podman pull registry.access.redhat.com/ubi9/ubi-minimal:latest
podman pull registry.access.redhat.com/ubi9/nginx-122:latest
podman images

# Run a throw-away interactive container
podman run -it --rm registry.access.redhat.com/ubi9/python-311 python3 -c "import sys; print(sys.version)"
podman run -it --rm --name tryme registry.access.redhat.com/ubi9/ubi-minimal bash
#   inside: id ; cat /etc/redhat-release ; exit
```

`registry.access.redhat.com` needs no login. To use the authenticated registry instead:

```bash
podman login registry.redhat.io        # Red Hat account / registry service account
```

and add `--build-arg BUILDER_IMAGE=registry.redhat.io/ubi9/python-311 --build-arg RUNTIME_IMAGE=registry.redhat.io/ubi9/ubi-minimal` to the base build in part 4. In the DO188 classroom, use the classroom registry the same way if your instructor says so (for example `registry.ocp4.example.com:8443/...`).

---

## 4. Build the images (Containerfiles)

Open each Containerfile and read the comments before you build. Things to notice:

* **`base/Containerfile`** has two `FROM` lines, so it is a **multi-stage** build. Stage 1 (`ubi9/python-311`, which has pip and compilers) installs the packages from the bundled `wheels/` into `/opt/venv` (`pip install --no-index --find-links=/wheels`: no PyPI). Stage 2 starts again from the tiny `ubi-minimal` and copies **only** `/opt/venv` with `COPY --from=builder`. Compilers and pip caches never reach the final image.
* `ARG` sets build-time values (base image names, `PIP_OPTS`, version); `ENV` sets run-time defaults you can override with `podman run -e`.
* `LABEL` adds metadata (`name`, `version`, `summary`, `io.k8s.display-name`).
* `USER 1001`: the containers never run as root. Directories are `chown 1001:0` + `chmod g=u` so that OpenShift's random UIDs (which are always in group 0) can write too.
* `trainer`: `VOLUME`, `ENTRYPOINT` (exec form). `api`: `EXPOSE`, `HEALTHCHECK`, `CMD`. `ui`: uses the `${NGINX_DEFAULT_CONF_PATH}` variable from the UBI nginx image.
* `.containerignore` keeps `dataset/`, scripts and docs out of the build context.

The build context is always the **project root** (`.`), and `-f` selects the Containerfile:

```bash
podman build --format docker -f base/Containerfile    -t localhost/fashion-base:1.0    .
#   if the check showed "UBI RPM repo FAIL", add this before -f:
#   --build-arg RUNTIME_IMAGE=registry.access.redhat.com/ubi9/python-311
podman build --format docker -f trainer/Containerfile -t localhost/fashion-trainer:1.0 .
podman build --format docker -f api/Containerfile     -t localhost/fashion-api:1.0     .
podman build --format docker -f ui/Containerfile      -t localhost/fashion-ui:1.0      .
```

(or `./scripts/01-build.sh`, which picks the right `RUNTIME_IMAGE` for you). The base build takes the longest. `--format docker` is needed because the OCI image format has no `HEALTHCHECK`; without it Podman warns and drops the healthcheck.

Look at what you built:

```bash
podman images --filter reference='localhost/fashion-*'
podman history localhost/fashion-api:1.0                 # one layer per instruction
podman image inspect localhost/fashion-base:1.0 --format '{{json .Labels}}'
podman image inspect localhost/fashion-api:1.0 --format '{{.Config.User}} {{.Config.ExposedPorts}} {{.Config.Cmd}}'
podman run --rm localhost/fashion-base:1.0               # default CMD prints the Python/NumPy versions

# Tags are just extra names for the same image ID
podman tag localhost/fashion-api:1.0 localhost/fashion-api:latest
podman images localhost/fashion-api

# Layer caching: change nothing and rebuild — every step says "Using cache"
podman build --format docker -f api/Containerfile -t localhost/fashion-api:1.0 .
```

---

## 5. Network, storage and secrets

```bash
# A user-defined network gives containers DNS names (container name = hostname)
podman network create fashion-net
podman network inspect fashion-net

# A named volume, managed by podman, shared by trainer (writes) and api (reads)
podman volume create fashion-output
podman volume inspect fashion-output

# A bind-mount directory for the dataset cache (survives everything, lives in the project)
mkdir -p dataset

# A second named volume for the PostgreSQL data files (part 7)
podman volume create fashion-db

# Secrets: a random token the API uses to protect /api/reload, and the database password
mkdir -p secrets
openssl rand -hex 16 > secrets/api_token.txt
openssl rand -hex 12 > secrets/db_password.txt
chmod 600 secrets/*.txt
podman secret create api_token secrets/api_token.txt
podman secret create db_password secrets/db_password.txt
podman secret ls
podman secret inspect db_password        # metadata only, never the value

# podman-compose (part 10) reads the database password from .env
echo "DB_PASSWORD=$(cat secrets/db_password.txt)" > .env
```

**Rootless UID mapping.** The containers run as UID 1001, which inside your user namespace is *not* your host user, so it cannot write to `./dataset` yet. Look at the mapping and fix the ownership:

```bash
podman unshare cat /proc/self/uid_map      # container UIDs → your subordinate UIDs
podman unshare chown -R 1001:0 dataset     # give the dir to container UID 1001
ls -ln dataset                             # host view: a big subordinate UID
```

(or `./scripts/02-prepare.sh` for this whole section)

---

## 6. Train, evaluate, and show sample predictions (the problem statement)

```bash
podman run --name fashion-trainer --rm \
  --network fashion-net \
  -e EPOCHS=5 \
  --memory 2g \
  -v ./dataset:/data:Z \
  -v fashion-output:/output \
  localhost/fashion-trainer:1.0
```

* `-v ./dataset:/data:Z` is a **bind mount**; `:Z` relabels it for SELinux so the container may use it.
* `-v fashion-output:/output` is the **named volume**.
* `-e EPOCHS=5` overrides the `ENV` default from the Containerfile. Use `-e EPOCHS=1` (or `-e TRAIN_LIMIT=10000`) for a quick first try.
* `--memory 2g` is a resource limit; `--rm` deletes the container when it exits.

The log walks through the four required steps:

```
STEP 1/4  Load the Fashion-MNIST dataset      → downloads 4 files into ./dataset (once)
STEP 2/4  Build and train the CNN             → prints the model and loss/accuracy per epoch
STEP 3/4  Evaluate accuracy on the test set   → TEST ACCURACY: ~90.5% (+ per class)
STEP 4/4  Show sample predictions with true labels → 20 lines like [OK ] predicted=Sneaker true=Sneaker
```

Results in the `fashion-output` volume: `sample_predictions.png` (20 test images titled *Pred / True*, green = correct, red = wrong), `confusion_matrix.png`, `training_curve.png`, `metrics.json`, `model.pt`, `test_subset.npz`.

Get the results out to your home directory:

```bash
mkdir -p ~/fashion-results
podman volume export fashion-output | tar -x -C ~/fashion-results
ls -l ~/fashion-results
python3 -m json.tool ~/fashion-results/metrics.json | head -20
xdg-open ~/fashion-results/sample_predictions.png    # or open it in the lab's file browser
```

Run it again: the dataset now comes from the bind mount (`using cached /data/...`), with no download. The volume keeps the newest model.

Try running the trainer **in the background** and following the logs:

```bash
podman run -d --name fashion-trainer -e EPOCHS=2 --network fashion-net \
  -v ./dataset:/data:Z -v fashion-output:/output localhost/fashion-trainer:1.0
podman logs -f fashion-trainer          # Ctrl+C stops following, not the container
podman stats --no-stream fashion-trainer
podman wait fashion-trainer             # prints the exit code (0 = success)
podman rm fashion-trainer
```

---

## 7. Serve the model: database + API + web UI on the network

### 7a. The PostgreSQL database container

The API saves every prediction it makes (test samples and uploads) in a PostgreSQL database. The database runs from the PostgreSQL 15 image built by Red Hat's Software Collections team (`quay.io/sclorg/postgresql-15-c9s`, the public CentOS Stream build of `rhel9/postgresql-15`), keeps its files on the `fashion-db` named volume, and gets its password from the `db_password` secret **as an environment variable**:

```bash
podman run -d --name fashion-db \
  --network fashion-net \
  -e POSTGRESQL_USER=fashion \
  -e POSTGRESQL_DATABASE=fashion \
  --secret db_password,type=env,target=POSTGRESQL_PASSWORD \
  -v fashion-db:/var/lib/pgsql/data \
  --restart on-failure \
  quay.io/sclorg/postgresql-15-c9s:latest

podman logs -f fashion-db       # wait for "Starting server...", then Ctrl+C
podman exec fashion-db pg_isready
```

> **Want the RHEL image?** `registry.access.redhat.com` refuses it ("requires terms acceptance and is only available on registry.redhat.io"). With a Red Hat account: `podman login registry.redhat.io`, then use `registry.redhat.io/rhel9/postgresql-15` (same variables). With the script: `DB_IMAGE=registry.redhat.io/rhel9/postgresql-15 ./scripts/04-run-network.sh`. This is also a good registry exercise: compare both with `skopeo inspect`.

Load the schema and reference data. Copy the SQL file **into** the running container, then run it there:

```bash
podman cp db/init.sql fashion-db:/tmp/init.sql
podman exec fashion-db psql -U fashion -d fashion -f /tmp/init.sql
podman exec fashion-db psql -U fashion -d fashion -c '\dt'              # tables
podman exec fashion-db psql -U fashion -d fashion -c 'SELECT * FROM fashion_classes'
```

Things to notice:
* The image runs as UID 26 (`podman exec fashion-db id`), not root.
* `podman inspect fashion-db --format '{{.Config.Env}}'` lists `POSTGRESQL_USER` and `POSTGRESQL_DATABASE` but **not** the password. The secret is injected only when the container starts.
* No `-p` here: only containers on `fashion-net` can reach the database. It is not exposed on the host.

### 7b. API and web UI

The API gets the same `db_password` secret, this time **as a file** (`/run/secrets/db_password`), plus `DB_HOST=fashion-db`:

```bash
podman run -d --name fashion-api \
  --network fashion-net \
  -p 8000:8000 \
  -e APP_ENV=lab \
  -e DB_HOST=fashion-db \
  --secret api_token \
  --secret db_password \
  -v fashion-output:/output:ro \
  --restart on-failure \
  localhost/fashion-api:1.0

podman run -d --name fashion-ui \
  --network fashion-net \
  -p 8080:8080 \
  localhost/fashion-ui:1.0

podman ps
```

(or `./scripts/04-run-network.sh` for all of part 7: database, SQL load, API and UI). Start the API **before** the UI: nginx looks up the name `fashion-api` when it starts.

Test it:

```bash
curl -s localhost:8000/healthz
curl -s localhost:8000/api/info | python3 -m json.tool      # "database": "ok"
curl -s localhost:8000/api/metrics | python3 -m json.tool | head
curl -s 'localhost:8000/api/samples?n=3' | python3 -c \
  'import sys,json; [print(s["predicted"], "| true:", s["true"]) for s in json.load(sys.stdin)["samples"]]'

# Classify one of the result images (any PNG/JPG works)
curl -s -F file=@$HOME/fashion-results/confusion_matrix.png localhost:8000/api/predict

# What the database stored
curl -s 'localhost:8000/api/history?limit=5' | python3 -m json.tool
curl -s localhost:8000/api/stats | python3 -m json.tool

# Through the UI container's nginx proxy
curl -s localhost:8080/api/info
```

Open **http://localhost:8080** in the lab's browser. The page (one HTML file in the `fashion-ui` image, `ui/index.html`) shows:
* status pills at the top: model loaded, PostgreSQL connected, and which API container answered;
* key numbers: test accuracy, epochs, training time, rows stored in the database;
* **sample predictions with true labels**: 6, 12 or 24 random test images with a ✓/✗ badge and a confidence bar (click **New random images** for more);
* **Classify your own image**: drag and drop a photo, and see your image, the 28×28 version the model sees, and the top 3 classes;
* accuracy per clothing type, the training curve, and an interactive confusion matrix (hover a cell), all drawn from `metrics.json`;
* **Prediction history (PostgreSQL container)**: totals and the latest rows of the `predictions` table, with a filter (test images, uploads, mistakes only);
* the three PNG files the trainer wrote (click to enlarge);
* a light/dark switch (moon icon) at the top right.

Compare with `reference-results/web-ui.png`.

Query the data directly with SQL:

```bash
podman exec -it fashion-db psql -U fashion -d fashion
#   SELECT count(*) FROM predictions;
#   SELECT predicted, true_label, confidence FROM predictions ORDER BY id DESC LIMIT 5;
#   SELECT * FROM accuracy_by_category;
#   \q
```

**Persistence test.** Remove the database container completely and start a new one on the same volume. The rows are still there:

```bash
podman exec fashion-db psql -U fashion -d fashion -Atc 'SELECT count(*) FROM predictions'
podman rm -f fashion-db
podman run -d --name fashion-db --network fashion-net \
  -e POSTGRESQL_USER=fashion -e POSTGRESQL_DATABASE=fashion \
  --secret db_password,type=env,target=POSTGRESQL_PASSWORD \
  -v fashion-db:/var/lib/pgsql/data \
  quay.io/sclorg/postgresql-15-c9s:latest
sleep 5
podman exec fashion-db psql -U fashion -d fashion -Atc 'SELECT count(*) FROM predictions'   # same number
```

Back up the database to your home directory, from inside the container:

```bash
podman exec fashion-db pg_dump -U fashion fashion > ~/fashion-db-backup.sql
ls -lh ~/fashion-db-backup.sql
```

The secrets, in action:

```bash
podman exec fashion-api cat /run/secrets/api_token      # secrets are files in the container...
podman exec fashion-api ls -l /run/secrets/
curl -s -X POST localhost:8000/api/reload                                    # 401
curl -s -X POST -H "X-API-Token: $(cat secrets/api_token.txt)" localhost:8000/api/reload  # 200
podman inspect fashion-api --format '{{.Config.Env}}'   # ...and NOT in the env list
podman exec fashion-db printenv POSTGRESQL_PASSWORD     # ...unless you ask for type=env (the db)
```

Container-to-container DNS:

```bash
podman exec fashion-ui curl -s http://fashion-api:8000/api/info
podman exec fashion-api python -c "import socket; print(socket.gethostbyname('fashion-db'))"
podman inspect fashion-api --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
podman port fashion-ui
```

Healthcheck (kept because of `--format docker`):

```bash
podman healthcheck run fashion-api && echo healthy
podman inspect fashion-api --format '{{.State.Health.Status}}'
```

---

## 8. Troubleshooting toolkit, things to break on purpose, and more commands

```bash
podman logs fashion-api                 # gunicorn access log + app log
podman logs --tail 20 -f fashion-ui
podman logs fashion-db                  # PostgreSQL start-up and errors
podman exec -it fashion-api bash        # look around: id, ls -l /output, env | sort
podman top fashion-api                  # processes, user
podman inspect fashion-api | less       # mounts, network, env, restart policy
podman stats --no-stream
podman events --since 10m               # what podman did
podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

**Break 1: SELinux.** Run the trainer with `-v ./dataset:/data` (no `:Z`). You get *Permission denied* even though the files exist. Check `ls -Z dataset` and `sudo ausearch -m avc -ts recent` if you have sudo. Add `:Z` back.

**Break 2: rootless UID mapping.** `podman unshare chown -R 0:0 dataset`, then rerun the trainer: *Permission denied* while downloading. Fix it with `podman unshare chown -R 1001:0 dataset`.

**Break 3: start order / DNS.** `podman rm -f fashion-api fashion-ui`, then start **only** the UI. `podman ps -a` shows it exited; `podman logs fashion-ui` says `host not found in upstream "fashion-api"`. Start the API, then `podman start fashion-ui`.

**Bonus:** start a second API with `-p 8000:8000` and read the *address already in use* error; run the trainer with `--memory 200m` and look for exit code 137 (killed for memory) with `podman inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}}'`.

**Break 4: database down.** `podman stop fashion-db`, then click **Show 12 new random images** in the UI. Predictions still work, but the history card says *Database not connected* and `curl -s localhost:8000/api/info` shows `"database": "error: ..."`. `podman logs fashion-api` has the warning. Fix it with `podman start fashion-db`.

### More container commands

**Copy files in and out of a container (`podman cp`):**

```bash
podman cp fashion-api:/output/metrics.json ~/metrics-from-container.json   # out of a container
podman cp db/init.sql fashion-db:/tmp/init.sql                             # into a container
podman exec fashion-db ls -l /tmp/init.sql
```

**Connect and disconnect networks on a running container:**

```bash
podman network create lab-extra
podman network connect lab-extra fashion-api
podman inspect fashion-api --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'   # fashion-net lab-extra
podman run --rm --network lab-extra localhost/fashion-base:1.0 \
  python -c "import urllib.request; print(urllib.request.urlopen('http://fashion-api:8000/api/info').read()[:80])"
podman network disconnect lab-extra fashion-api        # now that same test fails
podman network rm lab-extra

# Cut the API off from the database and watch the history card break, then repair it
podman network disconnect fashion-net fashion-db
curl -s localhost:8000/api/info | python3 -m json.tool | grep database
podman network connect fashion-net fashion-db
```

**Container lifecycle:**

```bash
podman stop fashion-ui              # SIGTERM, then SIGKILL after 10 s
podman ps -a --filter name=fashion-ui
podman start fashion-ui
podman restart fashion-api          # the API reconnects to the database on its own
podman pause fashion-api            # processes frozen: curl now hangs (Ctrl+C)
podman ps --filter name=fashion-api # STATUS: Paused
podman unpause fashion-api
podman kill fashion-ui              # SIGKILL right away; exit code 137
podman inspect fashion-ui --format '{{.State.ExitCode}}'
podman start fashion-ui
podman rm fashion-ui                # fails: a running container needs -f
```

**Live editing through a bind mount (the developer workflow).** Mount the source folder over the one baked into the image, change a file on the host, and see the change without rebuilding. Mount the **folder**, not a single file: `sed -i` and most editors save a new file, and a single-file bind mount would keep showing the old one.

```bash
# UI: nginx serves the file straight from your project folder
podman run -d --name fashion-dev-ui --network fashion-net -p 8090:8080 \
  -v ./ui:/opt/app-root/src:Z \
  localhost/fashion-ui:1.0
sed -i 's/<h1>Fashion Item Classifier<\/h1>/<h1>Fashion Item Classifier (DEV)<\/h1>/' ui/index.html
#   reload http://localhost:8090: the title now says (DEV)

# API: GUNICORN_CMD_ARGS=--reload restarts the worker when app.py changes
podman run -d --name fashion-dev-api --network fashion-net -p 8001:8000 \
  -e APP_ENV=dev -e GUNICORN_CMD_ARGS=--reload \
  -e DB_HOST=fashion-db --secret db_password \
  -v fashion-output:/output:ro \
  -v ./api:/opt/app-root/src:Z \
  localhost/fashion-api:1.0
sed -i 's/APP_ENV = os.environ.get("APP_ENV", "dev")/APP_ENV = os.environ.get("APP_ENV", "dev") + "-edited"/' api/app.py
sleep 3; curl -s localhost:8001/api/info | grep -o '"app_env":"[^"]*"'   # "dev-edited"
podman logs fashion-dev-api | grep -i reload

# Undo the edits and remove the dev containers
sed -i 's/ (DEV)<\/h1>/<\/h1>/' ui/index.html
sed -i 's/ + "-edited"//' api/app.py
podman rm -f fashion-dev-ui fashion-dev-api
```

When you are happy with a change, make it permanent with `podman build` (part 4). The image, not the bind mount, is what you ship.


---

## 9. Pods: containers that share localhost

```bash
podman pod create --name fashion-pod -p 8081:8080 \
  --network fashion-net --add-host fashion-api:127.0.0.1
podman run -d --pod fashion-pod --name fashion-pod-api -e APP_ENV=pod \
  -e DB_HOST=fashion-db --secret api_token --secret db_password \
  -v fashion-output:/output:ro localhost/fashion-api:1.0
podman run -d --pod fashion-pod --name fashion-pod-ui localhost/fashion-ui:1.0

podman pod ps
podman ps --pod
curl -s localhost:8081/api/info          # APP_ENV is "pod"
```

(or `./scripts/05-run-pod.sh`). The port is published on the **pod**, not on the containers, and the UI reaches the API at `127.0.0.1:8000` because they share one network namespace (that is why `--add-host` points `fashion-api` at 127.0.0.1). The extra `*-infra` container holds the namespace. The pod also joins `fashion-net`, so its API still reaches the `fashion-db` container from part 7 by name, and both APIs write to the same database.

Generate Kubernetes YAML from the running pod, then replay a prepared YAML:

```bash
podman generate kube fashion-pod > ~/fashion-pod-generated.yaml
less ~/fashion-pod-generated.yaml

podman pod rm -f fashion-pod
podman kube play kube/fashion-pod.yaml   # pod "fashion-kube", UI on port 8082
curl -s localhost:8082/api/info          # APP_ENV is "kube-play", database "disabled"
podman kube down kube/fashion-pod.yaml
```

---

## 10. The whole stack with podman-compose

Stop the containers from part 7 first (they use the same names and ports):

```bash
podman rm -f fashion-api fashion-ui fashion-db
```

`.env` and `secrets/*.txt` must exist (part 5 or `./scripts/02-prepare.sh`). Compose secrets can only be files, so the database password reaches the `db` service through `.env` and reaches the API as a secret file.

If `podman-compose` is not installed: `pip3 install --user podman-compose` (or `sudo dnf install podman-compose` where EPEL is available).

```bash
podman-compose config            # validated, merged view of compose.yaml
EPOCHS=2 podman-compose up -d    # builds if needed, trainer runs once, api + ui stay up
podman-compose ps
podman-compose logs -f trainer   # watch training; Ctrl+C when DONE
podman-compose logs api
curl -s localhost:8080/api/info  # APP_ENV is "compose"
podman-compose down              # removes containers + network (volume is kept)
```

Compose creates its own `fashion_fashion-db` volume, so the history starts empty. Load the reference data the same way as in part 7: `podman cp db/init.sql fashion-db:/tmp/ && podman exec fashion-db psql -U fashion -d fashion -f /tmp/init.sql`.

Read `compose.yaml` and match each key to the `podman run` flag you used by hand: `image`/`build`, `environment` (`-e`), `volumes` (`-v`, with `:Z` and `:ro`), `networks`, `ports` (`-p`), `secrets` (`--secret`), `depends_on` (start order), `restart`. Compose names the volume `fashion_fashion-output`, so the first run trains a fresh model.

---

## 11. Registries: tag, push, pull, save/load

Pick a registry you can push to: a free **quay.io** account, or the classroom registry.

```bash
podman login quay.io
REGISTRY=quay.io/<your-quay-user>

podman tag localhost/fashion-api:1.0 $REGISTRY/fashion-api:1.0
podman push $REGISTRY/fashion-api:1.0
skopeo inspect docker://$REGISTRY/fashion-api:1.0 | head -20

podman rmi $REGISTRY/fashion-api:1.0     # removes only the tag
podman pull $REGISTRY/fashion-api:1.0    # pulled back from the registry
```

`REGISTRY=quay.io/<user> ./scripts/06-push.sh` pushes all three app images. New quay.io repositories are **private**: make them public in the quay web UI if OpenShift has to pull them without a pull secret.

Moving images without a registry:

```bash
podman save -o fashion-api.tar localhost/fashion-api:1.0
podman load -i fashion-api.tar
```

---

## 12. Optional: deploy to OpenShift

Needs an OpenShift cluster (DO188 classroom cluster, Developer Sandbox, or OpenShift Local) and the images pushed in part 11.

```bash
oc login <cluster-api-url> -u <user>
oc new-project fashion-mnist
sed -i "s#REGISTRY#$REGISTRY#g" openshift/fashion-app.yaml
oc apply -f openshift/fashion-app.yaml

oc get pods -w                      # db starts, trainer Job runs, then api becomes Ready
oc logs -f job/fashion-trainer      # same STEP 1..4 output as in podman
oc rollout restart deployment/fashion-api   # pick up the freshly trained model
oc get route fashion-ui -o jsonpath='{.spec.host}{"\n"}'

# Load the reference data, the OpenShift way (oc cp / oc exec instead of podman cp / exec)
DB_POD=$(oc get pod -l component=db -o name | cut -d/ -f2)
oc cp db/init.sql $DB_POD:/tmp/init.sql
oc exec $DB_POD -- psql -U fashion -d fashion -f /tmp/init.sql
```

Open `http://<that host>`. The YAML maps one-to-one onto what you did with Podman: named volume → PVC, podman secret → Secret, `podman run --rm` → Job, long-running containers → Deployments, network DNS name → Services `fashion-api` and `fashion-db`, `--secret ...,type=env` → `secretKeyRef`, `-p` → Route. OpenShift runs the containers with a random UID in group 0, which the `chown 1001:0` + `chmod g=u` in the Containerfiles already allow for.

---

## 13. Clean up

```bash
./scripts/99-cleanup.sh            # containers, pods, volumes (incl. the database!), network, secrets
./scripts/99-cleanup.sh --images   # ...and the fashion images
podman image prune                 # dangling layers from rebuilds
podman system df
```

---

## 14. Offline lab

The project is already offline-ready: the dataset and all Python wheels are inside it, so the only network access the lab needs is **pulling the three UBI images**.

| Failed check | What it means |
|---|---|
| Dataset URL | Nothing to do: the trainer finds the 4 `.gz` files in `./dataset` (`using cached /data/...`). Add `-e OFFLINE=true` to make it fail fast instead of trying to download if a file is missing. |
| PyPI | Nothing to do: the build installs only from the bundled `wheels/`. |
| UBI RPM repo (microdnf) | `scripts/01-build.sh` switches to `RUNTIME_IMAGE=registry.access.redhat.com/ubi9/python-311` automatically. By hand, add that `--build-arg`. |
| UBI registry | If your lab has its own registry mirror (for example the DO188 classroom registry), pass it: `--build-arg BUILDER_IMAGE=<mirror>/ubi9/python-311 --build-arg RUNTIME_IMAGE=<mirror>/ubi9/python-311` for the base and `--build-arg NGINX_IMAGE=<mirror>/ubi9/nginx-122` for the UI. With no registry at all, build the images on a machine with internet (`./offline/fetch-on-internet-machine.sh --images`), copy `offline/images/fashion-images.tar` to the lab and run `podman load -i offline/images/fashion-images.tar`. |

---

## 15. Expected results

* Test accuracy after 5 epochs: **about 90.5 %** (tested: 90.55 %; 1 epoch: about 88 %).
* Easiest classes: Trouser, Sandal, Bag (≈ 98–99 %). Hardest: **Shirt** (≈ 76 %), mostly confused with T-shirt/top, Pullover and Coat (see `confusion_matrix.png`).
* `sample_predictions.png`: typically 18–19 of 20 correct.
* Image sizes, roughly: base ≈ 350 MB with `ubi-minimal` (≈ 1 GB with the `python-311` fallback), trainer/api a few KB more than base (shared layers), ui ≈ 400 MB.

---

## DO188 concept map

| DO188 topic | Where in this lab |
|---|---|
| Container & image basics, rootless Podman | Parts 2–3: `podman version/info/search/pull/run/images`, `skopeo inspect` |
| Registries, `registries.conf`, `podman login` | Part 3 (registry.access.redhat.com / registry.redhat.io), part 11 (quay.io) |
| UBI and Red Hat images | All 4 images: `ubi9/python-311`, `ubi9/ubi-minimal`, `ubi9/nginx-122`; database from `sclorg/postgresql-15-c9s` (or `registry.redhat.io/rhel9/postgresql-15` after `podman login`) |
| Containerfile instructions | `FROM, ARG, ENV, LABEL, RUN, COPY (--from, --chown), WORKDIR, USER, EXPOSE, VOLUME, HEALTHCHECK, ENTRYPOINT, CMD` |
| Multi-stage builds, small images, layer cache | `base/Containerfile`, part 4 (`podman history`, rebuild with cache) |
| Image layering / custom base images | trainer + api are `FROM localhost/fashion-base` |
| `.containerignore`, build context | Project root context with `-f`, `.containerignore` |
| Tagging, push, pull, save/load | Parts 4 and 11 |
| Non-root & OpenShift-friendly images | `USER 1001`, `chown 1001:0`, `chmod g=u`, part 12 |
| Environment variables | `ENV` defaults + `-e EPOCHS=…`, `APP_ENV`, `POSTGRESQL_USER/DATABASE`, `DB_HOST` |
| Secrets | `podman secret create/inspect`, `--secret` as a file (`/run/secrets/…`) and as an env var (`type=env,target=POSTGRESQL_PASSWORD`), compose `secrets:` + `.env`, OpenShift Secret |
| Persistent storage: volumes & bind mounts | `fashion-output` and `fashion-db` named volumes, `./dataset` bind mount, `:ro`, `podman volume export` |
| Database containers | Part 7a: PostgreSQL 15 (sclorg / RHEL image), loading SQL with `podman cp` + `podman exec psql`, persistence test, `pg_dump` backup |
| SELinux `:Z`, rootless UID mapping | Part 5 `podman unshare`, part 8 breaks 1 and 2 |
| Port mapping | `-p 8000:8000`, `-p 8080:8080`, `podman port` |
| Container networking & DNS | `podman network create`, DNS to `fashion-api` and `fashion-db`, `podman network connect/disconnect` (part 8) |
| Lifecycle: run -d, logs, stop/start/restart, pause/unpause, kill, rm, restart policy, resource limits | Parts 6–8 (`--restart`, `--memory`, `podman wait`, `podman stats`, "Container lifecycle") |
| Copying files in/out (`podman cp`) | Parts 7a and 8 |
| Developer workflow: live edits via bind mounts | Part 8 "Live editing" (`-v ./ui:…:Z`, `GUNICORN_CMD_ARGS=--reload`) |
| Troubleshooting: logs, exec, inspect, top, events, healthcheck | Part 8 (4 "break it" exercises) |
| Pods | Part 9 `podman pod create`, `--pod`, infra container |
| Kubernetes YAML with Podman | Part 9 `podman generate kube`, `podman kube play/down` |
| Multi-container apps with compose | Part 10 `podman-compose` |
| Deploying to OpenShift / Kubernetes | Part 12 PVC, Secret, Job, Deployment, Service, Route, probes |

## API reference

| Method & path | What it returns |
|---|---|
| `GET /healthz` | 200 when the model is loaded, 503 before training |
| `GET /api/info` | Model status, classes, APP_ENV, hostname, UID, database status |
| `GET /api/metrics` | `metrics.json` (test accuracy, per-class accuracy, confusion matrix, history) |
| `GET /api/samples?n=12` | Random test images (base64 PNG) with predicted label, true label, confidence |
| `POST /api/predict` (form field `file`) | Predicted class, confidence, top-3 for an uploaded image |
| `GET /api/images/<name>.png` | `sample_predictions`, `confusion_matrix` or `training_curve` |
| `POST /api/reload` (header `X-API-Token`) | Reloads the model after retraining |
| `GET /api/history?limit=20` | Latest rows of the `predictions` table |
| `GET /api/stats` | Totals, uploads, accuracy on stored test images, count per predicted class (SQL) |
