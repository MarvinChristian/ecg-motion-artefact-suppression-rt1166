function run_realtime_ecg_feature_gui()
% RUN_REALTIME_ECG_FEATURE_GUI
% Replays a recorded ECG/IMU file as a real-time stream.
%
% The GUI uses causal filters and past-window decisions only. It is meant to
% behave like the firmware pipeline would behave sample-by-sample, while
% still being easy to inspect during thesis writing.

paths = local_paths();
delete_stale_gui_timers();
manifest = readtable(paths.manifest, 'TextType', 'string');
manifest = manifest(manifest.include_main == 1, :);
manifest = manifest(arrayfun(@(p) isfile(fullfile(paths.repo, p)), manifest.relative_path), :);

if isempty(manifest)
    error('No manifest recordings were found. Check thesis_pipeline/config/recording_manifest.csv');
end

app = struct();
app.paths = paths;
app.manifest = manifest;
app.rec = [];
app.idx = 0;
app.running = false;
app.proc = [];
app.featureProc = [];
app.featureMode = "not_loaded";
app.featureLatencyMs = NaN;
app.motionScore = [];
app.motionLatencyMs = [];
app.motionSource = strings(0,1);
app.motionLabel = "not_loaded";
app.filter = struct();
app.qrs = struct();
app.log = struct('time_s', [], 'hr_bpm', [], 'rr_ms', [], 'sdnn_ms', [], ...
                 'rmssd_ms', [], 'pnn50_pct', [], 'sd1_ms', [], ...
                 'sd2_ms', [], 'rr_cv_pct', [], 'r_amp_mv', [], ...
                 'qrs_width_ms', [], 'qrs_area_mvms', [], ...
                 'qrs_slope_mvs', [], 'baseline_mv', [], ...
                 'noise_rms_mv', [], 'st60_mv', [], 'beat_quality', [], ...
                 'detector_latency_ms', [], 'filter_delay_ms', [], ...
                 'feature_latency_ms', [], 'motion_score', [], ...
                 'motion_latency_ms', [], 'sqi', [], ...
                 'beat_template_used', [], 'feature_signal_mode', strings(0,1), ...
                 'r_source', strings(0,1), 'rhythm_flag', strings(0,1), ...
                 'motion_label', strings(0,1), 'motion_source', strings(0,1));

app.fig = uifigure('Name', 'Real-Time ECG Feature Replay', ...
    'Position', [80 80 1360 820], 'Color', [0.10 0.11 0.13]);
app.fig.CloseRequestFcn = @close_gui;

main = uigridlayout(app.fig, [4 4]);
main.RowHeight = {58, '1x', '0.85x', 205};
main.ColumnWidth = {'1x', '1x', '1x', 360};
main.Padding = [10 10 10 10];
main.RowSpacing = 8;
main.ColumnSpacing = 8;

app.recordingDrop = uidropdown(main, ...
    'Items', compose("%s | %s | %s", manifest.recording_id, manifest.condition, manifest.cohort), ...
    'Value', compose("%s | %s | %s", manifest.recording_id(1), manifest.condition(1), manifest.cohort(1)));
app.recordingDrop.Layout.Row = 1;
app.recordingDrop.Layout.Column = [1 2];

app.speedDrop = uidropdown(main, ...
    'Items', {'0.5x','1x','2x','5x','10x','20x'}, ...
    'Value', '1x');
app.speedDrop.Layout.Row = 1;
app.speedDrop.Layout.Column = 3;

buttonGrid = uigridlayout(main, [1 4]);
buttonGrid.Layout.Row = 1;
buttonGrid.Layout.Column = 4;
buttonGrid.ColumnWidth = {'1x','1x','1x','1x'};
buttonGrid.Padding = [0 0 0 0];
app.loadBtn = uibutton(buttonGrid, 'Text', 'Load', 'ButtonPushedFcn', @load_selected);
app.startBtn = uibutton(buttonGrid, 'Text', 'Start', 'ButtonPushedFcn', @start_replay);
app.pauseBtn = uibutton(buttonGrid, 'Text', 'Pause', 'ButtonPushedFcn', @pause_replay);
app.saveBtn = uibutton(buttonGrid, 'Text', 'Save', 'ButtonPushedFcn', @save_features);

app.axEcg = uiaxes(main);
app.axEcg.Layout.Row = 2;
app.axEcg.Layout.Column = [1 3];
title(app.axEcg, 'ECG replay: raw and processed');
ylabel(app.axEcg, 'mV');
grid(app.axEcg, 'on');

app.axMotion = uiaxes(main);
app.axMotion.Layout.Row = 3;
app.axMotion.Layout.Column = [1 3];
title(app.axMotion, 'IMU MAS motion score and epoch class');
ylabel(app.axMotion, 'score');
xlabel(app.axMotion, 'Time (s)');
grid(app.axMotion, 'on');

app.featureTable = uitable(main);
app.featureTable.Layout.Row = [2 3];
app.featureTable.Layout.Column = 4;
app.featureTable.ColumnName = {'Feature', 'Live value'};
app.featureTable.Data = {'Status', 'Load a recording'};

app.notes = uitextarea(main, 'Editable', 'off');
app.notes.Layout.Row = 4;
app.notes.Layout.Column = [1 4];
app.notes.Value = { ...
    'This GUI simulates real-time processing from stored recordings.', ...
    'Filtering is causal. Motion classification uses fast-onset and sustained past-window IMU energy.', ...
    'DWT denoising and beat-template reconstruction are feature-only aids; they do not replace the output waveform.', ...
    'Motion thresholds are adaptive engineering defaults: clean < 3, risk 3-8, corrupted >= 8 robust deviations from calibration.', ...
    'Feature values are engineering measurements, not clinical diagnoses.', ...
    'The safest thesis outputs are HR/RR/HRV, QRS timing, SQI, and motion epoch class.', ...
    'Single-lead morphology outputs such as QRS width, QRS area, slope, and ST60 are displayed as approximate engineering features.'};

app.timer = timer('ExecutionMode', 'fixedSpacing', ...
                  'Name', 'RealtimeECGFeatureReplayTimer', ...
                  'Period', 0.10, ...
                  'TimerFcn', @timer_tick, ...
                  'BusyMode', 'drop');

