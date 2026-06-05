function out = retrain_and_compare(labels_path, varargin)
% RETRAIN_AND_COMPARE Evaluate a relabelled MAS dataset against the current
% deployed baseline. Uses the decoupled usability gate + selection workflow,
% LORO-CV, and held-out checks. Exportable headers are staged under
% Results/candidate_weights; source/ is not overwritten.
%
%   out = retrain_and_compare('path/to/revised_mas_labels.mat')
%   out = retrain_and_compare(path, 'feature_diagnostics', true)

opts = parse_options(varargin{:});
thisDir = fileparts(mfilename('fullpath'));
repo = repo_root_from_current_dir(thisDir);
supportFinal = fullfile(repo,'Support_Tools','Final_Pipeline_Files','MATLAB');
supportEval  = fullfile(repo,'Support_Tools','Evaluation_Files_By_Phase','MATLAB');
addpath(thisDir, supportFinal, supportEval);

if nargin < 1 || isempty(labels_path)
    [fn, fd] = uigetfile('*.mat', 'Select your new revised_mas_labels.mat');
    if isequal(fn, 0); out = struct(); return; end
    labels_path = fullfile(fd, fn);
end

% Current deployed RUSBoost baseline from the final relabelled result set.
base = struct('uB',80.1,'uClean',90.5,'uCorrupt',69.7,'sB',93.0);

fprintf('\n=============== LABEL BALANCE (new labels) ===============\n');
try
    summarize_mas_labels(labels_path);
catch e
    fprintf('  (summary skipped: %s)\n', e.message);
end

staging = fullfile(repo, 'Results', 'candidate_weights');
if ~exist(staging, 'dir'); mkdir(staging); end

% Same evaluation shape as the deployed path. Headers are staged for review.
out = train_mas_decoupled(labels_path, 'model_kind', 'bag', ...
        'export', true, 'export_dir', staging);

if opts.feature_diagnostics
    try
        out.feature_diagnostics = write_feature_diagnostics(out);
    catch ME
        fprintf('Feature diagnostics skipped: %s\n', ME.message);
    end
end

u = out.usability.pooled; s = out.selection.pooled;
fprintf('\n================ NEW  vs  CURRENT  (LORO-CV) ================\n');
fprintf('  Usability gate  balanced       : %5.1f%%   (current %.1f%%)\n', u.balanced_acc,  base.uB);
fprintf('                  clean-recall    : %5.1f%%   (current %.1f%%)\n', u.usable_recall, base.uClean);
fprintf('                  CORRUPT-recall  : %5.1f%%   (current %.1f%%)   <- clinically key\n', u.reject_recall, base.uCorrupt);
fprintf('  Selection model balanced       : %5.1f%%   (current %.1f%%)\n', s.balanced_acc, base.sB);

gateBetter   = u.balanced_acc  > base.uB + 0.5;
recallBetter = u.reject_recall > base.uCorrupt + 1.0;
fprintf('\n');
if gateBetter || recallBetter
    fprintf('>>> IMPROVED. Staged weights:\n    %s\n', staging);
    fprintf('    To deploy: copy mas_usability_classifier.h and mas_selection_classifier.h into source/.\n');
else
    fprintf('>>> NOT a clear improvement over current (within noise). Keep existing source/ weights.\n');
end
fprintf('============================================================\n');
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

function opts = parse_options(varargin)
opts = struct('feature_diagnostics', true);
if mod(numel(varargin), 2) ~= 0
    error('Options must be name/value pairs.');
end
for ii = 1:2:numel(varargin)
    name = lower(string(varargin{ii}));
    val = varargin{ii + 1};
    switch name
        case {"feature_diagnostics","diagnostics","ablation","feature_ablation"}
            opts.feature_diagnostics = logical(val);
        otherwise
            error('Unknown option "%s".', name);
    end
end
end

function diag = write_feature_diagnostics(out)
diagDir = fullfile(fileparts(char(out.usability_dir)), 'feature_diagnostics');
if ~exist(diagDir, 'dir'); mkdir(diagDir); end

