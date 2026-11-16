"""Shared Fashion-MNIST helpers used by both the trainer and the API images.

* reads the original gzip IDX files directly (no torchvision / keras needed)
* a small CNN written in plain NumPy (forward + backward + Adam), so the
  images only need numpy and can be built from bundled wheels in an offline lab

Layout is NHWC (batch, height, width, channels).
"""
import gzip
import os
import struct
import urllib.request

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

CLASSES = [
    "T-shirt/top", "Trouser", "Pullover", "Dress", "Coat",
    "Sandal", "Shirt", "Sneaker", "Bag", "Ankle boot",
]

FILES = {
    "train": ("train-images-idx3-ubyte.gz", "train-labels-idx1-ubyte.gz"),
    "test": ("t10k-images-idx3-ubyte.gz", "t10k-labels-idx1-ubyte.gz"),
}

DEFAULT_BASE_URL = "http://fashion-mnist.s3-website.eu-central-1.amazonaws.com/"

# Mean / std of the Fashion-MNIST training pixels (scaled to 0..1)
MEAN, STD = 0.2860, 0.3530


# --------------------------------------------------------------------------- data
def _download(url, dest):
    print(f"  downloading {url}", flush=True)
    tmp = dest + ".part"
    urllib.request.urlretrieve(url, tmp)
    os.replace(tmp, dest)


def _read_idx(path):
    with gzip.open(path, "rb") as f:
        magic = struct.unpack(">I", f.read(4))[0]
        ndim = magic & 0xFF
        shape = struct.unpack(">" + "I" * ndim, f.read(4 * ndim))
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(shape)


def load_split(split, data_dir, base_url=DEFAULT_BASE_URL):
    """Return (images uint8 [N,28,28], labels uint8 [N]); download if missing."""
    os.makedirs(data_dir, exist_ok=True)
    arrays = []
    for name in FILES[split]:
        path = os.path.join(data_dir, name)
        if not os.path.exists(path):
            if os.environ.get("OFFLINE", "false").lower() == "true":
                raise FileNotFoundError(
                    f"{path} is missing and OFFLINE=true. Copy the 4 Fashion-MNIST "
                    f".gz files into the dataset directory first.")
            _download(base_url.rstrip("/") + "/" + name, path)
        else:
            print(f"  using cached {path}", flush=True)
        arrays.append(_read_idx(path))
    return arrays[0], arrays[1]


def preprocess(images):
    """uint8 [N,28,28] -> normalized float32 [N,28,28,1]."""
    x = np.asarray(images, dtype=np.float32) / 255.0
    return ((x - MEAN) / STD)[..., None]


# --------------------------------------------------------------------------- layers
def _im2col(x):
    """[N,H,W,C] -> [N,H,W,9*C] patches of a 3x3, stride 1, 'same' convolution."""
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1), (0, 0)))
    win = sliding_window_view(xp, (3, 3), axis=(1, 2))      # N,H,W,C,3,3
    n, h, w, c = x.shape
    return win.transpose(0, 1, 2, 4, 5, 3).reshape(n, h, w, 9 * c)


def _col2im(dcols, shape):
    """Inverse of _im2col for the gradient: sum the 9 shifted patches back."""
    n, h, w, c = shape
    d = dcols.reshape(n, h, w, 3, 3, c)
    dxp = np.zeros((n, h + 2, w + 2, c), dtype=dcols.dtype)
    for i in range(3):
        for j in range(3):
            dxp[:, i:i + h, j:j + w, :] += d[:, :, :, i, j, :]
    return dxp[:, 1:-1, 1:-1, :]


