function label_mas_epoch_gui(feature_mat_path)
% LABEL_MAS_EPOCH_GUI Review two-candidate MAS epochs.
%
% For each recording/lead/epoch group, select exactly one terminal decision:
% fixed BPF+Notch, lead-matched BPF+Notch+NLMS(CH1 RA+LA, CH2 RA+LL),
% corrupted, or skip. Saved labels
% train a binary candidate scorer: selected candidate = 1, rejected candidate
% or corrupted group = 0, skipped/unreviewed = 2.

if nargin < 1 || isempty(feature_mat_path)
    [fn, fd] = uigetfile('*.mat', 'Select mas_epoch_features.mat');
    if isequal(fn, 0); return; end
    feature_mat_path = fullfile(fd, fn);
end
feature_mat_path = resolve_feature_mat_path(feature_mat_path);

d = load(feature_mat_path);
revisedPath = fullfile(fileparts(feature_mat_path), 'revised_mas_labels.mat');
if isfile(revisedPath) && ~isequal(feature_mat_path, revisedPath)
    try
        dr = load(revisedPath, 'y_manual_group', 'good_combo_mask');
        if isfield(dr, 'y_manual_group');  d.y_manual_group  = dr.y_manual_group;  end
        if isfield(dr, 'good_combo_mask'); d.good_combo_mask = dr.good_combo_mask; end
    catch
    end
end

required = {'X','featureNames','epochInfo','preview','config'};
for rr = 1:numel(required)
    if ~isfield(d, required{rr})
        error('Missing "%s" in %s.', required{rr}, feature_mat_path);
    end
end

app = struct();
app.X = d.X;
app.featureNames = d.featureNames;
app.epochInfo = d.epochInfo;
app.preview = d.preview;
app.config = d.config;
app.featurePath = feature_mat_path;
app.groupIds = unique(string(app.epochInfo.group_id), 'stable');
app.current = 1;

availableIds = unique(double(app.epochInfo.combo_id), 'stable');
preferredIds = [1 5];
app.comboIds = preferredIds(ismember(preferredIds, availableIds));
if isempty(app.comboIds)
    app.comboIds = availableIds(:)';
end
app.comboIds = app.comboIds(:)';
app.nCombos = numel(app.comboIds);
app.maskWidth = max(6, max(app.comboIds));
app.comboNames = strings(app.nCombos, 1);
for comboNameIdx = 1:app.nCombos
    rowIdx = find(double(app.epochInfo.combo_id) == app.comboIds(comboNameIdx), 1);
    if isempty(rowIdx)
        app.comboNames(comboNameIdx) = "combo " + string(app.comboIds(comboNameIdx));
    else
        app.comboNames(comboNameIdx) = string(app.epochInfo.combo_name(rowIdx));
    end
end

app.yGroup = repmat(uint8(255), numel(app.groupIds), 1); % 255 open, 254 skip, 253 both usable, 0 corrupt, active combo id otherwise
if isfield(d, 'y_manual_group') && numel(d.y_manual_group) == numel(app.groupIds)
    app.yGroup = uint8(d.y_manual_group(:));
    activeOrTerminal = app.yGroup == 255 | app.yGroup == 254 | app.yGroup == 253 | app.yGroup == 0 | ismember(double(app.yGroup), app.comboIds);
    app.yGroup(~activeOrTerminal) = uint8(255);
end

if isfield(d, 'good_combo_mask')
    app.goodMask = normalize_loaded_mask(d.good_combo_mask, numel(app.groupIds), app.maskWidth, app.comboIds);
else
app.goodMask = false(numel(app.groupIds), app.maskWidth);
end
for initIdx = 1:numel(app.yGroup)
    if app.yGroup(initIdx) == uint8(253)
        app.goodMask(initIdx, app.comboIds) = true;
    elseif ismember(double(app.yGroup(initIdx)), app.comboIds)
        app.goodMask(initIdx, :) = false;
        app.goodMask(initIdx, double(app.yGroup(initIdx))) = true;
    end
end

C_BG = [0.10 0.11 0.13];
C_AX = [0.08 0.09 0.11];
C_FG = [0.86 0.88 0.90];
C_DIM = [0.58 0.64 0.70];

app.fig = uifigure('Name','MAS Fixed/Lead-Matched RA-Pair NLMS Epoch Reviewer', ...
    'Position',[60 80 1280 760], 'Color', C_BG, 'WindowKeyPressFcn', @on_key);
