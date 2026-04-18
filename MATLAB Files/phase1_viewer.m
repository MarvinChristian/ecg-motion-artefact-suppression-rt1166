%% phase1_viewer_axes_full.m
%
% Purpose:
%   View Phase 1 UART recordings from the NXP board with:
%     - corrected raw ECG
%     - 3-axis accelerometer for IMU0, IMU1, IMU2
%     - 3-axis gyroscope for IMU0, IMU1, IMU2
%
% Why this file exists:
%   Your previous viewer was computing accelerometer magnitude
%   sqrt(ax^2 + ay^2 + az^2) and plotting that instead of the
%   individual axes. This file plots all axes directly.
%
% Data format expected from firmware in ECG_IMU mode:
%   t_us,ecg_corr,ax0,ay0,az0,gx0,gy0,gz0,ax1,ay1,az1,gx1,gy1,gz1,ax2,ay2,az2,gx2,gy2,gz2
%
% Notes:
%   - ecg_corr is the corrected ECG count streamed by firmware.
%     It is NOT separate ecg_raw and ref_raw.
%   - The script can display ECG in raw counts or in mV.
%   - The IMU data can be displayed in raw register units or scaled
%     engineering units using the MPU-6500 full-scale settings used
%     in your firmware:
%         accel: 16384 LSB/g at +/-2 g
%         gyro :   131 LSB/(deg/s) at +/-250 deg/s
%
% Put this file in your MATLAB folder, update LOGFILE below, and run it.

clear; close all; clc;

%% USER SETTINGS

LOGFILE = '2026_04_12_00_25_19\arm_movement_20260412_002859.txt';   % Change this to your file path
WINDOW_SEC = 10;                            % Time window shown by slider

% Display options
DISPLAY_ECG_AS_MV    = false;   % false = raw corrected ECG counts, true = mV
DISPLAY_IMU_AS_SCALED = true;   % true = g and deg/s, false = raw LSB counts

% Hardware scaling constants
VREF_MV     = 1800;   % LPADC reference used by firmware
ADC_SPAN    = 4096;   % 12-bit ADC span
LSB_PER_G   = 16384;  % MPU-6500 accel sensitivity at +/-2 g
LSB_PER_DPS = 131;    % MPU-6500 gyro sensitivity at +/-250 deg/s

%% 1) LOAD THE PUTTY LOG ROBUSTLY

fprintf('Reading: %s\n', LOGFILE);
[raw, header_names, skipped_lines] = load_putty_csv(LOGFILE);

if isempty(raw)
    error(['No valid numeric rows were found in: ' LOGFILE newline ...
           'Check the file path and confirm the log contains a CSV header.']);
end

[n_rows, n_cols] = size(raw);
fprintf('Rows loaded: %d | Columns: %d\n', n_rows, n_cols);

if ~isempty(skipped_lines)
    fprintf('Skipped %d malformed row(s). First skipped line number: %d\n', ...
        numel(skipped_lines), skipped_lines(1));
end

if n_cols ~= 2 && n_cols ~= 20
    error('Expected 2 columns (ECG_ONLY) or 20 columns (ECG_IMU). Got %d.', n_cols);
end

has_imu = (n_cols == 20);

if has_imu
    fprintf('Detected mode: ECG_IMU\n');
else
    fprintf('Detected mode: ECG_ONLY\n');
end

%% 2) PARSE TIMESTAMP

% Timestamp is unsigned in the log
t_us_raw = double(raw(:,1));

% Correct a single wrap if it occurs
wrap_idx = find(diff(t_us_raw) < 0, 1, 'first');
if ~isempty(wrap_idx)
    fprintf('Timestamp wrap detected at row %d. Correcting.\n', wrap_idx);
    t_us_raw(wrap_idx+1:end) = t_us_raw(wrap_idx+1:end) + 2^32;
end

t_s = (t_us_raw - t_us_raw(1)) / 1e6;

%% 3) PARSE ECG

% Firmware streams ecg_corr, which is already ECG_OUT - REFOUT
ecg_corr_counts = fix_sign(raw(:,2));
ecg_mV = ecg_corr_counts * (VREF_MV / ADC_SPAN);

if DISPLAY_ECG_AS_MV
    ecg_plot = ecg_mV;
    ecg_ylabel = 'ECG (mV)';
else
    ecg_plot = ecg_corr_counts;
    ecg_ylabel = 'ECG corr (counts)';
end

%% 4) PARSE IMU AXES

sig = struct();
sig.ecg = ecg_plot;

