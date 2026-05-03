# Real-Time ECG Feature Research Notes

These notes define which features can be extracted from the final processed ECG stream, which ones are safe for this thesis, and which ones should remain labelled as approximate engineering outputs.

The current GUI implements features that can be computed causally from the replayed stream. It does not use future samples, so the behaviour is close to what a live embedded or laptop-side system would see.

## Source Base

- Pan and Tompkins, 1985, "A Real-Time QRS Detection Algorithm", IEEE Transactions on Biomedical Engineering, DOI `10.1109/TBME.1985.325532`. Used for the real-time QRS idea: slope, amplitude, width, moving integration, adaptive thresholds.
- Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology, 1996, "Heart rate variability: standards of measurement, physiological interpretation, and clinical use", European Heart Journal / Circulation. Used for RR-derived HRV terminology and the caution that HRV depends on recording length and stationarity.
- AHA/ACCF/HRS ECG standardization statements, 2007/2009. Used for ECG interval/segment terminology. Part III covers intraventricular conduction/QRS interpretation. Part IV covers ST segment, T wave, U wave, and QT interval terminology.
- Clifford, Behar, Li, and Rezek, 2012, "Signal quality indices and data fusion for determining clinical acceptability of electrocardiograms", Physiological Measurement, DOI `10.1088/0967-3334/33/9/1419`. Used for the idea that ECG acceptability should be treated as a segment-level quality classification problem, not assumed from the presence of a waveform.
- Behar, Oster, Li, and Clifford, 2013, "ECG signal quality during arrhythmia and its application to false alarm reduction", IEEE Transactions on Biomedical Engineering, DOI `10.1109/TBME.2013.2240452`. Used for rhythm-aware caution around SQI and false alarms.
- Chen and Chuang, 2017, "A QRS Detection and R Point Recognition Method for Wearable Single-Lead ECG Devices", Sensors, DOI `10.3390/s17091969`. Used as support that low-compute single-lead QRS/R-point detection can run in real time on wearable-class hardware.
- Automatic ECG quality assessment reviews and ambulatory artefact papers. Used for the general claim that ambulatory ECG should be quality-assessed per segment, especially under motion.

## Decision Traceability

- QRS/R-peak extraction: literature-backed, with a simplified implementation for the thesis GUI.
- RR, HR, SDNN, RMSSD, pNN50, SD1, SD2: literature-backed HRV features, but window length limitations are an engineering constraint in the GUI.
- Motion class: empirical/engineering inference from local IMU energy because the project data does not have independent clinical artefact labels.
- SQI: engineering inference inspired by SQI literature, not a trained clinical SQI classifier.
- QRS width, QRS area, slope, ST60: engineering morphology estimates. These are useful for visualisation but are not clinical diagnostic claims in the current single-lead, motion-corrupted dataset.
- Rhythm flags: engineering review flags. They should not be written as arrhythmia diagnosis because this project does not have labelled rhythm ground truth.
- DWT and beat-template reconstruction: engineering feature aids only. They are not output waveform reconstruction and should not be claimed as motion artefact cancellation.

## Feature Tiers

### Tier 1 - Thesis-Safe Real-Time Outputs

These are defensible from a single processed ECG lead if the SQI/motion state is reported with them:

| Feature | Source signal | Live window | Output | Thesis use |
| --- | --- | --- | --- | --- |
| R peak time | processed ECG | sample-by-sample | seconds / sample index | Core timing feature |
| RR interval | R peak history | last two accepted R peaks | ms | Core beat timing |
| Instant heart rate | RR interval | last RR | bpm | Real-time status |
| Recent mean HR | RR history | last few beats / 60 s | bpm | Trend feature |
| Beat count | R peak history | from replay start | count | Sanity check |
| SDNN | RR history | recent 60 s in GUI | ms | Short-window HRV estimate |
| RMSSD | RR history | recent 60 s in GUI | ms | Short-window HRV estimate |
| pNN50 | RR history | recent 60 s in GUI | percent | Short-window HRV estimate |
| Poincare SD1 | RR history | recent 60 s in GUI | ms | Nonlinear-style RR variability |
| Poincare SD2 | RR history | recent 60 s in GUI | ms | Nonlinear-style RR variability |
| RR coefficient of variation | RR history | recent 60 s in GUI | percent | Simple variability feature |
| Motion score | IMU | past 2 s | relative score | MAS/quality epoch marker |
| Motion class | IMU | past 2 s | clean / motion_risk / corrupted / no_imu | Quality gating |
| Engineering SQI | ECG + IMU | current beat and motion state | 0-100 | Gating and reporting |
| Detector timing correction | QRS detector state | current accepted R peak | ms | Checks envelope-trigger delay |
| Rhythm flag | RR sequence | current accepted interval | ok / review flag | Engineering review only |
| Feature ECG mode | hidden feature stream | current replay window | mode string | Traceability for DWT/template feature path |

These are the strongest features for the thesis because they match the hardware reality: the system is single-lead, motion is present, and the most robust ECG information is R timing.

### Tier 2 - Useful Engineering Features

These are useful for analysis and real-time visualisation, but they must be labelled approximate:

| Feature | Meaning | Why approximate here |
| --- | --- | --- |
| R amplitude | R peak relative to pre-QRS baseline | Electrode motion and gain path change amplitude |
| QRS width | threshold crossing around R | Single-lead and filter-dependent |
| QRS area | absolute area near QRS | Depends on baseline and filter shape |
| Max QRS slope | steepest local QRS slope | Sensitive to noise and sample rate |
| Local baseline | median pre-QRS level | AD8233/digital high-pass affects it |
| Local noise RMS | pre-QRS residual energy | Not a full clinical noise model |
| ST60 | ECG 60 ms after R relative to baseline | Needs reliable J-point/QRS end for clinical use |
| Beat quality | local QRS SNR + width + motion penalty | Engineering score, not trained classifier |
| Template beat used | clean previous beats | Does not mean the ECG waveform was repaired |