app.fig.CloseRequestFcn = @on_close;
root = uigridlayout(app.fig, [4 1]);
root.RowHeight = {42, 30, '1x', 56};
root.Padding = [10 8 10 8];
root.RowSpacing = 8;
root.BackgroundColor = C_BG;

nav = uigridlayout(root, [1 14]);
nav.Layout.Row = 1;
nav.ColumnWidth = {82, 56, 40, 62, '1x', 34, 24, 38, 80, 102, 114, 106, 76, 118};
nav.BackgroundColor = C_BG;
nav.Padding = [0 0 0 0];
app.prevBtn = uibutton(nav, 'Text','Prev', 'ButtonPushedFcn', @on_prev);
app.prevBtn.Layout.Column = 1;
app.idxEdit = uieditfield(nav, 'numeric', 'Value',1, ...
    'Limits',[1 max(1,numel(app.groupIds))], 'ValueChangedFcn', @on_jump);
app.idxEdit.Layout.Column = 2;
app.totalLbl = uilabel(nav, 'Text', sprintf('/ %d', numel(app.groupIds)), 'FontColor', C_DIM);
app.totalLbl.Layout.Column = 3;
app.nextBtn = uibutton(nav, 'Text','Next', 'ButtonPushedFcn', @on_next);
app.nextBtn.Layout.Column = 4;
app.statusLbl = uilabel(nav, 'Text','', 'FontColor', C_DIM);
app.statusLbl.Layout.Column = 5;
app.qrsLbl = uilabel(nav, 'Text','QRS', 'FontColor', C_DIM, 'HorizontalAlignment','right', ...
    'Tooltip','Blinks red when the candidates have different in-epoch QRS counts.');
app.qrsLbl.Layout.Column = 6;
app.qrsLamp = uilamp(nav, 'Color',[0.15 0.18 0.16], ...
    'Tooltip','QRS count agreement across candidates');
app.qrsLamp.Layout.Column = 7;
app.qrsMismatch = false;
app.qrsFlashOn = false;
app.qrsFlashTimer = timer('ExecutionMode','fixedRate', 'Period',0.25, ...
    'TimerFcn', @(~,~) qrs_flash_tick());
start(app.qrsFlashTimer);
app.viewLbl = uilabel(nav, 'Text','View', 'FontColor', C_DIM, 'HorizontalAlignment','right');
app.viewLbl.Layout.Column = 8;
app.viewDd = uidropdown(nav, ...
    'Items', {'5 s','10 s','15 s','30 s','All'}, ...
    'Value', '10 s', ...
    'ValueChangedFcn', @on_view_change, ...
    'Tooltip', 'Displayed time span around the labelled epoch. Wider previews require re-extracting with preview_context_sec.');
app.viewDd.Layout.Column = 9;
app.nextOpenBtn = uibutton(nav, 'Text','Next Open', 'ButtonPushedFcn', @on_next_open);
app.nextOpenBtn.Layout.Column = 10;
app.saveBtn = uibutton(nav, 'Text','Save Labels', 'ButtonPushedFcn', @on_save);
app.saveBtn.Layout.Column = 11;
app.corruptTopBtn = uibutton(nav, 'Text','Corrupted', 'ButtonPushedFcn', @on_corrupt, ...
    'BackgroundColor',[0.42 0.12 0.12], 'FontColor',[1 0.9 0.9]);
app.corruptTopBtn.Layout.Column = 12;
app.skipTopBtn = uibutton(nav, 'Text','Skip', 'ButtonPushedFcn', @on_skip);
app.skipTopBtn.Layout.Column = 13;
app.importBtn = uibutton(nav, 'Text','Import Labels', ...
    'BackgroundColor',[0.28 0.28 0.32], 'FontColor', C_DIM, ...
    'ButtonPushedFcn', @on_import_labels, ...
    'Tooltip','Import matching labels from a previous revised_mas_labels.mat');
app.importBtn.Layout.Column = 14;

app.infoLbl = uilabel(root, 'Text','', 'FontColor', C_FG, 'FontSize', 12);
app.infoLbl.Layout.Row = 2;