if has_imu
    % Raw signed values from the CSV
    sig.ax0 = fix_sign(raw(:,3));
    sig.ay0 = fix_sign(raw(:,4));
    sig.az0 = fix_sign(raw(:,5));
    sig.gx0 = fix_sign(raw(:,6));
    sig.gy0 = fix_sign(raw(:,7));
    sig.gz0 = fix_sign(raw(:,8));

    sig.ax1 = fix_sign(raw(:,9));
    sig.ay1 = fix_sign(raw(:,10));
    sig.az1 = fix_sign(raw(:,11));
    sig.gx1 = fix_sign(raw(:,12));
    sig.gy1 = fix_sign(raw(:,13));
    sig.gz1 = fix_sign(raw(:,14));

    sig.ax2 = fix_sign(raw(:,15));
    sig.ay2 = fix_sign(raw(:,16));
    sig.az2 = fix_sign(raw(:,17));
    sig.gx2 = fix_sign(raw(:,18));
    sig.gy2 = fix_sign(raw(:,19));
    sig.gz2 = fix_sign(raw(:,20));

    % Scale to engineering units if requested
    if DISPLAY_IMU_AS_SCALED
        sig.ax0 = sig.ax0 / LSB_PER_G;
        sig.ay0 = sig.ay0 / LSB_PER_G;
        sig.az0 = sig.az0 / LSB_PER_G;
        sig.gx0 = sig.gx0 / LSB_PER_DPS;
        sig.gy0 = sig.gy0 / LSB_PER_DPS;
        sig.gz0 = sig.gz0 / LSB_PER_DPS;

        sig.ax1 = sig.ax1 / LSB_PER_G;
        sig.ay1 = sig.ay1 / LSB_PER_G;
        sig.az1 = sig.az1 / LSB_PER_G;
        sig.gx1 = sig.gx1 / LSB_PER_DPS;
        sig.gy1 = sig.gy1 / LSB_PER_DPS;
        sig.gz1 = sig.gz1 / LSB_PER_DPS;

        sig.ax2 = sig.ax2 / LSB_PER_G;
        sig.ay2 = sig.ay2 / LSB_PER_G;
        sig.az2 = sig.az2 / LSB_PER_G;
        sig.gx2 = sig.gx2 / LSB_PER_DPS;
        sig.gy2 = sig.gy2 / LSB_PER_DPS;
        sig.gz2 = sig.gz2 / LSB_PER_DPS;

        accel_ylabel = 'Accel (g)';
        gyro_ylabel  = 'Gyro (deg/s)';
    else
        accel_ylabel = 'Accel (LSB)';
        gyro_ylabel  = 'Gyro (LSB)';
    end
end

%% 5) SUMMARY

if n_rows >= 2
    fs_est = 1 / median(diff(t_s));
else
    fs_est = NaN;
end

total_sec = t_s(end);

fprintf('Duration: %.2f s | Estimated Fs: %.2f Hz\n', total_sec, fs_est);
fprintf('ECG range: %.3f to %.3f %s\n', ...
    min(ecg_plot), max(ecg_plot), strip_unit_label(ecg_ylabel));

if has_imu
    fprintf('IMU0 accel X range: %.3f to %.3f\n', min(sig.ax0), max(sig.ax0));
    fprintf('IMU1 accel X range: %.3f to %.3f\n', min(sig.ax1), max(sig.ax1));
    fprintf('IMU2 accel X range: %.3f to %.3f\n', min(sig.ax2), max(sig.ax2));
end

%% 6) BUILD FIGURE

if has_imu
    n_panels = 7;
else
    n_panels = 1;
end

fig = figure('Name', 'Phase 1 ECG + 3-Axis IMU Viewer', ...
             'NumberTitle', 'off', ...
             'Position', [40 40 1500 900]);

ax_h = gobjects(n_panels, 1);

for p = 1:n_panels
    ax_h(p) = subplot(n_panels, 1, p);
    grid(ax_h(p), 'on');
    box(ax_h(p), 'on');

    if p < n_panels
        set(ax_h(p), 'XTickLabel', []);
    else
        xlabel(ax_h(p), 'Time (s)', 'FontSize', 9);
    end
end

linkaxes(ax_h, 'x');

uicontrol('Style', 'slider', ...
    'Min', 0, ...
    'Max', max(total_sec - WINDOW_SEC, 0.01), ...
    'Value', 0, ...
    'Units', 'normalized', ...
    'Position', [0.04 0.01 0.92 0.025], ...
    'Callback', @(src,~) redraw(src.Value, WINDOW_SEC, t_s, ax_h, sig, ...
                                has_imu, ecg_ylabel, accel_ylabel_if_exists(has_imu, accel_ylabel), ...
                                gyro_ylabel_if_exists(has_imu, gyro_ylabel)));

uicontrol('Style', 'text', ...
    'String', sprintf('Window: %.0f s | Total: %.2f s | Fs ~= %.1f Hz | Rows: %d | Skipped bad rows: %d', ...
        WINDOW_SEC, total_sec, fs_est, n_rows, numel(skipped_lines)), ...
    'Units', 'normalized', ...
    'Position', [0.04 0.965 0.92 0.025], ...
    'FontSize', 8.5, ...
    'HorizontalAlignment', 'center', ...
    'BackgroundColor', fig.Color);

% Initial draw
redraw(0, WINDOW_SEC, t_s, ax_h, sig, has_imu, ecg_ylabel, ...
       accel_ylabel_if_exists(has_imu, accel_ylabel), ...
       gyro_ylabel_if_exists(has_imu, gyro_ylabel));

