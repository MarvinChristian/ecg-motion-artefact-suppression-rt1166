function [X, y, featureNames, epochInfo] = extract_epoch_features(varargin)
% EXTRACT_EPOCH_FEATURES Build ADS1293 ECG/IMU epoch features for ML training.
%
% Default use:
%   [X,y,names,info] = extract_epoch_features()
%
% Algorithm-selected use, matching the simplified ECG/IMU sim style:
%   [X,y,names,info] = extract_epoch_features( ...
%       'lead','ch1', 'bpf','B8', 'notch','N6', ...
%       'label_algorithm','kurtosis');
%
% Supported selectors:
%   lead            : 'ch1' | 'ch2' | 'diff12'
%   bpf             : 'none' | 'B1' | ... | 'B8'
%   notch           : 'none' | 'N1' | 'N2' | 'N3' | 'N4' | 'N5' | 'N6'
%   label_algorithm : 'kurtosis' | 'motion_score' | 'hybrid'
%
% The default manifest is config/ads1293_recording_manifest.csv, which points
% only to the copied 1 May ADS1293 two-channel recordings in
% thesis_pipeline/recordings/ads1293_20260501.

opts = parse_options(varargin{:});
paths = local_paths();

manifestPath = opts.manifest;
if ~isfile(manifestPath)
    manifestPath = fullfile(paths.subrepo, 'config', opts.manifest);
end
if ~isfile(manifestPath)
    error('Manifest not found: %s', opts.manifest);
end

manifest = readtable(manifestPath, 'TextType', 'string');
manifest = manifest(manifest.include_main == 1, :);
manifest = manifest(arrayfun(@(p) isfile(fullfile(paths.repo, p)), manifest.relative_path), :);
if isempty(manifest)
    error('No usable recordings found in manifest: %s', manifestPath);
end

featureNames = build_feature_names();
nFeat = numel(featureNames);
allX = zeros(0, nFeat);
allY = zeros(0, 1, 'uint8');
allInfo = table();

fprintf('Extracting ADS1293 epoch features from %d recordings\n', height(manifest));
fprintf('  manifest=%s\n', manifestPath);
fprintf('  lead=%s  bpf=%s  notch=%s  label=%s\n', ...
    opts.lead, opts.bpf, opts.notch, opts.label_algorithm);
fprintf('  epoch=%.0f ms  hop=%.0f ms  kSQI_thresh=%.2f  motion_clean_thresh=%.2f\n\n', ...
    opts.epoch_sec*1e3, opts.hop_sec*1e3, opts.kurtosis_thresh, opts.motion_clean_thresh);

