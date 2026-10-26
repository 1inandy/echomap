# EchoMap MVP & Production App Specification

## 1. Product Summary

**Working name:** EchoMap  
**Platform:** iOS, starting with iPhone 15  
**Primary audience:** Blind and low-vision users who want additional short-range spatial awareness indoors  
**Core concept:** Use the phone's speaker and microphone to estimate nearby surfaces and openings through acoustic reflections, then translate those estimates into haptic and/or audio feedback.

EchoMap is not intended to replace a white cane, guide dog, trained mobility techniques, or certified assistive-navigation equipment. It is an experimental situational-awareness tool designed to supplement existing mobility methods.

---

## 2. MVP Goal

Build a local, offline iPhone app that can answer one narrow question reliably:

> **How far away is the nearest large surface directly in front of the phone?**

The MVP should:

1. Emit a short acoustic chirp.
2. Record the response through the microphone.
3. Identify the reflected signal.
4. Estimate distance to a large wall or obstacle.
5. Present that distance through:
   - a large on-screen number,
   - haptic intensity/pattern,
   - optional spoken feedback.
6. Save local test measurements for analysis.
7. Work without an account, cloud service, or external dataset.

The MVP is successful if it can repeatedly estimate the distance to a large flat wall with useful accuracy across several indoor environments.

---

## 3. Production Vision

A production version of EchoMap should evolve from simple distance measurement into a short-range spatial-awareness system.

Possible production capabilities:

- Detect approximate distance to nearby large surfaces.
- Identify probable openings such as doorways or hallway gaps.
- Estimate whether the area ahead is open or constrained.
- Sweep across multiple directions while the user rotates the phone.
- Build a temporary local spatial model of the immediate environment.
- Convert spatial information into intuitive haptic or spatial-audio feedback.
- Offer multiple sensing modes:
  - Forward Scan
  - Doorway Search
  - Room Sweep
  - Quiet Mode
  - Training Mode
- Run entirely on-device when possible.
- Store no audio by default.
- Provide accessibility-first VoiceOver support.

The production app should remain a supplementary awareness tool rather than a primary mobility system.

---

# 4. Product Principles

## 4.1 Safety First

Never represent EchoMap as a guaranteed collision-avoidance system.

The app must clearly communicate:

- Detection may fail.
- Soft materials may absorb sound.
- Glass and irregular geometry may produce misleading echoes.
- Environmental noise can reduce reliability.
- The user should continue using established mobility aids.

Avoid claims such as:

- "See through sound."
- "Replace your cane."
- "Guaranteed obstacle detection."
- "Safe autonomous navigation."

Prefer language such as:

- "Additional spatial awareness."
- "Experimental acoustic sensing."
- "Approximate nearby-surface detection."

## 4.2 Local First

The MVP should operate fully offline.

No user account is required.

No raw microphone recordings should leave the device.

## 4.3 Explainable Measurements

Whenever possible, the app should expose confidence.

Example:

```text
Distance: 1.42 m
Confidence: High
Signal quality: Good
```

The app should prefer:

```text
Unable to estimate reliably
```

over showing a low-confidence measurement as fact.

## 4.4 Accessibility Is the Core UX

All controls must work with:

- VoiceOver
- Dynamic Type
- Reduce Motion
- high-contrast system settings
- haptic-first interaction

The UI should not depend on small visual graphs during normal use.

---

# 5. MVP Scope

## 5.1 Included

### Acoustic Measurement

- Generate one or more test chirps.
- Start with frequencies in the approximate 18-20 kHz range.
- Support audible fallback chirps during development.
- Record microphone input.
- Correlate recorded audio against the transmitted chirp.
- Estimate echo delay.
- Convert delay to approximate distance.

### Calibration

The app should support a simple device calibration flow:

1. User places phone at a known distance from a flat wall.
2. App emits multiple chirps.
3. App estimates:
   - direct-path offset,
   - hardware latency,
   - preferred frequency band,
   - signal threshold.
