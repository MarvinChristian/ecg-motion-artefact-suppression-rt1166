function export_bag_to_c(model_source, lead_name, out_path)
% EXPORT_BAG_TO_C  Export a tree ensemble from mas_epoch_models.mat to a
%                  self-contained C header for NXP MIMXRT1166 firmware.
%
% Usage:
%   export_bag_to_c('path/mas_epoch_models.mat', 'CH1')
%   export_bag_to_c('path/mas_epoch_models.mat', 'CH2', 'out/mas_bag_ch2.h')
%   export_bag_to_c(models_struct, 'CH1')
%
%   If lead_name is omitted and the .mat contains only one lead, that lead
%   is used automatically.
%
% Output header defines (all symbols are prefixed with the lead name, e.g.
% mas_bag_ch1_* so CH1 and CH2 headers can be included in the same build):
%   MAS_BAG_CH1_N_TREES     number of trees
%   MAS_BAG_CH1_MAX_NODES   padded node count per tree
%   MAS_BAG_CH1_N_FEATURES  number of input features
%   mas_bag_ch1_feat[]      feature index at each node; -1 for leaf
%   mas_bag_ch1_thresh[]    split threshold; 0.0f for leaf
%   mas_bag_ch1_left[]      left child index (feat <= thresh); -1 for leaf
%   mas_bag_ch1_right[]     right child index (feat >  thresh); -1 for leaf
%   mas_bag_ch1_prob[]      positive-class probability at leaf nodes
%   mas_bag_ch1_weight[]    tree weights (all 1.0 for bagged trees)
%   mas_bag_ch1_impute[]    per-feature NaN fill values from training
%   mas_bag_ch1_impute(feat)   inline function: fill NaN slots before inference
%   mas_bag_ch1_classify_prob  inline function: returns a score in [0, 1]
%
% Firmware usage:
%   The Phase 4 two-stage path exports pooled "usability" and "selection"
%   headers. The usability score is P(clean) for the baseline candidate. The
%   selection score is P(use suppressed) for the lead-matched NLMS candidate.
%   Per-channel CH1/CH2 headers can still be exported for PHASE4_TWO_STAGE_DECISION=0.
%
% Inference example (NXP firmware):
%   #include "mas_bag_classifier_ch1.h"
%   float feat[MAS_BAG_CH1_N_FEATURES] = { ... };
%   mas_bag_ch1_impute(feat);
%   float p = mas_bag_ch1_classify_prob(feat);
%   int positive = (p >= 0.5f);
%
% Memory footprint:
%   Each tree padded to MAX_NODES (largest tree in ensemble).
%   Arrays stored per tree: feature index, threshold, left/right children,
%   leaf positive-class score, and one tree weight. The exporter prints the
%   estimated flash footprint after writing the header.
%
% Supports 'bag' and 'rusboost'. The C symbol prefix remains mas_bag_* for
% firmware compatibility with the existing Phase 4 code.

if nargin < 1 || isempty(model_source)
    [fn, fd] = uigetfile('*.mat', 'Select mas_epoch_models.mat');
    if isequal(fn, 0); return; end
    model_source = fullfile(fd, fn);
end

% Load the model structure.
if ischar(model_source) || isstring(model_source)
    d = load(char(model_source), 'models');
    models = d.models;
    default_dir = fileparts(char(model_source));
    if isempty(default_dir); default_dir = pwd; end
else
    models = model_source;
    default_dir = pwd;
end

% Resolve which lead/model to export.
if nargin < 2 || isempty(lead_name)
    leads = fieldnames(models.by_lead);
    if isscalar(leads)
        lead_name = leads{1};
    else
        error('Model contains multiple leads (%s). Specify lead_name.', strjoin(leads, ', '));
    end
end

field = matlab.lang.makeValidName(char(lead_name));
if ~isfield(models.by_lead, field)
    error('Lead "%s" not found. Available: %s', lead_name, ...
        strjoin(fieldnames(models.by_lead), ', '));
end

lead_struct = models.by_lead.(field);
kind = string(lead_struct.model_kind);
if ~ismember(lower(kind), ["bag", "rusboost"])
    error('Lead %s used model "%s". This exporter supports bag and RUSBoost tree ensembles.', ...
        lead_name, kind);
end

