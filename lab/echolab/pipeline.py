"""Reference ranging pipeline (ONE_SHOT_PLAN.md §5).

band-pass -> matched filter (analytic, FFT) -> baseband envelope -> direct path ->
leakage subtraction -> noise floor -> first significant echo -> distance -> burst
aggregation -> confidence.

`EchoCore` (Swift) ports this file function for function.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .signal import DEFAULT, SignalConfig, bandpass_taps, make_chirp

MAD_SCALE = 1.4826
SNR_CAP_DB = 120.0
PROM_CAP = 1e6


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

def next_pow2(n: int) -> int:
    p = 1
    while p < n:
        p <<= 1
    return p


def filter_causal(x: np.ndarray, h: np.ndarray) -> np.ndarray:
    """Causal FIR, output truncated to len(x)."""
    return np.convolve(x, h)[: len(x)]


def filtered_reference(cfg: SignalConfig = DEFAULT) -> np.ndarray:
    """Transmitted chirp through the same band-pass (full convolution), so the
    filter's group delay cancels in the correlation lag."""
    return np.convolve(make_chirp(cfg), bandpass_taps(cfg))


def analytic_xcorr(x: np.ndarray, ref: np.ndarray) -> np.ndarray:
    """Analytic cross-correlation c[k] = sum_n x[n+k] ref[n] (+ j Hilbert),
    for lags k in [0, len(x)). Zero-padded to the next power of two >= 2*len(x)."""
    n = next_pow2(2 * max(len(x), len(ref)))
    X = np.fft.fft(x, n)
    R = np.fft.fft(ref, n)
    C = X * np.conj(R)
    C[1 : n // 2] *= 2.0
    C[n // 2 + 1 :] = 0.0
    return np.fft.ifft(C)[: len(x)]


def baseband(c: np.ndarray, cfg: SignalConfig = DEFAULT) -> np.ndarray:
    """Shift the analytic correlation down by the chirp centre frequency. |baseband| is the
    envelope; the baseband signal is smooth enough for linear sub-sample interpolation."""
    k = np.arange(len(c))
    return c * np.exp(-2j * np.pi * cfg.fc * k / cfg.fs)


def parabolic(y: np.ndarray, i: int) -> float:
    """Sub-sample peak position by fitting a parabola through y[i-1], y[i], y[i+1]."""
    if i <= 0 or i >= len(y) - 1:
        return float(i)
    a, b, c = y[i - 1], y[i], y[i + 1]
    den = a - 2 * b + c
    if den == 0:
        return float(i)
    return i + 0.5 * (a - c) / den


def interp_complex(z: np.ndarray, pos: np.ndarray) -> np.ndarray:
    """Linear interpolation of a complex sequence at fractional positions; 0 outside."""
    out = np.zeros(len(pos), dtype=complex)
    i0 = np.floor(pos).astype(int)
    f = pos - i0
    ok = (i0 >= 0) & (i0 + 1 < len(z))
    out[ok] = z[i0[ok]] * (1 - f[ok]) + z[i0[ok] + 1] * f[ok]
    # Exactly on the last sample.
    last = i0 == len(z) - 1
    out[last & (f == 0)] = z[-1]
    return out


def median(x: np.ndarray) -> float:
    return float(np.median(np.asarray(x, dtype=float)))


def mad(x: np.ndarray) -> float:
    x = np.asarray(x, dtype=float)
    return float(np.median(np.abs(x - np.median(x))))


def lag_for_distance(d: float, cfg: SignalConfig, offset: float, scale: float) -> float:
    """Lag (samples after the direct path) at which a surface at distance d appears."""
    return 2.0 * (d - offset) / (scale * cfg.speed_of_sound) * cfg.fs


def distance_for_lag(dlag: float, cfg: SignalConfig, offset: float, scale: float) -> float:
    return scale * cfg.speed_of_sound * dlag / (2.0 * cfg.fs) + offset


def prominence(env: np.ndarray, i: int, lo: int, hi: int) -> float:
    """Topographic prominence of env[i], with the search limited to [lo, hi]."""
    p = env[i]
    left_min = p
    j = i - 1
    while j >= lo and env[j] <= p:
        left_min = min(left_min, env[j])
        j -= 1
    right_min = p
    j = i + 1
    while j <= hi and env[j] <= p:
        right_min = min(right_min, env[j])
        j += 1
    return float(p - max(left_min, right_min))


# ---------------------------------------------------------------------------
# Leakage template
# ---------------------------------------------------------------------------

@dataclass
class LeakageTemplate:
    """Average baseband correlation around the direct path, phase-normalised.
    Index `pre` corresponds to the direct-path peak."""
    data: np.ndarray  # complex
    pre: int

    def to_interleaved(self) -> np.ndarray:
        return np.column_stack([self.data.real, self.data.imag]).ravel()


def template_lengths(cfg: SignalConfig) -> tuple[int, int, int]:
    pre = int(round(cfg.template_pre_ms * 1e-3 * cfg.fs))
    post = int(round(cfg.template_post_ms * 1e-3 * cfg.fs))
    taper = int(round(cfg.template_taper_ms * 1e-3 * cfg.fs))
    return pre, post, taper


def build_template(recording: np.ndarray, cfg: SignalConfig = DEFAULT,
                   n_chirps: int | None = None) -> LeakageTemplate:
    """From an open-space capture (no surface within ~1 m), average the aligned
    baseband correlation around the direct path over all chirps."""
    pre, post, taper = template_lengths(cfg)
    length = pre + post
    ref = filtered_reference(cfg)
    h = bandpass_taps(cfg)
    P = cfg.period_len
    n = n_chirps if n_chirps is not None else len(recording) // P
    acc = np.zeros(length, dtype=complex)
    used = 0
    for i in range(n):
        w = recording[i * P : (i + 1) * P]
        if len(w) < P:
            break
        b = baseband(analytic_xcorr(filter_causal(w, h), ref), cfg)
        env = np.abs(b)
        td = direct_path(env, cfg)
        seg = interp_complex(b, td - pre + np.arange(length))
        ph = interp_complex(b, np.array([td]))[0]
        if abs(ph) == 0:
            continue
        acc += seg * (np.conj(ph) / abs(ph))
        used += 1
    if used == 0:
        raise ValueError("no usable chirps for template")
    acc /= used
    if taper > 0:
        # Raised-cosine fade over the last `taper` samples.
        k = np.arange(taper)
        acc[length - taper :] *= 0.5 * (1 + np.cos(np.pi * (k + 1) / taper))
    return LeakageTemplate(acc, pre)


def ideal_template(cfg: SignalConfig = DEFAULT) -> LeakageTemplate:
    """Template for an ideal (flat-response) direct path: the reference's own baseband
    autocorrelation. Used until a calibrated template exists."""
    pre, _, taper = template_lengths(cfg)
    ref = filtered_reference(cfg)
    P = cfg.period_len
    x = np.zeros(P)
    lag0 = pre + 1
    x[lag0 : lag0 + len(ref)] = ref
    b = baseband(analytic_xcorr(x, ref), cfg)
    # The whole correlation support (len(ref) lags), so no direct-path sidelobe survives.
    length = pre + len(ref) + taper
    seg = b[lag0 - pre : lag0 - pre + length].copy()
    seg *= np.conj(b[lag0]) / abs(b[lag0])
    if taper > 0:
        k = np.arange(taper)
        seg[length - taper :] *= 0.5 * (1 + np.cos(np.pi * (k + 1) / taper))
    return LeakageTemplate(seg, pre)


def subtract_template(b: np.ndarray, td: float, tpl: LeakageTemplate,
                      cfg: SignalConfig) -> np.ndarray:
    """Align the template to td, least-squares complex scale over td +- fit window,
    subtract. Returns a new baseband array."""
    L = len(tpl.data)
    start = td - tpl.pre
    k0 = max(int(math.ceil(start)), 0)
    k1 = min(int(math.floor(start + L - 1)), len(b) - 1)
    if k1 < k0:
        return b.copy()
    ks = np.arange(k0, k1 + 1)
    t_al = interp_complex(tpl.data, ks - start)
    fit = int(round(cfg.template_fit_ms * 1e-3 * cfg.fs))
    c = int(round(td))
    m = (ks >= c - fit) & (ks <= c + fit)
    den = np.sum(np.abs(t_al[m]) ** 2)
    if den == 0:
        return b.copy()
    a = np.sum(np.conj(t_al[m]) * b[ks[m]]) / den
    out = b.copy()
    out[ks] -= a * t_al
    return out


# ---------------------------------------------------------------------------
# Per-chirp processing
# ---------------------------------------------------------------------------

def direct_path(env: np.ndarray, cfg: SignalConfig) -> float:
    n = min(len(env), int(round(cfg.direct_search_ms * 1e-3 * cfg.fs)))
    i = int(np.argmax(env[:n]))
    return parabolic(env, i)


@dataclass
class ChirpResult:
    tau_direct: float
    direct_peak: float
    floor: float
    sigma: float
    tau_echo: float | None = None
    echo_peak: float | None = None
    distance: float | None = None
    raw_range: float | None = None  # c * dlag / 2, no offset/scale (for calibration)
    snr_db: float | None = None
    prom_sigma: float | None = None

    @property
    def valid(self) -> bool:
        return self.distance is not None


def noise_region(env: np.ndarray, td: float, cfg: SignalConfig, offset: float,
                 scale: float) -> np.ndarray:
    P = len(env)
    a = int(math.ceil(td + lag_for_distance(cfg.noise_lo_m, cfg, offset, scale)))
    b = int(math.floor(td + lag_for_distance(cfg.noise_hi_m, cfg, offset, scale)))
    if b <= P - 1:
        return env[a : b + 1]
    pre, _, _ = template_lengths(cfg)
    pre_end = int(math.floor(td)) - pre
    if pre_end >= 64:
        return env[:pre_end]
    n = b - a + 1
    return env[P - n :]


def process_chirp(window: np.ndarray, cfg: SignalConfig = DEFAULT,
                  template: LeakageTemplate | None = None,
                  offset: float | None = None, scale: float = 1.0,
                  _cache: dict | None = None) -> ChirpResult:
    offset = cfg.default_offset_m if offset is None else offset
    if _cache is None:
        _cache = {}
    h = _cache.setdefault("h", bandpass_taps(cfg))
    ref = _cache.setdefault("ref", filtered_reference(cfg))

    b = baseband(analytic_xcorr(filter_causal(window, h), ref), cfg)
    env = np.abs(b)
    td = direct_path(env, cfg)
    direct_peak = float(np.max(env[: min(len(env), int(round(cfg.direct_search_ms * 1e-3 * cfg.fs)))]))
    if template is not None:
        b = subtract_template(b, td, template, cfg)
        env = np.abs(b)

    region = noise_region(env, td, cfg, offset, scale)
    floor = median(region)
    sigma = MAD_SCALE * mad(region)
    res = ChirpResult(tau_direct=td, direct_peak=direct_peak, floor=floor, sigma=sigma)

    P = len(env)
    lo = int(math.ceil(td + lag_for_distance(cfg.blanking_m, cfg, offset, scale)))
    hi = min(int(math.floor(td + lag_for_distance(cfg.max_range_m, cfg, offset, scale))), P - 2)
    lo = max(lo, 1)
    thr = max(floor + cfg.detection_k * sigma,
              direct_peak * 10 ** (cfg.sidelobe_guard_db / 20))
    min_prom = cfg.min_prominence_sigma * sigma
    width = int(round(cfg.cluster_pulse_widths * cfg.fs / cfg.bandwidth))

    def is_peak(i: int) -> bool:
        return env[i] > env[i - 1] and env[i] >= env[i + 1] and env[i] > thr

    first = None
    for i in range(lo, hi + 1):
        if is_peak(i) and prominence(env, i, lo, hi) >= min_prom:
            first = i
            break
    if first is None:
        return res

    # Climb from the first detection to the dominant peak of its cluster: an echo's own
    # leading sidelobes come up to ~2 pulse widths before its main peak.
    best = first
    moved = True
    while moved:
        moved = False
        for i in range(best + 1, min(best + width, hi) + 1):
            if is_peak(i) and env[i] > env[best]:
                best = i
                moved = True
                break

    te = parabolic(env, best)
    dlag = te - td
    res.tau_echo = te
    res.echo_peak = float(env[best])
    res.raw_range = cfg.speed_of_sound * dlag / (2.0 * cfg.fs)
    res.distance = distance_for_lag(dlag, cfg, offset, scale)
    res.snr_db = SNR_CAP_DB if floor <= 0 else min(SNR_CAP_DB, 20 * math.log10(env[best] / floor))
    prom = prominence(env, best, lo, hi)
    res.prom_sigma = PROM_CAP if sigma <= 0 else min(PROM_CAP, prom / sigma)
    return res


# ---------------------------------------------------------------------------
# Burst aggregation & confidence
# ---------------------------------------------------------------------------

def clamp01(x: float) -> float:
    return 0.0 if x < 0 else 1.0 if x > 1 else float(x)


@dataclass
class Confidence:
    snr: float
    consistency: float
    detection: float
    prominence: float

    @property
    def value(self) -> float:
        p = self.snr * self.consistency * self.detection * self.prominence
        return float(p ** 0.25) if p > 0 else 0.0


def confidence(snr_db: float, mad_d: float, valid: int, n: int,
               prom_sigma: float) -> Confidence:
    return Confidence(
        snr=clamp01((snr_db - 6.0) / 14.0),
        consistency=math.exp(-mad_d / 0.05),
        detection=valid / n if n else 0.0,
        prominence=clamp01((prom_sigma - 3.0) / 9.0),
    )


@dataclass
class BurstResult:
    chirps: list[ChirpResult]
    n: int
    valid: int
    distance: float | None  # None when suppressed
    median_distance: float | None  # median even if suppressed (for diagnostics)
    raw_range: float | None
    mad: float | None
    snr_db: float | None
    prom_sigma: float | None
    confidence: Confidence | None
    category: str  # "high" | "medium" | "suppressed"
    suppressed: bool = field(default=True)


def categorize(conf: float, cfg: SignalConfig) -> str:
    if conf >= cfg.high_threshold:
        return "high"
    if conf >= cfg.medium_threshold:
        return "medium"
    return "suppressed"


def process_burst(recording: np.ndarray, cfg: SignalConfig = DEFAULT,
                  template: LeakageTemplate | None = None,
                  offset: float | None = None, scale: float = 1.0) -> BurstResult:
    P = cfg.period_len
    cache: dict = {}
    chirps = []
    for i in range(cfg.n_chirps):
        w = recording[i * P : (i + 1) * P]
        if len(w) < P:
            break
        chirps.append(process_chirp(w, cfg, template, offset, scale, cache))
    n = cfg.n_chirps
    good = [c for c in chirps if c.valid]
    if not good:
        return BurstResult(chirps, n, 0, None, None, None, None, None, None, None,
                           "suppressed", True)
    ds = np.array([c.distance for c in good])
    d_med = median(ds)
    d_mad = mad(ds)
    raw = median(np.array([c.raw_range for c in good]))
    snr_db = median(np.array([c.snr_db for c in good]))
    prom = median(np.array([c.prom_sigma for c in good]))
    conf = confidence(snr_db, d_mad, len(good), n, prom)
    cat = categorize(conf.value, cfg) if len(good) >= cfg.min_valid_chirps else "suppressed"
    sup = cat == "suppressed"
    return BurstResult(chirps, n, len(good), None if sup else d_med, d_med, raw, d_mad,
                       snr_db, prom, conf, cat, sup)


# ---------------------------------------------------------------------------
# Calibration
# ---------------------------------------------------------------------------

@dataclass
class CalibrationFit:
    offset: float
    scale: float
    residual: float  # RMS residual over bursts (m)
    reliability: float  # share of bursts with enough valid chirps


def fit_calibration(truth: list[float], raw_ranges: list[float | None]) -> CalibrationFit:
    """Fit distance = scale * raw_range + offset. One known distance -> offset only
    (scale = 1); two or more distinct distances -> least-squares scale and offset.
    `raw_ranges` holds each burst's median raw range, or None if the burst failed."""
    pairs = [(t, r) for t, r in zip(truth, raw_ranges) if r is not None]
    reliability = len(pairs) / len(truth) if truth else 0.0
    if not pairs:
        raise ValueError("no valid bursts")
    t = np.array([p[0] for p in pairs])
    r = np.array([p[1] for p in pairs])
    if len(set(np.round(t, 6))) < 2:
        scale = 1.0
        offset = float(np.mean(t - r))
    else:
        rm, tm = r.mean(), t.mean()
        scale = float(np.sum((r - rm) * (t - tm)) / np.sum((r - rm) ** 2))
        offset = float(tm - scale * rm)
    res = t - (scale * r + offset)
    return CalibrationFit(offset, scale, float(np.sqrt(np.mean(res ** 2))), reliability)