grid = uigridlayout(root, [1 app.nCombos]);
grid.Layout.Row = 3;
grid.RowHeight = {'1x'};
grid.ColumnWidth = repmat({'1x'}, 1, app.nCombos);
grid.RowSpacing = 8;
grid.ColumnSpacing = 8;
grid.BackgroundColor = C_BG;
app.ax = gobjects(app.nCombos,1);
for axIdx = 1:app.nCombos
    app.ax(axIdx) = uiaxes(grid);
    app.ax(axIdx).Layout.Row = 1;
    app.ax(axIdx).Layout.Column = axIdx;
    style_axis(app.ax(axIdx), C_AX, C_DIM);
end

buttons = uigridlayout(root, [1 6]);
buttons.Layout.Row = 4;
buttons.ColumnWidth = {'1x','1x',112,110,92,90};
buttons.BackgroundColor = C_BG;
buttons.Padding = [0 0 0 0];
app.comboBtns = gobjects(app.nCombos,1);
for btnIdx = 1:app.nCombos
    comboId = app.comboIds(btnIdx);
    app.comboBtns(btnIdx) = uibutton(buttons, 'Text', sprintf('%d  %s', comboId, char(app.comboNames(btnIdx))), ...
        'ButtonPushedFcn', @(~,~) select_combo(comboId), ...
        'BackgroundColor',[0.18 0.34 0.22], 'FontColor',[0.88 1.00 0.90]);
    app.comboBtns(btnIdx).Layout.Column = btnIdx;
end
bothBtn = uibutton(buttons, 'Text','Both OK', 'ButtonPushedFcn', @on_both_usable, ...
    'BackgroundColor',[0.22 0.38 0.36], 'FontColor',[0.90 1.00 0.96], ...
    'Tooltip','Both candidates are monitoring-usable; exclude this epoch from the preference selector.');
bothBtn.Layout.Column = 3;
clearBtn = uibutton(buttons, 'Text','Open', 'ButtonPushedFcn', @on_clear);
clearBtn.Layout.Column = 4;
corruptBtn = uibutton(buttons, 'Text','Corrupted', 'ButtonPushedFcn', @on_corrupt, ...
    'BackgroundColor',[0.42 0.12 0.12], 'FontColor',[1 0.9 0.9]);
corruptBtn.Layout.Column = 5;
skipBtn = uibutton(buttons, 'Text','Skip', 'ButtonPushedFcn', @on_skip);
skipBtn.Layout.Column = 6;

