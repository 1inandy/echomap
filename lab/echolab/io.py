"""Trial CSV (ONE_SHOT_PLAN.md §7) and Capture Lab WAV + JSON sidecar loading."""
from __future__ import annotations

import csv
import json
from pathlib import Path

import numpy as np
from scipy.io import wavfile

from .signal import SignalConfig

TRIAL_COLUMNS = [
    "trial_id", "session_id", "timestamp_iso", "app_version", "algo_version", "device_model",
    "mode", "environment", "surface_material", "hold_orientation",
    "mic_source", "polar_pattern", "pitch_deg", "roll_deg", "temperature_c",
    "freq_start_hz", "freq_end_hz", "chirp_ms", "n_chirps", "period_ms",
    "actual_distance_m", "estimated_distance_m", "signed_error_m", "absolute_error_m",
    "percent_error",
    "suppressed", "confidence", "conf_snr", "conf_consistency", "conf_detection",
    "conf_prominence",
    "snr_db", "valid_chirps", "calibration_id", "notes",
]

FLOAT_COLUMNS = {
    "pitch_deg", "roll_deg", "temperature_c", "freq_start_hz", "freq_end_hz", "chirp_ms",
    "period_ms", "actual_distance_m", "estimated_distance_m", "signed_error_m",
    "absolute_error_m", "percent_error", "confidence", "conf_snr", "conf_consistency",
    "conf_detection", "conf_prominence", "snr_db",
}
INT_COLUMNS = {"n_chirps", "valid_chirps"}
BOOL_COLUMNS = {"suppressed"}


def _parse(col: str, v: str):
    if v == "":
        return None
    if col in FLOAT_COLUMNS:
        return float(v)
    if col in INT_COLUMNS:
        return int(v)
    if col in BOOL_COLUMNS:
        return v.strip().lower() == "true"
    return v


def read_trials(path: str | Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != TRIAL_COLUMNS:
            raise ValueError(f"unexpected header: {reader.fieldnames}")
        return [{k: _parse(k, row[k]) for k in TRIAL_COLUMNS} for row in reader]


def _fmt(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def write_trials(path: str | Path, trials: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\r\n")
        w.writerow(TRIAL_COLUMNS)
        for t in trials:
            w.writerow([_fmt(t.get(k)) for k in TRIAL_COLUMNS])


def read_wav(path: str | Path) -> tuple[float, np.ndarray]:
    fs, x = wavfile.read(path)
    x = np.asarray(x)
    if x.ndim > 1:
        x = x[:, 0]
    if np.issubdtype(x.dtype, np.integer):
        x = x.astype(float) / np.iinfo(x.dtype).max
    return float(fs), x.astype(float)


def read_capture(wav_path: str | Path) -> tuple[np.ndarray, SignalConfig, dict]:
    """Capture Lab export: <name>.wav + <name>.json sidecar."""
    wav_path = Path(wav_path)
    fs, x = read_wav(wav_path)
    side_path = wav_path.with_suffix(".json")
    meta = json.loads(side_path.read_text()) if side_path.exists() else {}
    c = meta.get("config", {})
    fields = SignalConfig.__dataclass_fields__
    cfg = SignalConfig(**{k: v for k, v in c.items() if k in fields})
    if cfg.fs != fs:
        cfg = cfg.with_(fs=fs)
    if "temperature_c" in meta:
        cfg = cfg.with_(temperature_c=float(meta["temperature_c"]))
    return x, cfg, meta
