%% phase1_import.m
%
% AUTHOR:   Marvin Christian
% TITLE:    Phase 1 — Raw data importer, sign correction, and .mat export
% DATE:     11/04/2026
%
% SUMMARY:
%   Imports a Phase 1 recording file produced by the Python GUI logger,
%   applies sign correction for the NXP PRINTF unsigned output issue,
%   converts all fields to physical units, removes DC gravity from IMU axes,
%   and saves a clean .mat file ready for Phase 2 and Phase 3 analysis.
%
%   Run this once per condition. You will end up with:
%       resting.mat
%       walking.mat
%       arm_movement.mat
%       vibration.mat
%
% SIGN CORRECTION (critical — read this):
%   The NXP fsl_debug_console PRINTF does not reliably print negative
%   integers with %d on Cortex-M. Negative values appear as their uint32
%   two's-complement representation instead.
%   Examples from real data:
%       4294965250  ->  -2046  (ecg_corr, negative ECG baseline offset)
%       4294967208  ->  -88    (gyro reading, small negative value)
%       14820       ->  14820  (positive accel, unchanged)
%   Fix: any value > 2^31 has 2^32 subtracted from it.
%   Applied to every column EXCEPT timestamp (col 1 is always unsigned).
%
% USAGE:
%   1. Set LOGFILE and CONDITION below.
%   2. Run with F5.
%   3. Repeat for each of the 4 conditions, changing LOGFILE and CONDITION.

clear; close all; clc;

%% ── USER SETTINGS ─────────────────────────────────────────────────────────────
LOGFILE   = '2026_04_12_00_25_19\resting_20260412_002613.txt';   % <- change per condition
CONDITION = 'resting';                        % resting | walking | arm_movement | vibration

%% ── HARDWARE CONSTANTS (must match app_config_phase1.h) ──────────────────────
VREF_MV     = 1800;    % on-board ADC reference voltage (mV)
ADC_SPAN    = 4096;    % 12-bit ADC (2^12)
LSB_PER_G   = 16384;   % at +/-2 g, FS_SEL=0  (MPU-6500 RM s4.2)
LSB_PER_DPS = 131;     % at +/-250 deg/s, FS_SEL=0 (MPU-6500 RM s4.4)
DC_ALPHA    = 0.995;   % IIR DC blocker alpha (matches mas_filter.c)

%% ============================================================================
%% SECTION 1 - IMPORT
%% ============================================================================
% readmatrix() skips every non-numeric line automatically:
%   - Boot messages:  [PHASE1] Waiting for all 3 IMUs...
%   - CSV header:     t_us,ecg_corr,ax0,...
%   - Any blank lines
% Only the pure CSV numeric rows are returned.

fprintf('=== Phase 1 Import ===\n');
fprintf('File     : %s\n', LOGFILE);
fprintf('Condition: %s\n\n', CONDITION);

if ~isfile(LOGFILE)
    error('File not found: %s\nCheck filename and current folder.', LOGFILE);
end

fprintf('Reading...\n');
raw = readmatrix(LOGFILE, 'FileType', 'text');

if isempty(raw)
    error(['No numeric data found.\nCheck:\n' ...
           '  1. File contains CSV rows (not just boot messages)\n' ...
           '  2. Board was streaming before you pressed Record\n' ...
           '  3. LOGFILE path is correct']);
end

[n_rows, n_cols] = size(raw);
fprintf('Rows: %d   Columns: %d\n', n_rows, n_cols);

if n_cols == 2
    MODE = 'ECG_ONLY';
    fprintf('Mode: ECG_ONLY -> Phase 2 filter analysis\n\n');
elseif n_cols == 20
    MODE = 'ECG_IMU';
    fprintf('Mode: ECG_IMU  -> Phase 3 MAS analysis\n\n');
else
    error('Unexpected column count: %d. Expected 2 or 20.', n_cols);
end

%% ============================================================================
%% SECTION 2 - SIGN CORRECTION
%% ============================================================================
% Convert all non-timestamp columns from uint32 to signed int32 where needed.
% col 1 (t_us) is always a genuine unsigned uint32 — leave alone.

data = double(raw);
for col = 2:n_cols
    mask = data(:,col) > 2147483647;        % > 2^31 - 1
    data(mask,col) = data(mask,col) - 4294967296;   % subtract 2^32
end

n_fixed = sum(sum(raw(:,2:end) > 2147483647));
fprintf('Sign correction: %d values fixed\n\n', n_fixed);

%% ============================================================================
%% SECTION 3 - TIMESTAMP
%% ============================================================================

t_us_raw = data(:,1);

