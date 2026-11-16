"""Fashion Item Classifier - inference REST API (Flask, served by gunicorn).

Reads the model and results the trainer container wrote to the shared
volume (/output, mounted read-only).

  GET  /healthz                 liveness/readiness (200 once the model is loaded)
  GET  /api/info                model status + config
  GET  /api/metrics             metrics.json from training
  GET  /api/samples?n=12        random test images with prediction + true label
  POST /api/predict             multipart "file" image -> predicted class
  GET  /api/images/<name>.png   result charts written by the trainer
  POST /api/reload              reload model after retraining (needs X-API-Token)
  GET  /api/history?limit=20    last predictions stored in PostgreSQL
  GET  /api/stats               totals and accuracy computed by SQL
"""
import base64
import io
import json
import os
import sys
import threading

import numpy as np
from flask import Flask, abort, jsonify, request, send_from_directory
from PIL import Image, ImageOps

sys.path.insert(0, os.environ.get("COMMON_DIR", "/opt/app-root/common"))
from fmnist import CLASSES, FashionCNN, preprocess  # noqa: E402

import db  # noqa: E402

OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/output")
APP_ENV = os.environ.get("APP_ENV", "dev")
TOKEN_FILE = os.environ.get("API_TOKEN_FILE", "/run/secrets/api_token")
CHARTS = {"sample_predictions.png", "confusion_matrix.png", "training_curve.png"}

app = Flask(__name__)
_lock = threading.Lock()
_state = {"model": None, "subset": None, "mtime": None}


def _api_token():
    # podman secret (file) wins over a plain env var
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    return os.environ.get("API_TOKEN")


def load_model(force=False):
    path = os.path.join(OUTPUT_DIR, "model.npz")
    # metrics.json is written last by the trainer, so its presence means "training finished"
    if not os.path.exists(os.path.join(OUTPUT_DIR, "metrics.json")):
        return None
    with _lock:
        if _state["model"] is None or force:
            _state["model"] = FashionCNN.load(path)
            _state["mtime"] = os.path.getmtime(path)
            subset = os.path.join(OUTPUT_DIR, "test_subset.npz")
            _state["subset"] = dict(np.load(subset)) if os.path.exists(subset) else None
            app.logger.info("model loaded from %s", path)
    return _state["model"]


def predict(images):
    model = load_model()
    if model is None:
        abort(503, "Model not trained yet - run the trainer container first")
    return model.predict_proba(preprocess(images))


def png_b64(img):
    buf = io.BytesIO()
    Image.fromarray(img).resize((112, 112), Image.NEAREST).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


@app.errorhandler(503)
@app.errorhandler(400)
@app.errorhandler(401)
@app.errorhandler(404)
def json_error(e):
    return jsonify(error=e.description), e.code


@app.get("/healthz")
def healthz():
    ready = load_model() is not None
    return jsonify(status="ok" if ready else "waiting-for-model", model_loaded=ready), 200 if ready else 503


@app.get("/api/info")
def info():
    return jsonify(model_loaded=load_model() is not None, classes=CLASSES, app_env=APP_ENV,
                   output_dir=OUTPUT_DIR, hostname=os.environ.get("HOSTNAME"),
                   uid=os.getuid(), token_configured=bool(_api_token()),
                   database=db.status(), db_host=db.DB_HOST or None)


@app.get("/api/metrics")
def metrics():
    path = os.path.join(OUTPUT_DIR, "metrics.json")
    if not os.path.exists(path):
        abort(503, "metrics.json not found - run the trainer container first")
    with open(path) as f:
        return jsonify(json.load(f))


@app.get("/api/samples")
def samples():
    n = max(1, min(int(request.args.get("n", 12)), 50))
    load_model()
    subset = _state["subset"]
    if subset is None:
        abort(503, "test_subset.npz not found - run the trainer container first")
    idx = np.random.choice(len(subset["labels"]), n, replace=False)
    imgs, labels = subset["images"][idx], subset["labels"][idx]
    probs = predict(imgs)
    out = []
    for img, label, p, i in zip(imgs, labels, probs, subset["index"][idx]):
        pred = int(p.argmax())
        out.append({"test_index": int(i), "image": png_b64(img), "true": CLASSES[int(label)],
                    "predicted": CLASSES[pred], "confidence": round(float(p[pred]), 4),
                    "correct": pred == int(label)})
    saved = db.save([{"source": "sample", "test_index": o["test_index"], "predicted": o["predicted"],
                      "true_label": o["true"], "confidence": o["confidence"]} for o in out])
    return jsonify(accuracy=sum(o["correct"] for o in out) / n, samples=out, saved_to_db=saved)


@app.post("/api/predict")
def predict_upload():
    if "file" not in request.files:
        abort(400, "send an image as multipart form field 'file'")
    try:
        img = Image.open(request.files["file"].stream).convert("L")
    except Exception:
        abort(400, "could not read image")
    img = ImageOps.fit(img, (28, 28))
    arr = np.asarray(img, dtype=np.uint8)
    # Fashion-MNIST is a light item on a black background: invert photos with light backgrounds
    border = np.concatenate([arr[0], arr[-1], arr[:, 0], arr[:, -1]])
    if border.mean() > 127:
        arr = 255 - arr
    p = predict(arr[None])[0]
    top = np.argsort(p)[::-1][:3]
    saved = db.save([{"source": "upload", "predicted": CLASSES[int(top[0])],
                      "confidence": round(float(p[top[0]]), 4)}])
    return jsonify(predicted=CLASSES[int(top[0])], confidence=round(float(p[top[0]]), 4),
                   saved_to_db=saved,
                   top3=[{"class": CLASSES[int(i)], "prob": round(float(p[i]), 4)} for i in top],
                   preprocessed=png_b64(arr))


@app.get("/api/images/<name>")
def images(name):
    if name not in CHARTS or not os.path.exists(os.path.join(OUTPUT_DIR, name)):
        abort(404, "image not found")
    return send_from_directory(OUTPUT_DIR, name, max_age=0)


@app.post("/api/reload")
def reload_model():
    token = _api_token()
    if not token or request.headers.get("X-API-Token") != token:
        abort(401, "missing or wrong X-API-Token header")
    ok = load_model(force=True) is not None
    return jsonify(reloaded=ok, model_mtime=_state["mtime"])


def _db_or_503():
    if not db.enabled():
        abort(503, "database not configured (set DB_HOST)")


@app.get("/api/history")
def history():
    _db_or_503()
    limit = max(1, min(int(request.args.get("limit", 20)), 200))
    try:
        return jsonify(rows=db.history(limit))
    except Exception as e:
        abort(503, f"database error: {e}")


@app.get("/api/stats")
def stats():
    _db_or_503()
    try:
        return jsonify(db.stats())
    except Exception as e:
        abort(503, f"database error: {e}")
