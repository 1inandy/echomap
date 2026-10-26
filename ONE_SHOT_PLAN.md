# EchoMap — One-Shot Build Plan (final)

Companion to `echomap_mvp_production_spec.md`. The spec says **what** and **why**; this file
says **exactly what gets built, in what order, with which parameters, and how each step is
checked**. If this file and the spec disagree, this file wins for the MVP.

---

## 0. Review of the MVP spec: what changes and why

The spec is well scoped: ranging first, honest confidence, local-only, accessibility-first.
The changes below fix physics and platform problems that would otherwise surface only
after the app is already built.

| # | Problem in spec | Fix in this plan |
|---|---|---|
| R1 | **"Directly in front" is not physically what an iPhone measures.** Speaker and mics are close to omnidirectional, so the *nearest reflector in any direction* wins: the floor (~1.2–1.4 m at chest height), the ceiling, a table, or the user's own body (~0.3 m behind the phone). This is the biggest risk to the whole thesis. | Phase H0 (§6) tests this **before** the UI is built: an open-space control capture, plus mic data-source and polar-pattern selection (cardioid back/front mic where iOS offers it). Report "nearest surface", not "surface ahead", until H0 shows directionality. |
| R2 | Calibration tries to estimate "hardware latency". Play/record latency on AVAudioEngine shifts between sessions, so a stored latency value goes stale. | **Self-referencing timing:** the direct speaker→mic peak in every recording is t=0. Distance = `c·(τ_echo − τ_direct)/2 + offset`. Latency drops out. Calibration fits only `offset` (plus an optional scale). |
| R3 | No mention of the session mode. The default/`voiceChat` modes turn on AGC, echo cancellation and noise suppression, and **AEC will erase the echo we're measuring.** | `AVAudioSession` category `.playAndRecord`, mode **`.measurement`**, options `[.defaultToSpeaker]`, 48 kHz preferred, 5 ms IO buffer. Check the session config on every route change and interruption. |
| R4 | Speaker leakage plus the body echo hide close range. A 10 ms chirp's direct-path sidelobes cover the first ~0.4 m. | Tukey-windowed chirp (lower sidelobes), **leakage-template subtraction** (captured in calibration), and a hard **blanking zone < 0.40 m**. The supported range is **0.5–2.5 m** (it matches the spec's accuracy target). |
| R5 | The haptic table makes "> 3 m" and "no result" both silent. For a blind user, silence then reads as "clear". This is a safety issue. | "No reliable reading" gets its **own pattern** (soft double-tick every 2 s). Silence happens only when scanning is stopped. Distance bands use hysteresis. |
| R6 | Spoken output plays through the same speaker during capture. | Speech is off by default and on demand (Magic Tap). Speech playback pauses the chirp burst. The band-pass filter takes care of VoiceOver and speech energy (<8 kHz). |
| R7 | The confidence formula multiplies four unnormalised scores against arbitrary 0.85/0.65 cuts. | Each component is normalised to [0,1] and combined by geometric mean. The starting thresholds are heuristic, then **refit from H2 data** (§5.6). |
| R8 | The `Measurement` struct and the CSV schema disagree (no band, mic, orientation in degrees, error, algorithm version). | One unified `TrialRecord` schema (§7) feeds the store, the CSV and the analysis scripts. |
| R9 | "Failure rate" and "measurement success" aren't defined. A system that abstains can look accurate by refusing hard cases. | Report **coverage** (share of trials not suppressed) and **accuracy on accepted trials** separately, plus the *wrongly accepted* rate (accepted with \|err\| > 30 cm). |
| R10 | Demo 3 (doorway sweep) depends on directionality (R1) and on features the MVP excludes. | Demo 3 becomes a **stretch demo**, attempted only if H0 shows usable directionality. |
| R11 | §24 says "record on iPhone and analyse in Python", but iOS has no stock app that plays and records raw audio at the same time without processing. | Build a minimal **Capture Lab** screen first (play burst, record raw, export WAV). It is the first thing on-device. |
| R12 | Swift data storage is undecided (SwiftData vs SQLite). | **Codable + JSON files** in Application Support. It is simple and portable, and it runs on macOS with no simulator. |
| R13 | `~/Downloads/CLAUDE.md` (an unrelated project, "The Workbench") is loaded in this folder because `echomap/` sits under `Downloads/`. | Add `echomap/CLAUDE.md` (step A0) that says the parent file doesn't apply. Better still, move the repo out of `Downloads/`. |

