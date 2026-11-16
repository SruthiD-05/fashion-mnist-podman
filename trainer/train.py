"""Fashion Item Classifier - training job.

1. Load the Fashion-MNIST dataset
2. Build and train a CNN
3. Evaluate accuracy on the test set
4. Save sample predictions with true labels (PNG) + metrics + model

All settings come from environment variables so they can be changed with
`podman run -e ...` without rebuilding the image.
"""
import json
import os
import sys
import time

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, os.environ.get("COMMON_DIR", "/opt/app-root/common"))
from fmnist import CLASSES, DEFAULT_BASE_URL, Adam, FashionCNN, load_split, preprocess  # noqa: E402

EPOCHS = int(os.environ.get("EPOCHS", "5"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "64"))
LEARNING_RATE = float(os.environ.get("LEARNING_RATE", "0.001"))
SEED = int(os.environ.get("SEED", "42"))
TRAIN_LIMIT = int(os.environ.get("TRAIN_LIMIT", "0"))  # 0 = use all 60k images
NUM_SAMPLES = int(os.environ.get("NUM_SAMPLES", "20"))
DATA_DIR = os.environ.get("DATA_DIR", "/data")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/output")
BASE_URL = os.environ.get("FMNIST_BASE_URL", DEFAULT_BASE_URL)


def banner(text):
    print("\n" + "=" * 60 + f"\n{text}\n" + "=" * 60, flush=True)


def evaluate(model, x):
    return model.predict_proba(x).argmax(1)


