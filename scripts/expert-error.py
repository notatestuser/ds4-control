#!/usr/bin/env python3
"""Quantify how much fidelity q4_K's re-quantization step costs on DeepSeek V4 Flash experts.

DeepSeek ships Flash with `expert_dtype: fp4`, so the released routed experts carry 4 bits. The
q4-imatrix GGUF dequantizes those FP4 values and re-quantizes them onto Q4_K's *different* 4-bit
grid — a second lossy step. The q8 build stores the same dequantized values in 8.5 bpw, which is
wide enough to be essentially exact.

So `dequant(q4_K)` vs `dequant(q8_0)` isolates exactly the error the second step introduces, using
only the two GGUFs we already have — no safetensors reader and no FP4 path required.

Usage:
    python3 scripts/expert-error.py                 # self-test + default tensor sweep
    python3 scripts/expert-error.py --list          # list expert tensors and their types
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

import numpy as np

GGUF_MAGIC = 0x46554747  # "GGUF"

# ggml type ids we need.
T_F32, T_F16, T_Q4_K, T_Q8_0 = 0, 1, 12, 8
TYPE_NAMES = {T_F32: "f32", T_F16: "f16", T_Q4_K: "q4_K", T_Q8_0: "q8_0"}
# (block elements, bytes per block) for the quantized types.
BLOCK = {T_Q4_K: (256, 144), T_Q8_0: (32, 34)}

GGUF_DIR = os.path.expanduser("~/Library/Application Support/DS4 Control/gguf")
Q4 = "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf"
Q8 = "DeepSeek-V4-Flash-Q8Experts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-0731.gguf"


# ---------------------------------------------------------------- GGUF container


class Reader:
    """Minimal GGUF v2/v3 reader: header -> KV block -> tensor infos -> aligned data."""

    def __init__(self, path: str):
        self.path = path
        self.f = open(path, "rb")
        magic, self.version, n_tensors, n_kv = struct.unpack("<IIQQ", self.f.read(24))
        if magic != GGUF_MAGIC:
            raise ValueError(f"{path}: not a GGUF file")
        self.alignment = 32
        for _ in range(n_kv):
            key = self._string()
            val = self._value()
            if key == "general.alignment":
                self.alignment = int(val)
        self.tensors: dict[str, tuple[list[int], int, int]] = {}
        for _ in range(n_tensors):
            name = self._string()
            n_dims = struct.unpack("<I", self.f.read(4))[0]
            dims = list(struct.unpack(f"<{n_dims}Q", self.f.read(8 * n_dims)))
            ttype, offset = struct.unpack("<IQ", self.f.read(12))
            self.tensors[name] = (dims, ttype, offset)
        pos = self.f.tell()
        self.data_start = (pos + self.alignment - 1) // self.alignment * self.alignment

    # -- primitive readers -------------------------------------------------
    def _string(self) -> str:
        (n,) = struct.unpack("<Q", self.f.read(8))
        return self.f.read(n).decode("utf-8", "replace")

    def _value(self, vtype: int | None = None):
        if vtype is None:
            (vtype,) = struct.unpack("<I", self.f.read(4))
        simple = {
            0: ("<B", 1), 1: ("<b", 1), 2: ("<H", 2), 3: ("<h", 2),
            4: ("<I", 4), 5: ("<i", 4), 6: ("<f", 4), 7: ("<?", 1),
            10: ("<Q", 8), 11: ("<q", 8), 12: ("<d", 8),
        }
        if vtype in simple:
            fmt, size = simple[vtype]
            return struct.unpack(fmt, self.f.read(size))[0]
        if vtype == 8:
            return self._string()
        if vtype == 9:  # array
            elem_type, count = struct.unpack("<IQ", self.f.read(12))
            return [self._value(elem_type) for _ in range(count)]
        raise ValueError(f"unhandled GGUF value type {vtype}")

    # -- tensor access -----------------------------------------------------
    def type_of(self, name: str) -> int:
        return self.tensors[name][1]

    def raw(self, name: str, max_blocks: int | None = None) -> tuple[bytes, list[int], int]:
        """Raw bytes for a tensor, optionally truncated to the first `max_blocks` blocks."""
        dims, ttype, offset = self.tensors[name]
        n_elems = 1
        for d in dims:
            n_elems *= d
        if ttype in BLOCK:
            elems_per_block, bytes_per_block = BLOCK[ttype]
            n_blocks = n_elems // elems_per_block
            if max_blocks is not None:
                n_blocks = min(n_blocks, max_blocks)
            nbytes = n_blocks * bytes_per_block
        elif ttype == T_F32:
            nbytes = n_elems * 4
        elif ttype == T_F16:
            nbytes = n_elems * 2
        else:
            raise ValueError(f"{name}: unsupported type {ttype}")
        self.f.seek(self.data_start + offset)
        return self.f.read(nbytes), dims, ttype


# ---------------------------------------------------------------- dequantizers


def dequant_q8_0(buf: bytes) -> np.ndarray:
    """34 bytes/block: fp16 scale `d` + 32 int8 quants. value = d * q."""
    b = np.frombuffer(buf, dtype=np.uint8).reshape(-1, 34)
    d = b[:, :2].copy().view(np.float16).astype(np.float32)  # (nb, 1)
    q = b[:, 2:].view(np.int8).astype(np.float32)  # (nb, 32)
    return (q * d).reshape(-1)


def _q4k_scales(sc12: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Unpack Q4_K's 12 bytes into 8 six-bit scales and 8 six-bit mins (llama.cpp layout)."""
    nb = sc12.shape[0]
    sc = np.zeros((nb, 8), dtype=np.uint8)
    mn = np.zeros((nb, 8), dtype=np.uint8)
    # First 4 sub-blocks: low 6 bits of bytes 0-3 (scales) and 4-7 (mins).
    sc[:, 0:4] = sc12[:, 0:4] & 0x3F
    mn[:, 0:4] = sc12[:, 4:8] & 0x3F
    # Last 4: low nibble from bytes 8-11, high 2 bits borrowed from bytes 0-7.
    sc[:, 4:8] = (sc12[:, 8:12] & 0x0F) | ((sc12[:, 0:4] >> 6) << 4)
    mn[:, 4:8] = (sc12[:, 8:12] >> 4) | ((sc12[:, 4:8] >> 6) << 4)
    return sc, mn