update_display();

    function on_close(~, ~)
        cleanup_qrs_timer();
        delete(app.fig);
    end

    function cleanup_qrs_timer()
        try
            if isfield(app, 'qrsFlashTimer') && isvalid(app.qrsFlashTimer)
                stop(app.qrsFlashTimer);
                delete(app.qrsFlashTimer);
            end
        catch
        end
    end

    function qrs_flash_tick()
        if ~isfield(app, 'fig') || ~isvalid(app.fig)
            cleanup_qrs_timer();
            return;
        end
        if ~app.qrsMismatch
            app.qrsFlashOn = false;
            if isvalid(app.qrsLamp)
                app.qrsLamp.Color = [0.12 0.55 0.25];
            end
            return;
        end
        app.qrsFlashOn = ~app.qrsFlashOn;
        if isvalid(app.qrsLamp)
            if app.qrsFlashOn
                app.qrsLamp.Color = [1.00 0.05 0.02];
            else
                app.qrsLamp.Color = [0.18 0.03 0.03];
            end
        end
    end

    function on_prev(~, ~)
        app.current = max(1, app.current - 1);
        update_display();
    end

    function on_next(~, ~)
        app.current = min(numel(app.groupIds), app.current + 1);
        update_display();
    end

    function on_jump(~, ~)
        app.current = max(1, min(numel(app.groupIds), round(app.idxEdit.Value)));
        update_display();
    end

    function on_view_change(~, ~)
        update_display();
    end

    function on_next_open(~, ~)
        openGroups = app.yGroup == 255 & ~any(app.goodMask(:, app.comboIds), 2);
        idx = find(openGroups & (1:numel(app.yGroup))' > app.current, 1);
        if isempty(idx)
            idx = find(openGroups, 1);
        end
        if isempty(idx)
            uialert(app.fig, 'All groups have a label or skip state.', 'Done');
        else
            app.current = idx;
            update_display();
        end
    end

    function select_combo(comboId)
        app.goodMask(app.current, :) = false;
        app.goodMask(app.current, comboId) = true;
        app.yGroup(app.current) = uint8(comboId);
        advance_after_terminal_label();
    end

    function on_both_usable(~, ~)
        app.goodMask(app.current, :) = false;
        app.goodMask(app.current, app.comboIds) = true;
        app.yGroup(app.current) = uint8(253);
        advance_after_terminal_label();
    end

    function on_corrupt(~, ~)
        app.goodMask(app.current, :) = false;
        app.yGroup(app.current) = uint8(0);
        advance_after_terminal_label();
    end

    function on_skip(~, ~)
        app.goodMask(app.current, :) = false;
        app.yGroup(app.current) = uint8(254);
        advance_after_terminal_label();
    end

    function on_clear(~, ~)
        app.goodMask(app.current, :) = false;
        app.yGroup(app.current) = uint8(255);
        update_display();
    end

    function advance_after_terminal_label()
        openGroups = app.yGroup == 255 & ~any(app.goodMask(:, app.comboIds), 2);
        nxt = find(openGroups & (1:numel(app.yGroup))' > app.current, 1);
        if ~isempty(nxt)
            app.current = nxt;
        elseif app.current < numel(app.groupIds)
            app.current = app.current + 1;
        end
        update_display();
    end

    function on_key(~, event)
        switch lower(event.Key)
            case {'1','numpad1'}
                if any(app.comboIds == 1); select_combo(1); end
            case {'2','numpad2','5','numpad5'}
                if any(app.comboIds == 5); select_combo(5); end
            case 'b'; on_both_usable([], []);
            case 'x'; on_corrupt([], []);
            case 's'; on_skip([], []);
            case 'c'; on_clear([], []);
            case {'return','enter'}; on_next_open([], []);
            case 'rightarrow'; on_next([], []);
            case 'leftarrow'; on_prev([], []);
        end
    end

    function update_display()
        nGroups = numel(app.groupIds);
        if nGroups == 0; return; end
        app.current = max(1, min(app.current, nGroups));
        gid = app.groupIds(app.current);
        rows = find(string(app.epochInfo.group_id) == gid);
        [~, ord] = sort(double(app.epochInfo.combo_id(rows)));
        rows = rows(ord);
        info0 = app.epochInfo(rows(1), :);
        app.idxEdit.Value = app.current;
        app.infoLbl.Text = sprintf('%s | %s | %s | %s | t=%.3fs | %s + %s | %s/%s | QRS: ^ epoch, o context', ...
            char(string(info0.recording_id)), char(string(info0.condition)), char(string(info0.cohort)), char(string(info0.lead)), ...
            info0.epoch_start_s, char(string(info0.bpf)), char(string(info0.notch)), char(string(info0.mas_algorithm)), char(string(info0.mas_ref_kind)));

        lbl = app.yGroup(app.current);
        maskRow = app.goodMask(app.current, :);
        reviewed = app.yGroup ~= 255 | any(app.goodMask(:, app.comboIds), 2);
        app.statusLbl.Text = sprintf('Reviewed %d/%d   decision: %s', ...
            nnz(reviewed), nGroups, label_text(lbl, maskRow, app.comboIds));

        qrsCounts = nan(app.nCombos, 1);
        for slotIdx = 1:app.nCombos
            comboId = app.comboIds(slotIdx);
            ax = app.ax(slotIdx);
            cla(ax);
            rowIdx = rows(double(app.epochInfo.combo_id(rows)) == comboId);
            if isempty(rowIdx)
                title(ax, sprintf('%d missing', comboId));
                continue;
            end
            rowIdx = rowIdx(1);
            t = double(app.preview.times{rowIdx});
            s = double(app.preview.signals{rowIdx});
            epochSec = row_epoch_sec(app.epochInfo(rowIdx, :), app.config);
            [xlo, xhi] = display_xrange(t, epochSec, app.viewDd.Value);
            hold(ax, 'on');
            if any(isfinite(s))
                visible = isfinite(s) & t >= xlo & t <= xhi;
                if nnz(visible) < 4
                    visible = isfinite(s);
                end
                ylo = prctile(s(visible), 1);
                yhi = prctile(s(visible), 99);
                pad = max(0.02, 0.15 * max(yhi - ylo, eps));
                patch(ax, [0 epochSec epochSec 0], ...
                    [ylo-pad ylo-pad yhi+pad yhi+pad], [0.25 0.22 0.10], ...
                    'EdgeColor','none', 'FaceAlpha', 0.45);
                plot(ax, t, s, 'Color',[0.28 0.78 0.55], 'LineWidth', 1.15);
                [pkT, pkY, pkInEpoch] = detect_qrs_peaks(t, s, epochSec);
                if ~isempty(pkT)
                    if any(~pkInEpoch)
                        plot(ax, pkT(~pkInEpoch), pkY(~pkInEpoch), 'o', ...
                            'MarkerSize', 4, 'LineWidth', 0.9, ...
                            'Color',[0.62 0.66 0.72], 'MarkerFaceColor',[0.16 0.17 0.19]);
                    end
                    if any(pkInEpoch)
                        plot(ax, pkT(pkInEpoch), pkY(pkInEpoch), '^', ...
                            'MarkerSize', 7, 'LineWidth', 1.1, ...
                            'Color',[1.00 0.78 0.18], 'MarkerFaceColor',[1.00 0.78 0.18]);
                    end
                end
                qrsCounts(slotIdx) = nnz(pkInEpoch);
                text(ax, 0.02, 0.94, sprintf('QRS peaks: %d', nnz(pkInEpoch)), ...
                    'Units','normalized', 'Color',[1.00 0.82 0.28], ...
                    'FontSize',9, 'FontWeight','bold', ...
                    'BackgroundColor',[0.08 0.09 0.11]);
                ylim(ax, [ylo-pad yhi+pad]);
            end
            xline(ax, 0, '--', 'Color',[0.95 0.78 0.20]);
            xline(ax, epochSec, '--', 'Color',[0.95 0.78 0.20]);
            hold(ax, 'off');
            if ~isempty(t) && all(isfinite([min(t), max(t)])) && max(t) > min(t)
                xlim(ax, [xlo xhi]);
            end
            title(ax, candidate_title(rowIdx), 'Color', title_color(lbl, maskRow, comboId), 'FontSize', 10);
        end
        update_qrs_lamp(qrsCounts);
        update_candidate_buttons(maskRow, lbl);
    end

    function update_qrs_lamp(qrsCounts)
        validCounts = qrsCounts(isfinite(qrsCounts));
        app.qrsMismatch = numel(validCounts) >= 2 && any(validCounts ~= validCounts(1));
        if app.qrsMismatch
            app.qrsLamp.Tooltip = sprintf('QRS count mismatch across candidates: %s', ...
                strjoin(string(validCounts(:).'), ' vs '));
            qrs_flash_tick();
        else
            app.qrsFlashOn = false;
            if isvalid(app.qrsLamp)
                app.qrsLamp.Color = [0.12 0.55 0.25];
                if isempty(validCounts)
                    app.qrsLamp.Tooltip = 'No QRS count available for this epoch';
                else
                    app.qrsLamp.Tooltip = sprintf('QRS counts agree: %d', validCounts(1));
                end
            end
        end
    end

    function update_candidate_buttons(maskRow, lbl)
        for slotIdx = 1:app.nCombos
            comboId = app.comboIds(slotIdx);
            if maskRow(comboId)
                app.comboBtns(slotIdx).BackgroundColor = [0.18 0.52 0.28];
                app.comboBtns(slotIdx).FontColor = [0.92 1.00 0.92];
            elseif lbl == 0
                app.comboBtns(slotIdx).BackgroundColor = [0.28 0.18 0.18];
                app.comboBtns(slotIdx).FontColor = [0.90 0.82 0.82];
            else
                app.comboBtns(slotIdx).BackgroundColor = [0.18 0.24 0.30];
                app.comboBtns(slotIdx).FontColor = [0.86 0.90 0.94];
            end
        end
    end

    function ttl = candidate_title(rowIdx)
        info = app.epochInfo(rowIdx, :);
        feat = app.X(rowIdx, :);
        dPct = feature_value(feat, 'mas_delta_rms_pct');
        b05 = feature_value(feat, 'band_0p5_8_change_db');
        qrs = feature_value(feat, 'ecg_qrs_artifact_ratio');
        ttl = sprintf('%d  %s   delta %.1f%%   0.5-8 %.1f dB   QRS/art %.2f', ...
            double(info.combo_id), char(string(info.combo_name)), dPct, b05, qrs);
    end

    function v = feature_value(row, name)
        idx = find(strcmpi(string(app.featureNames), string(name)), 1);
        if isempty(idx); v = NaN; else; v = row(idx); end
    end

    function on_import_labels(~, ~)
        [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat to import from', ...
            fileparts(app.featurePath));
        if isequal(fn, 0); return; end
        fpath = fullfile(fd, fn);
        try
            dr = load(fpath, 'y_manual_group', 'good_combo_mask', 'groupLabels');
        catch ME
            uialert(app.fig, ME.message, 'Import failed');
            return;
        end
        if ~isfield(dr, 'groupLabels') || ~isfield(dr, 'y_manual_group') || ~isfield(dr, 'good_combo_mask')
            uialert(app.fig, 'File is missing required label fields.', 'Import failed');
            return;
        end
        oldIds = string(dr.groupLabels.group_id(:));
        oldY = uint8(dr.y_manual_group(:));
        oldMask = normalize_loaded_mask(dr.good_combo_mask, numel(oldY), app.maskWidth, app.comboIds);
        nImported = 0;
        nSkipped = 0;
        for importIdx = 1:numel(app.groupIds)
            matchIdx = find(oldIds == app.groupIds(importIdx), 1);
            if isempty(matchIdx); continue; end
            app.goodMask(importIdx,:) = false;
            if oldY(matchIdx) == uint8(0) || oldY(matchIdx) == uint8(254)
                app.yGroup(importIdx) = oldY(matchIdx);
                nImported = nImported + 1;
                continue;
            end
            selected = app.comboIds(oldMask(matchIdx, app.comboIds));
            if ~isempty(selected)
                if numel(selected) > 1
                    app.yGroup(importIdx) = uint8(253);
                    app.goodMask(importIdx, selected) = true;
                else
                    app.yGroup(importIdx) = uint8(selected(1));
                    app.goodMask(importIdx, selected(1)) = true;
                end
                nImported = nImported + 1;
            else
                app.yGroup(importIdx) = uint8(255);
                nSkipped = nSkipped + 1;
            end
        end
        update_display();
        uialert(app.fig, sprintf('Imported %d labels. %d matched labels were outside the active two-candidate set.', ...
            nImported, nSkipped), 'Import complete');
    end

    function on_save(~, ~)
        y_manual_group = app.yGroup;
        y_final = repmat(uint8(2), height(app.epochInfo), 1);
        good_combo_mask = app.goodMask;
        best_combo_id = NaN(numel(app.groupIds), 1);
        selected_combo_id = NaN(numel(app.groupIds), 1);
        good_combo_ids = strings(numel(app.groupIds), 1);
        decision_label = strings(numel(app.groupIds), 1);
        for groupIdx = 1:numel(app.groupIds)
            rows = find(string(app.epochInfo.group_id) == app.groupIds(groupIdx));
            lbl = y_manual_group(groupIdx);
            maskRow = good_combo_mask(groupIdx, :);
            selected = app.comboIds(maskRow(app.comboIds));
            if lbl == 0
                y_final(rows) = uint8(0);
                best_combo_id(groupIdx) = 0;
                selected_combo_id(groupIdx) = 0;
                good_combo_ids(groupIdx) = "corrupted";
                decision_label(groupIdx) = "corrupted";
            elseif ~isempty(selected)
                y_final(rows) = uint8(0);
                for selIdx = 1:numel(selected)
                    hit = rows(double(app.epochInfo.combo_id(rows)) == selected(selIdx));
                    y_final(hit) = uint8(1);
                end
                best_combo_id(groupIdx) = selected(1);
                selected_combo_id(groupIdx) = selected(1);
                good_combo_ids(groupIdx) = strjoin(string(selected), "+");
                if numel(selected) > 1
                    decision_label(groupIdx) = "both_usable";
                    y_manual_group(groupIdx) = uint8(253);
                else
                    decision_label(groupIdx) = decision_name(selected(1));
                end
            elseif lbl == 254
                y_final(rows) = uint8(2);
                good_combo_ids(groupIdx) = "skip";
                decision_label(groupIdx) = "skip";
            else
                good_combo_ids(groupIdx) = "open";
                decision_label(groupIdx) = "open";
            end
        end
        goodCols = array2table(good_combo_mask, ...
            'VariableNames', cellstr(compose('good_combo_%d', 1:app.maskWidth)));
        groupLabels = table(app.groupIds(:), best_combo_id, selected_combo_id, good_combo_ids, ...
            decision_label, y_manual_group, ...
            'VariableNames', {'group_id','best_combo_id','selected_combo_id','good_combo_ids','decision_label','y_manual_group'});
        groupLabels = [groupLabels goodCols];
        X = app.X;
        featureNames = app.featureNames;
        epochInfo = app.epochInfo;
        preview = app.preview;
        config = app.config;
        config.candidate_policy = "fixed_or_ra_la_ra_ll_nlms_or_corrupt";
        config.firmware_combo_ids = uint8(app.comboIds);
        outDir = fileparts(app.featurePath);
        matOut = fullfile(outDir, 'revised_mas_labels.mat');
        save(matOut, 'X', 'featureNames', 'epochInfo', 'preview', 'config', ...
            'y_manual_group', 'good_combo_mask', 'y_final', 'groupLabels', '-v7.3');
        epochInfo.y_final = y_final;
        writetable(epochInfo, fullfile(outDir, 'revised_mas_variant_labels.csv'));
        writetable(groupLabels, fullfile(outDir, 'revised_mas_group_labels.csv'));
        uialert(app.fig, sprintf('Saved labels to:\n%s', matOut), 'Saved');
    end
end

function mask = normalize_loaded_mask(rawMask, nRows, maskWidth, comboIds)
mask = false(nRows, maskWidth);
raw = logical(rawMask);
n = min(nRows, size(raw, 1));
if size(raw, 2) >= maskWidth
    mask(1:n, :) = raw(1:n, 1:maskWidth);
elseif size(raw, 2) == numel(comboIds)
    for ii = 1:numel(comboIds)
        mask(1:n, comboIds(ii)) = raw(1:n, ii);
    end
else
    cols = min(maskWidth, size(raw, 2));
    mask(1:n, 1:cols) = raw(1:n, 1:cols);
end
inactive = true(1, maskWidth);
inactive(comboIds) = false;
mask(:, inactive) = false;
end

function txt = label_text(lbl, maskRow, comboIds)
selected = comboIds(maskRow(comboIds));
if numel(selected) > 1
    txt = 'both usable';
elseif ~isempty(selected)
    txt = decision_name(selected(1));
elseif lbl == 255
    txt = 'open';
elseif lbl == 254
    txt = 'skip';
elseif lbl == 253
    txt = 'both usable';
elseif lbl == 0
    txt = 'corrupted';
else
    txt = sprintf('combo %d', lbl);
end
end

function c = title_color(lbl, maskRow, comboId)
if maskRow(comboId)
    c = [0.35 1.00 0.50];
elseif lbl == 0
    c = [1.00 0.42 0.42];
else
    c = [0.78 0.78 0.78];
end
end

function name = decision_name(comboId)
switch double(comboId)
    case 1
        name = "fixed";
    case 5
        name = "ra_la_ra_ll_lms";
    otherwise
        name = "combo_" + string(comboId);
end
end

function epochSec = row_epoch_sec(info, config)
epochSec = NaN;
if istable(info) && ismember('epoch_sec', info.Properties.VariableNames)
    epochSec = double(info.epoch_sec(1));
end
if (~isfinite(epochSec) || epochSec <= 0) && isstruct(config) && isfield(config, 'epoch_sec')
    epochSec = double(config.epoch_sec);
end
if ~isfinite(epochSec) || epochSec <= 0
    epochSec = 1.0;
end
end

function [xlo, xhi] = display_xrange(t, epochSec, viewValue)
t = double(t(:));
t = t(isfinite(t));
if isempty(t)
    xlo = 0;
    xhi = max(1.0, epochSec);
    return;
end
dataLo = min(t);
dataHi = max(t);
if dataHi <= dataLo
    xlo = dataLo;
    xhi = dataLo + max(1.0, epochSec);
    return;
end

txt = string(viewValue);
if strcmpi(txt, "All")
    xlo = dataLo;
    xhi = dataHi;
    return;
end
winSec = str2double(extractBefore(txt, " s"));
if ~isfinite(winSec) || winSec <= 0
    winSec = 10.0;
end
available = dataHi - dataLo;
if winSec >= available
    xlo = dataLo;
    xhi = dataHi;
    return;
end
center = 0.5 * max(epochSec, 1e-6);
xlo = center - 0.5 * winSec;
xhi = center + 0.5 * winSec;
if xlo < dataLo
    xhi = xhi + (dataLo - xlo);
    xlo = dataLo;
end
if xhi > dataHi
    xlo = xlo - (xhi - dataHi);
    xhi = dataHi;
end
xlo = max(dataLo, xlo);
xhi = min(dataHi, xhi);
end

function [pkT, pkY, inEpoch] = detect_qrs_peaks(t, y, epochSec)
pkT = [];
pkY = [];
inEpoch = false(0, 1);
t = double(t(:));
y = double(y(:));
n = min(numel(t), numel(y));
t = t(1:n);
y = y(1:n);
goodT = isfinite(t);
if nnz(goodT) < 8
    return;
end
t = t(goodT);
y = y(goodT);
goodY = isfinite(y);
if nnz(goodY) < 8
    return;
end
if any(~goodY)
    sampleIdx = (1:numel(y))';
    y(~goodY) = interp1(sampleIdx(goodY), y(goodY), sampleIdx(~goodY), 'linear', 'extrap');
end
plotY = y;
dt = diff(t);
dt = dt(isfinite(dt) & dt > 0);
if isempty(dt)
    return;
end
Fs = 1 / median(dt);
if ~isfinite(Fs) || Fs <= 0
    return;
end

y = y - median(y, 'omitnan');
baseWin = max(3, round(0.60 * Fs));
if mod(baseWin, 2) == 0
    baseWin = baseWin + 1;
end
if baseWin < numel(y)
    y = y - movmedian(y, baseWin, 'Endpoints', 'shrink');
end
dy = [0; diff(y)];
envWin = max(3, round(0.080 * Fs));
env = movmean(dy .^ 2, envWin, 'Endpoints', 'shrink');
env(~isfinite(env)) = 0;
if max(env) <= 0
    return;
end

medEnv = median(env, 'omitnan');
madEnv = median(abs(env - medEnv), 'omitnan') + eps;
thr = max(medEnv + 4 * madEnv, prctile(env, 82));
refrac = max(1, round(0.280 * Fs));
search = max(1, round(0.080 * Fs));
candidate = find(env >= thr & env >= [env(1); env(1:end-1)] & env >= [env(2:end); env(end)]);
if isempty(candidate)
    return;
end

pkIdx = zeros(numel(candidate), 1);
pkCount = 0;
for ii = 1:numel(candidate)
    c = candidate(ii);
    lo = max(1, c - search);
    hi = min(numel(y), c + search);
    [~, rel] = max(abs(y(lo:hi)));
    p = lo + rel - 1;
    if pkCount == 0 || (p - pkIdx(pkCount)) >= refrac
        pkCount = pkCount + 1;
        pkIdx(pkCount) = p;
    elseif abs(y(p)) > abs(y(pkIdx(pkCount)))
        pkIdx(pkCount) = p;
    end
end
pkIdx = unique(pkIdx(1:pkCount), 'stable');
if isempty(pkIdx)
    return;
end
pkT = t(pkIdx);
pkY = plotY(pkIdx);
inEpoch = pkT >= 0 & pkT <= epochSec;
end

function style_axis(ax, bg, fg)
ax.Color = bg;
ax.XColor = fg;
ax.YColor = fg;
ax.GridColor = [0.24 0.24 0.26];
ax.XGrid = 'on';
ax.YGrid = 'on';
xlabel(ax, 'Time relative to epoch start (s)', 'Color', fg);
ylabel(ax, 'mV', 'Color', fg);
end

function pathOut = resolve_feature_mat_path(pathIn)
pathOut = char(string(pathIn));
if isfile(pathOut)
    return;
end

repoRoot = repo_root_from_current_dir(fileparts(mfilename('fullpath')));
candidate = fullfile(repoRoot, pathOut);
if isfile(candidate)
    pathOut = candidate;
    return;
end

% If MATLAB is currently inside a subfolder, a repo-relative path can appear
% nested after the current directory. Trim back to the support-tools marker.
marker = ['Support_Tools' filesep];
hit = strfind(pathOut, marker);
if isempty(hit)
    marker = 'Support_Tools/';
    hit = strfind(pathOut, marker);
end
if ~isempty(hit)
    rel = pathOut(hit(1):end);
    rel = strrep(rel, '/', filesep);
    candidate = fullfile(repoRoot, rel);
    if isfile(candidate)
        pathOut = candidate;
        return;
    end
end
end

function repo = repo_root_from_current_dir(thisDir)
repo = char(thisDir);
for rootIdx = 1:8
    if isfolder(fullfile(repo, '.git')) || isfolder(fullfile(repo, 'source'))
        return;
    end
    parent = fileparts(repo);
    if strcmp(parent, repo)
        break;
    end
    repo = parent;
end
end
