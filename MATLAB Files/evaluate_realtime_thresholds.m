function T = evaluate_realtime_thresholds(bpf_id, notch_id)
% EVALUATE_REALTIME_THRESHOLDS
% Audits the engineering thresholds used by run_realtime_ecg_feature_gui.
%
% Usage:
%   T = evaluate_realtime_thresholds()        % default: B1 + N1
%   T = evaluate_realtime_thresholds(2, 0)    % B2 bandpass, no notch
%   T = evaluate_realtime_thresholds(6, 1)    % B6 + N1 notch
%   T = evaluate_realtime_thresholds(0, 0)    % raw ECG, no filtering
%
% bpf_id:   0  = none (raw)
%           1  = B1 Butterworth 8th  0.5–40 Hz  (default)
%           2  = B2 Butterworth 4th  0.5–40 Hz
%           3  = B3 Butterworth 8th  0.05–150 Hz (hi clamped to Nyquist)
%           4  = B4 Chebyshev II 6th 0.5–40 Hz
%           5  = B5 Elliptic 4th     0.5–40 Hz
%           6  = B6 Butterworth 8th  0.05–40 Hz
%
% notch_id: 0  = none
%           1  = N1 IIR r=0.990 at 50 Hz (default)
%
% Filters are redesigned at each recording's actual Fs (derived from
% timestamps), not at the firmware design Fs of 500 Hz.  B3 hi-cutoff
% is clamped to 0.98*Nyquist when Fs < 310 Hz.
%
% DWT is intentionally excluded.  Standard DWT denoising (wdenoise) is
% non-causal; causal single-level wavelet filters at 166 Hz provide no
% meaningful improvement over the Butterworth BPF already applied.
% DWT in run_realtime_ecg_feature_gui is a non-causal offline feature
% aid only and would overstate firmware performance if included here.
%
% MAS algorithms are not evaluated here.  Use phase3_analyzer.m.

if nargin < 1 || isempty(bpf_id);   bpf_id   = 1; end
if nargin < 2 || isempty(notch_id); notch_id = 1; end

BPF_NAMES   = {'none', 'B1 Butter8 0.5-40Hz', 'B2 Butter4 0.5-40Hz', ...
               'B3 Butter8 0.05-150Hz', 'B4 ChebyII6 0.5-40Hz', ...
               'B5 Elliptic4 0.5-40Hz', 'B6 Butter8 0.05-40Hz'};
NOTCH_NAMES = {'none', 'N1 IIR r=0.990 50Hz'};

bpf_label   = BPF_NAMES{bpf_id + 1};
notch_label = NOTCH_NAMES{notch_id + 1};
fprintf('Filter selection:  BPF=%s   Notch=%s\n', bpf_label, notch_label);

paths    = local_paths();
manifest = readtable(paths.manifest, 'TextType', 'string');
manifest = manifest(manifest.include_main == 1, :);
manifest = manifest(arrayfun(@(p) isfile(fullfile(paths.repo, p)), manifest.relative_path), :);

rows = cell(height(manifest), 1);
for ii = 1:height(manifest)
    row = manifest(ii, :);
    rec = load_eval_recording(fullfile(paths.repo, row.relative_path), row);
    m   = evaluate_motion_thresholds(rec);
    q   = evaluate_qrs_thresholds(rec, bpf_id, notch_id);

    rows{ii} = table(row.recording_id, row.condition, row.cohort, ...
        string(bpf_label), string(notch_label), ...
        rec.Fs, rec.t_s(end), ...
        m.motion_p50, m.motion_p90, m.motion_p95, m.motion_p99, ...
        m.clean_pct, m.risk_pct, m.corrupt_pct, ...
        m.fast_source_pct, m.sustained_source_pct, m.absolute_source_pct, ...
        m.motion_latency_p50_ms, m.motion_latency_p95_ms, ...
        q.r_count, q.median_hr_bpm, q.hr_p05_bpm, q.hr_p95_bpm, ...
        q.tachy_review_pct, q.irregular_review_pct, q.long_rr_pct, ...
        q.predictive_pct, q.detector_latency_p50_ms, q.detector_latency_p95_ms, ...
        'VariableNames', {'recording_id','condition','cohort', ...
        'bpf','notch','Fs_Hz','duration_s', ...
        'motion_p50','motion_p90','motion_p95','motion_p99', ...
        'clean_pct','motion_risk_pct','corrupted_pct', ...
        'motion_fast_source_pct','motion_sustained_source_pct','motion_absolute_source_pct', ...
        'motion_latency_p50_ms','motion_latency_p95_ms', ...
        'r_count','median_hr_bpm','hr_p05_bpm','hr_p95_bpm', ...
        'tachy_review_pct','irregular_review_pct','long_rr_pct', ...
        'predictive_pct','detector_latency_p50_ms','detector_latency_p95_ms'});