load_selected();

    function load_selected(~, ~)
        pause_replay();
        row = selected_manifest_row();
        fpath = fullfile(paths.repo, row.relative_path);
        app.rec = load_recording(fpath, row);
        app.idx = 0;
        app.proc = nan(size(app.rec.ecg_mV));
        app.featureProc = nan(size(app.rec.ecg_mV));
        app.featureMode = "warming";
        app.featureLatencyMs = NaN;
        app.motionScore = nan(size(app.rec.ecg_mV));
        app.motionLatencyMs = nan(size(app.rec.ecg_mV));
        app.motionSource = strings(size(app.rec.ecg_mV));
        app.motionLabel = "warming";
        app.filter = init_filters(app.rec.Fs);
        app.qrs = init_qrs_state(app.rec.Fs);
        app.log = struct('time_s', [], 'hr_bpm', [], 'rr_ms', [], 'sdnn_ms', [], ...
                         'rmssd_ms', [], 'pnn50_pct', [], 'sd1_ms', [], ...
                         'sd2_ms', [], 'rr_cv_pct', [], 'r_amp_mv', [], ...
                         'qrs_width_ms', [], 'qrs_area_mvms', [], ...
                         'qrs_slope_mvs', [], 'baseline_mv', [], ...
                         'noise_rms_mv', [], 'st60_mv', [], 'beat_quality', [], ...
                         'detector_latency_ms', [], 'filter_delay_ms', [], ...
                         'feature_latency_ms', [], 'motion_score', [], ...
                         'motion_latency_ms', [], 'sqi', [], ...
                         'beat_template_used', [], 'feature_signal_mode', strings(0,1), ...
                         'r_source', strings(0,1), 'rhythm_flag', strings(0,1), ...
                         'motion_label', strings(0,1), 'motion_source', strings(0,1));
        update_feature_table(current_features());
        redraw_plots();
    end

    function start_replay(~, ~)
        if isempty(app.rec)
            load_selected();
        end
        app.running = true;
        if strcmp(app.timer.Running, 'off')
            start(app.timer);
        end
    end

    function pause_replay(~, ~)
        app.running = false;
        if isfield(app, 'timer') && strcmp(app.timer.Running, 'on')
            stop(app.timer);
        end
    end

    function timer_tick(~, ~)
        if ~app.running || isempty(app.rec)
            return;
        end

        speed = replay_speed();
        nStep = max(1, round(app.rec.Fs * app.timer.Period * speed));
        n0 = app.idx + 1;
        n1 = min(numel(app.rec.ecg_mV), app.idx + nStep);
        if n0 > n1
            pause_replay();
            return;
        end

        x = app.rec.ecg_mV(n0:n1);
        [y, app.filter] = filter_chunk_causal(x, app.filter);
        app.proc(n0:n1) = y;

        subMax = max(1, round(0.100 * app.rec.Fs));
        sub0 = n0;
        while sub0 <= n1
            sub1 = min(n1, sub0 + subMax - 1);
            [app.featureProc(sub0:sub1), app.featureMode, app.featureLatencyMs] = ...
                feature_only_dwt_chunk(app.proc, sub0, sub1, app.rec.Fs);

            for nn = sub0:sub1
                app.qrs = update_qrs_state(app.qrs, app.proc, nn, app.rec.Fs);
                [score, label, motionLatencyMs, motionSource] = motion_epoch_score(app.rec, nn);
                app.motionScore(nn) = score;
                app.motionLatencyMs(nn) = motionLatencyMs;
                app.motionSource(nn) = motionSource;
                app.motionLabel = label;
            end
            sub0 = sub1 + 1;
        end
        app.idx = n1;

        feat = current_features();
        append_log(feat);
        update_feature_table(feat);
        redraw_plots();

        if app.idx >= numel(app.rec.ecg_mV)
            pause_replay();
        end
    end

    function row = selected_manifest_row()
        items = compose("%s | %s | %s", manifest.recording_id, manifest.condition, manifest.cohort);
        idx = find(items == string(app.recordingDrop.Value), 1);
        if isempty(idx)
            idx = 1;
        end
        row = manifest(idx, :);
    end

    function speed = replay_speed()
        token = erase(string(app.speedDrop.Value), "x");
        speed = str2double(token);
        if ~isfinite(speed) || speed <= 0
            speed = 1;
        end
    end

    function feat = current_features()
        feat = compute_live_features(app.rec, app.proc, app.featureProc, app.idx, ...
                                     app.qrs, app.motionScore, app.motionLatencyMs, ...
                                     app.motionSource, app.motionLabel, ...
                                     app.featureMode, app.featureLatencyMs);
        if isfield(app.filter, 'delayMs')
            feat.filter_delay_ms = app.filter.delayMs;
        end
    end

    function append_log(feat)
        app.log.time_s(end+1,1) = feat.time_s;
        app.log.hr_bpm(end+1,1) = feat.hr_bpm;
        app.log.rr_ms(end+1,1) = feat.rr_ms;
        app.log.sdnn_ms(end+1,1) = feat.sdnn_ms;
        app.log.rmssd_ms(end+1,1) = feat.rmssd_ms;
        app.log.pnn50_pct(end+1,1) = feat.pnn50_pct;
        app.log.sd1_ms(end+1,1) = feat.sd1_ms;
        app.log.sd2_ms(end+1,1) = feat.sd2_ms;
        app.log.rr_cv_pct(end+1,1) = feat.rr_cv_pct;
        app.log.r_amp_mv(end+1,1) = feat.r_amp_mv;
        app.log.qrs_width_ms(end+1,1) = feat.qrs_width_ms;
        app.log.qrs_area_mvms(end+1,1) = feat.qrs_area_mvms;
        app.log.qrs_slope_mvs(end+1,1) = feat.qrs_slope_mvs;
        app.log.baseline_mv(end+1,1) = feat.baseline_mv;
        app.log.noise_rms_mv(end+1,1) = feat.noise_rms_mv;
        app.log.st60_mv(end+1,1) = feat.st60_mv;
        app.log.beat_quality(end+1,1) = feat.beat_quality;
        app.log.detector_latency_ms(end+1,1) = feat.detector_latency_ms;
        app.log.filter_delay_ms(end+1,1) = feat.filter_delay_ms;
        app.log.feature_latency_ms(end+1,1) = feat.feature_latency_ms;
        app.log.motion_score(end+1,1) = feat.motion_score;
        app.log.motion_latency_ms(end+1,1) = feat.motion_latency_ms;
        app.log.sqi(end+1,1) = feat.sqi;
        app.log.beat_template_used(end+1,1) = feat.beat_template_used;
        app.log.feature_signal_mode(end+1,1) = string(feat.feature_signal_mode);
        app.log.r_source(end+1,1) = string(feat.r_source);
        app.log.rhythm_flag(end+1,1) = string(feat.rhythm_flag);
        app.log.motion_label(end+1,1) = string(feat.motion_label);
        app.log.motion_source(end+1,1) = string(feat.motion_source);
    end

    function update_feature_table(feat)
        app.featureTable.Data = {
            'Recording', char(app.rec.id)
            'Condition', char(app.rec.condition)
            'Fs from timestamps', sprintf('%.2f Hz', app.rec.Fs)
            'Replay time', sprintf('%.2f / %.2f s', feat.time_s, app.rec.t_s(end))
            'Causal filter delay est.', fmt_num(feat.filter_delay_ms, '%.1f ms')
            'Feature ECG mode', char(feat.feature_signal_mode)
            'Feature buffer latency', fmt_num(feat.feature_latency_ms, '%.1f ms')
            'MAS epoch class', char(feat.motion_label)
            'Motion score', fmt_num(feat.motion_score, '%.2f')
            'Motion score source', char(feat.motion_source)
            'Motion lookback latency', fmt_num(feat.motion_latency_ms, '%.0f ms')
            'Engineering SQI', fmt_num(feat.sqi, '%.0f / 100')
            'R peaks detected', sprintf('%d', numel(app.qrs.rPeaks))
            'Latest R source', char(feat.r_source)
            'Detector timing correction', fmt_num(feat.detector_latency_ms, '%.1f ms')
            'Rhythm flag', char(feat.rhythm_flag)
            'Instant HR', fmt_num(feat.hr_bpm, '%.1f bpm')
            'RR interval', fmt_num(feat.rr_ms, '%.0f ms')
            'Mean HR recent', fmt_num(feat.hr_mean_bpm, '%.1f bpm')
            'SDNN recent', fmt_num(feat.sdnn_ms, '%.1f ms')
            'RMSSD recent', fmt_num(feat.rmssd_ms, '%.1f ms')
            'pNN50 recent', fmt_num(feat.pnn50_pct, '%.1f %%')
            'Poincare SD1', fmt_num(feat.sd1_ms, '%.1f ms')
            'Poincare SD2', fmt_num(feat.sd2_ms, '%.1f ms')
            'RR CV recent', fmt_num(feat.rr_cv_pct, '%.1f %%')
            'R amplitude', fmt_num(feat.r_amp_mv, '%.3f mV')
            'QRS width approx', fmt_num(feat.qrs_width_ms, '%.0f ms')
            'QRS area approx', fmt_num(feat.qrs_area_mvms, '%.2f mV*ms')
            'Max QRS slope', fmt_num(feat.qrs_slope_mvs, '%.1f mV/s')
            'Local baseline', fmt_num(feat.baseline_mv, '%.3f mV')
            'Local noise RMS', fmt_num(feat.noise_rms_mv, '%.3f mV')
            'ST60 approx', fmt_num(feat.st60_mv, '%.3f mV')
            'Beat quality', fmt_num(feat.beat_quality, '%.0f / 100')
            'Template beat used', logical_text(feat.beat_template_used)
            };
    end

    function redraw_plots()
        if isempty(app.rec)
            return;
        end

        n = max(1, app.idx);
        tNow = app.rec.t_s(n);
        mask = app.rec.t_s >= max(0, tNow - 10) & app.rec.t_s <= max(tNow, 0.1);

        cla(app.axEcg);
        hold(app.axEcg, 'on');
        plot(app.axEcg, app.rec.t_s(mask), app.rec.ecg_mV(mask), ...
            'Color', [0.48 0.50 0.55], 'LineWidth', 0.7);
        plot(app.axEcg, app.rec.t_s(mask), app.proc(mask), ...
            'Color', [0.10 0.78 0.42], 'LineWidth', 1.1);
        r = app.qrs.rPeaks(app.qrs.rPeaks <= n);
        r = r(app.rec.t_s(r) >= max(0, tNow - 10));
        if ~isempty(r)
            plot(app.axEcg, app.rec.t_s(r), app.proc(r), 'ro', ...
                'MarkerSize', 5, 'LineWidth', 1.0);
        end
        hold(app.axEcg, 'off');
        legend(app.axEcg, {'Raw ECG', 'Processed ECG', 'R peaks'}, 'Location', 'northwest');
        xlim(app.axEcg, [max(0, tNow - 10), max(10, tNow)]);

        cla(app.axMotion);
        hold(app.axMotion, 'on');
        plot(app.axMotion, app.rec.t_s(mask), app.motionScore(mask), ...
            'Color', [0.25 0.55 0.95], 'LineWidth', 1.2);
        yline(app.axMotion, 3, '--', 'motion risk', 'Color', [0.85 0.65 0.20]);
        yline(app.axMotion, 8, '--', 'corrupted', 'Color', [0.90 0.25 0.25]);
        hold(app.axMotion, 'off');
        xlim(app.axMotion, [max(0, tNow - 10), max(10, tNow)]);
        finiteScore = app.motionScore(mask);
        finiteScore = finiteScore(isfinite(finiteScore));
        if isempty(finiteScore)
            yMax = 10;
        else
            yMax = max(10, max(finiteScore) + 1);
        end
        ylim(app.axMotion, [0, yMax]);
    end

    function save_features(~, ~)
        if isempty(app.log.time_s)
            uialert(app.fig, 'No feature rows have been generated yet.', 'Nothing to save');
            return;
        end
        stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
        outDir = fullfile(paths.subrepo, 'outputs', stamp);
        if ~exist(outDir, 'dir')
            mkdir(outDir);
        end
        T = table(app.log.time_s, app.log.hr_bpm, app.log.rr_ms, ...
            app.log.sdnn_ms, app.log.rmssd_ms, app.log.pnn50_pct, ...
            app.log.sd1_ms, app.log.sd2_ms, app.log.rr_cv_pct, ...
            app.log.r_amp_mv, app.log.qrs_width_ms, app.log.qrs_area_mvms, ...
            app.log.qrs_slope_mvs, app.log.baseline_mv, app.log.noise_rms_mv, ...
            app.log.st60_mv, app.log.beat_quality, app.log.detector_latency_ms, ...
            app.log.filter_delay_ms, app.log.feature_latency_ms, app.log.motion_score, ...
            app.log.motion_latency_ms, app.log.sqi, app.log.beat_template_used, ...
            app.log.feature_signal_mode, app.log.r_source, app.log.rhythm_flag, ...
            app.log.motion_label, app.log.motion_source, ...
            'VariableNames', {'time_s','hr_bpm','rr_ms','sdnn_ms','rmssd_ms', ...
            'pnn50_pct','sd1_ms','sd2_ms','rr_cv_pct','r_amp_mv', ...
            'qrs_width_ms','qrs_area_mvms','qrs_slope_mvs','baseline_mv', ...
            'noise_rms_mv','st60_mv','beat_quality','detector_latency_ms', ...
            'filter_delay_ms','feature_latency_ms','motion_score','motion_latency_ms','sqi', ...
            'beat_template_used','feature_signal_mode','r_source','rhythm_flag', ...
            'motion_label','motion_source'});
        writetable(T, fullfile(outDir, 'realtime_feature_log.csv'));
        uialert(app.fig, ['Saved feature log to ' outDir], 'Saved');
    end

    function close_gui(~, ~)
        pause_replay();
        if isfield(app, 'timer') && isvalid(app.timer)
            delete(app.timer);
        end
        delete(app.fig);
    end
