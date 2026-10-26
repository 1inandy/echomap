"""Write golden fixtures for Swift parity (ONE_SHOT_PLAN.md step A4).

    lab/.venv/bin/python lab/make_fixtures.py

fixtures/
  config.json            default SignalConfig, band-pass taps, filtered reference, ideal template
  open_space.f32         calibration capture used to build the leakage template
  template.json          expected calibrated template (interleaved re, im)
  scene_XX.f32/.json     12 scenes: raw recording + expected per-chirp and burst results

Expected values are computed from the float32-rounded recordings, exactly what Swift reads.
"""
from __future__ import annotations

import json
import sys
from dataclasses import asdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from echolab.pipeline import (build_template, filtered_reference, ideal_template,  # noqa: E402
                              process_burst)
from echolab.signal import ALGO_VERSION, AUDIBLE_DEV, DEFAULT, bandpass_taps  # noqa: E402
from echolab.simulate import CLEAN_REFLECTOR, Scene, open_space, simulate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent / "fixtures"

SCENES: list[tuple[str, Scene, str, object]] = [
    ("wall_0p50", Scene(wall_m=0.50, seed=1), "calibrated", DEFAULT),
    ("wall_1p00", Scene(wall_m=1.00, seed=2), "calibrated", DEFAULT),
    ("wall_1p50", Scene(wall_m=1.50, seed=3, snr_db=15), "calibrated", DEFAULT),
    ("wall_2p00", Scene(wall_m=2.00, seed=4), "calibrated", DEFAULT),
    ("wall_2p50", Scene(wall_m=2.50, seed=5, snr_db=30), "calibrated", DEFAULT),
    ("clean_0p75", CLEAN_REFLECTOR.with_(wall_m=0.75), "ideal", DEFAULT),
    ("wall_1p00_nosub", Scene(wall_m=1.00, seed=6), "none", DEFAULT),
    ("floor_nearer", Scene(wall_m=2.0, floor_h_m=1.3, seed=7), "calibrated", DEFAULT),
    ("empty_room", Scene(wall_m=None, seed=8), "calibrated", DEFAULT),
    ("low_snr", Scene(wall_m=1.5, snr_db=-15, seed=9), "calibrated", DEFAULT),
    ("reverb_0p8", Scene(wall_m=2.0, rt60_s=0.8, seed=10), "calibrated", DEFAULT),
    ("audible_1p20", CLEAN_REFLECTOR.with_(wall_m=1.2), "ideal", AUDIBLE_DEV),
]


def f32(x: np.ndarray) -> np.ndarray:
    return np.asarray(x, dtype="<f4")


def interleave(z: np.ndarray) -> list[float]:
    return np.column_stack([z.real, z.imag]).ravel().tolist()


def burst_dict(r) -> dict:
    return {
        "valid": r.valid, "n": r.n, "distance": r.distance,
        "median_distance": r.median_distance, "raw_range": r.raw_range, "mad": r.mad,
        "snr_db": r.snr_db, "prom_sigma": r.prom_sigma, "category": r.category,
        "suppressed": r.suppressed,
        "confidence": None if r.confidence is None else {
            "value": r.confidence.value, "snr": r.confidence.snr,
            "consistency": r.confidence.consistency, "detection": r.confidence.detection,
            "prominence": r.confidence.prominence},
        "chirps": [{k: getattr(c, k) for k in ("tau_direct", "direct_peak", "floor", "sigma",
                                               "tau_echo", "echo_peak", "distance", "raw_range",
                                               "snr_db", "prom_sigma")} for c in r.chirps],
    }


def main() -> None:
    ROOT.mkdir(exist_ok=True)
    cfg = DEFAULT
    (ROOT / "config.json").write_text(json.dumps({
        "algo_version": ALGO_VERSION,
        "config": asdict(cfg),
        "bandpass_taps": bandpass_taps(cfg).tolist(),
        "filtered_reference": filtered_reference(cfg).tolist(),
        "ideal_template": {"pre": ideal_template(cfg).pre,
                           "data": interleave(ideal_template(cfg).data)},
    }, indent=1))

    rec, _ = simulate(open_space(), cfg)
    rec = f32(rec)
    rec.tofile(ROOT / "open_space.f32")
    tpl = build_template(rec.astype(float), cfg)
    (ROOT / "template.json").write_text(json.dumps({"pre": tpl.pre, "data": interleave(tpl.data)}))

    for i, (name, scene, mode, scfg) in enumerate(SCENES):
        x, info = simulate(scene, scfg)
        x = f32(x)
        x.tofile(ROOT / f"scene_{i:02d}.f32")
        t = {"calibrated": tpl, "ideal": ideal_template(scfg), "none": None}[mode]
        r = process_burst(x.astype(float), scfg, t)
        (ROOT / f"scene_{i:02d}.json").write_text(json.dumps({
            "name": name, "template": mode, "config": asdict(scfg),
            "scene": asdict(scene), "truth": info, "expected": burst_dict(r)}, indent=1))
        d = "suppressed" if r.suppressed else f"{r.distance:.3f} m"
        print(f"scene_{i:02d} {name:18s} {mode:10s} -> {d} ({r.category})")


if __name__ == "__main__":
    main()