% Detect and fix single wrap (2^32 us ~ 71.6 min)
wrap_idx = find(diff(t_us_raw) < 0, 1, 'first');
if ~isempty(wrap_idx)
    fprintf('Timestamp wrap at row %d - correcting.\n', wrap_idx);
    t_us_raw(wrap_idx+1:end) = t_us_raw(wrap_idx+1:end) + 4294967296;
end

t_us = t_us_raw - t_us_raw(1);   % zero-based
t_s  = t_us / 1e6;               % microseconds -> seconds

% Measure Fs from median inter-sample interval (robust to PRINTF overruns)
dt_pos  = diff(t_s); dt_pos = dt_pos(dt_pos > 0);
fs_meas = 1 / median(dt_pos);

fprintf('Duration : %.2f s\n', t_s(end));
if strcmp(MODE, 'ECG_ONLY')
    fprintf('Fs meas  : %.2f Hz  (expect ~500 Hz)\n\n', fs_meas);
else
    fprintf('Fs meas  : %.2f Hz  (expect ~250 Hz - PRINTF overrun halves rate)\n\n', fs_meas);
end

%% ============================================================================
%% SECTION 4 - ECG
%% ============================================================================
% ecg_corr = ecg_raw - ref_raw, computed in firmware.
% Removes the AD8233 mid-supply DC bias (REFOUT = VREF/2 ~ 0.9 V).
% After sign correction: ecg_corr is in [-4095, 4095].

ecg_corr = data(:,2);
ecg_mV   = ecg_corr * (VREF_MV / ADC_SPAN);

fprintf('ECG:\n');
fprintf('  Samples: %d\n', numel(ecg_corr));
fprintf('  Range  : %.2f to %.2f mV\n', min(ecg_mV), max(ecg_mV));

if max(abs(ecg_mV)) < 0.05
    fprintf('  WARNING: very low amplitude. Check electrode contact.\n');
elseif max(abs(ecg_mV)) > 1600
    fprintf('  WARNING: near saturation. Check gain settings.\n');
end

%% ============================================================================
%% SECTION 5 - IMU  (ECG_IMU mode only)
%% ============================================================================
% Column layout:
%   col 1     : t_us
%   col 2     : ecg_corr
%   cols 3-8  : IMU0 (Left Arm)   ax,ay,az,gx,gy,gz  (raw int16 LSB)
%   cols 9-14 : IMU1 (Right Arm)  ax,ay,az,gx,gy,gz
%   cols 15-20: IMU2 (Right Leg)  ax,ay,az,gx,gy,gz