def _maxpool(x):
    n, h, w, c = x.shape
    r = x.reshape(n, h // 2, 2, w // 2, 2, c)
    out = r.max(axis=(2, 4))
    mask = r == out[:, :, None, :, None, :]
    return out, mask


def _maxpool_back(dout, mask):
    d = mask * dout[:, :, None, :, None, :]
    n, h2, _, w2, _, c = d.shape
    return d.reshape(n, h2 * 2, w2 * 2, c)


# --------------------------------------------------------------------------- model
class FashionCNN:
    """conv3x3(16)-ReLU-pool -> conv3x3(32)-ReLU-pool -> dense(128)-ReLU -> dense(10)

    About 206k parameters; reaches ~90-91% test accuracy in 5 epochs on CPU.
    """

    def __init__(self, seed=42):
        rng = np.random.default_rng(seed)

        def he(fan_in, shape):
            return (rng.standard_normal(shape) * np.sqrt(2.0 / fan_in)).astype(np.float32)

        self.p = {
            "w1": he(9 * 1, (9 * 1, 16)), "b1": np.zeros(16, np.float32),
            "w2": he(9 * 16, (9 * 16, 32)), "b2": np.zeros(32, np.float32),
            "w3": he(7 * 7 * 32, (7 * 7 * 32, 128)), "b3": np.zeros(128, np.float32),
            "w4": he(128, (128, 10)), "b4": np.zeros(10, np.float32),
        }

    def describe(self):
        lines = ["FashionCNN (NumPy)",
                 "  input       28x28x1",
                 "  conv 3x3    16 filters + ReLU -> 28x28x16",
                 "  maxpool 2x2                   -> 14x14x16",
                 "  conv 3x3    32 filters + ReLU -> 14x14x32",
                 "  maxpool 2x2                   -> 7x7x32",
                 "  dense       1568 -> 128 + ReLU",
                 "  dense       128 -> 10 (softmax)"]
        return "\n".join(lines)

    def num_params(self):
        return sum(v.size for v in self.p.values())

    def forward(self, x, keep=False):
        p = self.p
        n = x.shape[0]
        c1 = _im2col(x)                                        # N,28,28,9
        a1 = np.maximum(c1 @ p["w1"] + p["b1"], 0)            # N,28,28,16
        m1, k1 = _maxpool(a1)                                  # N,14,14,16
        c2 = _im2col(m1)                                       # N,14,14,144
        a2 = np.maximum(c2 @ p["w2"] + p["b2"], 0)            # N,14,14,32
        m2, k2 = _maxpool(a2)                                  # N,7,7,32
        f = m2.reshape(n, -1)
        h = np.maximum(f @ p["w3"] + p["b3"], 0)
        logits = h @ p["w4"] + p["b4"]
        if keep:
            self._cache = (c1, a1, k1, m1, c2, a2, k2, f, h)
        return logits

    def predict_proba(self, x, batch=500):
        out = []
        for i in range(0, len(x), batch):
            z = self.forward(x[i:i + batch])
            z = np.exp(z - z.max(1, keepdims=True))
            out.append(z / z.sum(1, keepdims=True))
        return np.concatenate(out)

    def loss_and_grads(self, x, y):
        """Softmax cross-entropy loss and gradients for a batch."""
        p = self.p
        logits = self.forward(x, keep=True)
        c1, a1, k1, m1, c2, a2, k2, f, h = self._cache
        n = len(y)
        z = np.exp(logits - logits.max(1, keepdims=True))
        probs = z / z.sum(1, keepdims=True)
        loss = float(-np.log(probs[np.arange(n), y] + 1e-9).mean())

        g = {}
        dz = probs
        dz[np.arange(n), y] -= 1
        dz /= n
        g["w4"], g["b4"] = h.T @ dz, dz.sum(0)
        dh = (dz @ p["w4"].T) * (h > 0)
        g["w3"], g["b3"] = f.T @ dh, dh.sum(0)
        dm2 = (dh @ p["w3"].T).reshape(n, 7, 7, 32)
        da2 = _maxpool_back(dm2, k2) * (a2 > 0)
        da2f = da2.reshape(-1, 32)
        g["w2"], g["b2"] = c2.reshape(-1, 144).T @ da2f, da2f.sum(0)
        dm1 = _col2im(da2f @ p["w2"].T, m1.shape)
        da1 = _maxpool_back(dm1, k1) * (a1 > 0)
        da1f = da1.reshape(-1, 16)
        g["w1"], g["b1"] = c1.reshape(-1, 9).T @ da1f, da1f.sum(0)
        return loss, g

    def save(self, path):
        tmp = path + ".tmp.npz"
        np.savez(tmp, **self.p)
        os.replace(tmp, path)

    @classmethod
    def load(cls, path):
        m = cls()
        with np.load(path) as d:
            m.p = {k: d[k].astype(np.float32) for k in d.files}
        return m


class Adam:
    def __init__(self, params, lr=1e-3, b1=0.9, b2=0.999, eps=1e-8):
        self.p, self.lr, self.b1, self.b2, self.eps = params, lr, b1, b2, eps
        self.m = {k: np.zeros_like(v) for k, v in params.items()}
        self.v = {k: np.zeros_like(v) for k, v in params.items()}
        self.t = 0

    def step(self, grads):
        self.t += 1
        corr = np.sqrt(1 - self.b2 ** self.t) / (1 - self.b1 ** self.t)
        for k, gk in grads.items():
            self.m[k] = self.b1 * self.m[k] + (1 - self.b1) * gk
            self.v[k] = self.b2 * self.v[k] + (1 - self.b2) * gk * gk
            self.p[k] -= (self.lr * corr * self.m[k] / (np.sqrt(self.v[k]) + self.eps)).astype(np.float32)
