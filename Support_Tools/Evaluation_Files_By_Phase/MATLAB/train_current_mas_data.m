function models = train_current_mas_data(label_mat_path, varargin)
% TRAIN_CURRENT_MAS_DATA One-command trainer for the current MAS ML iteration.
%
% Usage:
%   addpath('Support_Tools/Evaluation_Files_By_Phase/MATLAB');
%   models = train_current_mas_data;
%   models = train_current_mas_data('...\revised_mas_labels.mat');
%   models = train_current_mas_data(labelPath, 'model_kind','auto_full');
%
% This trains the two-candidate fixed-vs-lead-matched RA-pair NLMS usable-candidate scorers,
% writes summary artifacts beside the labels, and exports bagged-tree firmware
% headers when a lead's selected model is exportable.

opts = parse_options(varargin{:});
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
pipelineDir = support_pipeline_matlab_dir(thisDir);
if isfolder(pipelineDir)
    addpath(pipelineDir);
end

if nargin < 1 || isempty(label_mat_path)
    label_mat_path = latest_revised_labels(thisDir);
    if strlength(label_mat_path) == 0
        [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat');
        if isequal(fn, 0)
            models = struct();
            return;
        end
        label_mat_path = fullfile(fd, fn);
    end
end

label_mat_path = char(label_mat_path);

% Pooled mode trains one ch1+ch2 model; force an exportable bag unless the
% caller explicitly asked for another kind.
if opts.pooled && strcmpi(opts.model_kind, "auto")
    opts.model_kind = "bag";
end

fprintf('Training current MAS ML data from:\n  %s\n', label_mat_path);
fprintf('Policy: combo 1 fixed BPF+Notch, combo 5 lead-matched BPF+Notch+NLMS (CH1 RA+LA, CH2 RA+LL), corrupted rejects both.\n');
if opts.pooled
    fprintf('Training mode: POOLED single ch1+ch2 model (lead_id is feature 1), overlap_guard=%d\n', opts.guard_overlap);
else
    fprintf('Training mode: per-lead (separate CH1/CH2 models)\n');
end
fprintf('Model search: %s, validation=%s, max_depth=%d, folds=%d\n\n', ...
    char(opts.model_kind), char(opts.validation), opts.max_depth, opts.k_folds);

models = train_mas_epoch_models(label_mat_path, opts.model_kind, opts.max_depth, opts.k_folds, ...
    'validation', opts.validation, 'pooled', opts.pooled, 'guard_overlap', opts.guard_overlap);
artifacts = write_mas_training_artifacts(models, label_mat_path, ...
    'export_bag', opts.export_bag, ...
    'export_dir', opts.export_dir);

fprintf('\nTraining artifacts:\n');
fprintf('  %s\n', char(artifacts.report_path));
fprintf('  %s\n', char(artifacts.summary_csv));
if isfield(artifacts, 'recording_csv') && strlength(artifacts.recording_csv) > 0
    fprintf('  %s\n', char(artifacts.recording_csv));
end
if isfield(artifacts, 'split_csv') && strlength(artifacts.split_csv) > 0
    fprintf('  %s\n', char(artifacts.split_csv));
end
if isfield(artifacts, 'condition_csv') && strlength(artifacts.condition_csv) > 0
    fprintf('  %s\n', char(artifacts.condition_csv));
end
for ii = 1:numel(artifacts.exported_headers)
    fprintf('  exported %s\n', char(artifacts.exported_headers(ii)));
end
if isempty(artifacts.exported_headers)
    if opts.export_bag
        fprintf('  no firmware headers exported because no selected lead model was bagged trees.\n');
    else
        fprintf('  firmware header export disabled (export=false).\n');
    end
end
end

function opts = parse_options(varargin)
opts = struct();
opts.model_kind = "auto";
opts.max_depth = 5;
opts.k_folds = 5;
opts.validation = "loro";
opts.export_bag = true;
opts.export_dir = default_firmware_source_dir();
opts.pooled = false;
opts.guard_overlap = true;
if mod(numel(varargin), 2) ~= 0
    error('Options must be name/value pairs.');
end
for ii = 1:2:numel(varargin)
    name = lower(string(varargin{ii}));
    val = varargin{ii + 1};
    switch name
        case {"model","model_kind","kind"}
            opts.model_kind = string(val);
        case {"max_depth","depth"}
            opts.max_depth = max(1, round(double(val)));
        case {"k_folds","folds","cv"}
            opts.k_folds = max(2, round(double(val)));
        case {"validation","validation_mode","cv_mode"}
            opts.validation = lower(string(val));
        case {"export","export_bag","export_headers"}
            opts.export_bag = logical(val);
        case {"export_dir","firmware_dir","source_dir"}
            opts.export_dir = char(string(val));
        case {"pooled","pool","single_model","combined"}
            opts.pooled = logical(val);
        case {"guard_overlap","overlap_guard","guard","drop_overlap"}
            opts.guard_overlap = logical(val);
        otherwise
            error('Unknown option "%s".', name);
    end
end
end

function labelPath = latest_revised_labels(thisDir)
repo = repo_root_from_current_dir(thisDir);
pipelineDir = support_pipeline_matlab_dir(thisDir);
roots = { ...
    fullfile(repo, 'MATLAB Files', 'Current_MAS_ML_Iteration', 'outputs'), ...
    fullfile(repo, 'MATLAB Files', 'Current_MAS_ML_Iteration'), ...
    fullfile(pipelineDir, 'outputs')};
hits = [];
for ii = 1:numel(roots)
    if isfolder(roots{ii})
        hits = [hits; dir(fullfile(roots{ii}, '**', 'revised_mas_labels.mat'))]; %#ok<AGROW>
    end
end
if isempty(hits)
    labelPath = "";
    return;
end
[~, ix] = max([hits.datenum]);
labelPath = string(fullfile(hits(ix).folder, hits(ix).name));
end

function outDir = default_firmware_source_dir()
thisDir = fileparts(mfilename('fullpath'));
repo = repo_root_from_current_dir(thisDir);
candidate = fullfile(repo, 'source');
if isfolder(candidate)
    outDir = candidate;
else
    outDir = thisDir;
end
end

function repo = repo_root_from_current_dir(thisDir)
repo = char(thisDir);
for ii = 1:8
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

function pipelineDir = support_pipeline_matlab_dir(thisDir)
repo = repo_root_from_current_dir(thisDir);
pipelineDir = fullfile(repo, 'Support_Tools', 'Final_Pipeline_Files', 'MATLAB');
end
