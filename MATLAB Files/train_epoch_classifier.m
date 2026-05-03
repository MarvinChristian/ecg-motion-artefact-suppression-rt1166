function model = train_epoch_classifier(feature_mat_path, max_depth, k_folds)
% TRAIN_EPOCH_CLASSIFIER   Train a decision tree to classify ECG epoch quality.
%
% Loads the feature matrix produced by extract_epoch_features, trains a
% classification tree, evaluates it with k-fold cross-validation, and
% compares it against the hard motion threshold baseline.
%
% Usage
% -----
%   model = train_epoch_classifier()
%   model = train_epoch_classifier('path/to/epoch_features.mat', 6, 5)
%
% Parameters
% ----------
%   feature_mat_path : path to epoch_features.mat from extract_epoch_features
%                      (default: auto-find latest in outputs/)
%   max_depth        : maximum tree depth                    [default: 6]
%   k_folds          : number of cross-validation folds      [default: 5]
%
% Outputs
% -------
%   model : struct with fields:
%     .tree         - trained ClassificationTree object
%     .featureNames - feature name cell array
%     .kfold_acc    - cross-validation accuracy
%     .kfold_sens   - cross-validation sensitivity (y=1 recall)
%     .kfold_spec   - cross-validation specificity (y=0 recall)
%     .cm           - confusion matrix (2x2, rows=actual, cols=predicted)
%     .vs_threshold - comparison table: classifier vs hard threshold baseline
%
% Classifier design choice: decision tree
% ----------------------------------------
%   A decision tree is selected over SVM or neural network for two reasons:
%   (1) Interpretability: the learned rules can be printed and discussed in
%       the thesis, making the classifier a transparent contribution rather
%       than a black box.
%   (2) Firmware portability: a trained decision tree can be exported as
%       C integer arrays (node_feature, node_thresh, node_left, node_right)
%       and executed in ~N_nodes comparisons with no floating-point library
%       beyond what is already used for feature computation. At depth 6 that
%       is at most 63 comparisons, well within the 600 MHz Cortex-M7 budget.
%       See export_tree_to_c.m for the export step.
%
%   A decision tree (MATLAB fitctree, CART-style induction, splits by Gini
%   impurity reduction) is used for interpretability and firmware portability.
%   Zhang et al. [2] benchmark decision-tree variants alongside SVM and Random
%   Forest for ECG quality assessment and confirm that tree-based classifiers
%   are competitive while remaining interpretable and computationally cheap.
%
% Cross-validation strategy
% -------------------------
%   Stratified k-fold cross-validation is used rather than a simple hold-out
%   split because the class distribution may be imbalanced across conditions.
%   MATLAB's cvpartition with 'Stratified' type preserves the class ratio in
%   each fold. k=5 folds gives 80/20 train/test splits with five independent
%   estimates of generalisation performance, following Arlot & Celisse [1].
%
% Comparison to hard threshold
% ----------------------------
%   The classifier is compared against the hard motion threshold at score >= 3
%   (the "risk" boundary used in evaluate_realtime_thresholds). This provides
%   a concrete answer to the thesis question: does learned feature weighting
%   improve over a fixed scalar threshold?
%
% References
% ----------
%   [1] S. Arlot, A. Celisse, "A survey of cross-validation procedures for
%       model selection," Statistics Surveys, vol. 4, pp. 40-79, 2010.
%       DOI: 10.1214/09-SS054
%   [2] Z. Zhang et al., "Comparing the Performance of Random Forest, SVM and
%       Their Variants for ECG Quality Assessment Combined with Nonlinear
%       Features," J. Med. Biol. Eng., vol. 39, no. 5, pp. 649-659, 2019.
%       DOI: 10.1007/s40846-018-0411-0

if nargin < 1 || isempty(feature_mat_path); feature_mat_path = ''; end
if nargin < 2 || isempty(max_depth);        max_depth = 6;          end
if nargin < 3 || isempty(k_folds);          k_folds   = 5;          end

% ── Load feature matrix ───────────────────────────────────────────────────────
if isempty(feature_mat_path)
    feature_mat_path = find_latest_feature_mat();
end

fprintf('Loading: %s\n', feature_mat_path);
loaded = load(feature_mat_path);
required = {'X','featureNames','epochInfo'};
for rr = 1:numel(required)
    if ~isfield(loaded, required{rr})
        error('Missing field "%s" in %s.', required{rr}, feature_mat_path);
    end
