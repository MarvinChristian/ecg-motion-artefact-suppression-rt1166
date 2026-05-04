function label_epoch_gui(feature_mat_path)
% LABEL_EPOCH_GUI  Manual epoch quality reviewer for the motion epoch classifier.
%
% Loads the feature matrix produced by extract_epoch_features, shows the
% filtered ECG trace and IMU accel signals for each epoch, and lets you
% manually label each epoch before saving for use in train_epoch_classifier.
%
% Usage
% -----
%   label_epoch_gui()                          % opens file-picker dialog
%   label_epoch_gui('path/epoch_features.mat')
%
% Keyboard shortcuts
% ------------------
%   C  or  Enter     label current epoch CLEAN and advance
%   X                label current epoch CORRUPTED and advance
%   S                mark current epoch SKIP (uncertain) and advance
%   ←  / →           step back / forward without labelling
%
% What each panel shows
% ----------------------
%   ECG panel   : selected BPF/notch from epochInfo, matching extraction.
%                 The yellow shaded band is the actual epoch window.
%                 Context (0.5 s each side) shown in green outside the band.
%   IMU panel   : 3D accel norm (gravity removed) per site.
%                 Blue=site 0 LL, Red=site 1 LA, Green=site 2 RA.
%                 Matching the IMU features used by the classifier.
%   Bottom bar  : key feature values at a glance, current label,
%                 and running review progress.
%
% Saved output  (revised_labels.mat + revised_labels.csv)
% --------------------------------------------------------
%   y_manual  your labels: 1=clean, 0=corrupted, 2=skip, 255=not reviewed
%   y_final   confirmed labels only: 0/1 where reviewed, 2 (skip) elsewhere
%   X, featureNames, epochInfo  unchanged from input

if nargin < 1; feature_mat_path = ''; end

% ─── Shared mutable state ────────────────────────────────────────────────────
app              = struct();
app.loaded       = false;
app.X            = [];
app.y_manual     = uint8([]);   % 255=not reviewed  0/1=label  2=skip
app.featureNames = {};
app.epochInfo    = table();
app.currentEpoch = 1;
app.manifest     = table();
app.recCache     = containers.Map('KeyType','char','ValueType','any');
app.featurePath  = '';
app.epochSec     = 0.500;   % assumed epoch duration — matches extract_epoch_features default
app.ctxSec       = 0.500;   % context shown on each side of the epoch window
app.bpf_id       = 1;       % B1: Butterworth 8th order 0.5-40 Hz
app.notch_id     = 1;       % N1: IIR 50 Hz notch
app.paths        = gui_local_paths();

% ─── Figure and layout ───────────────────────────────────────────────────────
app.fig = uifigure( ...
    'Name',        'Epoch Label Reviewer', ...
    'Position',    [50 50 1300 840], ...
    'Color',       [0.11 0.12 0.14], ...
    'KeyPressFcn', @on_key);

outer = uigridlayout(app.fig, [5 1]);
outer.RowHeight   = {44, 30, '2.2x', '1x', 52};
outer.ColumnWidth = {'1x'};
outer.Padding     = [10 8 10 8];
outer.RowSpacing  = 5;

% ── Row 1 : navigation bar ───────────────────────────────────────────────────
navGrid = uigridlayout(outer, [1 9]);
navGrid.Layout.Row    = 1;
navGrid.Layout.Column = 1;
navGrid.ColumnWidth   = {108, 70, 56, 28, 70, '1x', 148, 108, 120};
navGrid.Padding       = [0 4 0 4];
navGrid.ColumnSpacing = 5;

app.loadBtn = uibutton(navGrid, 'Text', 'Load .mat', ...
    'ButtonPushedFcn', @on_load_btn);
app.loadBtn.Layout.Column = 1;

app.prevBtn = uibutton(navGrid, 'Text', '◄  Prev', ...
    'ButtonPushedFcn', @on_prev, 'Enable', 'off');
app.prevBtn.Layout.Column = 2;

app.epochEdit = uieditfield(navGrid, 'numeric', ...
    'Value', 1, 'Limits', [1 1], ...
    'ValueChangedFcn', @on_jump, 'Enable', 'off');
app.epochEdit.Layout.Column = 3;

app.totalLabel = uilabel(navGrid, 'Text', '/ —', ...
    'FontColor', [0.55 0.55 0.55], 'HorizontalAlignment', 'left');
