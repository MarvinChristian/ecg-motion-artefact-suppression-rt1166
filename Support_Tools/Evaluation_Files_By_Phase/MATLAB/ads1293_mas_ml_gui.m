function ads1293_mas_ml_gui()
% ADS1293_MAS_ML_GUI One front door for MAS-aware epoch ML.
%
% This version does not require a manifest CSV. Add any number of recording
% files, label their condition in the table, then run extraction, candidate
% labelling, and per-channel model training. Each recording is split into
% 80/20 train/test epoch groups during feature extraction.

paths = local_paths();
if isfield(paths, 'pipeline_matlab') && isfolder(paths.pipeline_matlab)
    addpath(paths.pipeline_matlab);
end

C_BG = [0.10 0.11 0.13];
C_INPUT = [0.12 0.12 0.14];
C_FG = [0.86 0.88 0.90];
C_DIM = [0.58 0.64 0.70];
C_TABLE_BG = [0.98 0.99 1.00; 0.93 0.95 0.98];
C_TABLE_FG = [0.04 0.05 0.06];

app = struct();
app.records = empty_record_table();
app.featurePath = "";
app.labelPath = "";
app.masTapOrder = 32;
app.nlmsStepCap = 0.001;
app.autoTestFraction = 0.20;

fig = uifigure('Name','ADS1293 MAS ML Pipeline', ...
    'Position',[40 40 1480 900], 'Color', C_BG);
root = uigridlayout(fig, [1 2]);
root.ColumnWidth = {410, '1x'};
root.Padding = [12 12 12 12];
root.ColumnSpacing = 12;
root.BackgroundColor = C_BG;

left = uigridlayout(root, [20 2]);
left.Layout.Column = 1;
left.RowHeight = {36, 28, 32, 32, 32, 32, 24, 34, 34, 34, 34, 34, 34, 34, 34, 14, 42, 42, 42, '1x'};
left.ColumnWidth = {126, '1x'};
left.RowSpacing = 5;
left.BackgroundColor = C_BG;

titleLbl = uilabel(left, 'Text','ADS1293 MAS ML Pipeline', ...
    'FontSize',18, 'FontWeight','bold', 'FontColor', C_FG);
titleLbl.Layout.Row = 1; titleLbl.Layout.Column = [1 2];

modeLbl = uilabel(left, 'Text','Add files, label conditions, then extract. Each recording is split 80/20.', ...
    'FontSize',10, 'FontColor', C_DIM);
modeLbl.Layout.Row = 2; modeLbl.Layout.Column = [1 2];

app.addFilesBtn = uibutton(left, 'Text','Add Recording Files', ...
    'BackgroundColor',[0.23 0.39 0.58], 'FontColor','w', ...
    'ButtonPushedFcn', @on_add_files);
app.addFilesBtn.Layout.Row = 3; app.addFilesBtn.Layout.Column = [1 2];

app.addFolderBtn = uibutton(left, 'Text','Add Folder (*.txt, *.csv)', ...
    'BackgroundColor',[0.23 0.39 0.58], 'FontColor','w', ...
    'ButtonPushedFcn', @on_add_folder);
app.addFolderBtn.Layout.Row = 4; app.addFolderBtn.Layout.Column = [1 2];

app.removeBtn = uibutton(left, 'Text','Remove Selected Table Rows', ...
    'ButtonPushedFcn', @on_remove_rows);
app.removeBtn.Layout.Row = 5; app.removeBtn.Layout.Column = [1 2];

app.clearBtn = uibutton(left, 'Text','Clear Recording List', ...
    'ButtonPushedFcn', @on_clear_rows);
app.clearBtn.Layout.Row = 6; app.clearBtn.Layout.Column = [1 2];

defaultsLbl = uilabel(left, 'Text','DEFAULTS FOR NEW FILES', ...
    'FontSize',9, 'FontWeight','bold', 'FontColor', C_DIM);
defaultsLbl.Layout.Row = 7; defaultsLbl.Layout.Column = [1 2];

