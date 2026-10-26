"""Signal configuration and chirp generation.

Every number here must match `EchoCore/Sources/EchoCore/SignalConfig.swift`.
"""
from __future__ import annotations

from dataclasses import dataclass, asdict, replace

import numpy as np

ALGO_VERSION = "0.1.0"


@dataclass(frozen=True)
class SignalConfig:
    fs: float = 48_000.0
    f0: float = 18_000.0
    f1: float = 20_000.0
    chirp_ms: float = 10.0
    tukey_alpha: float = 0.5
    amplitude: float = 0.5
    n_chirps: int = 5
    period_ms: float = 100.0

    # Band-pass FIR
    fir_taps: int = 129
    kaiser_beta: float = 8.0
    fir_margin_hz: float = 500.0

    # Detection
    direct_search_ms: float = 60.0
    blanking_m: float = 0.40
    max_range_m: float = 3.00
    noise_lo_m: float = 4.0
    noise_hi_m: float = 6.0
    detection_k: float = 6.0
    min_prominence_sigma: float = 3.0
    # Guard against the direct path's own correlation sidelobes when the noise floor is
    # unrealistically low: a peak must also exceed this level relative to the direct peak.
    sidelobe_guard_db: float = -70.0
    # Climb window (pulse widths of fs/B samples): from the first detection, move to any higher
    # peak within this window, repeatedly. Covers an echo's own leading sidelobes.
    cluster_pulse_widths: float = 3.0

    # Leakage template (relative to the direct peak)
    template_pre_ms: float = 1.0
    # Covers leakage ringing; stays short of a floor echo (~1.1 m) in an open-space capture.
    template_post_ms: float = 5.0
    template_taper_ms: float = 0.5
    template_fit_ms: float = 1.0

    # Geometry / physics
    temperature_c: float = 20.0
    speaker_mic_separation_m: float = 0.14

    # Aggregation / confidence
    min_valid_chirps: int = 3
    high_threshold: float = 0.75
    medium_threshold: float = 0.50

    @property
    def chirp_len(self) -> int:
        return int(round(self.chirp_ms * 1e-3 * self.fs))

    @property
    def period_len(self) -> int:
        return int(round(self.period_ms * 1e-3 * self.fs))

    @property
    def fc(self) -> float:
        return 0.5 * (self.f0 + self.f1)

    @property
    def bandwidth(self) -> float:
        return abs(self.f1 - self.f0)

    @property
    def speed_of_sound(self) -> float:
        return speed_of_sound(self.temperature_c)

    @property
    def default_offset_m(self) -> float:
        return 0.5 * self.speaker_mic_separation_m

    def with_(self, **kw) -> "SignalConfig":
        return replace(self, **kw)

    def to_dict(self) -> dict:
        return asdict(self)


DEFAULT = SignalConfig()
AUDIBLE_DEV = SignalConfig(f0=14_000.0, f1=17_000.0)


def speed_of_sound(temperature_c: float) -> float:
    return 331.3 + 0.606 * temperature_c


def tukey(n: int, alpha: float) -> np.ndarray:
    """Tukey window, same definition as scipy.signal.windows.tukey(n, alpha, sym=True)."""
    if n == 1:
        return np.ones(1)
    if alpha <= 0:
        return np.ones(n)
    x = np.arange(n) / (n - 1)
    w = np.ones(n)
    a2 = alpha / 2.0
    lo = x < a2
    hi = x > 1.0 - a2
    w[lo] = 0.5 * (1 + np.cos(np.pi * (2 * x[lo] / alpha - 1)))
    w[hi] = 0.5 * (1 + np.cos(np.pi * (2 * x[hi] / alpha - 2 / alpha + 1)))
    return w


def chirp_at(t: np.ndarray, cfg: SignalConfig = DEFAULT) -> np.ndarray:
    """Continuous-time chirp evaluated at times t (seconds, 0 = chirp start).

    Used by the simulator for exact fractional delays. Zero outside [0, T].
    """
    T = cfg.chirp_len / cfg.fs
    k = (cfg.f1 - cfg.f0) / T
    t = np.asarray(t, dtype=float)
    inside = (t >= 0) & (t <= (cfg.chirp_len - 1) / cfg.fs)
    out = np.zeros_like(t)
    ti = t[inside]
    # Continuous Tukey over [0, (n-1)/fs], matching the sampled window at integer samples.
    x = ti * cfg.fs / (cfg.chirp_len - 1)
    a = cfg.tukey_alpha
    w = np.ones_like(x)
    lo = x < a / 2
    hi = x > 1 - a / 2
    w[lo] = 0.5 * (1 + np.cos(np.pi * (2 * x[lo] / a - 1)))
    w[hi] = 0.5 * (1 + np.cos(np.pi * (2 * x[hi] / a - 2 / a + 1)))
    out[inside] = cfg.amplitude * w * np.sin(2 * np.pi * (cfg.f0 * ti + 0.5 * k * ti * ti))
    return out


def make_chirp(cfg: SignalConfig = DEFAULT) -> np.ndarray:
    """The transmitted chirp, sampled. Length cfg.chirp_len."""
    return chirp_at(np.arange(cfg.chirp_len) / cfg.fs, cfg)


def make_burst(cfg: SignalConfig = DEFAULT) -> np.ndarray:
    """N chirps, one at the start of each period. Length n_chirps * period_len."""
    out = np.zeros(cfg.n_chirps * cfg.period_len)
    c = make_chirp(cfg)
    for i in range(cfg.n_chirps):
        out[i * cfg.period_len : i * cfg.period_len + len(c)] = c
    return out


def bessel_i0(x: np.ndarray | float) -> np.ndarray:
    """Modified Bessel function of the first kind, order 0 (power series)."""
    x = np.asarray(x, dtype=float)
    y = (x / 2.0) ** 2
    term = np.ones_like(x)
    total = np.ones_like(x)
    for k in range(1, 60):
        term = term * y / (k * k)
        total = total + term
    return total


def bandpass_taps(cfg: SignalConfig = DEFAULT) -> np.ndarray:
    """Kaiser-windowed sinc band-pass, equivalent to
    scipy.signal.firwin(taps, [lo, hi], pass_zero=False, window=('kaiser', beta), fs=fs)."""
    n = cfg.fir_taps
    lo = (min(cfg.f0, cfg.f1) - cfg.fir_margin_hz) / (cfg.fs / 2)
    hi = (max(cfg.f0, cfg.f1) + cfg.fir_margin_hz) / (cfg.fs / 2)
    hi = min(hi, 0.999)
    m = np.arange(n) - (n - 1) / 2.0
    h = hi * np.sinc(hi * m) - lo * np.sinc(lo * m)
    beta = cfg.kaiser_beta
    w = bessel_i0(beta * np.sqrt(1 - (2 * np.arange(n) / (n - 1) - 1) ** 2)) / bessel_i0(beta)
    h = h * w
    # Unity gain at the passband centre (firwin scale=True).
    f_center = 0.5 * (lo + hi)
    gain = np.sum(h * np.cos(np.pi * m * f_center))
    return h / gain
