# Final Pipeline Files

Minimal current two-stage pipeline, in execution order. MATLAB files live in
`./MATLAB/`, the deployed host monitor lives in `./Python/`, and firmware stays
in the repository `source/` tree because the NXP project depends on that layout.

## 1. Extract and label epochs if rebuilding labels

- `MATLAB/apply_biquad.m`
- `MATLAB/apply_notch.m`
- `MATLAB/extract_mas_epoch_features.m`
- `MATLAB/label_mas_epoch_gui.m`

These create and review the two current candidates per lead/epoch:
BPF+N3 baseline and BPF+N3+lead-matched RA-pair NLMS suppressed.
If `extract_mas_epoch_features` is run without an explicit recording table, it
uses `../Recordings/R01_R10_ADS1293_IMU_TS/ads1293_recording_manifest.csv`.
The extraction preview now defaults to a monitor-like 10 s visible context
around each 1 s epoch. For a Phase-2-analyser-style 30 s relabelling pass, run:

```matlab
addpath('Support_Tools/Final_Pipeline_Files/MATLAB');
[X,y,featureNames,epochInfo,preview] = extract_mas_epoch_features('preview_context_sec', 14.5);
label_mas_epoch_gui('Support_Tools/Final_Pipeline_Files/MATLAB/outputs/<timestamp>/mas_epoch_features.mat');
```

The labeller has a `View` control (`5 s`, `10 s`, `15 s`, `30 s`, `All`) and
rescales the y-axis from the visible interval, so wider previews do not flatten
the epoch being judged. Its decisions are now `fixed`, `suppressed`, `Both OK`,
`Corrupted`, or `Skip`. Use `Both OK` when both traces are monitoring-usable and
there is no clinically meaningful preference; those epochs train the usability
gate as clean but are excluded from the baseline-vs-suppressed selector. The
top-bar `QRS` lamp blinks red when the candidates have different in-epoch QRS
counts, which is a quick cue to slow down and inspect the epoch before choosing.

## 2. Train and export the two-stage classifier

- `MATLAB/train_mas_decoupled.m` - recommended current training entry point.
- `MATLAB/train_mas_epoch_models.m` - pooled trainer used by the decoupled path.
- `MATLAB/write_mas_training_artifacts.m` - report/CSV/header export wrapper.
- `MATLAB/export_bag_to_c.m` - generated C header writer for bagged or RUSBoost tree ensembles.
- `MATLAB/compare_mas_model_suite.m` - compares the sensible offline/embedded model set.
- `MATLAB/retrain_and_compare.m` - review-oriented retraining, feature importance, and ablation helper.

From the repository root in MATLAB:

```matlab
addpath('Support_Tools/Final_Pipeline_Files/MATLAB');
train_mas_decoupled('Support_Tools/Final_Pipeline_Files/MATLAB/outputs/<timestamp>/revised_mas_labels.mat', ...
    'export', true);
```

After relabelling, use the comparison harness before replacing firmware
weights:

```matlab
out = compare_mas_model_suite('Support_Tools/Final_Pipeline_Files/MATLAB/outputs/<timestamp>/revised_mas_labels.mat');
```

To export bagged-tree headers for a conservative firmware comparison:

```matlab
train_mas_decoupled('Support_Tools/Final_Pipeline_Files/MATLAB/outputs/<timestamp>/revised_mas_labels.mat', ...
    'model_kind', 'bag', 'export', true);
```

To export the current RUSBoost firmware model:

```matlab
train_mas_decoupled('Support_Tools/Final_Pipeline_Files/MATLAB/outputs/<timestamp>/revised_mas_labels.mat', ...
    'model_kind', 'rusboost', 'export', true);
```

`retrain_and_compare` remains useful for feature-importance CSVs and
`feature_ablation_usability.csv` comparing full, ECG-only, and IMU-only
usability models.

The committed final evidence snapshot is kept under `MATLAB/outputs/final/`.
Short folder names are intentional so the repository remains usable from deep
Windows paths.

## 3. Generated model headers in `source/`

- `source/mas_usability_classifier.h` - pooled clean/corrupted gate.
- `source/mas_selection_classifier.h` - pooled baseline/suppressed selector.

Both headers use the existing `mas_bag_*` C symbol names for firmware
compatibility. The generated header comment records whether the contents are
bagged trees or RUSBoost. The current source headers are RUSBoost. `lead_id` is
feature `[0]`, so one pooled model serves both channels. Reference per-channel
`mas_bag_classifier_ch1.h` and `mas_bag_classifier_ch2.h` headers remain only
for `PHASE4_TWO_STAGE_DECISION 0`.

## 4. Firmware path in `source/`

Required current firmware files:

- `source/main_phase1.c`
- `source/app_config_phase1.h`
- `source/phase4_realtime.h`
- `source/phase4_m4_classifier.c`
- `source/phase4_m4_ipc.h`
- `source/drivers/ads1293.c`, `source/drivers/ads1293.h`
- `source/drivers/ecg_adc.c`, `source/drivers/ecg_adc.h`
- `source/drivers/imu_manager.c`, `source/drivers/imu_manager.h`
- `source/drivers/mpu6500_spi.c`, `source/drivers/mpu6500_spi.h`
- `source/timebase/timebase.c`, `source/timebase/timebase.h`

The decision policy is: if `P(clean) < 0.5`, mark the epoch unusable; otherwise
use the suppressed candidate when `P(use suppressed) >= 0.5`, else use baseline.
CM7 deterministic safety flags still apply.

## 5. Build and flash

- `scripts/build_cm4_classifier.ps1`
- `scripts/flash_phase4_dual.ps1`
- `makefile`
- `makefile.targets`
- `Debug_CM4/`

## 6. Live monitor

- `Python/ecg_phase4_monitor_gui.py`

The monitor writes captures under `../Recordings/Phase4_Monitor_Recordings/`
when launched from this folder.

## Not In This Folder

- `train_current_mas_data.m` is kept under evaluation because it is useful for
  single-stage comparison runs, not the recommended current two-stage deploy.
- `ads1293_mas_ml_gui.m`, `mas_model_stats_gui.m`, and
  `mas_selected_model_export_gui.m` are evaluation/workflow GUIs, not required
  to reproduce the minimal final training/export path.

## Validation Boundary

The current relabelled-data comparison selected RUSBoost for both tasks:
usability gate 80.1% balanced LORO and selection 93.0% balanced LORO. The CM4
classifier and full CM7 Debug builds compile with the generated headers, and
the Phase 4 source includes DWT timing hooks for the embedded compute budget.
The current two-stage RUSBoost path has not yet been flashed and validated
against hand-labelled live Phase 4 epochs.
