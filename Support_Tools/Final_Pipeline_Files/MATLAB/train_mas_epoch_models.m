function models = train_mas_epoch_models(label_mat_path, model_kind, max_depth, k_folds, varargin)
% TRAIN_MAS_EPOCH_MODELS Train separate CH1/CH2 MAS candidate scorers.
%
% Input is revised_mas_labels.mat from label_mas_epoch_gui. The target is
% y_final per candidate row: 1 = reviewer-marked usable candidate, 0 =
% unusable/rejected candidate or corrupted group, 2 = skipped/unreviewed.
% The current firmware policy trains only combo 1 (fixed BPF+Notch) and
% combo 5 (lead-matched BPF+Notch+NLMS: CH1 RA+LA, CH2 RA+LL);
% corrupted epochs reject both candidates.
%
% model_kind can be:
%   auto      - compare embedded-suitable models and keep the best per lead
%   auto_full - also compare offline SVM/linear-SVM/kNN models
%   bag       - bagged/random-subspace trees (Random Forest style)
%   rusboost  - boosted trees with random undersampling
%   svm       - RBF SVM with Platt scaling; offline comparison/export risk
%   lsvm      - linear SVM (z-score normalised internally; NOT in auto - raw margins, not probabilities)
%   knn       - k-nearest neighbours (k=11, standardised); offline comparison
%   logistic  - regularized logistic linear model
%   tree      - single decision tree baseline
%
% Name/value options:
%   'validation','loro'        - default, leave one recording out on train split
%   'validation','group_kfold' - grouped epoch k-fold, kept for comparison runs
%   'save_model',false         - train and return models without writing mas_epoch_models.mat