4. Calibration is stored locally.

### Feedback

Provide three feedback channels.

#### Visual

```text
1.42 m
Surface ahead
Confidence: High
```

#### Haptic

Example mapping:

```text
> 3.0 m    no vibration
2-3 m      slow pulse
1-2 m      medium pulse
0.5-1 m    fast pulse
< 0.5 m    rapid urgent pulse
```

#### Voice

Optional spoken result:

```text
"Surface, one point four meters."
```

### Local Logging

Store:

- timestamp
- transmitted waveform ID
- estimated distance
- confidence
- user-entered ground truth distance, if available
- signal-to-noise estimate
- environment label
- test notes

Do not store raw audio by default.

---

## 5.2 Explicitly Excluded From MVP

Do not attempt these until the basic ranging system works:

- object classification
- stair detection
- person detection
- full floor-plan generation
- continuous navigation
- outdoor use
- cloud AI
- mapping entire buildings
- automatic emergency guidance
- crowd navigation
- computer vision
- multi-user networking

The first milestone is reliable ranging.

---

# 6. Technical Feasibility Model

## 6.1 Basic Distance Equation

For a reflected signal:

```text
distance = speed_of_sound * round_trip_time / 2
```

Approximate speed of sound at room temperature:

```text
343 meters/second
```

Example:

```text
Round-trip delay: 5.83 ms

distance = 343 * 0.00583 / 2
distance ≈ 1.0 m
```

The production implementation should adjust the speed of sound for temperature if environmental data is available.

---

## 6.2 Signal Strategy

Initial options to test:

### Option A: Short Tone Burst

Simple high-frequency burst.

Pros:
- easy to implement
- easy to inspect

Cons:
- reflections may overlap
- weak timing precision

### Option B: Linear Frequency Chirp

Sweep across a narrow frequency range.

Example:

```text
18.0 kHz -> 19.5 kHz
duration: 10-30 ms
```

Pros:
- better correlation properties
- easier to identify in noisy recordings
- likely best MVP direction

### Option C: Coded Sequence

Use a known pseudorandom signal.

Pros:
- strong matched-filter performance
- potentially better rejection of noise

Cons:
- more complex implementation

**Recommended MVP:** Linear chirp + matched filtering/cross-correlation.

---

# 7. Audio Pipeline

## 7.1 High-Level Flow

```text
Generate chirp
    |
Play through speaker
    |
Record microphone simultaneously
    |
Band-pass filter
    |
Cross-correlate with original chirp
    |
Find direct-path peak
    |
Find reflected peaks
    |
Reject implausible peaks
    |
Estimate distance
    |
Compute confidence
    |
Present feedback
```

---

## 7.2 iOS Components

Recommended Apple frameworks:

- `AVFoundation`
- `AVAudioEngine`
- `AVAudioPlayerNode`
- `AVAudioSession`
- `Accelerate`
- `CoreHaptics`
- `CoreMotion`
- `SwiftUI`

Potential later use:

- `Metal`
- `BNNS`
- `CoreML`
- `simd`

---

# 8. Proposed iOS Architecture

Use a modular Swift architecture.

```text
EchoMapApp
|
+-- Presentation
|   +-- ScanView
|   +-- CalibrationView
|   +-- ExperimentView
|   +-- SettingsView
|
+-- AcousticEngine
|   +-- SignalGenerator
|   +-- AudioCapture
|   +-- MatchedFilter
|   +-- PeakDetector
|   +-- DistanceEstimator
|   +-- ConfidenceEstimator
|
+-- SensorEngine
|   +-- MotionTracker
|   +-- OrientationTracker
|
+-- FeedbackEngine
|   +-- HapticFeedback
|   +-- SpeechFeedback
|
+-- Persistence
|   +-- CalibrationStore
|   +-- MeasurementStore
|
+-- Diagnostics
    +-- SpectrogramExporter
    +-- SignalDebugView
    +-- ExperimentExporter
```

---

# 9. Core Data Models

## Measurement

