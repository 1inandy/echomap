"""Stats, threshold fit, CSV schema, report and recording-analysis smoke tests."""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from scipy.io import wavfile

from echolab.io import TRIAL_COLUMNS, read_capture, read_trials, write_trials
from echolab.signal import DEFAULT
from echolab.simulate import Scene, open_space, simulate
from echolab.stats import fit_threshold, per_distance, summarize

LAB = Path(__file__).resolve().parents[1]
FIXTURES = LAB.parent / "fixtures"


def _trial(i, actual, est, conf, suppressed=False, **kw):
    t = {k: None for k in TRIAL_COLUMNS}
    t.update(trial_id=f"t{i}", session_id="s", mode="experiment", actual_distance_m=actual,
             estimated_distance_m=est, confidence=conf, suppressed=suppressed,
             calibration_id="c1", environment="lab")
    t.update(kw)
    return t


def test_schema_has_35_columns_in_plan_order():
    assert len(TRIAL_COLUMNS) == 35
    assert TRIAL_COLUMNS[0] == "trial_id" and TRIAL_COLUMNS[-1] == "notes"


def test_coverage_and_accuracy_are_separate():
    ts = [_trial(i, 1.0, 1.0 + 0.01 * i, 0.9) for i in range(8)]
    ts += [_trial(8, 1.0, None, 0.3, suppressed=True), _trial(9, 1.0, None, 0.2, suppressed=True)]
    s = summarize(ts)
    assert s.n == 10 and s.accepted == 8 and s.coverage == pytest.approx(0.8)
    assert s.median_abs == pytest.approx(0.035)
    assert s.wrongly_accepted == 0.0
    assert set(per_distance(ts)) == {1.0}


def test_threshold_fit_picks_lowest_threshold_meeting_targets():
    rng = np.random.default_rng(0)
    ts = []
    for i in range(200):
        conf = rng.uniform(0, 1)
        err = rng.normal(0, 0.05) if conf > 0.6 else rng.normal(0, 0.8)
        ts.append(_trial(i, 1.5, 1.5 + err, conf))
    fit = fit_threshold(ts)
    assert fit.threshold is not None and 0.5 < fit.threshold < 0.75
    assert fit.p90_abs <= 0.30 and fit.wrongly_accepted <= 0.05


def test_csv_round_trip_with_quoting(tmp_path):
    ts = [_trial(0, 1.0, 1.02, 0.8, notes='wall, "white", 2nd floor'),
          _trial(1, 2.0, None, 0.4, suppressed=True, notes="line\nbreak")]
    p = tmp_path / "t.csv"
    write_trials(p, ts)
    back = read_trials(p)
    assert back[0]["notes"] == 'wall, "white", 2nd floor'
    assert back[1]["notes"] == "line\nbreak" and back[1]["estimated_distance_m"] is None
    assert back[1]["suppressed"] is True


def test_swift_written_csv_is_readable():
    """EchoCore's TrialRecord CSV encoder writes this file in its tests (A5 round trip)."""
    p = FIXTURES / "trials_from_swift.csv"
    if not p.exists():
        pytest.skip("run `swift test --package-path EchoCore` first")
    ts = read_trials(p)
    assert len(ts) >= 3
    assert any(t["suppressed"] for t in ts)
    assert any("," in (t["notes"] or "") for t in ts)
    s = summarize(ts)
    assert s.n == len([t for t in ts if t["actual_distance_m"] is not None])


def test_swift_written_wav_is_readable():
    p = FIXTURES / "capture_from_swift.wav"
    if not p.exists():
        pytest.skip("run `swift test --package-path EchoCore` first")
    x, cfg, meta = read_capture(p)
    assert cfg.fs == 48_000 and len(x) == cfg.n_chirps * cfg.period_len
    assert meta["config"]["f0"] == cfg.f0
    assert np.max(np.abs(x)) > 0.1


def _write_capture(dirpath: Path, name: str, scene: Scene) -> Path:
    x, _ = simulate(scene, DEFAULT)
    wav = dirpath / f"{name}.wav"
    wavfile.write(wav, 48000, x.astype(np.float32))
    wav.with_suffix(".json").write_text(json.dumps({
        "config": {k: getattr(DEFAULT, k) for k in
                   ("fs", "f0", "f1", "chirp_ms", "tukey_alpha", "amplitude", "n_chirps", "period_ms")},
        "mic_source": "bottom", "polar_pattern": "omni", "hold_orientation": "A"}))
    return wav


def test_analyze_recordings_and_report_scripts_run(tmp_path):
    open_wav = _write_capture(tmp_path, "open", open_space())
    wall_wav = _write_capture(tmp_path, "wall", Scene(wall_m=1.5, seed=4))
    out = subprocess.run([sys.executable, str(LAB / "analyze_recordings.py"), str(wall_wav),
                          str(open_wav), "--template", str(open_wav), "--truth", "1.5",
                          "--out", str(tmp_path / "plots")], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert "H0:" in out.stdout and (tmp_path / "plots" / "wall.png").exists()

    ts = [_trial(i, d, d + 0.02, 0.8, environment=env)
          for i, (d, env) in enumerate([(1.0, "a"), (1.0, "b"), (2.0, "a"), (2.0, "b")] * 3)]
    csv_path = tmp_path / "t.csv"
    write_trials(csv_path, ts)
    out = subprocess.run([sys.executable, str(LAB / "report.py"), str(csv_path),
                          "--out", str(tmp_path / "rep")], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert (tmp_path / "rep" / "summary.md").exists()
    assert (tmp_path / "rep" / "error_vs_distance.png").exists()