---

## 1. Locked decisions

- **Platform:** iOS 17+, iPhone 15 is the reference device. SwiftUI. No third-party runtime dependencies.
- **Signal:** linear chirp + matched filter (spec Option B). The coded sequence (Option C) is out of the MVP.
- **Architecture:** a pure-Swift DSP package `EchoCore` (Accelerate only, no AVFoundation) that
  builds and runs on macOS. A thin iOS app on top of it handles audio I/O, haptics, UI and storage.
- **Reference implementation:** Python `lab/`, using numpy, scipy and matplotlib (all installed).
  Python owns the simulator and the analysis. Swift must match Python on shared golden fixtures.
- **Range claim:** 0.5–2.5 m, large flat surfaces, indoors. Nothing else is claimed.

## 2. Environment facts (checked on this machine, 2026-10-25)

| Tool | Status | Consequence |
|---|---|---|
| Swift 6.3.1 (Command Line Tools) | ✅ builds packages, Accelerate works | `EchoCore` builds, and executable check targets run |
| XCTest / Swift Testing | ❌ not available without Xcode | Use an **executable check target** (`swift run EchoCoreChecks`) until Xcode is installed. Move to Swift Testing afterwards. |
| Xcode | ❌ not installed | **Human prerequisite** for any iOS build or device deploy |
| XcodeGen | ❌ not installed | Needs approval: `brew install xcodegen` (dev tool only, generates the `.xcodeproj` from YAML) |
| Python 3.14, numpy 2.4, scipy 1.17, matplotlib 3.10 | ✅ | Lab works now |
| pytest | ❌ | Needs approval to `pip install pytest`. Otherwise use a plain `python3 -m lab.checks` runner. |

**Human prerequisites before step C:** install Xcode from the App Store, run
`sudo xcode-select -s /Applications/Xcode.app`, sign in with an Apple ID for free device
provisioning, and connect the iPhone 15 in Developer Mode.

---

## 3. Repository layout (target)

```
echomap/
├─ CLAUDE.md                     # project rules (A0)
├─ echomap_mvp_production_spec.md
├─ ONE_SHOT_PLAN.md
├─ lab/                          # Python reference + analysis
│  ├─ echolab/
│  │  ├─ signal.py               # chirp gen (identical params to Swift)
│  │  ├─ simulate.py             # synthetic room: leakage, body, floor, wall, noise, reverb
│  │  ├─ pipeline.py             # bandpass → matched filter → envelope → peaks → distance → confidence
│  │  ├─ stats.py                # coverage, median/p90 error, per-distance tables, threshold fit
│  │  └─ io.py                   # WAV + CSV/JSON trial loading
│  ├─ checks.py                  # assertion runner (or pytest if approved)
│  ├─ make_fixtures.py           # writes golden fixtures for Swift parity
│  ├─ analyze_recordings.py      # real WAVs from Capture Lab → tuned params report
│  └─ report.py                  # CSV export → stats + charts (PNG) for competition
├─ fixtures/                     # *.f32 + *.json golden vectors (generated, committed)
├─ EchoCore/                     # Swift package, platform-agnostic DSP
│  ├─ Package.swift              # platforms: macOS 14, iOS 17
│  ├─ Sources/EchoCore/
│  │  ├─ SignalConfig.swift
│  │  ├─ ChirpGenerator.swift
│  │  ├─ BandPassFilter.swift
│  │  ├─ MatchedFilter.swift     # FFT cross-correlation (vDSP)
│  │  ├─ Envelope.swift          # analytic-signal magnitude
│  │  ├─ DirectPathLocator.swift
│  │  ├─ LeakageTemplate.swift   # capture-averaged template + aligned subtraction
│  │  ├─ PeakDetector.swift      # first-significant-peak + parabolic interp
│  │  ├─ RangeEstimator.swift    # per-burst → median, MAD, valid count
│  │  ├─ ConfidenceModel.swift
│  │  ├─ Calibration.swift       # offset (+ optional scale) fit
│  │  ├─ HapticMapper.swift      # pure distance→pattern with hysteresis
│  │  ├─ TrialRecord.swift       # unified schema + CSV encoder
│  │  └─ Stats.swift
│  └─ Sources/EchoCoreChecks/main.swift   # assertions + fixture parity
└─ App/                          # iOS app (needs Xcode)
   ├─ project.yml                # XcodeGen spec
   ├─ EchoMap/
   │  ├─ EchoMapApp.swift
   │  ├─ Audio/ AudioSessionManager.swift, CaptureEngine.swift, MicRouting.swift
   │  ├─ Scan/ ScanController.swift, ScanView.swift
   │  ├─ Calibration/ CalibrationFlow.swift, CalibrationView.swift
   │  ├─ Experiments/ ExperimentView.swift, SummaryView.swift
   │  ├─ CaptureLab/ CaptureLabView.swift          # dev: raw WAV capture + export
   │  ├─ Feedback/ HapticEngine.swift, SpeechFeedback.swift
   │  ├─ Persistence/ JSONStore.swift, CalibrationStore.swift, TrialStore.swift
   │  ├─ Onboarding/ SafetyDisclosureView.swift
   │  ├─ Settings/ SettingsView.swift
   │  └─ Info.plist              # NSMicrophoneUsageDescription
   └─ EchoMapTests/              # Swift Testing once Xcode exists
```

