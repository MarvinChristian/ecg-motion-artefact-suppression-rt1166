---
title: ADS1293 MAS Pipeline and Coherence Audit 2026-05-02
type: project
tags: [phase3, mas, ads1293, coherence, analyzer, current, empirical]
sources: ["[[Current Thesis State]]", "[[Current Evidence Baseline]]", "[[MAS Subtraction Feasibility Review 2026-04-30]]", "[[MAS Coherence Failure Analysis]]", "[[Adaptive Filtering Methods]]", "[[IMU Reference Strategies]]", "[[beach-2021]]", "[[yoon-2008]]", "[[sayed-2003]]", "[[ghaleb-2018]]"]
related: ["[[Current Codebase Map]]", "[[Motion Artefact Suppression]]", "[[ECG Quality Metrics]]", "[[Notch Filter Taxonomy]]"]
created: 2026-05-02
last-updated: 2026-05-02
---

# ADS1293 MAS Pipeline and Coherence Audit 2026-05-02

This note records the 2026-05-01/02 update after the analyzer was adapted to the newer ADS1293-style Python recordings and the MAS algorithm set was narrowed to a defensible real-time set.

This note supersedes the older "current analyzer exposes M1-M31" wording for the GUI. The old M1-M31 implementation family still exists internally in `phase3_analyzer.m`, but the GUI-facing thesis set is now compacted to M1-M6.

---

## Short Current Result

The current full pipeline should be framed as:

```text
ADS1293 selected lead
-> BPF, preferably B7 0.75-40 Hz for the current baseline-wander compromise
-> N9 auto-detected interference notch when needed
-> optional coherence-gated MAS
-> otherwise pass through BPF+N9 only
```

The important change is that MAS is no longer treated as an always-on waveform repair stage. It is a conditional stage. It should run only when the selected IMU reference demonstrates plausible coupling to the ECG artefact band.

Decision type:

| Item | Evidence class |
|---|---|
| ADS1293 recordings exist in `Python Files/Recordings` with 21-column rows | Empirical recording/code evidence |
| Analyzer supports ADS1293 CH1/CH2 selection | Code evidence |
| MAS should be gated by coherence/event evidence | Empirical + engineering inference, consistent with adaptive-filter reference requirements |
| M31 is the best final MAS candidate | Engineering inference from current audit and safety logic |
| BPF high-pass 0.75 Hz is a compromise candidate | Engineering inference from observed baseline-wander/T-wave trade-off; not a clinical standard |

---

## Why the Evaluation Method Needed Tightening

The old analyzer metrics are useful for BPF/notch sanity checks, but they are not enough to prove MAS success.

### Metrics that remain useful for filters

| Metric | Useful for | Limitation |
|---|---|---|
| PSD before/after | Shows line noise, broad spectral energy, and filter attenuation. | Does not prove morphology preservation. |
| Filter magnitude/phase/group delay | Confirms BPF/notch design logic. | Does not prove the data-driven output is clinically better. |
| WBSNR-like in-band/out-of-band ratio | Useful for BPF/notch noise rejection. | Motion artefact lives inside the ECG band, so in-band energy is not automatically "signal." |
| PRD/correlation against a reference filter | Useful for comparing one filter output to another controlled baseline. | Not a clean physiological ground truth unless the reference is truly clean and simultaneous. |

### Why those metrics are weak for MAS

MAS is a reference-based subtraction problem. The key question is not "did the output get smaller?" The key question is:

```text
Does the IMU reference predict the ECG artefact waveform without learning ECG morphology?
```

If the IMU reference is weakly related to the artefact, an adaptive filter can still reduce energy by subtracting ECG morphology or overfitting short windows. This can make a trace look smoother while damaging QRS/ST/T morphology.

Therefore MAS evaluation must include:

1. Pre-MAS ECG/IMU coherence in the motion band.
2. QRS-blanked or QRS-protected coherence so the algorithm is not rewarded for correlating with ECG morphology.
3. Shuffled or shifted IMU controls.
4. Event/envelope alignment.
5. QRS-band preservation.
6. Low-motion distortion checks.
7. A gate that disables MAS when reference quality is not plausible.

This matches the adaptive-filter principle recorded in [[Motion Artefact Suppression]], [[IMU Reference Strategies]], and [[Adaptive Filtering Methods]]: the reference must be correlated with the artefact and not with the desired ECG.