def dequant_q4_k(buf: bytes) -> np.ndarray:
    """144 bytes/super-block of 256: d(f16), dmin(f16), 12B packed scales/mins, 128B of 4-bit quants.

    value = d*scale * q - dmin*min, per 32-element sub-block.
    """
    b = np.frombuffer(buf, dtype=np.uint8).reshape(-1, 144)
    d = b[:, 0:2].copy().view(np.float16).astype(np.float32)  # (nb,1)
    dmin = b[:, 2:4].copy().view(np.float16).astype(np.float32)  # (nb,1)
    sc, mn = _q4k_scales(b[:, 4:16])
    qs = b[:, 16:144]  # (nb,128) -> 256 nibbles
    lo = (qs & 0x0F).reshape(-1, 4, 32)  # sub-blocks 0,2,4,6
    hi = (qs >> 4).reshape(-1, 4, 32)  # sub-blocks 1,3,5,7
    q = np.empty((b.shape[0], 8, 32), dtype=np.float32)
    q[:, 0::2, :] = lo
    q[:, 1::2, :] = hi
    scale = (d * sc.astype(np.float32))[:, :, None]
    minv = (dmin * mn.astype(np.float32))[:, :, None]
    return (scale * q - minv).reshape(-1)


def dequant(buf: bytes, ttype: int) -> np.ndarray:
    if ttype == T_Q8_0:
        return dequant_q8_0(buf)
    if ttype == T_Q4_K:
        return dequant_q4_k(buf)
    if ttype == T_F32:
        return np.frombuffer(buf, dtype=np.float32).astype(np.float32)
    if ttype == T_F16:
        return np.frombuffer(buf, dtype=np.float16).astype(np.float32)
    raise ValueError(f"unsupported type {ttype}")


# ---------------------------------------------------------------- metrics


