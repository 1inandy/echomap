"""Synthetic room recordings (ONE_SHOT_PLAN.md step A2).

A recording is the transmitted burst through a sparse image-source impulse response
(speaker->mic leakage with a ringing tail, body, floor, target wall), plus band-limited
diffuse reverb, white + pink noise, a random play/record latency and +-1 sample jitter.

Levels are modelling assumptions, not measurements: they exist to exercise the pipeline.
Real numbers come from Capture Lab recordings (lab/analyze_recordings.py).
"""
from __future__ import annotations

from dataclasses import dataclass, replace

import numpy as np
from scipy.signal import fftconvolve

from .signal import DEFAULT, SignalConfig, bandpass_taps, chirp_at, make_chirp

# Echo amplitude = reflectance * ECHO_K / path_length (spherical spreading), relative to
# a speaker->mic leakage amplitude of LEAK_AMP.
ECHO_K = 0.1
LEAK_AMP = 1.0


@dataclass(frozen=True)
class Scene:
    wall_m: float | None = 1.0
    wall_reflectance: float = 0.8
    floor_h_m: float | None = None
    floor_reflectance: float = 0.6
    body: bool = True
    body_m: float = 0.30
    body_reflectance: float = 0.3
    leakage: bool = True
    ringing: bool = True
    ringing_ms: float = 3.0
    ringing_level: float = 0.3
    ringing_tau_ms: float = 1.0
    reverb: bool = True
    rt60_s: float = 0.5
    reverb_db: float = -30.0  # diffuse envelope level re a 1 m wall echo
    reverb_onset_ms: float = 3.0
    snr_db: float | None = 20.0  # in-band, re the wall echo; None = no noise
    latency_ms: float | None = None  # None = random in [5, 40]
    jitter: bool = True
    seed: int = 0
    device_seed: int = 7  # fixes the leakage ringing shape ("this phone")

    def with_(self, **kw) -> "Scene":
        return replace(self, **kw)


CLEAN_REFLECTOR = Scene(body=False, ringing=False, reverb=False, snr_db=None,
                        latency_ms=10.0, jitter=False)


def wall_path(d: float, cfg: SignalConfig) -> float:
    """Speaker->wall->mic path length for a wall at distance d, speaker and mic
    side by side (separation s) parallel to the wall."""
    s = cfg.speaker_mic_separation_m
    return 2.0 * np.sqrt(d * d + (s / 2) ** 2)


def expected_distance(d: float, cfg: SignalConfig = DEFAULT) -> float:
    """What a perfect pipeline with offset = s/2 reports for a wall at d."""
    s = cfg.speaker_mic_separation_m
    return (wall_path(d, cfg) - s) / 2 + s / 2


def taps(scene: Scene, cfg: SignalConfig) -> list[tuple[float, float]]:
    """(delay seconds after emission, amplitude) for every discrete path."""
    c = cfg.speed_of_sound
    s = cfg.speaker_mic_separation_m
    out: list[tuple[float, float]] = []
    t_leak = s / c
    if scene.leakage:
        out.append((t_leak, LEAK_AMP))
        if scene.ringing:
            rng = np.random.default_rng(scene.device_seed)
            n = int(round(scene.ringing_ms * 1e-3 * cfg.fs))
            tau = scene.ringing_tau_ms * 1e-3 * cfg.fs
            g = rng.standard_normal(n)
            for j in range(1, n + 1):
                out.append((t_leak + j / cfg.fs,
                            LEAK_AMP * scene.ringing_level * np.exp(-j / tau) * g[j - 1]))
    if scene.body:
        L = 2 * scene.body_m
        out.append((L / c, scene.body_reflectance * ECHO_K / L))
    if scene.floor_h_m is not None:
        L = wall_path(scene.floor_h_m, cfg)
        out.append((L / c, scene.floor_reflectance * ECHO_K / L))
    if scene.wall_m is not None:
        L = wall_path(scene.wall_m, cfg)
        out.append((L / c, scene.wall_reflectance * ECHO_K / L))
    return out