for ii = 1:height(manifest)
    row = manifest(ii, :);
    fpath = fullfile(paths.repo, row.relative_path);
    fprintf('[%2d/%2d] %s (%s)\n', ii, height(manifest), row.recording_id, row.condition);

    try
        rec = load_recording(fpath, row, opts);
    catch ME
        fprintf('       SKIP: load failed - %s\n', ME.message);
        continue;
    end

    if ~isfinite(rec.Fs) || rec.Fs <= 0
        fprintf('       SKIP: invalid sample rate\n');
        continue;
    end
    if all(~isfinite(rec.imu.acc_g(:)))
        fprintf('       SKIP: no IMU columns\n');
        continue;
    end

    filterState = build_filter_state(opts.bpf_id, opts.notch, rec.Fs);
    ecg_filt = filter_ecg(rec.ecg_mV, filterState);
    baseline = estimate_motion_baseline(rec.imu, rec.Fs);

    epochSamp = max(4, round(opts.epoch_sec * rec.Fs));
    hopSamp = max(1, round(opts.hop_sec * rec.Fs));
    N = numel(rec.ecg_mV);
    warmupSamp = round(opts.warmup_sec * rec.Fs);
    startMin = warmupSamp + 1;
    startMax = N - epochSamp + 1;

    if startMin > startMax
        fprintf('       SKIP: recording too short after warmup\n');
        continue;
    end

    epochStarts = startMin:hopSamp:startMax;
    nEpochs = numel(epochStarts);
    recX = nan(nEpochs, nFeat);
    recY = zeros(nEpochs, 1, 'uint8');
    recInfo = table( ...
        repmat(row.recording_id, nEpochs, 1), ...
        repmat(row.condition, nEpochs, 1), ...
        repmat(row.cohort, nEpochs, 1), ...
        repmat(string(rec.format), nEpochs, 1), ...
        repmat(string(opts.lead), nEpochs, 1), ...
        repmat(string(opts.bpf), nEpochs, 1), ...
        repmat(string(opts.notch), nEpochs, 1), ...
        repmat(string(opts.label_algorithm), nEpochs, 1), ...
        nan(nEpochs, 1), nan(nEpochs, 1), nan(nEpochs, 1), nan(nEpochs, 1), zeros(nEpochs, 1, 'uint8'), ...
        'VariableNames', {'recording_id','condition','cohort','signal_format', ...
        'lead','bpf','notch','label_algorithm','epoch_start_s','motion_score', ...
        'motion_score_fast','sqi_kurtosis','y'});

    for kk = 1:nEpochs
        s1 = epochStarts(kk);
        idx = s1:(s1 + epochSamp - 1);

        imuFeats = compute_imu_features(rec.imu, idx, rec.Fs, baseline);
        ecgFeats = compute_ecg_quality_features(ecg_filt(idx), rec.Fs);
        fv = [imuFeats, ecgFeats];

        kSQI = ecgFeats(1);
        mScore = imuFeats(13);
        mFast = imuFeats(14);
        recX(kk,:) = fv;
        recY(kk) = epoch_label(kSQI, mScore, opts);

        recInfo.epoch_start_s(kk) = rec.t_s(s1);
        recInfo.motion_score(kk) = mScore;
        recInfo.motion_score_fast(kk) = mFast;
        recInfo.sqi_kurtosis(kk) = kSQI;
        recInfo.y(kk) = recY(kk);
    end

    valid = all(isfinite(recX), 2);
    allX = [allX; recX(valid,:)]; %#ok<AGROW>
    allY = [allY; recY(valid)]; %#ok<AGROW>
    allInfo = [allInfo; recInfo(valid,:)]; %#ok<AGROW>

    nOk = sum(valid);
    nClean = sum(recY(valid) == 1);
    fprintf('       Fs=%.2f Hz  %d epochs -> %d clean (%.0f%%), %d corrupted\n', ...
        rec.Fs, nOk, nClean, 100*nClean/max(1,nOk), nOk - nClean);
end

X = allX;
y = allY;
epochInfo = allInfo;

