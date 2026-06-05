function [X, y, featureNames, epochInfo, preview] = extract_mas_epoch_features(varargin)
% EXTRACT_MAS_EPOCH_FEATURES Build epoch features for MAS selection ML.
%
% Each epoch is expanded into 4 candidate rows:
%   Lead I  x BPF+Notch, BPF+Notch+NLMS(RA+LA)
%   Lead II x BPF+Notch, BPF+Notch+NLMS(RA+LL)
%
% The labels start as skip/unreviewed. Use label_mas_epoch_gui on the output
% .mat file to select fixed, lead-matched RA-pair NLMS, or corrupted for each
% epoch. IMU references are causally restricted to the transport-motion band
% before NLMS so the model sees the same suppression mechanism as firmware.

opts = parse_options(varargin{:});
paths = local_paths();
manifestPath = "";
if ~isempty(opts.recording_table)
    manifest = normalize_recording_table(opts.recording_table);
else
    manifestPath = resolve_manifest(opts.manifest, paths);
    manifest = readtable(manifestPath, 'TextType', 'string');
    if ismember('include_main', manifest.Properties.VariableNames)
        manifest = manifest(manifest.include_main == 1, :);
    end
end
manifest = manifest(arrayfun(@(p) isfile(recording_full_path(p, paths.repo)), manifest.relative_path), :);
selectedRecordings = opts.recordings;
if isempty(selectedRecordings) && (~isempty(opts.train_recordings) || ~isempty(opts.test_recordings))
    selectedRecordings = unique([opts.train_recordings(:); opts.test_recordings(:)], 'stable');
end
if ~isempty(selectedRecordings)
    keep = ismember(manifest.recording_id, string(selectedRecordings));
    manifest = manifest(keep, :);
end
if isempty(manifest)
    error('No usable recordings found for MAS ML extraction.');
end

combos = mas_combo_defs();
leads = ["ch1", "ch2"];
featureNames = mas_feature_names();
nFeat = numel(featureNames);

X = zeros(0, nFeat);
y = zeros(0, 1, 'uint8');
epochInfo = table();
preview.signals = {};
preview.times = {};

fprintf('MAS ML extraction from %d recordings\n', height(manifest));
fprintf('  bpf=%s  notch=%s  mas=%s  ref=%s  band=%.3g-%.3gHz  epoch=%.3fs  hop=%.3fs  preview=%.3fs each side  split=%s %.0f/%.0f\n\n', ...
    opts.bpf, opts.notch, opts.mas_algorithm, opts.ref_kind, ...
    opts.transport_band(1), opts.transport_band(2), opts.epoch_sec, opts.hop_sec, ...
    opts.preview_context_sec, opts.split_mode, 100 * (1 - opts.test_fraction), 100 * opts.test_fraction);

for rr = 1:height(manifest)
    row = manifest(rr, :);
    fpath = recording_full_path(row.relative_path, paths.repo);
    fprintf('[%2d/%2d] %s (%s)\n', rr, height(manifest), row.recording_id, row.condition);
    try
        rec = load_recording(fpath, row);
    catch ME
        fprintf('       SKIP: %s\n', ME.message);
        continue;
    end
    noImu = all(~isfinite(rec.imu.acc_g(:)));
    telemetryUsable = opts.use_phase4_telemetry && rec.phase4.has_ra_pair;
    if ~isfinite(rec.Fs) || rec.Fs <= 0 || (noImu && ~telemetryUsable)
        fprintf('       SKIP: invalid Fs or no IMU/new-config telemetry fallback\n');
        continue;
    end

    epochSamp = max(8, round(opts.epoch_sec * rec.Fs));
    hopSamp = max(1, round(opts.hop_sec * rec.Fs));
    warmupSamp = round(opts.warmup_sec * rec.Fs);
    startMin = warmupSamp + 1;
    startMax = numel(rec.t_s) - epochSamp + 1;
    if startMin > startMax
        fprintf('       SKIP: too short after warmup\n');
        continue;
    end
    starts = startMin:hopSamp:startMax;
    cap = round(opts.max_epochs_per_rec);
    if isfinite(cap) && cap > 0 && numel(starts) > cap
        mid = round(numel(starts) / 2);
        lo  = max(1, mid - floor(cap / 2));
        hi  = min(numel(starts), lo + cap - 1);
        lo  = max(1, hi - cap + 1);
        starts = starts(lo:hi);
    end
    splitNames = split_for_epoch_starts(row.recording_id, starts, opts);
    base = estimate_motion_baseline(rec.imu, rec.Fs);
    recRows = 0;

    for lead = leads
        ecg_raw = select_lead(rec, lead);
        ecg_pre = filter_ecg(ecg_raw, opts.bpf_id, opts.notch, rec.Fs);
        variants = cell(numel(combos), 1);
        variantRefs = cell(numel(combos), 1);
        refCounts = zeros(numel(combos), 1);
        variants{1} = ecg_pre;
        variantRefs{1} = [];
        for cc = 2:numel(combos)
            if combos(cc).id == 5 && telemetryUsable && noImu
                refs = [];
                variants{cc} = select_phase4_ra_pair(rec, lead);
                refCounts(cc) = uint16(18);
            else
                refs = build_source_refs(rec.imu, combos(cc).source, opts.ref_kind, rec.Fs, lead, opts.transport_band);
                refCounts(cc) = size(refs, 2);
                if isempty(refs)
                    variants{cc} = ecg_pre;
                else
                    variants{cc} = apply_mas_algorithm(ecg_pre, refs, opts, rec.Fs);
                end
            end
            variantRefs{cc} = refs;
        end

        for ss = 1:numel(starts)
            s1 = starts(ss);
            idx = s1:(s1 + epochSamp - 1);
            groupId = sprintf('%s|%s|%.6f', row.recording_id, lead, rec.t_s(s1));
            for cc = 1:numel(combos)
                sig = variants{cc};
                fv = compute_variant_features(ecg_pre, sig, rec.imu, idx, rec.Fs, base, combos(cc), refCounts(cc), lead, variantRefs{cc}, opts.transport_band);
                X(end+1, :) = fv; %#ok<AGROW>
                y(end+1, 1) = uint8(2); %#ok<AGROW>
                splitName = splitNames(ss);
                epochInfo = [epochInfo; make_info_row(row, groupId, splitName, lead, opts, combos(cc), rec.t_s(s1), refCounts(cc))]; %#ok<AGROW>
                [pt, ps] = preview_window(rec.t_s, sig, s1, epochSamp, rec.Fs, opts.preview_context_sec);
                preview.times{end+1,1} = single(pt);
                preview.signals{end+1,1} = single(ps);
                recRows = recRows + 1;
            end
        end
    end
    fprintf('       %.2f Hz  %d epoch groups -> %d variant rows (%d train / %d test starts)\n', ...
        rec.Fs, numel(starts) * numel(leads), recRows, nnz(splitNames == "train"), nnz(splitNames == "test"));