def compare(a: np.ndarray, b: np.ndarray) -> dict[str, float]:
    n = min(a.size, b.size)
    a, b = a[:n], b[:n]
    err = a - b
    rms_ref = float(np.sqrt(np.mean(b * b)))
    rmse = float(np.sqrt(np.mean(err * err)))
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    cos = float(np.dot(a, b) / denom) if denom > 0 else float("nan")
    return {
        "rmse": rmse,
        "rel_rmse_pct": 100.0 * rmse / rms_ref if rms_ref > 0 else float("nan"),
        "cosine": cos,
        "max_abs": float(np.max(np.abs(err))) if n else 0.0,
        "ref_rms": rms_ref,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--q4", default=os.path.join(GGUF_DIR, Q4))
    ap.add_argument("--q8", default=os.path.join(GGUF_DIR, Q8))
    ap.add_argument("--blocks", type=int, default=200_000,
                    help="blocks per tensor to sample (q4_K super-blocks of 256)")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    r4, r8 = Reader(args.q4), Reader(args.q8)

    if args.list:
        for name in sorted(n for n in r4.tensors if "exps" in n)[:12]:
            print(f"{name:44s} q4={TYPE_NAMES.get(r4.type_of(name))} q8={TYPE_NAMES.get(r8.type_of(name))}")
        return 0

    # --- self-test: a tensor that is q8_0 in BOTH files and proven byte-identical by
    # --- `--compare-tensor` must dequantize to exactly the same floats. If this isn't 0,
    # --- the reader is wrong and every number below is noise.
    probe = "blk.0.attn_q_a.weight"
    b4, _, t4 = r4.raw(probe, max_blocks=4096)
    b8, _, t8 = r8.raw(probe, max_blocks=4096)
    assert t4 == t8 == T_Q8_0, f"expected {probe} to be q8_0 in both, got {t4}/{t8}"
    v4, v8 = dequant(b4, t4), dequant(b8, t8)
    st = compare(v4, v8)
    ok = b4 == b8 and st["rmse"] == 0.0
    print(f"SELF-TEST {probe}: bytes_equal={b4 == b8} rmse={st['rmse']:.3e} -> {'PASS' if ok else 'FAIL'}")
    if not ok:
        print("  reader/dequant is unsound; aborting", file=sys.stderr)
        return 1
    print()

    # --- expert error across depth
    layers = [0, 5, 10, 15, 20, 25, 30, 35, 37, 40, 41, 42]
    parts = ["gate", "down", "up"]
    print(f"q4_K vs q8_0 on routed experts (first {args.blocks} super-blocks/tensor)")
    print(f"{'tensor':38s} {'rel_rmse%':>10s} {'cosine':>10s} {'rmse':>11s} {'max_abs':>10s}")
    rows = []
    for layer in layers:
        for part in parts:
            name = f"blk.{layer}.ffn_{part}_exps.weight"
            if name not in r4.tensors or name not in r8.tensors:
                continue
            b4, _, t4 = r4.raw(name, max_blocks=args.blocks)
            # q8_0 has 32-element blocks vs q4_K's 256: sample the same element count.
            b8, _, t8 = r8.raw(name, max_blocks=args.blocks * 8)
            m = compare(dequant(b4, t4), dequant(b8, t8))
            rows.append((layer, part, m))
            print(f"{name:38s} {m['rel_rmse_pct']:10.3f} {m['cosine']:10.6f} "
                  f"{m['rmse']:11.3e} {m['max_abs']:10.3e}")

    if rows:
        print()
        by_layer: dict[int, list[float]] = {}
        for layer, _part, m in rows:
            by_layer.setdefault(layer, []).append(m["rel_rmse_pct"])
        first = np.mean(by_layer[min(by_layer)])
        last = np.mean(by_layer[max(by_layer)])
        allv = [m["rel_rmse_pct"] for _l, _p, m in rows]
        print(f"mean rel_rmse {np.mean(allv):.3f}%  (layer {min(by_layer)}: {first:.3f}%  "
              f"layer {max(by_layer)}: {last:.3f}%)  spread {max(allv) - min(allv):.3f} pp")
        print("depth trend:", "later layers worse" if last > first * 1.15
              else "later layers better" if first > last * 1.15 else "FLAT across depth")
    return 0


if __name__ == "__main__":
    sys.exit(main())
