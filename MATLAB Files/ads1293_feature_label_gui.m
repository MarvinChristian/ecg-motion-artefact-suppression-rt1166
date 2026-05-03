function ads1293_feature_label_gui()
% ADS1293_FEATURE_LABEL_GUI  GUI front door for feature extraction and labelling.
%
% Run from the repository root after:
%   addpath('MATLAB Files');
%
% Workflow:
%   1. Press Extract Features  — processes all manifest recordings causally,
%      extracts 21 IMU/ECG-quality features per epoch, saves feature file.
%      All epoch labels start as skip (no auto-labelling).
%   2. Reviewer opens automatically — press C (clean), X (corrupted), S (skip).
%   3. Save Labels  — only manually reviewed epochs are used for training.

% ── Colour palette (matches signal_diagnose_gui / phase2_analyzer) ────────────
C_BG    = [0.10 0.11 0.13];
C_INPUT = [0.12 0.12 0.14];
C_DROP  = [0.13 0.13 0.16];
C_FG    = [0.85 0.85 0.85];
C_DIM   = [0.62 0.68 0.74];
C_GO    = [0.20 0.55 0.30];
C_BLUE  = [0.25 0.45 0.65];
C_OFF   = [0.28 0.28 0.32];

paths = gui_paths();

app = struct();
app.paths       = paths;
app.featurePath = "";

fig = uifigure( ...
    'Name', 'ADS1293 Feature Extraction + Epoch Labelling', ...
    'Position', [80 80 1180 640], ...
    'Color', C_BG);

root = uigridlayout(fig, [1 2]);
root.ColumnWidth    = {320, '1x'};
root.RowHeight      = {'1x'};
root.Padding        = [12 12 12 12];
root.ColumnSpacing  = 12;
root.BackgroundColor = C_BG;

% ── Left panel ────────────────────────────────────────────────────────────────
left = uigridlayout(root, [11 2]);
left.Layout.Row     = 1;
left.Layout.Column  = 1;
left.RowHeight      = {30, 24, 34, 34, 34, 34, 34, 30, 44, 44, '1x'};
left.ColumnWidth    = {110, '1x'};
left.Padding        = [0 0 0 0];
left.RowSpacing     = 8;
left.BackgroundColor = C_BG;

% Title
titleLbl = uilabel(left, ...
    'Text', 'ADS1293 ML Pipeline', ...
    'FontSize', 18, 'FontWeight', 'bold', ...
    'FontColor', [0.92 0.94 0.96]);
titleLbl.Layout.Row = 1; titleLbl.Layout.Column = [1 2];

% Manifest path
manifestLbl = uilabel(left, ...
    'Text', sprintf('Manifest: %s', relative_to_repo(paths.repo, paths.manifest)), ...
    'FontColor', C_DIM, 'FontSize', 10);
manifestLbl.Layout.Row = 2; manifestLbl.Layout.Column = [1 2];

% Lead
add_label(left, 3, 'Lead', C_DIM);
app.leadDrop = uidropdown(left, ...
    'Items', {'ch1','ch2','diff12'}, 'Value', 'ch1', ...
    'BackgroundColor', C_DROP, 'FontColor', C_FG);
app.leadDrop.Layout.Row = 3; app.leadDrop.Layout.Column = 2;

% Bandpass
add_label(left, 4, 'Bandpass', C_DIM);
app.bpfDrop = uidropdown(left, ...
    'Items', { ...
        'none  (no bandpass)', ...
        'B1  Butter 8th  0.5-40 Hz', ...
        'B2  Butter 4th  0.5-40 Hz', ...
        'B3  Butter 8th  0.05-150 Hz', ...
        'B4  Cheby II 6th  0.5-40 Hz', ...
        'B5  Elliptic 4th  0.5-40 Hz', ...
        'B6  Butter 8th  0.05-40 Hz', ...
        'B7  Butter 8th  0.75-40 Hz'}, ...
    'Value', 'B1  Butter 8th  0.5-40 Hz', ...
    'BackgroundColor', C_DROP, 'FontColor', C_FG);