The spec's `SensorEngine`, `Diagnostics/SpectrogramExporter` and `SignalDebugView` move into
Python, and Core Motion is limited to logging pitch and roll. This keeps the app thin.

---

## 4. Build steps

Each step has a **Done when** line. An agent can check every step except those marked 🧑 (human / on-device).

### A. Foundations (agent, no Xcode needed)

- **A0 · Project rules.** Write `echomap/CLAUDE.md`: say the parent `~/Downloads/CLAUDE.md` does
  not apply. Point to the spec and this plan. Record the hard rules: no raw audio leaves the device;
  never claim "path clear"; low-confidence readings are suppressed; VoiceOver labels on every control.
  `git init`, `.gitignore` (Xcode, `.build`, `__pycache__`, `*.wav` outside `fixtures/`).
  *Done when:* repo initialised, first commit made.

- **A1 · Python reference pipeline.** Implement `signal.py` and `pipeline.py` with the §5 parameters.
  *Done when:* `checks.py` passes. A clean synthetic chirp autocorrelates to a peak at lag 0, and
  a single synthetic reflector at d ∈ {0.5, 1.0, 1.5, 2.0, 2.5} m is recovered within ±2 cm with no noise.

- **A2 · Simulator.** `simulate.py` builds a recording from: leakage (strong, fixed delay `s/c`,
  s ≈ 0.14 m, with a short ringing tail), body echo at 0.30 m behind, floor echo
  (`sqrt(h² + …)`, h configurable), the target wall, exponential diffuse reverb (RT60 0.3–0.8 s
  band-limited), white plus pink noise at a set SNR, a random play/record latency of 5–40 ms,
  and a ±1 sample clock jitter.
  *Done when:* the pipeline on simulated scenes (wall 0.5–2.5 m, SNR ≥ 15 dB, no floor) has a median
  error ≤ 3 cm. With leakage subtraction off, the 0.5 m error is visibly worse (asserted).
  **The floor-echo scene must show that the pipeline reports the floor, not the wall**, when the floor
  is nearer. This documents R1 instead of hiding it.

- **A3 · EchoCore Swift package.** Port the pipeline file for file. vDSP FFT for the
  correlation (zero-pad to the next power of two ≥ 2 × window). FIR band-pass by `vDSP.convolve`.
  Envelope via an FFT Hilbert transform.
  *Done when:* `swift build` is clean and `swift run EchoCoreChecks` passes all assertions.

