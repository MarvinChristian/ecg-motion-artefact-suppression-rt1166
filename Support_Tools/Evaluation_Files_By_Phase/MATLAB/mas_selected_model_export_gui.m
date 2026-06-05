function mas_selected_model_export_gui(model_path)
% MAS_SELECTED_MODEL_EXPORT_GUI Export selected MAS models from a GUI.
%
% Firmware C-header export is available for selected "bag" models. If the
% selected model is SVM/LSVM/kNN/etc. but a BAG candidate exists, this GUI can
% refit BAG from models.source_file and export that firmware header.

C_BG = [0.10 0.11 0.13];
C_INPUT = [0.12 0.12 0.14];
C_FG = [0.86 0.88 0.90];
C_DIM = [0.58 0.64 0.70];
C_TABLE_BG = [0.98 0.99 1.00; 0.93 0.95 0.98];
C_TABLE_FG = [0.04 0.05 0.06];

paths = local_paths();
if isfield(paths, 'pipeline_matlab') && isfolder(paths.pipeline_matlab)
    addpath(paths.pipeline_matlab);
end

app = struct();
app.modelPath = "";
app.models = struct();
app.bagModels = struct();
app.bagModelsSource = "";
app.outputDir = default_firmware_source_dir();
app.rows = empty_export_table();

fig = uifigure('Name','MAS Selected Model Export', ...
    'Position',[90 90 1040 620], 'Color', C_BG);
root = uigridlayout(fig, [5 1]);
root.RowHeight = {44, 50, '1x', 86, 150};
root.Padding = [12 12 12 12];
root.RowSpacing = 10;
root.BackgroundColor = C_BG;

titleRow = uigridlayout(root, [1 2]);
titleRow.Layout.Row = 1;
titleRow.ColumnWidth = {'1x', 230};
titleRow.Padding = [0 0 0 0];
titleRow.BackgroundColor = C_BG;
uilabel(titleRow, 'Text','Export MAS Firmware Models', ...
    'FontSize',18, 'FontWeight','bold', 'FontColor', C_FG);
app.loadBtn = uibutton(titleRow, 'Text','Load mas_epoch_models.mat', ...
    'BackgroundColor',[0.23 0.39 0.58], 'FontColor','w', ...
    'ButtonPushedFcn', @on_load_model);

pathRow = uigridlayout(root, [2 3]);
pathRow.Layout.Row = 2;
pathRow.ColumnWidth = {96, '1x', 130};
pathRow.RowHeight = {22, 22};
pathRow.Padding = [0 0 0 0];
pathRow.RowSpacing = 4;
pathRow.BackgroundColor = C_BG;
uilabel(pathRow, 'Text','Model file', 'FontColor', C_DIM, 'FontWeight','bold');
app.modelLbl = uilabel(pathRow, 'Text','None loaded', 'FontColor', C_FG);
app.modelLbl.Layout.Column = 2;
app.refreshBtn = uibutton(pathRow, 'Text','Refresh', 'Enable','off', ...
    'ButtonPushedFcn', @refresh_table);
app.refreshBtn.Layout.Column = 3;
uilabel(pathRow, 'Text','Output dir', 'FontColor', C_DIM, 'FontWeight','bold');
app.outputLbl = uilabel(pathRow, 'Text', app.outputDir, 'FontColor', C_FG);
app.outputLbl.Layout.Row = 2;
app.outputLbl.Layout.Column = 2;
app.dirBtn = uibutton(pathRow, 'Text','Choose...', ...
    'ButtonPushedFcn', @on_choose_output_dir);
app.dirBtn.Layout.Row = 2;
app.dirBtn.Layout.Column = 3;

app.table = uitable(root, ...
    'Data', app.rows, ...
    'ColumnName', {'Export','Lead','Selected Model','Firmware Header','CV Balanced','Test Balanced','Rows','Exportable'}, ...
    'ColumnEditable', [true false false false false false false false], ...
    'BackgroundColor', C_TABLE_BG, ...
    'CellEditCallback', @on_table_edit);
app.table.Layout.Row = 3;
style_table();

buttonRow = uigridlayout(root, [1 4]);
buttonRow.Layout.Row = 4;
buttonRow.ColumnWidth = {'1x','1x','1x','1x'};
buttonRow.Padding = [0 0 0 0];
buttonRow.ColumnSpacing = 10;
buttonRow.BackgroundColor = C_BG;
app.exportCheckedBtn = uibutton(buttonRow, 'Text','Export Checked Firmware Headers', ...
    'Enable','off', 'FontWeight','bold', 'BackgroundColor',[0.18 0.48 0.28], 'FontColor','w', ...
    'ButtonPushedFcn', @on_export_checked_headers);
