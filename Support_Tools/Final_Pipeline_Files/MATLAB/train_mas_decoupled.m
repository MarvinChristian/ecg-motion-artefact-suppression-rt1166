function out = train_mas_decoupled(label_mat_path, varargin)
% TRAIN_MAS_DECOUPLED Split the single-winner MAS labels into two targets and
% train/evaluate each separately, reusing the pooled train_mas_epoch_models
% machinery (LORO-CV + within-recording 80/20 held-out + per-condition).
%
% Early labels forced one winner per epoch (baseline / suppressed / corrupted),
% so candidate preference dominated and genuine corruption was buried. Current
% labeller outputs can mark both candidates usable. This function derives:
%
%   (A) Usability gate    - per epoch: clean (>=1 candidate usable) vs corrupted
%                           (neither). Trained on the baseline (combo 1) row.
%                           usable_recall = clean recall; reject_recall =
%                           CORRUPTION recall (the clinically important number).
%   (B) Candidate select  - per CLEAN epoch: use-suppressed vs keep-baseline.
%                           Trained on the suppressed (combo 5) row, whose
%                           delta/comparison features describe what NLMS did.
%
% By default this writes training artifacts only. Set 'export',true to write
% firmware headers for the selected tree-ensemble models.
%
% Usage:
%   addpath('MATLAB Files/Current_MAS_ML_Iteration');
%   out = train_mas_decoupled('...\revised_mas_labels.mat');
%   out = train_mas_decoupled(path, 'model_kind','bag', 'out_dir','...');

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

opts = parse_opts(varargin{:});

% Keep 'auto' export conservative. RUSBoost can also be exported when requested
% explicitly, but the automatic deploy path uses bagged trees.
if opts.export && strcmpi(opts.model_kind, "auto")
    opts.model_kind = "bag";
    fprintf('Export requested with model_kind=auto: using model_kind=bag for the conservative firmware default.\n');
end