importancePaths = strings(0, 1);
importancePaths(end+1, 1) = write_importance_csv(out.usability, "usability", diagDir);
importancePaths(end+1, 1) = write_importance_csv(out.selection, "selection", diagDir);

useLabels = fullfile(char(out.usability_dir), 'revised_mas_usability_labels.mat');
L = load(useLabels, 'X', 'featureNames', 'epochInfo', 'y_final');
fn = string(L.featureNames(:))';
imuCols = find(feature_group(fn) == "imu");
ecgCols = find(feature_group(fn) == "ecg");

p = out.usability.pooled;
ecgOnly = ablate_label_file(L, imuCols, diagDir, "ecg_only");
imuOnly = ablate_label_file(L, ecgCols, diagDir, "imu_only");
task = repmat("usability", 3, 1);
feature_set = ["full"; "ecg_only"; "imu_only"];
zeroed_features = ["none"; "imu"; "ecg"];
balanced_acc = [p.balanced_acc; ecgOnly.balanced_acc; imuOnly.balanced_acc];
usable_recall = [p.usable_recall; ecgOnly.usable_recall; imuOnly.usable_recall];
reject_recall = [p.reject_recall; ecgOnly.reject_recall; imuOnly.reject_recall];
n_rows = [p.n_rows; ecgOnly.n_rows; imuOnly.n_rows];
T = table(task, feature_set, zeroed_features, balanced_acc, usable_recall, reject_recall, n_rows);
ablationPath = fullfile(diagDir, 'feature_ablation_usability.csv');
writetable(T, ablationPath);

fprintf('\n================ FEATURE DIAGNOSTICS ================\n');
fprintf('  Feature importance CSVs:\n');
for ii = 1:numel(importancePaths)
    fprintf('    %s\n', char(importancePaths(ii)));
end
fprintf('  Usability ablation CSV:\n    %s\n', ablationPath);
fprintf('  ECG-only means IMU columns zeroed; IMU-only means ECG/SQI/MAS-delta columns zeroed.\n');

diag = struct('dir', string(diagDir), ...
    'importance_csv', importancePaths, ...
    'ablation_csv', string(ablationPath), ...
    'ablation', T);
end

function out = ablate_label_file(L, zeroCols, diagDir, name)
X = L.X;
X(:, zeroCols) = 0;
featureNames = L.featureNames;
epochInfo = L.epochInfo;
y_final = L.y_final;
tmpDir = fullfile(diagDir, '_tmp');
if ~exist(tmpDir, 'dir'); mkdir(tmpDir); end
tmpPath = fullfile(tmpDir, sprintf('usability_%s.mat', char(name)));
save(tmpPath, 'X', 'featureNames', 'epochInfo', 'y_final', '-v7.3');
M = train_mas_epoch_models(tmpPath, 'bag', 5, 5, ...
    'pooled', true, 'validation', 'loro', 'guard_overlap', true, 'save_model', false);
out = M.pooled;
end

function outPath = write_importance_csv(models, task, diagDir)
fn = string(models.featureNames(:));
imp = nan(numel(fn), 1);
if isfield(models, 'pooled') && isfield(models.pooled, 'feature_importance')
    raw = double(models.pooled.feature_importance(:));
    n = min(numel(raw), numel(imp));
    imp(1:n) = raw(1:n);
end
T = table(fn, feature_group(fn), imp, ...
    'VariableNames', {'feature_name','feature_group','importance'});
T = sortrows(T, 'importance', 'descend');
outPath = fullfile(diagDir, sprintf('feature_importance_%s.csv', char(task)));
writetable(T, outPath);
outPath = string(outPath);
end

function g = feature_group(names)
names = lower(string(names(:)));
g = repmat("meta", size(names));
isImu = startsWith(names, "imu_") | startsWith(names, "motion_score") | names == "source_ref_count";
isEcg = startsWith(names, "ecg_") | startsWith(names, "pre_") | ...
    startsWith(names, "mas_delta") | startsWith(names, "band_") | names == "pre_post_corr";
g(isImu) = "imu";
g(isEcg) = "ecg";
end