app.bpfDrop.Layout.Row = 4; app.bpfDrop.Layout.Column = 2;

% Notch
add_label(left, 5, 'Notch', C_DIM);
app.notchDrop = uidropdown(left, ...
    'Items', { ...
        'none  (no notch)', ...
        'N1  IIR x6  r=0.99  50 Hz fixed', ...
        'N3  NLMS  u=0.005  50 Hz fixed', ...
        'N5  IIR + NLMS  50 Hz hybrid', ...
        'N6  RLS  L=0.99  50 Hz fixed', ...
        'N8  IIR + RLS  50 Hz hybrid', ...
        'N9  Auto-detect + tracking NLMS'}, ...
    'Value', 'N9  Auto-detect + tracking NLMS', ...
    'BackgroundColor', C_DROP, 'FontColor', C_FG);
app.notchDrop.Layout.Row = 5; app.notchDrop.Layout.Column = 2;

% Epoch
add_label(left, 6, 'Epoch (s)', C_DIM);
app.epochEdit = uieditfield(left, 'numeric', ...
    'Value', 1.000, 'Limits', [0.100 10.000], ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.epochEdit.Layout.Row = 6; app.epochEdit.Layout.Column = 2;

% Hop
add_label(left, 7, 'Hop (s)', C_DIM);
app.hopEdit = uieditfield(left, 'numeric', ...
    'Value', 0.500, 'Limits', [0.050 10.000], ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.hopEdit.Layout.Row = 7; app.hopEdit.Layout.Column = 2;

% Open reviewer checkbox
app.openAfterCheck = uicheckbox(left, ...
    'Text', 'Open reviewer after extraction', ...
    'Value', true, 'FontColor', C_FG);
app.openAfterCheck.Layout.Row = 8; app.openAfterCheck.Layout.Column = [1 2];

% Extract button
app.extractBtn = uibutton(left, ...
    'Text', 'Extract Features', ...
    'FontWeight', 'bold', ...
    'BackgroundColor', C_GO, 'FontColor', 'w', ...
    'ButtonPushedFcn', @on_extract);
app.extractBtn.Layout.Row = 9; app.extractBtn.Layout.Column = [1 2];

% Load / Label buttons
app.loadBtn = uibutton(left, ...
    'Text', 'Load Feature File', ...
    'BackgroundColor', C_BLUE, 'FontColor', 'w', ...
    'ButtonPushedFcn', @on_load_existing);
app.loadBtn.Layout.Row = 10; app.loadBtn.Layout.Column = 1;

app.labelBtn = uibutton(left, ...
    'Text', 'Label Epochs', ...
    'Enable', 'off', ...
    'BackgroundColor', C_OFF, 'FontColor', [0.55 0.55 0.55], ...
    'ButtonPushedFcn', @on_label);
app.labelBtn.Layout.Row = 10; app.labelBtn.Layout.Column = 2;

% ── Right panel ───────────────────────────────────────────────────────────────
right = uigridlayout(root, [3 1]);
right.Layout.Row    = 1;
right.Layout.Column = 2;
right.RowHeight     = {180, 72, '1x'};
right.ColumnWidth   = {'1x'};
right.Padding       = [0 0 0 0];
right.RowSpacing    = 10;
right.BackgroundColor = C_BG;

app.recordingTable = uitable(right, ...
    'BackgroundColor', [C_INPUT; [0.14 0.14 0.16]], ...
    'RowStriping', 'on');
app.recordingTable.Layout.Row = 1;
app.recordingTable.Layout.Column = 1;
app.recordingTable.Data = manifest_preview(paths.manifest);
try
    addStyle(app.recordingTable, uistyle('FontColor', C_FG));
catch
end

summaryGrid = uigridlayout(right, [2 3]);
summaryGrid.Layout.Row   = 2;
summaryGrid.ColumnWidth  = {'1x','1x','1x'};
summaryGrid.RowHeight    = {24, 38};
summaryGrid.Padding      = [0 0 0 0];
summaryGrid.ColumnSpacing = 8;
summaryGrid.BackgroundColor = C_BG;

app.epochSummary = summary_box(summaryGrid, 1, 'Epochs',        '-',   C_DIM, C_FG);
app.labelSummary = summary_box(summaryGrid, 2, 'Labeled C / X', '-',   C_DIM, C_FG);
app.fileSummary  = summary_box(summaryGrid, 3, 'Feature File',  'None',C_DIM, C_FG);

app.logArea = uitextarea(right, ...
    'Editable', 'off', ...
    'FontName', 'Consolas', 'FontSize', 12, ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Value', {'Ready. Set Lead / BPF / Notch / Epoch / Hop, then Extract Features.'});
app.logArea.Layout.Row = 3;

refresh_manifest_info();

% ── Callbacks ─────────────────────────────────────────────────────────────────

    function on_extract(~, ~)
        set_busy(true);
        cleanupObj = onCleanup(@() set_busy(false));
        try
            append_log(sprintf('Extracting: lead=%s  bpf=%s  notch=%s  epoch=%.2fs  hop=%.2fs', ...
                app.leadDrop.Value, app.bpfDrop.Value, app.notchDrop.Value, ...
                app.epochEdit.Value, app.hopEdit.Value));
            append_log('  Per-recording progress in MATLAB Command Window.');
            drawnow; pause(0.1);

            bpfCode   = strtok(app.bpfDrop.Value);
            notchCode = strtok(app.notchDrop.Value);
            result = run_ads1293_ml_pipeline( ...
                'lead',    app.leadDrop.Value, ...
                'bpf',     bpfCode, ...
                'notch',   notchCode, ...
                'label_algorithm', 'none', ...
                'epoch_sec', app.epochEdit.Value, ...
                'hop_sec',   app.hopEdit.Value, ...
                'train', false);

            app.featurePath = string(result.feature_file);
            enable_label_btn(true);
            app.epochSummary.Text = sprintf('%d', size(result.X, 1));
            app.labelSummary.Text = '0 / 0';
            app.fileSummary.Text  = short_file(app.featurePath);
            append_log(sprintf('Done. %d epochs — all unlabelled. Open reviewer to label.', ...
                size(result.X, 1)));

            if app.openAfterCheck.Value
                append_log('Opening epoch reviewer...');
                drawnow; pause(0.05);
                label_epoch_gui(char(app.featurePath));
            else
                append_log('Press Label Epochs when ready.');
            end
        catch ME
            append_log(sprintf('ERROR: %s', ME.message));
            uialert(fig, ME.message, 'Extraction failed');
        end
    end

    function on_load_existing(~, ~)
        startDir = fullfile(paths.subrepo, 'outputs');
        if ~isfolder(startDir); startDir = paths.subrepo; end
        [fn, fd] = uigetfile('*.mat', 'Select epoch_features.mat or revised_labels.mat', startDir);
        if isequal(fn, 0); return; end
        fpath = fullfile(fd, fn);
        try
            d = load(fpath);
            if ~isfield(d, 'X') || ~isfield(d, 'featureNames') || ~isfield(d, 'epochInfo')
                error('File is missing X, featureNames, or epochInfo.');
            end
            app.featurePath = string(fpath);
            enable_label_btn(true);
            app.epochSummary.Text = sprintf('%d', size(d.X, 1));
            app.fileSummary.Text  = short_file(app.featurePath);
            if isfield(d, 'y_final')
                yy = double(d.y_final(:));
                app.labelSummary.Text = sprintf('%d / %d', sum(yy==1), sum(yy==0));
            else
                app.labelSummary.Text = '- / -';
            end
            append_log(sprintf('Loaded: %s', fpath));
        catch ME
            append_log(sprintf('ERROR: %s', ME.message));
            uialert(fig, ME.message, 'Load failed');
        end
    end

    function on_label(~, ~)
        if strlength(app.featurePath) == 0 || ~isfile(app.featurePath)
            uialert(fig, 'Extract or load a feature file first.', 'No feature file');
            return;
        end
        append_log('Opening epoch reviewer...');
        label_epoch_gui(char(app.featurePath));
    end

    function set_busy(tf)
        if tf
            app.extractBtn.Enable = 'off';
            app.loadBtn.Enable    = 'off';
            app.labelBtn.Enable   = 'off';
            fig.Pointer = 'watch';
        else
            app.extractBtn.Enable = 'on';
            app.loadBtn.Enable    = 'on';
            if strlength(app.featurePath) > 0 && isfile(app.featurePath)
                enable_label_btn(true);
            end
            fig.Pointer = 'arrow';
        end
        drawnow;
    end

    function enable_label_btn(tf)
        if tf
            app.labelBtn.Enable          = 'on';
            app.labelBtn.BackgroundColor = C_BLUE;
            app.labelBtn.FontColor       = 'w';
        else
            app.labelBtn.Enable          = 'off';
            app.labelBtn.BackgroundColor = C_OFF;
            app.labelBtn.FontColor       = [0.55 0.55 0.55];
        end
    end

    function refresh_manifest_info()
        try
            m = readtable(paths.manifest, 'TextType', 'string');
            n = height(m(m.include_main == 1, :));
            append_log(sprintf('Manifest: %d recordings active  (%s)', ...
                n, relative_to_repo(paths.repo, paths.manifest)));
        catch ME
            append_log(sprintf('Manifest warning: %s', ME.message));
        end
    end

    function append_log(msg)
        stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
        old = app.logArea.Value;
        if ischar(old); old = {old}; end
        app.logArea.Value = [old; {sprintf('[%s] %s', stamp, msg)}];
        drawnow;
    end
end

% ── Helpers ───────────────────────────────────────────────────────────────────

function add_label(parent, row, txt, color)
lbl = uilabel(parent, 'Text', txt, 'FontColor', color);
lbl.Layout.Row = row; lbl.Layout.Column = 1;
end

function lbl = summary_box(parent, col, titleText, valueText, dimColor, fgColor)
tl = uilabel(parent, 'Text', titleText, 'FontColor', dimColor, ...
    'HorizontalAlignment', 'center');
tl.Layout.Row = 1; tl.Layout.Column = col;
lbl = uilabel(parent, 'Text', valueText, 'FontColor', fgColor, ...
    'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
lbl.Layout.Row = 2; lbl.Layout.Column = col;
end

function data = manifest_preview(manifestPath)
try
    m = readtable(manifestPath, 'TextType', 'string');
    keep = intersect({'recording_id','condition','signal_format','default_lead'}, ...
        m.Properties.VariableNames, 'stable');
    data = m(:, keep);
catch
    data = table();
end
end

function paths = gui_paths()
matlabDir      = fileparts(mfilename('fullpath'));
paths.repo     = fileparts(matlabDir);
paths.subrepo  = matlabDir;
paths.manifest = fullfile(paths.subrepo, 'config', 'ads1293_recording_manifest.csv');
end

function out = relative_to_repo(repoRoot, fpath)
repoRoot = char(repoRoot); fpath = char(fpath);
if startsWith(lower(fpath), lower(repoRoot))
    out = erase(fpath, [repoRoot filesep]);
else
    out = fpath;
end
end

function out = short_file(fpath)
fpath = char(fpath);
if isempty(fpath); out = 'None'; return; end
[parent, name, ext] = fileparts(fpath);
[~, folder] = fileparts(parent);
out = sprintf('%s/%s%s', folder, name, ext);
end