end
X            = loaded.X;
featureNames = loaded.featureNames;
epochInfo    = loaded.epochInfo;

if isfield(loaded, 'y_final')
    y = double(loaded.y_final(:));
    label_source = 'manual-reviewed y_final';
elseif isfield(loaded, 'y')
    y = double(loaded.y(:));
    label_source = 'auto y';
else
    error('Missing labels. Expected y or y_final in %s.', feature_mat_path);
end

valid_rows = isfinite(y) & (y == 0 | y == 1);
if ~all(valid_rows)
    fprintf('  Dropping %d rows with non-binary labels.\n', sum(~valid_rows));
    X = X(valid_rows, :);
    y = y(valid_rows);
    epochInfo = epochInfo(valid_rows, :);
end

fprintf('  Epochs loaded:  %d\n', size(X,1));
fprintf('  Features:       %d\n', size(X,2));
fprintf('  Label source:   %s\n', label_source);
fprintf('  y=1 (clean):    %d (%.1f%%)\n', sum(y==1), 100*mean(y==1));
fprintf('  y=0 (corrupted):%d (%.1f%%)\n\n', sum(y==0), 100*mean(y==0));
if strcmp(label_source, 'auto y')
    fprintf(['  NOTE: these are pseudo-labels. Very high accuracy can mean the tree\n', ...
             '        learned the pseudo-label rule. Use label_epoch_gui before final claims.\n\n']);
end

if size(X,1) < 20
    error('Too few epochs (%d) to train a classifier. Run extract_epoch_features first.', size(X,1));
end

% ── Train on full dataset ─────────────────────────────────────────────────────
% fitctree with MaxNumSplits = 2^max_depth - 1 produces a tree of the desired
% depth. MinLeafSize = 5 prevents single-sample leaves that overfit to
% recording-specific noise in the training set.
fprintf('Training decision tree (max depth=%d)...\n', max_depth);

tree = fitctree(X, y, ...
    'MaxNumSplits', 2^max_depth - 1, ...
    'MinLeafSize',  5, ...
    'PredictorNames', featureNames, ...
    'ResponseName',   'EpochLabel');

train_pred = predict(tree, X);
train_acc  = mean(train_pred == y) * 100;
fprintf('  Training accuracy: %.1f%%\n\n', train_acc);

% ── k-fold cross-validation ───────────────────────────────────────────────────
% Stratified partitioning preserves the y=1/y=0 ratio in each fold.
fprintf('Running %d-fold stratified cross-validation...\n', k_folds);

cv   = cvpartition(y, 'KFold', k_folds, 'Stratify', true);
cv_pred = zeros(size(y));

for fold = 1:k_folds
    tr_idx  = training(cv, fold);
    te_idx  = test(cv,     fold);

    fold_tree = fitctree(X(tr_idx,:), y(tr_idx), ...
        'MaxNumSplits', 2^max_depth - 1, ...
        'MinLeafSize',  5, ...
        'PredictorNames', featureNames, ...
        'ResponseName',   'EpochLabel');

    cv_pred(te_idx) = predict(fold_tree, X(te_idx,:));
end

cm = confusionmat(y, cv_pred);    % [2x2]: rows=actual (0,1), cols=predicted

% Sensitivity = recall for y=1 (clean epochs correctly identified)
% Specificity = recall for y=0 (corrupted epochs correctly identified)
TP = cm(2,2); FN = cm(2,1);
TN = cm(1,1); FP = cm(1,2);

kfold_acc  = 100 * (TP+TN) / sum(cm(:));
kfold_sens = 100 * TP / max(1, TP+FN);
kfold_spec = 100 * TN / max(1, TN+FP);

fprintf('\n%d-fold cross-validation results:\n', k_folds);
fprintf('  Accuracy:    %.1f%%\n', kfold_acc);
fprintf('  Sensitivity: %.1f%%  (clean epochs correctly passed)\n',     kfold_sens);
fprintf('  Specificity: %.1f%%  (corrupted epochs correctly rejected)\n', kfold_spec);
fprintf('\n  Confusion matrix (rows=actual, cols=predicted):\n');
fprintf('                pred y=0   pred y=1\n');
fprintf('  actual y=0   %6d     %6d\n', cm(1,1), cm(1,2));
fprintf('  actual y=1   %6d     %6d\n', cm(2,1), cm(2,2));

