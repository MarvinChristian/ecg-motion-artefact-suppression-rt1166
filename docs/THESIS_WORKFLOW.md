# Current Thesis Workflow

This document is the working direction for the repository after the thesis
pivot toward embedded real-time biosignal processing on the NXP MIMXRT1166.

## One-Sentence Thesis

The thesis develops and evaluates an NXP-based ECG/IMU system that acquires
timestamped biosignals, extracts motion-aware ECG features in real time, gates
alarms using signal-quality classification, and quantifies the latency, memory,
and compute cost of pushing the embedded board toward the practical limit.

## Current Technical Position

The repository already contains three useful layers:

1. Acquisition firmware in `source/` plus NXP SDK support files at the project
   root.
2. Exploratory MATLAB analysis in `MATLAB Files/`, including filter evaluation
   and IMU-MAS feasibility diagnostics.
3. A clean thesis-facing MATLAB package in `thesis_pipeline/`, including live
   replay, feature extraction, threshold audits, classifier training, and
   classifier export.

The repository should keep all three layers. The first layer proves the data
source, the second layer preserves the investigation trail, and the third layer
is the reproducible thesis pipeline.

## Stage 1 - Freeze The Acquisition Evidence

Goal: preserve what the board already proves.

Keep:

```text
source/main_phase1.c
source/app_config_phase1.h
source/drivers/ecg_adc.c
source/drivers/ecg_adc.h
source/drivers/imu_manager.c
source/drivers/imu_manager.h
source/drivers/mpu6500_spi.c
source/drivers/mpu6500_spi.h
source/timebase/timebase.c
source/timebase/timebase.h
Python Files/ecg_monitor.py
```

Decision traceability:

- empirical: actual sample rate must be measured from `t_us`;
- datasheet/project constraint: LPADC scaling, UART baud, SPI chip-selects,
  and MIMXRT1166 memory/clock assumptions;
- engineering inference: raw acquisition format should stay stable while the
  feature/classifier work is added.

Deliverables:

- confirm current ECG-only and ECG+IMU stream formats;
- record exact firmware mode, baud rate, and board pin assumptions;
- do not change serial columns without updating the Python monitor, MATLAB
  loader, and manifest notes together.

## Stage 2 - Build A Traceable Recording Set

Goal: ensure every analysis result can be traced to a recording and condition.

Use:

```text
thesis_pipeline/config/recording_manifest.csv
```

Rules:

- every recording used in thesis tables gets a manifest row;
- recordings that are historical, malformed, or raw session logs are excluded
  with a reason rather than deleted;
- `Fs` is computed from timestamps in the analysis scripts;
- large raw recordings stay outside Git unless a small example is deliberately
  kept for reproducibility.

Decision traceability:

- empirical: inclusion/exclusion comes from observed file layout, sample rate,
  and signal quality;
- engineering inference: local raw data is not automatically versioned because
  it can be large and recording-specific.

## Stage 3 - Establish ECG Processing Baseline

Goal: show that ECG filtering and feature extraction behave causally before
moving computation onto the board.

Use:

```text
MATLAB Files/apply_biquad.m
MATLAB Files/apply_notch.m
MATLAB Files/ecg_metrics.m
thesis_pipeline/matlab/evaluate_realtime_thresholds.m
thesis_pipeline/matlab/run_realtime_ecg_feature_gui.m
```

Outputs:

- measured sample rate by recording;
- causal BPF/notch behavior;
- R-peak timing, RR, HR, short-window HRV estimates;
- signal-quality and motion-state columns beside every feature output.

Decision traceability:

- literature-backed: QRS/R timing and RR-derived HR/HRV feature families;
- empirical: filter behavior and threshold summaries on the local recordings;
- engineering inference: single-lead morphology outputs remain approximate
  unless independently labelled fiducials are added.

## Stage 4 - Report IMU-MAS As A Feasibility Result

Goal: keep the valuable investigation without overclaiming.

Use:

```text
MATLAB Files/phase3_analyzer.m
MATLAB Files/phase3_mas_ceiling.m
MATLAB Files/phase3_diagnose.m
MATLAB Files/phase3_diagnose_advanced.m
```

Thesis framing:

- direct IMU waveform subtraction was investigated;
- for the present setup, the limiting result is coherence/reference quality,
  not a polished cancellation success;
- that result justifies pivoting IMU use toward motion/quality epoch detection.

Decision traceability:

- empirical: coherence and MAS outputs measured from project recordings;
- literature-backed: motion artefact and signal-quality assessment framing;
- engineering inference: do not force subtraction when the reference signal is
  not sufficiently aligned with ECG artefact.

## Stage 5 - Train And Compare The Epoch Classifier

Goal: earn the classifier contribution without making it a black box.

Use:

```text
thesis_pipeline/matlab/extract_epoch_features.m
thesis_pipeline/matlab/train_epoch_classifier.m
thesis_pipeline/matlab/export_tree_to_c.m
```

Feature groups:

- IMU motion features: accelerometer RMS, gyroscope RMS, jerk, inter-site
  differential motion, slow and fast motion scores;
- ECG quality features: kurtosis/SQI proxy, signal RMS, noise-to-signal ratio;
- optional live ECG outputs: R timing, RR, HR, short-window HRV estimates,
  quality flags, and motion class.

Model choice:

- decision tree first, because it is interpretable and portable to C;
- compare against the hard motion threshold baseline;
- report cross-validation as preliminary unless manual labels or
  subject/recording-separated validation are added.

Decision traceability:

- literature-backed: segment-level ECG quality classification and tree-based
  interpretable classification;
- empirical: thresholds and feature distributions from local recordings;
- engineering inference: alarm gating should require high confidence because
  false alarms during corrupted epochs are worse than withholding a value.

## Stage 6 - Port The Defensible Pipeline To NXP

Goal: make the thesis an embedded systems contribution, not only MATLAB
analysis.

Recommended firmware modes:

```text
M0 raw acquisition only
M1 acquisition + causal ECG filtering
M2 acquisition + filtering + R/RR/HR features
M3 acquisition + filtering + ECG features + IMU motion features
M4 acquisition + full feature set + epoch classifier + confidence-gated alarm
```

Metrics to log per mode:

- real output sample rate;
- per-sample or per-epoch cycle count;
- worst-case processing time;
- sample-to-feature latency;
- RAM and flash use;
- UART payload size and drop/miss behavior;
- classifier inference time;
- alarm decision latency.

Decision traceability:

- empirical: cycle counts, latency, memory, and throughput measured on the
  NXP board;
- datasheet: clock, memory, ADC, SPI, and UART constraints;
- engineering inference: each mode isolates one added compute burden so the
  board limit can be defended experimentally.

## Stage 7 - Thesis Results Package

The final thesis results should be generated, not hand-assembled.

Expected outputs:

```text
sample_rate_summary.csv
raw_quality_summary.csv
filter_summary.csv
mas_feasibility_summary.csv
threshold_audit.csv
epoch_classifier_summary.csv
firmware_benchmark_summary.csv
final_claims_table.csv
```

Expected figures:

```text
raw_rest_example.png
raw_motion_example.png
filter_response_or_filter_comparison.png
mas_coherence_bound.png
motion_epoch_gate_example.png
classifier_vs_threshold.png
firmware_latency_by_mode.png
```

## Final Claim Boundary

Strong final claim:

> The system demonstrates timestamped ECG/IMU acquisition and a defensible
> motion-aware ECG feature pipeline, then evaluates how far that pipeline can
> be pushed onto the NXP MIMXRT1166 while preserving acceptable latency.

Avoid claiming:

- clinical diagnostic accuracy;
- fully validated arrhythmia detection;
- generalised classifier performance beyond the available recordings;
- successful IMU waveform cancellation unless the measured coherence and output
  metrics support that claim.
