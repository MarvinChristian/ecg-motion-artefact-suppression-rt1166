function export_tree_to_c(model_or_path, out_path)
% EXPORT_TREE_TO_C   Export a trained MATLAB ClassificationTree to C arrays.
%
% Traverses the decision tree and writes a self-contained C header that can
% be compiled into the NXP MIMXRT1166 firmware without any external library.
%
% Usage
% -----
%   export_tree_to_c(model)              % model from train_epoch_classifier
%   export_tree_to_c('path/epoch_classifier.mat')
%   export_tree_to_c(model, 'epoch_classifier.h')
%
% Parameters
% ----------
%   model_or_path : model struct from train_epoch_classifier, OR path to
%                   the epoch_classifier.mat file saved by that function
%   out_path      : output .h file path  [default: auto, written to outputs/]
%
% Output file
% -----------
%   A C header defining:
%     EPOCH_TREE_N_NODES    total node count
%     EPOCH_TREE_N_FEATURES number of input features
%     epoch_tree_feature[]  feature index at each node (-1 for leaf nodes)
%     epoch_tree_thresh[]   split threshold at each node (0.0 for leaves)
%     epoch_tree_left[]     child index when feature <= threshold (-1 = leaf)
%     epoch_tree_right[]    child index when feature >  threshold (-1 = leaf)
%     epoch_tree_class[]    predicted class (0/1) at leaf nodes (0 otherwise)
%
% Inference on NXP firmware
% -------------------------
%   The exported arrays support a simple recursive-free traversal loop:
%
%     int classify_epoch(const float *features) {
%         int node = 0;
%         while (epoch_tree_left[node] != -1) {
%             if (features[epoch_tree_feature[node]] <= epoch_tree_thresh[node])
%                 node = epoch_tree_left[node];
%             else
%                 node = epoch_tree_right[node];
%         }
%         return epoch_tree_class[node];
%     }
%
%   This loop executes at most max_depth comparisons per call. At depth 6
%   that is at most 6 comparisons. With the Cortex-M7 FPU at 600 MHz and
%   DTCM latency of ~1 cycle, inference time is well under 1 microsecond.
%   The full feature computation (~17 float operations per epoch) dominates
%   the per-epoch CPU cost, not the tree traversal.
%
% Memory footprint
% ----------------
%   A depth-6 tree has at most 127 nodes (2^7 - 1). Each node stores one
%   int16 (feature index), one float32 (threshold), and two int16 (children)
%   plus one uint8 (class). That is approximately 127 * 11 bytes = ~1.4 KB,
%   well within the 2 MB SRAM of the MIMXRT1166.
%
% References
% ----------
%   [1] NXP Semiconductors, "MIMXRT1166 Processor Reference Manual,"
%       Rev. 1, 2021. Sec. 4 (DTCM), Sec. 11 (FPU).

if nargin < 1 || isempty(model_or_path)
    model_or_path = find_latest_classifier_mat();
end

% Accept path string or already-loaded struct.
if ischar(model_or_path) || isstring(model_or_path)
    loaded       = load(char(model_or_path), 'model');
    model        = loaded.model;
else
    model = model_or_path;
end

tree         = model.tree;
featureNames = model.featureNames;
nFeat        = numel(featureNames);

% ── Extract tree structure from MATLAB ClassificationTree ─────────────────────
% MATLAB stores the tree internally with NaN thresholds at leaf nodes and
% child indices of 0 for absent children. We remap to -1 for firmware clarity.

nodes  = tree.IsBranch;         % logical vector: true = branch, false = leaf
nNodes = numel(nodes);

feat_idx  = zeros(nNodes, 1, 'int16');   % feature index (0-based)
thresh    = zeros(nNodes, 1, 'single');   % split threshold
left_ch   = -ones(nNodes, 1, 'int16');   % left child index (feature <= thresh)
right_ch  = -ones(nNodes, 1, 'int16');   % right child index (feature > thresh)
class_out = zeros(nNodes, 1, 'uint8');   % predicted class at leaf