% ── Comparison: classifier vs hard motion threshold ───────────────────────────
% The hard threshold flags an epoch as corrupted when motion_score >= 3.
% This is the existing engineering rule evaluated in evaluate_realtime_thresholds.
% We compute the same four metrics for a direct apples-to-apples comparison.
fprintf('\nComparing against hard motion threshold (score >= 3)...\n');

motion_score_col = find(strcmpi(featureNames, 'motion_score'), 1);
if isempty(motion_score_col)
    warning('motion_score feature not found. Skipping threshold comparison.');
    vs_threshold = table();
else
    thresh_pred_clean   = double(X(:, motion_score_col) < 3);
    th_cm  = confusionmat(y, thresh_pred_clean);
    th_TP  = th_cm(2,2); th_FN = th_cm(2,1);
    th_TN  = th_cm(1,1); th_FP = th_cm(1,2);
    th_acc  = 100 * (th_TP+th_TN) / sum(th_cm(:));
    th_sens = 100 * th_TP / max(1, th_TP+th_FN);
    th_spec = 100 * th_TN / max(1, th_TN+th_FP);

    fprintf('  Hard threshold accuracy:    %.1f%%\n', th_acc);
    fprintf('  Hard threshold sensitivity: %.1f%%\n', th_sens);
    fprintf('  Hard threshold specificity: %.1f%%\n', th_spec);
    fprintf('\n');

    vs_threshold = table( ...
        {'Decision Tree (CV)'; 'Hard Threshold (>= 3)'}, ...
        [kfold_acc;  th_acc], ...
        [kfold_sens; th_sens], ...
        [kfold_spec; th_spec], ...
        'VariableNames', {'method','accuracy_pct','sensitivity_pct','specificity_pct'});

    fprintf('Summary comparison:\n');
    disp(vs_threshold);
end

% ── Feature importance ────────────────────────────────────────────────────────
imp = predictorImportance(tree);
[~, imp_order] = sort(imp, 'descend');

fprintf('Top-10 feature importances (Gini impurity reduction, full tree):\n');
for kk = 1:min(10, numel(imp_order))
    fprintf('  %2d. %-25s  %.4f\n', kk, featureNames{imp_order(kk)}, imp(imp_order(kk)));
end
fprintf('\n');

% ── Save outputs ──────────────────────────────────────────────────────────────
paths  = local_paths();
outDir = fullfile(paths.subrepo, 'outputs', ...
    char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
if ~exist(outDir, 'dir'); mkdir(outDir); end

model = struct();
model.tree          = tree;
model.featureNames  = featureNames;
model.epochInfo     = epochInfo;
model.label_source  = label_source;
model.max_depth     = max_depth;
model.kfold_acc     = kfold_acc;
model.kfold_sens    = kfold_sens;
model.kfold_spec    = kfold_spec;
model.cm            = cm;
model.vs_threshold  = vs_threshold;

save(fullfile(outDir, 'epoch_classifier.mat'), 'model');
if ~isempty(vs_threshold)
    writetable(vs_threshold, fullfile(outDir, 'classifier_vs_threshold.csv'));
end

% Print the tree rules for thesis documentation
view(tree, 'Mode', 'text');

fprintf('Model saved to:\n  %s\n', outDir);
fprintf('Run export_tree_to_c(model) to generate NXP firmware C arrays.\n');
end

% =============================================================================
% Helpers
% =============================================================================

function fpath = find_latest_feature_mat()
paths   = local_paths();
outRoot = fullfile(paths.subrepo, 'outputs');
if ~exist(outRoot, 'dir')
    error('No outputs folder found. Run extract_epoch_features first.');
end

d = dir(fullfile(outRoot, '**', 'epoch_features.mat'));
if isempty(d)
    error('No epoch_features.mat found in %s. Run extract_epoch_features first.', outRoot);
end

% Sort by folder name (timestamp format yyyyMMdd_HHmmss) — take latest.
[~, ix] = sort(string({d.folder}), 'descend');
fpath   = fullfile(d(ix(1)).folder, d(ix(1)).name);
fprintf('Auto-selected feature file: %s\n', fpath);
end

function paths = local_paths()
matlabDir      = fileparts(mfilename('fullpath'));
paths.repo     = fileparts(matlabDir);
paths.subrepo  = matlabDir;
paths.manifest = fullfile(paths.subrepo, 'config', 'ads1293_recording_manifest.csv');
end
