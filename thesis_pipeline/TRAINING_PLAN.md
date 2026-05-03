# ADS1293 Epoch Classifier Training Plan

This is the current ML direction: use the 1 May ADS1293 two-channel ECG plus
three-site IMU recordings to train a lightweight epoch-quality classifier. The
model decides whether a short ECG epoch is clean enough for downstream ECG
features and alarms.

## Canonical Dataset

Use only:

```text
thesis_pipeline/recordings/ads1293_20260501/
thesis_pipeline/config/ads1293_recording_manifest.csv
```

Included conditions:

- resting 3 min
- standing 3 min
- deep breaths 1 min
- arm movement LA 1 min
- arm movement RA 1 min
- shake 1 min
- chest torsion 1 min
- walking 2 min

Do not train from the older scattered `Recordings` folders unless the manifest
is deliberately changed.

## Feature Extraction

Start MATLAB from the repo root:

```matlab
addpath('MATLAB Files');
addpath('thesis_pipeline/matlab');
```

Recommended GUI workflow:

```matlab
ads1293_feature_label_gui
```

Use this to select the ADS1293 lead, BPF, notch, pseudo-label rule, epoch
timing, and thresholds, then press `Extract Features`. When extraction finishes,
the GUI can open the epoch reviewer directly on the generated feature file.

Default extraction:

```matlab
[X,y,names,info] = extract_epoch_features;
```

Selectable algorithm run, matching the ECG/IMU simulator style:

```matlab
[X,y,names,info] = extract_epoch_features( ...
    'lead','ch1', ...
    'bpf','B7', ...
    'notch','N9', ...
    'label_algorithm','hybrid');
```

Supported selectors:

- `lead`: `ch1`, `ch2`, `diff12`
- `bpf`: `none`, `B1`, `B2`, `B3`, `B4`, `B5`, `B6`, `B7`
- `notch`: `none`, `N1`, `N3`, `N5`, `N6`, `N8`, `N9`
- `label_algorithm`: `kurtosis`, `motion_score`, `hybrid`

The output is written to:

```text
thesis_pipeline/outputs/<timestamp>/epoch_features.mat
thesis_pipeline/outputs/<timestamp>/epoch_labels.csv
```

## Recommended Training Workflow

1. Open `ads1293_feature_label_gui`.
2. Extract a baseline feature set with `lead=ch1`, `bpf=B7`, `notch=N9`, and
   `label_algorithm=kurtosis`.
3. Let the GUI open the label reviewer, or press `Label Epochs` after loading
   an existing feature file.

4. Correct ambiguous labels. Focus first on high-motion recordings because
   those decide whether the classifier learns real motion rejection or only the
   pseudo-label rule.
5. Save `revised_labels.mat` from the reviewer.
6. Train the first interpretable tree:

   ```matlab
   model = train_epoch_classifier('thesis_pipeline/outputs/<timestamp>/revised_labels.mat', 6, 5);
   ```

7. Compare against the hard motion threshold report printed by the trainer.
8. Export the tree for firmware:

   ```matlab
   export_tree_to_c(model);
   ```

## Experiment Matrix

Run the same workflow for these variants and keep the best cross-validation
result plus the most thesis-defensible behavior:

| Run | Lead | BPF | Notch | Labels | Purpose |
| --- | --- | --- | --- | --- | --- |
| A | ch1 | B7 | N9 | kurtosis plus review | Primary candidate |
| B | ch2 | B7 | N9 | kurtosis plus review | Check whether Lead II is cleaner |
| C | diff12 | B7 | N9 | kurtosis plus review | Test differential channel utility |
| D | ch1 | B1 | N1 | kurtosis plus review | Compare with older firmware-like filtering |
| E | ch1 | B7 | N9 | hybrid plus review | Test motion-aware pseudo-labeling |

## Acceptance Criteria

Use the model only if it beats the hard threshold baseline on at least one of:

- higher corrupted-epoch rejection specificity without destroying clean-epoch
  sensitivity;
- cleaner feature-gating behavior during walking, shake, arm movement, and
  chest torsion;
- simpler exported tree that still performs well enough for firmware.

The thesis claim should be conservative: the decision tree is a transparent
motion/SQI gate for ECG feature reliability, not a diagnostic classifier.

## Next Data Needed

The current dataset is enough for a first model, but the final thesis model
should add more labelled ADS1293 recordings from multiple sessions and repeated
conditions. The minimum useful expansion is three more sessions with the same
conditions and a short deliberate electrode-disturbance segment.
