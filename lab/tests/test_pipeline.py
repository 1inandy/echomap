"""A1 + A2 checks (ONE_SHOT_PLAN.md §4)."""
import numpy as np
import pytest
from scipy.signal import firwin
from scipy.signal.windows import tukey as sp_tukey

from echolab.pipeline import (analytic_xcorr, build_template, filtered_reference,
                              fit_calibration, ideal_template, process_burst)
from echolab.signal import DEFAULT, bandpass_taps, make_chirp, tukey
from echolab.simulate import CLEAN_REFLECTOR, Scene, open_space, simulate

CFG = DEFAULT


@pytest.fixture(scope="module")
def calibrated_template():
    rec, _ = simulate(open_space(), CFG)
    return build_template(rec, CFG)


# --- A1 ---------------------------------------------------------------------

def test_tukey_matches_scipy():
    assert np.allclose(tukey(CFG.chirp_len, CFG.tukey_alpha),
                       sp_tukey(CFG.chirp_len, CFG.tukey_alpha))


def test_bandpass_matches_firwin():
    ref = firwin(CFG.fir_taps, [CFG.f0 - CFG.fir_margin_hz, CFG.f1 + CFG.fir_margin_hz],
                 pass_zero=False, window=("kaiser", CFG.kaiser_beta), fs=CFG.fs)
    assert np.allclose(bandpass_taps(CFG), ref, atol=1e-12)


def test_chirp_length_and_band():
    c = make_chirp(CFG)
    assert len(c) == 480
    spec = np.abs(np.fft.rfft(c, 1 << 14))
    f = np.fft.rfftfreq(1 << 14, 1 / CFG.fs)
    assert CFG.f0 - 500 < f[np.argmax(spec)] < CFG.f1 + 500
    assert np.max(np.abs(c)) <= CFG.amplitude + 1e-12


def test_autocorrelation_peaks_at_lag_zero():
    ref = filtered_reference(CFG)
    x = np.zeros(CFG.period_len)
    x[: len(ref)] = ref
    env = np.abs(analytic_xcorr(x, ref))
    assert int(np.argmax(env)) == 0


@pytest.mark.parametrize("d", [0.5, 1.0, 1.5, 2.0, 2.5])
def test_clean_single_reflector_within_2cm(d):
    rec, _ = simulate(CLEAN_REFLECTOR.with_(wall_m=d), CFG)
    r = process_burst(rec, CFG, ideal_template(CFG))
    assert not r.suppressed
    assert abs(r.distance - d) <= 0.02


# --- A2 ---------------------------------------------------------------------

def _errors(template, walls, snrs, seeds, **scene_kw):
    errs = {}
    for d in walls:
        for snr in snrs:
            for seed in seeds:
                rec, _ = simulate(Scene(wall_m=d, snr_db=snr, seed=seed, **scene_kw), CFG)
                r = process_burst(rec, CFG, template)
                errs.setdefault(d, []).append(
                    np.inf if r.median_distance is None else abs(r.median_distance - d))
    return errs


def test_simulated_rooms_median_error_le_3cm(calibrated_template):
    walls = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5]
    errs = _errors(calibrated_template, walls, [15, 20, 30], range(4))
    all_errs = np.concatenate([v for v in errs.values()])
    assert np.median(all_errs) <= 0.03
    for d, e in errs.items():
        assert np.median(e) <= 0.03, (d, np.median(e))


def test_reverb_range_rt60(calibrated_template):
    for rt60 in (0.3, 0.8):
        errs = _errors(calibrated_template, [1.0, 2.0], [15], range(3), rt60_s=rt60)
        assert np.median(np.concatenate(list(errs.values()))) <= 0.03, rt60


def test_leakage_subtraction_off_is_visibly_worse_at_half_metre(calibrated_template):
    on = np.median(_errors(calibrated_template, [0.5], [20], range(6))[0.5])
    off = np.median(_errors(None, [0.5], [20], range(6))[0.5])
    assert on <= 0.03
    assert off >= 0.05 and off >= 3 * on, (on, off)


def test_floor_nearer_than_wall_is_reported_not_the_wall(calibrated_template):
    """Documents risk R1: the iPhone measures the NEAREST reflector in any direction.
    With the floor at 1.3 m and a wall at 2.0 m, the pipeline reports the floor."""
    for seed in range(5):
        rec, info = simulate(Scene(wall_m=2.0, floor_h_m=1.3, seed=seed), CFG)
        r = process_burst(rec, CFG, calibrated_template)
        assert r.median_distance is not None
        assert abs(r.median_distance - info["expected_floor_m"]) <= 0.05
        assert abs(r.median_distance - 2.0) > 0.5


def test_empty_room_is_suppressed(calibrated_template):
    for seed in range(6):
        rec, _ = simulate(Scene(wall_m=None, seed=seed), CFG)
        assert process_burst(rec, CFG, calibrated_template).suppressed


def test_very_low_snr_is_suppressed_not_wrong(calibrated_template):
    wrong = 0
    for seed in range(8):
        rec, _ = simulate(Scene(wall_m=1.5, snr_db=-15, seed=seed), CFG)
        r = process_burst(rec, CFG, calibrated_template)
        if not r.suppressed and abs(r.distance - 1.5) > 0.30:
            wrong += 1
    assert wrong == 0


def test_latency_drops_out(calibrated_template):
    ds = []
    for lat in (5.0, 17.3, 39.0):
        rec, _ = simulate(Scene(wall_m=1.2, latency_ms=lat, seed=3), CFG)
        ds.append(process_burst(rec, CFG, calibrated_template).distance)
    assert max(ds) - min(ds) < 0.01


def test_calibration_offset_fit_removes_bias(calibrated_template):
    # Calibrate at 1.00 m (offset only), then check other distances.
    raws = []
    for seed in range(10):
        rec, _ = simulate(Scene(wall_m=1.0, seed=50 + seed), CFG)
        raws.append(process_burst(rec, CFG, calibrated_template).raw_range)
    fit = fit_calibration([1.0] * len(raws), raws)
    assert fit.scale == 1.0 and fit.reliability == 1.0 and fit.residual < 0.01
    for d in (0.75, 2.0):
        rec, _ = simulate(Scene(wall_m=d, seed=99), CFG)
        r = process_burst(rec, CFG, calibrated_template, offset=fit.offset, scale=fit.scale)
        assert abs(r.distance - d) < 0.01


def test_calibration_two_point_fit_recovers_scale():
    truth = [1.0] * 5 + [2.0] * 5
    raws = [(t - 0.05) / 1.02 for t in truth]
    fit = fit_calibration(truth, raws + [])
    assert abs(fit.scale - 1.02) < 1e-9 and abs(fit.offset - 0.05) < 1e-9
    fit2 = fit_calibration([1.0, 1.0], [0.9, None])
    assert fit2.reliability == 0.5 and abs(fit2.offset - 0.1) < 1e-12