if strcmp(MODE, 'ECG_IMU')

    % Raw LSB (Kalman bypassed in firmware for Phase 1 recording)
    ax0_raw = data(:,3);  ay0_raw = data(:,4);  az0_raw = data(:,5);
    gx0_raw = data(:,6);  gy0_raw = data(:,7);  gz0_raw = data(:,8);
    ax1_raw = data(:,9);  ay1_raw = data(:,10); az1_raw = data(:,11);
    gx1_raw = data(:,12); gy1_raw = data(:,13); gz1_raw = data(:,14);
    ax2_raw = data(:,15); ay2_raw = data(:,16); az2_raw = data(:,17);
    gx2_raw = data(:,18); gy2_raw = data(:,19); gz2_raw = data(:,20);

    % Physical units
    ax0_g = ax0_raw/LSB_PER_G; ay0_g = ay0_raw/LSB_PER_G; az0_g = az0_raw/LSB_PER_G;
    ax1_g = ax1_raw/LSB_PER_G; ay1_g = ay1_raw/LSB_PER_G; az1_g = az1_raw/LSB_PER_G;
    ax2_g = ax2_raw/LSB_PER_G; ay2_g = ay2_raw/LSB_PER_G; az2_g = az2_raw/LSB_PER_G;

    gx0_dps = gx0_raw/LSB_PER_DPS; gy0_dps = gy0_raw/LSB_PER_DPS; gz0_dps = gz0_raw/LSB_PER_DPS;
    gx1_dps = gx1_raw/LSB_PER_DPS; gy1_dps = gy1_raw/LSB_PER_DPS; gz1_dps = gz1_raw/LSB_PER_DPS;
    gx2_dps = gx2_raw/LSB_PER_DPS; gy2_dps = gy2_raw/LSB_PER_DPS; gz2_dps = gz2_raw/LSB_PER_DPS;

    % Full accel magnitudes (includes gravity ~ 1 g at rest)
    mag0_g = sqrt(ax0_g.^2 + ay0_g.^2 + az0_g.^2);
    mag1_g = sqrt(ax1_g.^2 + ay1_g.^2 + az1_g.^2);
    mag2_g = sqrt(ax2_g.^2 + ay2_g.^2 + az2_g.^2);

    % DC removal - IIR high-pass matching firmware mas_filter.c DC blocker
    % dc[n] = DC_ALPHA * dc[n-1] + (1-DC_ALPHA) * x[n]
    % y[n]  = x[n] - dc[n]
    % Cutoff: (1-DC_ALPHA)*Fs/(2*pi) ~ 0.005*250/6.283 ~ 0.2 Hz
    dc_b = 1 - DC_ALPHA;
    dc_a = [1, -DC_ALPHA];

    ax0_ac = ax0_g - filter(dc_b, dc_a, ax0_g);
    ay0_ac = ay0_g - filter(dc_b, dc_a, ay0_g);
    az0_ac = az0_g - filter(dc_b, dc_a, az0_g);
    ax1_ac = ax1_g - filter(dc_b, dc_a, ax1_g);
    ay1_ac = ay1_g - filter(dc_b, dc_a, ay1_g);
    az1_ac = az1_g - filter(dc_b, dc_a, az1_g);
    ax2_ac = ax2_g - filter(dc_b, dc_a, ax2_g);
    ay2_ac = ay2_g - filter(dc_b, dc_a, ay2_g);
    az2_ac = az2_g - filter(dc_b, dc_a, az2_g);

    gx0_ac = gx0_dps - filter(dc_b, dc_a, gx0_dps);
    gy0_ac = gy0_dps - filter(dc_b, dc_a, gy0_dps);
    gz0_ac = gz0_dps - filter(dc_b, dc_a, gz0_dps);
    gx1_ac = gx1_dps - filter(dc_b, dc_a, gx1_dps);
    gy1_ac = gy1_dps - filter(dc_b, dc_a, gy1_dps);
    gz1_ac = gz1_dps - filter(dc_b, dc_a, gz1_dps);
    gx2_ac = gx2_dps - filter(dc_b, dc_a, gx2_dps);
    gy2_ac = gy2_dps - filter(dc_b, dc_a, gy2_dps);
    gz2_ac = gz2_dps - filter(dc_b, dc_a, gz2_dps);

    % AC magnitudes - these are the actual MAS reference signals
    mag0_ac  = sqrt(ax0_ac.^2 + ay0_ac.^2 + az0_ac.^2);
    mag1_ac  = sqrt(ax1_ac.^2 + ay1_ac.^2 + az1_ac.^2);
    mag2_ac  = sqrt(ax2_ac.^2 + ay2_ac.^2 + az2_ac.^2);
    gmag0_ac = sqrt(gx0_ac.^2 + gy0_ac.^2 + gz0_ac.^2);
    gmag1_ac = sqrt(gx1_ac.^2 + gy1_ac.^2 + gz1_ac.^2);
    gmag2_ac = sqrt(gx2_ac.^2 + gy2_ac.^2 + gz2_ac.^2);

    fprintf('\nIMU at-rest check (expect 0.8-1.2 g):\n');
    fprintf('  IMU0 LA  |a| = %.3f g\n', mean(mag0_g));
    fprintf('  IMU1 RA  |a| = %.3f g\n', mean(mag1_g));
    fprintf('  IMU2 RL  |a| = %.3f g\n', mean(mag2_g));

    for s = 1:3
        raw_ax = {ax0_raw, ax1_raw, ax2_raw};
        lbl    = {'IMU0 LA (D10)','IMU1 RA (D4)','IMU2 RL (D0)'};
        if all(raw_ax{s} == 0)
            fprintf('  FAIL: %s all zeros - check SPI wiring\n', lbl{s});
        end
    end
end

%% ============================================================================
%% SECTION 6 - QUICK LOOK PLOTS
%% ============================================================================

t_end  = min(15, t_s(end));
idx    = t_s <= t_end;

if strcmp(MODE, 'ECG_ONLY')
    npanels = 1;
else
    npanels = 4;
end

figure('Name', sprintf('Phase 1 — %s', CONDITION), ...
       'NumberTitle','off','Position',[50 80 1350 700]);

subplot(npanels,1,1);
plot(t_s(idx), ecg_mV(idx), 'Color',[0.15 0.4 0.8], 'LineWidth',0.8);
ylabel('ECG (mV)'); grid on; box on;
title(sprintf('ECG — %s  |  Fs=%.1f Hz  |  %d samples  |  %.1f s', ...
      CONDITION, fs_meas, n_rows, t_s(end)), 'FontSize',10);
if npanels == 1, xlabel('Time (s)'); end