app.totalLabel.Layout.Column = 4;

app.nextBtn = uibutton(navGrid, 'Text', 'Next  ►', ...
    'ButtonPushedFcn', @on_next_btn, 'Enable', 'off');
app.nextBtn.Layout.Column = 5;

app.statusLabel = uilabel(navGrid, ...
    'Text', 'Load an epoch_features.mat file to begin.', ...
    'FontColor', [0.52 0.57 0.62], 'HorizontalAlignment', 'left');
app.statusLabel.Layout.Column = 6;

app.jumpUnreviewedBtn = uibutton(navGrid, 'Text', '► Next Unreviewed', ...
    'ButtonPushedFcn', @on_jump_unreviewed, 'Enable', 'off');
app.jumpUnreviewedBtn.Layout.Column = 7;

app.saveBtn = uibutton(navGrid, 'Text', 'Save Labels', ...
    'ButtonPushedFcn', @on_save, 'Enable', 'off');
app.saveBtn.Layout.Column = 8;

app.progressLabel = uilabel(navGrid, 'Text', '', ...
    'FontColor', [0.58 0.64 0.70], 'HorizontalAlignment', 'right');
app.progressLabel.Layout.Column = 9;

% ── Row 2 : info bar ──────────────────────────────────────────────────────────
app.infoLabel = uilabel(outer, ...
    'Text', 'No file loaded.  Run extract_epoch_features.m first, then load the output .mat here.', ...
    'FontColor', [0.78 0.78 0.78], 'FontSize', 12, ...
    'HorizontalAlignment', 'left');
app.infoLabel.Layout.Row    = 2;
app.infoLabel.Layout.Column = 1;

% ── Row 3 : ECG axes ─────────────────────────────────────────────────────────
app.ecgAx = uiaxes(outer);
app.ecgAx.Layout.Row    = 3;
app.ecgAx.Layout.Column = 1;
gui_style_axes(app.ecgAx, ...
    'ECG  (BPF 0.5–40 Hz + 50 Hz notch)  —  yellow band = epoch window', ...
    'Time (s)', 'Amplitude (mV)');

% ── Row 4 : IMU axes ─────────────────────────────────────────────────────────
app.imuAx = uiaxes(outer);
app.imuAx.Layout.Row    = 4;
app.imuAx.Layout.Column = 1;
gui_style_axes(app.imuAx, ...
    'IMU — 3D accel norm (gravity removed)  |  blue = site 0 LL   red = site 1 LA   green = site 2 RA', ...
    'Time (s)', 'Accel (g)');

% ── Row 5 : label buttons + feature summary + label state + progress ──────────
botGrid = uigridlayout(outer, [1 5]);
botGrid.Layout.Row    = 5;
botGrid.Layout.Column = 1;
botGrid.ColumnWidth   = {148, 168, 118, '1x', 240};
botGrid.Padding       = [0 2 0 2];
botGrid.ColumnSpacing = 8;

app.cleanBtn = uibutton(botGrid, 'Text', '✓  CLEAN  [C]', ...
    'ButtonPushedFcn', @on_clean, ...
    'BackgroundColor', [0.14 0.38 0.17], 'FontColor', [0.88 1.00 0.88], ...
    'FontSize', 13, 'FontWeight', 'bold', 'Enable', 'off');
app.cleanBtn.Layout.Column = 1;

app.corruptBtn = uibutton(botGrid, 'Text', '✗  CORRUPTED  [X]', ...
    'ButtonPushedFcn', @on_corrupt, ...
    'BackgroundColor', [0.44 0.12 0.12], 'FontColor', [1.00 0.88 0.88], ...
    'FontSize', 13, 'FontWeight', 'bold', 'Enable', 'off');
app.corruptBtn.Layout.Column = 2;

app.skipBtn = uibutton(botGrid, 'Text', '?  SKIP  [S]', ...
    'ButtonPushedFcn', @on_skip_label, ...
    'BackgroundColor', [0.28 0.26 0.11], 'FontColor', [1.00 0.94 0.68], ...
    'FontSize', 13, 'Enable', 'off');
app.skipBtn.Layout.Column = 3;

