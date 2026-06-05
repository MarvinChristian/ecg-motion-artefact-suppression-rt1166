function artifacts = write_mas_training_artifacts(models, label_mat_path, varargin)
% WRITE_MAS_TRAINING_ARTIFACTS Save reports and optional firmware headers.
%
% This is intentionally separate from train_mas_epoch_models so it can be used
% from the GUI and from train_current_mas_data.

opts = parse_options(varargin{:});
outDir = fileparts(char(label_mat_path));
if isempty(outDir)
    outDir = pwd;
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

summary = model_summary_table(models);
summary_csv = fullfile(outDir, 'mas_training_summary.csv');
writetable(summary, summary_csv);

recordingSummary = recording_summary_table(models);
recording_csv = "";
if ~isempty(recordingSummary)
    recording_csv = fullfile(outDir, 'mas_recording_performance.csv');
    writetable(recordingSummary, recording_csv);
end

split_csv = "";
if isfield(models, 'split_summary') && istable(models.split_summary) && ~isempty(models.split_summary)
    split_csv = fullfile(outDir, 'mas_split_summary.csv');
    writetable(models.split_summary, split_csv);
end

condition_csv = "";
if isfield(models, 'condition_summary') && istable(models.condition_summary) && ~isempty(models.condition_summary)
    condition_csv = fullfile(outDir, 'mas_condition_performance.csv');
    writetable(models.condition_summary, condition_csv);
end

report_path = fullfile(outDir, 'mas_training_report.txt');
write_text_report(report_path, models, label_mat_path, summary, recordingSummary);

exported = strings(0, 1);
if opts.export_bag
    if ~exist(opts.export_dir, 'dir')
        mkdir(opts.export_dir);
    end
    leads = fieldnames(models.by_lead);
    for ii = 1:numel(leads)
        leadStruct = models.by_lead.(leads{ii});
        if ~isfield(leadStruct, 'model_kind') || ...
                ~ismember(lower(string(leadStruct.model_kind)), ["bag", "rusboost"])
            continue;
        end
        leadName = string(leadStruct.lead);
        outName = sprintf('mas_bag_classifier_%s.h', lower(char(leadName)));
        outPath = fullfile(opts.export_dir, outName);
        export_bag_to_c(models, leadName, outPath);
        exported(end+1, 1) = string(outPath); %#ok<AGROW>
    end
end

artifacts = struct();
artifacts.report_path = string(report_path);
artifacts.summary_csv = string(summary_csv);
artifacts.recording_csv = string(recording_csv);
artifacts.split_csv = string(split_csv);
artifacts.condition_csv = string(condition_csv);
artifacts.exported_headers = exported;
end

function opts = parse_options(varargin)
opts = struct();
opts.export_bag = true;
opts.export_dir = default_firmware_source_dir();
if mod(numel(varargin), 2) ~= 0
    error('Options must be name/value pairs.');
end
for ii = 1:2:numel(varargin)
    name = lower(string(varargin{ii}));
    val = varargin{ii + 1};
    switch name
        case {"export","export_bag","export_headers"}
            opts.export_bag = logical(val);
        case {"export_dir","firmware_dir","source_dir"}
            opts.export_dir = char(string(val));
        otherwise
            error('Unknown option "%s".', name);
    end
end
end

function T = model_summary_table(models)
if ~isstruct(models) || ~isfield(models, 'by_lead')
    T = table();
    return;
