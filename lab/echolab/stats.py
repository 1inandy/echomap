"""Accuracy statistics and threshold fitting (ONE_SHOT_PLAN.md §5.6, R9).

Coverage (share of trials not suppressed) and accuracy on accepted trials are reported
separately, together with the wrongly-accepted rate (accepted with |err| > 30 cm).

    python -m echolab.stats fit-threshold trials.csv
"""
from __future__ import annotations

import argparse
import math
from dataclasses import dataclass

import numpy as np

WRONG_M = 0.30


@dataclass
class Summary:
    n: int
    accepted: int
    coverage: float
    median_abs: float | None
    p90_abs: float | None
    mean_signed: float | None
    sd_signed: float | None
    wrongly_accepted: float | None  # share of accepted trials with |err| > 0.30 m

    def row(self) -> list[str]:
        f = lambda v, d=3: "" if v is None else f"{v:.{d}f}"
        return [str(self.n), str(self.accepted), f(self.coverage, 2), f(self.median_abs),
                f(self.p90_abs), f(self.mean_signed), f(self.sd_signed),
                f(self.wrongly_accepted, 2)]


SUMMARY_HEADER = ["n", "accepted", "coverage", "median|err|", "p90|err|", "mean err",
                  "sd err", "wrong-accept"]


def percentile(x: np.ndarray, q: float) -> float:
    """Linear-interpolated percentile (numpy default); matches EchoCore.Stats."""
    return float(np.percentile(x, q))


def _ground_truth(trials: list[dict]) -> list[dict]:
    return [t for t in trials if t.get("actual_distance_m") is not None]


def summarize(trials: list[dict], threshold: float | None = None) -> Summary:
    """If `threshold` is given, acceptance is re-decided as confidence >= threshold
    (trials must carry an estimate); otherwise the recorded `suppressed` flag is used."""
    trials = _ground_truth(trials)
    n = len(trials)
    if threshold is None:
        acc = [t for t in trials if not t["suppressed"] and t["estimated_distance_m"] is not None]
    else:
        acc = [t for t in trials if t["estimated_distance_m"] is not None
               and t["confidence"] is not None and t["confidence"] >= threshold]
    if not acc:
        return Summary(n, 0, 0.0 if n else math.nan, None, None, None, None, None)
    err = np.array([t["estimated_distance_m"] - t["actual_distance_m"] for t in acc])
    a = np.abs(err)
    return Summary(n, len(acc), len(acc) / n if n else math.nan, float(np.median(a)),
                   percentile(a, 90), float(np.mean(err)),
                   float(np.std(err, ddof=1)) if len(err) > 1 else 0.0,
                   float(np.mean(a > WRONG_M)))


def group_by(trials: list[dict], key: str) -> dict:
    out: dict = {}
    for t in trials:
        out.setdefault(t.get(key), []).append(t)
    return dict(sorted(out.items(), key=lambda kv: (kv[0] is None, kv[0])))


def per_distance(trials: list[dict], threshold: float | None = None) -> dict[float, Summary]:
    return {d: summarize(ts, threshold)
            for d, ts in group_by(_ground_truth(trials), "actual_distance_m").items()}


@dataclass
class ThresholdFit:
    threshold: float | None
    coverage: float | None
    p90_abs: float | None
    wrongly_accepted: float | None


def fit_threshold(trials: list[dict], p90_max: float = 0.30,
                  wrong_max: float = 0.05) -> ThresholdFit:
    """Lowest threshold t such that, on trials with confidence >= t, p90 |err| <= p90_max
    and the wrongly-accepted rate <= wrong_max. Record H2 with the app's "accept all"
    experiment setting so sub-threshold estimates exist."""
    gt = [t for t in _ground_truth(trials)
          if t["estimated_distance_m"] is not None and t["confidence"] is not None]
    cands = sorted({round(t["confidence"], 4) for t in gt})
    for th in cands:
        s = summarize(trials, th)
        if s.accepted >= 5 and s.p90_abs is not None and s.p90_abs <= p90_max \
                and s.wrongly_accepted <= wrong_max:
            return ThresholdFit(th, s.coverage, s.p90_abs, s.wrongly_accepted)
    return ThresholdFit(None, None, None, None)


def format_table(header: list[str], rows: list[list[str]]) -> str:
    widths = [max(len(str(x)) for x in col) for col in zip(header, *rows)]
    line = lambda r: "| " + " | ".join(str(c).rjust(w) for c, w in zip(r, widths)) + " |"
    sep = "|" + "|".join("-" * (w + 2) for w in widths) + "|"
    return "\n".join([line(header), sep] + [line(r) for r in rows])


def main(argv: list[str] | None = None) -> None:
    from .io import read_trials

    ap = argparse.ArgumentParser(prog="echolab.stats")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fit-threshold")
    f.add_argument("csv")
    f.add_argument("--p90-max", type=float, default=0.30)
    f.add_argument("--wrong-max", type=float, default=0.05)
    a = ap.parse_args(argv)
    trials = read_trials(a.csv)
    fit = fit_threshold(trials, a.p90_max, a.wrong_max)
    if fit.threshold is None:
        print("No threshold meets the targets. Do not raise accuracy claims.")
    else:
        print(f"threshold={fit.threshold:.4f} coverage={fit.coverage:.2f} "
              f"p90={fit.p90_abs:.3f} m wrongly_accepted={fit.wrongly_accepted:.3f}")


if __name__ == "__main__":
    main()