for nn = 1:nNodes
    if nodes(nn)
        % Branch node: has a split variable and threshold.
        var_name        = tree.CutPredictorNames{nn};
        var_idx         = find(strcmpi(featureNames, var_name), 1) - 1;   % 0-based
        if isempty(var_idx)
            error('Feature "%s" from tree node %d not found in featureNames.', var_name, nn);
        end
        feat_idx(nn)  = int16(var_idx);
        thresh(nn)    = single(tree.CutPoint(nn));

        children        = tree.Children(nn,:);   % [left_child, right_child], 1-based
        left_ch(nn)   = int16(children(1) - 1);  % convert to 0-based index
        right_ch(nn)  = int16(children(2) - 1);
    else
        % Leaf node: no split. Class is the majority class.
        leaf_classes   = tree.ClassNames;
        node_class_idx = tree.ClassProb(nn,:);
        [~, ci]        = max(node_class_idx);
        class_out(nn)  = uint8(str2double(leaf_classes{ci}));
        feat_idx(nn)  = int16(-1);
    end
end

% ── Determine output path ─────────────────────────────────────────────────────
if nargin < 2 || isempty(out_path)
    paths   = local_paths();
    outDir  = fullfile(paths.subrepo, 'outputs', ...
        char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
    if ~exist(outDir, 'dir'); mkdir(outDir); end
    out_path = fullfile(outDir, 'epoch_classifier.h');
end

% ── Write C header ────────────────────────────────────────────────────────────
fid = fopen(out_path, 'w');
if fid < 0
    error('Could not open output file: %s', out_path);
end

fprintf(fid, '/*\n');
fprintf(fid, ' * epoch_classifier.h\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * Motion-aware ECG epoch quality classifier — decision tree.\n');
fprintf(fid, ' * Generated from MATLAB train_epoch_classifier.m\n');
fprintf(fid, ' * Generated: %s\n', char(datetime('now')));
fprintf(fid, ' *\n');
fprintf(fid, ' * Usage:\n');
fprintf(fid, ' *   #include "epoch_classifier.h"\n');
fprintf(fid, ' *   int label = epoch_classify(features);   // 1=clean, 0=corrupted\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * Training summary:\n');
fprintf(fid, ' *   CV accuracy:    %.1f%%\n', model.kfold_acc);
fprintf(fid, ' *   CV sensitivity: %.1f%%\n', model.kfold_sens);
fprintf(fid, ' *   CV specificity: %.1f%%\n', model.kfold_spec);
fprintf(fid, ' *   Tree depth:     %d\n',     model.max_depth);
fprintf(fid, ' *   Nodes:          %d\n',     nNodes);
fprintf(fid, ' */\n\n');

fprintf(fid, '#ifndef EPOCH_CLASSIFIER_H\n');
fprintf(fid, '#define EPOCH_CLASSIFIER_H\n\n');

fprintf(fid, '#include <stdint.h>\n\n');

fprintf(fid, '#define EPOCH_TREE_N_NODES    %d\n', nNodes);
fprintf(fid, '#define EPOCH_TREE_N_FEATURES %d\n\n', nFeat);

% Feature index → feature name mapping as comments
fprintf(fid, '/* Feature index mapping (input to epoch_classify):\n');
for ff = 0:nFeat-1
    fprintf(fid, ' *   [%2d]  %s\n', ff, featureNames{ff+1});
end
fprintf(fid, ' */\n\n');

% feat_idx array
fprintf(fid, '/* feat_idx[n]: feature index split at node n; -1 for leaf nodes */\n');
fprintf(fid, 'static const int16_t epoch_tree_feature[EPOCH_TREE_N_NODES] = {\n');
write_int16_array(fid, feat_idx);
fprintf(fid, '};\n\n');

% thresh array
fprintf(fid, '/* thresh[n]: split threshold at node n; 0.0f for leaf nodes */\n');
fprintf(fid, 'static const float epoch_tree_thresh[EPOCH_TREE_N_NODES] = {\n');
write_float_array(fid, thresh);
fprintf(fid, '};\n\n');

% left_ch array
fprintf(fid, '/* left[n]:  child node index when feature[feat_idx[n]] <= thresh[n]; -1 = leaf */\n');
fprintf(fid, 'static const int16_t epoch_tree_left[EPOCH_TREE_N_NODES] = {\n');
write_int16_array(fid, left_ch);
fprintf(fid, '};\n\n');

% right_ch array
fprintf(fid, '/* right[n]: child node index when feature[feat_idx[n]] >  thresh[n]; -1 = leaf */\n');
fprintf(fid, 'static const int16_t epoch_tree_right[EPOCH_TREE_N_NODES] = {\n');
write_int16_array(fid, right_ch);
fprintf(fid, '};\n\n');

% class_out array
fprintf(fid, '/* class[n]: predicted label at leaf node n; 0 at branch nodes */\n');
fprintf(fid, 'static const uint8_t epoch_tree_class[EPOCH_TREE_N_NODES] = {\n');
write_uint8_array(fid, class_out);
fprintf(fid, '};\n\n');

% Inference function — inline so the compiler can optimise the loop
fprintf(fid, '/*\n');
fprintf(fid, ' * epoch_classify - run decision tree inference.\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * features: pointer to float array of length EPOCH_TREE_N_FEATURES.\n');
fprintf(fid, ' *           Feature order matches the index mapping above.\n');
fprintf(fid, ' * Returns: 1 if the epoch is classified as ECG-acceptable,\n');
fprintf(fid, ' *          0 if the epoch is classified as ECG-corrupted.\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * The loop executes at most max_depth comparisons. At depth %d\n', model.max_depth);
fprintf(fid, ' * that is %d comparisons per call, well under 1 us at 600 MHz.\n', model.max_depth);
fprintf(fid, ' */\n');
fprintf(fid, 'static inline int epoch_classify(const float *features)\n');
fprintf(fid, '{\n');
fprintf(fid, '    int node = 0;\n');
fprintf(fid, '    while (epoch_tree_left[node] != -1) {\n');
fprintf(fid, '        if (features[epoch_tree_feature[node]] <= epoch_tree_thresh[node])\n');
fprintf(fid, '            node = epoch_tree_left[node];\n');
fprintf(fid, '        else\n');
fprintf(fid, '            node = epoch_tree_right[node];\n');
fprintf(fid, '    }\n');
fprintf(fid, '    return (int)epoch_tree_class[node];\n');
fprintf(fid, '}\n\n');

fprintf(fid, '#endif /* EPOCH_CLASSIFIER_H */\n');
fclose(fid);

fprintf('C header written to:\n  %s\n\n', out_path);
fprintf('Nodes:    %d\n', nNodes);
fprintf('Features: %d\n', nFeat);
fprintf('Include in firmware as:\n');
fprintf('  #include "epoch_classifier.h"\n');
fprintf('  int ok = epoch_classify(feature_buf);\n');
end

% =============================================================================
% Array formatting helpers
% =============================================================================

function write_int16_array(fid, v)
cols = 12;
for ii = 1:numel(v)
    if mod(ii-1, cols) == 0
        fprintf(fid, '    ');
    end
    if ii < numel(v)
        fprintf(fid, '%d, ', v(ii));
    else
        fprintf(fid, '%d',   v(ii));
    end
    if mod(ii, cols) == 0
        fprintf(fid, '\n');
    end
end
if mod(numel(v), cols) ~= 0
    fprintf(fid, '\n');
end
end

function write_float_array(fid, v)
cols = 6;
for ii = 1:numel(v)
    if mod(ii-1, cols) == 0
        fprintf(fid, '    ');
    end
    if ii < numel(v)
        fprintf(fid, '%.8ef, ', v(ii));
    else
        fprintf(fid, '%.8ef',   v(ii));
    end
    if mod(ii, cols) == 0
        fprintf(fid, '\n');
    end
end
if mod(numel(v), cols) ~= 0
    fprintf(fid, '\n');
end
end

function write_uint8_array(fid, v)
cols = 20;
for ii = 1:numel(v)
    if mod(ii-1, cols) == 0
        fprintf(fid, '    ');
    end
    if ii < numel(v)
        fprintf(fid, '%d, ', v(ii));
    else
        fprintf(fid, '%d',   v(ii));
    end
    if mod(ii, cols) == 0
        fprintf(fid, '\n');
    end
end
if mod(numel(v), cols) ~= 0
    fprintf(fid, '\n');
end
end

% =============================================================================
% Path helpers
% =============================================================================

function fpath = find_latest_classifier_mat()
paths   = local_paths();
outRoot = fullfile(paths.subrepo, 'outputs');
d = dir(fullfile(outRoot, '**', 'epoch_classifier.mat'));
if isempty(d)
    error('No epoch_classifier.mat found. Run train_epoch_classifier first.');
end
[~, ix] = sort({d.folder}, 'descend');
fpath   = fullfile(d(ix(1)).folder, d(ix(1)).name);
fprintf('Auto-selected classifier: %s\n', fpath);
end

function paths = local_paths()
matlabDir      = fileparts(mfilename('fullpath'));
paths.repo     = fileparts(matlabDir);
paths.subrepo  = matlabDir;
paths.manifest = fullfile(paths.subrepo, 'config', 'ads1293_recording_manifest.csv');
end