```swift
struct Measurement {
    let id: UUID
    let timestamp: Date
    let estimatedDistanceMeters: Double?
    let confidence: Double
    let signalToNoiseRatio: Double?
    let peakStrength: Double?
    let waveformID: String
    let deviceOrientation: DeviceOrientation
    let groundTruthMeters: Double?
    let environmentLabel: String?
}
```

## CalibrationProfile

```swift
struct CalibrationProfile {
    let deviceModel: String
    let sampleRate: Double
    let preferredStartFrequency: Double
    let preferredEndFrequency: Double
    let latencyOffsetSeconds: Double
    let detectionThreshold: Double
    let createdAt: Date
}
```

---

# 10. Local MVP Screens

## 10.1 Home

```text
+---------------------------+
|         EchoMap           |
|                           |
|   Ready                   |
|                           |
|   [ START SCAN ]          |
|                           |
|   Calibration             |
|   Experiments             |
|   Settings                |
+---------------------------+
```

VoiceOver focus should begin on **Start Scan**.

---

## 10.2 Scan Screen

```text
+---------------------------+
|                           |
|          1.42 m           |
|                           |
|       Surface ahead       |
|                           |
|      Confidence: High     |
|                           |
|         [ Stop ]          |
+---------------------------+
```

During normal use, haptics should communicate distance without requiring the user to look at the screen.

---

## 10.3 Calibration

```text
Calibration

Place the phone 1 meter
from a flat wall.

[ Run Calibration ]

Trial 1/10
Signal quality: Good
```

After calibration:

```text
Calibration complete

Preferred signal:
18.2-19.4 kHz

Baseline offset:
2.1 ms

Reliability:
92%
```

---

## 10.4 Experiment Mode

This is especially important for a competition project.

Allow the developer/user to enter known ground truth:

```text
Actual distance:
[ 1.00 ] meters

[ Measure ]
```

Output:

```text
Actual:       1.00 m
Estimated:    1.07 m
Absolute err: 0.07 m
Percent err:  7.0%
```

Save each trial locally.

---

# 11. Confidence Model

Do not return only a raw distance.

Example confidence score:

```text
confidence =
    correlation_peak_strength
    * signal_to_noise_score
    * peak_separation_score
    * consistency_score
```

Possible categories:

```text
0.85-1.00  High
0.65-0.85  Medium
< 0.65     Low / no result
```

A production app should suppress low-confidence results.

---

# 12. Testing Plan

## Phase 1: Signal Presence

Goal:

Confirm that the iPhone 15 can transmit and record the chosen frequency band.

Tests:

```text
16.0 kHz
17.0 kHz
18.0 kHz
18.5 kHz
19.0 kHz
19.5 kHz
20.0 kHz
```

Measure:

- recorded amplitude
- noise floor
- repeatability
- audible perception

Select the best usable band.

---

## Phase 2: Flat-Wall Ranging

Test distances:

```text
0.5 m
0.75 m
1.0 m
1.5 m
2.0 m
2.5 m
3.0 m
```

At least 20 trials per distance.

Collect:

- mean error
- median error
- standard deviation
- failure rate
- confidence score

Target initial MVP:

```text
Median error <= 20 cm
for large flat surfaces
between 0.5 and 2.5 m.
```

This target may need adjustment based on hardware results.

---

## Phase 3: Environment Robustness

Repeat tests in:

- bedroom
- classroom
- hallway
- carpeted room
- hard-floor room
- room with furniture
- moderately noisy room

Track performance degradation.

---

## Phase 4: Orientation Robustness

Test phone:

- upright
- horizontal
- angled 15 degrees
- angled 30 degrees

Determine whether orientation compensation is needed.

---

# 13. Dataset Strategy

EchoMap should not depend on a large external dataset.

The project creates its own experimental dataset.

Example schema:

```csv
trial_id,
environment,
actual_distance_m,
estimated_distance_m,
absolute_error_m,
frequency_start_hz,
frequency_end_hz,
snr,
confidence,
orientation_deg
```