These features are good for demonstrating that the system can produce live measurements, but they should not be used as clinical conclusions.

### Tier 3 - Research-Only / Not Current Thesis Claims

The following are valid ECG feature families in general, but they require better validation than the current dataset provides:

- PR interval and P-wave duration.
- P-wave amplitude and morphology.
- T-wave peak, T-wave end, T-wave alternans.
- QT and QTc.
- ST elevation/depression diagnosis.
- Ventricular hypertrophy criteria.
- Bundle branch block diagnosis.
- Atrial fibrillation diagnosis.
- Ectopic beat classification.
- Ischemia/STEMI diagnosis.
- Full arrhythmia classification.
- ECG-derived respiration.

The main limitation is not MATLAB. The limitation is the evidence chain: single-lead wearable ECG, motion artefact, electrode movement, no manually labelled fiducials, no clinical reference ECG, and no validated arrhythmia labels.

## Real-Time Pipeline Used By The GUI

1. Load one manifest recording.
2. Measure sample rate from `t_us`.
3. Convert ECG ADC counts to mV using the project ADC scale.
4. Replay chunks through causal filtering:
   - 0.5-40 Hz Butterworth bandpass;
   - 50 Hz notch if sample rate allows it.
5. Build a hidden feature-only ECG stream:
   - DWT denoising over a bounded replay buffer when MATLAB's wavelet denoiser is available;
   - fallback to the causal BPF/notch stream if DWT is unavailable.
6. Update QRS detector sample-by-sample using the hidden feature stream.
7. Localise accepted R peaks by searching backward from the causal envelope trigger.
8. Recover likely missed beats by searching near the predicted next RR interval once the confirmation window has passed.
9. Remove hard duplicate detections and flag very fast, long, or irregular RR intervals for review.
10. Compute IMU motion energy over the previous 2 s.
11. Classify the current epoch:
   - `clean`: score below 3;
   - `motion_risk`: score from 3 to 8;
   - `corrupted`: score above 8;
   - `no_imu`: no usable IMU channels.
12. Compute live ECG features from accepted R peaks and the most recent beat.
13. If the current beat is motion-risk/corrupted or low quality, morphology features can be estimated from a median template made from recent clean beats.
14. Save a feature log CSV if requested.

## GUI Feature Columns

The current MATLAB GUI logs:

- `time_s`
- `hr_bpm`
- `rr_ms`
- `sdnn_ms`
- `rmssd_ms`
- `pnn50_pct`
- `sd1_ms`
- `sd2_ms`
- `rr_cv_pct`
- `r_amp_mv`
- `qrs_width_ms`
- `qrs_area_mvms`
- `qrs_slope_mvs`
- `baseline_mv`
- `noise_rms_mv`
- `st60_mv`
- `beat_quality`
- `detector_latency_ms`
- `filter_delay_ms`
- `feature_latency_ms`
- `motion_score`
- `sqi`
- `beat_template_used`
- `feature_signal_mode`
- `r_source`
- `rhythm_flag`
- `motion_label`

## Reporting Rules For The Thesis

- Always report motion class and SQI beside any ECG feature.
- Treat timing columns carefully: `detector_latency_ms` is the delay between the causal envelope trigger and the final localised R peak, while `filter_delay_ms` is an estimated group delay through the causal ECG filters.
- Treat HR/RR features as the primary output.
- Treat HRV values as short-window estimates unless the recording length and stationarity are explicitly shown.
- Treat morphology values as engineering estimates unless manually validated fiducials are available.
- If `beat_template_used` is true, report the morphology row as template-estimated rather than observed morphology.
- Do not show the hidden DWT/template stream as the output ECG unless explicitly labelled as a feature-extraction signal.
- Do not report clinical diagnoses from this GUI.
- Do not call the rhythm flags arrhythmia detection. Use wording such as "tachycardia-range RR interval flagged for review" or "irregular RR review flag".
- Use corrupted epochs to show when the system refuses or down-weights measurements, not as proof that MAS subtraction cleaned the waveform.

## Timing Notes

The GUI stamps motion score at the current replay sample. It must not backfill one score across a full replay chunk because high replay speeds can make the motion plot appear to lead the ECG events artificially.

Timing note from 2026-04-30:

- R-peak detection uses the causal BPF/notch ECG stream, not the DWT feature-only stream.
- The hidden DWT/template path is still allowed for morphology feature stabilisation after timing has already been assigned.
- Motion score uses a 0.40 s fast-onset IMU window and a 2.00 s sustained IMU window.
- An empirical absolute IMU-energy floor prevents recordings that start during movement from calibrating obvious motion as clean.

Two different delays can still be real:

- ECG detection delay: the causal derivative/integration detector fires after the R-wave energy is visible. The GUI localises the displayed R peak by searching backward from the trigger and logs the correction.
- Physical motion-to-ECG delay: electrode movement can appear in the IMU before the ECG baseline or R-detector false positives become obvious. That delay matters for subtraction-style MAS because an adaptive canceller needs the reference to be aligned with the ECG artefact, not merely correlated with the same activity.

## Practical Thesis Framing

The final story can be:

"The system streams ECG and IMU data, applies causal ECG filtering, identifies motion-contaminated epochs from local IMU energy, detects QRS/R peaks in real time, and outputs motion-aware ECG timing, HRV, morphology-proxy, and signal-quality features. IMU waveform subtraction was investigated separately and found to be coherence-limited; therefore, the final defensible IMU role is real-time artefact/quality epoch classification rather than forced ECG reconstruction."
