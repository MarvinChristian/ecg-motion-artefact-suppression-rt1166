function varargout = mas_model_stats_gui(varargin)
% MAS_MODEL_STATS_GUI Visual performance report for trained MAS epoch models.
%
% Live mode — call before training:
%   callback = mas_model_stats_gui('live')
%   Pass as 'progress_fn' to train_mas_epoch_models.
%   A tab appears for each model as it finishes CV evaluation.
%
% Post-training mode:
%   mas_model_stats_gui(models)   % trained models struct
%   mas_model_stats_gui()         % prompt for mas_epoch_models.mat

C_BG    = [0.10 0.11 0.13];
C_AX    = [0.08 0.09 0.11];
C_FG    = [0.86 0.88 0.90];
C_DIM   = [0.58 0.64 0.70];
C_PANEL = [0.13 0.14 0.16];

if nargin >= 1 && ischar(varargin{1}) && strcmp(varargin{1}, 'live')
    varargout{1} = make_live_callback(C_BG, C_AX, C_FG, C_DIM, C_PANEL);
    return;
end

if nargin < 1 || isempty(varargin{1})
    [fn, fd] = uigetfile('*.mat', 'Select mas_epoch_models.mat');
    if isequal(fn, 0)
        if nargout > 0; varargout{1} = []; end
        return;
    end
    d = load(fullfile(fd, fn), 'models');
    models = d.models;
else
    models = varargin{1};
end

leads  = fieldnames(models.by_lead);
nLeads = numel(leads);
if nLeads == 0
    f = uifigure('Visible','off');
    uialert(f, 'No trained leads found in models struct.', 'No data');
    return;
end

fig = uifigure('Name','MAS Model Performance', ...
    'Position',[60 60 1140 780], 'Color', C_BG);
root = uigridlayout(fig, [1 1]);
root.Padding = [12 12 12 12];
root.BackgroundColor = C_BG;
tabGroup = uitabgroup(root);
tabGroup.Layout.Row    = 1;
tabGroup.Layout.Column = 1;

featureNames = models.featureNames;
for li = 1:nLeads
    ld = models.by_lead.(leads{li});
    if ~isfield(ld, 'candidate_results') || isempty(ld.candidate_results)
        continue;
    end
    cr = ld.candidate_results;
    for ci = 1:numel(cr)
        if ismember(char(cr(ci).status), {'not_run','unavailable'})
            continue;
        end
        isSelected = strcmp(char(cr(ci).kind), char(ld.model_kind));
        imp = [];
        if isSelected && isfield(ld, 'feature_importance')
            imp = ld.feature_importance;
        end
        t = uitab(tabGroup, 'Title', make_tab_title(ld.lead, cr(ci).kind, isSelected), ...
            'BackgroundColor', C_BG);
        draw_candidate_content(t, cr(ci), featureNames, imp, isSelected, ...
            C_BG, C_AX, C_FG, C_DIM, C_PANEL);
    end
    if isfield(ld, 'test') && isfield(ld.test, 'y_true') && ~isempty(ld.test.y_true)
        t = uitab(tabGroup, 'Title', sprintf('%s Test', char(ld.lead)), ...
            'BackgroundColor', C_BG);
        draw_test_content(t, ld, C_BG, C_AX, C_FG, C_DIM, C_PANEL);
    end
end

if nargout > 0; varargout{1} = fig; end
end

% =========================================================================
function cb = make_live_callback(C_BG, C_AX, C_FG, C_DIM, C_PANEL)
fig = uifigure('Name','Training in progress...', ...
    'Position',[60 60 1140 780], 'Color', C_BG);
root = uigridlayout(fig, [1 1]);
root.Padding = [12 12 12 12];
root.BackgroundColor = C_BG;
tabGroup = uitabgroup(root);
tabGroup.Layout.Row    = 1;
tabGroup.Layout.Column = 1;

waitTab = uitab(tabGroup, 'Title', 'Waiting...', 'BackgroundColor', C_BG);
wg = uigridlayout(waitTab, [1 1]);
wg.BackgroundColor = C_BG;
uilabel(wg, 'Text', 'Training in progress — tabs appear as each model finishes.', ...
    'FontColor', C_DIM, 'FontSize', 13, 'HorizontalAlignment', 'center');

