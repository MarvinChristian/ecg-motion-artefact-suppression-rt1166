# Thesis Pipeline

This folder is the clean MATLAB pipeline for the current thesis direction. It
does not replace the MCUXpresso firmware project or the exploratory MATLAB
analyzers. Treat this folder as the canonical route for ADS1293 data, feature
extraction, epoch labelling, training, evaluation, and firmware export.

## Purpose

The pipeline is designed around defensible evidence:

- the active thesis recordings are listed in
  `config/ads1293_recording_manifest.csv`;
- the active raw data lives under `recordings/ads1293_20260501/`;
- sample rate is measured from `t_us`;
- ECG quality is checked before using ECG-derived features;
- bandpass and notch filters are replayed causally;
- direct IMU waveform cancellation is treated as a feasibility/coherence
  question, not forced into a success claim;
- IMU features are used for motion and quality epoch gating;
- ECG features are reported beside signal-quality and motion state;
- alarms are intended to be confidence-gated, not emitted blindly during
  corrupted epochs.

## MATLAB Setup

Run from the repository root:

```matlab
addpath('MATLAB Files');
addpath('thesis_pipeline/matlab');
```

## Main Entry Points

```matlab
ads1293_feature_label_gui
```

Opens the main GUI for the current ML workflow. From there you can select the
ADS1293 lead, BPF, notch, pseudo-label rule, epoch timing, extract features,
load an existing feature file, and launch the epoch label reviewer.

```matlab
run_ads1293_ml_pipeline
```

Runs the streamlined ML path from the 1 May ADS1293 two-channel recordings. It
uses selectable ECG/IMU simulator-style options for lead, bandpass, notch, and
label algorithm:

```matlab
run_ads1293_ml_pipeline('lead','ch1', 'bpf','B7', 'notch','N9', ...
    'label_algorithm','hybrid', 'train',true)
```

```matlab
run_realtime_ecg_feature_gui
```

Replays one manifest recording as a simulated real-time stream. It displays raw
and processed ECG, IMU motion score, epoch class, and live ECG features.

```matlab
evaluate_realtime_thresholds
```

Runs the threshold audit across all manifest recordings that are available on
the local machine.

```matlab
[X,y,featureNames,epochInfo] = extract_epoch_features( ...
    'lead','ch1', 'bpf','B7', 'notch','N9', ...
    'label_algorithm','kurtosis');
label_epoch_gui('thesis_pipeline/outputs/<timestamp>/epoch_features.mat');
model = train_epoch_classifier('thesis_pipeline/outputs/<timestamp>/revised_labels.mat');
export_tree_to_c(model);
```

Builds epoch-level IMU/ECG-quality features, trains an interpretable decision
tree, compares it with the hard motion threshold, and exports a C header for
the NXP firmware port.

See `TRAINING_PLAN.md` for the full model-training workflow and experiment
matrix.

## Outputs

Generated files are written to:

```text
thesis_pipeline/outputs/<timestamp>/
```

That folder is ignored by Git because the outputs are reproducible products of
the scripts, not source files.

## Safe Thesis Claims From This Folder

- The system can replay recorded ECG/IMU streams with causal filtering.
- The real sample rate is measured from timestamps for each recording.
- The system can output R timing, RR, HR, short-window HRV estimates, SQI, and
  motion class from the recorded stream.
- IMU features are useful for detecting motion-corrupted epochs.
- A decision tree is a transparent classifier candidate that can be exported to
  firmware and benchmarked on the NXP board.

## Claims To Avoid

- Do not claim the current firmware already runs the full feature/classifier
  pipeline until it is ported and benchmarked.
- Do not claim direct IMU-MAS successfully reconstructs clean ECG unless the
  coherence and output metrics support it for the specific dataset.
- Do not report clinical diagnoses from this single-lead, motion-corrupted
  dataset.
- Do not treat short-window HRV values as full clinical HRV assessment.