- **A4 · Golden parity.** `make_fixtures.py` writes 12 simulated scenes (raw `.f32` +
  expected JSON: τ_direct, τ_echo, distance, confidence components). `EchoCoreChecks` loads them.
  *Done when:* Swift matches Python within 1 sample on lags, 5 mm on distance, 0.02 on confidence.

- **A5 · Pure logic modules.** `HapticMapper` (with hysteresis), `ConfidenceModel`, `Calibration`
  fit, `Stats`, `TrialRecord` CSV encoder (RFC 4180 quoting, with a header that matches §7 exactly).
  *Done when:* checks cover band transitions in both directions, the no-result pattern, and a CSV
  round trip (Python `report.py` reads the Swift-written CSV fixture).

### B. Tooling approvals (ask the user)

- **B1** `brew install xcodegen` · **B2** `pip install pytest` (optional; `checks.py` works without it).

### C. iOS app (agent writes it; building needs Xcode 🧑)

- **C1 · Project.** `App/project.yml` (iOS 17, single app target plus a test target, local package
  dependency on `../EchoCore`, Swift 6 toolchain with **Swift 5 language mode on the app target**
  so the real-time audio code doesn't fight strict concurrency). `xcodegen generate`.
  *Done when:* `xcodebuild -scheme EchoMap -destination 'generic/platform=iOS Simulator' build` succeeds.

- **C2 · Audio session & routing.** `AudioSessionManager`: `.playAndRecord` / `.measurement` /
  `[.defaultToSpeaker]`, preferred sample rate 48 000, IO buffer 0.005 s. Assert the actual sample
  rate after activation and refuse to scan if it isn't 48 kHz. `MicRouting` lists the built-in mic
  `dataSources` (bottom / front / back) and their `supportedPolarPatterns`, and applies the user's
  choice (`setPreferredDataSource`, `setPreferredPolarPattern`). Handle interruptions and route
  changes: stop scanning, announce it through VoiceOver, never resume silently.

- **C3 · CaptureEngine.** `AVAudioEngine` with an `AVAudioPlayerNode` playing a pre-rendered burst
  buffer (N chirps at period P), and an input tap on `inputNode` copying into a preallocated
  ring buffer. No allocation, locks or Swift concurrency on the audio thread; hand off with an
  `os_unfair_lock`-guarded swap. Capture window per chirp = P. Timing comes from the direct-path
  peak, so play/record alignment only has to land the chirp somewhere inside the window.

- **C4 · Capture Lab (dev screen, built first on device 🧑).** Configure the band, duration, amplitude,
  N, P, mic source and polar pattern. Record a burst and export a **raw float WAV plus a JSON sidecar**
  (config, device, pitch/roll) via ShareLink. The screen is clearly labelled "Diagnostic — raw audio
  export".
  *Done when (🧑):* the WAV shows the chirp and a wall echo in `lab/analyze_recordings.py`.

- **C5 · Scan.** `ScanController` loops bursts → `EchoCore` → result. `ScanView`: a huge distance
  number (or "No reliable reading"), "Nearest surface", the confidence word, and a Stop button
  filling the bottom half. `UIApplication.isIdleTimerDisabled = true` while scanning.
  Accessibility: Magic Tap (two-finger double-tap) toggles scanning; Escape (Z-scrub) stops;
  the distance label uses `.updatesFrequently`; announcements are rate-limited to one every 3 s,
  and only when the band changes.

- **C6 · Haptics.** `CHHapticEngine` with transient pulses at the §5.7 rates. Restart it on
  `resetHandler` and `stoppedHandler`. Prepare it when scanning starts, not on the first pulse.

- **C7 · Speech.** `AVSpeechSynthesizer`, `usesApplicationAudioSession = true`. Off by default.
  When enabled, it speaks on Magic Tap or on a band change. **While speaking, the next burst waits.**

- **C8 · Calibration flow.** (1) *Leakage:* point the phone at open space, at least 3 m clear, and
  capture 20 chirps → `LeakageTemplate`. (2) *Range:* phone at 1.00 m from a flat wall (optionally
  also 2.00 m) → 10 bursts → fit `offset` (and `scale` if two points). Show the band, offset,
  reliability (share of valid bursts) and residual error. Save a `CalibrationProfile` per device +
  mic source.

- **C9 · Experiment mode.** Enter the ground-truth distance, environment, surface material, hold
  orientation and notes → Measure → show actual / estimated / abs err / % err, or "Suppressed".
  Every trial is saved, **including suppressed ones**. `SummaryView`: per-distance table (n,
  coverage, median, p90) computed with `EchoCore.Stats`. CSV export through ShareLink.

- **C10 · Onboarding, settings, privacy.** A safety disclosure (spec §17 text) is shown on first
  launch and must be acknowledged with an explicit button. It can be reopened from Settings.
  Settings: speech on/off, haptic strength, temperature (default 20 °C, c = 331.3 + 0.606·T),
  mic source, audible dev band toggle (14–17 kHz), raw-audio diagnostics toggle (off by default).
  No network entitlement is used and no analytics run.

- **C11 · Accessibility pass.** Every control has a label, value and hint (spec §18). Dynamic Type up to
  AX5 with no truncation of the distance or the Stop button. Reduce Motion respected (no animated
  number transitions). Increase Contrast respected. VoiceOver focus starts on Start Scan.
  *Done when:* SwiftUI previews at AX5 render. 🧑 A full VoiceOver walkthrough on device.

### D. On-device research protocol 🧑 (the human does this, the scripts analyse it)

See §6. The output feeds back into `SignalConfig` defaults and the confidence thresholds (§5.6),
committed with an `algoVersion` bump.

---

## 5. Algorithm specification (defaults, all in `SignalConfig`)

### 5.1 Signal
- `fs = 48 000 Hz`, mono, Float32.
- Chirp: linear sweep **18.0 → 20.0 kHz**, **10 ms** (480 samples), **Tukey α = 0.5** window,
  amplitude 0.5 FS (configurable). Bandwidth 2 kHz → resolution ≈ c/(2B) ≈ 8.6 cm.
- Burst: **N = 5 chirps, period P = 100 ms** → one estimate about every 0.55 s (≈ 1.8 Hz).
- Dev audible band: 14.0 → 17.0 kHz, same structure.
- The band, duration and P are re-picked from H1 results (§6) before any accuracy claims.

### 5.2 Per-chirp processing
1. Extract the P-length window.
2. Band-pass FIR, 129 taps, Kaiser β = 8, passband `[f0 − 500, f1 + 500]` Hz. Apply the same filter to
   the reference chirp so the group delay cancels.
3. Matched filter: cross-correlate with the filtered reference via FFT → complex/analytic output →
   envelope `|·|`.
4. **Direct path:** global envelope max in the first 60 ms → `τ_d` (parabolic sub-sample).
5. **Leakage subtraction** (if a template exists): align the template by `τ_d` (integer shift +
   sub-sample by linear interpolation), scale by least squares over `τ_d ± 1 ms`, subtract in the
   analytic domain, recompute the envelope.
6. **Search window:** lags for `d ∈ [0.40 m, 3.00 m]` after `τ_d` (blanking zone below 0.40 m).
7. **Noise floor:** median envelope over lags equivalent to 4.0–6.0 m (or over pre-chirp samples if
   that window runs out of P). `σ` = 1.4826 × MAD of the same region.
8. **Echo:** the **first** local max in the search window whose height > `floor + k·σ` (k = 6) and whose
   prominence ≥ 3σ. Parabolic interpolation → `τ_e`. "First", not "largest": we want the nearest surface.
9. `d = scale · c · (τ_e − τ_d)/2 + offset`, `c` from temperature. Defaults `scale = 1`, `offset = s/2`
   (s = speaker–mic separation for the chosen mic, per-device constant, refined by calibration).

### 5.3 Per-burst aggregation
- `valid` = chirps that produced an echo. If `valid < 3` → suppressed.
- `d̂ = median(d_i)`, `MAD_d = median(|d_i − d̂|)`.

### 5.4 Confidence (each component in [0,1])
- `snr = clamp((SNR_dB − 6) / 14)`, where SNR_dB = 20·log10(peak/floor) of the median chirp.
- `consistency = exp(−MAD_d / 0.05 m)`
- `detection = valid / N`
- `prominence = clamp((prom/σ − 3) / 9)`
- `confidence = (snr · consistency · detection · prominence)^(1/4)` (geometric mean, so one bad
  component pulls the score down without zeroing it).

### 5.5 Initial categories (replaced by the fit in 5.6)
- `≥ 0.75` High · `0.50–0.75` Medium · `< 0.50` **suppressed** → "No reliable reading".

### 5.6 Threshold fitting (after H2)
`lab/stats.py fit-threshold`: choose the lowest threshold `t` such that, on accepted trials,
**p90 |err| ≤ 30 cm** and the wrongly-accepted rate ≤ 5%. Report the coverage at `t`. Commit `t`
with an `algoVersion` bump.

### 5.7 Haptic mapping (`HapticMapper`)
| Band | Pattern |
|---|---|
| `< 0.5 m` | rapid urgent pulses, 10 Hz, intensity 1.0, sharpness 0.8 |
| `0.5–1.0 m` | fast pulses, 5 Hz, 0.8 |
| `1.0–2.0 m` | medium pulses, 2.5 Hz, 0.6 |
| `2.0–3.0 m` | slow pulses, 1 Hz, 0.4 |
| `> 3.0 m` | single very soft tick every 3 s ("scanning, nothing near") |
| **No reliable reading** | **soft double-tick every 2 s, sharpness 0.2** (clearly different) |
| Scanning stopped | silence + one long buzz on stop |

Hysteresis: a band change needs the estimate to pass the boundary by **±0.10 m** for **2 consecutive
estimates**. This means "nothing near" is never silent while scanning (fixes R5).

### 5.8 Smoothing (MVP-light)
Median of the last 3 accepted estimates for display and haptics. A suppressed estimate doesn't
enter the history. Two suppressed estimates in a row switch to the no-result pattern straight away.

---

## 6. On-device experiment protocol 🧑

All runs log `TrialRecord`s. Phases H0–H1 use Capture Lab WAVs; H2 onward use Experiment mode.

- **H0 · Geometry & directionality (go/no-go, ~1 h).** For each mic source × polar pattern ×
  hold (A: portrait, top edge toward target; B: screen facing away from user, back toward target):
  (i) 10 bursts with a wall at 1.5 m, (ii) 10 bursts aimed into open space (a long hallway or a
  gym) at the same height. **Decision rule:** pick the configuration with the largest
  wall-echo/floor-echo ratio. If no configuration resolves the wall when the floor is nearer,
  the MVP claim becomes "nearest large surface" and the demo uses a board at chest height in
  open space. Record this honestly in the report.
- **H1 · Band presence.** Tones and chirps at 16, 17, 18, 18.5, 19, 19.5, 20 kHz. For each: recorded
  amplitude, noise floor, repeatability (10×), audibility (ask 3 listeners, including someone under 20).
  → Choose `f0/f1`.
- **H2 · Flat-wall ranging.** 0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0 m × **20 trials** × raw + calibrated
  → ≥ 280 trials (exceeds the ≥ 100 DoD). Use a tape measure from the phone's chosen mic.
- **H3 · Environments.** At least 3 rooms required (DoD) and up to 7 (spec list): 1.0 and 2.0 m × 10 trials each.
- **H4 · Orientation.** Upright, horizontal, 15°, 30° at 1.5 m × 10 trials.
- **H5 · Materials (research Q3).** Drywall, glass, wood, curtain/fabric at 1.5 m × 10 trials.

`lab/report.py` produces: a per-distance table (n, coverage, median, p90, mean, SD, wrongly accepted), an
error-vs-distance plot, a calibrated-vs-raw comparison (research Q6), environment and material
breakdowns, and a confidence-vs-error scatter with the fitted threshold. These are the competition
charts; **only real measured numbers go in the demo** (spec §19).

**Pivot triggers (decide, don't drift):**
- H1 finds no band ≥ 18 kHz with SNR ≥ 15 dB at 1 m → use 16–18 kHz with low amplitude and document the audibility trade-off.
- H2 calibrated median error at 1–2 m > 40 cm, or coverage < 50% → stop building UI and spend the time on the pipeline (Python on the WAVs) until it passes.

---

## 7. Unified `TrialRecord` schema (store = CSV = analysis)

```
trial_id, session_id, timestamp_iso, app_version, algo_version, device_model,
mode (scan|experiment|calibration), environment, surface_material, hold_orientation,
mic_source, polar_pattern, pitch_deg, roll_deg, temperature_c,
freq_start_hz, freq_end_hz, chirp_ms, n_chirps, period_ms,
actual_distance_m, estimated_distance_m, signed_error_m, absolute_error_m, percent_error,
suppressed, confidence, conf_snr, conf_consistency, conf_detection, conf_prominence,
snr_db, valid_chirps, calibration_id, notes
```
Empty cells for unknown or not-applicable values. `estimated_distance_m` is empty when `suppressed = true`.
**No audio in this record, ever.** Raw WAVs exist only through the Capture Lab diagnostics toggle.

`CalibrationProfile`: `id, device_model, mic_source, polar_pattern, sample_rate, f0, f1,
offset_m, scale, detection_k, leakage_template (Float32 blob, base64), reliability, residual_m, created_at`.

---

## 8. Definition of Done (MVP), mapped to the steps

| Spec §28 item | Delivered by | Checked by |
|---|---|---|
| Emit chirp | C3 | 🧑 C4 WAV |
| Record chirp + reflections | C3, C4 | 🧑 `analyze_recordings.py` |
| Matched filter finds a usable echo | A1–A4 | agent: checks + parity; 🧑 H2 |
| Distance estimated locally | A3, C5 | agent + 🧑 |
| Confidence calculated | A5, §5.4 | agent |
| Below-threshold readings suppressed | §5.5/5.6, C5 | agent (mapper checks) + 🧑 |
| Haptic distance feedback | A5, C6 | agent (mapper) + 🧑 feel test |
| VoiceOver throughout | C11 | 🧑 walkthrough |
| Calibration saved locally | C8 | 🧑 |
| Experiment mode with ground truth & error | C9 | 🧑 |
| CSV export | A5, C9 | agent (round trip) + 🧑 share sheet |
| ≥ 100 controlled measurements | H2 | 🧑 (~280 planned) |
| Statistical summary | `report.py`, C9 Summary | agent on sample CSV + 🧑 real data |
| Safety messaging | C10 | 🧑 first-launch check |

Explicitly **not** in the MVP: everything in spec §5.2, directional sweep, opening detection, Kalman
filtering, multiple-model support, Watch/earbuds, and Demo 3 (stretch, gated by H0).

---

## 9. Commit / milestone map

| Branch | Steps | Gate |
|---|---|---|
| `m0-foundation` | A0–A2 | Python checks green |
| `m1-echocore` | A3–A5 | `swift run EchoCoreChecks` green, parity green |
| `m2-capture-lab` | C1–C4 | 🧑 real WAV shows the echo → **H0 + H1 run here** |
| `m3-scan` | C5–C8 | 🧑 calibrated scan reads a 1 m wall within 20 cm |
| `m4-experiments` | C9–C11 | 🧑 **H2–H5**, threshold fit, `report.py` charts |

H0/H1 sit **in the middle** on purpose (spec §23: validate the sensing before polishing the app).
Steps C5–C11 can be written before H0, but their default parameters are only final after H1.

---

## 10. The one-shot prompt

Paste into Claude Code from inside `echomap/`:

> Read `ONE_SHOT_PLAN.md` and `echomap_mvp_production_spec.md`. The plan wins where they differ.
> Do steps **A0–A5** completely, in order, committing after each on the branches in §9. Run every
> "Done when" check yourself and don't move on until it passes. Use only numpy/scipy/matplotlib
> in Python and only Accelerate in Swift. Then ask me about B1/B2. If Xcode is installed
> (`xcodebuild -version` works), continue with **C1–C11** and stop at the first 🧑 gate with a short
> list of exactly what I need to do on the device. If Xcode isn't installed, write C1–C11 anyway,
> say that it's unbuilt, and give me the install steps from §2. Never weaken a check to make it pass;
> if a check fails for a physical reason (e.g. the floor-echo scene), keep it as a documented
> expected-failure and explain it.
