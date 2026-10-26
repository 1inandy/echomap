"""Experiment CSV (from the app's Experiment mode) -> statistics + competition charts.

    lab/.venv/bin/python lab/report.py trials.csv [--out lab/out/report]

Only real measured numbers belong in the demo (spec §19). This script never invents data.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from echolab.io import read_trials  # noqa: E402
from echolab.stats import (SUMMARY_HEADER, fit_threshold, format_table, group_by,  # noqa: E402
                           per_distance, summarize)


def _section(title: str, groups: dict) -> str:
    rows = [[str(k if k is not None else "—")] + summarize(v).row() for k, v in groups.items()]
    return f"## {title}\n\n" + format_table([title.split(" by ")[-1]] + SUMMARY_HEADER, rows)


def build_report(trials: list[dict], out: Path) -> str:
    out.mkdir(parents=True, exist_ok=True)
    exp = [t for t in trials if t["actual_distance_m"] is not None]
    parts = [f"# EchoMap results\n\nTrials with ground truth: {len(exp)} "
             f"(of {len(trials)} rows)\n"]
    parts.append("## Overall\n\n" + format_table(SUMMARY_HEADER, [summarize(exp).row()]))
    pd = per_distance(exp)
    parts.append("## Per distance\n\n" + format_table(
        ["actual m"] + SUMMARY_HEADER, [[f"{d:.2f}"] + s.row() for d, s in pd.items()]))
    cal = {"calibrated": [t for t in exp if t["calibration_id"]],
           "raw": [t for t in exp if not t["calibration_id"]]}
    parts.append(_section("Accuracy by calibration", cal))
    for key, title in [("environment", "environment"), ("surface_material", "material"),
                       ("hold_orientation", "orientation"), ("mic_source", "mic")]:
        g = group_by(exp, key)
        if len(g) > 1 or None not in g:
            parts.append(_section(f"Accuracy by {title}", g))
    fit = fit_threshold(exp)
    if fit.threshold is None:
        parts.append("## Threshold fit\n\nNo threshold meets p90 ≤ 30 cm and wrongly-accepted "
                     "≤ 5 %. Keep the default thresholds and do not claim accuracy.")
    else:
        parts.append(f"## Threshold fit\n\nthreshold = **{fit.threshold:.3f}** → coverage "
                     f"{fit.coverage:.0%}, p90 |err| {fit.p90_abs:.3f} m, wrongly accepted "
                     f"{fit.wrongly_accepted:.1%}")

    _plot_error_vs_distance(exp, out / "error_vs_distance.png")
    _plot_calibration(cal, out / "raw_vs_calibrated.png")
    _plot_confidence(exp, fit.threshold, out / "confidence_vs_error.png")
    _plot_groups(exp, "environment", out / "by_environment.png")
    _plot_groups(exp, "surface_material", out / "by_material.png")
    text = "\n\n".join(parts) + "\n"
    (out / "summary.md").write_text(text)
    return text


def _accepted(ts):
    return [t for t in ts if not t["suppressed"] and t["estimated_distance_m"] is not None]


def _plot_error_vs_distance(trials, path):
    g = per_distance(trials)
    ds = list(g.keys())
    errs = [[t["estimated_distance_m"] - t["actual_distance_m"]
             for t in _accepted(group_by(trials, "actual_distance_m")[d])] for d in ds]
    fig, ax = plt.subplots(2, 1, figsize=(7, 6), sharex=True,
                           gridspec_kw={"height_ratios": [3, 1]})
    if ds:
        ax[0].boxplot([e if e else [np.nan] for e in errs], positions=range(len(ds)))
    ax[0].axhline(0, color="k", lw=0.8)
    ax[0].axhspan(-0.2, 0.2, color="tab:green", alpha=0.1, label="±20 cm target")
    ax[0].set_ylabel("signed error (m)")
    ax[0].legend(loc="upper left")
    ax[1].bar(range(len(ds)), [g[d].coverage for d in ds], color="tab:blue")
    ax[1].set_ylim(0, 1)
    ax[1].set_ylabel("coverage")
    ax[1].set_xticks(range(len(ds)), [f"{d:.2f}" for d in ds])
    ax[1].set_xlabel("actual distance (m)")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def _plot_calibration(cal, path):
    fig, ax = plt.subplots(figsize=(6, 4))
    data, labels = [], []
    for k, ts in cal.items():
        e = [abs(t["estimated_distance_m"] - t["actual_distance_m"]) for t in _accepted(ts)]
        if e:
            data.append(e)
            labels.append(f"{k} (n={len(e)})")
    if data:
        ax.boxplot(data)
        ax.set_xticks(range(1, len(labels) + 1), labels)
    ax.set_ylabel("|error| (m)")
    ax.set_title("Raw vs calibrated")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def _plot_confidence(trials, threshold, path):
    ts = [t for t in trials if t["estimated_distance_m"] is not None and t["confidence"] is not None]
    fig, ax = plt.subplots(figsize=(6, 4))
    if ts:
        c = [t["confidence"] for t in ts]
        e = [abs(t["estimated_distance_m"] - t["actual_distance_m"]) for t in ts]
        ax.scatter(c, e, s=10, alpha=0.6)
    if threshold is not None:
        ax.axvline(threshold, color="tab:red", label=f"fitted threshold {threshold:.2f}")
        ax.legend()
    ax.axhline(0.30, color="0.5", ls="--", lw=0.8)
    ax.set_xlabel("confidence")
    ax.set_ylabel("|error| (m)")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def _plot_groups(trials, key, path):
    g = {k: summarize(v) for k, v in group_by(trials, key).items()}
    fig, ax = plt.subplots(figsize=(7, 4))
    ks = list(g.keys())
    ax.bar(range(len(ks)), [g[k].median_abs or 0 for k in ks], color="tab:orange")
    ax.set_xticks(range(len(ks)), [str(k) for k in ks], rotation=30, ha="right")
    ax.set_ylabel("median |error| (m)")
    ax.set_title(f"by {key}")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "out" / "report"))
    a = ap.parse_args()
    print(build_report(read_trials(a.csv), Path(a.out)))
    print(f"Charts written to {a.out}")


if __name__ == "__main__":
    main()