tabHandles  = containers.Map('KeyType','char','ValueType','any');
removedWait = false;

    function on_progress(lead, result, featureNames)
        if ~isvalid(fig); return; end

        % Selected-model notification: mark tab and fill importance plot
        if isstruct(result) && isfield(result,'type') && strcmp(result.type,'selected')
            key = sprintf('%s|%s', char(lead), char(result.kind));
            if isKey(tabHandles, key)
                try
                    tabHandles(key).Title = make_tab_title(lead, result.kind, true);
                catch
                end
            end
            impKey = [key '|imp'];
            if isKey(tabHandles, impKey) && ~isempty(result.importance)
                try
                    draw_importance(tabHandles(impKey), result.importance, featureNames, C_FG, C_DIM);
                catch
                end
            end
            fig.Name = sprintf('Training complete  —  %s selected', char(result.kind));
            drawnow;
            return;
        end

        % New candidate CV result — add a tab
        key      = sprintf('%s|%s', char(lead), char(result.kind));
        t        = uitab(tabGroup, 'Title', make_tab_title(lead, result.kind, false), ...
            'BackgroundColor', C_BG);
        tabHandles(key) = t;

        axImp = draw_candidate_content(t, result, featureNames, [], false, ...
            C_BG, C_AX, C_FG, C_DIM, C_PANEL);
        if ~isempty(axImp)
            tabHandles([key '|imp']) = axImp;
        end

        if ~removedWait
            try; delete(waitTab); catch; end
            removedWait = true;
        end
        tabGroup.SelectedTab = t;
        drawnow;
    end

cb = @on_progress;
end

% =========================================================================
function axImp = draw_candidate_content(container, result, featureNames, imp, isSelected, ...
    C_BG, C_AX, C_FG, C_DIM, C_PANEL)
axImp = [];

tGrid = uigridlayout(container, [4 2]);
tGrid.RowHeight     = {84, '1x', '1x', '0.82x'};
tGrid.ColumnWidth   = {'1x', '1x'};
tGrid.Padding       = [10 10 10 10];
tGrid.RowSpacing    = 8;
tGrid.ColumnSpacing = 8;
tGrid.BackgroundColor = C_BG;

% Row 1: model label and metric boxes.
mRow = uigridlayout(tGrid, [1 6]);
mRow.Layout.Row    = 1;
mRow.Layout.Column = [1 2];
mRow.ColumnWidth   = {110, '1x','1x','1x','1x','1x'};
mRow.Padding       = [0 0 0 0];
mRow.ColumnSpacing = 8;
mRow.BackgroundColor = C_BG;

nameLbl = uilabel(mRow, 'Text', char(result.name), ...
    'FontSize', 12, 'FontWeight', 'bold', ...
    'FontColor', ternary(isSelected, [0.28 0.78 0.55], C_FG));
nameLbl.Layout.Column = 1;
try
    nameLbl.Tooltip = char(string(result.validation_mode));
catch
end

draw_metric_box(mRow, 2, 'Accuracy',       result.acc,           C_PANEL, C_DIM, C_FG, false);
draw_metric_box(mRow, 3, 'Balanced Acc',   result.balanced_acc,  C_PANEL, C_DIM, C_FG, true);
draw_metric_box(mRow, 4, 'Precision',      result.precision,     C_PANEL, C_DIM, C_FG, true);
draw_metric_box(mRow, 5, 'Usable Recall',  result.usable_recall, C_PANEL, C_DIM, C_FG, true);
draw_metric_box(mRow, 6, 'Reject Recall',  result.reject_recall, C_PANEL, C_DIM, C_FG, true);

% Row 2: ROC curve and confusion matrix.
axROC = uiaxes(tGrid);
axROC.Layout.Row = 2; axROC.Layout.Column = 1;
style_ax(axROC, C_AX, C_DIM);
draw_roc(axROC, result, C_FG, C_DIM);

axCM = uiaxes(tGrid);
axCM.Layout.Row = 2; axCM.Layout.Column = 2;
style_ax(axCM, C_AX, C_DIM);
draw_confusion(axCM, result.cm, ...
    cv_title(result), C_FG, C_DIM);