outDir = fullfile(paths.subrepo, 'outputs', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
if ~exist(outDir, 'dir'); mkdir(outDir); end
config = opts;
save(fullfile(outDir, 'epoch_features.mat'), 'X', 'y', 'featureNames', 'epochInfo', 'config');
writetable(epochInfo, fullfile(outDir, 'epoch_labels.csv'));

fprintf('\nDone. %d total epochs written to:\n  %s\n', size(X,1), outDir);
fprintf('  y=1 clean:     %d (%.1f%%)\n', sum(y==1), 100*mean(y==1));
fprintf('  y=0 corrupted: %d (%.1f%%)\n', sum(y==0), 100*mean(y==0));
fprintf('  Features:      %d\n\n', size(X,2));
end

function opts = parse_options(varargin)
opts = struct();
opts.epoch_sec = 0.500;
opts.hop_sec = 0.250;
opts.bpf = "B8";
opts.notch = "N6";
opts.lead = "ch1";
opts.label_algorithm = "kurtosis";
opts.kurtosis_thresh = 5.0;
opts.motion_clean_thresh = 3.0;
opts.motion_corrupt_thresh = 8.0;
opts.warmup_sec = 2.0;
opts.manifest = "ads1293_recording_manifest.csv";

% Backwards-compatible numeric form:
% extract_epoch_features(epochSec, hopSec, bpf_id, notch_id, kSQI_thresh)
if ~isempty(varargin) && isnumeric(varargin{1})
    legacy = varargin;
    if numel(legacy) >= 1 && ~isempty(legacy{1}); opts.epoch_sec = legacy{1}; end
    if numel(legacy) >= 2 && ~isempty(legacy{2}); opts.hop_sec = legacy{2}; end
    if numel(legacy) >= 3 && ~isempty(legacy{3})
        if legacy{3} == 0; opts.bpf = "none"; else; opts.bpf = "B" + string(legacy{3}); end
    end
    if numel(legacy) >= 4 && ~isempty(legacy{4})
        if legacy{4} == 0; opts.notch = "none"; else; opts.notch = "N" + string(legacy{4}); end
    end
    if numel(legacy) >= 5 && ~isempty(legacy{5}); opts.kurtosis_thresh = legacy{5}; end
else
    if mod(numel(varargin), 2) ~= 0
        error('Options must be name/value pairs.');
    end
    for ii = 1:2:numel(varargin)
        name = lower(string(varargin{ii}));
        val = varargin{ii+1};
        switch name
            case {"epoch","epoch_sec","epochsec"}
                opts.epoch_sec = val;
            case {"hop","hop_sec","hopsec"}
                opts.hop_sec = val;
            case "bpf"
                opts.bpf = string(val);
            case "notch"
                opts.notch = string(val);
            case "lead"
                opts.lead = lower(string(val));
            case {"label","label_algorithm","labelalgorithm"}
                opts.label_algorithm = lower(string(val));
            case {"kurtosis_thresh","ksqi_thresh"}
                opts.kurtosis_thresh = val;
            case "motion_clean_thresh"
                opts.motion_clean_thresh = val;
            case "motion_corrupt_thresh"
                opts.motion_corrupt_thresh = val;
            case "warmup_sec"
                opts.warmup_sec = val;
            case "manifest"
                opts.manifest = string(val);
            otherwise
                error('Unknown option: %s', name);
        end
    end
end

opts.bpf = upper(string(opts.bpf));
opts.notch = upper(string(opts.notch));
if opts.bpf == "NONE"; opts.bpf = "none"; end
if opts.notch == "NONE"; opts.notch = "none"; end
opts.bpf_id = bpf_to_id(opts.bpf);
validLeads = ["ch1","ch2","diff12"];
if ~any(opts.lead == validLeads)
    error('lead must be one of: ch1, ch2, diff12');
end
validLabels = ["kurtosis","motion_score","hybrid","none"];
if ~any(opts.label_algorithm == validLabels)
    error('label_algorithm must be one of: kurtosis, motion_score, hybrid, none');
end
end

function id = bpf_to_id(bpf)
if bpf == "none"
    id = 0;
    return;
end
tok = regexp(char(bpf), '^B([1-8])$', 'tokens', 'once');
if isempty(tok)
    error('bpf must be none or B1..B8.');
end
id = str2double(tok{1});
end

function y = epoch_label(kSQI, motionScore, opts)
switch opts.label_algorithm
    case "kurtosis"
        y = uint8(kSQI > opts.kurtosis_thresh);
    case "motion_score"
        y = uint8(motionScore < opts.motion_clean_thresh);
    case "hybrid"
        y = uint8((kSQI > opts.kurtosis_thresh) && (motionScore < opts.motion_corrupt_thresh));
    case "none"
        y = uint8(2);   % skip — reviewer starts blank, only manual labels are used
end
end

function names = build_feature_names()
% 21 features: 14 IMU + 7 ECG quality
% ECG features 15-17 are the original set; 18-21 are added from
% Li, Rajagopalan & Clifford 2014 (bsSQI, sSQI, entSQI) and
% Pan & Tompkins 1985 (R-peak presence binary).
names = { ...
    'acc_rms_s0', 'acc_rms_s1', 'acc_rms_s2', ...
    'gyr_rms_s0', 'gyr_rms_s1', 'gyr_rms_s2', ...
    'jerk_rms_s0', 'jerk_rms_s1', 'jerk_rms_s2', ...
    'diff_acc_s01', 'diff_acc_s02', 'diff_acc_s12', ...
    'motion_score', 'motion_score_fast', ...
    'ecg_kurtosis', 'ecg_signal_rms', 'ecg_nsr', ...
    'ecg_spectral_ratio', 'ecg_skewness', 'ecg_spectral_entropy', 'ecg_has_rpeak'};
end

function feats = compute_imu_features(imu, idx, Fs, baseline)
feats = nan(1, 14);
acc = imu.acc_g(idx, :);
gyr = imu.gyro_dps(idx, :);

for s = 1:3
    ac_cols = (s-1)*3 + (1:3);
    a = acc(:, ac_cols);
    g = gyr(:, ac_cols);
    ok_a = all(isfinite(a), 1);
    ok_g = all(isfinite(g), 1);
    if any(ok_a)
        a_dyn = a(:, ok_a) - mean(a(:, ok_a), 1);
        a_norm = sqrt(sum(a_dyn.^2, 2));
        feats(s) = rms(a_norm);
        jerk = diff(a_norm) * Fs;
        feats(6+s) = rms(jerk);
    end
    if any(ok_g)
        g_dyn = g(:, ok_g) - mean(g(:, ok_g), 1);
        g_norm = sqrt(sum(g_dyn.^2, 2));
        feats(3+s) = rms(g_norm);
    end
end

site_pairs = [1 2; 1 3; 2 3];
for pp = 1:3
    c1 = (site_pairs(pp,1)-1)*3 + (1:3);
    c2 = (site_pairs(pp,2)-1)*3 + (1:3);
    a1 = acc(:, c1);
    a2 = acc(:, c2);
    ok = all(isfinite(a1), 2) & all(isfinite(a2), 2);
    if sum(ok) >= 2
        d = a1(ok,:) - a2(ok,:);
        feats(9+pp) = mean(sqrt(sum(d.^2, 2)));
    end
end

e_slow = epoch_motion_energy(imu, idx);
fast_len = min(numel(idx), round(0.4 * Fs));
e_fast = epoch_motion_energy(imu, idx(end-fast_len+1:end));
feats(13) = score_from_energy(e_slow, baseline.slow);
feats(14) = score_from_energy(e_fast, baseline.fast);
end

function score = score_from_energy(energy, winBaseline)
if ~isfinite(energy) || ~isfinite(winBaseline.med)
    score = NaN;
else
    score = max(0, (energy - winBaseline.med) / (winBaseline.mad + eps));
end
end

function energy = epoch_motion_energy(imu, idx)
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
    acc = acc - mean(acc, 1, 'omitnan');
    accE = sqrt(mean(acc(:).^2, 'omitnan'));
end
if ~isempty(gyr)
    gyr = gyr - mean(gyr, 1, 'omitnan');
    gyrE = sqrt(mean(gyr(:).^2, 'omitnan'));
end
energy = accE + 0.01*gyrE;
end

function feats = compute_ecg_quality_features(ecg_epoch, Fs)
% Returns 7 ECG quality features.
%   1  ecg_kurtosis       : kSQI (Moeyersons 2019; Li et al. 2014)
%   2  ecg_signal_rms     : epoch amplitude
%   3  ecg_nsr            : high-freq noise ratio, ~hfSQI (Li et al. 2014)
%   4  ecg_spectral_ratio : bsSQI — power(8-35 Hz)/power(0.5-8 Hz) (Li et al. 2014)
%   5  ecg_skewness       : sSQI — 3rd standardised moment (Li et al. 2014)
%   6  ecg_spectral_entropy: entSQI — spectral flatness measure (Li et al. 2014)
%   7  ecg_has_rpeak      : 1 if QRS envelope detected (Pan & Tompkins 1985)
feats = nan(1, 7);
ecg = double(ecg_epoch(:));
ecg = ecg(isfinite(ecg));
N = numel(ecg);
if N < 8
    return;
end
ecg = ecg - mean(ecg);
mu2 = mean(ecg.^2);
mu4 = mean(ecg.^4);
if mu2 < eps
    return;
end

% 1. Kurtosis
feats(1) = mu4 / (mu2^2);
% 2. Signal RMS
feats(2) = sqrt(mu2);
% 3. High-freq noise ratio (~hfSQI)
win_len = min(N - 1, max(2, round(0.090 * Fs)));
if win_len >= 2
    trend = filter(ones(win_len,1)/win_len, 1, ecg);
    feats(3) = rms(ecg - trend) / max(eps, feats(2));
end

% Spectral features — shared FFT over 0.5-40 Hz
nfft = max(64, 2^nextpow2(N));
w = hann(N);
X = abs(fft(ecg .* w, nfft)).^2 / (N * sum(w.^2));
f_ax = (0:nfft/2) * Fs / nfft;
X = X(1:nfft/2+1);

% 4. Spectral ratio (bsSQI, Li et al. 2014)
% QRS band (8-35 Hz) power / motion-artefact band (0.5-8 Hz) power.
% High ratio = ECG-dominated epoch; low ratio = motion-artefact dominated.
qrs_mask = f_ax >= 8   & f_ax <= min(35, 0.95*Fs/2);
art_mask  = f_ax >= 0.5 & f_ax <= 8;
E_qrs = sum(X(qrs_mask));
E_art = sum(X(art_mask));
if E_art > eps
    feats(4) = E_qrs / E_art;
end

% 5. Skewness (sSQI, Li et al. 2014)
% Positive skew expected when R-peak (large positive excursion) is present.
mu3 = mean(ecg.^3);
feats(5) = mu3 / (mu2^1.5);

% 6. Spectral entropy (entSQI, Li et al. 2014)
% Entropy of normalised PSD within 0.5-40 Hz.
% Low entropy = spectrally concentrated (ECG-like); high = flat (noise-like).
ecg_mask = f_ax >= 0.5 & f_ax <= min(40, 0.95*Fs/2);
P = X(ecg_mask);
P_sum = sum(P);
if P_sum > eps
    p = P / P_sum;
    p = p(p > 0);
    feats(6) = -sum(p .* log2(p));
end

% 7. R-peak presence (binary, Pan & Tompkins 1985)
% Bandpass 5-20 Hz, square, integrate — QRS produces a high-crest-factor
% envelope. Feature = 1 if peak/mean of integrated envelope exceeds 4.
feats(7) = double(ecg_has_rpeak(ecg, Fs));
end

function present = ecg_has_rpeak(ecg, Fs)
present = false;
Ny = Fs / 2;
lo = 5; hi = min(20, 0.9 * Ny);
if lo >= hi || numel(ecg) < 16
    return;
end
[b, a] = butter(2, [lo hi] / Ny, 'bandpass');
xf = filter(b, a, ecg - ecg(1));
xs = xf .^ 2;
xi = movmean(xs, max(3, round(0.080 * Fs)));
if max(xi) > 0 && (max(xi) / mean(xi)) > 4.0
    present = true;
end
end

function paths = local_paths()
matlabDir = fileparts(mfilename('fullpath'));
paths.repo = fileparts(matlabDir);
paths.subrepo = matlabDir;
end

function rec = load_recording(fpath, manifestRow, opts)
data = read_numeric_recording(fpath);
t_us = double(data(:,1));
wrap = find(diff(t_us) < 0);
for ii = reshape(wrap, 1, [])
    t_us(ii+1:end) = t_us(ii+1:end) + 4294967296;
end
t_s = (t_us - t_us(1)) * 1e-6;
dt = diff(t_s);
dt = dt(isfinite(dt) & dt > 0);

rec = struct();
rec.id = manifestRow.recording_id;
rec.condition = manifestRow.condition;
rec.cohort = manifestRow.cohort;
rec.path = string(fpath);
rec.t_s = t_s;
rec.Fs = 1 / median(dt);
if isempty(dt) || ~isfinite(rec.Fs) || rec.Fs <= 0
    rec.Fs = NaN;
end

[ecg_mV, fmt, imuStartCol] = select_ecg_signal(data, opts.lead);
rec.ecg_mV = ecg_mV;
rec.format = fmt;
rec.imu = parse_imu_columns(data, imuStartCol);
end

function [ecg_mV, fmt, imuStartCol] = select_ecg_signal(data, lead)
ADS_SCALE_MV = (2.0 * 2400.0 / 3.5) / hex2dec('C35000');
nCols = size(data, 2);
if nCols == 21
    ch1 = data(:,2) * ADS_SCALE_MV;
    ch2 = data(:,3) * ADS_SCALE_MV;
    fmt = "ADS1293_IMU";
    imuStartCol = 4;
    switch lead
        case "ch1"; ecg_mV = ch1;
        case "ch2"; ecg_mV = ch2;
        case "diff12"; ecg_mV = ch1 - ch2;
    end
elseif nCols == 23
    ch1 = data(:,21) * ADS_SCALE_MV;
    ch2 = data(:,22) * ADS_SCALE_MV;
    fmt = "ECG_IMU_ADS_AUX";
    imuStartCol = 3;
    switch lead
        case "ch1"; ecg_mV = ch1;
        case "ch2"; ecg_mV = ch2;
        case "diff12"; ecg_mV = ch1 - ch2;
    end
else
    fmt = "AD8233";
    imuStartCol = 3;
    ecg_mV = data(:,2) * (1800 / 4096);
end
ecg_mV = ecg_mV - median(ecg_mV, 'omitnan');
end

function data = read_numeric_recording(fpath)
fid = fopen(fpath, 'r');
if fid < 0
    error('Could not open: %s', fpath);
end
headerLines = 0;
while true
    line = fgetl(fid);
    if ~ischar(line)
        fclose(fid);
        error('No numeric rows found in: %s', fpath);
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
% A few malformed rows with a different column count force readmatrix to
% NaN-pad all other rows. Trim to the modal column count first so those
% padding NaNs don't discard valid data.
col_counts = sum(~isnan(data), 2);
if ~isempty(col_counts)
    modal_cols = mode(col_counts);
    if modal_cols < size(data, 2)
        data = data(:, 1:modal_cols);
    end
end
data = data(all(isfinite(data), 2), :);
for cc = 2:size(data, 2)
    wrapped = data(:,cc) > 2147483647;
    data(wrapped, cc) = data(wrapped, cc) - 4294967296;
end
end

function imu = parse_imu_columns(data, imuStartCol)
N = size(data, 1);
raw = nan(N, 18);
available = max(0, min(18, size(data,2) - imuStartCol + 1));
if available > 0
    raw(:,1:available) = data(:, imuStartCol:(imuStartCol+available-1));
end
imu = struct();
imu.raw = raw;
imu.acc_g = nan(N, 9);
imu.gyro_dps = nan(N, 9);
for site = 1:3
    src = (site-1)*6 + (1:6);
    dst = (site-1)*3 + (1:3);
    imu.acc_g(:,dst) = raw(:, src(1:3)) / 16384;
    imu.gyro_dps(:,dst) = raw(:, src(4:6)) / 131;
end
end

function base = estimate_motion_baseline(imu, Fs)
N = size(imu.raw, 1);
if ~isfinite(Fs) || Fs <= 0
    base.fastWindowSec = NaN;
    base.slowWindowSec = NaN;
    base.fast = struct('med', NaN, 'mad', NaN);
    base.slow = struct('med', NaN, 'mad', NaN);
    base.med = NaN;
    base.mad = NaN;
    return;
end
calN = min(N, max(16, round(5 * Fs)));
base.fastWindowSec = 0.40;
base.slowWindowSec = 2.00;
base.fast = estimate_window_baseline(imu, Fs, calN, base.fastWindowSec);
base.slow = estimate_window_baseline(imu, Fs, calN, base.slowWindowSec);
base.med = base.slow.med;
base.mad = base.slow.mad;
end

function wb = estimate_window_baseline(imu, Fs, calN, windowSec)
win = max(8, round(windowSec * Fs));
hop = max(1, round(0.25 * Fs));
nWins = max(0, floor((calN - win) / hop) + 1);
energy = nan(nWins, 1);
ee = 0;
for stopIdx = win:hop:calN
    ee = ee + 1;
    energy(ee,1) = epoch_motion_energy(imu, (stopIdx-win+1):stopIdx);
end
if all(~isfinite(energy))
    energy = epoch_motion_energy(imu, 1:calN);
end
wb.med = median(energy, 'omitnan');
wb.mad = median(abs(energy - wb.med), 'omitnan');
madFloor = max(wb.med * 0.25, 1e-3);
if ~isfinite(wb.mad)
    wb.mad = madFloor;
else
    wb.mad = max(wb.mad, madFloor);
end
end

function filterState = build_filter_state(bpf_id, notch, Fs)
filterState.bpf_id = bpf_id;
filterState.notch = string(notch);
filterState.Fs = Fs;
filterState.bpSOS = design_bpf(bpf_id, Fs);
end

function sos = design_bpf(bpf_id, Fs)
sos = [];
if bpf_id == 0 || ~isfinite(Fs) || Fs <= 0
    return;
end
Ny = Fs / 2;
passbands = {[0.5 40], [0.5 40], [0.05 150], [0.5 40], [0.5 40], [0.05 40], [0.75 40], [0.5 40]};
pb = passbands{bpf_id};
pb(1) = max(pb(1), 0.01);
pb(2) = min(pb(2), 0.95 * Ny);
if pb(1) >= pb(2)
    return;
end
Wn = pb / Ny;
switch bpf_id
    case 1
        [z,p,k] = butter(4, Wn, 'bandpass');
    case 2
        [z,p,k] = butter(2, Wn, 'bandpass');
    case 3
        [z,p,k] = butter(4, Wn, 'bandpass');
    case 4
        [z,p,k] = cheby2(3, 40, Wn, 'bandpass');
    case 5
        [z,p,k] = ellip(2, 0.5, 40, Wn, 'bandpass');
    case {6,7}
        [z,p,k] = butter(4, Wn, 'bandpass');
    case 8
        [z,p,k] = butter(6, Wn, 'bandpass');
end
sos = zp2sos(z, p, k);
end

function y = filter_ecg(ecg, filterState)
if isempty(filterState.bpSOS)
    y = ecg;
else
    % Subtract first sample before filtering: ADS1293 DC offset (~1000 mV)
    % drives a 20-30 s causal BPF transient otherwise. The BPF removes DC
    % regardless; subtracting y(1) only prevents the initial blow-up.
    y = sosfilt(filterState.bpSOS, ecg - ecg(1));
end
if filterState.notch ~= "none"
    if exist('apply_notch', 'file') == 2
        y = apply_notch(y, char(filterState.notch), filterState.Fs);
    else
        warning('apply_notch.m is not on path. Skipping notch %s.', filterState.notch);
    end
end
end