if nargin < 1 || isempty(label_mat_path)
    [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat');
    if isequal(fn, 0); out = struct(); return; end
    label_mat_path = fullfile(fd, fn);
end
label_mat_path = char(label_mat_path);

d = load(label_mat_path);
for rf = {'X', 'featureNames', 'epochInfo', 'y_final'}
    if ~isfield(d, rf{1})
        error('Missing "%s" in %s.', rf{1}, label_mat_path);
    end
end

ei = d.epochInfo;
if ~ismember('group_id', ei.Properties.VariableNames)
    error('epochInfo needs group_id to pair baseline/suppressed candidates.');
end
gid   = string(ei.group_id);
combo = double(ei.combo_id);
yf    = double(d.y_final);

baseSel = combo == 1;
suppSel = combo == 5;
baseGid = gid(baseSel);  baseY = yf(baseSel);  baseIdx = find(baseSel);
suppGid = gid(suppSel);  suppY = yf(suppSel);  suppIdx = find(suppSel);

% Pair each baseline row with its suppressed row via the shared group_id.
[hasSupp, loc] = ismember(baseGid, suppGid);
ys = nan(size(baseY));
sIdxForBase = nan(size(baseY));
ys(hasSupp) = suppY(loc(hasSupp));
sIdxForBase(hasSupp) = suppIdx(loc(hasSupp));

reviewed  = hasSupp & ismember(baseY, [0 1]) & ismember(ys, [0 1]);
isClean   = reviewed & ((baseY == 1) | (ys == 1));
isCorrupt = reviewed & (baseY == 0) & (ys == 0);
isBothUsable = reviewed & (baseY == 1) & (ys == 1);

fprintf('Decoupled label derivation from:\n  %s\n', label_mat_path);
fprintf('  reviewed epochs: %d  (clean=%d, corrupted=%d, %.1f%% corrupt)\n', ...
    nnz(reviewed), nnz(isClean), nnz(isCorrupt), 100 * nnz(isCorrupt) / max(1, nnz(reviewed)));
fprintf('  among clean: suppressed-preferred=%d, baseline-preferred=%d, both-usable=%d\n', ...
    nnz(isClean & ys == 1 & baseY == 0), nnz(isClean & baseY == 1 & ys == 0), nnz(isBothUsable));

% (A) Usability dataset: baseline rows, label clean(1)/corrupt(0).
useRows = baseIdx(reviewed);
dUse = struct();
dUse.X = d.X(useRows, :);
dUse.featureNames = d.featureNames;
dUse.epochInfo = ei(useRows, :);
dUse.y_final = double((baseY(reviewed) == 1) | (ys(reviewed) == 1));

% (B) Selection dataset: suppressed rows of CLEAN epochs with a real
% preference. "Both usable" labels are clean for the usability gate but are
% deliberately excluded here so the selector is not trained on a fake tie.
cleanLocal = find(isClean & ~isBothUsable);
selRows = sIdxForBase(cleanLocal);
dSel = struct();
dSel.X = d.X(selRows, :);
dSel.featureNames = d.featureNames;
dSel.epochInfo = ei(selRows, :);
dSel.y_final = double(ys(cleanLocal) == 1);

% Output dirs.
baseOut = char(opts.out_dir);
if isempty(baseOut)
    stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    baseOut = fullfile(fileparts(label_mat_path), ['decoupled_' stamp]);
end
useDir = fullfile(baseOut, 'usability');
selDir = fullfile(baseOut, 'selection');
if ~exist(useDir, 'dir'); mkdir(useDir); end
if ~exist(selDir, 'dir'); mkdir(selDir); end

useLabels = fullfile(useDir, 'revised_mas_usability_labels.mat');
selLabels = fullfile(selDir, 'revised_mas_selection_labels.mat');
save_label_struct(useLabels, dUse);
save_label_struct(selLabels, dSel);

% Train each via the pooled trainer. Header export is handled below only when
% opts.export is true; this call writes reports and CSVs only.
fprintf('\n================ (A) USABILITY GATE: clean vs corrupted ================\n');
modelsUse = train_mas_epoch_models(useLabels, opts.model_kind, opts.max_depth, opts.k_folds, ...
    'pooled', true, 'validation', 'loro', 'guard_overlap', true);
write_mas_training_artifacts(modelsUse, useLabels, 'export_bag', false);

fprintf('\n=========== (B) CANDIDATE SELECTION: suppressed vs baseline ===========\n');
modelsSel = train_mas_epoch_models(selLabels, opts.model_kind, opts.max_depth, opts.k_folds, ...
    'pooled', true, 'validation', 'loro', 'guard_overlap', true);
write_mas_training_artifacts(modelsSel, selLabels, 'export_bag', false);

exported = strings(0, 1);
if opts.export
    expDir = char(opts.export_dir);
    if isempty(expDir)
        expDir = default_firmware_source_dir(thisDir);
    end
    if ~exist(expDir, 'dir'); mkdir(expDir); end
    usePath = fullfile(expDir, 'mas_usability_classifier.h');
    selPath = fullfile(expDir, 'mas_selection_classifier.h');
    export_pooled(modelsUse, 'usability', usePath);
    export_pooled(modelsSel, 'selection', selPath);
    exported = [string(usePath); string(selPath)];
end

fprintf('\n==================== DECOUPLED SUMMARY ====================\n');
print_task('USABILITY  (usable=clean, reject=CORRUPTED)', modelsUse);
print_task('SELECTION  (usable=use suppressed, reject=keep baseline)', modelsSel);
fprintf('Artifacts under:\n  %s\n  %s\n', useDir, selDir);
for ii = 1:numel(exported)
    fprintf('Exported firmware header: %s\n', char(exported(ii)));
end

out = struct( ...
    'usability', modelsUse, ...
    'selection', modelsSel, ...
    'usability_dir', string(useDir), ...
    'selection_dir', string(selDir), ...
    'n_reviewed', nnz(reviewed), ...
    'n_clean', nnz(isClean), ...
    'n_corrupt', nnz(isCorrupt), ...
    'exported_headers', exported);
end

function print_task(name, models)
if isfield(models, 'pooled')
    p = models.pooled;
    fprintf('%s\n', name);
    fprintf('  LORO-CV : balanced %.1f%%, usable-recall %.1f%%, reject-recall %.1f%% (n=%d)\n', ...
        p.balanced_acc, p.usable_recall, p.reject_recall, p.n_rows);
    if isfinite(p.test_balanced_acc)
        fprintf('  80/20   : balanced %.1f%%, usable-recall %.1f%%, reject-recall %.1f%%\n', ...
            p.test_balanced_acc, p.test_usable_recall, p.test_reject_recall);
    end
else
    fprintf('%s : (no pooled result)\n', name);
end
end

function save_label_struct(path, s)
X = s.X;
featureNames = s.featureNames;
epochInfo = s.epochInfo;
y_final = s.y_final;
if isfile(path)
    delete(path);
end
save(path, 'X', 'featureNames', 'epochInfo', 'y_final', '-v7');
end

function opts = parse_opts(varargin)
opts = struct();
opts.model_kind = "auto";
opts.max_depth = 5;
opts.k_folds = 5;
opts.out_dir = "";
opts.export = false;
opts.export_dir = "";
if mod(numel(varargin), 2) ~= 0
    error('Options must be name/value pairs.');
end
for ii = 1:2:numel(varargin)
    name = lower(string(varargin{ii}));
    val = varargin{ii + 1};
    switch name
        case {"model", "model_kind", "kind"}
            opts.model_kind = string(val);
        case {"max_depth", "depth"}
            opts.max_depth = max(1, round(double(val)));
        case {"k_folds", "folds", "cv"}
            opts.k_folds = max(2, round(double(val)));
        case {"out_dir", "outdir", "output_dir"}
            opts.out_dir = string(val);
        case {"export", "export_headers", "export_models"}
            opts.export = logical(val);
        case {"export_dir", "firmware_dir", "source_dir"}
            opts.export_dir = string(val);
        otherwise
            error('Unknown option "%s".', name);
    end
end
end

function export_pooled(models, name, outPath)
% Export the single pooled forest (held identically in by_lead.ch1/ch2) under
% one task name, with the pooled overall metrics in the header comment.
if ~isfield(models, 'by_lead')
    error('No by_lead models to export for %s.', name);
end
flds = fieldnames(models.by_lead);
v = models.by_lead.(flds{1});
if ~ismember(lower(string(v.model_kind)), ["bag", "rusboost"])
    error('Export for %s needs a bag or RUSBoost tree ensemble; got %s.', name, char(string(v.model_kind)));
end
if isfield(models, 'pooled')
    v.balanced_acc  = models.pooled.balanced_acc;
    v.usable_recall = models.pooled.usable_recall;
    v.reject_recall = models.pooled.reject_recall;
end
em = struct();
em.featureNames = models.featureNames;
em.by_lead = struct();
em.by_lead.(name) = v;
export_bag_to_c(em, name, char(outPath));
end

function outDir = default_firmware_source_dir(thisDir)
repo = char(thisDir);
for ii = 1:8
    if isfolder(fullfile(repo, 'source'))
        outDir = fullfile(repo, 'source');
        return;
    end
    parent = fileparts(repo);
    if strcmp(parent, repo); break; end
    repo = parent;
end
outDir = char(thisDir);
end