end

function paths = local_paths()
matlabDir = fileparts(mfilename('fullpath'));
paths.repo = fileparts(matlabDir);
paths.subrepo = matlabDir;
paths.manifest = fullfile(paths.subrepo, 'config', 'recording_manifest.csv');
end

function delete_stale_gui_timers()
oldTimers = timerfindall('Name', 'RealtimeECGFeatureReplayTimer');
if ~isempty(oldTimers)
    stop(oldTimers);
    delete(oldTimers);
end
end

function rec = load_recording(fpath, manifestRow)
data = read_numeric_recording(fpath);
if size(data, 2) < 2
    error('Recording has fewer than two numeric columns: %s', fpath);
end

t_us = double(data(:,1));
t_s = (t_us - t_us(1)) * 1e-6;
dt = diff(t_s);
dt = dt(isfinite(dt) & dt > 0);
Fs = 1 / median(dt);

ecg_mV = double(data(:,2)) * (1800 / 4096);
imu = parse_imu_columns(data);

rec = struct();
rec.id = manifestRow.recording_id;
rec.condition = manifestRow.condition;
rec.path = string(fpath);
rec.t_s = t_s;
rec.Fs = Fs;
rec.ecg_mV = ecg_mV;
rec.imu = imu;
rec.motionBaseline = estimate_motion_baseline(imu, Fs);
end