No new literature source was ingested for this update. Existing vault literature notes remain the support for the general adaptive-filter/reference-quality logic.

---

## Python ADS1293 Recording Audit

New Python recordings under the current repository path:

```text
Python Files/Recordings/
```

were checked as ADS1293-style recordings, not clinical/reference-bank data.

The key files included:

```text
arm_move_LA_20260501_041820.txt
arm_move_RA_20260501_042004.txt
chest_torsion_1min_20260501_042439.txt
deep_breaths_1min_20260501_041627.txt
resting_3min_20260501_040632.txt
session_raw_20260501_040607.txt
session_raw_20260501_041601.txt
shake_1min_20260501_042257.txt
standing_3min_20260501_041000.txt
walking_2min_20260501_043428.txt
```

### Schema

The current Python recording parser and audit script treat 21-column rows as:

```text
1       t_us
2       ads_ch1
3       ads_ch2
4-21    IMU0, IMU1, IMU2 ax,ay,az,gx,gy,gz
```

Some condition files do not begin with a header row. The analysis therefore infers format from numeric column count rather than requiring `t_us,...` header text.

ADS1293 scale used in the analyzer and audit:

```text
ADS_SCALE_MV = 1400 / 8388607
```

Effective sample rate from timestamps:

```text
Fs ~= 166.67 Hz
```

This is empirical and should be computed per file from `t_us`.

---

## Coherence Audit Script

Repository file added:

```text
Python Files/mas_coherence_audit.py
```

Outputs written:

```text
analysis/mas_coherence_audit.md
analysis/mas_coherence_algorithm_summary.csv
analysis/mas_coherence_recording_summary.csv
```

The audit analyses Python recordings only, not bank/reference files.

### Method Summary

For each recording:

1. Load 21-column ADS1293 + IMU rows.
2. Estimate `Fs` from timestamp spacing.
3. Analyse three ECG lead views:
   - `ch1`,
   - `ch2`,
   - `diff12 = ch1 - ch2`.
4. Convert ADS counts to mV.
5. Convert IMU to physical-ish units:
   - accelerometer counts to g using `16384 LSB/g`,
   - gyroscope counts to deg/s using `131 LSB/(deg/s)`.
6. Create IMU feature banks:
   - accelerometer axes,
   - gyroscope axes,
   - acceleration magnitude,
   - gyro magnitude,
   - velocity-like integrated acceleration,
   - jerk,
   - angular acceleration,
   - differential IMU features,
   - AD8233/OUT-shaped matched variants.
7. Band-shape references into the motion-artefact band.
8. Create a QRS-blanked ECG motion-band signal.
9. Compute magnitude-squared coherence in the motion band.
10. Compute event-envelope correlation and lag.
11. Compare against shuffled-window reference controls.
12. Classify each MAS algorithm/lead row as:
   - plausible,
   - weak,
   - poor.

The audit was limited to a default 60 s window per recording for speed and consistency. It still touches every Python recording file.

### Plausibility Gate

A row is considered plausible only if the IMU reference shows more than a narrow accidental coherence spike. The current script requires:

- high enough peak coherence,
- sufficient mean coherence or enough coherent bins,
- event/envelope alignment,
- and performance above shuffled-window control.

This is an engineering gate, not a clinical validation threshold. It is intentionally conservative because false-positive MAS can damage ECG morphology.

---

## Audit Result

Batch result:

```text
Algorithm/lead rows analysed: 930
Plausible rows: 89
Weak rows: 172
Poor rows: 669
```

### Best Recording/Lead Pairs

| Recording | Lead | Best family | Best feature | Peak gamma^2 | Mean gamma^2 | Peak Hz | Event corr | Shuffle95 | Plausible algos |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| `session_raw_20260501_041601.txt` | CH1 | M17/M23/M24/M31-family | `gy1` | 0.7697 | 0.19024 | 7.8125 | 0.33878 | 0.15111 | 27 |
| `deep_breaths_1min_20260501_041627.txt` | CH1 | feature/coherent-band family | `jx2` | 0.72278 | 0.34476 | 7.48698 | 0.12961 | 0.16411 | 22 |
| `standing_3min_20260501_041000.txt` | diff12 | feature/coherent-band family | `vz2` | 0.56606 | 0.19600 | 5.53385 | 0.15741 | 0.24975 | 21 |
| `standing_3min_20260501_041000.txt` | CH1 | feature/coherent-band family | `vz2` | 0.50281 | 0.13884 | 5.53385 | 0.15990 | 0.13965 | 8 |
| `arm_move_LA_20260501_041820.txt` | CH1 | matched/coherent-band family | `out_vz0` | 0.46427 | 0.09809 | 7.16146 | 0.08615 | 0.09646 | 11 |