end

T = vertcat(rows{:});
outDir = fullfile(paths.subrepo, 'outputs', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
writetable(T, fullfile(outDir, 'threshold_audit.csv'));

fprintf('\nThreshold audit written to:\n%s\n\n', fullfile(outDir, 'threshold_audit.csv'));
print_group_summary(T, bpf_label, notch_label);
end

% ─────────────────────────────────────────────────────────────────────────────
% Path helpers
% ─────────────────────────────────────────────────────────────────────────────

function paths = local_paths()
matlabDir    = fileparts(mfilename('fullpath'));
paths.repo    = fileparts(matlabDir);
paths.subrepo = matlabDir;
paths.manifest = fullfile(paths.subrepo, 'config', 'recording_manifest.csv');
end

% ─────────────────────────────────────────────────────────────────────────────
% Recording loader
% ─────────────────────────────────────────────────────────────────────────────

function rec = load_eval_recording(fpath, manifestRow)
data = read_numeric_recording(fpath);
t_us = double(data(:,1));
t_s  = (t_us - t_us(1)) * 1e-6;
dt   = diff(t_s);
dt   = dt(isfinite(dt) & dt > 0);

rec             = struct();
rec.id          = manifestRow.recording_id;
rec.condition   = manifestRow.condition;
rec.cohort      = manifestRow.cohort;
rec.path        = string(fpath);
rec.t_s         = t_s;
rec.Fs          = 1 / median(dt);
if isempty(dt) || ~isfinite(rec.Fs) || rec.Fs <= 0
    rec.Fs = NaN;
end
rec.ecg_mV       = double(data(:,2)) * (1800 / 4096);
rec.imu          = parse_imu_columns(data);
rec.motionBaseline = estimate_motion_baseline(rec.imu, rec.Fs);
end

function data = read_numeric_recording(fpath)
fid = fopen(fpath, 'r');
if fid < 0
    error('Could not open recording: %s', fpath);
end

headerLines = 0;
while true
    line = fgetl(fid);
    if ~ischar(line)
        fclose(fid);
        error('No numeric rows found in %s', fpath);
    end
    vals = str2double(regexp(strtrim(line), '[,\s]+', 'split'));
    if nnz(isfinite(vals)) >= 2
        break;
    end
    headerLines = headerLines + 1;
end
fclose(fid);

data = readmatrix(fpath, 'FileType', 'text', 'NumHeaderLines', headerLines);
data = double(data);
data = data(all(isfinite(data), 2), :);

for cc = 2:size(data, 2)
    wrapped = data(:,cc) > 2147483647;
    data(wrapped, cc) = data(wrapped, cc) - 4294967296;
end
end

function imu = parse_imu_columns(data)
N         = size(data, 1);
raw       = nan(N, 18);
available = max(0, min(18, size(data,2) - 2));
if available > 0
    raw(:,1:available) = data(:,3:(2+available));
end

imu = struct();
imu.raw     = raw;
imu.acc_g   = nan(N, 9);
imu.gyro_dps = nan(N, 9);
for site = 1:3
    src = (site-1)*6 + (1:6);
    dst = (site-1)*3 + (1:3);
    imu.acc_g(:,dst)   = raw(:,src(1:3)) / 16384;
    imu.gyro_dps(:,dst) = raw(:,src(4:6)) / 131;
end
end

% ─────────────────────────────────────────────────────────────────────────────
% Filter design — redesigned at recording Fs, not firmware Fs=500 Hz
% ─────────────────────────────────────────────────────────────────────────────

function filterState = build_filter_state(bpf_id, notch_id, Fs)
% Returns SOS (for BPF) and [b,a] (for notch) matched to recording Fs.
% Filters are redesigned at Fs, so the frequency response is correct
% regardless of whether the recording is at 166.67 Hz or 500 Hz.
filterState.bpf_id   = bpf_id;
filterState.notch_id = notch_id;
filterState.bpSOS    = design_bpf(bpf_id, Fs);
[filterState.notchB, filterState.notchA] = design_notch(notch_id, Fs);
end

function sos = design_bpf(bpf_id, Fs)
% Returns an SOS matrix for the selected BPF, designed at Fs.
% Returns [] for bpf_id=0 (no filtering).
sos = [];
if bpf_id == 0 || ~isfinite(Fs) || Fs <= 0
    return;
end

Nyq = Fs / 2;

% Clamp passband edges to valid range.
lo_default = 0.5 / Nyq;
hi_default = min(40,  Nyq * 0.95) / Nyq;

switch bpf_id
    case 1  % B1: Butterworth 8th order, 0.5–40 Hz
        lo = lo_default;
        hi = hi_default;
        if lo >= hi; return; end
        [z, p, k] = butter(4, [lo hi], 'bandpass');

    case 2  % B2: Butterworth 4th order, 0.5–40 Hz
        lo = lo_default;
        hi = hi_default;
        if lo >= hi; return; end
        [z, p, k] = butter(2, [lo hi], 'bandpass');

    case 3  % B3: Butterworth 8th order, 0.05–150 Hz (hi clamped to Nyquist)
        lo = max(0.05, 1e-3 * Nyq) / Nyq;
        hi = min(150,  Nyq * 0.95) / Nyq;
        if lo >= hi; return; end
        [z, p, k] = butter(4, [lo hi], 'bandpass');

    case 4  % B4: Chebyshev II 6th order, 0.5–40 Hz, 40 dB stopband
        lo = lo_default;
        hi = hi_default;
        if lo >= hi; return; end
        [z, p, k] = cheby2(3, 40, [lo hi], 'bandpass');

    case 5  % B5: Elliptic 4th order, 0.5–40 Hz, 0.5 dB ripple, 40 dB stopband
        lo = lo_default;
        hi = hi_default;
        if lo >= hi; return; end
        [z, p, k] = ellip(2, 0.5, 40, [lo hi], 'bandpass');

    case 6  % B6: Butterworth 8th order, 0.05–40 Hz (ST-segment preserving)
        lo = max(0.05, 1e-3 * Nyq) / Nyq;
        hi = hi_default;
        if lo >= hi; return; end
        [z, p, k] = butter(4, [lo hi], 'bandpass');

    otherwise
        return;
end

sos = zp2sos(z, p, k);
end

function [nb, na] = design_notch(notch_id, Fs)
% Returns [b,a] notch coefficients for the selected notch, designed at Fs.
nb = 1;
na = 1;
if notch_id == 0 || ~isfinite(Fs) || Fs <= 0
    return;
end

switch notch_id
    case 1  % N1: IIR r=0.990 at 50 Hz — only applicable when Nyquist > 50 Hz
        if Fs > 110
            r  = 0.990;
            w0 = 2*pi*50/Fs;
            nb = [1, -2*cos(w0), 1];
            na = [1, -2*r*cos(w0), r^2];
        end
end
end

% ─────────────────────────────────────────────────────────────────────────────
% Filter application (batch — processes whole signal at once)
% ─────────────────────────────────────────────────────────────────────────────

function y = filter_ecg(ecg, filterState)
% Apply causal BPF + notch to the full ECG vector.
% sosfilt() applies SOS from initial conditions of zero (causal, matches
% firmware behaviour for a recording that starts from rest).
if isempty(filterState.bpSOS)
    ybp = ecg;
else
    ybp = sosfilt(filterState.bpSOS, ecg);
end

if isequal(filterState.notchB, 1) && isequal(filterState.notchA, 1)
    y = ybp;
else
    y = filter(filterState.notchB, filterState.notchA, ybp);
end
end

% ─────────────────────────────────────────────────────────────────────────────
% Motion baseline and threshold evaluation
% ─────────────────────────────────────────────────────────────────────────────

function base = estimate_motion_baseline(imu, Fs)
N = size(imu.raw, 1);
if ~isfinite(Fs) || Fs <= 0
    base.fastWindowSec   = NaN;
    base.slowWindowSec   = NaN;
    base.absQuietEnergy  = NaN;
    base.absScaleEnergy  = NaN;
    base.fast = struct('med', NaN, 'mad', NaN);
    base.slow = struct('med', NaN, 'mad', NaN);
    base.med  = NaN;
    base.mad  = NaN;
    return;
end
calN = min(N, max(16, round(5 * Fs)));
base.fastWindowSec  = 0.40;
base.slowWindowSec  = 2.00;
base.absQuietEnergy = 0.040;
base.absScaleEnergy = 0.060;
base.fast = estimate_motion_window_baseline(imu, Fs, calN, base.fastWindowSec);
base.slow = estimate_motion_window_baseline(imu, Fs, calN, base.slowWindowSec);
base.med  = base.slow.med;
base.mad  = base.slow.mad;
end

function winBase = estimate_motion_window_baseline(imu, Fs, calN, windowSec)
win  = max(8, round(windowSec * Fs));
hop  = max(1, round(0.25 * Fs));
nWins = max(0, floor((calN - win) / hop) + 1);
energy = nan(nWins, 1);
ee = 0;
for stopIdx = win:hop:calN
    ee = ee + 1;
    idx = (stopIdx - win + 1):stopIdx;
    energy(ee,1) = motion_energy(imu, idx);
end
if isempty(energy)
    energy = motion_energy(imu, 1:calN);
end

winBase.med = median(energy, 'omitnan');
winBase.mad = median(abs(energy - winBase.med), 'omitnan');
madFloor = max(winBase.med * 0.25, 1e-3);
if ~isfinite(winBase.mad)
    winBase.mad = madFloor;
else
    winBase.mad = max(winBase.mad, madFloor);
end
end

function m = evaluate_motion_thresholds(rec)
m = struct();
m.motion_p50            = NaN;
m.motion_p90            = NaN;
m.motion_p95            = NaN;
m.motion_p99            = NaN;
m.clean_pct             = NaN;
m.risk_pct              = NaN;
m.corrupt_pct           = NaN;
m.fast_source_pct       = NaN;
m.sustained_source_pct  = NaN;
m.absolute_source_pct   = NaN;
m.motion_latency_p50_ms = NaN;
m.motion_latency_p95_ms = NaN;

if ~isfinite(rec.Fs) || rec.Fs <= 0
    return;
end

hop = max(1, round(0.25 * rec.Fs));
idx = 1:hop:numel(rec.t_s);
scores    = nan(numel(idx), 1);
latencyMs = nan(numel(idx), 1);
sources   = strings(numel(idx), 1);

for kk = 1:numel(idx)
    [scores(kk), latencyMs(kk), sources(kk)] = motion_score_at(rec, idx(kk));
end
motionEpoch  = isfinite(scores) & scores >= 3;
scores       = scores(isfinite(scores));
validLatency = latencyMs(motionEpoch & isfinite(latencyMs));
validSources = sources(motionEpoch & strlength(sources) > 0 & sources ~= "unavailable");

if isempty(scores)
    scores = NaN;
end

m.motion_p50   = percentile_local(scores, 50);
m.motion_p90   = percentile_local(scores, 90);
m.motion_p95   = percentile_local(scores, 95);
m.motion_p99   = percentile_local(scores, 99);
m.clean_pct    = 100 * mean(scores < 3,           'omitnan');
m.risk_pct     = 100 * mean(scores >= 3 & scores < 8, 'omitnan');
m.corrupt_pct  = 100 * mean(scores >= 8,          'omitnan');

if ~isempty(validSources)
    m.fast_source_pct      = 100 * nnz(startsWith(validSources, "fast_"))      / numel(validSources);
    m.sustained_source_pct = 100 * nnz(startsWith(validSources, "sustained_")) / numel(validSources);
    m.absolute_source_pct  = 100 * nnz(endsWith(validSources,   "_absolute"))  / numel(validSources);
end
if ~isempty(validLatency)
    m.motion_latency_p50_ms = percentile_local(validLatency, 50);
    m.motion_latency_p95_ms = percentile_local(validLatency, 95);
end
end

function [score, latencyMs, source] = motion_score_at(rec, n)
latencyMs = NaN;
source    = "unavailable";
if isempty(rec.imu.raw) || all(~isfinite(rec.imu.raw(:)))
    score = NaN;
    return;
end

fastWinSec = rec.motionBaseline.fastWindowSec;
slowWinSec = rec.motionBaseline.slowWindowSec;
[fastScore, fastComponent] = motion_score_for_window(rec, n, fastWinSec, rec.motionBaseline.fast);
[slowScore, slowComponent] = motion_score_for_window(rec, n, slowWinSec, rec.motionBaseline.slow);

if (isfinite(fastScore) && fastScore >= 3) || ~isfinite(slowScore)
    score     = fastScore;
    latencyMs = 1000 * fastWinSec;
    source    = "fast_" + fastComponent;
else
    score     = slowScore;
    latencyMs = 1000 * slowWinSec;
    source    = "sustained_" + slowComponent;
end
end

function [score, component] = motion_score_for_window(rec, n, windowSec, baseline)
idx    = max(1, n - round(windowSec * rec.Fs) + 1):n;
energy = motion_energy(rec.imu, idx);
calScore = max(0, (energy - baseline.med) / (baseline.mad + eps));
absScore = max(0, (energy - rec.motionBaseline.absQuietEnergy) / ...
    rec.motionBaseline.absScaleEnergy);
if absScore > calScore
    score     = absScore;
    component = "absolute";
else
    score     = calScore;
    component = "calibrated";
end
end

function energy = motion_energy(imu, idx)
acc = imu.acc_g(idx, :);
gyr = imu.gyro_dps(idx, :);
acc = acc(:, all(isfinite(acc), 1));
gyr = gyr(:, all(isfinite(gyr), 1));

if isempty(acc) && isempty(gyr)
    energy = NaN;
    return;
end

accE = 0;
gyrE = 0;
if ~isempty(acc)
    acc  = acc - mean(acc, 1, 'omitnan');
    accE = sqrt(mean(acc(:).^2, 'omitnan'));
end
if ~isempty(gyr)
    gyr  = gyr - mean(gyr, 1, 'omitnan');
    gyrE = sqrt(mean(gyr(:).^2, 'omitnan'));
end

energy = accE + 0.01*gyrE;
end

% ─────────────────────────────────────────────────────────────────────────────
% QRS detector evaluation
% ─────────────────────────────────────────────────────────────────────────────

function q = evaluate_qrs_thresholds(rec, bpf_id, notch_id)
q = struct();
q.r_count              = NaN;
q.median_hr_bpm        = NaN;
q.hr_p05_bpm           = NaN;
q.hr_p95_bpm           = NaN;
q.tachy_review_pct     = NaN;
q.irregular_review_pct = NaN;
q.long_rr_pct          = NaN;
q.predictive_pct       = NaN;
q.detector_latency_p50_ms = NaN;
q.detector_latency_p95_ms = NaN;

if ~isfinite(rec.Fs) || rec.Fs <= 0
    return;
end

filterState = build_filter_state(bpf_id, notch_id, rec.Fs);
proc = filter_ecg(rec.ecg_mV, filterState);

qrs = init_qrs_state(rec.Fs);
for nn = 1:numel(proc)
    qrs = update_qrs_state(qrs, proc, nn, rec.Fs);
end

r = qrs.rPeaks(:);
q.r_count = numel(r);

if numel(r) >= 2
    rr = diff(rec.t_s(r));
    hr = 60 ./ rr;
    hr = hr(isfinite(hr) & hr > 0);
    q.median_hr_bpm = median(hr, 'omitnan');
    q.hr_p05_bpm    = percentile_local(hr, 5);
    q.hr_p95_bpm    = percentile_local(hr, 95);
end

if ~isempty(qrs.rFlags)
    flags = qrs.rFlags(:);
    denom = max(1, numel(flags));
    q.tachy_review_pct     = 100 * nnz(flags == "tachy_range_review") / denom;
    q.irregular_review_pct = 100 * nnz(flags == "irregular_rr_review") / denom;
    q.long_rr_pct          = 100 * nnz(flags == "long_rr_or_missed")   / denom;
end

if ~isempty(qrs.rSource)
    q.predictive_pct = 100 * nnz(qrs.rSource(:) == "predictive") / max(1, numel(qrs.rSource));
end

if ~isempty(qrs.rLatencyMs)
    q.detector_latency_p50_ms = percentile_local(qrs.rLatencyMs, 50);
    q.detector_latency_p95_ms = percentile_local(qrs.rLatencyMs, 95);
end
end

% ─────────────────────────────────────────────────────────────────────────────
% QRS detector state machine (unchanged from original)
% ─────────────────────────────────────────────────────────────────────────────

function qrs = init_qrs_state(Fs)
qrs.rPeaks          = [];
qrs.rSource         = strings(0,1);
qrs.rFlags          = strings(0,1);
qrs.rLatencyMs      = [];
qrs.envBuf          = zeros(max(4, round(0.150 * Fs)), 1);
qrs.warmEnv         = [];
qrs.noiseLevel      = 0;
qrs.signalLevel     = 0;
qrs.threshold       = inf;
qrs.lastDecision    = -inf;
qrs.refractory      = round(0.280 * Fs);
qrs.warmup          = round(2.0 * Fs);
qrs.searchBack      = round(0.240 * Fs);
qrs.predictHalfWindow = round(0.180 * Fs);
qrs.hardMinRR       = round(0.240 * Fs);
qrs.fastReviewRR    = round(0.300 * Fs);
end

function qrs = update_qrs_state(qrs, ecg, n, Fs)
if n < 2 || ~isfinite(ecg(n)) || ~isfinite(ecg(n-1))
    return;
end

d = ecg(n) - ecg(n-1);
qrs.envBuf = [d*d; qrs.envBuf(1:end-1)];
env = mean(qrs.envBuf);

if n <= qrs.warmup
    qrs.warmEnv(end+1,1) = env;
    if n == qrs.warmup
        medv = median(qrs.warmEnv);
        madv = median(abs(qrs.warmEnv - medv)) + eps;
        qrs.noiseLevel  = medv;
        qrs.signalLevel = medv + 6*madv;
        qrs.threshold   = medv + 3*madv;
    end
    return;
end

if env > qrs.threshold && (n - qrs.lastDecision) > qrs.refractory
    search0 = max(1, n - qrs.searchBack);
    r       = localize_r_peak(ecg, search0, n, qrs);
    [qrs, accepted] = accept_qrs_candidate(qrs, ecg, r, n, "threshold", Fs);
    if accepted
        qrs.signalLevel = 0.875*qrs.signalLevel + 0.125*env;
    else
        qrs.noiseLevel  = 0.995*qrs.noiseLevel  + 0.005*env;
    end
else
    qrs.noiseLevel = 0.995*qrs.noiseLevel + 0.005*env;
end

prevBeatCount = numel(qrs.rPeaks);
qrs = try_predictive_recovery(qrs, ecg, n, Fs);
if numel(qrs.rPeaks) > prevBeatCount
    % Predictive recovery accepted a beat — update signal level so the
    % threshold does not drift down during motion-corrupted segments where
    % the threshold path consistently misses and predictive recovery fills in.
    qrs.signalLevel = 0.875*qrs.signalLevel + 0.125*env;
end

if qrs.signalLevel <= qrs.noiseLevel
    qrs.threshold = qrs.noiseLevel * 1.5 + eps;
else
    qrs.threshold = qrs.noiseLevel + 0.25*(qrs.signalLevel - qrs.noiseLevel);
end
end

function r = localize_r_peak(ecg, search0, search1, qrs)
r       = [];
search0 = max(1, search0);
search1 = min(numel(ecg), search1);
if search0 > search1; return; end

seg = ecg(search0:search1);
if all(~isfinite(seg)); return; end

if numel(qrs.rPeaks) >= 3
    recent   = qrs.rPeaks(max(1, end-4):end);
    recent   = recent(recent >= 1 & recent <= numel(ecg));
    polarity = sign(median(ecg(recent), 'omitnan'));
else
    polarity = 0;
end

if polarity > 0
    [~, k] = max(seg);
elseif polarity < 0
    [~, k] = min(seg);
else
    [~, k] = max(abs(seg));
end
r = search0 + k - 1;
end

function [qrs, accepted] = accept_qrs_candidate(qrs, ecg, r, triggerIdx, source, Fs)
accepted = false;
if isempty(r) || ~isfinite(r) || r < 1 || r > numel(ecg) || ~isfinite(ecg(r))
    return;
end

if ~isempty(qrs.rPeaks)
    rrSamples = r - qrs.rPeaks(end);
    if rrSamples < qrs.hardMinRR
        existing = qrs.rPeaks(end);
        if peak_strength(ecg, r, Fs) > peak_strength(ecg, existing, Fs)
            qrs.rPeaks(end)     = r;
            qrs.rSource(end)    = source;
            qrs.rLatencyMs(end) = 1000 * (triggerIdx - r) / Fs;
            qrs.rFlags(end)     = "duplicate_replaced";
            qrs.lastDecision    = triggerIdx;
        end
        return;
    end
end

flag           = rhythm_flag_for_candidate(qrs, r, Fs);
qrs.rPeaks(end+1,1)     = r;
qrs.rSource(end+1,1)    = source;
qrs.rLatencyMs(end+1,1) = 1000 * (triggerIdx - r) / Fs;
qrs.rFlags(end+1,1)     = flag;
qrs.lastDecision        = triggerIdx;
accepted = true;
end

function qrs = try_predictive_recovery(qrs, ecg, n, Fs)
if numel(qrs.rPeaks) < 4; return; end

rr = diff(qrs.rPeaks) / Fs;
rr = rr(rr >= 0.300 & rr <= 2.000);
if numel(rr) < 3; return; end

predRR   = median(rr(max(1, end-4):end));
expected = qrs.rPeaks(end) + round(predRR * Fs);
search0  = expected - qrs.predictHalfWindow;
search1  = expected + qrs.predictHalfWindow;

if n < search1 || search0 <= qrs.rPeaks(end) + qrs.refractory
    return;
end

search0 = max(1, search0);
search1 = min(n, min(numel(ecg), search1));
r = localize_r_peak(ecg, search0, search1, qrs);
if isempty(r); return; end

recent    = qrs.rPeaks(max(1, end-5):end);
recentAmp = median(arrayfun(@(idx) peak_strength(ecg, idx, Fs), recent), 'omitnan');
candAmp   = peak_strength(ecg, r, Fs);
if ~isfinite(candAmp) || candAmp < max(0.35 * recentAmp, eps)
    return;
end

[qrs, accepted] = accept_qrs_candidate(qrs, ecg, r, n, "predictive", Fs);
if accepted
    qrs.lastDecision = n;
end
end

function strength = peak_strength(ecg, r, Fs)
if r < 1 || r > numel(ecg) || ~isfinite(ecg(r))
    strength = NaN;
    return;
end
baseIdx  = max(1, r - round(0.250*Fs)):max(1, r - round(0.120*Fs));
baseline = median(ecg(baseIdx), 'omitnan');
strength = abs(ecg(r) - baseline);
end

function flag = rhythm_flag_for_candidate(qrs, r, Fs)
flag = "ok";
if isempty(qrs.rPeaks)
    flag = "first";
    return;
end

rrSamples = r - qrs.rPeaks(end);
if rrSamples < qrs.fastReviewRR
    flag = "tachy_range_review";
    return;
end

if rrSamples > round(2.000 * Fs)
    flag = "long_rr_or_missed";
    return;
end

if numel(qrs.rPeaks) >= 4
    rr  = diff(qrs.rPeaks(max(1, end-4):end)) / Fs;
    rr  = rr(rr >= 0.300 & rr <= 2.000);
    if numel(rr) >= 3
        medRR  = median(rr);
        thisRR = rrSamples / Fs;
        if abs(thisRR - medRR) > 0.30 * medRR
            flag = "irregular_rr_review";
        end
    end
end
end

% ─────────────────────────────────────────────────────────────────────────────
% Utilities
% ─────────────────────────────────────────────────────────────────────────────

function p = percentile_local(x, q)
x = x(isfinite(x));
if isempty(x); p = NaN; return; end
x   = sort(x(:));
pos = 1 + (numel(x) - 1) * q / 100;
lo  = floor(pos);
hi  = ceil(pos);
if lo == hi
    p = x(lo);
else
    p = x(lo) + (x(hi) - x(lo)) * (pos - lo);
end
end

function print_group_summary(T, bpf_label, notch_label)
fprintf('Overall threshold summary across %d recordings:\n', height(T));
fprintf('  BPF:    %s\n', bpf_label);
fprintf('  Notch:  %s\n\n', notch_label);
fprintf('  Median clean time:      %.1f %%\n', median(T.clean_pct, 'omitnan'));
fprintf('  Median risk time:       %.1f %%\n', median(T.motion_risk_pct, 'omitnan'));
fprintf('  Median corrupted time:  %.1f %%\n', median(T.corrupted_pct, 'omitnan'));
fprintf('  Median motion latency:  %.0f ms\n', median(T.motion_latency_p50_ms, 'omitnan'));
fprintf('  Median fast-score use:  %.1f %%\n', median(T.motion_fast_source_pct, 'omitnan'));
fprintf('  Median abs-floor use:   %.1f %%\n', median(T.motion_absolute_source_pct, 'omitnan'));
fprintf('  Median HR:              %.1f bpm\n', median(T.median_hr_bpm, 'omitnan'));
fprintf('  Median tachy flags:     %.2f %% of R detections\n', median(T.tachy_review_pct, 'omitnan'));
fprintf('  Median irregular flags: %.2f %% of R detections\n', median(T.irregular_review_pct, 'omitnan'));
fprintf('  Median predictive use:  %.2f %% of R detections\n\n', median(T.predictive_pct, 'omitnan'));

conditions = unique(T.condition);
fprintf('By condition:\n');
for ii = 1:numel(conditions)
    mask = T.condition == conditions(ii);
    fprintf('  %-18s n=%2d clean=%5.1f%% risk=%5.1f%% corrupt=%5.1f%% motionLat=%4.0fms tachy=%5.2f%% irregular=%5.2f%% HRmed=%5.1f\n', ...
        conditions(ii), nnz(mask), ...
        median(T.clean_pct(mask), 'omitnan'), ...
        median(T.motion_risk_pct(mask), 'omitnan'), ...
        median(T.corrupted_pct(mask), 'omitnan'), ...
        median(T.motion_latency_p50_ms(mask), 'omitnan'), ...
        median(T.tachy_review_pct(mask), 'omitnan'), ...
        median(T.irregular_review_pct(mask), 'omitnan'), ...
        median(T.median_hr_bpm(mask), 'omitnan'));
end
end