if strcmp(MODE, 'ECG_IMU')
    subplot(npanels,1,2);
    plot(t_s(idx), mag0_g(idx),'b', t_s(idx), mag1_g(idx),'r', ...
         t_s(idx), mag2_g(idx),'g', 'LineWidth',0.8);
    yline(1.0,'k--','1 g','LineWidth',0.7);
    ylabel('|a| (g)'); grid on; box on;
    legend('IMU0 LA','IMU1 RA','IMU2 RL','Location','northeast','FontSize',8,'Box','off');
    title('Accel magnitude per site (includes gravity)');

    subplot(npanels,1,3);
    plot(t_s(idx), mag0_ac(idx),'b', t_s(idx), mag1_ac(idx),'r', ...
         t_s(idx), mag2_ac(idx),'g', 'LineWidth',0.8);
    ylabel('|a_{AC}| (g)'); grid on; box on;
    legend('IMU0 LA','IMU1 RA','IMU2 RL','Location','northeast','FontSize',8,'Box','off');
    title('AC accel magnitude — MAS reference (gravity removed)');

    subplot(npanels,1,4);
    plot(t_s(idx), gx0_dps(idx),'b', t_s(idx), gx1_dps(idx),'r', ...
         t_s(idx), gx2_dps(idx),'g', 'LineWidth',0.8);
    xlabel('Time (s)'); ylabel('gx (deg/s)'); grid on; box on;
    legend('IMU0 LA','IMU1 RA','IMU2 RL','Location','northeast','FontSize',8,'Box','off');
    title('Gyroscope X per site');
end

sgtitle(sprintf('Phase 1 Quick Look — %s', upper(CONDITION)), 'FontSize',12);

%% ============================================================================
%% SECTION 7 - SAVE .mat
%% ============================================================================

save_name = sprintf('%s.mat', CONDITION);

if strcmp(MODE, 'ECG_ONLY')
    save(save_name, ...
         't_s','t_us','ecg_corr','ecg_mV', ...
         'fs_meas','MODE','CONDITION','VREF_MV','ADC_SPAN');
else
    save(save_name, ...
         't_s','t_us','ecg_corr','ecg_mV', ...
         'fs_meas','MODE','CONDITION','VREF_MV','ADC_SPAN','LSB_PER_G','LSB_PER_DPS', ...
         'ax0_raw','ay0_raw','az0_raw','gx0_raw','gy0_raw','gz0_raw', ...
         'ax1_raw','ay1_raw','az1_raw','gx1_raw','gy1_raw','gz1_raw', ...
         'ax2_raw','ay2_raw','az2_raw','gx2_raw','gy2_raw','gz2_raw', ...
         'ax0_g','ay0_g','az0_g','gx0_dps','gy0_dps','gz0_dps', ...
         'ax1_g','ay1_g','az1_g','gx1_dps','gy1_dps','gz1_dps', ...
         'ax2_g','ay2_g','az2_g','gx2_dps','gy2_dps','gz2_dps', ...
         'ax0_ac','ay0_ac','az0_ac','gx0_ac','gy0_ac','gz0_ac', ...
         'ax1_ac','ay1_ac','az1_ac','gx1_ac','gy1_ac','gz1_ac', ...
         'ax2_ac','ay2_ac','az2_ac','gx2_ac','gy2_ac','gz2_ac', ...
         'mag0_g','mag1_g','mag2_g', ...
         'mag0_ac','mag1_ac','mag2_ac', ...
         'gmag0_ac','gmag1_ac','gmag2_ac');
end

fprintf('\n=== Saved: %s ===\n', save_name);
fprintf('Load in Phase 2:  load(''%s'')\n\n', save_name);
fprintf('Key variables:\n');
fprintf('  t_s        time axis (seconds)\n');
fprintf('  ecg_corr   DC-corrected ECG counts (signed)\n');
fprintf('  ecg_mV     ECG in millivolts\n');
fprintf('  fs_meas    measured sample rate (%.1f Hz)\n', fs_meas);
if strcmp(MODE, 'ECG_IMU')
fprintf('  ax0_ac     IMU0 LA accel X, DC-removed [MAS reference input]\n');
fprintf('  mag0_ac    IMU0 accel magnitude, DC-removed [M1/M2 reference]\n');
fprintf('  gmag0_ac   IMU0 gyro magnitude, DC-removed  [M9 reference]\n');
end
fprintf('\nNext condition:\n');
fprintf('  LOGFILE   = ''walking_20260411_163012.txt''\n');
fprintf('  CONDITION = ''walking''\n');
fprintf('  (then rerun this script)\n');