This dataset can support:

- algorithm tuning
- model validation
- charts for competition presentations
- reproducible experiments

---

# 14. MVP Success Criteria

The MVP is ready for demonstration when:

- The app runs fully on-device.
- It can emit and capture the sensing signal reliably.
- It can detect a large flat surface.
- It returns a plausible distance.
- It suppresses unreliable measurements.
- Haptic feedback changes with distance.
- At least 100 labeled test measurements have been recorded.
- Accuracy statistics are available.
- The demo works consistently in at least three indoor environments.

---

# 15. Production Feature Roadmap

## Phase 1: Reliable Forward Ranging

Deliver:

```text
"Surface approximately 1.3 meters ahead."
```

---

## Phase 2: Continuous Scanning

Run repeated measurements as the phone moves.

Add smoothing:

- moving median
- Kalman filter
- confidence-weighted history

Avoid rapidly fluctuating distance estimates.

---

## Phase 3: Directional Sweep

Use Core Motion to associate measurements with device heading.

Example:

```text
Angle -45°: 0.9 m
Angle -30°: 1.0 m
Angle -15°: 3.8 m
Angle   0°: 4.1 m
Angle +15°: 4.0 m
Angle +30°: 1.2 m
```

This may indicate an opening ahead.

---

## Phase 4: Opening Detection

Detect abrupt changes in measured distance across angles.

Example:

```text
wall wall wall OPEN OPEN wall wall
```

Possible output:

```text
Possible doorway ahead.
Opening centered 10 degrees left.
```

Use conservative language.

---

## Phase 5: Short-Range Spatial Model

Build a temporary polar map.

```text
          far
       .........
    ....       ....
   ..             ..
  .                 .
  .       USER      .
  .        *        .
   ..             ..
    ####       ####
       ########
```

Do not attempt architectural-grade mapping.

---

## Phase 6: Haptic Spatial Language

Develop a consistent tactile vocabulary.

Example:

```text
Distance:
closer = faster pulses

Direction:
left obstacle  = left-side haptic pattern
right obstacle = right-side pattern

Opening:
double pulse

Low confidence:
no spatial claim + warning tone
```

User testing should determine the final patterns.

---

## Phase 7: Optional Sensor Fusion

Possible inputs:

- gyroscope
- accelerometer
- barometer
- camera, only if explicitly enabled
- LiDAR on supported devices
- Bluetooth accessories

The core app should remain functional without LiDAR.

---

# 16. Privacy Design

Default behavior:

- No account.
- No cloud upload.
- No location collection.
- No raw audio retention.
- No analytics by default.
- Measurements stored only on device.

If diagnostic export is enabled:

- user explicitly initiates export,
- raw audio export is clearly labeled,
- files remain under user control.

---

# 17. Safety Design

The app should include an onboarding disclosure:

```text
EchoMap provides experimental spatial information.
It may fail to detect obstacles or openings.

Do not rely on EchoMap as your sole mobility aid.
Continue using your normal mobility techniques
and assistive equipment.
```

Operational safeguards:

- suppress low-confidence readings,
- never report "path clear" with certainty,
- never claim stair/drop-off detection until independently validated,
- avoid continuous speech that masks environmental audio,
- support immediate mute/stop gesture,
- provide clear sensing-active state.

---

# 18. Accessibility Requirements

## VoiceOver

Every control must include:

- concise label
- state
- hint where useful

Example:

```text
"Start scan. Begins acoustic surface detection."
```

## Haptics

Core functionality should be usable without vision.

## Audio Feedback

Speech should be optional.

Environmental sound should remain easy to hear.

## Interaction

Prefer:

- large controls
- minimal menus
- one-handed operation
- predictable gestures

---

# 19. Competition Demo Script

## Demo 1: Controlled Measurement

Place a board at 1 meter.

Show:

```text
Actual distance: 1.00 m
EchoMap: 1.06 m
```

Move it to 2 meters.