end
leads = fieldnames(models.by_lead);
n = numel(leads);
lead = strings(n, 1);
model_kind = strings(n, 1);
model_name = strings(n, 1);
validation_mode = strings(n, 1);
n_rows = zeros(n, 1);
n_usable = zeros(n, 1);
n_rejected = zeros(n, 1);
balanced_acc = nan(n, 1);
usable_recall = nan(n, 1);
reject_recall = nan(n, 1);
test_balanced_acc = nan(n, 1);
test_usable_recall = nan(n, 1);
test_reject_recall = nan(n, 1);
for ii = 1:n
    s = models.by_lead.(leads{ii});
    lead(ii) = string(read_field(s, 'lead', leads{ii}));
    model_kind(ii) = string(read_field(s, 'model_kind', ""));
    model_name(ii) = string(read_field(s, 'model_name', ""));
    validation_mode(ii) = string(read_field(s, 'validation_mode', ""));
    n_rows(ii) = double(read_field(s, 'n_rows', 0));
    n_usable(ii) = double(read_field(s, 'n_usable', 0));
    n_rejected(ii) = double(read_field(s, 'n_rejected', 0));
    balanced_acc(ii) = double(read_field(s, 'balanced_acc', NaN));
    usable_recall(ii) = double(read_field(s, 'usable_recall', NaN));
    reject_recall(ii) = double(read_field(s, 'reject_recall', NaN));
    if isfield(s, 'test') && isstruct(s.test)
        test_balanced_acc(ii) = double(read_field(s.test, 'balanced_acc', NaN));
        test_usable_recall(ii) = double(read_field(s.test, 'usable_recall', NaN));
        test_reject_recall(ii) = double(read_field(s.test, 'reject_recall', NaN));
    end
end
T = table(lead, model_kind, model_name, validation_mode, n_rows, n_usable, n_rejected, ...
    balanced_acc, usable_recall, reject_recall, ...
    test_balanced_acc, test_usable_recall, test_reject_recall);
end

function T = recording_summary_table(models)
T = table();
if ~isstruct(models) || ~isfield(models, 'by_lead')
    return;
end
leads = fieldnames(models.by_lead);
for ii = 1:numel(leads)
    s = models.by_lead.(leads{ii});
    leadName = string(read_field(s, 'lead', leads{ii}));
    if isfield(s, 'cv') && isfield(s.cv, 'by_recording') && istable(s.cv.by_recording) && ~isempty(s.cv.by_recording)
        cvT = s.cv.by_recording;
        cvT.lead = repmat(leadName, height(cvT), 1);
        cvT.phase = repmat("loro_cv", height(cvT), 1);
        cvT = movevars(cvT, {'lead','phase'}, 'Before', 1);
        if isempty(T); T = cvT; else; T = [T; cvT]; end %#ok<AGROW>
    end
    if isfield(s, 'test') && isfield(s.test, 'by_recording') && istable(s.test.by_recording) && ~isempty(s.test.by_recording)
        testT = s.test.by_recording;
        testT.lead = repmat(leadName, height(testT), 1);
        testT.phase = repmat("heldout_test", height(testT), 1);
        testT = movevars(testT, {'lead','phase'}, 'Before', 1);
        if isempty(T); T = testT; else; T = [T; testT]; end %#ok<AGROW>
    end
end
end

function write_text_report(reportPath, models, labelPath, summary, recordingSummary)
fid = fopen(reportPath, 'w');
if fid < 0
    error('Could not write report: %s', reportPath);
end
cleanupObj = onCleanup(@() fclose(fid));
fprintf(fid, 'Current MAS ML Training Report\n');
fprintf(fid, '==============================\n\n');
fprintf(fid, 'Labels: %s\n', char(string(labelPath)));
fprintf(fid, 'Policy: combo 1 fixed BPF+Notch; combo 5 lead-matched BPF+Notch+NLMS (CH1 RA+LA, CH2 RA+LL); corrupted rejects both.\n');
fprintf(fid, 'Requested model: %s\n', char(string(read_field(models, 'requested_model', ""))));
fprintf(fid, 'Validation: %s\n', char(string(read_field(models, 'validation', ""))));
fprintf(fid, 'Selection metric: %s\n', char(string(read_field(models, 'selection_metric', ""))));
if isfield(models, 'active_combo_ids')
    fprintf(fid, 'Active combo ids: %s\n', char(strjoin(string(models.active_combo_ids), ',')));