%% LOCAL FUNCTIONS

function out = fix_sign(col_data)
    % Convert unsigned-imported values back to signed 32-bit if needed.
    % This is defensive. For normal int16-range values it changes nothing.
    out = double(col_data);
    idx = out > 2^31;
    out(idx) = out(idx) - 2^32;
end

function label = strip_unit_label(full_label)
    label = full_label;
end

function out = accel_ylabel_if_exists(has_imu, accel_ylabel)
    if has_imu
        out = accel_ylabel;
    else
        out = '';
    end
end

function out = gyro_ylabel_if_exists(has_imu, gyro_ylabel)
    if has_imu
        out = gyro_ylabel;
    else
        out = '';
    end
end

function [raw, header_names, skipped_lines] = load_putty_csv(filename)
    fid = fopen(filename, 'rt');
    if fid == -1
        error('Could not open file: %s', filename);
    end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

    header_names = {};
    header_found = false;
    line_number = 0;

    % Find the actual CSV header
    while true
        line = fgetl(fid);
        if ~ischar(line)
            break;
        end

        line_number = line_number + 1;
        s = strtrim(line);

        if startsWith(s, 't_us,')
            header_names = strsplit(s, ',');
            header_found = true;
            break;
        end
    end

    if ~header_found
        raw = [];
        skipped_lines = [];
        return;
    end

    expected_cols = numel(header_names);
    rows = cell(0,1);
    skipped_lines = [];

    while true
        line = fgetl(fid);
        if ~ischar(line)
            break;
        end

        line_number = line_number + 1;
        s = strtrim(line);

        if isempty(s)
            continue;
        end

        parts = strsplit(s, ',');
        if numel(parts) ~= expected_cols
            skipped_lines(end+1,1) = line_number; %#ok<AGROW>
            continue;
        end

        vals = str2double(parts);
        if any(isnan(vals))
            skipped_lines(end+1,1) = line_number; %#ok<AGROW>
            continue;
        end

        rows{end+1,1} = vals; %#ok<AGROW>
    end

    if isempty(rows)
        raw = [];
    else
        raw = vertcat(rows{:});
    end
end

function redraw(t_start, window_sec, t_s, ax_h, sig, has_imu, ecg_ylabel, accel_ylabel, gyro_ylabel)
    t_end = t_start + window_sec;
    idx = (t_s >= t_start) & (t_s <= t_end);

    if nnz(idx) < 2
        return;
    end

    t_win = t_s(idx);

    % Panel 1: ECG
    cla(ax_h(1));
    plot(ax_h(1), t_win, sig.ecg(idx), 'k', 'LineWidth', 0.7);
    ylabel(ax_h(1), ecg_ylabel, 'FontSize', 8);
    title(ax_h(1), 'Corrected Raw ECG', 'FontSize', 9);
    grid(ax_h(1), 'on');
    xlim(ax_h(1), [t_start t_end]);

    if has_imu
        plot_xyz_panel(ax_h(2), t_win, sig.ax0(idx), sig.ay0(idx), sig.az0(idx), ...
            'IMU0 Accelerometer (LA)', accel_ylabel);
        plot_xyz_panel(ax_h(3), t_win, sig.gx0(idx), sig.gy0(idx), sig.gz0(idx), ...
            'IMU0 Gyroscope (LA)', gyro_ylabel);

        plot_xyz_panel(ax_h(4), t_win, sig.ax1(idx), sig.ay1(idx), sig.az1(idx), ...
            'IMU1 Accelerometer (RA)', accel_ylabel);
        plot_xyz_panel(ax_h(5), t_win, sig.gx1(idx), sig.gy1(idx), sig.gz1(idx), ...
            'IMU1 Gyroscope (RA)', gyro_ylabel);

        plot_xyz_panel(ax_h(6), t_win, sig.ax2(idx), sig.ay2(idx), sig.az2(idx), ...
            'IMU2 Accelerometer (RL)', accel_ylabel);
        plot_xyz_panel(ax_h(7), t_win, sig.gx2(idx), sig.gy2(idx), sig.gz2(idx), ...
            'IMU2 Gyroscope (RL)', gyro_ylabel);
    end

    drawnow limitrate;
end

function plot_xyz_panel(ax, t, x, y, z, panel_title, ylab)
    cla(ax);
    hold(ax, 'on');

    plot(ax, t, x, 'LineWidth', 0.7, 'DisplayName', 'X');
    plot(ax, t, y, 'LineWidth', 0.7, 'DisplayName', 'Y');
    plot(ax, t, z, 'LineWidth', 0.7, 'DisplayName', 'Z');

    hold(ax, 'off');
    ylabel(ax, ylab, 'FontSize', 8);
    title(ax, panel_title, 'FontSize', 9);
    legend(ax, 'Location', 'northeast', 'FontSize', 7, 'Box', 'off');
    grid(ax, 'on');
    xlim(ax, [t(1) t(end)]);
end