function data = read_numeric_recording(fpath)
fid = fopen(fpath, 'r');
if fid < 0
    error('Could not open recording: %s', fpath);
end

headerLines = 0;
while true
    line = fgetl(fid);
    if ~ischar(line)
        fclose(fid);
        error('No numeric rows found in %s', fpath);
    end
    vals = str2double(regexp(strtrim(line), '[,\s]+', 'split'));
    if nnz(isfinite(vals)) >= 2
        break;
    end
    headerLines = headerLines + 1;
end
fclose(fid);

data = readmatrix(fpath, 'FileType', 'text', 'NumHeaderLines', headerLines);
data = double(data);
data = data(all(isfinite(data), 2), :);

for cc = 2:size(data, 2)
    wrapped = data(:,cc) > 2147483647;
    data(wrapped, cc) = data(wrapped, cc) - 4294967296;
end
end

function imu = parse_imu_columns(data)
N = size(data, 1);
raw = nan(N, 18);
available = max(0, min(18, size(data,2) - 2));
if available > 0
    raw(:,1:available) = data(:,3:(2+available));
end

imu = struct();
imu.raw = raw;
imu.acc_g = nan(N, 9);
imu.gyro_dps = nan(N, 9);

for site = 1:3
    src = (site-1)*6 + (1:6);
    dst = (site-1)*3 + (1:3);
    imu.acc_g(:,dst) = raw(:,src(1:3)) / 16384;
    imu.gyro_dps(:,dst) = raw(:,src(4:6)) / 131;
end
end

function base = estimate_motion_baseline(imu, Fs)
N = size(imu.raw, 1);
calN = min(N, max(16, round(5 * Fs)));

base.fastWindowSec = 0.40;
base.slowWindowSec = 2.00;
base.absQuietEnergy = 0.040;
base.absScaleEnergy = 0.060;
base.fast = estimate_motion_window_baseline(imu, Fs, calN, base.fastWindowSec);
base.slow = estimate_motion_window_baseline(imu, Fs, calN, base.slowWindowSec);

% Keep the old field names as the sustained-window baseline for compatibility.
base.med = base.slow.med;
base.mad = base.slow.mad;
end

function winBase = estimate_motion_window_baseline(imu, Fs, calN, windowSec)
win = max(8, round(windowSec * Fs));
hop = max(1, round(0.25 * Fs));
nWins = max(0, floor((calN - win) / hop) + 1);
energy = nan(nWins, 1);
ee = 0;
for stopIdx = win:hop:calN
    ee = ee + 1;
    idx = (stopIdx - win + 1):stopIdx;
    energy(ee,1) = motion_energy(imu, idx);
end
if isempty(energy)
    energy = motion_energy(imu, 1:calN);
end