```text
Actual distance: 2.00 m
EchoMap: 1.91 m
```

---

## Demo 2: Haptic Awareness

User closes eyes or turns screen away.

Move toward wall.

Haptic pulses increase as the wall gets closer.

Important:

Do not present blindfold testing as equivalent to the lived experience of blindness.

---

## Demo 3: Doorway Sweep

Point toward:

```text
WALL | DOORWAY | WALL
```

Rotate phone.

Show the measured distance increasing through the opening.

---

## Demo 4: Experimental Results

Show actual data:

```text
Rooms tested: 8
Trials: 240
Median error: 14 cm
90th percentile error: 27 cm
Measurement success: 91%
```

Use real measured numbers only.

---

# 20. Competition Narrative

A strong project story:

> Many assistive apps use cameras to identify objects. EchoMap investigates a different approach: whether the speaker and microphone already present in an ordinary smartphone can provide useful short-range spatial awareness through acoustic reflections.

Then:

> Instead of requiring a specialized sensor, external dataset, or cloud AI service, EchoMap performs acoustic ranging locally on the device and converts the results into accessible haptic feedback.

Then demonstrate measured accuracy.

The strongest differentiator is not "AI."

It is:

```text
commodity hardware
+ signal processing
+ accessibility
+ experimentally validated performance
```

---

# 21. Suggested Tech Stack

## iOS

- Swift
- SwiftUI
- AVFoundation
- AVAudioEngine
- Accelerate/vDSP
- CoreHaptics
- CoreMotion
- SwiftData or SQLite

## Signal Processing

Initial implementation:

- band-pass filtering
- cross-correlation
- matched filtering
- peak detection
- median filtering
- signal-to-noise estimation

Later:

- GCC-PHAT
- adaptive filtering
- multipath rejection
- probabilistic tracking
- sensor fusion

---

# 22. Repository Structure

```text
EchoMap/
|
+-- App/
|   +-- EchoMapApp.swift
|
+-- Features/
|   +-- Scan/
|   +-- Calibration/
|   +-- Experiments/
|   +-- Settings/
|
+-- Audio/
|   +-- AudioSessionManager.swift
|   +-- ChirpGenerator.swift
|   +-- AudioRecorder.swift
|   +-- Correlator.swift
|   +-- PeakDetector.swift
|   +-- DistanceEstimator.swift
|
+-- Motion/
|   +-- MotionManager.swift
|
+-- Feedback/
|   +-- HapticManager.swift
|   +-- SpeechManager.swift
|
+-- Models/
|   +-- Measurement.swift
|   +-- CalibrationProfile.swift
|
+-- Persistence/
|   +-- MeasurementStore.swift
|   +-- CalibrationStore.swift
|
+-- Experiments/
|   +-- ExperimentRunner.swift
|   +-- CSVExporter.swift
|
+-- Tests/
    +-- SignalTests/
    +-- DistanceEstimatorTests/
    +-- CalibrationTests/
```

---

# 23. Development Order

Do not start by building the polished UI.

Build in this order:

## Milestone 1

Generate a chirp and play it.

## Milestone 2

Record microphone input at the same time.

## Milestone 3

Plot or export the recording and verify the chirp exists.

## Milestone 4

Implement cross-correlation.

## Milestone 5

Detect direct-path and reflected peaks.

## Milestone 6

Estimate wall distance.

## Milestone 7

Run controlled accuracy experiments.

## Milestone 8

Implement calibration.

## Milestone 9

Add haptic feedback.

## Milestone 10

Build polished accessible UI.

## Milestone 11

Implement directional sweep.

## Milestone 12

Investigate doorway/opening detection.

This order prevents spending weeks building an app around a sensing method that has not yet been validated.

---

# 24. First Local Prototype

The first prototype does not need to be a full iOS app.

A useful first version can:

1. Generate a WAV chirp.
2. Play it from the iPhone.
3. Record the result.
4. Export the recording.
5. Analyze it in Python.
6. Detect the correlation peaks.
7. Estimate distance.