% Row 3: probability distribution and feature importance.
axProb = uiaxes(tGrid);
axProb.Layout.Row = 3; axProb.Layout.Column = 1;
style_ax(axProb, C_AX, C_DIM);
draw_prob_dist(axProb, result, C_FG, C_DIM);

axImp = uiaxes(tGrid);
axImp.Layout.Row = 3; axImp.Layout.Column = 2;
style_ax(axImp, C_AX, C_DIM);
if ~isempty(imp)
    draw_importance(axImp, imp, featureNames, C_FG, C_DIM);
else
    ax_blank(axImp, ternary(isSelected,'Computing...','Available for selected model only'), ...
        'Feature Importance', C_DIM, C_FG);
end

axRec = uiaxes(tGrid);
axRec.Layout.Row = 4; axRec.Layout.Column = [1 2];
style_ax(axRec, C_AX, C_DIM);
if isfield(result, 'by_recording') && istable(result.by_recording) && ~isempty(result.by_recording)
    draw_recording_bars(axRec, result.by_recording, 'LORO CV by Recording', C_FG, C_DIM);
else
    ax_blank(axRec, 'No recording-level CV metrics', 'LORO CV by Recording', C_DIM, C_FG);
end
end

% =========================================================================
function draw_test_content(container, leadStruct, C_BG, C_AX, C_FG, C_DIM, C_PANEL)
test = leadStruct.test;
tGrid = uigridlayout(container, [3 2]);
tGrid.RowHeight = {84, '1x', '1x'};
tGrid.ColumnWidth = {'1x', '1x'};
tGrid.Padding = [10 10 10 10];
tGrid.RowSpacing = 8;
tGrid.ColumnSpacing = 8;
tGrid.BackgroundColor = C_BG;

mRow = uigridlayout(tGrid, [1 6]);
mRow.Layout.Row = 1;
mRow.Layout.Column = [1 2];
mRow.ColumnWidth = {110, '1x','1x','1x','1x','1x'};
mRow.Padding = [0 0 0 0];
mRow.ColumnSpacing = 8;
mRow.BackgroundColor = C_BG;

uilabel(mRow, 'Text', 'Held-out test', ...
    'FontSize', 12, 'FontWeight', 'bold', 'FontColor', C_FG);
draw_metric_box(mRow, 2, 'Accuracy',       test.acc,           C_PANEL, C_DIM, C_FG, false);
draw_metric_box(mRow, 3, 'Balanced Acc',   test.balanced_acc,  C_PANEL, C_DIM, C_FG, true);
draw_metric_box(mRow, 4, 'Precision',      test.precision,     C_PANEL, C_DIM, C_FG, true);
draw_metric_box(mRow, 5, 'Usable Recall',  test.usable_recall, C_PANEL, C_DIM, C_FG, true);
draw_metric_box(mRow, 6, 'Reject Recall',  test.reject_recall, C_PANEL, C_DIM, C_FG, true);

axCM = uiaxes(tGrid);
axCM.Layout.Row = 2; axCM.Layout.Column = 1;
style_ax(axCM, C_AX, C_DIM);
draw_confusion(axCM, test.cm, 'Held-out Test Confusion Matrix', C_FG, C_DIM);

axProb = uiaxes(tGrid);
axProb.Layout.Row = 2; axProb.Layout.Column = 2;
style_ax(axProb, C_AX, C_DIM);
draw_test_prob_dist(axProb, test, C_FG, C_DIM);

axRec = uiaxes(tGrid);
axRec.Layout.Row = 3; axRec.Layout.Column = [1 2];
style_ax(axRec, C_AX, C_DIM);
if isfield(test, 'by_recording') && istable(test.by_recording) && ~isempty(test.by_recording)
    draw_recording_bars(axRec, test.by_recording, 'Held-out Test by Recording', C_FG, C_DIM);
else
    ax_blank(axRec, 'No held-out test recordings', 'Held-out Test by Recording', C_DIM, C_FG);
end
end

% =========================================================================
function txt = cv_title(result)
mode = "";
if isfield(result, 'validation_mode')
    mode = string(result.validation_mode);
end
if strlength(mode) == 0
    mode = "cross-validation";
