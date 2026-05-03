# Real-Time Threshold Audit Notes

Audit run: `2026-04-30 11:22` local time.

Script:

```matlab
addpath('thesis_pipeline/matlab');
T = evaluate_realtime_thresholds();
```

CSV outputs are generated locally and ignored by Git:

```text
thesis_pipeline/outputs/<timestamp>/threshold_audit.csv
```

## How The Current Thresholds Are Determined

### Motion / MAS Epoch Score

The GUI computes IMU motion energy from the accelerometer and gyroscope channels:

```text
energy = RMS(acceleration after mean removal) + 0.01 * RMS(gyro after mean removal)
```

Two causal windows are evaluated:

```text
fast_onset window = 0.40 s
sustained window  = 2.00 s
```

The first 5 s of the recording are used as a local baseline for each window. The calibrated score is:

```text
calibrated_score = max(0, (energy - baseline_median) / baseline_MAD)
```

The baseline MAD now has a floor:

```text
baseline_MAD >= max(0.25 * baseline_median, 1e-3)
```

This prevents a nearly motionless calibration window from making tiny IMU changes explode into false corrupted epochs.

An absolute motion-energy floor is also used:

```text
absolute_score = max(0, (energy - 0.040) / 0.060)
```

This prevents a recording that starts while already moving from teaching the algorithm that obvious motion is normal. The current motion score uses the larger of the calibrated and absolute scores. If the fast score is already in the motion-risk range, the fast score is preferred so the GUI does not wait for the full 2 s sustained window.

The GUI reports the score source:

```text
fast_calibrated
fast_absolute
sustained_calibrated
sustained_absolute
```

Current class thresholds:

```text
clean       motion_score < 3
motion_risk 3 <= motion_score < 8
corrupted   motion_score >= 8
```

These are robust engineering thresholds:

- `3` is a conventional robust outlier-style boundary;
- `8` is intended to mean a large deviation from the local baseline;
- `0.040` and `0.060` are empirical engineering floors from the current local recordings, not literature values;
- they are not clinical or literature-derived thresholds.

### QRS / R-Peak Detector

The QRS detector uses a Pan-Tompkins-style derivative energy envelope:

```text
initial threshold = median(first 2 s envelope) + 3 * MAD(first 2 s envelope)
adaptive threshold = noise + 0.25 * (signal - noise)
```

Timing and rhythm guardrails:

```text
refractory interval  = 280 ms
hard duplicate limit = 240 ms
tachy review flag    = RR < 300 ms, equivalent to HR > 200 bpm
SQI RR penalty       = RR < 350 ms or RR > 2000 ms
predictive search    = expected RR +/- 180 ms
```

These thresholds are engineering guardrails. The GUI flags suspicious intervals for review; it does not diagnose arrhythmia.

### Beat Quality / SQI

The beat quality score penalizes:

- low local QRS SNR, relative to a target of roughly 24 dB;
- approximate QRS width outside 50-180 ms;
- high motion score.

The engineering SQI penalizes:

- high motion score;
- no recent R peak;
- RR interval outside the broad 350-2000 ms plausibility range.

## Audit Result

After adding the fast/sustained score and absolute motion floor, the latest audit summary is:

```text
overall median clean time:      28.4 %
overall median risk time:       46.1 %
overall median corrupted time:   3.0 %
median motion latency:         400 ms over motion-risk/corrupted epochs
median fast-score use:          78.9 % over motion-risk/corrupted epochs
median absolute-floor use:      99.6 % over motion-risk/corrupted epochs
```

Rest remains mostly clean:

```text
rest recordings median:
clean      95.9 %
risk        3.3 %
corrupted   0.4 %
tachy flags 0.0 % of R detections
irregular   0.0 % of R detections
```

Current April 29 files:

```text
apr29_rest:      clean 80.4 %, risk 16.5 %, corrupted  3.1 %
apr29_walk:      clean 26.3 %, risk 70.7 %, corrupted  3.0 %
apr29_shake:     clean 56.1 %, risk 42.6 %, corrupted  1.3 %
apr29_restshake: clean  7.6 %, risk 12.1 %, corrupted 80.3 %
```

The QRS guardrails are not firing constantly:

```text
overall median tachy review flags:     0.90 % of R detections
overall median irregular review flags: 3.54 % of R detections
overall median predictive detections:  1.46 % of R detections
```

## Is This Good Enough?

For a GUI demonstration, yes, with careful wording:

- the thresholds are good enough to show live ECG feature extraction with motion-aware quality flags;
- the R-peak guardrails are reasonable because the review flags remain low in most recordings;
- the motion score is useful for visible quality gating, especially in the April 29 `resting_shaking` file;
- the previous false-clean `tape_shaking` behaviour is fixed by the absolute floor.

For a final thesis classifier, not yet:

- the absolute floor is empirically tuned from local recordings;
- some motion classes still vary strongly by attachment condition and recording start state;
- the score measures IMU motion, not ECG corruption directly;
- without hand labels, the thresholds cannot be reported as validated classifier thresholds.

## Recommendation

Use the current thresholds as engineering defaults, but describe them as adaptive robust thresholds rather than validated clinical/classifier thresholds.

For stronger thesis evidence, create a small manually labelled validation table:

```text
clean ECG usable
motion present but ECG still usable
motion corrupted / feature values should be down-weighted
```

Then tune `clean/risk/corrupted` thresholds against those labels using sensitivity, specificity, precision, recall, and confusion matrices.