def save_sample_grid(images, labels, preds, path):
    cols = 5
    rows = int(np.ceil(len(images) / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(cols * 2.4, rows * 2.7))
    for ax in axes.flat:
        ax.axis("off")
    for ax, img, t, p in zip(axes.flat, images, labels, preds):
        ax.imshow(img, cmap="gray")
        color = "green" if t == p else "red"
        ax.set_title(f"Pred: {CLASSES[p]}\nTrue: {CLASSES[t]}", fontsize=9, color=color)
    correct = int((labels == preds).sum())
    fig.suptitle(f"Sample predictions ({correct}/{len(images)} correct, green = right, red = wrong)")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def save_confusion_matrix(labels, preds, path):
    cm = np.zeros((10, 10), dtype=int)
    for t, p in zip(labels, preds):
        cm[t, p] += 1
    fig, ax = plt.subplots(figsize=(8, 7))
    ax.imshow(cm, cmap="Blues")
    ax.set_xticks(range(10), CLASSES, rotation=45, ha="right")
    ax.set_yticks(range(10), CLASSES)
    ax.set_xlabel("Predicted")
    ax.set_ylabel("True")
    for i in range(10):
        for j in range(10):
            ax.text(j, i, cm[i, j], ha="center", va="center", fontsize=7,
                    color="white" if cm[i, j] > cm.max() / 2 else "black")
    ax.set_title("Confusion matrix (test set)")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return cm


def save_curve(history, path):
    epochs = [h["epoch"] for h in history]
    fig, ax1 = plt.subplots(figsize=(7, 4))
    ax1.plot(epochs, [h["train_loss"] for h in history], "o-", label="train loss")
    ax1.set_xlabel("epoch")
    ax1.set_ylabel("loss")
    ax2 = ax1.twinx()
    ax2.plot(epochs, [h["test_acc"] for h in history], "s-", color="tab:green", label="test acc")
    ax2.set_ylabel("test accuracy")
    fig.legend(loc="center right")
    ax1.set_title("Training progress")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def main():
    rng = np.random.default_rng(SEED)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    banner("STEP 1/4  Load the Fashion-MNIST dataset")
    print(f"  DATA_DIR={DATA_DIR}  running as uid={os.getuid()}")
    x_train, y_train = load_split("train", DATA_DIR, BASE_URL)
    x_test, y_test = load_split("test", DATA_DIR, BASE_URL)
    if TRAIN_LIMIT:
        x_train, y_train = x_train[:TRAIN_LIMIT], y_train[:TRAIN_LIMIT]
    print(f"  train: {x_train.shape}  test: {x_test.shape}  classes: {len(CLASSES)}")
    counts = np.bincount(y_train, minlength=10)
    for name, c in zip(CLASSES, counts):
        print(f"    {name:<12} {c}")

    xtr, ytr = preprocess(x_train), y_train.astype(np.int64)
    xte, labels = preprocess(x_test), y_test.astype(np.int64)

    banner("STEP 2/4  Build and train the CNN")
    model = FashionCNN(seed=SEED)
    print(model.describe())
    print(f"  trainable parameters: {model.num_params():,}")
    print(f"  EPOCHS={EPOCHS} BATCH_SIZE={BATCH_SIZE} LEARNING_RATE={LEARNING_RATE}")
    optimizer = Adam(model.p, lr=LEARNING_RATE)
    history = []
    start = time.time()
    steps = int(np.ceil(len(xtr) / BATCH_SIZE))
    for epoch in range(1, EPOCHS + 1):
        order = rng.permutation(len(xtr))
        total, n = 0.0, 0
        for step in range(steps):
            b = order[step * BATCH_SIZE:(step + 1) * BATCH_SIZE]
            loss, grads = model.loss_and_grads(xtr[b], ytr[b])
            optimizer.step(grads)
            total += loss * len(b)
            n += len(b)
            if (step + 1) % 200 == 0:
                print(f"    epoch {epoch} step {step + 1}/{steps}  loss={total / n:.4f}", flush=True)
        preds = evaluate(model, xte)
        acc = float((preds == labels).mean())
        history.append({"epoch": epoch, "train_loss": total / n, "test_acc": acc})
        print(f"  epoch {epoch}/{EPOCHS}  loss={total / n:.4f}  test_acc={acc:.4f}  "
              f"elapsed={time.time() - start:.0f}s", flush=True)

    banner("STEP 3/4  Evaluate accuracy on the test set")
    preds = evaluate(model, xte)
    test_acc = float((preds == labels).mean())
    print(f"  TEST ACCURACY: {test_acc * 100:.2f}%  ({int((preds == labels).sum())}/{len(labels)})")
    per_class = {}
    for i, name in enumerate(CLASSES):
        mask = labels == i
        per_class[name] = float((preds[mask] == i).mean())
        print(f"    {name:<12} {per_class[name] * 100:6.2f}%")
    cm = save_confusion_matrix(labels, preds, os.path.join(OUTPUT_DIR, "confusion_matrix.png"))
    save_curve(history, os.path.join(OUTPUT_DIR, "training_curve.png"))

    banner("STEP 4/4  Show sample predictions with true labels")
    idx = rng.choice(len(x_test), NUM_SAMPLES, replace=False)
    save_sample_grid(x_test[idx], labels[idx], preds[idx],
                     os.path.join(OUTPUT_DIR, "sample_predictions.png"))
    for i in idx:
        mark = "OK " if preds[i] == labels[i] else "BAD"
        print(f"  [{mark}] test#{i:<5} predicted={CLASSES[preds[i]]:<12} true={CLASSES[labels[i]]}")

    # Remove the old "finished" marker, then write files; metrics.json goes last
    if os.path.exists(os.path.join(OUTPUT_DIR, "metrics.json")):
        os.remove(os.path.join(OUTPUT_DIR, "metrics.json"))
    model.save(os.path.join(OUTPUT_DIR, "model.npz"))
    # Small test subset so the API can show random samples without the full dataset
    sub = rng.choice(len(x_test), 1000, replace=False)
    np.savez_compressed(os.path.join(OUTPUT_DIR, "test_subset.npz"),
                        images=x_test[sub], labels=y_test[sub], index=sub)
    metrics = {
        "test_accuracy": test_acc,
        "per_class_accuracy": per_class,
        "confusion_matrix": cm.tolist(),
        "history": history,
        "params": {"epochs": EPOCHS, "batch_size": BATCH_SIZE, "learning_rate": LEARNING_RATE,
                   "seed": SEED, "train_images": int(len(x_train))},
        "training_seconds": round(time.time() - start, 1),
        "hostname": os.environ.get("HOSTNAME", ""),
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with open(os.path.join(OUTPUT_DIR, "metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)
    print(f"\n  saved to {OUTPUT_DIR}: " + ", ".join(sorted(os.listdir(OUTPUT_DIR))))
    print("\nDONE")


if __name__ == "__main__":
    main()