end
if contains(mode, "leave_one_recording", 'IgnoreCase', true)
    txt = sprintf('Confusion Matrix  (LORO CV, %d recordings)', result.k_folds);
else
    txt = sprintf('Confusion Matrix  (%d-fold CV)', result.k_folds);
end
end

% =========================================================================
function draw_recording_bars(ax, T, titleText, fgColor, dimColor)
if isempty(T) || ~istable(T) || ~ismember('recording_id', T.Properties.VariableNames)
    ax_blank(ax, 'No recording-level metrics', titleText, dimColor, fgColor);
    return;
end
metric = T.balanced_acc;
names = string(T.recording_id);
if isempty(metric)
    ax_blank(ax, 'No recording-level metrics', titleText, dimColor, fgColor);
    return;
end
[metric, ord] = sort(metric, 'descend', 'MissingPlacement', 'last');
names = names(ord);
nShow = min(numel(metric), 16);
metric = metric(1:nShow);
names = names(1:nShow);
shortNames = cellstr(names);
for ii = 1:numel(shortNames)
    if strlength(shortNames{ii}) > 22
        shortNames{ii} = [char(extractBefore(string(shortNames{ii}), 21)) '...'];
    end
end
cla(ax);
bar(ax, 1:nShow, metric, 'FaceColor', [0.23 0.39 0.58], 'EdgeColor', 'none');
hold(ax, 'on');
yline(ax, 75, '--', 'Color', [0.28 0.78 0.55], 'LineWidth', 1);
yline(ax, 60, '--', 'Color', [0.95 0.78 0.20], 'LineWidth', 1);
hold(ax, 'off');
ylim(ax, [0 100]);
set(ax, 'XTick', 1:nShow, 'XTickLabel', shortNames, ...
    'XTickLabelRotation', 25, 'XColor', dimColor, 'YColor', dimColor, ...
    'TickLabelInterpreter', 'none');
ylabel(ax, 'Balanced accuracy (%)', 'Color', dimColor);
title(ax, titleText, 'Color', fgColor, 'FontSize', 10);
end

% =========================================================================
function draw_test_prob_dist(ax, test, fgColor, dimColor)
if ~isfield(test, 'probs') || isempty(test.probs) || ~any(isfinite(test.probs))
    ax_blank(ax, 'No probability scores available', 'Held-out Test Score Distribution', dimColor, fgColor);
    return;
end
probs = double(test.probs(:));
yTrue = double(test.y_true(:));
p0 = probs(yTrue == 0 & isfinite(probs));
p1 = probs(yTrue == 1 & isfinite(probs));
edges = linspace(0, 1, 22);
if any(probs(isfinite(probs)) < -0.05 | probs(isfinite(probs)) > 1.05)
    vals = probs(isfinite(probs));
    edges = linspace(min(vals), max(vals), 22);
end
hold(ax, 'on');
if ~isempty(p0)
    histogram(ax, p0, edges, 'FaceColor', [0.88 0.32 0.32], 'FaceAlpha', 0.65, ...
        'EdgeColor', 'none', 'DisplayName', 'Rejected');
end
if ~isempty(p1)
    histogram(ax, p1, edges, 'FaceColor', [0.28 0.78 0.55], 'FaceAlpha', 0.65, ...
        'EdgeColor', 'none', 'DisplayName', 'Usable');
end
hold(ax, 'off');
legend(ax, 'Location','best', 'TextColor', fgColor);
xlabel(ax, 'P(usable)', 'Color', dimColor);
ylabel(ax, 'Epoch count', 'Color', dimColor);
title(ax, 'Held-out Test Score Distribution', 'Color', fgColor, 'FontSize', 10);
set(ax, 'XColor', dimColor, 'YColor', dimColor);
end

% =========================================================================
function draw_roc(ax, result, fgColor, dimColor)
if ~isfield(result,'roc_x') || ~isfield(result,'roc_y') || isempty(result.roc_x) || isempty(result.roc_y)
    ax_blank(ax, 'Not available for this model type', 'ROC Curve', dimColor, fgColor);
    return;