def pink_noise(n: int, rng: np.random.Generator) -> np.ndarray:
    X = np.fft.rfft(rng.standard_normal(n))
    f = np.arange(len(X), dtype=float)
    f[0] = 1.0
    x = np.fft.irfft(X / np.sqrt(f), n)
    return x / np.std(x)


def simulate(scene: Scene, cfg: SignalConfig = DEFAULT) -> tuple[np.ndarray, dict]:
    """Return (recording, info). The recording has n_chirps * period_len samples and starts
    when recording starts; playback starts `latency` later."""
    rng = np.random.default_rng(scene.seed)
    fs = cfg.fs
    P = cfg.period_len
    n_total = cfg.n_chirps * P
    latency_ms = scene.latency_ms if scene.latency_ms is not None else rng.uniform(5, 40)
    lat = int(round(latency_ms * 1e-3 * fs))
    jit = rng.integers(-1, 2, cfg.n_chirps) if scene.jitter else np.zeros(cfg.n_chirps, int)
    emit = lat + np.arange(cfg.n_chirps) * P + jit  # integer emission samples

    rec = np.zeros(n_total)
    t = np.arange(n_total) / fs
    clen = cfg.chirp_len
    for e in emit:
        for delay, amp in taps(scene, cfg):
            start = e / fs + delay
            i0 = max(int(np.floor(start * fs)), 0)
            i1 = min(i0 + clen + 2, n_total)
            if i0 >= n_total:
                continue
            rec[i0:i1] += amp * chirp_at(t[i0:i1] - start, cfg)

    # Wall echo amplitude (or a 1 m reference) sets the noise / reverb levels.
    a_1m = 0.8 * ECHO_K / wall_path(1.0, cfg)
    a_ref = (scene.wall_reflectance * ECHO_K / wall_path(scene.wall_m, cfg)
             if scene.wall_m is not None else a_1m)

    if scene.reverb:
        n_ir = int(min(scene.rt60_s, 0.6) * fs)
        k = np.arange(n_ir)
        onset = int(round(scene.reverb_onset_ms * 1e-3 * fs))
        ramp = np.clip((k - onset) / (5e-3 * fs), 0, 1)
        decay = np.exp(-6.9078 * k / (scene.rt60_s * fs))
        eff = fs / cfg.bandwidth  # ~ correlated samples per pulse width
        sigma = 10 ** (scene.reverb_db / 20) * a_1m / np.sqrt(eff)
        ir = sigma * rng.standard_normal(n_ir) * ramp * decay
        exc = np.zeros(n_total)
        exc[emit[emit < n_total]] = 1.0
        src = np.convolve(exc, make_chirp(cfg))[:n_total]
        rec += fftconvolve(src, ir)[:n_total]

    if scene.snr_db is not None:
        noise = rng.standard_normal(n_total) + pink_noise(n_total, rng)
        h = bandpass_taps(cfg)
        p_noise = np.mean(np.convolve(noise, h, mode="same") ** 2)
        p_echo = a_ref ** 2 * np.mean(make_chirp(cfg) ** 2)
        noise *= np.sqrt(p_echo / 10 ** (scene.snr_db / 10) / p_noise)
        rec += noise

    info = {
        "latency_samples": lat,
        "emit": emit.tolist(),
        "expected_wall_m": expected_distance(scene.wall_m, cfg) if scene.wall_m else None,
        "expected_floor_m": expected_distance(scene.floor_h_m, cfg) if scene.floor_h_m else None,
    }
    return rec, info


def open_space(seed: int = 100, **kw) -> Scene:
    """Calibration step 1: nothing within ~1 m except the user's body (floor further away)."""
    return Scene(wall_m=None, floor_h_m=1.3, seed=seed, **kw)
