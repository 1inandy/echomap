"""Capture Lab WAV (+ JSON sidecar) -> what the pipeline sees, for H0/H1 and C4.

    lab/.venv/bin/python lab/analyze_recordings.py rec1.wav [rec2.wav ...]
        [--template open_space.wav] [--truth 1.5] [--out lab/out/recordings]

For each recording: band presence (in-band vs out-of-band level), per-chirp direct path,
every echo candidate above the noise threshold (distance, dB re direct, prominence), the
pipeline's burst result, and an envelope plot. With several recordings it prints the H0
table (wall/floor peak ratio per configuration) when --truth is given.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from echolab.io import read_capture  # noqa: E402
from echolab.pipeline import (MAD_SCALE, analytic_xcorr, bandpass_taps, baseband,  # noqa: E402
                              build_template, direct_path, distance_for_lag, filter_causal,
                              filtered_reference, ideal_template, mad, median, noise_region,
                              process_burst, subtract_template)


def band_presence(x: np.ndarray, cfg) -> dict:
    X = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    f = np.fft.rfftfreq(len(x), 1 / cfg.fs)
    inb = (f >= cfg.f0) & (f <= cfg.f1)
    ref = (f >= 10_000) & (f <= 14_000) if cfg.f0 > 15_000 else (f >= 20_500) & (f <= 23_000)
    return {"in_band_db": 10 * math.log10(X[inb].mean() + 1e-30),
            "reference_band_db": 10 * math.log10(X[ref].mean() + 1e-30)}


def candidates(env, td, cfg, offset, k=6.0):
    reg = noise_region(env, td, cfg, offset, 1.0)
    floor, sigma = median(reg), MAD_SCALE * mad(reg)
    out = []
    for i in range(1, len(env) - 1):
        if env[i] > env[i - 1] and env[i] >= env[i + 1] and env[i] > floor + k * sigma and i > td:
            d = distance_for_lag(i - td, cfg, offset, 1.0)
            if 0.1 < d < 6:
                out.append((d, env[i]))
    return floor, sigma, out


def analyze(path: Path, template_path: Path | None, out: Path, truth: float | None) -> dict:
    x, cfg, meta = read_capture(path)
    tpl = build_template(read_capture(template_path)[0], cfg) if template_path else ideal_template(cfg)
    offset = cfg.default_offset_m
    h, ref = bandpass_taps(cfg), filtered_reference(cfg)
    P = cfg.period_len
    bp = band_presence(x, cfg)
    print(f"\n=== {path.name}  ({len(x) / cfg.fs:.2f} s, {cfg.f0:.0f}-{cfg.f1:.0f} Hz, "
          f"mic={meta.get('mic_source', '?')}, pattern={meta.get('polar_pattern', '?')}, "
          f"hold={meta.get('hold_orientation', '?')})")
    print(f"band presence: in-band {bp['in_band_db']:.1f} dB vs reference band "
          f"{bp['reference_band_db']:.1f} dB")
    fig, ax = plt.subplots(figsize=(9, 4))
    n = min(cfg.n_chirps, len(x) // P)
    wall_floor = []
    for i in range(n):
        w = x[i * P : (i + 1) * P]
        b = baseband(analytic_xcorr(filter_causal(w, h), ref), cfg)
        env0 = np.abs(b)
        td = direct_path(env0, cfg)
        env = np.abs(subtract_template(b, td, tpl, cfg))
        floor, sigma, cands = candidates(env, td, cfg, offset)
        dpk = env0.max()
        top = sorted(cands, key=lambda c: -c[1])[:6]
        desc = ", ".join(f"{d:.2f} m ({20 * math.log10(a / dpk):.0f} dB)" for d, a in sorted(top))
        print(f"  chirp {i}: direct at {td:.1f} smp, floor {20 * math.log10(floor / dpk + 1e-30):.0f} dB; "
              f"candidates: {desc or 'none'}")
        if truth is not None and cands:
            near = [a for d, a in cands if abs(d - truth) < 0.15]
            other = [a for d, a in cands if abs(d - truth) >= 0.15 and d < truth]
            if near:
                wall_floor.append(20 * math.log10(max(near) / (max(other) if other else floor)))
        lags = np.arange(len(env)) - td
        dist = distance_for_lag(lags, cfg, offset, 1.0)
        m = (dist > 0) & (dist < 5)
        ax.plot(dist[m], 20 * np.log10(env[m] / dpk + 1e-12), lw=0.7, label=f"chirp {i}")
    r = process_burst(x, cfg, tpl)
    status = "SUPPRESSED" if r.suppressed else f"{r.distance:.3f} m ({r.category})"
    conf = f"{r.confidence.value:.2f}" if r.confidence else "—"
    print(f"  burst: {status}; median {r.median_distance}; valid {r.valid}/{r.n}; "
          f"confidence {conf}; snr {r.snr_db}")
    if truth is not None:
        ax.axvline(truth, color="k", ls="--", lw=0.8)
    ax.axvline(cfg.blanking_m, color="0.6", lw=0.8)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("dB re direct path")
    ax.set_ylim(-90, 5)
    ax.set_title(path.name)
    ax.legend(fontsize=7)
    out.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out / f"{path.stem}.png", dpi=130)
    plt.close(fig)
    return {"name": path.name, "mic": meta.get("mic_source"), "pattern": meta.get("polar_pattern"),
            "hold": meta.get("hold_orientation"), "band": bp,
            "wall_vs_other_db": float(np.median(wall_floor)) if wall_floor else None,
            "distance": r.distance, "suppressed": r.suppressed}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("wavs", nargs="+", type=Path)
    ap.add_argument("--template", type=Path, help="open-space capture for leakage template")
    ap.add_argument("--truth", type=float, help="tape-measured wall distance (m)")
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "out" / "recordings")
    a = ap.parse_args()
    rows = [analyze(p, a.template, a.out, a.truth) for p in a.wavs]
    if a.truth is not None and len(rows) > 1:
        print("\nH0: wall peak vs strongest nearer peak (higher is better)")
        for r in sorted(rows, key=lambda r: -(r["wall_vs_other_db"] or -999)):
            v = "—" if r["wall_vs_other_db"] is None else f"{r['wall_vs_other_db']:+.1f} dB"
            print(f"  {v:>9}  mic={r['mic']} pattern={r['pattern']} hold={r['hold']}  ({r['name']})")
    print(f"\nPlots in {a.out}")


if __name__ == "__main__":
    main()
