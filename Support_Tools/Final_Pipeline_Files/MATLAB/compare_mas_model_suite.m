function out = compare_mas_model_suite(labels_path, varargin)
% COMPARE_MAS_MODEL_SUITE Compare sensible MAS ML models on revised labels.
%
% Runs the current decoupled targets:
%   1) usability gate: clean vs corrupted
%   2) selector: suppressed vs baseline, excluding Both OK ties
%
% Default model suite is auto_full from train_mas_epoch_models:
% bagged trees, RUSBoost, RBF SVM, linear SVM, kNN, logistic regression,
% and a single decision tree. The output CSV includes LORO-CV metrics for
% every candidate model on both tasks.
%
% Usage:
%   out = compare_mas_model_suite('...\revised_mas_labels.mat');

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
opts = parse_options(varargin{:});

if nargin < 1 || isempty(labels_path)
    [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat');
    if isequal(fn, 0); out = struct(); return; end
    labels_path = fullfile(fd, fn);
end
labels_path = char(labels_path);

if strlength(opts.out_dir) == 0
    stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    opts.out_dir = string(fullfile(fileparts(labels_path), ['model_suite_' stamp]));
end
outDir = char(opts.out_dir);
if ~exist(outDir, 'dir'); mkdir(outDir); end

fprintf('\n================ MAS MODEL SUITE COMPARISON ================\n');
fprintf('Labels:\n  %s\n', labels_path);
fprintf('Output:\n  %s\n', outDir);
fprintf('Model suite: %s\n', opts.model_kind);
fprintf('Validation: LORO-CV; held-out 80/20 also reported where available.\n');
fprintf('Both OK labels: clean for usability, excluded from selector.\n\n');

out = train_mas_decoupled(labels_path, ...
    'model_kind', opts.model_kind, ...
    'max_depth', opts.max_depth, ...
    'k_folds', opts.k_folds, ...
    'out_dir', outDir, ...
    'export', false);

T = candidate_table(out);
csvPath = fullfile(outDir, 'mas_model_suite_comparison.csv');
writetable(T, csvPath);

fprintf('\n================ MODEL SUITE SUMMARY ================\n');
disp(T(:, {'task','model_kind','c_export_ready','embedded_sensible','balanced_acc','usable_recall','reject_recall','auc','status'}));
fprintf('Wrote comparison CSV:\n  %s\n', csvPath);

out.comparison_csv = string(csvPath);
out.comparison_table = T;
end

function opts = parse_options(varargin)
opts = struct();
opts.model_kind = "auto_full";
opts.max_depth = 5;
opts.k_folds = 5;
opts.out_dir = "";
if mod(numel(varargin), 2) ~= 0
    error('Options must be name/value pairs.');
end
for ii = 1:2:numel(varargin)
    name = lower(string(varargin{ii}));
    val = varargin{ii + 1};
    switch name
        case {"model_kind","model","suite"}
            opts.model_kind = string(val);
        case {"max_depth","depth"}
            opts.max_depth = max(1, round(double(val)));
        case {"k_folds","folds","cv"}
            opts.k_folds = max(2, round(double(val)));
        case {"out_dir","outdir","output_dir"}
            opts.out_dir = string(val);
        otherwise
            error('Unknown option "%s".', name);
    end
end
end

function T = candidate_table(out)
T = [task_candidate_table(out.usability, "usability_gate"); ...
     task_candidate_table(out.selection, "selection")];
[~, ord] = sortrows(table(T.task, -T.balanced_acc));
T = T(ord, :);
end

function T = task_candidate_table(models, taskName)
if ~isfield(models, 'pooled') || ~isfield(models, 'by_lead')
    T = table();
    return;
end
leadFields = fieldnames(models.by_lead);
if isempty(leadFields)
    T = table();
    return;
end
cr = models.by_lead.(leadFields{1}).candidate_results;
if isempty(cr)
    T = table();
    return;
end
n = numel(cr);
task = repmat(string(taskName), n, 1);
model_kind = strings(n, 1);
model_name = strings(n, 1);
embedded_sensible = false(n, 1);
c_export_ready = false(n, 1);
status = strings(n, 1);
balanced_acc = nan(n, 1);
usable_recall = nan(n, 1);
reject_recall = nan(n, 1);
precision = nan(n, 1);
f1 = nan(n, 1);
auc = nan(n, 1);
k_folds = nan(n, 1);
n_rows = repmat(double(models.pooled.n_rows), n, 1);
n_usable = repmat(double(models.pooled.n_usable), n, 1);
n_rejected = repmat(double(models.pooled.n_rejected), n, 1);
selected_by_auto = false(n, 1);

for ii = 1:n
    c = cr(ii);
    model_kind(ii) = string(c.kind);
    model_name(ii) = model_display_name_local(model_kind(ii));
    embedded_sensible(ii) = is_embedded_sensible(model_kind(ii));
    c_export_ready(ii) = is_c_export_ready(model_kind(ii));
    status(ii) = string(c.status);
    balanced_acc(ii) = read_num(c, 'balanced_acc');
    usable_recall(ii) = read_num(c, 'usable_recall');
    reject_recall(ii) = read_num(c, 'reject_recall');
    precision(ii) = read_num(c, 'precision');
    f1(ii) = read_num(c, 'f1');
    auc(ii) = read_num(c, 'auc');
    k_folds(ii) = read_num(c, 'k_folds');
    selected_by_auto(ii) = model_kind(ii) == string(models.pooled.model_kind);
end
T = table(task, model_kind, model_name, embedded_sensible, c_export_ready, selected_by_auto, status, ...
    balanced_acc, usable_recall, reject_recall, precision, f1, auc, ...
    k_folds, n_rows, n_usable, n_rejected);
end

function tf = is_embedded_sensible(kind)
tf = any(lower(string(kind)) == ["tree", "bag", "rusboost", "logistic", "lsvm"]);
end

function tf = is_c_export_ready(kind)
% export_bag_to_c emits firmware-compatible headers for bagged and RUSBoost
% tree ensembles. Other model families need their own exporter/inference path.
tf = any(lower(string(kind)) == ["bag", "rusboost"]);
end

function v = read_num(s, field)
if isstruct(s) && isfield(s, field) && ~isempty(s.(field))
    v = double(s.(field));
else
    v = NaN;
end
end

function name = model_display_name_local(kind)
switch lower(string(kind))
    case "bag"
        name = "Bagged trees";
    case "rusboost"
        name = "RUSBoost trees";
    case "svm"
        name = "RBF SVM";
    case "lsvm"
        name = "Linear SVM";
    case "knn"
        name = "kNN";
    case "logistic"
        name = "Logistic regression";
    case "tree"
        name = "Single decision tree";
    otherwise
        name = string(kind);
end
end