winBase.med = median(energy, 'omitnan');
winBase.mad = median(abs(energy - winBase.med), 'omitnan');
madFloor = max(winBase.med * 0.25, 1e-3);
if ~isfinite(winBase.mad)
    winBase.mad = madFloor;
else
    winBase.mad = max(winBase.mad, madFloor);
end
end

function filterState = init_filters(Fs)
lo = 0.5;
hi = min(40, 0.45 * Fs);
if hi <= lo
    filterState.bpB = 1;
    filterState.bpA = 1;
else
    [filterState.bpB, filterState.bpA] = butter(2, [lo hi] / (Fs/2), 'bandpass');
end
filterState.bpZ = zeros(max(numel(filterState.bpA), numel(filterState.bpB)) - 1, 1);

if Fs > 110
    f0 = 50;
    r = 0.985;
    w0 = 2*pi*f0/Fs;
    filterState.notchB = [1, -2*cos(w0), 1];
    filterState.notchA = [1, -2*r*cos(w0), r^2];
else
    filterState.notchB = 1;
    filterState.notchA = 1;
end
filterState.notchZ = zeros(max(numel(filterState.notchA), numel(filterState.notchB)) - 1, 1);
filterState.delayMs = estimate_causal_filter_delay(filterState, Fs);
end

function [y, filterState] = filter_chunk_causal(x, filterState)
[ybp, filterState.bpZ] = filter(filterState.bpB, filterState.bpA, x, filterState.bpZ);
[y, filterState.notchZ] = filter(filterState.notchB, filterState.notchA, ybp, filterState.notchZ);
end

function [featureChunk, mode, latencyMs] = feature_only_dwt_chunk(proc, n0, n1, Fs)
% DWT is used only to stabilise feature extraction. The plotted/output ECG
% remains the causal BPF/notch signal.
latencyMs = 1000 * max(0, n1 - n0) / Fs;
histN = max(32, round(4.0 * Fs));
idx = max(1, n1 - histN + 1):n1;
x = proc(idx);
[xd, mode] = dwt_denoise_for_features(x);

rel0 = n0 - idx(1) + 1;
rel1 = n1 - idx(1) + 1;
featureChunk = xd(rel0:rel1);
end

function [y, mode] = dwt_denoise_for_features(x)
x = x(:);
y = x;
mode = "bpf_notch_feature";

good = isfinite(x);
if nnz(good) < 32
    return;
end
if any(~good)
    x = fillmissing(x, 'linear', 'EndValues', 'nearest');
end

if exist('wdenoise', 'file') == 2
    level = min(5, max(1, floor(log2(numel(x))) - 2));
    try
        y = wdenoise(x, level, ...
            'Wavelet', 'sym4', ...
            'DenoisingMethod', 'Bayes', ...
            'ThresholdRule', 'Soft');
        y = y(:);
        mode = "dwt_sym4_feature_only";
    catch
        y = x;
        mode = "dwt_unavailable_bpf_notch_feature";
    end
else
    mode = "dwt_unavailable_bpf_notch_feature";
end
end

function delayMs = estimate_causal_filter_delay(filterState, Fs)
delayMs = NaN;
try
    b = conv(filterState.bpB, filterState.notchB);
    a = conv(filterState.bpA, filterState.notchA);
    [gd, f] = grpdelay(b, a, 512, Fs);
    qrsBand = f >= 8 & f <= min(25, 0.45*Fs);
    if any(qrsBand)
        delayMs = 1000 * median(gd(qrsBand), 'omitnan') / Fs;
    end
catch
    delayMs = NaN;
end
end

function qrs = init_qrs_state(Fs)
qrs.rPeaks = [];
qrs.rSource = strings(0,1);
qrs.rFlags = strings(0,1);
qrs.rLatencyMs = [];
qrs.envBuf = zeros(max(4, round(0.150 * Fs)), 1);
qrs.warmEnv = [];
qrs.noiseLevel = 0;
qrs.signalLevel = 0;
qrs.threshold = inf;
qrs.lastDecision = -inf;
qrs.refractory = round(0.280 * Fs);
qrs.warmup = round(2.0 * Fs);
qrs.searchBack = round(0.240 * Fs);
qrs.predictHalfWindow = round(0.180 * Fs);
qrs.hardMinRR = round(0.240 * Fs);
qrs.fastReviewRR = round(0.300 * Fs);
end

function qrs = update_qrs_state(qrs, ecg, n, Fs)
if n < 2 || ~isfinite(ecg(n)) || ~isfinite(ecg(n-1))
    return;
end

d = ecg(n) - ecg(n-1);
qrs.envBuf = [d*d; qrs.envBuf(1:end-1)];
env = mean(qrs.envBuf);

if n <= qrs.warmup
    qrs.warmEnv(end+1,1) = env;
    if n == qrs.warmup
        medv = median(qrs.warmEnv);
        madv = median(abs(qrs.warmEnv - medv)) + eps;
        qrs.noiseLevel = medv;
        qrs.signalLevel = medv + 6*madv;
        qrs.threshold = medv + 3*madv;
    end
    return;
end

if env > qrs.threshold && (n - qrs.lastDecision) > qrs.refractory
    search0 = max(1, n - qrs.searchBack);
    r = localize_r_peak(ecg, search0, n, qrs);
    [qrs, accepted] = accept_qrs_candidate(qrs, ecg, r, n, "threshold", Fs);
    if accepted
        qrs.signalLevel = 0.875*qrs.signalLevel + 0.125*env;
    else
        qrs.noiseLevel = 0.995*qrs.noiseLevel + 0.005*env;
    end
else
    qrs.noiseLevel = 0.995*qrs.noiseLevel + 0.005*env;
end

qrs = try_predictive_recovery(qrs, ecg, n, Fs);

if qrs.signalLevel <= qrs.noiseLevel
    qrs.threshold = qrs.noiseLevel * 1.5 + eps;
else
    qrs.threshold = qrs.noiseLevel + 0.25*(qrs.signalLevel - qrs.noiseLevel);
end
end

function r = localize_r_peak(ecg, search0, search1, qrs)
r = [];
search0 = max(1, search0);
search1 = min(numel(ecg), search1);
if search0 > search1
    return;
end

seg = ecg(search0:search1);
if all(~isfinite(seg))
    return;