end

outDir = fullfile(paths.subrepo, 'outputs', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
if ~exist(outDir, 'dir'); mkdir(outDir); end
config = opts;
config.manifest = manifestPath;
config.candidate_policy = "fixed_or_ra_la_ra_ll_nlms_or_corrupt";
config.transport_band_hz = opts.transport_band;
config.firmware_combo_ids = uint8([combos.id]);
save(fullfile(outDir, 'mas_epoch_features.mat'), 'X', 'y', 'featureNames', 'epochInfo', 'config', 'preview', '-v7.3');
writetable(epochInfo, fullfile(outDir, 'mas_epoch_variants.csv'));

fprintf('\nDone. %d variant rows written to:\n  %s\n', size(X,1), outDir);
end

function opts = parse_options(varargin)
opts = struct();
opts.bpf = "B8";
opts.notch = "N3";
opts.mas_algorithm = "nlms";
opts.ref_kind = "six";
opts.lms_mu_cap = 0.01;
opts.nlms_mu_base = 0.5;
opts.nlms_step_cap = 0.001;
opts.rls_lambda = 0.999;
opts.mas_tap_order = 32;
opts.transport_band = [0.5 1.0];
opts.epoch_sec = 1.000;
opts.hop_sec = 0.500;
opts.preview_context_sec = 4.500;
opts.warmup_sec = 2.0;
opts.max_epochs_per_rec = Inf;
opts.manifest = "ads1293_recording_manifest.csv";
opts.recording_table = table();
opts.recordings = strings(0,1);
opts.train_recordings = strings(0,1);
opts.test_recordings = strings(0,1);
opts.split_mode = "recording";
opts.test_fraction = 0.20;
opts.use_phase4_telemetry = false;
if mod(numel(varargin), 2) ~= 0
    error('Options must be name/value pairs.');
end
for ii = 1:2:numel(varargin)
    name = lower(string(varargin{ii}));
    val = varargin{ii+1};
    switch name
        case "bpf"
            opts.bpf = upper(string(val));
        case "notch"
            opts.notch = upper(string(val));
        case {"mas","mas_algorithm","algorithm"}
            opts.mas_algorithm = lower(string(val));
        case {"ref","ref_kind","mas_ref"}
            opts.ref_kind = lower(string(val));
        case {"lms_mu","lms_mu_cap","mu_lms"}
            opts.lms_mu_cap = val;
        case {"nlms_mu","nlms_mu_base","mu_nlms"}
            opts.nlms_mu_base = val;
        case {"nlms_step_cap","step_cap","mu_cap_nlms"}
            opts.nlms_step_cap = val;
        case {"rls_lambda","lambda"}
            opts.rls_lambda = val;
        case {"mas_tap_order","tap_order","taps"}
            opts.mas_tap_order = val;
        case {"transport_band","motion_band","mas_band","mas_band_hz"}
            opts.transport_band = double(val(:)');
        case {"transport_band_low","band_low","mas_band_low","motion_band_low"}
            opts.transport_band(1) = double(val);
        case {"transport_band_high","band_high","mas_band_high","motion_band_high"}
            opts.transport_band(2) = double(val);
        case {"epoch","epoch_sec"}
            opts.epoch_sec = val;
        case {"hop","hop_sec","step_sec","step"}
            opts.hop_sec = val;
        case {"preview_context","preview_context_sec","label_context","label_context_sec","context_sec"}
            opts.preview_context_sec = val;
        case "warmup_sec"
            opts.warmup_sec = val;
        case {"max_epochs_per_rec","max_epochs","epochs_per_rec"}
            opts.max_epochs_per_rec = val;
        case "manifest"
            opts.manifest = string(val);
        case {"recording_table","recordingtable","recordings_table"}
            opts.recording_table = val;
        case {"recordings","recording_ids"}
            opts.recordings = string(val(:));
        case {"train_recordings","train_ids"}
            opts.train_recordings = string(val(:));
        case {"test_recordings","test_ids"}
            opts.test_recordings = string(val(:));
        case {"split_mode","split_policy","train_test_split"}
            opts.split_mode = lower(string(val));
        case {"test_fraction","test_ratio","holdout_fraction","holdout_ratio"}
            opts.test_fraction = double(val);
        case {"use_phase4_telemetry","use_telemetry","phase4_telemetry"}
            opts.use_phase4_telemetry = logical(val);
        otherwise
            error('Unknown option: %s', name);
    end
end
if opts.bpf == "NONE"; opts.bpf = "none"; end
if opts.notch == "NONE"; opts.notch = "none"; end
opts.bpf_id = bpf_to_id(opts.bpf);
if ~any(opts.mas_algorithm == ["lms","nlms","rls"])
    error('mas_algorithm must be lms, nlms, or rls.');
end
if ~any(opts.ref_kind == ["amag","gmag","magpair","accel3","gyro3","six"])
    error('ref_kind must be amag, gmag, magpair, accel3, gyro3, or six.');
end
opts.lms_mu_cap = bounded_option(opts.lms_mu_cap, 1e-7, 0.1, 0.01);
opts.nlms_mu_base = bounded_option(opts.nlms_mu_base, 1e-5, 2.0, 0.5);
opts.nlms_step_cap = bounded_option(opts.nlms_step_cap, 1e-6, 0.5, 0.001);
opts.rls_lambda = bounded_option(opts.rls_lambda, 0.95, 0.9999, 0.999);
opts.mas_tap_order = round(bounded_option(opts.mas_tap_order, 4, 64, 32));
opts.transport_band = sanitize_transport_band(200, opts.transport_band);
opts.preview_context_sec = bounded_option(opts.preview_context_sec, 0.0, 60.0, 4.5);
opts.test_fraction = min(max(double(opts.test_fraction), 0), 1);
end

function val = bounded_option(val, lo, hi, fallback)
if ~isnumeric(val) || isempty(val) || ~isfinite(double(val(1)))
    val = fallback;
else
    val = double(val(1));
end
val = min(hi, max(lo, val));
end

function band = sanitize_transport_band(Fs, band)
if nargin < 1 || ~isfinite(Fs) || Fs <= 2
    Fs = 200;
end
band = double(band(:)');
if numel(band) < 2 || ~all(isfinite(band(1:2)))
    band = [0.5 10.0];
else
    band = band(1:2);
end
band(1) = min(max(band(1), 0.05), max(0.05, 0.40 * Fs));
band(2) = min(max(band(2), band(1) + 0.25), 0.45 * Fs);
if band(2) <= band(1)
    band = [0.5 min(10.0, 0.45 * Fs)];
end
end

function manifest = normalize_recording_table(inputTable)
if ~istable(inputTable)
    error('recording_table must be a MATLAB table.');
end
manifest = inputTable;
if ismember('file_path', manifest.Properties.VariableNames) && ~ismember('relative_path', manifest.Properties.VariableNames)
    manifest.relative_path = string(manifest.file_path);
end
required = ["recording_id","relative_path"];
for kk = 1:numel(required)
    if ~ismember(required(kk), manifest.Properties.VariableNames)
        error('recording_table must contain "%s".', required(kk));
    end
end
if ~ismember('condition', manifest.Properties.VariableNames)
    manifest.condition = repmat("unknown", height(manifest), 1);
end
if ~ismember('cohort', manifest.Properties.VariableNames)
    manifest.cohort = repmat("gui", height(manifest), 1);
end
for name = ["recording_id","relative_path","condition","cohort"]
    manifest.(name) = string(manifest.(name));
end
manifest = manifest(strlength(strtrim(manifest.relative_path)) > 0, :);
end

function fpath = recording_full_path(pathValue, repoRoot)
p = char(string(pathValue));
if isfile(p)
    fpath = p;
else
    fpath = fullfile(repoRoot, p);
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

function names = mas_feature_names()
names = { ...
    'lead_id','combo_id','is_mas','source_ref_count', ...
    'motion_score_all','motion_score_source','imu_env_rms','imu_env_p95', ...
    'ecg_kurtosis','ecg_rms','ecg_nsr','ecg_qrs_artifact_ratio', ...
    'ecg_skewness','ecg_entropy','ecg_has_rpeak', ...
    'pre_kurtosis','pre_rms','pre_qrs_artifact_ratio', ...
    'mas_delta_rms_pct','mas_delta_p95_pct', ...
    'band_0p5_8_change_db','band_8_35_change_db', ...
    'pre_post_corr','imu_ecg_corr','imu_delta_corr'};
end

function combos = mas_combo_defs()
combos = struct( ...
    'id', {uint8(1), uint8(5)}, ...
    'name', {'BPF+Notch','BPF+Notch+NLMS(lead-matched RA-pair)'}, ...
    'source', {'none','ra_la_ra_ll'});
end

function rowOut = make_info_row(row, groupId, splitName, lead, opts, combo, startS, refCount)
rowOut = table( ...
    string(groupId), row.recording_id, row.condition, row.cohort, string(splitName), string(lead), ...
    string(opts.bpf), string(opts.notch), string(opts.mas_algorithm), string(opts.ref_kind), ...
    uint8(combo.id), string(combo.name), string(combo.source), startS, opts.epoch_sec, uint16(refCount), uint8(2), ...
    'VariableNames', {'group_id','recording_id','condition','cohort','split','lead','bpf','notch', ...
    'mas_algorithm','mas_ref_kind','combo_id','combo_name','mas_source','epoch_start_s', ...
    'epoch_sec','source_ref_count','y'});
end

function splitName = split_for_recording(recordingId, opts)
rid = string(recordingId);
if any(rid == opts.test_recordings)
    splitName = "test";
elseif any(rid == opts.train_recordings)
    splitName = "train";
else
    splitName = "unspecified";
end
end

function splitNames = split_for_epoch_starts(recordingId, starts, opts)
mode = lower(string(opts.split_mode));
if any(mode == ["per_recording_epoch","per_recording_epochs","within_recording","within_recording_epoch","epoch_per_recording"])
    n = numel(starts);
    splitNames = repmat("train", n, 1);
    if n < 2 || opts.test_fraction <= 0
        return;
    end
    nTest = max(1, round(opts.test_fraction * n));
    nTest = min(nTest, n - 1);
    splitNames((n - nTest + 1):n) = "test";
else
    splitNames = repmat(split_for_recording(recordingId, opts), numel(starts), 1);
end
end

function fv = compute_variant_features(pre, sig, imu, idx, Fs, baseline, combo, refCount, lead, refs, transportBand)
preEpoch = pre(idx);
sigEpoch = sig(idx);
imuFeats = compute_imu_summary(imu, idx, Fs, baseline, combo.source, lead, transportBand);
ecgFeats = compute_ecg_quality(sigEpoch, Fs);
preFeats = compute_ecg_quality(preEpoch, Fs);
delta = sigEpoch - preEpoch;
scale = robust_range(preEpoch, 5, 95);
if ~isfinite(scale) || scale < 1e-9
    scale = 6 * rms(preEpoch(isfinite(preEpoch)));
end
if ~isfinite(scale) || scale < 1e-9
    scale = 1;
end
delta = delta - median(delta, 'omitnan');
finiteDelta = delta(isfinite(delta));
if isempty(finiteDelta)
    deltaRmsPct = NaN;
    deltaP95Pct = NaN;
else
    deltaRmsPct = 100 * rms(finiteDelta) / scale;
    deltaP95Pct = 100 * prctile(abs(finiteDelta), 95) / scale;
end
[b05, bqrs] = band_changes(preEpoch, sigEpoch, Fs);
rho = corr_safe(preEpoch, sigEpoch);
refEnv = reference_envelope(refs, Fs);
if isempty(refEnv)
    imuEcgCorr = NaN;
    imuDeltaCorr = NaN;
else
    imuEcgCorr = corr_safe(refEnv(idx), sigEpoch);
    imuDeltaCorr = corr_safe(refEnv(idx), delta);
end
fv = [ ...
    double(lead_to_id(lead)), double(combo.id), double(combo.id > 1), double(refCount), ...
    imuFeats.motion_all, imuFeats.motion_source, imuFeats.imu_rms, imuFeats.imu_p95, ...
    ecgFeats.kurtosis, ecgFeats.rms, ecgFeats.nsr, ecgFeats.qrs_ratio, ecgFeats.skewness, ecgFeats.entropy, ecgFeats.has_rpeak, ...
    preFeats.kurtosis, preFeats.rms, preFeats.qrs_ratio, ...
    deltaRmsPct, deltaP95Pct, b05, bqrs, rho, imuEcgCorr, imuDeltaCorr];
end

function id = lead_to_id(lead)
if string(lead) == "ch2"
    id = 2;
else
    id = 1;
end
end

function feats = compute_imu_summary(imu, idx, Fs, baseline, source, lead, transportBand)
if nargin < 7
    transportBand = [0.5 10.0];
end
refs = build_source_refs(imu, source, "six", Fs, lead, transportBand);
env = reference_envelope(refs, Fs);
if isempty(env)
    envEpoch = NaN(size(idx(:)));
else
    envEpoch = env(idx);
end
allEnergy = epoch_motion_energy(imu, idx);
sourceEnergy = sqrt(mean(envEpoch.^2, 'omitnan'));
feats.motion_all = score_from_energy(allEnergy, baseline.slow);
feats.motion_source = score_from_energy(sourceEnergy, baseline.slow);
if isfield(imu, 'motion_score') && numel(imu.motion_score) >= max(idx)
    motionEpoch = imu.motion_score(idx);
    motionMed = median(motionEpoch, 'omitnan');
    if isfinite(motionMed)
        feats.motion_all = motionMed;
        if ~isfinite(feats.motion_source)
            feats.motion_source = motionMed;
        end
    end
end
feats.imu_rms = sourceEnergy;
finiteEnv = envEpoch(isfinite(envEpoch));
if isempty(finiteEnv)
    feats.imu_p95 = NaN;
else
    feats.imu_p95 = prctile(finiteEnv, 95);
end
end

function [b05, bqrs] = band_changes(preEpoch, sigEpoch, Fs)
nfft = max(64, 2^nextpow2(numel(preEpoch)));
[Ppre, f] = local_psd(preEpoch, Fs, nfft);
[Psig, ~] = local_psd(sigEpoch, Fs, nfft);
b05 = band_drop(Ppre, Psig, f, 0.5, 8);
bqrs = -band_drop(Ppre, Psig, f, 8, min(35, 0.45*Fs));
end

function db = band_drop(Pa, Pb, f, lo, hi)
mask = f >= lo & f <= hi;
db = 10 * log10((sum(Pa(mask)) + 1e-30) / (sum(Pb(mask)) + 1e-30));
end

function [P, f] = local_psd(x, Fs, nfft)
x = double(x(:));
x(~isfinite(x)) = 0;
x = x - mean(x);
w = hann(numel(x));
X = abs(fft(x .* w, nfft)).^2 / max(eps, sum(w.^2) * Fs);
P = X(1:nfft/2+1);
f = (0:nfft/2)' * Fs / nfft;
end

function feats = compute_ecg_quality(ecg, Fs)
ecg = double(ecg(:));
ecg = ecg(isfinite(ecg));
feats = struct('kurtosis',NaN,'rms',NaN,'nsr',NaN,'qrs_ratio',NaN,'skewness',NaN,'entropy',NaN,'has_rpeak',0);
if numel(ecg) < 8
    return;
end
ecg = ecg - mean(ecg);
mu2 = mean(ecg.^2);
if mu2 < eps
    return;
end
feats.kurtosis = mean(ecg.^4) / (mu2^2);
feats.rms = sqrt(mu2);
trendLen = min(numel(ecg)-1, max(2, round(0.090 * Fs)));
trend = filter(ones(trendLen,1)/trendLen, 1, ecg);
feats.nsr = rms(ecg - trend) / max(eps, feats.rms);
nfft = max(64, 2^nextpow2(numel(ecg)));
[P, f] = local_psd(ecg, Fs, nfft);
art = f >= 0.5 & f <= 8;
qrs = f >= 8 & f <= min(35, 0.45*Fs);
feats.qrs_ratio = sum(P(qrs)) / max(sum(P(art)), eps);
feats.skewness = mean(ecg.^3) / (mu2^1.5);
mask = f >= 0.5 & f <= min(40, 0.45*Fs);
Pband = P(mask);
Psum = sum(Pband);
if Psum > eps
    p = Pband / Psum;
    p = p(p > 0);
    feats.entropy = -sum(p .* log2(p));
end
feats.has_rpeak = double(local_has_rpeak(ecg, Fs));
end

function present = local_has_rpeak(ecg, Fs)
present = false;
if numel(ecg) < 16 || ~isfinite(Fs) || Fs <= 0
    return;
end
dx = [0; diff(ecg(:))];
env = movmean(dx.^2, max(3, round(0.080 * Fs)), 'Endpoints', 'shrink');
if max(env) > 0 && max(env) / max(mean(env), eps) > 5
    present = true;
end
end

function rec = load_recording(fpath, row)
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
rec.id = row.recording_id;
rec.condition = row.condition;
rec.cohort = row.cohort;
rec.t_s = t_s;
rec.Fs = 1 / median(dt);
if isempty(dt) || ~isfinite(rec.Fs) || rec.Fs <= 0
    rec.Fs = NaN;
end
[rec.ch1_mV, rec.ch2_mV, imuStartCol, rec.phase4] = select_ecg_columns(data);
rec.imu = parse_imu_columns(data, imuStartCol);
if rec.phase4.has_ra_pair && numel(rec.phase4.motion_score) == numel(rec.t_s)
    rec.imu.motion_score = rec.phase4.motion_score;
else
    rec.imu.motion_score = nan(numel(rec.t_s), 1);
end
end

function [ch1, ch2, imuStartCol, phase4] = select_ecg_columns(data)
ADS_SCALE_MV = (2.0 * 2400.0 / 3.5) / hex2dec('C35000');
nCols = size(data, 2);
phase4 = struct('has_ra_pair', false, ...
    'ra_pair_ch1_mV', nan(size(data,1),1), ...
    'ra_pair_ch2_mV', nan(size(data,1),1), ...
    'motion_score', nan(size(data,1),1));
isPhase4Compact21 = nCols == 21 && ...
    median(abs(data(:,9)), 'omitnan') <= 8 && ...
    median(abs(data(:,10)), 'omitnan') <= 8 && ...
    median(abs(data(:,11)), 'omitnan') <= 2 && ...
    median(abs(data(:,12)), 'omitnan') <= 4095;
isPhase4Telemetry = (nCols == 22 || nCols == 23 || nCols == 32 || nCols == 33) && ...
    median(abs(data(:,9)), 'omitnan') <= 8 && ...
    median(abs(data(:,10)), 'omitnan') <= 8 && ...
    median(abs(data(:,11)), 'omitnan') <= 2 && ...
    median(abs(data(:,12)), 'omitnan') <= 4095;
if (nCols == 21 && ~isPhase4Compact21) || nCols == 24
    ch1 = data(:,2) * ADS_SCALE_MV;
    ch2 = data(:,3) * ADS_SCALE_MV;
    imuStartCol = 4;
elseif nCols == 15 || nCols == 19 || nCols == 20 || isPhase4Compact21 || isPhase4Telemetry
    ch1 = data(:,2) * ADS_SCALE_MV;
    ch2 = data(:,3) * ADS_SCALE_MV;
    phase4.has_ra_pair = true;
    phase4.ra_pair_ch1_mV = data(:,4) * ADS_SCALE_MV;
    phase4.ra_pair_ch2_mV = data(:,5) * ADS_SCALE_MV;
    if nCols == 15 || nCols == 19 || nCols == 20 || isPhase4Compact21 || isPhase4Telemetry
        phase4.motion_score = data(:,13) / 10;
    end
    imuStartCol = NaN; % Phase4 realtime telemetry: IMU is internal, not streamed.
elseif nCols == 23
    ch1 = data(:,21) * ADS_SCALE_MV;
    ch2 = data(:,22) * ADS_SCALE_MV;
    imuStartCol = 3;
else
    ch1 = data(:,2) * (1800 / 4096);
    ch2 = ch1;
    imuStartCol = 3;
end
ch1 = ch1 - median(ch1, 'omitnan');
ch2 = ch2 - median(ch2, 'omitnan');
end

function ecg = select_lead(rec, lead)
if string(lead) == "ch2"
    ecg = rec.ch2_mV;
else
    ecg = rec.ch1_mV;
end
end

function ecg = select_phase4_ra_pair(rec, lead)
if string(lead) == "ch2"
    ecg = rec.phase4.ra_pair_ch2_mV;
else
    ecg = rec.phase4.ra_pair_ch1_mV;
end
if numel(ecg) ~= numel(rec.t_s)
    ecg = nan(size(rec.t_s));
end
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
colCounts = sum(~isnan(data), 2);
if ~isempty(colCounts)
    modalCols = mode(colCounts);
    if modalCols < size(data, 2)
        data = data(:, 1:modalCols);
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
if ~isfinite(imuStartCol)
    available = 0;
else
    available = max(0, min(18, size(data,2) - imuStartCol + 1));
end
if available > 0
    raw(:,1:available) = data(:, imuStartCol:(imuStartCol + available - 1));
end
imu = struct();
imu.raw = raw;
imu.acc_g = nan(N, 9);
imu.gyro_dps = nan(N, 9);
imu.motion_score = nan(N, 1);
for site = 1:3
    src = (site-1)*6 + (1:6);
    dst = (site-1)*3 + (1:3);
    imu.acc_g(:,dst) = raw(:, src(1:3)) / 16384;
    imu.gyro_dps(:,dst) = raw(:, src(4:6)) / 131;
end
end

function y = filter_ecg(ecg, bpf_id, notch, Fs)
sos = design_bpf(bpf_id, Fs);
if isempty(sos)
    y = ecg;
else
    y = sosfilt(sos, ecg - ecg(1));
end
if string(notch) ~= "none"
    y = apply_notch(y, char(notch), Fs, ecg);
end
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
pb(2) = min(pb(2), 0.99 * Ny);
if pb(1) >= pb(2)
    return;
end
Wn = pb / Ny;
switch bpf_id
    case 1, [z,p,k] = butter(4, Wn, 'bandpass');
    case 2, [z,p,k] = butter(2, Wn, 'bandpass');
    case 3, [z,p,k] = butter(4, Wn, 'bandpass');
    case 4, [z,p,k] = cheby2(5, 40, Wn, 'bandpass');
    case 5, [z,p,k] = ellip(2, 0.5, 40, Wn, 'bandpass');
    case 6, [z,p,k] = butter(4, Wn, 'bandpass');
    case 7, [z,p,k] = butter(4, Wn, 'bandpass');
    case 8, [z,p,k] = butter(6, Wn, 'bandpass');
end
[sos, g] = zp2sos(z, p, k);
sos(1,1:3) = sos(1,1:3) * g;
end

function refs = build_source_refs(imu, source, refKind, Fs, lead, transportBand)
if nargin < 5 || strlength(string(lead)) == 0
    lead = "ch1";
end
if nargin < 6
    transportBand = [0.5 10.0];
end
if string(source) == "none"
    refs = [];
    return;
end
[ll, la, ra] = site_ref_sets(imu, refKind);
switch string(source)
    case "ll"
        raw = ll;
    case "la"
        raw = la;
    case "ra"
        raw = ra;
    case "ra_ll"
        n = min(size(ra,1), size(ll,1));
        raw = [ra(1:n,:), ll(1:n,:), ra(1:n,:) - ll(1:n,:)];
    case "ra_la"
        n = min(size(ra,1), size(la,1));
        raw = [ra(1:n,:), la(1:n,:), ra(1:n,:) - la(1:n,:)];
    case "ra_la_ra_ll"
        if string(lead) == "ch2"
            n = min(size(ra,1), size(ll,1));
            raw = [ra(1:n,:), ll(1:n,:), ra(1:n,:) - ll(1:n,:)];
        else
            n = min(size(ra,1), size(la,1));
            raw = [ra(1:n,:), la(1:n,:), ra(1:n,:) - la(1:n,:)];
        end
    otherwise
        raw = [];
end
refs = condition_refs(raw, Fs, transportBand);
end

function [ll, la, ra] = site_ref_sets(imu, refKind)
ll = site_refs(imu, 1, refKind);
la = site_refs(imu, 2, refKind);
ra = site_refs(imu, 3, refKind);
end

function refs = site_refs(imu, site, refKind)
cols = (site-1)*3 + (1:3);
acc = imu.acc_g(:, cols);
gyr = imu.gyro_dps(:, cols);
amag = sqrt(sum(acc.^2, 2));
gmag = sqrt(sum(gyr.^2, 2));
switch string(refKind)
    case "amag"
        refs = amag;
    case "gmag"
        refs = gmag;
    case "magpair"
        refs = [amag, gmag];
    case "accel3"
        refs = acc;
    case "gyro3"
        refs = gyr;
    otherwise
        refs = [acc, gyr];
end
end

function refs = condition_refs(raw, Fs, transportBand)
refs = double(raw);
if isempty(refs)
    return;
end
if nargin < 3
    transportBand = [0.5 10.0];
end
refs = transport_bandpass(refs, Fs, transportBand);
refs(~isfinite(refs)) = 0;
alpha = exp(-1 / max(1, 2 * Fs));
alpha = min(max(alpha, 0.90), 0.9995);
mu = refs(1, :);
p = ones(1, size(refs, 2));
for nn = 1:size(refs, 1)
    xn = refs(nn, :);
    xc = xn - mu;
    p = alpha * p + (1 - alpha) * (xc.^2);
    refs(nn, :) = xc ./ sqrt(max(p, 1e-6));
    mu = alpha * mu + (1 - alpha) * xn;
end
refs = refs(:, all(isfinite(refs), 1) & std(refs,0,1) > 1e-10);
end

function y = transport_bandpass(x, Fs, band)
band = sanitize_transport_band(Fs, band);
lo = band(1);
hi = band(2);
if hi <= lo || Fs <= 2 * lo
    y = dc_block(x, 0.995);
    return;
end
try
    [bb, ba] = butter(2, [lo hi] / (Fs / 2), 'bandpass');
    y = filter(bb, ba, x);
catch
    y = dc_block(x, 0.995);
end
end

function y = dc_block(x, alpha)
lp = x(1, :);
y = zeros(size(x));
for nn = 1:size(x, 1)
    y(nn,:) = x(nn,:) - lp;
    lp = alpha * lp + (1 - alpha) * x(nn,:);
end
end

function y = apply_mas_algorithm(d, refs, opts, ~)
Nfull = numel(d);
n = min(Nfull, size(refs, 1));
refs = refs(1:n, :);
dWork = d(1:n);
nRef = size(refs, 2);
tapOrder = opts.mas_tap_order;
switch string(opts.mas_algorithm)
    case "lms"
        mu = min(opts.lms_mu_cap, 0.05 / max(1, nRef * tapOrder));
        yWork = mas_lms(dWork, refs, mu, tapOrder);
    case "rls"
        tapOrder = min(tapOrder, max(4, floor(160 / max(nRef,1))));
        yWork = mas_rls(dWork, refs, opts.rls_lambda, 1e-8, tapOrder);
    otherwise
        yWork = mas_nlms(dWork, refs, opts.nlms_mu_base, 1e-8, ...
            tapOrder, opts.nlms_step_cap);
end
bad = ~isfinite(yWork);
if any(bad)
    yWork(bad) = dWork(bad);
end
y = d(:);
y(1:n) = yWork;
end

function y = mas_lms(d, xRef, mu, filterOrder)
N = numel(d);
L = size(xRef, 2);
w = zeros(L*filterOrder, 1);
buf = zeros(L, filterOrder);
y = zeros(N, 1);
for nn = 1:N
    buf = [xRef(nn,:)', buf(:,1:end-1)];
    x = buf(:);
    e = d(nn) - w' * x;
    w = w + mu * e * x;
    y(nn) = e;
end
end

function y = mas_nlms(d, xRef, mu, epsReg, filterOrder, stepCap)
if nargin < 6 || isempty(stepCap) || ~isfinite(stepCap) || stepCap <= 0
    stepCap = Inf;
end
N = numel(d);
L = size(xRef, 2);
w = zeros(L*filterOrder, 1);
buf = zeros(L, filterOrder);
y = zeros(N, 1);
for nn = 1:N
    buf = [xRef(nn,:)', buf(:,1:end-1)];
    x = buf(:);
    e = d(nn) - w' * x;
    step = min(stepCap, mu / (x' * x + epsReg));
    w = w + step * e * x;
    y(nn) = e;
end
end

function y = mas_rls(d, xRef, lambda, epsReg, filterOrder)
N = numel(d);
L = size(xRef, 2);
w = zeros(L*filterOrder, 1);
P = 10 * eye(L*filterOrder);
buf = zeros(L, filterOrder);
y = zeros(N, 1);
for nn = 1:N
    buf = [xRef(nn,:)', buf(:,1:end-1)];
    x = buf(:);
    Px = P * x;
    k = Px / (lambda + x' * Px + epsReg);
    e = d(nn) - w' * x;
    w = w + k * e;
    P = (P - k * x' * P) / lambda;
    y(nn) = e;
end
end

function env = reference_envelope(refs, Fs)
env = [];
if isempty(refs)
    return;
end
env = sqrt(mean(refs.^2, 2, 'omitnan'));
if isfinite(Fs) && Fs > 0
    env = movmean(env, max(3, round(0.25 * Fs)), 'Endpoints', 'shrink');
end
end

function base = estimate_motion_baseline(imu, Fs)
calN = min(size(imu.raw, 1), max(16, round(5 * Fs)));
base.slow = estimate_window_baseline(imu, Fs, calN, 2.0);
end

function wb = estimate_window_baseline(imu, Fs, calN, windowSec)
win = max(8, round(windowSec * Fs));
hop = max(1, round(0.25 * Fs));
energy = [];
for stopIdx = win:hop:calN
    energy(end+1,1) = epoch_motion_energy(imu, (stopIdx-win+1):stopIdx); %#ok<AGROW>
end
if isempty(energy)
    energy = epoch_motion_energy(imu, 1:calN);
end
wb.med = median(energy, 'omitnan');
wb.mad = median(abs(energy - wb.med), 'omitnan');
wb.mad = max(wb.mad, max(wb.med * 0.25, 1e-3));
end

function score = score_from_energy(energy, base)
if ~isfinite(energy) || ~isfinite(base.med)
    score = NaN;
else
    score = max(0, (energy - base.med) / (base.mad + eps));
end
end

function energy = epoch_motion_energy(imu, idx)
acc = imu.acc_g(idx, :);
gyr = imu.gyro_dps(idx, :);
acc = acc(:, all(isfinite(acc), 1));
gyr = gyr(:, all(isfinite(gyr), 1));
accE = 0; gyrE = 0;
if ~isempty(acc)
    acc = acc - mean(acc, 1, 'omitnan');
    accE = sqrt(mean(acc(:).^2, 'omitnan'));
end
if ~isempty(gyr)
    gyr = gyr - mean(gyr, 1, 'omitnan');
    gyrE = sqrt(mean(gyr(:).^2, 'omitnan'));
end
energy = accE + 0.01 * gyrE;
end

function [pt, ps] = preview_window(t, sig, s1, epochSamp, Fs, contextSec)
if nargin < 6 || ~isfinite(contextSec)
    contextSec = 4.5;
end
ctx = round(max(0, contextSec) * Fs);
lo = max(1, s1 - ctx);
hi = min(numel(sig), s1 + epochSamp - 1 + ctx);
pt = t(lo:hi) - t(s1);
ps = sig(lo:hi);
end

function rr = robust_range(x, loPct, hiPct)
x = double(x(:));
x = x(isfinite(x));
if isempty(x)
    rr = NaN;
else
    rr = prctile(x, hiPct) - prctile(x, loPct);
end
end

function r = corr_safe(a, b)
a = double(a(:));
b = double(b(:));
n = min(numel(a), numel(b));
a = a(1:n); b = b(1:n);
good = isfinite(a) & isfinite(b);
if nnz(good) < 3 || std(a(good)) < eps || std(b(good)) < eps
    r = NaN;
else
    r = corr(a(good), b(good));
end
end

function manifestPath = resolve_manifest(manifest, paths)
manifestPath = char(manifest);
if isfile(manifestPath)
    return;
end
candidates = { ...
    fullfile(paths.subrepo, 'config', char(manifest)), ...
    fullfile(paths.support_tools, 'Recordings', 'R01_R10_ADS1293_IMU_TS', char(manifest)), ...
    fullfile(paths.support_tools, 'Recordings', 'R01_R10_ADS1293_IMU_TS', 'recording_manifest.csv')};
for ii = 1:numel(candidates)
    if isfile(candidates{ii})
        manifestPath = candidates{ii};
        return;
    end
end
error('Manifest not found: %s', manifest);
end

function paths = local_paths()
matlabDir = fileparts(mfilename('fullpath'));
paths.repo = repo_root_from_current_dir(matlabDir);
paths.subrepo = matlabDir;
paths.support_tools = fullfile(paths.repo, 'Support_Tools');
end

function repo = repo_root_from_current_dir(thisDir)
repo = char(thisDir);
for ii = 1:10
    if isfolder(fullfile(repo, '.git')) || isfolder(fullfile(repo, 'source'))
        return;
    end
    parent = fileparts(repo);
    if strcmp(parent, repo)
        break;
    end
    repo = parent;
end
repo = char(thisDir);
end
