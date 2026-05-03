# Real-Time ECG/IMU Processing on NXP MIMXRT1166

Firmware, capture tools, and MATLAB analysis for a thesis project on
real-time ECG acquisition, motion-aware feature extraction, and embedded
latency/compute evaluation on the NXP MIMXRT1166.

## Current Thesis Direction

The project is no longer framed as "prove that IMU waveform subtraction
removes ECG motion artefact." The current thesis direction is:

1. acquire timestamped single-lead ECG and multi-site IMU data on the NXP
   board;
2. measure the true sample rate and data quality from recordings;
3. replay ECG filtering and feature extraction causally from the recorded
   stream;
4. quantify why direct IMU-based waveform cancellation is coherence-limited
   on the current hardware/data;
5. use IMU and ECG quality features to classify motion-corrupted epochs;
6. port the defensible real-time feature/classifier path back toward the NXP
   board and benchmark latency, memory, and compute cost.

The strongest final output is therefore a motion-aware ECG feature pipeline:
R peaks, RR intervals, heart rate, short-window HRV estimates, signal-quality
state, IMU motion state, and conservative alarm gating. Alarms should only be
raised when the classifier/quality logic is confident that the epoch is usable.

## What Is Implemented

| Area | Status |
| --- | --- |
| NXP ECG/IMU acquisition firmware | Implemented in `source/` with board support at repo root |
| Python serial monitor/recorder | Implemented in `Python Files/ecg_monitor.py` |
| Offline filter and MAS exploration | Implemented in `MATLAB Files/` |
| Clean thesis replay/feature pipeline | Implemented in `thesis_pipeline/` |
| Epoch feature extraction and classifier training | Implemented in `thesis_pipeline/matlab/` |
| Classifier export to C header | Implemented in `thesis_pipeline/matlab/export_tree_to_c.m` |
| Full on-board feature/classifier benchmark | Planned thesis implementation/validation step |

## Repository Layout

```text
source/
  main_phase1.c              Firmware acquisition loop
  app_config_phase1.h        Hardware and stream constants
  drivers/                   ECG ADC and MPU-6500 drivers
  dsp/                       Small DSP helpers
  timebase/                  Timestamp support

board/, CMSIS/, component/, device/, drivers/, startup/, utilities/, xip/
  MCUXpresso/NXP SDK project support. Keep these paths stable for the IDE.

Python Files/
  ecg_monitor.py             Serial capture, plotting, and recording tool

MATLAB Files/
  phase2_*.m                 Filter evaluation and diagnostics
  phase3_analyzer.m          Current GUI - B1-B7, N1/N3/N5/N6/N8/N9, M1-M6
  phase3_analyzer_history.m  Historical reference - full M1-M31 set, kept
                              for thesis writing and offline evaluation
  phase3_diagnose*.m         Coherence and feasibility diagnostics
  apply_*.m, ecg_metrics.m   Reusable analysis helpers

thesis_pipeline/
  README.md                  Clean pipeline entry points
  config/recording_manifest.csv
  matlab/run_realtime_ecg_feature_gui.m
  matlab/evaluate_realtime_thresholds.m
  matlab/extract_epoch_features.m
  matlab/train_epoch_classifier.m
  matlab/export_tree_to_c.m

docs/
  THESIS_WORKFLOW.md         Current end-to-end thesis workflow

scripts/
  export_source_code.py      Optional source export utility
```

## Firmware

Open the project in MCUXpresso IDE from this repository root.

Important configuration points:

- target board: NXP MIMXRT1166;
- ECG front-end: AD8233 `OUT` and `REFOUT` through LPADC;
- IMUs: three MPU-6500 devices on shared LPSPI1 with separate chip-selects;
- UART: `500000` baud, matching `board/board.h` and
  `Python Files/ecg_monitor.py`;
- ECG corrected stream: `ecg_corr = out_raw - refout_raw`;
- real recording sample rate must be computed from `t_us`, not assumed from
  nominal firmware constants.

The firmware currently supports acquisition evidence. The final thesis port
should add benchmarked on-board feature extraction/classifier modes without
changing the raw acquisition evidence trail.

## Capture

Install the Python monitor dependencies:

```bash
pip install numpy pyqtgraph pyserial PyQt5
```

Run the recorder:

```bash
python "Python Files/ecg_monitor.py"
```

Raw recordings are intentionally not broadly versioned. Keep large recordings
under `Python Files/Recordings/` or `Recordings/`, and add manifest rows for
recordings that should be used by the thesis pipeline.

## MATLAB Thesis Pipeline

From the repository root in MATLAB:

```matlab
addpath('MATLAB Files');
addpath('thesis_pipeline/matlab');
```

Useful entry points:

```matlab
run_realtime_ecg_feature_gui          % replay one recording with live features
evaluate_realtime_thresholds          % audit motion/QRS thresholds across manifest
[X,y,names,info] = extract_epoch_features;
model = train_epoch_classifier;
export_tree_to_c(model);
```

Generated outputs are written under `thesis_pipeline/outputs/` and are ignored
by Git.

## Claim Boundaries

Safe claims for the current repository:

- timestamped ECG and IMU acquisition is implemented;
- sample rate is recording-specific and measured from timestamps;
- causal ECG filtering and real-time feature replay can be demonstrated from
  recordings;
- IMU waveform subtraction was explored and can be reported as
  coherence-limited for this setup;
- IMU and ECG-quality features can support motion-corrupted epoch gating.

Claims that still require implementation or validation:

- the full feature/classifier pipeline runs on the NXP board within a measured
  latency budget;
- classifier performance generalises beyond the current recordings;
- any clinical diagnostic interpretation of morphology, rhythm, ST segment, or
  arrhythmia state.

See `docs/THESIS_WORKFLOW.md` for the current end-to-end plan.