end

if numel(qrs.rPeaks) >= 3
    recent = qrs.rPeaks(max(1, end-4):end);
    recent = recent(recent >= 1 & recent <= numel(ecg));
    polarity = sign(median(ecg(recent), 'omitnan'));
else
    polarity = 0;
end

if polarity > 0
    [~, k] = max(seg);
elseif polarity < 0
    [~, k] = min(seg);
else
    [~, k] = max(abs(seg));
end
r = search0 + k - 1;
end

function [qrs, accepted] = accept_qrs_candidate(qrs, ecg, r, triggerIdx, source, Fs)
accepted = false;
if isempty(r) || ~isfinite(r) || r < 1 || r > numel(ecg) || ~isfinite(ecg(r))
    return;
end

if ~isempty(qrs.rPeaks)
    rrSamples = r - qrs.rPeaks(end);
    if rrSamples < qrs.hardMinRR
        existing = qrs.rPeaks(end);
        if peak_strength(ecg, r, Fs) > peak_strength(ecg, existing, Fs)
            qrs.rPeaks(end) = r;
            qrs.rSource(end) = source;
            qrs.rLatencyMs(end) = 1000 * (triggerIdx - r) / Fs;
            qrs.rFlags(end) = "duplicate_replaced";
            qrs.lastDecision = triggerIdx;
        end
        return;
    end
end

flag = rhythm_flag_for_candidate(qrs, r, Fs);
qrs.rPeaks(end+1,1) = r;
qrs.rSource(end+1,1) = source;
qrs.rLatencyMs(end+1,1) = 1000 * (triggerIdx - r) / Fs;
qrs.rFlags(end+1,1) = flag;
qrs.lastDecision = triggerIdx;
accepted = true;
end

function qrs = try_predictive_recovery(qrs, ecg, n, Fs)
if numel(qrs.rPeaks) < 4
    return;
end

rr = diff(qrs.rPeaks) / Fs;
rr = rr(rr >= 0.300 & rr <= 2.000);
if numel(rr) < 3
    return;
end

predRR = median(rr(max(1, end-4):end));
expected = qrs.rPeaks(end) + round(predRR * Fs);
search0 = expected - qrs.predictHalfWindow;
search1 = expected + qrs.predictHalfWindow;

if n < search1 || search0 <= qrs.rPeaks(end) + qrs.refractory
    return;
end

search0 = max(1, search0);
search1 = min(n, min(numel(ecg), search1));
r = localize_r_peak(ecg, search0, search1, qrs);
if isempty(r)
    return;
end

recent = qrs.rPeaks(max(1, end-5):end);
recentAmp = median(arrayfun(@(idx) peak_strength(ecg, idx, Fs), recent), 'omitnan');
candAmp = peak_strength(ecg, r, Fs);
if ~isfinite(candAmp) || candAmp < max(0.35 * recentAmp, eps)
    return;
end

[qrs, accepted] = accept_qrs_candidate(qrs, ecg, r, n, "predictive", Fs);
if accepted
    qrs.lastDecision = n;
end
end

function strength = peak_strength(ecg, r, Fs)
if r < 1 || r > numel(ecg) || ~isfinite(ecg(r))
    strength = NaN;
    return;
end

baseIdx = max(1, r - round(0.250*Fs)):max(1, r - round(0.120*Fs));
baseline = median(ecg(baseIdx), 'omitnan');
strength = abs(ecg(r) - baseline);
end

function flag = rhythm_flag_for_candidate(qrs, r, Fs)
flag = "ok";
if isempty(qrs.rPeaks)
    flag = "first";
    return;
end

rrSamples = r - qrs.rPeaks(end);
if rrSamples < qrs.fastReviewRR
    flag = "tachy_range_review";
    return;
end

if rrSamples > round(2.000 * Fs)
    flag = "long_rr_or_missed";
    return;
end

if numel(qrs.rPeaks) >= 4
    rr = diff(qrs.rPeaks(max(1, end-4):end)) / Fs;
    rr = rr(rr >= 0.300 & rr <= 2.000);
    if numel(rr) >= 3
        medRR = median(rr);
        thisRR = rrSamples / Fs;
        if abs(thisRR - medRR) > 0.30 * medRR
            flag = "irregular_rr_review";
        end
    end
end
end

function [score, label, latencyMs, source] = motion_epoch_score(rec, n)
latencyMs = NaN;
source = "unavailable";
if isempty(rec.imu.raw) || all(~isfinite(rec.imu.raw(:)))
    score = NaN;
    label = "no_imu";
    return;
end

fastWinSec = rec.motionBaseline.fastWindowSec;
slowWinSec = rec.motionBaseline.slowWindowSec;
[fastScore, fastComponent] = motion_score_for_window(rec, n, fastWinSec, rec.motionBaseline.fast);
[slowScore, slowComponent] = motion_score_for_window(rec, n, slowWinSec, rec.motionBaseline.slow);

if (isfinite(fastScore) && fastScore >= 3) || ~isfinite(slowScore)
    score = fastScore;
    latencyMs = 1000 * fastWinSec;
    source = "fast_" + fastComponent;
else
    score = slowScore;
    latencyMs = 1000 * slowWinSec;
    source = "sustained_" + slowComponent;
end

if ~isfinite(score)
    score = NaN;
    label = "no_imu";
    source = "unavailable";
    latencyMs = NaN;
    return;
end

if score < 3
    label = "clean";
elseif score < 8
    label = "motion_risk";
else
    label = "corrupted";
end
end

function [score, component] = motion_score_for_window(rec, n, windowSec, baseline)
idx = max(1, n - round(windowSec * rec.Fs) + 1):n;
energy = motion_energy(rec.imu, idx);
calScore = max(0, (energy - baseline.med) / (baseline.mad + eps));
absScore = max(0, (energy - rec.motionBaseline.absQuietEnergy) / ...
    rec.motionBaseline.absScaleEnergy);
if absScore > calScore
    score = absScore;
    component = "absolute";
else
    score = calScore;
    component = "calibrated";
end
end

function energy = motion_energy(imu, idx)
acc = imu.acc_g(idx, :);
gyr = imu.gyro_dps(idx, :);
acc = acc(:, all(isfinite(acc), 1));
gyr = gyr(:, all(isfinite(gyr), 1));