if nargin < 1 || isempty(label_mat_path)
    [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat');
    if isequal(fn, 0); models = struct(); return; end
    label_mat_path = fullfile(fd, fn);
end

% Accept the earlier positional form train_mas_epoch_models(path, depth, folds).
if nargin < 2 || isempty(model_kind)
    model_kind = "auto";
elseif isnumeric(model_kind)
    oldMaxDepth = model_kind;
    if nargin >= 3
        oldKFolds = max_depth;
    else
        oldKFolds = [];
    end
    model_kind = "auto";
    max_depth = oldMaxDepth;
    k_folds = oldKFolds;
else
    model_kind = string(model_kind);
end
if nargin < 3 || isempty(max_depth); max_depth = 6; end
if nargin < 4 || isempty(k_folds); k_folds = 5; end
k_folds   = max(2, round(k_folds));
max_depth = max(1, round(max_depth));
progress_fn = [];
validation_mode = "loro";
save_model = true;
pooled = false;        % true = one ch1+ch2 model (lead_id is feature 1); false = per-lead
guard_overlap = true;  % pooled mode: drop boundary train epochs overlapping the test region
for vi = 1:2:numel(varargin)-1
    name = lower(string(varargin{vi}));
    switch name
        case "progress_fn"
            progress_fn = varargin{vi + 1};
        case {"validation","validation_mode","cv_mode","cv"}
            validation_mode = lower(string(varargin{vi + 1}));
        case {"save_model","save_models","write_model","write_models"}
            save_model = logical(varargin{vi + 1});
        case {"pooled","pool","single_model","combined"}
            pooled = logical(varargin{vi + 1});
        case {"guard_overlap","overlap_guard","guard","drop_overlap"}
            guard_overlap = logical(varargin{vi + 1});
    end
end

d = load(label_mat_path);
for rf = {'X','featureNames','epochInfo','y_final'}
    if ~isfield(d, rf{1})
        error('Missing "%s" in %s.', rf{1}, label_mat_path);
    end
end

featureNames = normalize_feature_names(d.featureNames, size(d.X, 2));
models = struct();
models.source_file = label_mat_path;
models.featureNames = featureNames;
models.requested_model = string(model_kind);
models.validation = validation_label(validation_mode);
models.selection_metric = "balanced_accuracy";
models.candidate_policy = "fixed_or_ra_la_ra_ll_nlms_or_corrupt";
models.active_combo_ids = active_combo_ids(d);
models.split_summary = split_summary_table(d, models.active_combo_ids);
models.by_lead = struct();
models.is_pooled = pooled;
leads = unique(string(d.epochInfo.lead), 'stable');

if pooled
    models = train_pooled_model(d, models, model_kind, max_depth, k_folds, ...
        validation_mode, progress_fn, guard_overlap, featureNames);
else
for leadIdx = 1:numel(leads)
    lead = leads(leadIdx);
    activeRows = ismember(double(d.epochInfo.combo_id), double(models.active_combo_ids));
    labelledRows = string(d.epochInfo.lead) == lead & activeRows & (d.y_final == 0 | d.y_final == 1);
    split = strings(height(d.epochInfo), 1);
    if ismember('split', d.epochInfo.Properties.VariableNames)
        split = string(d.epochInfo.split);
    end
    trainRows = labelledRows & split == "train";
    testRows = labelledRows & split == "test";
    if nnz(trainRows) == 0
        trainRows = labelledRows;
    end

    Xraw = double(d.X(trainRows, :));
    y = double(d.y_final(trainRows));
    groupIds = row_group_ids(d.epochInfo, trainRows);
    recordingIds = row_recording_ids(d.epochInfo, trainRows);
    comboTxt = char(strjoin(string(models.active_combo_ids), ','));
    fprintf('\nTraining MAS scorer for %s: %d train rows, %d train recordings, usable=%d rejected=%d, combos=%s', ...
        char(lead), size(Xraw,1), numel(unique(recordingIds)), sum(y==1), sum(y==0), comboTxt);
    if nnz(testRows) > 0
        fprintf(', test rows=%d', nnz(testRows));
    end
    fprintf('\n');

    if size(Xraw,1) < 20 || numel(unique(y)) < 2
        warning('Skipping %s: not enough labelled rows or only one class.', lead);
        continue;
    end

    kinds = resolve_model_kinds(model_kind, size(Xraw, 1));
    candidateResults = repmat(empty_candidate_result(""), 0, 1);
    bestKind = "";
    bestScore = -Inf;
    for kindIdx = 1:numel(kinds)
        kind = kinds(kindIdx);
        if ~model_available(kind)
            result = empty_candidate_result(kind);
            result.status = "unavailable";
        else
            result = evaluate_candidate(kind, Xraw, y, groupIds, recordingIds, featureNames, ...
                max_depth, k_folds, validation_mode);
        end
        candidateResults(end+1, 1) = result; %#ok<AGROW>
        fprintf('  candidate %-9s: %s', result.kind, result.status);
        if isfinite(result.balanced_acc)
            fprintf(' | balanced %.1f%%, usable %.1f%%, reject %.1f%%', ...
                result.balanced_acc, result.usable_recall, result.reject_recall);
        end
        fprintf('\n');
        if ~isempty(progress_fn)
            try
                progress_fn(lead, result, featureNames);
            catch
            end
        end
        if result.selection_score > bestScore
            bestScore = result.selection_score;
            bestKind = result.kind;
        end
    end

    if strlength(bestKind) == 0
        bestKind = "tree";
        warning('No candidate model validated for %s; falling back to single tree.', lead);
    end

    [X, imputeValues] = clean_features(Xraw);
    finalModel = fit_candidate_model(bestKind, X, y, featureNames, max_depth);
    featureImp = get_feature_importance(finalModel, bestKind, featureNames);
    if ~isempty(progress_fn)
        try
            progress_fn(lead, struct('type','selected','kind',bestKind,'importance',featureImp), featureNames);
        catch
        end
    end
    bestIdx = find([candidateResults.kind] == bestKind, 1);
    finalCv = candidateResults(bestIdx);
    fprintf('  selected model for %s: %s (%s)\n', lead, model_display_name(bestKind), bestKind);

    testMetrics = blank_metrics();
    if nnz(testRows) > 0
        Xt = clean_features(double(d.X(testRows, :)), imputeValues);
        yt = double(d.y_final(testRows));
        pt = predict_labels(finalModel, Xt);
        testMetrics = classification_metrics(yt, pt);
        try
            testMetrics.probs = predict_usable_prob(finalModel, Xt);
        catch
            testMetrics.probs = NaN(size(yt));
        end
        testMetrics.y_true = yt(:);
        testMetrics.y_pred = pt(:);
        testMetrics.recording_ids = row_recording_ids(d.epochInfo, testRows);
        testMetrics.by_recording = metrics_by_recording(testMetrics.y_true, testMetrics.y_pred, testMetrics.recording_ids);
        fprintf('  held-out test: accuracy %.1f%%, balanced %.1f%%, usable recall %.1f%%, reject recall %.1f%%\n', ...
            testMetrics.acc, testMetrics.balanced_acc, testMetrics.usable_recall, testMetrics.reject_recall);
    end

    field = matlab.lang.makeValidName(char(lead));
    models.by_lead.(field) = struct( ...
        'lead', lead, ...
        'model_kind', bestKind, ...
        'model_name', model_display_name(bestKind), ...
        'model', finalModel, ...
        'tree', finalModel, ...
        'impute_values', imputeValues, ...
        'cv', finalCv, ...
        'validation_mode', finalCv.validation_mode, ...
        'candidate_results', candidateResults, ...
        'feature_importance', featureImp, ...
        'kfold_acc', finalCv.acc, ...
        'balanced_acc', finalCv.balanced_acc, ...
        'usable_recall', finalCv.usable_recall, ...
        'selected_recall', finalCv.usable_recall, ...
        'reject_recall', finalCv.reject_recall, ...
        'cm', finalCv.cm, ...
        'test', testMetrics, ...
        'n_rows', size(X,1), ...
        'n_usable', sum(y==1), ...
        'n_selected', sum(y==1), ...
        'n_rejected', sum(y==0));
end
end  % if pooled / else per-lead

if save_model
    outDir = fileparts(label_mat_path);
    save(fullfile(outDir, 'mas_epoch_models.mat'), 'models');
    fprintf('\nSaved MAS ML models to:\n  %s\n', fullfile(outDir, 'mas_epoch_models.mat'));
end
end

function ids = active_combo_ids(d)
ids = uint8([1 5]);
if isfield(d, 'config') && isstruct(d.config) && isfield(d.config, 'firmware_combo_ids')
    cfgIds = uint8(d.config.firmware_combo_ids(:)');
    if ~isempty(cfgIds)
        ids = cfgIds;
    end
end
if isfield(d, 'epochInfo') && ismember('combo_id', d.epochInfo.Properties.VariableNames)
    present = unique(uint8(d.epochInfo.combo_id(:)))';
    ids = ids(ismember(ids, present));
    if isempty(ids)
        ids = present;
    end
end
ids = ids(:)';
end

function T = split_summary_table(d, activeIds)
if ~isfield(d, 'epochInfo') || ~isfield(d, 'y_final')
    T = table();
    return;
end
activeRows = ismember(double(d.epochInfo.combo_id), double(activeIds));
labelled = activeRows & (d.y_final == 0 | d.y_final == 1);
if ismember('split', d.epochInfo.Properties.VariableNames)
    splitVals = string(d.epochInfo.split);
else
    splitVals = repmat("unspecified", height(d.epochInfo), 1);
end
if ismember('recording_id', d.epochInfo.Properties.VariableNames)
    recVals = string(d.epochInfo.recording_id);
else
    recVals = repmat("recording_unknown", height(d.epochInfo), 1);
end
leads = unique(string(d.epochInfo.lead), 'stable');
splits = unique(splitVals(labelled), 'stable');
lead = strings(0,1);
split = strings(0,1);
n_recordings = zeros(0,1);
n_rows = zeros(0,1);
n_usable = zeros(0,1);
n_rejected = zeros(0,1);
for li = 1:numel(leads)
    for si = 1:numel(splits)
        mask = labelled & string(d.epochInfo.lead) == leads(li) & splitVals == splits(si);
        lead(end+1,1) = leads(li); %#ok<AGROW>
        split(end+1,1) = splits(si); %#ok<AGROW>
        n_recordings(end+1,1) = numel(unique(recVals(mask))); %#ok<AGROW>
        n_rows(end+1,1) = nnz(mask); %#ok<AGROW>
        n_usable(end+1,1) = nnz(mask & d.y_final == 1); %#ok<AGROW>
        n_rejected(end+1,1) = nnz(mask & d.y_final == 0); %#ok<AGROW>
    end
end
T = table(lead, split, n_recordings, n_rows, n_usable, n_rejected);
end

function result = evaluate_candidate(kind, Xraw, y, groupIds, recordingIds, featureNames, max_depth, k_folds, validation_mode)
result = empty_candidate_result(kind);
validation_mode = lower(string(validation_mode));
if validation_mode == "loro"
    [foldOfRow, kUse, foldNames] = make_loro_folds(recordingIds);
else
    [foldOfRow, kUse] = make_group_folds(groupIds, y, k_folds);
    foldNames = "fold_" + string((1:kUse)');
end
result.validation_mode = validation_label(validation_mode);
result.k_folds = kUse;
result.fold_names = foldNames(:);
if kUse < 2
    result.status = "no_" + validation_mode + "_cv";
    result.selection_score = -Inf;
    return;
end

pred  = NaN(numel(y), 1);
probs = NaN(numel(y), 1);
foldMetric = repmat(blank_fold_metric(), kUse, 1);
for foldIdx = 1:kUse
    te = foldOfRow == foldIdx;
    tr = foldOfRow ~= foldIdx & foldOfRow > 0;
    if nnz(te) == 0 || numel(unique(y(tr))) < 2
        continue;
    end
    try
        [Xtr, fillVals] = clean_features(Xraw(tr, :));
        Xte = clean_features(Xraw(te, :), fillVals);
        mdl = fit_candidate_model(kind, Xtr, y(tr), featureNames, max_depth);
        pred(te) = predict_labels(mdl, Xte);
        try
            probs(te) = predict_usable_prob(mdl, Xte);
        catch
        end
        fm = classification_metrics(y(te), pred(te));
        foldMetric(foldIdx) = fold_metric_from_metrics(foldNames(foldIdx), nnz(te), fm);
    catch ME
        result.status = "failed: " + string(ME.message);
        result.selection_score = -Inf;
        return;
    end
end

valid = isfinite(pred);
if nnz(valid) == 0
    result.status = "failed: no valid fold predictions";
    result.selection_score = -Inf;
    return;
end
m = classification_metrics(y(valid), pred(valid));
result.status        = "ok";
result.acc           = m.acc;
result.balanced_acc  = m.balanced_acc;
result.precision     = m.precision;
result.usable_recall = m.usable_recall;
result.reject_recall = m.reject_recall;
result.f1            = m.f1;
result.cm            = m.cm;
result.selection_score = m.balanced_acc;
result.fold_probs    = probs;
result.fold_y_true   = y;
result.fold_y_pred   = pred;
result.fold_recording_ids = recordingIds(:);
result.fold_metrics = foldMetric;
result.by_recording = metrics_by_recording(y(valid), pred(valid), recordingIds(valid));
probValid = isfinite(probs) & isfinite(pred);
if nnz(probValid) > 10
    try
        [rx, ry, ~, auc] = perfcurve(double(y(probValid)), double(probs(probValid)), 1);
        result.roc_x = rx(:);
        result.roc_y = ry(:);
        result.auc   = auc;
    catch
    end
end
end

function mdl = fit_candidate_model(kind, X, y, featureNames, max_depth)
maxSplits = max(1, 2^max_depth - 1);
minLeaf = max(2, min(10, floor(size(X,1) / 20)));
classNames = [0 1];
switch lower(string(kind))
    case "tree"
        mdl = fitctree(X, y, ...
            'MaxNumSplits', maxSplits, ...
            'MinLeafSize', minLeaf, ...
            'ClassNames', classNames, ...
            'Prior', 'uniform', ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
    case "bag"
        nVars = max(1, round(sqrt(size(X, 2))));
        tmpl = templateTree('MaxNumSplits', maxSplits, ...
            'MinLeafSize', minLeaf, ...
            'NumVariablesToSample', nVars);
        mdl = fitcensemble(X, y, ...
            'Method', 'Bag', ...
            'Learners', tmpl, ...
            'NumLearningCycles', 80, ...
            'ClassNames', classNames, ...
            'Prior', 'uniform', ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
    case "rusboost"
        tmpl = templateTree('MaxNumSplits', min(maxSplits, 31), ...
            'MinLeafSize', minLeaf);
        mdl = fitcensemble(X, y, ...
            'Method', 'RUSBoost', ...
            'Learners', tmpl, ...
            'NumLearningCycles', 100, ...
            'LearnRate', 0.1, ...
            'ClassNames', classNames, ...
            'Prior', 'uniform', ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
    case "svm"
        mdl = fitcsvm(X, y, ...
            'KernelFunction', 'rbf', ...
            'KernelScale', 'auto', ...
            'Standardize', true, ...
            'BoxConstraint', 1, ...
            'ClassNames', classNames, ...
            'Prior', 'uniform', ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
        mdl = fitPosterior(mdl); % Platt scaling: predict returns a positive-class score.
    case "lsvm"
        % fitclinear does not accept Standardize; z-score manually and wrap
        mu = mean(X, 1);
        sigma = std(X, 0, 1);
        sigma(sigma < 1e-10) = 1;
        Xz = (X - mu) ./ sigma;
        inner = fitclinear(Xz, y, ...
            'Learner', 'svm', ...
            'ClassNames', classNames, ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
        mdl = struct('type', 'zscore_wrapped', 'inner', inner, 'mu', mu, 'sigma', sigma);
    case "knn"
        mdl = fitcknn(X, y, ...
            'NumNeighbors', 11, ...
            'Standardize', true, ...
            'ClassNames', classNames, ...
            'Prior', 'uniform', ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
    case "logistic"
        mdl = fitclinear(X, y, ...
            'Learner', 'logistic', ...
            'Regularization', 'ridge', ...
            'ClassNames', classNames, ...
            'PredictorNames', featureNames, ...
            'ResponseName', 'UsableCandidate');
    otherwise
        error('Unknown model kind "%s".', kind);
end
end

function yhat = predict_labels(mdl, X)
if isstruct(mdl) && isfield(mdl, 'type') && strcmp(mdl.type, 'zscore_wrapped')
    sig = mdl.sigma; sig(sig < 1e-10) = 1;
    X = (X - mdl.mu) ./ sig;
    mdl = mdl.inner;
end
yhat = predict(mdl, X);
if iscategorical(yhat)
    yhat = str2double(string(yhat));
else
    yhat = double(yhat);
end
yhat = yhat(:);
end

function kinds = resolve_model_kinds(model_kind, ~)
kind = lower(strtrim(string(model_kind)));
switch kind
    case {"auto","best","compare"}
        % Embedded default: probability-like scores and simple C export paths.
        % SVM/kNN remain available as explicit offline comparisons.
        kinds = ["bag"; "rusboost"; "logistic"; "tree"];
    case {"auto_full","full","compare_full","offline"}
        kinds = ["bag"; "rusboost"; "svm"; "lsvm"; "knn"; "logistic"; "tree"];
    case {"bag","bagged","bagged trees","randomforest","random forest","rf"}
        kinds = "bag";
    case {"rusboost","boost","boosted","boosted trees"}
        kinds = "rusboost";
    case {"svm","rbf svm","rbf"}
        kinds = "svm";
    case {"lsvm","linear svm","linear support vector machine"}
        kinds = "lsvm";
    case {"knn","k-nearest neighbours","k nearest neighbours"}
        kinds = "knn";
    case {"logistic","linear","linear logistic"}
        kinds = "logistic";
    case {"tree","decision tree","single tree"}
        kinds = "tree";
    otherwise
        error('Unknown model kind "%s".', model_kind);
end
kinds = kinds(:);
end

function tf = model_available(kind)
switch lower(string(kind))
    case "tree"
        tf = exist('fitctree', 'file') == 2;
    case {"bag","rusboost"}
        tf = exist('fitcensemble', 'file') == 2 && exist('templateTree', 'file') == 2;
    case "svm"
        tf = exist('fitcsvm', 'file') == 2;
    case "lsvm"
        tf = exist('fitclinear', 'file') == 2;
    case "knn"
        tf = exist('fitcknn', 'file') == 2;
    case "logistic"
        tf = exist('fitclinear', 'file') == 2;
    otherwise
        tf = false;
end
end

function name = model_display_name(kind)
switch lower(string(kind))
    case "tree"
        name = "Single decision tree";
    case "bag"
        name = "Bagged/random-subspace trees";
    case "rusboost"
        name = "RUSBoost trees";
    case "svm"
        name = "RBF SVM + Platt scaling";
    case "lsvm"
        name = "Linear SVM";
    case "knn"
        name = "k-nearest neighbours (k=11)";
    case "logistic"
        name = "Regularized logistic linear";
    otherwise
        name = string(kind);
end
end

function result = empty_candidate_result(kind)
result = struct( ...
    'kind', string(kind), ...
    'name', model_display_name(kind), ...
    'status', "not_run", ...
    'validation_mode', "", ...
    'k_folds', 0, ...
    'fold_names', strings(0,1), ...
    'acc', NaN, ...
    'balanced_acc', NaN, ...
    'precision', NaN, ...
    'usable_recall', NaN, ...
    'reject_recall', NaN, ...
    'f1', NaN, ...
    'auc', NaN, ...
    'roc_x', [], ...
    'roc_y', [], ...
    'fold_probs',  [], ...
    'fold_y_true', [], ...
    'fold_y_pred', [], ...
    'fold_recording_ids', strings(0,1), ...
    'fold_metrics', [], ...
    'by_recording', table(), ...
    'cm', [], ...
    'selection_score', -Inf);
end

function m = classification_metrics(yTrue, yPred)
m = blank_metrics();
if isempty(yTrue)
    return;
end
yTrue = double(yTrue(:));
yPred = double(yPred(:));
cm = confusionmat(yTrue, yPred, 'Order', [0 1]);
% cm layout (order = [reject=0, usable=1]):
%   [TN  FP]
%   [FN  TP]
m.cm = cm;
TN = cm(1,1); FP = cm(1,2); FN = cm(2,1); TP = cm(2,2);
m.acc           = 100 * (TP + TN)   / max(1, sum(cm(:)));
m.reject_recall = 100 * TN          / max(1, TN + FP);   % specificity
m.usable_recall = 100 * TP          / max(1, TP + FN);   % sensitivity
m.selected_recall = m.usable_recall;
m.balanced_acc  = mean([m.reject_recall, m.usable_recall], 'omitnan');
m.precision     = 100 * TP          / max(1, TP + FP);
m.f1            = 100 * 2*TP        / max(1, 2*TP + FP + FN);
end

function m = blank_metrics()
m = struct('acc', NaN, ...
    'balanced_acc', NaN, ...
    'precision', NaN, ...
    'usable_recall', NaN, ...
    'selected_recall', NaN, ...
    'reject_recall', NaN, ...
    'f1', NaN, ...
    'cm', []);
end

function label = validation_label(mode)
mode = lower(string(mode));
switch mode
    case "loro"
        label = "leave_one_recording_out_cv_on_train_split";
    otherwise
        label = "group_kfold_by_epoch_on_train_split";
end
end

function fm = blank_fold_metric()
fm = struct('fold', "", ...
    'n', 0, ...
    'acc', NaN, ...
    'balanced_acc', NaN, ...
    'usable_recall', NaN, ...
    'reject_recall', NaN, ...
    'precision', NaN, ...
    'f1', NaN);
end

function fm = fold_metric_from_metrics(foldName, n, m)
fm = blank_fold_metric();
fm.fold = string(foldName);
fm.n = n;
fm.acc = m.acc;
fm.balanced_acc = m.balanced_acc;
fm.usable_recall = m.usable_recall;
fm.reject_recall = m.reject_recall;
fm.precision = m.precision;
fm.f1 = m.f1;
end

function [foldOfRow, kUse, foldNames] = make_loro_folds(recordingIds)
recordingIds = string(recordingIds(:));
[foldNames, ~, foldOfRow] = unique(recordingIds, 'stable');
kUse = numel(foldNames);
if kUse < 2
    foldOfRow = zeros(numel(recordingIds), 1);
    foldNames = strings(0, 1);
    kUse = 0;
end
end

function [foldOfRow, kUse] = make_group_folds(groupIds, y, kWanted)
y = double(y(:));
groupIds = string(groupIds(:));
[~, ~, groupIndex] = unique(groupIds, 'stable');
nGroups = max(groupIndex);
foldOfRow = zeros(numel(y), 1);
if nGroups < 2
    kUse = 0;
    return;
end

groupHasUsable = false(nGroups, 1);
for groupIdx = 1:nGroups
    groupHasUsable(groupIdx) = any(y(groupIndex == groupIdx) == 1);
end
nUsableGroups = nnz(groupHasUsable);
nRejectOnlyGroups = nnz(~groupHasUsable);
if nUsableGroups >= 2 && nRejectOnlyGroups >= 2
    kUse = min([kWanted, nUsableGroups, nRejectOnlyGroups, nGroups]);
else
    kUse = min(kWanted, nGroups);
end
if kUse < 2
    kUse = 0;
    return;
end

rng(1, 'twister');
foldByGroup = zeros(nGroups, 1);
if nUsableGroups >= 2 && nRejectOnlyGroups >= 2
    posGroups = find(groupHasUsable);
    negGroups = find(~groupHasUsable);
    posGroups = posGroups(randperm(numel(posGroups)));
    negGroups = negGroups(randperm(numel(negGroups)));
    for ii = 1:numel(posGroups)
        foldByGroup(posGroups(ii)) = 1 + mod(ii - 1, kUse);
    end
    for ii = 1:numel(negGroups)
        foldByGroup(negGroups(ii)) = 1 + mod(ii - 1, kUse);
    end
else
    groups = randperm(nGroups);
    for ii = 1:numel(groups)
        foldByGroup(groups(ii)) = 1 + mod(ii - 1, kUse);
    end
end
foldOfRow = foldByGroup(groupIndex);
end

function groupIds = row_group_ids(epochInfo, rows)
if ismember('group_id', epochInfo.Properties.VariableNames)
    groupIds = string(epochInfo.group_id(rows));
else
    groupIds = "row_" + string(find(rows));
end
groupIds = groupIds(:);
end

function recordingIds = row_recording_ids(epochInfo, rows)
if ismember('recording_id', epochInfo.Properties.VariableNames)
    recordingIds = string(epochInfo.recording_id(rows));
elseif ismember('group_id', epochInfo.Properties.VariableNames)
    gid = string(epochInfo.group_id(rows));
    recordingIds = extractBefore(gid, "|");
    missing = recordingIds == "";
    recordingIds(missing) = gid(missing);
else
    recordingIds = "recording_unknown";
    recordingIds = repmat(recordingIds, nnz(rows), 1);
end
recordingIds = recordingIds(:);
end

function T = metrics_by_recording(yTrue, yPred, recordingIds)
yTrue = double(yTrue(:));
yPred = double(yPred(:));
recordingIds = string(recordingIds(:));
valid = isfinite(yTrue) & isfinite(yPred) & strlength(recordingIds) > 0;
yTrue = yTrue(valid);
yPred = yPred(valid);
recordingIds = recordingIds(valid);
if isempty(yTrue)
    T = table();
    return;
end
ids = unique(recordingIds, 'stable');
n = numel(ids);
n_rows = zeros(n,1);
usable = zeros(n,1);
rejected = zeros(n,1);
acc = nan(n,1);
balanced_acc = nan(n,1);
usable_recall = nan(n,1);
reject_recall = nan(n,1);
precision = nan(n,1);
f1 = nan(n,1);
for ii = 1:n
    mask = recordingIds == ids(ii);
    m = classification_metrics(yTrue(mask), yPred(mask));
    n_rows(ii) = nnz(mask);
    usable(ii) = nnz(yTrue(mask) == 1);
    rejected(ii) = nnz(yTrue(mask) == 0);
    acc(ii) = m.acc;
    balanced_acc(ii) = m.balanced_acc;
    usable_recall(ii) = m.usable_recall;
    reject_recall(ii) = m.reject_recall;
    precision(ii) = m.precision;
    f1(ii) = m.f1;
end
recording_id = ids(:);
T = table(recording_id, n_rows, usable, rejected, acc, balanced_acc, ...
    usable_recall, reject_recall, precision, f1);
end

function models = train_pooled_model(d, models, model_kind, max_depth, k_folds, ...
    validation_mode, progress_fn, guard_overlap, featureNames)
% Train ONE ch1+ch2 scorer. lead_id is feature 1, so a tree ensemble can still
% branch per lead while sharing the lead-agnostic ECG-quality concept. The
% within-recording 80/20 held-out split is preserved; LORO-CV on the train
% split is the primary generalization metric. Per-lead views of this single
% model are written into models.by_lead so the existing report/CSV/exporter
% paths keep working and ch1.h / ch2.h export the identical pooled forest.
activeRows = ismember(double(d.epochInfo.combo_id), double(models.active_combo_ids));
labelledRows = activeRows & (d.y_final == 0 | d.y_final == 1);
split = strings(height(d.epochInfo), 1);
if ismember('split', d.epochInfo.Properties.VariableNames)
    split = string(d.epochInfo.split);
end
trainRows = labelledRows & split == "train";
testRows  = labelledRows & split == "test";
if nnz(trainRows) == 0
    trainRows = labelledRows;
    testRows = false(size(testRows));
end
if guard_overlap && nnz(testRows) > 0
    [trainRows, nDropped] = apply_overlap_guard(trainRows, testRows, d.epochInfo);
    if nDropped > 0
        fprintf('Overlap guard: dropped %d boundary train epochs overlapping the held-out test region.\n', nDropped);
    end
end

Xraw = double(d.X(trainRows, :));
y = double(d.y_final(trainRows));
groupIds = row_group_ids(d.epochInfo, trainRows);
recordingIds = row_recording_ids(d.epochInfo, trainRows);
leadIds = row_lead_ids(d.epochInfo, trainRows);
conditions = row_conditions(d.epochInfo, trainRows);
comboTxt = char(strjoin(string(models.active_combo_ids), ','));
fprintf('\nTraining POOLED MAS scorer (ch1+ch2 combined): %d train rows, %d recordings, usable=%d rejected=%d, combos=%s\n', ...
    size(Xraw,1), numel(unique(recordingIds)), sum(y==1), sum(y==0), comboTxt);
if nnz(testRows) > 0
    fprintf('Held-out test rows (within-recording 80/20): %d\n', nnz(testRows));
end

if size(Xraw,1) < 20 || numel(unique(y)) < 2
    warning('Pooled training skipped: not enough labelled rows or only one class.');
    return;
end

kinds = resolve_model_kinds(model_kind, size(Xraw, 1));
candidateResults = repmat(empty_candidate_result(""), 0, 1);
bestKind = "";
bestScore = -Inf;
for kindIdx = 1:numel(kinds)
    kind = kinds(kindIdx);
    if ~model_available(kind)
        result = empty_candidate_result(kind);
        result.status = "unavailable";
    else
        result = evaluate_candidate(kind, Xraw, y, groupIds, recordingIds, featureNames, ...
            max_depth, k_folds, validation_mode);
    end
    candidateResults(end+1, 1) = result; %#ok<AGROW>
    fprintf('  candidate %-9s: %s', result.kind, result.status);
    if isfinite(result.balanced_acc)
        fprintf(' | balanced %.1f%%, usable %.1f%%, reject %.1f%%', ...
            result.balanced_acc, result.usable_recall, result.reject_recall);
    end
    fprintf('\n');
    if ~isempty(progress_fn)
        try
            progress_fn("pooled", result, featureNames);
        catch
        end
    end
    if result.selection_score > bestScore
        bestScore = result.selection_score;
        bestKind = result.kind;
    end
end
if strlength(bestKind) == 0
    bestKind = "tree";
    warning('No pooled candidate validated; falling back to single tree.');
end

[X, imputeValues] = clean_features(Xraw);
finalModel = fit_candidate_model(bestKind, X, y, featureNames, max_depth);
featureImp = get_feature_importance(finalModel, bestKind, featureNames);
bestIdx = find([candidateResults.kind] == bestKind, 1);
finalCv = candidateResults(bestIdx);
fprintf('  selected pooled model: %s (%s)\n', model_display_name(bestKind), bestKind);

% LORO out-of-fold row predictions, aligned to the train-row order
loroTrue = finalCv.fold_y_true(:);
loroPred = finalCv.fold_y_pred(:);
if numel(loroTrue) ~= size(Xraw, 1) || numel(loroPred) ~= size(Xraw, 1)
    loroTrue = y(:);
    loroPred = nan(size(y(:)));
end

% Held-out test on the within-recording 20% tail
testMetrics = blank_metrics();
ytAll = [];
ptAll = [];
testLead = strings(0, 1);
testCond = strings(0, 1);
testRec = strings(0, 1);
if nnz(testRows) > 0
    Xt = clean_features(double(d.X(testRows, :)), imputeValues);
    yt = double(d.y_final(testRows));
    pt = predict_labels(finalModel, Xt);
    testMetrics = classification_metrics(yt, pt);
    try
        testMetrics.probs = predict_usable_prob(finalModel, Xt);
    catch
        testMetrics.probs = nan(size(yt));
    end
    testRec = row_recording_ids(d.epochInfo, testRows);
    testLead = row_lead_ids(d.epochInfo, testRows);
    testCond = row_conditions(d.epochInfo, testRows);
    testMetrics.y_true = yt(:);
    testMetrics.y_pred = pt(:);
    testMetrics.recording_ids = testRec;
    testMetrics.by_recording = metrics_by_recording(yt, pt, testRec);
    ytAll = yt(:);
    ptAll = pt(:);
    fprintf('  pooled held-out test: balanced %.1f%%, usable %.1f%%, reject %.1f%%\n', ...
        testMetrics.balanced_acc, testMetrics.usable_recall, testMetrics.reject_recall);
end

% Per-lead views: same pooled model, metrics sliced per lead so the existing
% summary/recording-CSV/export loop produce per-lead numbers and identical
% ch1.h / ch2.h headers.
leadNames = unique(leadIds, 'stable');
for li = 1:numel(leadNames)
    lead = leadNames(li);
    trMask = leadIds == lead;
    loroValid = trMask & isfinite(loroPred) & isfinite(loroTrue);
    leadCv = classification_metrics(loroTrue(loroValid), loroPred(loroValid));
    cvStruct = struct( ...
        'balanced_acc', leadCv.balanced_acc, ...
        'usable_recall', leadCv.usable_recall, ...
        'reject_recall', leadCv.reject_recall, ...
        'acc', leadCv.acc, ...
        'cm', leadCv.cm, ...
        'validation_mode', finalCv.validation_mode, ...
        'by_recording', metrics_by_recording(loroTrue(loroValid), loroPred(loroValid), recordingIds(loroValid)));
    leadTest = blank_metrics();
    if ~isempty(ytAll)
        teMask = testLead == lead;
        leadTest = classification_metrics(ytAll(teMask), ptAll(teMask));
        leadTest.by_recording = metrics_by_recording(ytAll(teMask), ptAll(teMask), testRec(teMask));
    end
    field = matlab.lang.makeValidName(char(lead));
    models.by_lead.(field) = struct( ...
        'lead', lead, ...
        'model_kind', bestKind, ...
        'model_name', model_display_name(bestKind) + " (pooled ch1+ch2)", ...
        'model', finalModel, ...
        'tree', finalModel, ...
        'impute_values', imputeValues, ...
        'cv', cvStruct, ...
        'validation_mode', finalCv.validation_mode, ...
        'candidate_results', candidateResults, ...
        'feature_importance', featureImp, ...
        'kfold_acc', leadCv.acc, ...
        'balanced_acc', leadCv.balanced_acc, ...
        'usable_recall', leadCv.usable_recall, ...
        'selected_recall', leadCv.usable_recall, ...
        'reject_recall', leadCv.reject_recall, ...
        'cm', leadCv.cm, ...
        'test', leadTest, ...
        'n_rows', nnz(trMask), ...
        'n_usable', nnz(trMask & y == 1), ...
        'n_rejected', nnz(trMask & y == 0));
end

% Pooled overall summary + per-condition breakdown for the report/CSV.
models.pooled = struct( ...
    'model_kind', bestKind, ...
    'model_name', model_display_name(bestKind), ...
    'balanced_acc', finalCv.balanced_acc, ...
    'usable_recall', finalCv.usable_recall, ...
    'reject_recall', finalCv.reject_recall, ...
    'test_balanced_acc', testMetrics.balanced_acc, ...
    'test_usable_recall', testMetrics.usable_recall, ...
    'test_reject_recall', testMetrics.reject_recall, ...
    'feature_importance', featureImp, ...
    'n_rows', size(Xraw, 1), ...
    'n_usable', sum(y == 1), ...
    'n_rejected', sum(y == 0), ...
    'guard_overlap', guard_overlap);
models.condition_summary = build_condition_summary(loroTrue, loroPred, leadIds, conditions, ...
    ytAll, ptAll, testLead, testCond);
end

function ids = row_lead_ids(epochInfo, rows)
ids = string(epochInfo.lead(rows));
ids = ids(:);
end

function conds = row_conditions(epochInfo, rows)
% Prefer the explicit condition column only if it actually varies. In the
% current labels it is a constant default ("walking" for every recording), so
% fall back to deriving the condition from the recording_id, which encodes it
% (e.g. R02_Standing_2min_... -> "Standing").
useCol = false;
if ismember('condition', epochInfo.Properties.VariableNames)
    allc = string(epochInfo.condition);
    useCol = numel(unique(allc(strlength(allc) > 0))) >= 2;
end
if useCol
    conds = string(epochInfo.condition(rows));
elseif ismember('recording_id', epochInfo.Properties.VariableNames)
    conds = arrayfun(@condition_from_recording, string(epochInfo.recording_id(rows)));
else
    conds = repmat("unknown", nnz(rows), 1);
end
conds = conds(:);
end

function c = condition_from_recording(rid)
% Strip the R## prefix and trailing duration/rec/timestamp tokens so the two
% resting and two bus recordings collapse into single condition buckets.
s = string(rid);
s = regexprep(s, '^R\d+_', '');
s = regexprep(s, '_\d{8}_\d{6}.*$', '');
s = regexprep(s, '_\d+min.*$', '');
s = regexprep(s, '_rec_\d+.*$', '');
s = regexprep(s, '_\d+$', '');
if strlength(s) == 0
    s = string(rid);
end
c = s;
end

function [trainRows, nDropped] = apply_overlap_guard(trainRows, testRows, epochInfo)
% Drop train epochs whose time window overlaps the start of the held-out test
% region of the same recording. With 1 s epochs and 0.5 s hop this removes the
% single boundary epoch that shares samples with the first test epoch, so the
% 80/20 split definition is unchanged but train/test no longer share samples.
nDropped = 0;
if ~ismember('epoch_start_s', epochInfo.Properties.VariableNames)
    return;
end
starts = double(epochInfo.epoch_start_s);
if ismember('epoch_sec', epochInfo.Properties.VariableNames)
    lens = double(epochInfo.epoch_sec);
else
    lens = ones(height(epochInfo), 1);
end
if ismember('recording_id', epochInfo.Properties.VariableNames)
    recs = string(epochInfo.recording_id);
else
    recs = repmat("recording_unknown", height(epochInfo), 1);
end
testRecs = unique(recs(testRows), 'stable');
for ri = 1:numel(testRecs)
    r = testRecs(ri);
    teMask = testRows & recs == r;
    if ~any(teMask); continue; end
    firstTestStart = min(starts(teMask));
    drop = trainRows & recs == r & (starts + lens) > (firstTestStart + 1e-9);
    nDropped = nDropped + nnz(drop);
    trainRows(drop) = false;
end
end

function T = build_condition_summary(loroTrue, loroPred, loroLead, loroCond, ...
    testTrue, testPred, testLead, testCond)
T = condition_rows("loro_cv", loroTrue, loroPred, loroLead, loroCond);
if ~isempty(testTrue)
    T = [T; condition_rows("heldout_test", testTrue, testPred, testLead, testCond)];
end
end

function T = condition_rows(phase, yTrue, yPred, leadIds, conds)
T = table();
yTrue = double(yTrue(:));
yPred = double(yPred(:));
leadIds = string(leadIds(:));
conds = string(conds(:));
valid = isfinite(yTrue) & isfinite(yPred);
yTrue = yTrue(valid); yPred = yPred(valid);
leadIds = leadIds(valid); conds = conds(valid);
if isempty(yTrue)
    return;
end
leadGroups = ["all"; unique(leadIds, 'stable')];
for li = 1:numel(leadGroups)
    lg = leadGroups(li);
    if lg == "all"
        lmask = true(size(yTrue));
    else
        lmask = leadIds == lg;
    end
    condList = unique(conds(lmask), 'stable');
    for ci = 1:numel(condList)
        cmask = lmask & conds == condList(ci);
        m = classification_metrics(yTrue(cmask), yPred(cmask));
        row = table(string(phase), lg, condList(ci), nnz(cmask), ...
            nnz(yTrue(cmask) == 1), nnz(yTrue(cmask) == 0), ...
            m.balanced_acc, m.usable_recall, m.reject_recall, ...
            'VariableNames', {'phase', 'lead', 'condition', 'n_rows', ...
            'usable', 'rejected', 'balanced_acc', 'usable_recall', 'reject_recall'});
        T = [T; row]; %#ok<AGROW>
    end
end
end

function [Xclean, fillVals] = clean_features(X, fillVals)
Xclean = double(X);
Xclean(~isfinite(Xclean)) = NaN;
if nargin < 2 || isempty(fillVals)
    fillVals = zeros(1, size(Xclean, 2));
    for colIdx = 1:size(Xclean, 2)
        vals = Xclean(:, colIdx);
        vals = vals(isfinite(vals));
        if isempty(vals)
            fillVals(colIdx) = 0;
        else
            fillVals(colIdx) = median(vals);
        end
    end
end
for colIdx = 1:size(Xclean, 2)
    bad = ~isfinite(Xclean(:, colIdx));
    Xclean(bad, colIdx) = fillVals(colIdx);
end
end

function p = predict_usable_prob(mdl, X)
% Returns P(usable=1) per row. Works for any model type:
%   SVM with Platt scaling: second column of scores is P(class=1)
%   Ensemble/tree: posteriors directly
%   logistic/lsvm (fitclinear): scores via predict second output
if isstruct(mdl) && isfield(mdl, 'type') && strcmp(mdl.type, 'zscore_wrapped')
    sig = mdl.sigma; sig(sig < 1e-10) = 1;
    X = (X - mdl.mu) ./ sig;
    mdl = mdl.inner;
end
[~, scores] = predict(mdl, X);
if isnumeric(scores) && size(scores, 2) == 2
    % standard two-class: columns ordered by mdl.ClassNames
    if isprop(mdl, 'ClassNames')
        cn = double(string(mdl.ClassNames));
    else
        cn = [0 1];
    end
    usableCol = find(cn == 1, 1);
    if isempty(usableCol); usableCol = 2; end
    p = scores(:, usableCol);
else
    p = double(scores(:));
end
p = double(p(:));
end

function imp = get_feature_importance(mdl, kind, featureNames)
imp = [];
innerMdl = mdl;
if isstruct(mdl) && isfield(mdl,'type') && strcmp(mdl.type,'zscore_wrapped')
    innerMdl = mdl.inner;
end
try
    switch lower(string(kind))
        case {'tree','bag','rusboost'}
            raw = predictorImportance(innerMdl);
            imp = raw(:)';
        case 'logistic'
            if isprop(innerMdl,'Beta') && ~isempty(innerMdl.Beta)
                raw = abs(innerMdl.Beta(:))';
                s = sum(raw);
                if s > 0; imp = 100 * raw / s; end
            end
    end
    if ~isempty(imp) && numel(imp) ~= numel(featureNames)
        imp = [];
    end
catch
    imp = [];
end
end

function names = normalize_feature_names(featureNames, nCols)
names = cellstr(string(featureNames(:)))';
if numel(names) ~= nCols
    names = cellstr("x" + string(1:nCols));
end
for ii = 1:numel(names)
    names{ii} = matlab.lang.makeValidName(names{ii});
end
end