% Extract ensemble and feature metadata.
ens          = lead_struct.model;   % ClassificationBaggedEnsemble
featureNames = cellstr(models.featureNames);
nFeat        = numel(featureNames);
nTrees       = ens.NumTrained;
model_kind   = lower(string(kind));
scoreTransform = string(ens.ScoreTransform);
if ~strcmpi(scoreTransform, "none")
    error('Lead %s uses ScoreTransform "%s"; exporter currently supports untransformed tree-ensemble scores only.', ...
        lead_name, scoreTransform);
end

if strcmpi(model_kind, "rusboost")
    if ~strcmpi(string(ens.Method), "RUSBoost")
        error('Lead %s model_kind=rusboost but ensemble Method is "%s".', lead_name, string(ens.Method));
    end
    if ~strcmpi(string(ens.CombineWeights), "WeightedSum")
        error('Lead %s RUSBoost uses CombineWeights "%s"; expected WeightedSum.', ...
            lead_name, string(ens.CombineWeights));
    end
    tree_weights = double(ens.TrainedWeights(:)');
    model_label = 'RUSBoost weighted tree ensemble';
else
    if ~strcmpi(string(ens.Method), "Bag")
        error('Lead %s model_kind=bag but ensemble Method is "%s".', lead_name, string(ens.Method));
    end
    tree_weights = ones(1, nTrees);
    model_label = 'bagged Random Forest';
end
if numel(tree_weights) ~= nTrees || any(~isfinite(tree_weights)) || any(tree_weights < 0)
    error('Invalid tree weights for lead %s.', lead_name);
end
tree_weight_sum = sum(tree_weights);
if ~(isfinite(tree_weight_sum) && tree_weight_sum > 0)
    error('Tree weights for lead %s have non-positive sum.', lead_name);
end

% NaN imputation values used during training
impute_values = zeros(1, nFeat, 'double');
if isfield(lead_struct, 'impute_values') && ~isempty(lead_struct.impute_values)
    iv = double(lead_struct.impute_values(:)');
    n  = min(numel(iv), nFeat);
    impute_values(1:n) = iv(1:n);
end

% Column in ClassProb that corresponds to class 1 (usable)
class_names = ens.ClassNames;
if isnumeric(class_names)
    usable_col = find(class_names == 1, 1);
else
    usable_col = find(strcmp(cellstr(string(class_names)), '1'), 1);
end
if isempty(usable_col)
    error('Cannot locate class 1 (usable) in ensemble ClassNames.');
end

fprintf('Exporting %s for lead %s: %d trees, %d features.\n', model_label, lead_name, nTrees, nFeat);

% First pass: find the maximum node count across all trees.
nNodes_per_tree = zeros(nTrees, 1);
for t = 1:nTrees
    nNodes_per_tree(t) = numel(ens.Trained{t}.IsBranch);
end
maxNodes = max(nNodes_per_tree);
fprintf('  Node counts: min=%d, max=%d, mean=%.1f\n', ...
    min(nNodes_per_tree), maxNodes, mean(nNodes_per_tree));

% Allocate arrays [nTrees x maxNodes], row = tree, col = node.
% Defaults: feat=-1 (leaf sentinel), left=-1, right=-1, thresh=0, prob=0
feat_arr   = -ones(nTrees, maxNodes, 'int32');
thresh_arr =  zeros(nTrees, maxNodes, 'single');
left_arr   = -ones(nTrees, maxNodes, 'int32');
right_arr  = -ones(nTrees, maxNodes, 'int32');
prob_arr   =  zeros(nTrees, maxNodes, 'single');

for t = 1:nTrees
    tree_t   = ens.Trained{t};
    isBranch = tree_t.IsBranch;   % logical, length = nNodes for this tree
    nN       = numel(isBranch);

    for nn = 1:nN
        if isBranch(nn)
            % Branch: find split feature index and threshold
            var_name = tree_t.CutPredictor{nn};
            if isempty(var_name)
                continue;  % degenerate branch, leave as leaf sentinel
            end
            var_idx = find(strcmpi(featureNames, var_name), 1) - 1;  % 0-based
            if isempty(var_idx)
                error('Tree %d node %d: feature "%s" not in featureNames.', t, nn, var_name);
            end
            feat_arr(t, nn)   = int32(var_idx);
            thresh_arr(t, nn) = single(tree_t.CutPoint(nn));
            kids = tree_t.Children(nn, :);  % [left, right], 1-based; 0 = absent
            left_arr(t, nn)   = int32(kids(1) - 1);   % 0-based; -1 if no child
            right_arr(t, nn)  = int32(kids(2) - 1);
        else
            % Leaf: store MATLAB's positive-class probability.
            prob_arr(t, nn) = single(tree_t.ClassProb(nn, usable_col));
        end
    end
    % Nodes beyond nN stay at sentinel defaults (padded region)
end

% Resolve output path.
lead_suffix = lower(regexprep(char(lead_name), '[^a-zA-Z0-9]', '_'));
if nargin < 3 || isempty(out_path)
    out_path = fullfile(default_dir, sprintf('mas_bag_classifier_%s.h', lead_suffix));
end
[~, header_base, header_ext] = fileparts(char(out_path));
header_file = [header_base header_ext];

% C symbol naming.
P      = sprintf('mas_bag_%s', lead_suffix);   % firmware-compatible symbol prefix, e.g. mas_bag_ch1
GUARD  = upper(sprintf('%s_H', P));            % header guard

% CV metrics for header comment. In the decoupled workflow, class 1 is
% "clean" for usability and "use suppressed" for selection.
bal_acc = NaN; usable_rec = NaN; reject_rec = NaN;
if isfield(lead_struct, 'balanced_acc');  bal_acc    = lead_struct.balanced_acc;  end
if isfield(lead_struct, 'usable_recall'); usable_rec = lead_struct.usable_recall; end
if isfield(lead_struct, 'reject_recall'); reject_rec = lead_struct.reject_recall; end

% Write the C header.
fid = fopen(out_path, 'w');
if fid < 0; error('Cannot open: %s', out_path); end

fprintf(fid, '/*\n');
fprintf(fid, ' * %s\n', header_file);
fprintf(fid, ' *\n');
fprintf(fid, ' * MAS model scorer - %s, lead %s.\n', model_label, lead_name);
fprintf(fid, ' * Exported from the MATLAB training pipeline (export_bag_to_c.m).\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * Training summary:\n');
fprintf(fid, ' *   Lead:             %s\n', lead_name);
fprintf(fid, ' *   Model kind:       %s\n', char(model_kind));
fprintf(fid, ' *   Trees:            %d\n', nTrees);
fprintf(fid, ' *   Features:         %d\n', nFeat);
fprintf(fid, ' *   Weight sum:       %.8g\n', tree_weight_sum);
fprintf(fid, ' *   CV balanced acc:  %.1f%%\n', bal_acc);
fprintf(fid, ' *   CV class-1 recall: %.1f%%\n', usable_rec);
fprintf(fid, ' *   CV class-0 recall: %.1f%%\n', reject_rec);
fprintf(fid, ' *\n');
fprintf(fid, ' * Usage:\n');
fprintf(fid, ' *   #include "%s"\n', header_file);
fprintf(fid, ' *   float feat[%s_N_FEATURES] = { ... };\n', upper(P));
fprintf(fid, ' *   %s_impute(feat);                 // fill NaN slots\n', P);
fprintf(fid, ' *   float p = %s_classify_prob(feat); // 0.0-1.0\n', P);
fprintf(fid, ' *   int positive = (p >= 0.5f);\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * Inference cost (Cortex-M7 @ 600 MHz, %d trees, max %d nodes/tree):\n', nTrees, maxNodes);
fprintf(fid, ' *   ~%d tree traversals per call, each <=%d comparisons.\n', nTrees, ceil(log2(maxNodes+1)));
fprintf(fid, ' *   Estimated: <%d us per epoch candidate.\n', ceil(nTrees * ceil(log2(maxNodes+1)) / 600));
fprintf(fid, ' */\n\n');

fprintf(fid, '#ifndef %s\n', GUARD);
fprintf(fid, '#define %s\n\n', GUARD);
fprintf(fid, '#include <stdint.h>\n');
fprintf(fid, '#include <math.h>   /* isnan, nanf */\n\n');

fprintf(fid, '#define %s_N_TREES    %d\n', upper(P), nTrees);
fprintf(fid, '#define %s_MAX_NODES  %d\n', upper(P), maxNodes);
fprintf(fid, '#define %s_N_FEATURES %d\n\n', upper(P), nFeat);
fprintf(fid, '#define %s_WEIGHT_SUM %.8ef\n\n', upper(P), single(tree_weight_sum));

% Feature index map comment
fprintf(fid, '/* Feature index mapping (input order to %s_classify_prob):\n', P);
for ff = 0:nFeat-1
    fprintf(fid, ' *   [%2d]  %s\n', ff, featureNames{ff+1});
end
fprintf(fid, ' */\n\n');

% Feature-index array.
fprintf(fid, '/* feat[t * MAX_NODES + n]: feature index at node n of tree t; -1 = leaf */\n');
fprintf(fid, 'static const int16_t %s_feat[%s_N_TREES * %s_MAX_NODES] = {\n', P, upper(P), upper(P));
write_int_flat(fid, feat_arr, 12);
fprintf(fid, '};\n\n');

% Threshold array.
fprintf(fid, '/* thresh[t * MAX_NODES + n]: split threshold at node n of tree t */\n');
fprintf(fid, 'static const float %s_thresh[%s_N_TREES * %s_MAX_NODES] = {\n', P, upper(P), upper(P));
write_float_flat(fid, thresh_arr, 6);
fprintf(fid, '};\n\n');

% Left-child array.
fprintf(fid, '/* left[t * MAX_NODES + n]: left child index (feat <= thresh); -1 = leaf */\n');
fprintf(fid, 'static const int16_t %s_left[%s_N_TREES * %s_MAX_NODES] = {\n', P, upper(P), upper(P));
write_int_flat(fid, left_arr, 12);
fprintf(fid, '};\n\n');

% Right-child array.
fprintf(fid, '/* right[t * MAX_NODES + n]: right child index (feat > thresh); -1 = leaf */\n');
fprintf(fid, 'static const int16_t %s_right[%s_N_TREES * %s_MAX_NODES] = {\n', P, upper(P), upper(P));
write_int_flat(fid, right_arr, 12);
fprintf(fid, '};\n\n');

% Leaf-score array.
fprintf(fid, '/* prob[t * MAX_NODES + n]: positive-class score at leaf node n; 0.0f at branch */\n');
fprintf(fid, 'static const float %s_prob[%s_N_TREES * %s_MAX_NODES] = {\n', P, upper(P), upper(P));
write_float_flat(fid, prob_arr, 6);
fprintf(fid, '};\n\n');

% Tree weight array.
fprintf(fid, '/* weight[t]: ensemble weight for tree t; all 1.0 for bagged trees */\n');
fprintf(fid, 'static const float %s_weight[%s_N_TREES] = {\n    ', P, upper(P));
for tt = 1:nTrees
    if tt < nTrees
        fprintf(fid, '%.8ef, ', single(tree_weights(tt)));
    else
        fprintf(fid, '%.8ef', single(tree_weights(tt)));
    end
    if mod(tt, 6) == 0 && tt < nTrees
        fprintf(fid, '\n    ');
    end
end
fprintf(fid, '\n};\n\n');

% NaN-imputation array.
fprintf(fid, '/* impute[i]: median fill value for feature i from training data */\n');
fprintf(fid, 'static const float %s_impute_vals[%s_N_FEATURES] = {\n    ', P, upper(P));
for ff = 1:nFeat
    if ff < nFeat
        fprintf(fid, '%.8ef, ', single(impute_values(ff)));
    else
        fprintf(fid, '%.8ef', single(impute_values(ff)));
    end
    if mod(ff, 5) == 0 && ff < nFeat
        fprintf(fid, '\n    ');
    end
end
fprintf(fid, '\n};\n\n');

% Imputation inline function.
fprintf(fid, '/*\n');
fprintf(fid, ' * %s_impute - replace NaN entries with training medians.\n', P);
fprintf(fid, ' * Call this before %s_classify_prob on any feature vector\n', P);
fprintf(fid, ' * that may have missing values.\n');
fprintf(fid, ' */\n');
fprintf(fid, 'static inline void %s_impute(float *feat)\n', P);
fprintf(fid, '{\n');
fprintf(fid, '    for (int i = 0; i < %s_N_FEATURES; i++) {\n', upper(P));
fprintf(fid, '        if (isnan(feat[i])) feat[i] = %s_impute_vals[i];\n', P);
fprintf(fid, '    }\n');
fprintf(fid, '}\n\n');

% Inference inline function.
fprintf(fid, '/*\n');
fprintf(fid, ' * %s_classify_prob - run %s inference.\n', P, model_label);
fprintf(fid, ' *\n');
fprintf(fid, ' * feat: float array of length %s_N_FEATURES in the order\n', upper(P));
fprintf(fid, ' *       listed in the feature index mapping above.\n');
fprintf(fid, ' *       Call %s_impute(feat) first if NaN values are possible.\n', P);
fprintf(fid, ' *\n');
fprintf(fid, ' * Returns: weighted positive-class score across all %d trees, range [0, 1].\n', nTrees);
fprintf(fid, ' *          >= 0.5 is the default positive-class threshold.\n');
fprintf(fid, ' */\n');
fprintf(fid, 'static inline float %s_classify_prob(const float *feat)\n', P);
fprintf(fid, '{\n');
fprintf(fid, '    float prob_sum = 0.0f;\n');
fprintf(fid, '    for (int t = 0; t < %s_N_TREES; t++) {\n', upper(P));
fprintf(fid, '        int base = t * %s_MAX_NODES;\n', upper(P));
fprintf(fid, '        int node = 0;\n');
fprintf(fid, '        while (%s_left[base + node] != -1) {\n', P);
fprintf(fid, '            int fi = (int)%s_feat[base + node];\n', P);
fprintf(fid, '            if (feat[fi] <= %s_thresh[base + node])\n', P);
fprintf(fid, '                node = (int)%s_left[base + node];\n', P);
fprintf(fid, '            else\n');
fprintf(fid, '                node = (int)%s_right[base + node];\n', P);
fprintf(fid, '        }\n');
fprintf(fid, '        prob_sum += %s_weight[t] * %s_prob[base + node];\n', P, P);
fprintf(fid, '    }\n');
fprintf(fid, '    return prob_sum / %s_WEIGHT_SUM;\n', upper(P));
fprintf(fid, '}\n\n');

fprintf(fid, '#endif /* %s */\n', GUARD);
fclose(fid);

fprintf('\nC header written to:\n  %s\n', out_path);
fprintf('  Trees:     %d\n', nTrees);
fprintf('  Max nodes: %d\n', maxNodes);
fprintf('  Features:  %d\n', nFeat);
fprintf('  Flash est: ~%d KB\n', round((nTrees * maxNodes * (2+4+2+2+4) + nTrees * 4) / 1024));
end

% =============================================================================
% Array write helpers - row-major: tree index is outer, node index is inner
% =============================================================================

function write_int_flat(fid, arr, cols_per_line)
% arr is [nTrees x maxNodes]. Write row-major as int16 values.
[nT, nN] = size(arr);
total = nT * nN;
idx = 0;
for t = 1:nT
    for n = 1:nN
        idx = idx + 1;
        if mod(idx - 1, cols_per_line) == 0
            fprintf(fid, '    ');
        end
        if idx < total
            fprintf(fid, '%d, ', int16(arr(t, n)));
        else
            fprintf(fid, '%d', int16(arr(t, n)));
        end
        if mod(idx, cols_per_line) == 0
            fprintf(fid, '\n');
        end
    end
end
if mod(total, cols_per_line) ~= 0
    fprintf(fid, '\n');
end
end

function write_float_flat(fid, arr, cols_per_line)
% arr is [nTrees x maxNodes]. Write row-major as float32 literals.
[nT, nN] = size(arr);
total = nT * nN;
idx = 0;
for t = 1:nT
    for n = 1:nN
        idx = idx + 1;
        if mod(idx - 1, cols_per_line) == 0
            fprintf(fid, '    ');
        end
        if idx < total
            fprintf(fid, '%.8ef, ', single(arr(t, n)));
        else
            fprintf(fid, '%.8ef', single(arr(t, n)));
        end
        if mod(idx, cols_per_line) == 0
            fprintf(fid, '\n');
        end
    end
end
if mod(total, cols_per_line) ~= 0
    fprintf(fid, '\n');
end
end