if isempty(acc) && isempty(gyr)
    energy = NaN;
    return;
end

accE = 0;
gyrE = 0;
if ~isempty(acc)
    acc = acc - mean(acc, 1, 'omitnan');
    accE = sqrt(mean(acc(:).^2, 'omitnan'));
end
if ~isempty(gyr)
    gyr = gyr - mean(gyr, 1, 'omitnan');
    gyrE = sqrt(mean(gyr(:).^2, 'omitnan'));
end

energy = accE + 0.01*gyrE;
end

function feat = compute_live_features(rec, proc, featureProc, n, qrs, motionScore, ...
    motionLatencyMs, motionSource, motionLabel, featureMode, featureLatencyMs)
feat = struct();
if isempty(rec) || n < 1
    feat.time_s = 0;
else
    feat.time_s = rec.t_s(n);
end

feat.hr_bpm = NaN;
feat.hr_mean_bpm = NaN;
feat.rr_ms = NaN;
feat.sdnn_ms = NaN;
feat.rmssd_ms = NaN;
feat.pnn50_pct = NaN;
feat.sd1_ms = NaN;
feat.sd2_ms = NaN;
feat.rr_cv_pct = NaN;
feat.r_amp_mv = NaN;
feat.qrs_width_ms = NaN;
feat.qrs_area_mvms = NaN;
feat.qrs_slope_mvs = NaN;
feat.baseline_mv = NaN;
feat.noise_rms_mv = NaN;
feat.st60_mv = NaN;
feat.beat_quality = NaN;
feat.detector_latency_ms = NaN;
feat.filter_delay_ms = NaN;
feat.feature_latency_ms = featureLatencyMs;
feat.feature_signal_mode = featureMode;
feat.beat_template_used = false;
feat.r_source = "unavailable";
feat.rhythm_flag = "unavailable";
feat.motion_score = NaN;
feat.motion_latency_ms = NaN;
feat.motion_source = "unavailable";
feat.motion_label = motionLabel;
feat.sqi = NaN;

if n >= 1 && numel(motionScore) >= n
    feat.motion_score = motionScore(n);
end
if n >= 1 && numel(motionLatencyMs) >= n
    feat.motion_latency_ms = motionLatencyMs(n);
end
if n >= 1 && numel(motionSource) >= n && strlength(motionSource(n)) > 0
    feat.motion_source = motionSource(n);
end

rMask = qrs.rPeaks <= n;
r = qrs.rPeaks(rMask);
rFlags = strings(size(r));
rSource = strings(size(r));
if isfield(qrs, 'rFlags') && numel(qrs.rFlags) >= numel(qrs.rPeaks)
    rFlags = qrs.rFlags(rMask);
end
if isfield(qrs, 'rSource') && numel(qrs.rSource) >= numel(qrs.rPeaks)
    rSource = qrs.rSource(rMask);
end

if ~isempty(r)
    if isfield(qrs, 'rLatencyMs') && numel(qrs.rLatencyMs) >= numel(qrs.rPeaks)
        lat = qrs.rLatencyMs(rMask);
        feat.detector_latency_ms = lat(end);
    end
    if ~isempty(rSource)
        feat.r_source = rSource(end);
    end
    if ~isempty(rFlags)
        feat.rhythm_flag = rFlags(end);
    end
end

if numel(r) >= 2
    rr = diff(rec.t_s(r));
    feat.rr_ms = 1000 * rr(end);
    feat.hr_bpm = 60 / rr(end);
    recentRR = rr(max(1, end-7):end);
    feat.hr_mean_bpm = 60 / mean(recentRR);

    rRecent = r(rec.t_s(r) >= max(0, feat.time_s - 60));
    if numel(rRecent) >= 3
        recentMask = rec.t_s(r) >= max(0, feat.time_s - 60);
        flagsRecent = rFlags(recentMask);
        rr60_ms = 1000 * diff(rec.t_s(rRecent));
        intervalFlags = flagsRecent(2:end);
        normalInterval = intervalFlags == "ok" | intervalFlags == "first";
        normalInterval = normalInterval(:);
        rr60_ms = rr60_ms(isfinite(rr60_ms) & rr60_ms >= 300 & rr60_ms <= 2000 & normalInterval);
        if numel(rr60_ms) >= 2
            drr = diff(rr60_ms);
            feat.sdnn_ms = std(rr60_ms);
            feat.rmssd_ms = sqrt(mean(drr.^2));
            feat.pnn50_pct = 100 * mean(abs(drr) > 50);
            feat.sd1_ms = feat.rmssd_ms / sqrt(2);
            feat.sd2_ms = sqrt(max(0, 2*feat.sdnn_ms^2 - 0.5*feat.rmssd_ms^2));
            feat.rr_cv_pct = 100 * feat.sdnn_ms / mean(rr60_ms);
        end
    end
end

if ~isempty(r)
    featEcg = featureProc;
    if isempty(featEcg) || numel(featEcg) ~= numel(proc)
        featEcg = proc;
        feat.feature_signal_mode = "bpf_notch_feature";
    end

    [feat.r_amp_mv, feat.qrs_width_ms, feat.st60_mv, ...
        feat.qrs_area_mvms, feat.qrs_slope_mvs, feat.baseline_mv, ...
        feat.noise_rms_mv] = beat_shape_features(featEcg, rec.Fs, r(end), n);

    observedQuality = beat_quality_score(feat);
    feat.beat_quality = observedQuality;
    if should_use_template_features(feat, rFlags)
        [templateBeat, templateR, ok] = build_clean_beat_template(featEcg, rec.Fs, ...
            r, rFlags, motionScore, n);
        if ok
            [feat.r_amp_mv, feat.qrs_width_ms, feat.st60_mv, ...
                feat.qrs_area_mvms, feat.qrs_slope_mvs, feat.baseline_mv, ...
                feat.noise_rms_mv] = beat_shape_features(templateBeat, rec.Fs, ...
                templateR, numel(templateBeat));
            feat.beat_template_used = true;
            feat.feature_signal_mode = feat.feature_signal_mode + "_template_features";
            feat.beat_quality = observedQuality;
        end
    end