### Important Negative Results

Walking produced visually tempting coherence peaks, but the stricter plausibility gate often rejected them.

Examples:

| Recording | Lead | Best peak gamma^2 | Event corr | Plausible algos | Interpretation |
|---|---:|---:|---:|---:|---|
| `walking_2min_20260501_043428.txt` | CH2 | 0.43207 | 0.06150 | 0 | Coherence peak exists but event alignment/gate is too weak. |
| `walking_2min_20260501_043428.txt` | diff12 | 0.37764 | 0.15173 | 0 | Better event alignment, but still failed the full plausibility gate. |
| `shake_1min_20260501_042257.txt` | diff12 | 0.28676 | 0.02224 | 0 | Peak is not enough; event relation is too weak. |

Interpretation:

- Some ADS1293 Python recordings do show real ECG/IMU coherence.
- The coherence is not universal across files or leads.
- CH1 is currently the strongest lead path in the audited data.
- MAS should remain optional and gated.
- A high peak coherence alone is not enough to justify subtraction.

---

## Current Analyzer Update

Repository file updated:

```text
MATLAB Files/phase3_analyzer.m
```

### User-Facing MAS Set

The GUI MAS list was narrowed to a clean chronological thesis set:

| UI ID | Label | Internal implementation | Role |
|---|---|---:|---|
| M1 | LMS baseline `|a|` 3-site | new internal ID 32 | Literature-backed baseline; low compute; sensitive to scaling. |
| M2 | NLMS baseline `|a|` 3-site | old internal M3 | Literature-backed practical embedded baseline; normalises update by reference power. |
| M3 | RLS baseline `|a|` 3-site | old internal M6 | Literature-backed least-squares baseline; faster convergence but heavier and more fragile. |
| M4 | RT coherent-band NLMS | old internal M24 | Best simple real-time candidate; coherence-selects feature/lag/band before subtraction. |
| M5 | RT differential coherent-band | old internal M26 | ADS1293/differential-ECG motivated candidate using IMU0-IMU1 differential references. |
| M6 | Validated adaptive event-band | old internal M31 | Best final candidate; train/validation and event gates reduce overfit and morphology risk. |

The old internal algorithms remain useful for analysis history, but they are no longer the GUI-facing thesis set.

### Why These Six

The six choices are intentionally split into two groups.

#### Literature-backed baselines

| UI ID | Why kept |
|---|---|
| M1 LMS | Foundational adaptive-noise-canceller baseline; simplest possible reference subtraction. |
| M2 NLMS | Embedded-practical baseline because it stabilises the update against changing IMU magnitude. |
| M3 RLS | Standard fast-converging adaptive-filter baseline; useful as a high-compute comparator. |

These are not automatically expected to win. They are included because the thesis needs a fair comparison against known adaptive-filter families.

#### Project-best real-time candidates

| UI ID | Why kept |
|---|---|
| M4 RT coherent-band NLMS | Prevents the filter from adapting on unrelated IMU energy; subtracts only selected coherent bands. |
| M5 RT differential coherent-band | Matches the differential ECG idea: artefact caused by relative electrode motion should be better represented by differential IMU references than by absolute body motion. |
| M6 Validated adaptive event-band | Safest final candidate because it requires validation before subtraction and passes through unchanged when evidence is weak. |

### LMS Baseline Added

A new MATLAB helper was added:

```matlab
mas_lms(d, x_ref, mu, filter_order)
```

It uses a tapped-delay-line LMS update:

```text
e[n] = d[n] - w[n]^T x[n]
w[n+1] = w[n] + mu e[n] x[n]
```

The GUI M1 setting applies LMS to the three-site acceleration-magnitude reference after the same MAS reference conditioning used by the other baseline algorithms.

### Display and Verification

Analyzer checks performed:

```text
checkcode('phase3_analyzer.m','-id') -> ERR: 0
GUI smoke test opened successfully
MAS listbox showed exactly M1-M6 labels
```

---

## Mathematical Logic for Thesis Justification

### Common Adaptive Noise Canceller Model

Measured ECG:

```text
d[n] = s[n] + v[n]
```

where:

- `s[n]` is the desired ECG,
- `v[n]` is motion artefact.

IMU reference:

```text
x[n]
```

should be correlated with `v[n]` and ideally uncorrelated with `s[n]`.

The adaptive filter estimates:

```text
v_hat[n] = w[n]^T x_vec[n]
```

Cleaned output:

```text
e[n] = d[n] - v_hat[n]
```

The core risk is that, if `x[n]` is not genuinely predictive of `v[n]`, the filter may learn ECG morphology or random correlations.

### M1 LMS Baseline

Update:

```text
w[n+1] = w[n] + mu e[n] x_vec[n]
```

Justification:

- lowest compute,
- classic stochastic-gradient adaptive noise cancellation,
- useful lower baseline.

Limitation:

- sensitive to reference amplitude,
- can converge slowly,
- can become unstable or morphology-damaging under poor ECG/IMU coherence.

### M2 NLMS Baseline

Update:

```text
w[n+1] = w[n] + (mu / (epsilon + ||x_vec[n]||^2)) e[n] x_vec[n]
```

Justification:

- same adaptive cancellation idea as LMS,
- update is normalised by reference power,
- more suitable for IMU references because acceleration/gyro magnitudes change across conditions.

Limitation:

- still cannot overcome poor reference coherence,
- can still adapt to ECG morphology without gating/blanking.

### M3 RLS Baseline

Objective:

```text
min_w sum_{k=0}^{n} lambda^{n-k} e[k]^2
```

Justification:

- standard fast-converging adaptive-filter comparator,
- useful high-compute baseline.

Limitation:

- higher memory/compute than LMS/NLMS,
- can be fragile when the reference covariance is ill-conditioned,
- not ideal as the final embedded choice unless it strongly outperforms lighter methods.

### M4 RT Coherent-Band NLMS

Logic:

```text
1. Build IMU feature bank.
2. Apply causal motion-band conditioning to each reference.
3. In a calibration/history window, compute ECG/IMU coherence.
4. Select only feature/lag/frequency-band candidates with plausible coherence.
5. Band-limit the selected reference and primary signal.
6. Run NLMS only on the selected coherent component.
7. Subtract the estimated narrowband artefact.
```

Why it is defensible:

- It directly addresses the measured failure mode: many IMU features are unrelated to the ECG artefact.
- It does not assume that all acceleration magnitude is useful.
- It reduces QRS morphology risk by restricting adaptation to coherent motion bands.

Limitation:

- If coherence is narrow and weak, improvement will also be narrow and weak.
- Selection must be protected by shifted/shuffled controls.

### M5 RT Differential Coherent-Band

Core reference idea:

```text
x_diff[n] = x_IMU0[n] - x_IMU1[n]
```

Logic:

```text
1. Build differential IMU0-IMU1 features.
2. Select coherent feature/lag/band candidates.
3. Run the same coherent-band NLMS subtraction as M4.
```

Why it is defensible:

- ADS/ECG measurement is differential.
- Artefact at the ECG input is often driven by relative electrode motion, not whole-body motion.
- Differential IMU features may better match electrode-vector artefact than absolute acceleration.

Limitation:

- If the artefact comes from cable triboelectric noise, local contact potential, gel deformation, or EMG, differential IMU motion can still miss it.

### M6 Validated Adaptive Event-Band

Logic:

```text
1. Use a past-only rolling history window.
2. Split candidate selection into train and validation portions.
3. Generate candidate IMU feature/lag/band combinations.
4. Require training coherence.
5. Require held-out validation coherence.
6. Require event-envelope correlation.
7. Require motion/distortion burst overlap.
8. Require held-out narrowband reduction.
9. Subtract only the validated narrowband component.
10. If validation fails, output unchanged ECG.
```

Why it is the best final candidate:

- It is real-time-shaped because it uses past windows only.
- It directly rejects M30-style overfit.
- It has a "do no harm" path: no validated reference means no subtraction.
- It is easiest to justify as a final optional MAS stage because it does not claim MAS works when reference evidence is weak.

Limitation:

- It is more complex than M4/M5.
- It may pass through unchanged often.
- Passing through unchanged is not a failure; it is correct behaviour when MAS is not justified.

---

## Updated Full-Pipeline Decision

Current recommended full pipeline:

| Stage | Current choice | Evidence class |
|---|---|---|
| Lead input | ADS1293 CH1 by default, CH2 selectable | Empirical audit suggests CH1 strongest so far; channel choice must remain selectable. |
| Baseline/BPF | B7 0.75-40 Hz candidate | Engineering compromise from observed baseline wander vs T-wave distortion; verify per recording. |
| Notch | N9 auto-detected multi-frequency | Existing analyzer behaviour; retain because user reports it is useful and N10 was removed from current GUI set. |
| MAS | M6 validated adaptive event-band as final candidate; M4/M5 as simpler candidates; M1-M3 as baselines | Code + empirical audit + engineering inference. |
| MAS gate | Run MAS only when coherence/event validation passes | Empirical audit and adaptive-filter reference-quality logic. |
| Fallback | BPF+N9 only | Prevents morphology damage when IMU reference is weak. |

This pipeline should be described as:

> A coherence-gated ECG/IMU processing pipeline, not an unconditional IMU subtraction pipeline.

---

## How This Changes the Earlier MAS Conclusion

The 2026-04-30 conclusion was:

> Current AD8233 recordings do not support reliable broadband IMU waveform subtraction; IMU is better supported for motion/quality gating.

The 2026-05-02 ADS1293 update does not simply reverse this conclusion.

The new, more precise position is:

> ADS1293 Python recordings contain some lead- and condition-specific ECG/IMU coherence that can justify conditional MAS testing. However, coherence is inconsistent across recordings and leads. Therefore MAS should remain in the pipeline only as a gated optional stage. M31/M6 is the safest final candidate because it validates before subtracting.

So the thesis can now say:

- Earlier AD8233 results showed a reference-quality limit.
- New ADS1293 recordings show some better coherence opportunities.
- The correct engineering response is not to run MAS blindly.
- The correct response is to expose a compact literature-backed and real-time-shaped MAS set, then gate MAS by measured reference quality.

---

## Do-Not-Claim List

Do not claim:

- all Python ADS1293 recordings show good coherence;
- walking now has reliable MAS opportunity;
- a high peak coherence alone proves subtractability;
- M6/M31 guarantees visible waveform cleanup;
- B7 0.75 Hz is a universal diagnostic ECG high-pass standard;
- the current firmware already contains the final BPF/notch/MAS pipeline;
- the coherence audit is a clinical validation study.

Safe claims:

- the analyzer now supports ADS1293-style 21-column recordings and selectable CH1/CH2 display/evaluation;
- the Python ADS1293 recordings show meaningful ECG/IMU coherence in some conditions, especially CH1 in selected files;
- the current MAS set has been compacted to six thesis-defensible options: LMS, NLMS, RLS, coherent-band NLMS, differential coherent-band NLMS, and validated adaptive event-band MAS;
- M6 is the most defensible final MAS candidate because it validates before subtracting and otherwise passes the ECG through unchanged;
- MAS should be reported as conditional and coherence-gated, not always-on.

---

## Open Gaps

| Gap | Why it matters |
|---|---|
| Full-duration audit beyond the default 60 s window | Confirms whether coherence persists across longer recordings. |
| Manual visual review of CH1/CH2 ADS1293 traces | Ensures the strongest coherence is not caused by morphology or artefact unrelated to true motion. |
| Run actual M1-M6 outputs on the best ADS1293 files | Coherence is a precondition, not an output-quality result. |
| Add shifted/shuffled controls to analyzer metrics, not only the Python audit | Makes GUI MAS verdicts harder to fool. |
| Firmware port status | MATLAB/Python implementation is not yet embedded Phase 4. |
| Literature ingest for any newly discussed external source | Vault policy requires explicit approval before new source notes are created. |

---

## Change Summary

Repository-side changes represented by this note:

- `phase3_analyzer.m` now presents MAS as M1-M6, not M1-M31.
- `phase3_analyzer.m` has an LMS baseline.
- `phase3_analyzer.m` maps GUI M2/M3/M4/M5/M6 to existing stronger internal implementations where appropriate.
- `mas_coherence_audit.py` scans ADS1293 Python recordings for QRS-blanked coherence, event alignment, and shuffled controls.
- `analysis/` contains CSV and Markdown output from the audit.

Vault interpretation:

- Treat MAS as conditional.
- Use M6 as the safest final candidate.
- Keep M4/M5 as practical real-time alternatives.
- Keep M1-M3 as literature-backed baselines.
