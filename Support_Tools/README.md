# Support Tools

Curated MATLAB/Python tools and recording files that support the firmware
snapshot in the repository root.

This folder is organised by role instead of by language: the final pipeline is
kept separate from evaluation and diagnostic tools so the publication tree stays
easy to audit.

## Layout

| Path | Contents |
|---|---|
| `Final_Pipeline_Files/MATLAB/` | Minimal MATLAB chain for extraction, labelling, training, comparison, and firmware header export. |
| `Final_Pipeline_Files/Python/` | Host monitor for the deployed Phase 4 UART stream. |
| `Evaluation_Files_By_Phase/MATLAB/` | Phase 2, Phase 3, and Phase 3b evaluation/diagnostic MATLAB tools. |
| `Evaluation_Files_By_Phase/Python/` | Phase 1 capture and Phase 3 frequency-domain inspection tools. |
| `Recordings/R01_R10_ADS1293_IMU_TS/` | Curated ADS1293/IMU recording subset used by the MAS/ML evaluation. |

## Current Final Pipeline Files

These files cover the current train -> export -> firmware -> monitor path:

- `Final_Pipeline_Files/MATLAB/apply_biquad.m`
- `Final_Pipeline_Files/MATLAB/apply_notch.m`
- `Final_Pipeline_Files/MATLAB/extract_mas_epoch_features.m`
- `Final_Pipeline_Files/MATLAB/label_mas_epoch_gui.m`
- `Final_Pipeline_Files/MATLAB/train_mas_decoupled.m`
- `Final_Pipeline_Files/MATLAB/train_mas_epoch_models.m`
- `Final_Pipeline_Files/MATLAB/write_mas_training_artifacts.m`
- `Final_Pipeline_Files/MATLAB/export_bag_to_c.m`
- `Final_Pipeline_Files/MATLAB/compare_mas_model_suite.m`
- `Final_Pipeline_Files/MATLAB/retrain_and_compare.m`
- `Final_Pipeline_Files/Python/ecg_phase4_monitor_gui.py`

## Evaluation Files

These files are kept for diagnostics, reporting, or comparison runs outside the
minimal final pipeline:

- `Evaluation_Files_By_Phase/MATLAB/ads1293_mas_ml_gui.m`
- `Evaluation_Files_By_Phase/MATLAB/apply_biquad.m`
- `Evaluation_Files_By_Phase/MATLAB/apply_notch.m`
- `Evaluation_Files_By_Phase/MATLAB/ecg_imu_scroll_gui.m`
- `Evaluation_Files_By_Phase/MATLAB/ecg_metrics.m`
- `Evaluation_Files_By_Phase/MATLAB/launch_label_gui.m`
- `Evaluation_Files_By_Phase/MATLAB/mas_model_stats_gui.m`
- `Evaluation_Files_By_Phase/MATLAB/mas_selected_model_export_gui.m`
- `Evaluation_Files_By_Phase/MATLAB/phase2_analyzer.m`
- `Evaluation_Files_By_Phase/MATLAB/signal_diagnose_gui.m`
- `Evaluation_Files_By_Phase/MATLAB/summarize_mas_labels.m`
- `Evaluation_Files_By_Phase/MATLAB/train_current_mas_data.m`
- `Evaluation_Files_By_Phase/Python/ecg_monitor.py`
- `Evaluation_Files_By_Phase/Python/ecg_imu_freq_gui.py`

`apply_biquad.m` and `apply_notch.m` are intentionally duplicated because they
are dependencies for both the Phase 2 analyser and the final feature extraction
path.

## Recording Set

The curated R01-R10 ADS1293/IMU recordings live in
`Recordings/R01_R10_ADS1293_IMU_TS/`. This folder includes the condition files
and `ads1293_recording_manifest.csv`, not the session-wide raw logs or earlier
debug recordings.

New Phase 1 captures from the support GUI are written to
`Recordings/New_ADS1293_IMU_TS_Recordings/`; Phase 4 monitor captures are
written to `Recordings/Phase4_Monitor_Recordings/`.

## Excluded From This Folder

- top-level MATLAB/Python working folders;
- generated figure/result pipelines;
- report-building files;
- large local feature matrices;
- historical debug/demo utilities that are not needed by the current firmware
  and support-tool workflow.

Firmware is not copied into this folder because the NXP project must keep its
original root-level layout to build correctly.

## Status

The current RUSBoost usability/selection headers and the CM4/CM7 project builds
are source/build validated. The two-stage Phase 4 path should still be checked
against a flashed live run and hand-labelled Phase 4 epochs before being treated
as fully hardware-validated.