end

if ~isfinite(feat.beat_quality)
    feat.beat_quality = beat_quality_score(feat);
end
feat.sqi = engineering_sqi(feat, qrs, n, rec.Fs);
end

function useTemplate = should_use_template_features(feat, rFlags)
useTemplate = false;
if isfinite(feat.motion_score) && feat.motion_score >= 3
    useTemplate = true;
end
if isfinite(feat.beat_quality) && feat.beat_quality < 55
    useTemplate = true;
end
if ~isempty(rFlags)
    flag = rFlags(end);
    if flag ~= "ok" && flag ~= "first"
        useTemplate = true;
    end
end
end

function [templateBeat, templateR, ok] = build_clean_beat_template(ecg, Fs, r, rFlags, motionScore, nNow)
pre = round(0.300 * Fs);
post = round(0.450 * Fs);
templateR = pre + 1;
templateBeat = nan(pre + post + 1, 1);
ok = false;

if numel(r) < 4
    return;
end

candidates = r(1:end-1);
candidateIdx = 1:numel(candidates);
if numel(candidates) > 12
    candidates = candidates(end-11:end);
    candidateIdx = candidateIdx(end-11:end);
end

segments = nan(numel(templateBeat), numel(candidates));
keep = false(numel(candidates), 1);
for kk = 1:numel(candidates)
    c = candidates(kk);
    if c - pre < 1 || c + post > min(numel(ecg), nNow)
        continue;
    end
    sourceIdx = candidateIdx(kk);
    if sourceIdx <= numel(rFlags)
        flag = rFlags(sourceIdx);
        if flag ~= "ok" && flag ~= "first"
            continue;
        end
    end
    if c <= numel(motionScore) && isfinite(motionScore(c)) && motionScore(c) >= 3
        continue;
    end

    seg = ecg((c-pre):(c+post));
    baseIdx = max(1, templateR - round(0.250*Fs)):max(1, templateR - round(0.120*Fs));
    base = median(seg(baseIdx), 'omitnan');
    segments(:,kk) = seg - base;
    keep(kk) = true;
end

segments = segments(:, keep);
if size(segments, 2) < 3
    return;
end

templateBeat = median(segments, 2, 'omitnan');
ok = any(isfinite(templateBeat));
end

function [rAmp, qrsWidth, st60, qrsArea, qrsSlope, baseline, noiseRms] = beat_shape_features(ecg, Fs, rIdx, nNow)
rAmp = NaN;
qrsWidth = NaN;
st60 = NaN;
qrsArea = NaN;
qrsSlope = NaN;
baseline = NaN;
noiseRms = NaN;
if rIdx < 2 || rIdx > numel(ecg) || ~isfinite(ecg(rIdx))
    return;
end

baseIdx = max(1, rIdx - round(0.250*Fs)):max(1, rIdx - round(0.120*Fs));
baseline = median(ecg(baseIdx), 'omitnan');
noiseRms = sqrt(mean((ecg(baseIdx) - baseline).^2, 'omitnan'));
rAmp = ecg(rIdx) - baseline;

left0 = max(1, rIdx - round(0.120*Fs));
right1 = min(min(numel(ecg), nNow), rIdx + round(0.120*Fs));
seg = abs(ecg(left0:right1) - baseline);
thr = 0.50 * abs(rAmp);
if isfinite(thr) && thr > 0
    relR = rIdx - left0 + 1;
    leftCross = find(seg(1:relR) < thr, 1, 'last');
    rightCrossRel = find(seg(relR:end) < thr, 1, 'first');
    if ~isempty(leftCross) && ~isempty(rightCrossRel)
        rightCross = relR + rightCrossRel - 1;
        qrsWidth = 1000 * (rightCross - leftCross) / Fs;
    end
end

areaIdx = max(1, rIdx - round(0.080*Fs)):min(min(numel(ecg), nNow), rIdx + round(0.080*Fs));
if numel(areaIdx) >= 2
    centered = ecg(areaIdx) - baseline;
    qrsArea = 1000 * sum(abs(centered), 'omitnan') / Fs;
    qrsSlope = max(abs(diff(centered)), [], 'omitnan') * Fs;
end

stIdx = rIdx + round(0.060 * Fs);
if stIdx <= nNow && stIdx <= numel(ecg)
    st60 = ecg(stIdx) - baseline;
end
end

function quality = beat_quality_score(feat)
quality = 100;

if isfinite(feat.noise_rms_mv) && isfinite(feat.r_amp_mv) && feat.noise_rms_mv > 0
    qrsSnrDb = 20 * log10(abs(feat.r_amp_mv) / (feat.noise_rms_mv + eps));
    quality = quality - max(0, 24 - qrsSnrDb) * 2.0;
else
    quality = quality - 35;
end

if isfinite(feat.qrs_width_ms) && (feat.qrs_width_ms < 50 || feat.qrs_width_ms > 180)
    quality = quality - 20;
elseif ~isfinite(feat.qrs_width_ms)
    quality = quality - 10;
end

if isfinite(feat.motion_score)
    quality = quality - min(40, 5 * feat.motion_score);
else
    quality = quality - 15;
end

quality = max(0, min(100, quality));
end

function sqi = engineering_sqi(feat, qrs, n, Fs)
sqi = 100;
if ~isfinite(feat.motion_score)
    sqi = sqi - 25;
else
    sqi = sqi - min(60, 8 * feat.motion_score);
end

if isempty(qrs.rPeaks) || (n - qrs.rPeaks(end)) > round(3 * Fs)
    sqi = sqi - 35;
end

if isfinite(feat.rr_ms)
    if feat.rr_ms < 350 || feat.rr_ms > 2000
        sqi = sqi - 25;
    end
else
    sqi = sqi - 15;
end

sqi = max(0, min(100, sqi));
end

function out = fmt_num(x, fmt)
if ~isfinite(x)
    out = 'warming / unavailable';
else
    out = sprintf(fmt, x);
end
end

function out = logical_text(x)
if islogical(x) || isnumeric(x)
    out = char(string(logical(x)));
else
    out = char(string(x));
end
end