end
if isfield(models, 'split_summary') && istable(models.split_summary) && ~isempty(models.split_summary)
    fprintf(fid, '\nTrain/test split summary:\n');
    for ii = 1:height(models.split_summary)
        r = models.split_summary(ii,:);
        fprintf(fid, '  %s %s: recordings=%d rows=%d usable=%d rejected=%d\n', ...
            char(r.lead), char(r.split), r.n_recordings, r.n_rows, r.n_usable, r.n_rejected);
    end
end
if isfield(models, 'is_pooled') && models.is_pooled && isfield(models, 'pooled')
    p = models.pooled;
    fprintf(fid, '\nPooled model (single ch1+ch2 scorer; lead_id is feature [0]):\n');
    fprintf(fid, '  Model: %s (%s)\n', char(string(p.model_name)), char(string(p.model_kind)));
    fprintf(fid, '  LORO-CV (primary, across-recording): balanced %.1f%%, usable %.1f%%, reject %.1f%% (rows=%d usable=%d rejected=%d)\n', ...
        p.balanced_acc, p.usable_recall, p.reject_recall, p.n_rows, p.n_usable, p.n_rejected);
    if isfinite(p.test_balanced_acc)
        fprintf(fid, '  Held-out (within-recording 80/20): balanced %.1f%%, usable %.1f%%, reject %.1f%%\n', ...
            p.test_balanced_acc, p.test_usable_recall, p.test_reject_recall);
    end
    if isfield(p, 'guard_overlap') && p.guard_overlap
        fprintf(fid, '  Overlap guard: ON (boundary train epochs overlapping the test region were dropped).\n');
    end
    fprintf(fid, '  ch1.h and ch2.h export the same pooled forest; lead-specific behaviour is via the lead_id feature.\n');
end
fprintf(fid, '\nSelected lead models:\n');
for ii = 1:height(summary)
    fprintf(fid, '  %s: %s (%s), balanced %.1f%%, usable %.1f%%, reject %.1f%%, rows %d\n', ...
        char(summary.lead(ii)), char(summary.model_name(ii)), char(summary.model_kind(ii)), ...
        summary.balanced_acc(ii), summary.usable_recall(ii), summary.reject_recall(ii), ...
        summary.n_rows(ii));
    if isfinite(summary.test_balanced_acc(ii))
        fprintf(fid, '      held-out test balanced %.1f%%, usable %.1f%%, reject %.1f%%\n', ...
            summary.test_balanced_acc(ii), summary.test_usable_recall(ii), summary.test_reject_recall(ii));
    end
end
if istable(recordingSummary) && ~isempty(recordingSummary)
    fprintf(fid, '\nRecording-level performance:\n');
    for ii = 1:height(recordingSummary)
        r = recordingSummary(ii,:);
        fprintf(fid, '  %s %s %s: n=%d balanced=%.1f%% usable=%.1f%% reject=%.1f%%\n', ...
            char(r.lead), char(r.phase), char(r.recording_id), r.n_rows, ...
            r.balanced_acc, r.usable_recall, r.reject_recall);
    end
end
if isfield(models, 'condition_summary') && istable(models.condition_summary) && ~isempty(models.condition_summary)
    fprintf(fid, '\nPer-condition performance:\n');
    cs = models.condition_summary;
    for ii = 1:height(cs)
        r = cs(ii, :);
        fprintf(fid, '  %s %s %s: n=%d balanced=%.1f%% usable=%.1f%% reject=%.1f%%\n', ...
            char(r.phase), char(r.lead), char(r.condition), r.n_rows, ...
            r.balanced_acc, r.usable_recall, r.reject_recall);
    end
end
fprintf(fid, '\nFirmware note:\n');
fprintf(fid, '  Bagged-tree and RUSBoost tree ensembles are exportable by export_bag_to_c. Non-tree models remain training comparisons unless another exporter is added.\n');
end

function val = read_field(s, name, fallback)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    val = s.(name);
else
    val = fallback;
end
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