app.exportAllBtn = uibutton(buttonRow, 'Text','Export All Exportable Headers', ...
    'Enable','off', 'BackgroundColor',[0.18 0.42 0.24], 'FontColor','w', ...
    'ButtonPushedFcn', @on_export_all_headers);
app.saveMatBtn = uibutton(buttonRow, 'Text','Save Checked MATLAB Models', ...
    'Enable','off', 'BackgroundColor',[0.44 0.34 0.16], 'FontColor','w', ...
    'ButtonPushedFcn', @on_save_checked_mat);
app.openStatsBtn = uibutton(buttonRow, 'Text','Open Performance GUI', ...
    'Enable','off', 'ButtonPushedFcn', @on_open_stats);

app.logArea = uitextarea(root, 'Editable','off', 'FontName','Consolas', ...
    'FontSize', 11, 'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'Value', {'Load mas_epoch_models.mat. Firmware export uses selected BAG models or refits BAG candidates from source labels.'});
app.logArea.Layout.Row = 5;

if nargin >= 1 && ~isempty(model_path)
    load_model_file(model_path);
else
    latest = find_latest_model_file();
    if strlength(latest) > 0
        load_model_file(latest);
    end
end

    function on_load_model(~, ~)
        startDir = default_start_dir();
        [fn, fd] = uigetfile('*.mat', 'Select mas_epoch_models.mat', startDir);
        if isequal(fn, 0)
            return;
        end
        load_model_file(fullfile(fd, fn));
    end

    function load_model_file(pathValue)
        try
            d = load(char(pathValue), 'models');
            if ~isfield(d, 'models') || ~isstruct(d.models) || ~isfield(d.models, 'by_lead')
                uialert(fig, 'Selected file does not contain a valid models.by_lead struct.', 'Invalid model file');
                return;
            end
            app.modelPath = string(pathValue);
            app.models = d.models;
            app.bagModels = struct();
            app.bagModelsSource = "";
            app.modelLbl.Text = char(short_path(app.modelPath));
            append_log(sprintf('Loaded %s', char(app.modelPath)));
            refresh_table();
        catch ME
            uialert(fig, ME.message, 'Could not load model file');
            append_log(['ERROR loading model: ' ME.message]);
        end
    end

    function refresh_table(~, ~)
        if ~isfield(app.models, 'by_lead')
            app.rows = empty_export_table();
        else
            app.rows = model_rows(app.models, app.modelPath);
        end
        app.table.Data = app.rows;
        style_table();
        enable_controls();
    end

    function on_table_edit(src, ~)
        app.rows = normalize_rows(src.Data);
        app.table.Data = app.rows;
        enable_controls();
    end

    function on_choose_output_dir(~, ~)
        fd = uigetdir(char(app.outputDir), 'Choose firmware header output folder');
        if isequal(fd, 0)
            return;
        end
        app.outputDir = string(fd);
        app.outputLbl.Text = char(app.outputDir);
        append_log(sprintf('Output folder: %s', char(app.outputDir)));
    end

    function on_export_checked_headers(~, ~)
        export_header_rows(checked_exportable_rows());
    end

    function on_export_all_headers(~, ~)
        rows = app.rows;
        exportable = rows.exportable;
        export_header_rows(find(exportable));
    end

    function export_header_rows(rowIdx)
        if isempty(rowIdx)
            append_log('No firmware-exportable BAG rows to export.');
            uialert(fig, 'No checked rows can be exported as BAG firmware headers.', 'Nothing to export');
            return;
        end
        if ~exist(char(app.outputDir), 'dir')
            mkdir(char(app.outputDir));
        end
        exported = strings(0, 1);
        failed = strings(0, 1);
        for ii = rowIdx(:)'
            leadName = string(app.rows.lead(ii));
            selectedKind = string(app.rows.selected_model(ii));
            outName = sprintf('mas_bag_classifier_%s.h', lower(char(leadName)));
            outPath = fullfile(char(app.outputDir), outName);
            try
                exportModels = app.models;
                if ~strcmpi(selectedKind, "bag")
                    exportModels = get_or_train_bag_models();
                end
                export_bag_to_c(exportModels, leadName, outPath);
                exported(end+1, 1) = string(outPath); %#ok<AGROW>
                if strcmpi(selectedKind, "bag")
                    append_log(sprintf('Exported selected BAG %s -> %s', char(leadName), outPath));
                else
                    append_log(sprintf('Exported BAG refit for %s (selected was %s) -> %s', ...
                        char(leadName), char(upper(selectedKind)), outPath));
                end
            catch ME
                failed(end+1, 1) = leadName + ": " + string(ME.message); %#ok<AGROW>
                append_log(sprintf('ERROR exporting %s: %s', char(leadName), ME.message));
            end
        end
        if isempty(failed)
            uialert(fig, sprintf('Exported %d firmware header(s).', numel(exported)), 'Export complete');
        else
            uialert(fig, strjoin(cellstr(failed), newline), 'Some exports failed');
        end
    end

    function bagModels = get_or_train_bag_models()
        sourceFile = model_source_label_file(app.models, app.modelPath);
        if strlength(sourceFile) == 0 || ~isfile(char(sourceFile))
            savedSource = "<missing>";
            if isfield(app.models, 'source_file') && ~isempty(app.models.source_file)
                savedSource = string(app.models.source_file);
            end
            error('Cannot refit BAG export model because source labels were not found: %s', char(savedSource));
        end
        if isfield(app.bagModels, 'by_lead') && strcmp(string(app.bagModelsSource), sourceFile)
            bagModels = app.bagModels;
            return;
        end
        append_log(sprintf('Refitting BAG export models from %s', char(sourceFile)));
        app.bagModels = train_mas_epoch_models(char(sourceFile), "bag", 5, 5, ...
            "validation", "loro", "save_model", false);
        app.bagModelsSource = sourceFile;
        if ~isfield(app.bagModels, 'by_lead')
            error('BAG refit did not return models.by_lead.');
        end
        bagModels = app.bagModels;
    end

    function on_save_checked_mat(~, ~)
        rowIdx = checked_rows();
        if isempty(rowIdx)
            uialert(fig, 'No checked rows to save.', 'Nothing to save');
            return;
        end
        [fn, fd] = uiputfile('selected_mas_models.mat', 'Save selected MATLAB models as');
        if isequal(fn, 0)
            return;
        end
        selected_models = struct();
        selected_models.source_file = app.modelPath;
        selected_models.featureNames = app.models.featureNames;
        selected_models.by_lead = struct();
        for ii = rowIdx(:)'
            leadName = char(app.rows.lead(ii));
            field = matlab.lang.makeValidName(leadName);
            selected_models.by_lead.(field) = app.models.by_lead.(field);
        end
        outPath = fullfile(fd, fn);
        save(outPath, 'selected_models', '-v7.3');
        append_log(sprintf('Saved MATLAB selected model bundle: %s', outPath));
        uialert(fig, sprintf('Saved %d selected MATLAB model(s).', numel(rowIdx)), 'Saved');
    end

    function on_open_stats(~, ~)
        if isempty(fieldnames(app.models))
            return;
        end
        mas_model_stats_gui(app.models);
    end

    function rowIdx = checked_rows()
        rows = normalize_rows(app.table.Data);
        rowIdx = find(rows.export);
    end

    function rowIdx = checked_exportable_rows()
        rows = normalize_rows(app.table.Data);
        rowIdx = find(rows.export & rows.exportable);
    end

    function enable_controls()
        hasModel = isfield(app.models, 'by_lead');
        anyChecked = hasModel && any(app.rows.export);
        anyCheckedExportable = hasModel && any(app.rows.export & app.rows.exportable);
        anyExportable = hasModel && any(app.rows.exportable);
        app.refreshBtn.Enable = ternary(hasModel, 'on', 'off');
        app.exportCheckedBtn.Enable = ternary(anyCheckedExportable, 'on', 'off');
        app.exportAllBtn.Enable = ternary(anyExportable, 'on', 'off');
        app.saveMatBtn.Enable = ternary(anyChecked, 'on', 'off');
        app.openStatsBtn.Enable = ternary(hasModel, 'on', 'off');
    end

    function append_log(msg)
        stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
        app.logArea.Value = [app.logArea.Value; {sprintf('[%s] %s', stamp, msg)}];
        drawnow limitrate;
    end

    function style_table()
        try
            st = uistyle('FontColor', C_TABLE_FG);
            addStyle(app.table, st, 'table');
        catch
        end
    end

    function startDir = default_start_dir()
        if strlength(app.modelPath) > 0
            startDir = fileparts(char(app.modelPath));
        else
            latest = find_latest_model_file();
            if strlength(latest) > 0
                startDir = fileparts(char(latest));
            else
                startDir = pwd;
            end
        end
    end
end

function rows = model_rows(models, modelPath)
if nargin < 2
    modelPath = "";
end
leads = fieldnames(models.by_lead);
n = numel(leads);
export = false(n, 1);
lead = strings(n, 1);
selected_model = strings(n, 1);
firmware_header = strings(n, 1);
cv_balanced = nan(n, 1);
test_balanced = nan(n, 1);
rows_count = zeros(n, 1);
exportable = false(n, 1);
sourceAvailable = has_source_label_file(models, modelPath);
for ii = 1:n
    s = models.by_lead.(leads{ii});
    lead(ii) = string(read_field(s, 'lead', leads{ii}));
    selected_model(ii) = string(read_field(s, 'model_kind', ""));
    selectedBag = strcmpi(selected_model(ii), "bag");
    bagCandidate = selectedBag || has_candidate_model(s, "bag");
    exportable(ii) = selectedBag || (bagCandidate && sourceAvailable);
    export(ii) = exportable(ii);
    if selectedBag
        firmware_header(ii) = "selected BAG header";
    elseif bagCandidate && sourceAvailable
        firmware_header(ii) = "BAG candidate refit";
    elseif bagCandidate
        firmware_header(ii) = "BAG candidate; source missing";
    else
        firmware_header(ii) = "no BAG candidate/exporter";
    end
    cv_balanced(ii) = double(read_field(s, 'balanced_acc', NaN));
    if isfield(s, 'test') && isstruct(s.test)
        test_balanced(ii) = double(read_field(s.test, 'balanced_acc', NaN));
    end
    rows_count(ii) = double(read_field(s, 'n_rows', 0));
end
rows = table(export, lead, selected_model, firmware_header, cv_balanced, test_balanced, rows_count, exportable);
end

function tf = has_candidate_model(s, kind)
tf = false;
if ~isstruct(s) || ~isfield(s, 'candidate_results') || isempty(s.candidate_results)
    return;
end
cr = s.candidate_results;
for ii = 1:numel(cr)
    thisKind = string(read_field(cr(ii), 'kind', ""));
    if strcmpi(thisKind, kind)
        status = lower(string(read_field(cr(ii), 'status', "")));
        balanced = double(read_field(cr(ii), 'balanced_acc', NaN));
        score = double(read_field(cr(ii), 'selection_score', NaN));
        tf = ~(status == "not_run" || status == "unavailable") && ...
            (isfinite(balanced) || isfinite(score));
        return;
    end
end
end

function tf = has_source_label_file(models, modelPath)
sourceFile = model_source_label_file(models, modelPath);
tf = strlength(sourceFile) > 0 && isfile(char(sourceFile));
end

function sourceFile = model_source_label_file(models, modelPath)
sourceFile = "";
if ~isstruct(models) || ~isfield(models, 'source_file') || isempty(models.source_file)
    return;
end
sourceFile = string(models.source_file);
if strlength(sourceFile) == 0 || isfile(char(sourceFile))
    return;
end
if nargin < 2 || strlength(string(modelPath)) == 0
    return;
end
modelDir = string(fileparts(char(modelPath)));
candidate = string(fullfile(char(modelDir), char(sourceFile)));
if isfile(char(candidate))
    sourceFile = candidate;
    return;
end
[srcDir, srcName, srcExt] = fileparts(char(sourceFile));
if isempty(srcDir)
    candidate = string(fullfile(char(modelDir), [srcName srcExt]));
    if isfile(char(candidate))
        sourceFile = candidate;
    end
end
end

function rows = normalize_rows(rows)
if isempty(rows)
    rows = empty_export_table();
    return;
end
if ~ismember('exportable', rows.Properties.VariableNames)
    rows.exportable = strcmpi(string(rows.selected_model), "bag");
end
rows.export = logical(rows.export);
end

function rows = empty_export_table()
rows = table(false(0,1), strings(0,1), strings(0,1), strings(0,1), ...
    nan(0,1), nan(0,1), zeros(0,1), false(0,1), ...
    'VariableNames', {'export','lead','selected_model','firmware_header','cv_balanced','test_balanced','rows_count','exportable'});
end

function latest = find_latest_model_file()
paths = local_paths();
roots = unique([paths.subrepo; fullfile(paths.repo, "MATLAB Files"); paths.repo], 'stable');
hits = [];
for ii = 1:numel(roots)
    if isfolder(roots(ii))
        hits = [hits; dir(fullfile(roots(ii), '**', 'mas_epoch_models.mat'))]; %#ok<AGROW>
    end
end
if isempty(hits)
    latest = "";
    return;
end
[~, ix] = max([hits.datenum]);
latest = string(fullfile(hits(ix).folder, hits(ix).name));
end

function outDir = default_firmware_source_dir()
paths = local_paths();
candidate = fullfile(paths.repo, "source");
if isfolder(candidate)
    outDir = string(candidate);
else
    outDir = string(paths.subrepo);
end
end

function paths = local_paths()
matlabDir = string(fileparts(mfilename('fullpath')));
paths.subrepo = matlabDir;
paths.repo = string(repo_root_from_current_dir(char(matlabDir)));
paths.pipeline_matlab = string(fullfile(char(paths.repo), 'Support_Tools', 'Final_Pipeline_Files', 'MATLAB'));
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

function s = short_path(p)
[folder, name, ext] = fileparts(char(p));
[~, parent] = fileparts(folder);
s = string(fullfile(parent, [name ext]));
end

function val = read_field(s, name, fallback)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    val = s.(name);
else
    val = fallback;
end
end

function out = ternary(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