add_label(left, 8, 'Condition', C_DIM);
app.conditionEdit = uieditfield(left, 'text', 'Value','walking', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.conditionEdit.Layout.Row = 8; app.conditionEdit.Layout.Column = 2;

add_label(left, 9, 'Cohort', C_DIM);
app.cohortEdit = uieditfield(left, 'text', 'Value','manual', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.cohortEdit.Layout.Row = 9; app.cohortEdit.Layout.Column = 2;

add_label(left, 10, 'Split', C_DIM);
app.splitDrop = uidropdown(left, 'Items', {'80/20 epochs per recording + LORO CV'}, 'Value','80/20 epochs per recording + LORO CV', ...
    'Enable','off', 'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Tooltip','Each recording contributes 80% train epoch groups and 20% held-out test epoch groups; training uses LORO CV on train rows.');
app.splitDrop.Layout.Row = 10; app.splitDrop.Layout.Column = 2;

add_label(left, 11, 'BPF', C_DIM);
app.bpfDrop = uidropdown(left, 'Items', { ...
    'B1  Butterworth 8th 0.5-40 Hz', ...
    'B2  Butterworth 4th 0.5-40 Hz', ...
    'B3  Butterworth 8th 0.05-150 Hz', ...
    'B4  Chebyshev II 10th 0.5-40 Hz', ...
    'B5  Elliptic 4th 0.5-40 Hz', ...
    'B6  Butterworth 8th 0.05-40 Hz', ...
    'B7  Butterworth 8th 0.75-40 Hz', ...
    'B8  Butterworth 12th 0.5-40 Hz'}, ...
    'Value','B8  Butterworth 12th 0.5-40 Hz', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.bpfDrop.Layout.Row = 11; app.bpfDrop.Layout.Column = 2;

add_label(left, 12, 'Notch', C_DIM);
app.notchDrop = uidropdown(left, 'Items', { ...
    'N1  IIR x6 50 Hz', 'N2  NLMS 50 Hz', 'N3  IIR+NLMS', ...
    'N4  RLS 50 Hz', 'N5  IIR+RLS'}, ...
    'Value','N3  IIR+NLMS', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.notchDrop.Layout.Row = 12; app.notchDrop.Layout.Column = 2;

add_label(left, 13, 'MAS / Ref set / mu', C_DIM);
masGrid = uigridlayout(left, [1 3]);
masGrid.Layout.Row = 13; masGrid.Layout.Column = 2;
masGrid.ColumnWidth = {'0.75x','1.25x',58};
masGrid.Padding = [0 0 0 0];
masGrid.ColumnSpacing = 5;
masGrid.BackgroundColor = C_BG;
app.masDrop = uidropdown(masGrid, 'Items', {'LMS','NLMS','RLS'}, 'Value','NLMS', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.refDrop = uidropdown(masGrid, 'Items', { ...
    'six  accel+gyro axes', 'accel3  accel xyz', 'gyro3  gyro xyz', ...
    'amag  accel magnitude', 'gmag  gyro magnitude', 'magpair  |a|+|g|'}, ...
    'Value','six  accel+gyro axes', 'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Tooltip','Reference components inside the lead-matched RA-pair bank: CH1 uses RA/LA/RA-LA, CH2 uses RA/LL/RA-LL.');
app.lmsMuEdit = uieditfield(masGrid, 'numeric', 'Value',0.5, 'Limits',[1e-7 2.0], ...
    'ValueDisplayFormat','%.4g', 'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Tooltip','NLMS base mu for the lead-matched multireference bank. Current default pairs this with 32 taps and step cap 0.001.');

add_label(left, 14, 'ML Model', C_DIM);
app.modelDrop = uidropdown(left, 'Items', { ...
    'auto  embedded compare and choose', ...
    'bag  bagged/random-subspace trees', ...
    'rusboost  boosted trees for imbalance', ...
    'logistic  regularized linear logistic', ...
    'tree  single decision tree baseline', ...
    'auto_full  include offline SVM/LSVM/kNN', ...
    'svm  RBF support vector machine', ...
    'lsvm  linear support vector machine', ...
    'knn  k-nearest neighbours'}, ...
    'Value','auto_full  include offline SVM/LSVM/kNN', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.modelDrop.Layout.Row = 14; app.modelDrop.Layout.Column = 2;

sizeGrid = uigridlayout(left, [1 10]);
sizeGrid.Layout.Row = 15; sizeGrid.Layout.Column = [1 2];
sizeGrid.ColumnWidth = {42, '0.85x', 34, '0.85x', 52, '0.9x', 48, '0.75x', 48, '0.75x'};
sizeGrid.Padding = [0 0 0 0];
sizeGrid.BackgroundColor = C_BG;
uilabel(sizeGrid, 'Text','Epoch', 'FontColor', C_DIM);
app.epochEdit = uieditfield(sizeGrid, 'numeric', 'Value',1.000, 'Limits',[0.2 10], ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
uilabel(sizeGrid, 'Text','Step', 'FontColor', C_DIM);
app.hopEdit = uieditfield(sizeGrid, 'numeric', 'Value',0.500, 'Limits',[0.05 10], ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
uilabel(sizeGrid, 'Text','Max/rec', 'FontColor', C_DIM);
app.maxEpochEdit = uieditfield(sizeGrid, 'numeric', 'Value',0, 'Limits',[0 100000], ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Tooltip','Max epochs from each recording. 0 means extract and label all available epochs.');
uilabel(sizeGrid, 'Text','Lo Hz', 'FontColor', C_DIM);
app.bandLoEdit = uieditfield(sizeGrid, 'numeric', 'Value',0.5, 'Limits',[0.05 8], ...
    'ValueDisplayFormat','%.3g', 'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Tooltip','Low cutoff for transport-motion IMU references used by MAS.');
uilabel(sizeGrid, 'Text','Hi Hz', 'FontColor', C_DIM);
app.bandHiEdit = uieditfield(sizeGrid, 'numeric', 'Value',1.0, 'Limits',[1 20], ...
    'ValueDisplayFormat','%.3g', 'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Tooltip','High cutoff for transport-motion IMU references. Current best setting is 1 Hz; widen only for testing.');

divider = uipanel(left, 'BackgroundColor',[0.24 0.25 0.28], 'BorderType','none');
divider.Layout.Row = 16;
divider.Layout.Column = [1 2];

app.loadFeatBtn = uibutton(left, 'Text','Load Existing Features (.mat)', ...
    'BackgroundColor',[0.28 0.28 0.32], 'FontColor', C_DIM, ...
    'ButtonPushedFcn', @on_load_features);
app.loadFeatBtn.Layout.Row = 17; app.loadFeatBtn.Layout.Column = [1 2];

app.extractBtn = uibutton(left, 'Text','Extract Lead-Matched NLMS Epoch Set', ...
    'FontWeight','bold', 'BackgroundColor',[0.18 0.48 0.28], 'FontColor','w', ...
    'ButtonPushedFcn', @on_extract);
app.extractBtn.Layout.Row = 18; app.extractBtn.Layout.Column = [1 2];

buttonRow = uigridlayout(left, [1 2]);
buttonRow.Layout.Row = 19; buttonRow.Layout.Column = [1 2];
buttonRow.Padding = [0 0 0 0];
buttonRow.ColumnWidth = {'1x','1x'};
buttonRow.BackgroundColor = C_BG;
app.labelBtn = uibutton(buttonRow, 'Text','Open Labeller', ...
    'Enable','off', 'BackgroundColor',[0.23 0.39 0.58], 'FontColor','w', ...
    'ButtonPushedFcn', @on_label);
app.trainBtn = uibutton(buttonRow, 'Text','Train Models', ...
    'Enable','off', 'BackgroundColor',[0.44 0.34 0.16], 'FontColor','w', ...
    'ButtonPushedFcn', @on_train);

right = uigridlayout(root, [4 1]);
right.Layout.Column = 2;
right.RowHeight = {'1x', 70, 76, 230};
right.BackgroundColor = C_BG;
right.RowSpacing = 10;

app.recordingTable = uitable(right, ...
    'Data', app.records, ...
    'ColumnName', {'Recording ID','Condition','Cohort','Split','File Path'}, ...
    'ColumnEditable', [true true true false false], ...
    'BackgroundColor', C_TABLE_BG, ...
    'CellEditCallback', @on_table_edit);
app.recordingTable.Layout.Row = 1;
style_recording_table();

statsGrid = uigridlayout(right, [1 3]);
statsGrid.Layout.Row = 2;
statsGrid.ColumnWidth = {'1x','1x','1x'};
statsGrid.BackgroundColor = C_BG;
app.selBox = summary_box(statsGrid, 1, 'Recordings', '0', C_DIM, C_FG);
app.featureBox = summary_box(statsGrid, 2, 'Feature File', 'None', C_DIM, C_FG);
app.labelBox = summary_box(statsGrid, 3, 'Labels', 'None', C_DIM, C_FG);

comboText = {
    'Candidate set per epoch and lead:'
    '1. BPF + Notch'
    '5. BPF + Notch + lead-matched multireference NLMS'
    '   CH1 / Lead I:  RA, LA, RA-LA'
    '   CH2 / Lead II: RA, LL, RA-LL'
    'Ref set dropdown chooses six-axis, accel-only, gyro-only, or magnitude references.'
    'Current default: B8, N3, NLMS six-axis, 32 taps, 0.5-1 Hz, mu 0.5, step cap 0.001.'
    'Labeller overlays QRS/R peak detections on each candidate trace.'
    'Terminal label: corrupted'
};
app.comboArea = uitextarea(right, 'Value', comboText, 'Editable','off', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.comboArea.Layout.Row = 3;

app.logArea = uitextarea(right, 'Value', {'Ready. Add recording files, edit conditions, then extract. Each recording is split into 80/20 epoch groups; training uses LORO CV.'}, ...
    'Editable','off', 'FontName','Consolas', 'FontSize', 11, ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.logArea.Layout.Row = 4;

refresh_recording_summary();

    function on_add_files(~, ~)
        [fn, fd] = uigetfile({'*.txt;*.csv','Recording files (*.txt, *.csv)'; '*.*','All files'}, ...
            'Select recording files', default_recording_dir(paths), 'MultiSelect','on');
        if isequal(fn, 0); return; end
        if ischar(fn) || isstring(fn)
            fn = {char(fn)};
        end
        newRows = rows_from_files(fullfile(fd, string(fn(:))));
        app.records = [table_from_ui(); newRows];
        app.records = normalize_gui_records(app.records);
        refresh_recording_table();
        append_log(sprintf('Added %d recording file(s). Each will be split into 80/20 epoch groups during extraction.', height(newRows)));
    end

    function on_add_folder(~, ~)
        fd = uigetdir(default_recording_dir(paths), 'Select folder containing recording files');
        if isequal(fd, 0); return; end
        txtFiles = dir(fullfile(fd, '*.txt'));
        csvFiles = dir(fullfile(fd, '*.csv'));
        files = [fullfile({txtFiles.folder}', {txtFiles.name}'); fullfile({csvFiles.folder}', {csvFiles.name}')];
        if isempty(files)
            append_log('No .txt or .csv recordings found in selected folder.');
            return;
        end
        newRows = rows_from_files(string(files));
        app.records = [table_from_ui(); newRows];
        app.records = normalize_gui_records(app.records);
        refresh_recording_table();
        append_log(sprintf('Added %d recording file(s) from folder. Each will be split into 80/20 epoch groups during extraction.', height(newRows)));
    end

    function on_remove_rows(~, ~)
        rec = table_from_ui();
        if isempty(rec); return; end
        rows = [];
        try
            sel = app.recordingTable.Selection;
            if ~isempty(sel)
                rows = unique(sel(:,1));
            end
        catch
        end
        if isempty(rows)
            rows = height(rec);
        end
        rows = rows(rows >= 1 & rows <= height(rec));
        rec(rows,:) = [];
        app.records = normalize_gui_records(rec);
        refresh_recording_table();
        append_log(sprintf('Removed %d row(s).', numel(rows)));
    end

    function on_clear_rows(~, ~)
        app.records = empty_record_table();
        refresh_recording_table();
        append_log('Recording list cleared.');
    end

    function on_table_edit(src, ~)
        app.records = normalize_gui_records(src.Data);
        refresh_recording_summary();
    end

    function on_load_features(~, ~)
        [fn, fd] = uigetfile('*.mat', 'Select mas_epoch_features.mat or revised_mas_labels.mat', paths.repo);
        if isequal(fn, 0); return; end
        fpath = fullfile(fd, fn);
        try
            info = whos('-file', fpath);
            names = {info.name};
            if ~all(ismember({'X','featureNames','epochInfo'}, names))
                uialert(fig, 'Selected file is missing required fields (X, featureNames, epochInfo).', 'Invalid file');
                return;
            end
        catch ME
            uialert(fig, ['Could not read file: ' ME.message], 'Error');
            return;
        end
        app.featurePath = string(fpath);
        app.labelPath = "";
        app.featureBox.Text = short_path(app.featurePath);
        revisedSibling = fullfile(fd, 'revised_mas_labels.mat');
        if isfile(revisedSibling)
            app.labelBox.Text = 'Saved labels found';
        else
            app.labelBox.Text = 'Not reviewed';
        end
        app.labelBtn.Enable = 'on';
        app.trainBtn.Enable = 'off';
        append_log(sprintf('Loaded features from: %s', fn));
    end

    function on_extract(~, ~)
        try
            set_busy(true);
            cleanupObj = onCleanup(@() set_busy(false));
            rec = normalize_gui_records(table_from_ui());
            rec = rec(arrayfun(@(p) isfile(char(p)), rec.file_path), :);
            if isempty(rec)
                append_log('No valid recording files selected.');
                return;
            end
            rec = normalize_gui_records(rec);
            app.records = rec;
            refresh_recording_table();
            append_log(sprintf('Each recording will be split into %.0f/%.0f train/test epoch groups. LORO CV is used during training on the train rows.', ...
                100 * (1 - app.autoTestFraction), 100 * app.autoTestFraction));
            transportBand = [app.bandLoEdit.Value app.bandHiEdit.Value];
            append_log(sprintf('Extracting %d recordings with %s, %s, lead-matched multireference %s/%s, band %.3g-%.3g Hz, taps=%d, mu=%.4g, cap=%.4g, max %d epochs/rec...', ...
                height(rec), code_of(app.bpfDrop.Value), code_of(app.notchDrop.Value), ...
                lower(app.masDrop.Value), code_of(app.refDrop.Value), transportBand(1), transportBand(2), ...
                app.masTapOrder, app.lmsMuEdit.Value, app.nlmsStepCap, app.maxEpochEdit.Value));
            drawnow;
            [X, ~, ~, epochInfo] = extract_mas_epoch_features( ...
                'recording_table', rec, ...
                'split_mode', 'per_recording_epoch', ...
                'test_fraction', app.autoTestFraction, ...
                'bpf', code_of(app.bpfDrop.Value), ...
                'notch', code_of(app.notchDrop.Value), ...
                'mas_algorithm', lower(app.masDrop.Value), ...
                'ref_kind', code_of(app.refDrop.Value), ...
                'lms_mu_cap', app.lmsMuEdit.Value, ...
                'nlms_mu_base', app.lmsMuEdit.Value, ...
                'nlms_step_cap', app.nlmsStepCap, ...
                'mas_tap_order', app.masTapOrder, ...
                'transport_band', transportBand, ...
                'epoch_sec', app.epochEdit.Value, ...
                'hop_sec', app.hopEdit.Value, ...
                'max_epochs_per_rec', app.maxEpochEdit.Value);
            app.featurePath = string(find_latest_output('mas_epoch_features.mat'));
            app.labelPath = "";
            app.featureBox.Text = short_path(app.featurePath);
            app.labelBox.Text = 'Not reviewed';
            app.labelBtn.Enable = 'on';
            app.trainBtn.Enable = 'off';
            append_log(sprintf('Extracted %d variant rows across %d epoch groups.', ...
                size(X,1), numel(unique(epochInfo.group_id))));
        catch ME
            append_log(['ERROR: ' ME.message]);
            disp(getReport(ME));
        end
    end

    function on_label(~, ~)
        if strlength(app.featurePath) == 0
            append_log('No feature file loaded.');
            return;
        end
        revisedSibling = fullfile(fileparts(char(app.featurePath)), 'revised_mas_labels.mat');
        if isfile(revisedSibling)
            labellerInput = revisedSibling;
            append_log('Resuming from existing revised_mas_labels.mat.');
        else
            labellerInput = char(app.featurePath);
        end
        label_mas_epoch_gui(labellerInput);
        app.labelBox.Text = 'Reviewer open';
        app.trainBtn.Enable = 'on';
        append_log('Candidate labeller opened. Save labels there before training.');
    end

    function on_train(~, ~)
        try
            if strlength(app.labelPath) == 0
                candidate = latest_sibling(app.featurePath, 'revised_mas_labels.mat');
                if isfile(candidate)
                    app.labelPath = string(candidate);
                else
                    [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat');
                    if isequal(fn, 0); return; end
                    app.labelPath = string(fullfile(fd, fn));
                end
            end
            modelKind = code_of(app.modelDrop.Value);
            append_log(sprintf('Training fixed/lead-matched RA-pair/corrupt candidate scorers from %s with %s...', app.labelPath, modelKind));
            liveCallback = mas_model_stats_gui('live');
            models = train_mas_epoch_models(char(app.labelPath), modelKind, 5, 5, ...
                'validation', 'loro', ...
                'progress_fn', liveCallback);
            artifacts = write_mas_training_artifacts(models, char(app.labelPath), 'export_bag', true);
            app.labelBox.Text = short_path(app.labelPath);
            append_log(sprintf('Training complete. Summary: %s', char(artifacts.summary_csv)));
            if ~isempty(artifacts.exported_headers)
                append_log(sprintf('Exported %d bagged-tree firmware header(s).', numel(artifacts.exported_headers)));
            end
            mas_model_stats_gui(models);
        catch ME
            append_log(['ERROR: ' ME.message]);
            disp(getReport(ME));
        end
    end

    function rows = rows_from_files(filePaths)
        filePaths = string(filePaths(:));
        n = numel(filePaths);
        ids = strings(n,1);
        for ii = 1:n
            [~, base] = fileparts(filePaths(ii));
            ids(ii) = unique_recording_id(base, [app.records.recording_id; ids(1:ii-1)]);
        end
        rows = table(ids, repmat(string(app.conditionEdit.Value), n, 1), ...
            repmat(string(app.cohortEdit.Value), n, 1), ...
            repmat("epoch_80_20", n, 1), filePaths, ...
            'VariableNames', {'recording_id','condition','cohort','split','file_path'});
    end

    function rec = table_from_ui()
        rec = app.records;
        if has_recording_table()
            try
                rec = app.recordingTable.Data;
            catch
                rec = app.records;
            end
        end
        if isempty(rec)
            rec = empty_record_table();
        end
    end

    function refresh_recording_table()
        if has_recording_table()
            app.recordingTable.Data = app.records;
            style_recording_table();
        end
        refresh_recording_summary();
    end

    function refresh_recording_summary()
        rec = normalize_gui_records(table_from_ui());
        app.selBox.Text = sprintf('%d recordings | 80/20 epochs each', height(rec));
    end

    function tf = has_recording_table()
        tf = isfield(app, 'recordingTable') && ~isempty(app.recordingTable);
        if tf
            try
                tf = isvalid(app.recordingTable);
            catch
                tf = true;
            end
        end
    end

    function style_recording_table()
        if ~has_recording_table()
            return;
        end
        try
            st = uistyle('FontColor', C_TABLE_FG);
            addStyle(app.recordingTable, st, 'table');
        catch
            % Some MATLAB Table implementations do not expose text color styling.
            % The forced light row background keeps the default dark text readable.
        end
    end

    function set_busy(tf)
        state = ternary(tf, 'off', 'on');
        app.extractBtn.Enable = state;
        app.addFilesBtn.Enable = state;
        app.addFolderBtn.Enable = state;
        app.removeBtn.Enable = state;
        app.clearBtn.Enable = state;
        app.labelBtn.Enable = ternary(tf || strlength(app.featurePath)==0, 'off', 'on');
        app.trainBtn.Enable = ternary(tf, 'off', app.trainBtn.Enable);
    end

    function append_log(msg)
        stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
        app.logArea.Value = [app.logArea.Value; {sprintf('[%s] %s', stamp, msg)}];
        drawnow limitrate;
    end
end

function rec = normalize_gui_records(rec)
if isempty(rec)
    rec = empty_record_table();
    return;
end
need = {'recording_id','condition','cohort','split','file_path'};
for ii = 1:numel(need)
    if ~ismember(need{ii}, rec.Properties.VariableNames)
        rec.(need{ii}) = strings(height(rec), 1);
    end
end
rec = rec(:, need);
for ii = 1:numel(need)
    rec.(need{ii}) = string(rec.(need{ii}));
end
blankId = strlength(strtrim(rec.recording_id)) == 0;
for ii = find(blankId)'
    [~, base] = fileparts(rec.file_path(ii));
    rec.recording_id(ii) = unique_recording_id(base, rec.recording_id);
end
rec.condition(strlength(strtrim(rec.condition)) == 0) = "unknown";
rec.cohort(strlength(strtrim(rec.cohort)) == 0) = "manual";
rec.split(:) = "epoch_80_20";
end

function t = empty_record_table()
t = table(strings(0,1), strings(0,1), strings(0,1), strings(0,1), strings(0,1), ...
    'VariableNames', {'recording_id','condition','cohort','split','file_path'});
end

function id = unique_recording_id(base, existing)
idBase = string(matlab.lang.makeValidName(char(base)));
if strlength(idBase) == 0
    idBase = "recording";
end
existing = string(existing(:));
id = idBase;
kk = 2;
while any(existing == id)
    id = sprintf('%s_%d', idBase, kk);
    kk = kk + 1;
end
end

function add_label(parent, row, txt, color)
lbl = uilabel(parent, 'Text', txt, 'FontColor', color, 'FontWeight','bold');
lbl.Layout.Row = row;
lbl.Layout.Column = 1;
end

function lbl = summary_box(parent, col, titleText, valueText, dimColor, fgColor)
box = uigridlayout(parent, [2 1]);
box.Layout.Column = col;
box.RowHeight = {20, '1x'};
box.Padding = [8 4 8 4];
box.BackgroundColor = [0.13 0.14 0.16];
titleLbl = uilabel(box, 'Text', titleText, 'FontColor', dimColor, 'FontSize', 10);
titleLbl.Layout.Row = 1;
lbl = uilabel(box, 'Text', valueText, 'FontColor', fgColor, 'FontSize', 13, 'FontWeight','bold');
lbl.Layout.Row = 2;
end

function code = code_of(txt)
parts = split(string(txt));
code = lower(strtrim(parts(1)));
if startsWith(upper(code), "B") || startsWith(upper(code), "N")
    code = upper(code);
end
end

function latest = find_latest_output(filename)
paths = local_paths();
roots = {paths.subrepo, paths.pipeline_matlab};
d = [];
for ii = 1:numel(roots)
    if isfolder(roots{ii})
        d = [d; dir(fullfile(roots{ii}, 'outputs', '**', filename))]; %#ok<AGROW>
    end
end
if isempty(d)
    latest = "";
    return;
end
[~, ix] = max([d.datenum]);
latest = fullfile(d(ix).folder, d(ix).name);
end

function f = latest_sibling(featurePath, filename)
if strlength(string(featurePath)) == 0
    f = "";
else
    f = fullfile(fileparts(char(featurePath)), filename);
end
end

function s = short_path(p)
p = string(p);
if strlength(p) == 0
    s = 'None';
else
    [~, name, ext] = fileparts(char(p));
    s = [name ext];
end
end

function out = ternary(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

function paths = local_paths()
matlabDir = fileparts(mfilename('fullpath'));
paths.repo = repo_root_from_current_dir(matlabDir);
paths.subrepo = matlabDir;
paths.pipeline_matlab = fullfile(paths.repo, 'Support_Tools', 'Final_Pipeline_Files', 'MATLAB');
paths.recordings = fullfile(paths.repo, 'Support_Tools', 'Recordings', 'R01_R10_ADS1293_IMU_TS');
end

function d = default_recording_dir(paths)
if isfield(paths, 'recordings') && isfolder(paths.recordings)
    d = paths.recordings;
else
    d = paths.repo;
end
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