Once the sensing algorithm works offline, port the analysis pipeline into Swift.

This dramatically reduces iteration time.

---

# 25. Production Quality Requirements

Before calling the app production-ready:

- Test multiple supported iPhone models.
- Create device-specific calibration profiles.
- Test different cases and speaker orientations.
- Test noisy and reverberant environments.
- Test soft and hard surfaces.
- Test with VoiceOver users.
- Perform accessibility research with blind and low-vision participants.
- Conduct formal usability testing.
- Add automated signal-processing tests.
- Add telemetry only if opt-in and privacy-preserving.
- Clearly document unsupported environments.
- Complete App Store privacy disclosures.
- Obtain expert accessibility review.

---

# 26. Open Technical Risks

## Risk: Direct Speaker-to-Microphone Leakage

The phone's own speaker may dominate the recording.

Mitigation:

- characterize direct-path timing,
- subtract known response,
- use calibration,
- use matched filtering.

## Risk: Multipath Reflections

Rooms generate many echoes.

Mitigation:

- temporal gating,
- peak scoring,
- repeated measurements,
- confidence suppression.

## Risk: Near-Ultrasonic Hardware Limits

Some devices may poorly reproduce high frequencies.

Mitigation:

- frequency sweep during calibration,
- device-specific profiles,
- audible development mode,
- adaptive waveform selection.

## Risk: User Can Hear the Signal

Some users, especially younger users, may perceive high-frequency tones.

Mitigation:

- test perceptibility,
- reduce amplitude,
- shorten pulses,
- allow configurable bands,
- provide an audible-safe mode.

## Risk: Acoustic Noise

Some environments may mask the signal.

Mitigation:

- matched filtering,
- repeated chirps,
- SNR estimation,
- refuse low-confidence measurements.

---

# 27. Research Questions

Potential questions for the final project report:

1. What near-ultrasonic frequency band provides the best ranging performance on an iPhone 15?
2. How does ranging error change with distance?
3. How does surface material affect accuracy?
4. How much does room reverberation affect measurement reliability?
5. Can multiple angle measurements identify an opening?
6. Does device-specific calibration significantly reduce error?
7. What haptic encoding can users interpret fastest?
8. Can EchoMap provide useful information without masking environmental sound?

These questions turn the project from a simple app into an engineering investigation.

---

# 28. Definition of Done for MVP

EchoMap MVP is complete when all of the following are true:

- [ ] iPhone 15 can emit the chosen chirp.
- [ ] iPhone 15 can record the chirp and reflections.
- [ ] Matched filtering identifies a usable echo.
- [ ] Distance is estimated locally.
- [ ] Confidence is calculated.
- [ ] Measurements below threshold are suppressed.
- [ ] User receives haptic distance feedback.
- [ ] VoiceOver works throughout the app.
- [ ] Calibration is saved locally.
- [ ] Experiment mode records ground truth and error.
- [ ] CSV export works.
- [ ] At least 100 controlled measurements are completed.
- [ ] Results are summarized statistically.
- [ ] Safety messaging is implemented.

---

# 29. Stretch Goals

Only attempt these after the MVP is solid:

- directional opening detection
- room-boundary reconstruction
- multi-microphone processing
- adaptive beamforming
- personalized haptic language
- Apple Watch haptic companion
- Bluetooth earbud spatial-audio output
- temperature compensation
- collaborative research dataset
- on-device learned echo classifier
- object-presence classification
- room-shape estimation

---

# 30. Final Product Positioning

The strongest positioning is:

> **EchoMap is an experimental acoustic spatial-awareness app that explores whether an ordinary smartphone can use sound reflections to provide blind and low-vision users with additional information about nearby indoor space.**

Avoid making the project about having the most features.

The strongest version is one that proves a difficult technical claim with real measurements:

> **A commodity iPhone can estimate nearby spatial geometry using only its existing speaker, microphone, and motion sensors, with measurable accuracy and accessible feedback.**

That is the core product and research thesis.