app.featLabel = uilabel(botGrid, 'Text', '', ...
    'FontColor', [0.62 0.70 0.76], 'FontSize', 10, ...
    'HorizontalAlignment', 'left', 'WordWrap', 'on');
app.featLabel.Layout.Column = 4;

app.labelDisplay = uilabel(botGrid, 'Text', '', ...
    'FontSize', 15, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', 'FontColor', [0.88 0.88 0.88]);
app.labelDisplay.Layout.Column = 5;

% ─── Auto-load if path was supplied ──────────────────────────────────────────
if ~isempty(feature_mat_path)
    do_load(feature_mat_path);
end

% =============================================================================
% Nested callback functions — all share `app` via the enclosing workspace
% =============================================================================

    function on_load_btn(~, ~)
        [fn, fd] = uigetfile('*.mat', 'Select epoch_features.mat');
        if isequal(fn, 0); return; end
        do_load(fullfile(fd, fn));
    end

    % ── Core loader ───────────────────────────────────────────────────────────
    function do_load(fpath)
        try
            d = load(fpath);
        catch ME
            uialert(app.fig, ME.message, 'Load failed'); return;
        end
        for rf = {'X','featureNames','epochInfo'}
            if ~isfield(d, rf{1})
                uialert(app.fig, sprintf('Missing field "%s". Is this an epoch_features.mat file?', rf{1}), 'Wrong file');
                return;
            end
        end
        app.X            = d.X;
        app.featureNames = d.featureNames;
        app.epochInfo    = d.epochInfo;
        app.currentEpoch = 1;
        app.loaded       = true;
        app.featurePath  = fpath;
        app.recCache     = containers.Map('KeyType','char','ValueType','any');

        nRows = size(app.X, 1);
        app.y_manual = repmat(uint8(255), nRows, 1);
        if isfield(d, 'y_manual')   % resume a saved session
            ym = uint8(d.y_manual(:));
            if numel(ym) == nRows; app.y_manual = ym; end
        end
        if isfield(d, 'config') && isfield(d.config, 'epoch_sec')
            app.epochSec = d.config.epoch_sec;
        end

        try
            app.manifest = readtable(app.paths.manifest, 'TextType','string');
        catch
            app.manifest = table();
            uialert(app.fig, 'Could not find ADS1293 recording manifest. ECG/IMU traces will not display.', 'Warning');
        end

        nT = size(app.X,1);
        app.epochEdit.Limits = [1 max(1,nT)];
        app.totalLabel.Text  = sprintf('/ %d', nT);

        set([app.prevBtn, app.nextBtn, app.epochEdit, app.cleanBtn, ...
             app.corruptBtn, app.skipBtn, app.saveBtn, app.jumpUnreviewedBtn], ...
            'Enable', 'on');
        app.statusLabel.Text = '[C] clean     [X] corrupted     [S] skip     [←][→] navigate';

        update_display();
    end

    % ── Navigation ────────────────────────────────────────────────────────────
    function on_prev(~, ~)
        if ~app.loaded; return; end
        if app.currentEpoch > 1
            app.currentEpoch = app.currentEpoch - 1;
            update_display();
        end
    end

    function on_next_btn(~, ~)
        if ~app.loaded; return; end
        if app.currentEpoch < size(app.X,1)
            app.currentEpoch = app.currentEpoch + 1;
            update_display();
        end
    end

    function on_jump(~, ~)
        if ~app.loaded; return; end
        n = max(1, min(round(app.epochEdit.Value), size(app.X,1)));
        app.currentEpoch = n;
        update_display();
    end

    function on_jump_unreviewed(~, ~)
        if ~app.loaded; return; end
        idx = find(app.y_manual == 255 & (1:numel(app.y_manual))' > app.currentEpoch, 1);
        if isempty(idx)
            idx = find(app.y_manual == 255, 1);  % wrap from start
        end
        if isempty(idx)
            uialert(app.fig, 'All epochs reviewed.  Press Save Labels to export.', 'Complete');
        else
            app.currentEpoch = idx;
            update_display();
        end
    end

    % ── Labelling ─────────────────────────────────────────────────────────────
    function on_clean(~, ~)
        if ~app.loaded; return; end
        app.y_manual(app.currentEpoch) = uint8(1);
        advance();
    end

    function on_corrupt(~, ~)
        if ~app.loaded; return; end
        app.y_manual(app.currentEpoch) = uint8(0);
        advance();
    end

    function on_skip_label(~, ~)
        if ~app.loaded; return; end
        app.y_manual(app.currentEpoch) = uint8(2);
        advance();
    end

    function advance()
        % Move to next unreviewed epoch; fall back to simple +1 if all reviewed.
        nxt = find(app.y_manual == 255 & (1:numel(app.y_manual))' > app.currentEpoch, 1);
        if ~isempty(nxt)
            app.currentEpoch = nxt;
        elseif app.currentEpoch < size(app.X,1)
            app.currentEpoch = app.currentEpoch + 1;
        end
        update_display();
    end

    % ── Save ──────────────────────────────────────────────────────────────────
    function on_save(~, ~)
        if ~app.loaded; return; end

        y_manual = app.y_manual;

        % y_final: 0/1 where manually confirmed; 2 (skip) elsewhere.
        y_final = repmat(2, numel(y_manual), 1);
        y_final(y_manual == 1) = 1;
        y_final(y_manual == 0) = 0;

        X            = app.X;
        featureNames = app.featureNames;
        epochInfo    = app.epochInfo;

        outDir = fileparts(app.featurePath);
        if isempty(outDir)
            outDir = fullfile(app.paths.subrepo, 'outputs', ...
                char(datetime('now','Format','yyyyMMdd_HHmmss')));
        end
        if ~exist(outDir,'dir'); mkdir(outDir); end

        matOut = fullfile(outDir, 'revised_labels.mat');
        save(matOut, 'X', 'y_manual', 'y_final', 'featureNames', 'epochInfo');

        epochInfo.y_manual = double(y_manual);
        epochInfo.y_final  = y_final;
        writetable(epochInfo, fullfile(outDir, 'revised_labels.csv'));

        nDone = sum(y_manual ~= 255);
        uialert(app.fig, sprintf('%d / %d epochs manually reviewed.\n\nSaved to:\n%s', ...
            nDone, numel(y_manual), matOut), 'Saved');
    end

    % ── Keyboard ──────────────────────────────────────────────────────────────
    function on_key(~, event)
        if ~app.loaded; return; end
        switch lower(event.Key)
            case {'c','return'};  on_clean([],[]);
            case 'x';             on_corrupt([],[]);
            case 's';             on_skip_label([],[]);
            case 'rightarrow';    on_next_btn([],[]);
            case 'leftarrow';     on_prev([],[]);
        end
    end

    % ── Main display update ───────────────────────────────────────────────────
    function update_display()
        nT = size(app.X,1);
        if nT == 0; return; end
        n = max(1, min(app.currentEpoch, nT));
        app.currentEpoch    = n;
        app.epochEdit.Value = n;

        info      = app.epochInfo(n,:);
        rec_id    = char(info.recording_id);
        t_start   = info.epoch_start_s;
        condition = char(info.condition);
        cohort    = char(info.cohort);
        lead      = gui_table_string(info, 'lead', 'ch1');
        bpf_name  = gui_table_string(info, 'bpf', 'B1');
        notch     = gui_table_string(info, 'notch', 'N1');
        bpf_id    = gui_bpf_to_id(bpf_name);

        feat   = app.X(n,:);
        kSQI   = fv(feat, app.featureNames, 'ecg_kurtosis');
        mScore = fv(feat, app.featureNames, 'motion_score');
        mFast  = fv(feat, app.featureNames, 'motion_score_fast');
        nsr    = fv(feat, app.featureNames, 'ecg_nsr');
        acc0   = fv(feat, app.featureNames, 'acc_rms_s0');
        acc1   = fv(feat, app.featureNames, 'acc_rms_s1');
        acc2   = fv(feat, app.featureNames, 'acc_rms_s2');
        d01    = fv(feat, app.featureNames, 'diff_acc_s01');

        % Info bar
        app.infoLabel.Text = sprintf( ...
            '%s  |  %s  |  %s  |  %s/%s/%s  |  t = %.3f s     kSQI = %.2f    motion = %.2f (fast %.2f)    nsr = %.2f', ...
            rec_id, condition, cohort, lead, bpf_name, notch, t_start, kSQI, mScore, mFast, nsr);

        % Feature summary (bottom bar)
        app.featLabel.Text = sprintf( ...
            'acc s0=%.3f  s1=%.3f  s2=%.3f  |  diff_s01=%.3f  |  kSQI=%.2f  nsr=%.2f  motion=%.2f', ...
            acc0, acc1, acc2, d01, kSQI, nsr, mScore);

        % Label state
        man = app.y_manual(n);
        if man == 255
            ltxt = 'Not reviewed';  lcol = [0.52 0.57 0.62];
        elseif man == 2
            ltxt = 'SKIP';          lcol = [0.88 0.80 0.28];
        else
            ltxt = gui_lbl_str(man); lcol = gui_lbl_col(man);
        end
        app.labelDisplay.Text      = ltxt;
        app.labelDisplay.FontColor = lcol;

        % Progress counter
        nRev = sum(app.y_manual ~= 255);
        nC   = sum(app.y_manual == 1);
        nX   = sum(app.y_manual == 0);
        nS   = sum(app.y_manual == 2);
        app.progressLabel.Text = sprintf('%d / %d   C:%d  X:%d  S:%d', nRev, nT, nC, nX, nS);

        % Fetch raw recording (cached after first load)
        rec = fetch_recording(rec_id, lead, bpf_id, notch);
        if isempty(rec)
            cla(app.ecgAx);
            title(app.ecgAx, sprintf('Recording not found: %s', rec_id), 'Color',[0.80 0.38 0.30]);
            cla(app.imuAx);
            title(app.imuAx, '', 'Color',[0.78 0.78 0.78]);
            return;
        end

        % Display window: 5 s centred on the epoch midpoint
        epoch_mid = t_start + app.epochSec / 2;
        win_lo = max(rec.t_s(1),   epoch_mid - 2.5);
        win_hi = min(rec.t_s(end), epoch_mid + 2.5);
        seg    = rec.t_s >= win_lo & rec.t_s <= win_hi;
        t_seg  = rec.t_s(seg);

        % ── ECG ───────────────────────────────────────────────────────────────
        ecg_seg = rec.ecg_disp(seg);   % despike + BPF + notch + display baseline
        cla(app.ecgAx);
        if any(isfinite(ecg_seg))
            % Y-limits from 1st/99th pctile of visible data + 15% pad
            sv  = sort(ecg_seg(isfinite(ecg_seg)));
            nsv = numel(sv);
            ylo = sv(max(1, round(0.01 * nsv)));
            yhi = sv(min(nsv, max(1, round(0.99 * nsv))));
            pad = max(0.05, 0.15 * max(yhi - ylo, eps));
            ylo = ylo - pad;  yhi = yhi + pad;
            hold(app.ecgAx, 'on');
            if isfinite(ylo) && isfinite(yhi) && yhi > ylo
                patch(app.ecgAx, ...
                    [t_start, t_start+app.epochSec, t_start+app.epochSec, t_start], ...
                    [ylo, ylo, yhi, yhi], ...
                    [0.24 0.22 0.10], 'EdgeColor','none', 'FaceAlpha',0.50);
            end
            plot(app.ecgAx, t_seg, ecg_seg, ...
                'Color', [0.24 0.78 0.50], 'LineWidth', 1.3);
            xline(app.ecgAx, t_start,               '--', ...
                'Color',[0.94 0.78 0.20], 'LineWidth',1.1, 'Alpha',0.85);
            xline(app.ecgAx, t_start + app.epochSec, '--', ...
                'Color',[0.94 0.78 0.20], 'LineWidth',1.1, 'Alpha',0.85);
            hold(app.ecgAx, 'off');
            app.ecgAx.XLim = [win_lo win_hi];
            if isfinite(ylo) && isfinite(yhi) && yhi > ylo
                app.ecgAx.YLim = [ylo yhi];
            end
        end
        title(app.ecgAx, ...
            'ECG  (BPF 0.5–40 Hz + 50 Hz notch)  —  yellow band = epoch window', ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);

        % ── IMU ───────────────────────────────────────────────────────────────
        site_c = {[0.28 0.58 1.00], [1.00 0.36 0.36], [0.32 0.88 0.40]};
        site_n = {'LL (s0)', 'LA (s1)', 'RA (s2)'};
        cla(app.imuAx);
        hold(app.imuAx, 'on');
        drew_imu = false;
        for ss = 1:3
            ac = (ss-1)*3 + (1:3);
            a  = rec.imu.acc_g(seg, ac);
            ok = all(isfinite(a), 1);
            if any(ok)
                a_dyn  = a(:,ok) - mean(a(:,ok), 1);
                a_norm = sqrt(sum(a_dyn.^2, 2));
                plot(app.imuAx, t_seg, a_norm, ...
                    'Color', site_c{ss}, 'LineWidth', 1.1, ...
                    'DisplayName', site_n{ss});
                drew_imu = true;
            end
        end
        if drew_imu
            xline(app.imuAx, t_start,               '--', ...
                'Color',[0.94 0.78 0.20], 'LineWidth',1.1, 'Alpha',0.85);
            xline(app.imuAx, t_start + app.epochSec, '--', ...
                'Color',[0.94 0.78 0.20], 'LineWidth',1.1, 'Alpha',0.85);
            legend(app.imuAx, 'Location','northwest', ...
                'TextColor',[0.76 0.76 0.76], ...
                'Color',[0.10 0.11 0.13], 'EdgeColor',[0.30 0.30 0.30]);
        end
        hold(app.imuAx, 'off');
        app.imuAx.XLim = [win_lo win_hi];
        title(app.imuAx, ...
            'IMU — 3D accel norm (gravity removed)  |  blue = site 0 LL   red = site 1 LA   green = site 2 RA', ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
    end

    % ── Recording cache ───────────────────────────────────────────────────────
    function rec = fetch_recording(rec_id, lead, bpf_id, notch)
        % Return the pre-filtered recording struct; load from disk on first access.
        cacheKey = sprintf('%s|%s|B%d|%s', rec_id, char(lead), bpf_id, char(notch));
        if isKey(app.recCache, cacheKey)
            rec = app.recCache(cacheKey);
            return;
        end
        rec = [];
        if isempty(app.manifest); app.recCache(cacheKey) = []; return; end

        mask = app.manifest.recording_id == string(rec_id);
        if ~any(mask); app.recCache(cacheKey) = []; return; end

        mrow  = app.manifest(mask,:);
        fpath = fullfile(app.paths.repo, char(mrow.relative_path(1)));
        if ~isfile(fpath); app.recCache(cacheKey) = []; return; end

        try
            rec = gui_load_recording(fpath, bpf_id, notch, lead);
        catch
            rec = [];
        end
        app.recCache(cacheKey) = rec;
    end

end  % end label_epoch_gui

% =============================================================================
% Local helper functions — explicit parameters, no access to app
% =============================================================================

function rec = gui_load_recording(fpath, bpf_id, notch, lead)
% Load a recording file and pre-filter the ECG for display.
data = gui_read_numeric(fpath);

t_us = double(data(:,1));
t_s  = (t_us - t_us(1)) * 1e-6;
dt   = diff(t_s); dt = dt(isfinite(dt) & dt > 0);

rec         = struct();
rec.t_s     = t_s;
rec.Fs      = 1 / median(dt);
if isempty(dt) || ~isfinite(rec.Fs) || rec.Fs <= 0; rec.Fs = NaN; end

ADS_SCALE_MV = (2 * 2400 / 3.5) / hex2dec('C35000');
nCols = size(data, 2);
lead = lower(string(lead));
if nCols == 21
    ch1 = double(data(:,2)) * ADS_SCALE_MV;
    ch2 = double(data(:,3)) * ADS_SCALE_MV;
    imuStartCol = 4;
elseif nCols == 23
    ch1 = double(data(:,21)) * ADS_SCALE_MV;
    ch2 = double(data(:,22)) * ADS_SCALE_MV;
    imuStartCol = 3;
else
    ch1 = double(data(:,2)) * (1800 / 4096);
    ch2 = ch1;
    imuStartCol = 3;
end
switch lead
    case "ch2"; rec.ecg_raw = ch2;
    case "diff12"; rec.ecg_raw = ch1 - ch2;
    otherwise; rec.ecg_raw = ch1;
end
rec.ecg_raw = gui_despike_ecg(rec.ecg_raw, rec.Fs);
rec.ecg_raw = rec.ecg_raw - median(rec.ecg_raw, 'omitnan');
rec.imu     = gui_parse_imu(data, imuStartCol);

bpSOS    = gui_design_bpf(bpf_id, rec.Fs);

ybp = rec.ecg_raw;
if ~isempty(bpSOS); ybp = sosfilt(bpSOS, ybp - ybp(1)); end
if lower(string(notch)) ~= "none"
    if exist('apply_notch', 'file') == 2
        ybp = apply_notch(ybp, char(notch), rec.Fs);
    else
        [nb, na] = gui_design_notch(notch, rec.Fs);
        if ~(isequal(nb,1) && isequal(na,1)); ybp = filter(nb, na, ybp); end
    end
end
rec.ecg_filt = ybp;
rec.ecg_disp = gui_display_baseline(ybp, rec.Fs);
rec.ylim_ecg = [];  % computed per-window in update_display
end

function data = gui_read_numeric(fpath)
fid = fopen(fpath, 'r');
if fid < 0; error('Cannot open: %s', fpath); end
headerLines = 0;
while true
    line = fgetl(fid);
    if ~ischar(line); fclose(fid); error('No numeric rows: %s', fpath); end
    vals = str2double(regexp(strtrim(line), '[,\s]+', 'split'));
    if nnz(isfinite(vals)) >= 2; break; end
    headerLines = headerLines + 1;
end
fclose(fid);
data = readmatrix(fpath, 'FileType','text', 'NumHeaderLines',headerLines);
data = double(data);
col_counts = sum(~isnan(data), 2);
if ~isempty(col_counts)
    modal_cols = mode(col_counts);
    if modal_cols < size(data, 2)
        data = data(:, 1:modal_cols);
    end
end
data = double(data(all(isfinite(data),2),:));
for cc = 2:size(data,2)
    w = data(:,cc) > 2147483647;
    data(w,cc) = data(w,cc) - 4294967296;
end
end

function imu = gui_parse_imu(data, imuStartCol)
N   = size(data,1);
raw = nan(N,18);
av  = max(0, min(18, size(data,2)-imuStartCol+1));
if av > 0; raw(:,1:av) = data(:,imuStartCol:(imuStartCol+av-1)); end
imu = struct('acc_g',nan(N,9), 'gyro_dps',nan(N,9));
for s = 1:3
    src = (s-1)*6+(1:6); dst = (s-1)*3+(1:3);
    imu.acc_g(:,dst)    = raw(:,src(1:3)) / 16384;
    imu.gyro_dps(:,dst) = raw(:,src(4:6)) / 131;
end
end

function sos = gui_design_bpf(bpf_id, Fs)
sos = [];
if bpf_id==0 || ~isfinite(Fs) || Fs<=0; return; end
Nyq = Fs/2; lo = 0.5/Nyq; hi = min(40,Nyq*0.95)/Nyq;
switch bpf_id
    case 1; [z,p,k] = butter(4,  [lo  hi ], 'bandpass');
    case 2; [z,p,k] = butter(2,  [lo  hi ], 'bandpass');
    case 3; lo2 = max(0.05,1e-3*Nyq)/Nyq; hi2 = min(150,Nyq*0.95)/Nyq;
            if lo2>=hi2; return; end; [z,p,k] = butter(4,[lo2 hi2],'bandpass');
    case 4; [z,p,k] = cheby2(3, 40, [lo  hi ], 'bandpass');
    case 5; [z,p,k] = ellip(2, 0.5, 40, [lo hi], 'bandpass');
    case 6; lo2 = max(0.05,1e-3*Nyq)/Nyq; if lo2>=hi; return; end
            [z,p,k] = butter(4, [lo2 hi], 'bandpass');
    case 7; lo7 = 0.75/Nyq; if lo7>=hi; return; end
            [z,p,k] = butter(4, [lo7 hi], 'bandpass');
    case 8; [z,p,k] = butter(6, [lo  hi], 'bandpass');
    otherwise; return;
end
sos = zp2sos(z,p,k);
end

function [nb,na] = gui_design_notch(notch, Fs)
nb = 1; na = 1;
if lower(string(notch)) == "none" || ~isfinite(Fs) || Fs<=0; return; end
if lower(string(notch)) ~= "none" && Fs > 110
    r=0.990; w0=2*pi*50/Fs;
    nb=[1,-2*cos(w0),1]; na=[1,-2*r*cos(w0),r^2];
end
end

function out = gui_table_string(row, field, fallback)
out = fallback;
if ismember(field, row.Properties.VariableNames)
    val = row.(field);
    if ~isempty(val); out = char(string(val(1))); end
end
end

function id = gui_bpf_to_id(name)
s = upper(string(name));
if s == "NONE"; id = 0; return; end
tok = regexp(char(s), '^B([1-8])$', 'tokens', 'once');
if isempty(tok); id = 1; else; id = str2double(tok{1}); end
end

function v = fv(feat_row, names, name)
% Retrieve a single feature value by name; returns NaN if not found.
idx = find(strcmpi(names, name), 1);
if isempty(idx); v = NaN; else; v = feat_row(idx); end
end

function s = gui_lbl_str(lbl)
if lbl == 1; s = 'CLEAN'; else; s = 'CORRUPTED'; end
end

function c = gui_lbl_col(lbl)
if lbl == 1; c = [0.26 0.88 0.44]; else; c = [0.92 0.30 0.30]; end
end

function gui_style_axes(ax, ttl, xl, yl)
ax.Color     = [0.08 0.09 0.11];
ax.XColor    = [0.46 0.46 0.46];
ax.YColor    = [0.46 0.46 0.46];
ax.GridColor = [0.26 0.26 0.26];
ax.XGrid     = 'on';
ax.YGrid     = 'on';
title(ax,  ttl, 'Color',[0.76 0.76 0.76], 'FontSize',10);
xlabel(ax, xl,  'Color',[0.62 0.62 0.62]);
ylabel(ax, yl,  'Color',[0.62 0.62 0.62]);
end

function paths = gui_local_paths()
matlabDir      = fileparts(mfilename('fullpath'));
paths.repo     = fileparts(matlabDir);
paths.subrepo  = matlabDir;
adsManifest = fullfile(paths.subrepo, 'config', 'ads1293_recording_manifest.csv');
if isfile(adsManifest)
    paths.manifest = adsManifest;
else
    paths.manifest = fullfile(paths.subrepo, 'config', 'recording_manifest.csv');
end
end

function y = gui_despike_ecg(ecg, Fs)
% MAD-based spike removal via linear interpolation — matches phase2_analyzer.
ecg = double(ecg(:));
y   = ecg;
if numel(ecg) < 8 || ~isfinite(Fs) || Fs <= 0; return; end
win = max(3, round(0.25 * Fs));
win = min(win, max(3, numel(ecg)));
if mod(win, 2) == 0; win = max(3, win - 1); end
baseline = movmedian(ecg, win, 'Endpoints', 'shrink');
residual = ecg - baseline;
med_res  = median(residual, 'omitnan');
mad_val  = median(abs(residual - med_res), 'omitnan');
if ~isfinite(mad_val) || mad_val < 1e-12; return; end
bad = abs(residual - med_res) > max(8 * mad_val, 1.5);
if any(bad)
    ii   = (1:numel(ecg))';
    good = ~bad & isfinite(ecg);
    if nnz(good) >= 2
        y(bad) = interp1(ii(good), ecg(good), ii(bad), 'linear', 'extrap');
    end
end
end

function y = gui_display_baseline(ecg, Fs)
% Double movmedian baseline subtraction — matches phase2_analyzer display_trace.
% First pass (0.20 s) suppresses QRS; second pass (0.80 s) smooths result.
ecg = double(ecg(:));
if numel(ecg) < 8 || ~isfinite(Fs) || Fs <= 0
    y = ecg - median(ecg, 'omitnan');
    return;
end
good = isfinite(ecg);
if nnz(good) >= 2 && any(~good)
    ii = (1:numel(ecg))';
    ecg(~good) = interp1(ii(good), ecg(good), ii(~good), 'linear', 'extrap');
elseif nnz(good) < 2
    y = zeros(size(ecg));
    return;
end
qrs_win  = max(3, round(0.20 * Fs));
qrs_win  = min(qrs_win, max(3, numel(ecg)));
if mod(qrs_win, 2) == 0; qrs_win = max(3, qrs_win - 1); end
tw_win   = max(3, round(0.80 * Fs));
tw_win   = min(tw_win, max(3, numel(ecg)));
if mod(tw_win, 2) == 0; tw_win = max(3, tw_win - 1); end
baseline = movmedian(ecg, qrs_win, 'Endpoints', 'shrink');
baseline = movmedian(baseline, tw_win, 'Endpoints', 'shrink');
y = ecg - baseline;
end
