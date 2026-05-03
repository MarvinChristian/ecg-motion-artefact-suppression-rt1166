function result = run_ads1293_ml_pipeline(varargin)
% RUN_ADS1293_ML_PIPELINE Clean entry point for ADS1293 epoch ML work.
%
% Example:
%   result = run_ads1293_ml_pipeline( ...
%       'lead','ch1', 'bpf','B7', 'notch','N9', ...
%       'label_algorithm','hybrid', 'train',true);

p = inputParser;
addParameter(p, 'lead', 'ch1');
addParameter(p, 'bpf', 'B7');
addParameter(p, 'notch', 'N9');
addParameter(p, 'label_algorithm', 'kurtosis');
addParameter(p, 'epoch_sec', 0.500);
addParameter(p, 'hop_sec', 0.250);
addParameter(p, 'kurtosis_thresh', 5.0);
addParameter(p, 'motion_clean_thresh', 3.0);
addParameter(p, 'motion_corrupt_thresh', 8.0);
addParameter(p, 'manifest', 'ads1293_recording_manifest.csv');
addParameter(p, 'train', false);
addParameter(p, 'max_depth', 6);
addParameter(p, 'k_folds', 5);
parse(p, varargin{:});
opts = p.Results;

extractArgs = { ...
    'lead', opts.lead, ...
    'bpf', opts.bpf, ...
    'notch', opts.notch, ...
    'label_algorithm', opts.label_algorithm, ...
    'epoch_sec', opts.epoch_sec, ...
    'hop_sec', opts.hop_sec, ...
    'kurtosis_thresh', opts.kurtosis_thresh, ...
    'motion_clean_thresh', opts.motion_clean_thresh, ...
    'motion_corrupt_thresh', opts.motion_corrupt_thresh, ...
    'manifest', opts.manifest};

[X, y, featureNames, epochInfo] = extract_epoch_features(extractArgs{:});

result = struct();
result.X = X;
result.y = y;
result.featureNames = featureNames;
result.epochInfo = epochInfo;
result.feature_file = find_latest_epoch_features();
result.model = [];

if opts.train
    result.model = train_epoch_classifier(result.feature_file, opts.max_depth, opts.k_folds);
end
end

function fpath = find_latest_epoch_features()
matlabDir = fileparts(mfilename('fullpath'));
outRoot = fullfile(matlabDir, 'outputs');
d = dir(fullfile(outRoot, '**', 'epoch_features.mat'));
if isempty(d)
    fpath = '';
    return;
end
[~, ix] = sort(string({d.folder}), 'descend');
fpath = fullfile(d(ix(1)).folder, d(ix(1)).name);
end
