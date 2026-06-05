# Evaluation Files By Phase

These are the files needed for project evaluation, diagnostics, and
reporting by phase. Evaluation-only MATLAB/Python files live in this folder.
Shared current training/export files live in `../Final_Pipeline_Files/`.
`apply_biquad.m` and `apply_notch.m` are duplicated here because they are Phase
2 analyzer dependencies as well as final feature-extraction dependencies.

MATLAB setup from the repository root:

```matlab
addpath('Support_Tools/Evaluation_Files_By_Phase/MATLAB');
addpath('Support_Tools/Final_Pipeline_Files/MATLAB');
```

## Phase 1 - ECG + IMU acquisition and recording

Acquire timestamp-matched ADS1293 CH1/CH2 plus three MPU-6500 IMUs and record.

- Host capture: `Python/ecg_monitor.py`.
  It writes new captures to `../Recordings/New_ADS1293_IMU_TS_Recordings/`.
- Firmware, canonical in `source/`: `main_phase1.c`, `app_config_phase1.h`,
  `drivers/ads1293.{c,h}`, `drivers/ecg_adc.{c,h}`,
  `drivers/imu_manager.{c,h}`, `drivers/mpu6500_spi.{c,h}`,
  `timebase/timebase.{c,h}`.
- Curated data: `../Recordings/R01_R10_ADS1293_IMU_TS/`. This contains the
  R01-R10 condition files used by the current MAS/ML evaluation.
- Historical/debug recordings are not included in the public support package.
  Derive sample rate from `t_us`, not nominal constants.

## Phase 2 - Bandpass and notch evaluation

- `MATLAB/phase2_analyzer.m` - main analyzer GUI for BPF/notch/MAS views.
- `MATLAB/apply_biquad.m` - BPF helper.
- `MATLAB/apply_notch.m` - notch helper.
- `MATLAB/ecg_metrics.m` - WBSNR, PRD, RMSE, and Pearson reporting helper.

## Phase 3 - MAS feasibility and diagnostics

- `MATLAB/phase2_analyzer.m` - current MAS selector and visual comparison.
- `MATLAB/signal_diagnose_gui.m` - coherence and QRS-blanking diagnostics.
- `MATLAB/ecg_imu_scroll_gui.m` - ECG/IMU scroll inspection.
- `Python/ecg_imu_freq_gui.py` - frequency-domain ECG/IMU inspection. Its file
  picker opens the curated R01-R10 recording folder by default.
- `MATLAB/apply_biquad.m`
- `MATLAB/apply_notch.m`

The previous `mas_coherence_audit.py` script is no longer part of the active
support tree.

## Phase 3b - ML epoch/candidate classifier evaluation

Shared current pipeline files:

- `../Final_Pipeline_Files/MATLAB/extract_mas_epoch_features.m`
- `../Final_Pipeline_Files/MATLAB/label_mas_epoch_gui.m`
- `../Final_Pipeline_Files/MATLAB/train_mas_decoupled.m`
- `../Final_Pipeline_Files/MATLAB/train_mas_epoch_models.m`
- `../Final_Pipeline_Files/MATLAB/write_mas_training_artifacts.m`
- `../Final_Pipeline_Files/MATLAB/export_bag_to_c.m`
- `../Final_Pipeline_Files/MATLAB/compare_mas_model_suite.m`
- `../Final_Pipeline_Files/MATLAB/retrain_and_compare.m`

Evaluation/workflow files in this folder:

- `MATLAB/ads1293_mas_ml_gui.m` - GUI front door for extraction/labelling/training.
- `MATLAB/launch_label_gui.m` - path-safe helper for opening the current labeller.
- `MATLAB/summarize_mas_labels.m` - label-balance check.
- `MATLAB/train_current_mas_data.m` - single-stage comparison trainer.
- `MATLAB/mas_model_stats_gui.m` - ROC/AUC/confusion/feature-importance GUI.
- `MATLAB/mas_selected_model_export_gui.m` - selected-model export/review GUI.

Compact published model outputs are kept under
`../Final_Pipeline_Files/MATLAB/outputs/final/`.

## Phase 4 - Embedded real-time pipeline

- Firmware, canonical in `source/`: `phase4_realtime.h`,
  `phase4_m4_classifier.c`, `phase4_m4_ipc.h`,
  `mas_usability_classifier.h`, `mas_selection_classifier.h`.
- Reference per-channel headers: `mas_bag_classifier_ch1.h` and
  `mas_bag_classifier_ch2.h` only for `PHASE4_TWO_STAGE_DECISION 0`.
- Host monitor: `../Final_Pipeline_Files/Python/ecg_phase4_monitor_gui.py`.
  It writes monitor captures to `../Recordings/Phase4_Monitor_Recordings/`.
- Build/flash: `scripts/build_cm4_classifier.ps1`,
  `scripts/flash_phase4_dual.ps1`, `makefile`, `makefile.targets`.

## Files Judged Not Needed Here

- top-level historical MATLAB/Python working folders: excluded from this public snapshot.
- `cmsis2matlab.m`: previous coefficient documentation helper, not current Phase 4.
- `ecg_ra_ll_sanity_gui.py`, `ecg_seminar_overlay.py`, and
  `imu_playback_gui.py`: debug/demo tools, not required for the current evaluation workflow.

Status: the current RUSBoost usability/selection headers and CM4/CM7 project
builds are source/build validated. The current two-stage RUSBoost Phase 4 path
still needs a flashed live run and hand-labelled Phase 4 validation.