end
plot(ax, [0 1], [0 1], '--', 'Color', [0.40 0.42 0.46], 'LineWidth', 1);
hold(ax, 'on');
plot(ax, result.roc_x, result.roc_y, 'Color', [0.28 0.78 0.55], 'LineWidth', 2);
hold(ax, 'off');
auc = NaN;
if isfield(result,'auc'); auc = result.auc; end
if isfinite(auc)
    title(ax, sprintf('ROC Curve  —  AUC = %.3f', auc), 'Color', fgColor, 'FontSize', 10);
else
    title(ax, 'ROC Curve', 'Color', fgColor, 'FontSize', 10);
end
xlabel(ax, 'False Positive Rate  (1 − specificity)', 'Color', dimColor);
ylabel(ax, 'True Positive Rate  (sensitivity)',      'Color', dimColor);
xlim(ax, [0 1]); ylim(ax, [0 1]);
set(ax, 'XColor', dimColor, 'YColor', dimColor);
end

% =========================================================================
function draw_prob_dist(ax, result, fgColor, dimColor)
probs = []; yTrue = [];
if isfield(result,'fold_probs');  probs = result.fold_probs;  end
if isfield(result,'fold_y_true'); yTrue = result.fold_y_true; end
if isempty(probs) || ~any(isfinite(probs))
    ax_blank(ax, 'No probability scores available', 'Score Distribution', dimColor, fgColor);
    return;
end
p0 = probs(yTrue == 0 & isfinite(probs));
p1 = probs(yTrue == 1 & isfinite(probs));
% Check if scores are in [0,1] (calibrated probability) or raw margins
isProb = all(probs(isfinite(probs)) >= -0.05 & probs(isfinite(probs)) <= 1.05);
if isProb
    edges    = linspace(0, 1, 22);
    xLabel   = 'P(usable)  —  out-of-fold';
else
    allVals  = probs(isfinite(probs));
    edges    = linspace(min(allVals), max(allVals), 22);
    xLabel   = 'Decision score  (raw margin)';
end
hold(ax, 'on');
if ~isempty(p0)
    histogram(ax, p0, edges, 'FaceColor', [0.88 0.32 0.32], 'FaceAlpha', 0.65, ...
        'EdgeColor', 'none', 'DisplayName', 'Rejected');
end
if ~isempty(p1)
    histogram(ax, p1, edges, 'FaceColor', [0.28 0.78 0.55], 'FaceAlpha', 0.65, ...
        'EdgeColor', 'none', 'DisplayName', 'Usable');
end
hold(ax, 'off');
legend(ax, 'Location','best', 'TextColor', fgColor);
xlabel(ax, xLabel,          'Color', dimColor);
ylabel(ax, 'Epoch count',   'Color', dimColor);
title(ax,  'Predicted Score Distribution  (out-of-fold CV)', 'Color', fgColor, 'FontSize', 10);
if isProb; xlim(ax, [0 1]); end
set(ax, 'XColor', dimColor, 'YColor', dimColor);
end

% =========================================================================
function draw_importance(ax, imp, featureNames, fgColor, dimColor)
if isempty(imp)
    ax_blank(ax, 'Not available for this model type', 'Feature Importance', dimColor, fgColor);
    return;
end
[sorted, idx] = sort(imp, 'descend');
nShow  = min(10, numel(sorted));
sorted = sorted(1:nShow);
names  = featureNames(idx(1:nShow));
shortNames = cellfun(@clean_feat_name, names, 'UniformOutput', false);
cla(ax);
barh(ax, 1:nShow, sorted, 'FaceColor', [0.23 0.39 0.58], 'EdgeColor', 'none');
set(ax, 'YTick', 1:nShow, 'YTickLabel', shortNames, 'YDir', 'reverse', ...
    'XColor', dimColor, 'YColor', dimColor, 'FontSize', 11, 'TickLabelInterpreter', 'none');
xlabel(ax, 'Importance', 'Color', dimColor);
title(ax, 'Feature Importance  (top 10)', 'Color', fgColor, 'FontSize', 10);
end

function s = clean_feat_name(n)
% Strip common prefixes, replace underscores with spaces, fix decimal notation
prefixes = {'mas_delta_','mas_','ecg_','band_','imu_','bpf_','notch_'};
s = n;
for ii = 1:numel(prefixes)
    if startsWith(s, prefixes{ii})
        s = s(numel(prefixes{ii})+1:end);
        break;
    end
end
s = strrep(s, '_', ' ');
s = regexprep(s, '(\d)p(\d)', '$1.$2');  % 0p5 -> 0.5
if numel(s) > 22; s = [s(1:20) '…']; end
end

% =========================================================================
function draw_confusion(ax, cm, titleText, fgColor, dimColor)
if isempty(cm) || ~all(isfinite(cm(:)))
    ax_blank(ax, 'No confusion data', titleText, dimColor, fgColor);
    return;
end
cm = double(cm);
cmNorm = cm ./ max(sum(cm, 2), 1);
imagesc(ax, cmNorm);
nC   = 64;
cmap = [linspace(0.08,0.06,nC)', linspace(0.09,0.42,nC)', linspace(0.11,0.32,nC)'];
colormap(ax, cmap);
ax.CLim = [0 1];
set(ax, 'XTick',1:2, 'XTickLabel',{'Reject','Usable'}, ...
        'YTick',1:2, 'YTickLabel',{'Reject','Usable'}, ...
        'XColor',dimColor, 'YColor',dimColor, 'FontSize',10);
xlabel(ax, 'Predicted', 'Color', dimColor);
ylabel(ax, 'True',      'Color', dimColor);
title(ax, titleText, 'Color', fgColor, 'FontSize', 10);
total = max(sum(cm(:)), 1);
for rr = 1:2
    for cc = 1:2
        v = cm(rr,cc);
        text(ax, cc, rr, sprintf('%d\n%.1f%%', v, 100*v/total), ...
            'HorizontalAlignment','center','VerticalAlignment','middle', ...
            'Color',fgColor,'FontSize',11,'FontWeight','bold');
    end
end
end

% =========================================================================
function draw_metric_box(parent, col, label, value, bgColor, dimColor, fgColor, useColor)
box = uigridlayout(parent, [2 1]);
box.Layout.Column   = col;
box.RowHeight       = {20, '1x'};
box.Padding         = [6 4 6 4];
box.RowSpacing      = 2;
box.BackgroundColor = bgColor;
titleLbl = uilabel(box, 'Text', label, 'FontColor', dimColor, 'FontSize', 9);
titleLbl.Layout.Row = 1;
if isfinite(value)
    valStr = sprintf('%.1f%%', value);
    if useColor
        if value >= 75;     valColor = [0.28 0.78 0.55];
        elseif value >= 60; valColor = [0.95 0.78 0.20];
        else;               valColor = [0.90 0.35 0.35];
        end
    else
        valColor = fgColor;
    end
else
    valStr   = 'N/A';
    valColor = dimColor;
end
valLbl = uilabel(box, 'Text', valStr, 'FontColor', valColor, ...
    'FontSize', 19, 'FontWeight', 'bold');
valLbl.Layout.Row = 2;
end

% =========================================================================
function ax_blank(ax, bodyText, titleText, dimColor, fgColor)
ax.XAxis.Visible = 'off';
ax.YAxis.Visible = 'off';
text(ax, 0.5, 0.5, bodyText, 'Units','normalized', ...
    'HorizontalAlignment','center', 'Color', dimColor, 'FontSize', 11);
title(ax, titleText, 'Color', fgColor, 'FontSize', 10);
end

% =========================================================================
function style_ax(ax, bgColor, dimColor)
ax.Color     = bgColor;
ax.XColor    = dimColor;
ax.YColor    = dimColor;
ax.GridColor = [0.22 0.22 0.24];
ax.XGrid     = 'off';
ax.YGrid     = 'on';
end

% =========================================================================
function s = make_tab_title(lead, kind, isSelected)
marker = ternary(isSelected, ' ★', '');
s = sprintf('%s — %s%s', char(lead), short_name(char(kind)), marker);
end

function s = short_name(kind)
switch lower(kind)
    case 'tree';     s = 'Tree';
    case 'bag';      s = 'Bag RF';
    case 'rusboost'; s = 'RUSBoost';
    case 'svm';      s = 'SVM';
    case 'lsvm';     s = 'LinSVM';
    case 'knn';      s = 'kNN';
    case 'logistic'; s = 'Logistic';
    otherwise;       s = kind;
end
end

function out = ternary(cond, a, b)
if cond; out = a; else; out = b; end
end
