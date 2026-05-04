% %%% phase2_analyzer.m
%
% AUTHOR:   Marvin Christian
% TITLE:    ECG Filter + MAS Analysis GUI (thesis Phase 2)
% DATE:     19/04/2026
% RENAMED:  02/05/2026 — was phase3_analyzer.m; promoted to Phase 2 main GUI
%
% CURRENT GUI-FACING SET:
%   BPF   : B1-B8 (build_bpf_struct)
%   Notch : N1-N6
%   MAS   : M1 LMS, M2 NLMS, M3 RLS, M4 RT coherent-band NLMS,
%           M5 RT differential coherent-band, M6 validated adaptive event-band.
%   These dispatch to internal implementation IDs [32, 3, 6, 24, 26, 31].
%
% LEGACY / HISTORICAL ALGORITHMS:
%   Full M1-M31 internal MAS family preserved in analyzer_history.m for
%   thesis-writing reference and offline evaluation. Do not extend this file
%   with legacy variants; work against the history file when documenting
%   prior comparisons.
%
% DIAGNOSTICS:
%   Coherence ceiling, Wiener bound, QRS-blanked γ², shifted/shuffled-null
%   controls, and batch audit live in signal_diagnose_gui.m (replaces the
%   prior phase3_diagnose*.m and phase3_mas_ceiling.m files).
%
% SUMMARY:
%   Extends phase2_analyzer with MAS evaluation (M1-M6 thesis-facing).
%   2-column and 4-column files (ECG_ONLY/ECG_ONLY_DEBUG) run Phase 2 analysis only.
%   17-column, 20-column, 21-column, 22-column, and 23-column files additionally enable
%   Phase 3 MAS evaluation. ECG_IMU_ADS/ECG_IMU_DEBUG files keep cols 1-20
%   for MAS and ignore trailing debug/extra columns here.
%
%   Supported ECG_IMU column layouts:
%     17 columns:
%       col 1      : t_us
%       col 2      : ecg_corr
%       cols 3-8   : IMU0 ax,ay,az,gx,gy,gz  (raw LSB)
%       cols 9-14  : IMU1 ax,ay,az,gx,gy,gz
%       cols 15-17 : IMU2 ax,ay,az
%
%     20 columns:
%       col 1      : t_us
%       col 2      : ecg_corr
%       cols 3-8   : IMU0 ax,ay,az,gx,gy,gz  (raw LSB)
%       cols 9-14  : IMU1 ax,ay,az,gx,gy,gz
%       cols 15-20 : IMU2 ax,ay,az,gx,gy,gz
%
%     21 columns (ADS1293_IMU):
%       col 1      : t_us
%       col 2      : ADS1293 Lead I / CH1
%       col 3      : ADS1293 Lead II / CH2
%       cols 4-21  : IMU0, IMU1, IMU2 ax,ay,az,gx,gy,gz
%
%     22 columns:
%       cols 1-20  : same as 20-column ECG_IMU
%       cols 21-22 : AD8233 OUT/REFOUT debug taps, ignored by MAS
%
%     23 columns:
%       cols 1-20  : same as 20-column ECG_IMU
%       cols 21-23 : ADS1293 Lead I/II/III extras from the Python monitor
%
% DEPENDENCIES:
%   apply_biquad.m, apply_notch.m  (same folder)
%
% MAS PARAMETERS:
%   NLMS  mu      = 0.01   (step size; normalised so this is dimensionless)
%   RLS   lambda  = 0.999  (forgetting factor)
%   APA   mu      = 0.10,  order = 2
%   VS-NLMS alpha = 0.995, beta  = 0.005, mu_max = 0.02
%   Regularisation eps = 1e-8

function phase2_analyzer()

%% ═══════════════════════════════════════════════════════════════════════
%% FILTER DEFINITIONS
%% ═══════════════════════════════════════════════════════════════════════

BPF = build_bpf_struct();
NOTCH_NAMES = {
    'N1: IIR ×6  r=0.990',
    'N2: NLMS  μ=0.005',
    'N3: Hybrid IIR+NLMS',
    'N4: RLS  λ=0.990',
    'N5: Hybrid IIR+RLS',
    'N6: Auto-detect multi-freq'
};
NOTCH_TYPES = {'N1','N2','N3','N4','N5','N6'};

MAS_NAMES = {
    'None (skip MAS)',
    'M1:  NLMS  |a|     IMU0',
    'M2:  NLMS  |a|     2-site',
    'M3:  NLMS  |a|     3-site',
    'M4:  RLS   |a|     IMU0',
    'M5:  RLS   |a|     2-site',
    'M6:  RLS   |a|     3-site',
    'M7:  NLMS  3-axis  IMU0',
    'M8:  NLMS  3-axis  2-site',
    'M9:  NLMS  3-axis  3-site',
    'M10: VS-NLMS |a|   IMU0',
    'M11: VS-NLMS |a|   2-site',
    'M12: VS-NLMS |a|   3-site',
    'M13: NLMS  |g|     IMU0',
    'M14: NLMS  |g|     2-site',
    'M15: NLMS  |g|     3-site',
    'M16: NLMS  6-axis  IMU0',
    'M17: NLMS  6-axis  2-site',
    'M18: NLMS  6-axis  3-site',
    'M19: Blanked Leaky NLMS |a| IMU0',
    'M20: Blanked Leaky NLMS |a| 2-site',
    'M21: Blanked Leaky NLMS |a| 3-site',
    'M22: Selective 2.9Hz gz1',
    'M23: RT best feature+lag NLMS',
    'M24: RT coherent-band NLMS',
    'M25: RT staged LA/RA NLMS',
    'M26: RT diff12 coherent-band',
    'M27: Aggressive all-IMU NLMS',
    'M28: Aggressive all-IMU bands',
    'M29: AD8233 OUT-matched all-IMU',
    'M30: Adaptive event-band all-IMU',
    'M31: Validated adaptive event-band'
};
MAS_LIST_IMPL  = [0 32 3 6 24 26 31];
MAS_LIST_NAMES = {
    'None (skip MAS)',
    'M1: LMS baseline |a| 3-site',
    'M2: NLMS baseline |a| 3-site',
    'M3: RLS baseline |a| 3-site',
    'M4: RT coherent-band NLMS',
    'M5: RT differential coherent-band',
    'M6: Validated adaptive event-band'
};

% Hardware constants — must match app_config_phase1.h and phase1_import.m
LSB_PER_G   = 16384;   % +/-2g, FS_SEL=0
LSB_PER_DPS = 131;     % +/-250 deg/s, FS_SEL=0
DC_ALPHA     = 0.995;  % IIR DC blocker matching firmware
ADS_SCALE_MV = (2 * 2400 / 3.5) / hex2dec('C35000');

%% ═══════════════════════════════════════════════════════════════════════
%% SHARED STATE
%% ═══════════════════════════════════════════════════════════════════════
state.raw            = [];
state.raw_bl         = [];
state.ch1_mV         = [];
state.ch2_mV         = [];
state.t_s            = [];
state.fs             = 500;
state.condition      = 'unknown';
state.file_path      = '';
state.loaded         = false;
state.mode           = 'ECG_ONLY';   % or 'ECG_IMU'
state.inject_n_tones = 4;

% IMU state (populated on ECG_IMU load)
state.imu.mag0_ac  = [];  state.imu.mag1_ac  = [];  state.imu.mag2_ac  = [];
state.imu.ax0_ac   = [];  state.imu.ay0_ac   = [];  state.imu.az0_ac   = [];
state.imu.ax1_ac   = [];  state.imu.ay1_ac   = [];  state.imu.az1_ac   = [];
state.imu.ax2_ac   = [];  state.imu.ay2_ac   = [];  state.imu.az2_ac   = [];
state.imu.gx0_ac   = [];  state.imu.gy0_ac   = [];  state.imu.gz0_ac   = [];
state.imu.gx1_ac   = [];  state.imu.gy1_ac   = [];  state.imu.gz1_ac   = [];
state.imu.gx2_ac   = [];  state.imu.gy2_ac   = [];  state.imu.gz2_ac   = [];
state.imu.gmag0_ac = [];  state.imu.gmag1_ac = [];  state.imu.gmag2_ac = [];

% Last evaluated signals (for scroll update without re-running)
state.last.sig_in   = [];
state.last.filtered = [];
state.last.after_mas = [];
state.last.ref_sig  = [];   % IMU reference used by MAS (for display)
state.last.ref_label = '';
state.last.combo_label = '';
state.last.mas_idx = 0;
state.last.stage_sigs = {};
state.last.stage_lbls = {};
state.last.mas_input = [];
state.last.mas_direct_out = [];
state.last.evaluated = false;
state.cmp_fig        = [];

%% ═══════════════════════════════════════════════════════════════════════
%% FIGURE AND LAYOUT
%% ═══════════════════════════════════════════════════════════════════════

fig = uifigure('Name','ECG Filter + MAS Analyser', ...
               'Position',[40 40 1740 970], ...
               'Color',[0.14 0.14 0.16]);

% ── Left sidebar ──────────────────────────────────────────────────────
sidebar = uipanel(fig, ...
    'Position',[8 8 340 954], ...
    'BackgroundColor',[0.18 0.18 0.21], ...
    'BorderType','none');

uilabel(sidebar, 'Text','ECG Filter + MAS Analyser  (B1-B8 | N1-N6 | M1-M6)',...
    'Position',[10 924 320 22], ...
    'FontSize',13, 'FontWeight','bold', 'FontColor',[0.9 0.9 0.9], ...
    'HorizontalAlignment','center');

% ── FILE SECTION ──────────────────────────────────────────────────────
uilabel(sidebar,'Text','RECORDING FILE','Position',[10 902 320 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

file_field = uieditfield(sidebar,'text', ...
    'Position',[10 878 270 24], ...
    'Value','Paste path or use Browse...', ...
    'FontSize',8.5, 'FontColor',[0.7 0.7 0.7], ...
    'BackgroundColor',[0.12 0.12 0.14]);

uibutton(sidebar,'Text','Browse', ...
    'Position',[285 878 50 24], ...
    'BackgroundColor',[0.25 0.45 0.65], 'FontColor','w', 'FontSize',8, ...
    'ButtonPushedFcn', @(~,~) browse_file());

condition_label = uilabel(sidebar,'Text','Condition: (load file first)', ...
    'Position',[10 858 320 16], ...
    'FontSize',8,'FontColor',[0.6 0.6 0.6]);

mode_label = uilabel(sidebar,'Text','Mode: —', ...
    'Position',[10 840 170 16], ...
    'FontSize',8,'FontColor',[0.6 0.6 0.6]);

ch_dd = uidropdown(sidebar, ...
    'Items', {'Lead I (CH1)', 'Lead II (CH2)'}, ...
    'Value', 'Lead I (CH1)', ...
    'Position', [185 836 145 22], ...
    'FontSize',8,'BackgroundColor',[0.13 0.13 0.16], ...
    'FontColor',[0.85 0.85 0.85], ...
    'Enable','off', ...
    'ValueChangedFcn',@(~,~) switch_ads_channel());

load_btn = uibutton(sidebar,'Text','Load File', ...
    'Position',[10 814 320 24], ...
    'BackgroundColor',[0.2 0.55 0.3], 'FontColor','w', ...
    'FontWeight','bold','FontSize',10, ...
    'ButtonPushedFcn', @(~,~) load_file());

status_lbl = uilabel(sidebar,'Text','No file loaded.', ...
    'Position',[10 795 320 18], ...
    'FontSize',8,'FontColor',[0.55 0.55 0.55], ...
    'HorizontalAlignment','center');

divider_line(sidebar, 783, 320);

% ── BPF SECTION ───────────────────────────────────────────────────────
uilabel(sidebar,'Text','BANDPASS FILTER  (one or none)', ...
    'Position',[10 768 320 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

bpf_grp = uibuttongroup(sidebar, ...
    'Position',[10 614 320 153], ...
    'BackgroundColor',[0.18 0.18 0.21], ...
    'BorderType','none');

bpf_btn = gobjects(numel(BPF)+1, 1);
bpf_btn(1) = uiradiobutton(bpf_grp,'Text','None (skip BPF)', ...
    'Position',[4 131 312 20],'Value',false, ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
for b = 1:numel(BPF)
    bpf_btn(b+1) = uiradiobutton(bpf_grp,'Text',BPF(b).name, ...
        'Position',[4 131-b*15 312 20],'Value',false, ...
        'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
end
bpf_btn(9).Value = true;   % B8 default

divider_line(sidebar, 602, 320);

% ── NOTCH SECTION ─────────────────────────────────────────────────────
uilabel(sidebar,'Text','NOTCH FILTER  (one or none)', ...
    'Position',[10 587 320 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

notch_grp = uibuttongroup(sidebar, ...
    'Position',[10 378 320 208], ...
    'BackgroundColor',[0.18 0.18 0.21], ...
    'BorderType','none');

notch_btn = gobjects(numel(NOTCH_NAMES)+1, 1);
notch_btn(1) = uiradiobutton(notch_grp,'Text','None (skip Notch)', ...
    'Position',[4 186 312 20],'Value',false, ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
for n = 1:numel(NOTCH_NAMES)
    notch_btn(n+1) = uiradiobutton(notch_grp,'Text',NOTCH_NAMES{n}, ...
        'Position',[4 186-n*20 312 20],'Value',false, ...
        'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
end
notch_btn(7).Value = true;  % N6 default

divider_line(sidebar, 366, 320);

% ── MAS SECTION ───────────────────────────────────────────────────────
uilabel(sidebar,'Text','MAS ALGORITHM  (requires ECG_IMU file)', ...
    'Position',[10 351 320 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

mas_list = uilistbox(sidebar, ...
    'Items', MAS_LIST_NAMES, ...
    'Position',[10 230 320 120], ...
    'Value','None (skip MAS)', ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82], ...
    'BackgroundColor',[0.13 0.13 0.16], ...
    'Enable','off');

mas_status_lbl = uilabel(sidebar,'Text','Load an ECG_IMU file to enable MAS.', ...
    'Position',[10 212 320 16], ...
    'FontSize',8,'FontColor',[0.55 0.55 0.55]);

divider_line(sidebar, 200, 320);

% ── NOISE INJECTION ───────────────────────────────────────────────────
uilabel(sidebar,'Text','NOISE INJECTION TEST', ...
    'Position',[10 185 320 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

inject_count_lbl = uilabel(sidebar, ...
    'Text',sprintf('Random tone count: %d', state.inject_n_tones), ...
    'Position',[10 166 320 16], ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);

noise_slider = uislider(sidebar, ...
    'Position',[18 156 304 3], ...
    'Limits',[1 8], 'MajorTicks',1:8, 'MinorTicks',[], ...
    'Value',state.inject_n_tones, ...
    'ValueChangedFcn', @(src,~)  update_injection_controls(src.Value), ...
    'ValueChangingFcn',@(~,evt)  update_injection_controls(evt.Value));

uilabel(sidebar,'Text','New random freqs on every Evaluate press.', ...
    'Position',[10 130 320 16],'FontSize',8,'FontColor',[0.62 0.62 0.62]);

% ── FILTER ORDER ──────────────────────────────────────────────────────
uilabel(sidebar,'Text','FILTER ORDER', ...
    'Position',[10 112 320 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

order_dd = uidropdown(sidebar, ...
    'Items', {'A: BPF → Notch → MAS', ...
              'B: MAS → BPF → Notch', ...
              'C: BPF → MAS → Notch', ...
              'D: MAS only (selected lead -> MAS)'}, ...
    'Value','A: BPF → Notch → MAS', ...
    'Position',[10 88 320 22], ...
    'FontSize',8.5,'BackgroundColor',[0.13 0.13 0.16], ...
    'FontColor',[0.85 0.85 0.85]);

uilabel(sidebar,'Text','Use D to bypass BPF/notch and inspect MAS on the selected ADS lead.', ...
    'Position',[10 68 320 16],'FontSize',8,'FontColor',[0.62 0.62 0.62]);

% ── EVALUATE ──────────────────────────────────────────────────────────
eval_btn = uibutton(sidebar,'Text','▶  EVALUATE', ...
    'Position',[10 10 320 42], ...
    'BackgroundColor',[0.2 0.45 0.75], 'FontColor','w', ...
    'FontWeight','bold','FontSize',13, ...
    'ButtonPushedFcn', @(~,~) run_evaluation());

%% ═══════════════════════════════════════════════════════════════════════
%% RIGHT PANEL — TABS
%% ═══════════════════════════════════════════════════════════════════════

tabgrp = uitabgroup(fig,'Position',[358 8 1374 954]);

tab_time   = uitab(tabgrp,'Title','  Time Domain  ',         'BackgroundColor',[0.12 0.12 0.14]);
tab_freq   = uitab(tabgrp,'Title','  Frequency Domain  ',    'BackgroundColor',[0.12 0.12 0.14]);
tab_phase  = uitab(tabgrp,'Title','  Phase & Group Delay  ', 'BackgroundColor',[0.12 0.12 0.14]);
tab_metric = uitab(tabgrp,'Title','  Measurements  ',        'BackgroundColor',[0.12 0.12 0.14]);
tab_quant  = uitab(tabgrp,'Title','  Quantitative  ',        'BackgroundColor',[0.12 0.12 0.14]);
tab_mas    = uitab(tabgrp,'Title','  MAS Analysis  ',        'BackgroundColor',[0.12 0.12 0.14]);

% ── TAB 1: TIME DOMAIN ────────────────────────────────────────────────
% Main axes — leave 50 px at bottom for scroll controls
ax_time = gobjects(4,1);
time_y = [725 505 285 65];
for tt = 1:4
    ax_time(tt) = uiaxes(tab_time,'Position',[10 time_y(tt) 1350 200], ...
        'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
        'GridColor',[0.3 0.3 0.3]);
    ax_time(tt).XGrid = 'on'; ax_time(tt).YGrid = 'on';
    ylabel(ax_time(tt),'mV','Color',[0.8 0.8 0.8]);
    if tt < 4
        ax_time(tt).XTickLabel = {};
    else
        xlabel(ax_time(tt),'Time (s)','Color',[0.8 0.8 0.8]);
    end
    title(ax_time(tt),sprintf('Stage %d - load a file and press Evaluate', tt), ...
          'Color',[0.9 0.9 0.9]);
end

% Window width dropdown
uilabel(tab_time,'Text','Window:', ...
    'Position',[10 12 60 22],'FontSize',9,'FontColor',[0.75 0.75 0.75]);
win_dd = uidropdown(tab_time, ...
    'Items',{'5 s','15 s','30 s','60 s','All'}, ...
    'Value','30 s', ...
    'Position',[72 10 70 26], ...
    'FontSize',9,'BackgroundColor',[0.16 0.16 0.18],'FontColor',[0.85 0.85 0.85], ...
    'ValueChangedFcn',@(~,~) update_time_view());

uilabel(tab_time,'Text','Position:', ...
    'Position',[155 12 60 22],'FontSize',9,'FontColor',[0.75 0.75 0.75]);

time_slider = uislider(tab_time, ...
    'Position',[220 18 860 3], ...
    'Limits',[0 1],'Value',0, ...
    'MajorTicks',[],'MinorTicks',[], ...
    'ValueChangedFcn',@(~,~) update_time_view(), ...
    'ValueChangingFcn',@(~,~) update_time_view());

bl_cb = uicheckbox(tab_time, ...
    'Text','Display baseline correction', ...
    'Value',false, ...
    'Position',[1096 10 244 22], ...
    'FontSize',9,'FontColor',[0.82 0.82 0.82], ...
    'ValueChangedFcn',@(~,~) redraw_time_display());

% ── TAB 2: FREQUENCY DOMAIN ───────────────────────────────────────────
ax_psd = uiaxes(tab_freq,'Position',[10 490 1350 450], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_psd.XGrid = 'on'; ax_psd.YGrid = 'on';
xlabel(ax_psd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_psd,'PSD (mV²/Hz)','Color',[0.8 0.8 0.8]);
title(ax_psd,'Power Spectral Density — Raw vs Filtered','Color',[0.9 0.9 0.9]);

ax_mag = uiaxes(tab_freq,'Position',[10 10 1350 460], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_mag.XGrid = 'on'; ax_mag.YGrid = 'on';
xlabel(ax_mag,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_mag,'Magnitude (dB)','Color',[0.8 0.8 0.8]);
title(ax_mag,'Filter Magnitude Response','Color',[0.9 0.9 0.9]);

% ── TAB 3: PHASE & GROUP DELAY ────────────────────────────────────────
ax_phase = uiaxes(tab_phase,'Position',[10 490 1350 450], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_phase.XGrid = 'on'; ax_phase.YGrid = 'on';
xlabel(ax_phase,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_phase,'Phase (degrees)','Color',[0.8 0.8 0.8]);
title(ax_phase,'Phase Response','Color',[0.9 0.9 0.9]);

ax_gd = uiaxes(tab_phase,'Position',[10 10 1350 460], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_gd.XGrid = 'on'; ax_gd.YGrid = 'on';
xlabel(ax_gd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_gd,'Group Delay (samples)','Color',[0.8 0.8 0.8]);
title(ax_gd,'Group Delay','Color',[0.9 0.9 0.9]);

% ── TAB 4: MEASUREMENTS ───────────────────────────────────────────────
metric_txt = uitextarea(tab_metric, ...
    'Position',[10 10 1350 890],'Editable','off', ...
    'FontSize',10.5,'FontName','Courier New', ...
    'BackgroundColor',[0.08 0.08 0.10],'FontColor',[0.85 0.85 0.85], ...
    'Value',{'Load a file and press Evaluate.'});

% ── TAB 5: QUANTITATIVE COMPARISON ───────────────────────────────────
ax_beat = uiaxes(tab_quant,'Position',[10 705 665 225], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7],'GridColor',[0.3 0.3 0.3]);
ax_beat.XGrid = 'on'; ax_beat.YGrid = 'on';
xlabel(ax_beat,'Time after R-peak (ms)','Color',[0.8 0.8 0.8]);
ylabel(ax_beat,'mV','Color',[0.8 0.8 0.8]);
title(ax_beat,'Median Beat + ST Ringing Window','Color',[0.9 0.9 0.9]);

ax_noise = uiaxes(tab_quant,'Position',[695 705 665 225], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7],'GridColor',[0.3 0.3 0.3]);
ax_noise.XGrid = 'on'; ax_noise.YGrid = 'on';
xlabel(ax_noise,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_noise,'PSD (mV²/Hz)','Color',[0.8 0.8 0.8]);
title(ax_noise,'Noise Injection Test — PSD','Color',[0.9 0.9 0.9]);

ax_inject = uiaxes(tab_quant,'Position',[10 330 1350 350], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7],'GridColor',[0.3 0.3 0.3]);
ax_inject.XGrid = 'on'; ax_inject.YGrid = 'on';
xlabel(ax_inject,'Time (s)','Color',[0.8 0.8 0.8]);
ylabel(ax_inject,'mV','Color',[0.8 0.8 0.8]);
title(ax_inject,'Noise Injection — Time Domain','Color',[0.9 0.9 0.9]);

quant_txt = uitextarea(tab_quant,'Position',[10 10 1350 295], ...
    'Editable','off','FontSize',10.5,'FontName','Courier New', ...
    'BackgroundColor',[0.08 0.08 0.10],'FontColor',[0.85 0.85 0.85], ...
    'Value',{'Run Evaluate to see quantitative metrics.'});

% ── TAB 6: MAS ANALYSIS ───────────────────────────────────────────────
% Top: MAS time trace with scroll (raw / BPF+notch / +MAS)
ax_mas_time = gobjects(2,1);
ax_mas_time(1) = uiaxes(tab_mas,'Position',[10 650 665 270], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_mas_time(2) = uiaxes(tab_mas,'Position',[695 650 665 270], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
for mm = 1:2
    ax_mas_time(mm).XGrid = 'on'; ax_mas_time(mm).YGrid = 'on';
    xlabel(ax_mas_time(mm),'Time (s)','Color',[0.8 0.8 0.8]);
    ylabel(ax_mas_time(mm),'mV','Color',[0.8 0.8 0.8]);
end
title(ax_mas_time(1),'MAS Input - load file, select MAS, press Evaluate','Color',[0.9 0.9 0.9]);
title(ax_mas_time(2),'MAS Output - load file, select MAS, press Evaluate','Color',[0.9 0.9 0.9]);

% Scroll controls for MAS time trace
uilabel(tab_mas,'Text','Window:', ...
    'Position',[10 592 60 22],'FontSize',9,'FontColor',[0.75 0.75 0.75]);
mas_win_dd = uidropdown(tab_mas, ...
    'Items',{'5 s','15 s','30 s','60 s','All'}, ...
    'Value','30 s', ...
    'Position',[72 590 70 26], ...
    'FontSize',9,'BackgroundColor',[0.16 0.16 0.18],'FontColor',[0.85 0.85 0.85], ...
    'ValueChangedFcn',@(~,~) update_mas_time_view());

uilabel(tab_mas,'Text','Position:', ...
    'Position',[155 592 60 22],'FontSize',9,'FontColor',[0.75 0.75 0.75]);

mas_time_slider = uislider(tab_mas, ...
    'Position',[220 598 1125 3], ...
    'Limits',[0 1],'Value',0, ...
    'MajorTicks',[],'MinorTicks',[], ...
    'ValueChangedFcn',@(~,~) update_mas_time_view(), ...
    'ValueChangingFcn',@(~,~) update_mas_time_view());

% Middle: IMU reference signal
ax_imu = uiaxes(tab_mas,'Position',[10 335 1350 235], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_imu.XGrid = 'on'; ax_imu.YGrid = 'on';
xlabel(ax_imu,'Time (s)','Color',[0.8 0.8 0.8]);
ylabel(ax_imu,'Reference (g or deg/s or g·s)','Color',[0.8 0.8 0.8]);
title(ax_imu,'IMU Reference Signal — used by MAS as artefact proxy','Color',[0.9 0.9 0.9]);

% Bottom: MAS metrics text
mas_txt = uitextarea(tab_mas,'Position',[10 10 1350 310], ...
    'Editable','off','FontSize',10.5,'FontName','Courier New', ...
    'BackgroundColor',[0.08 0.08 0.10],'FontColor',[0.85 0.85 0.85], ...
    'Value',{'Select a MAS algorithm and press Evaluate.'});

%% ═══════════════════════════════════════════════════════════════════════
%% CALLBACKS
%% ═══════════════════════════════════════════════════════════════════════

    function update_injection_controls(val)
        state.inject_n_tones = max(1, min(8, round(val)));
        inject_count_lbl.Text = sprintf('Random tone count: %d', state.inject_n_tones);
        if abs(noise_slider.Value - state.inject_n_tones) > eps
            noise_slider.Value = state.inject_n_tones;
        end
    end

    function browse_file()
        [fname, fpath] = uigetfile({'*.txt;*.csv','Recording files'; '*.*','All files'}, ...
                                   'Select Phase 1 recording');
        if isequal(fname, 0), return; end
        file_field.Value = fullfile(fpath, fname);
    end

    function switch_ads_channel()
        if isempty(state.ch1_mV) || isempty(state.ch2_mV)
            return;
        end
        if strcmp(ch_dd.Value, 'Lead II (CH2)')
            state.raw = state.ch2_mV;
        else
            state.raw = state.ch1_mV;
        end
        state.raw_bl = apply_display_baseline(state.raw, state.fs);
        state.last.evaluated = false;
        redraw_time_display();
        if strcmp(state.mode, 'ECG_IMU')
            mas_status_lbl.Text = sprintf('ADS1293_IMU - MAS enabled. %s active.', ch_dd.Value);
        end
    end

    function load_file()
        fpath = strtrim(file_field.Value);
        if isempty(fpath) || strcmp(fpath,'Paste path or use Browse...')
            status_lbl.Text = 'Enter or browse for a file.';
            status_lbl.FontColor = [0.9 0.4 0.4]; return;
        end
        if ~isfile(fpath)
            status_lbl.Text = 'File not found.';
            status_lbl.FontColor = [0.9 0.4 0.4]; return;
        end

        status_lbl.Text = 'Reading...';
        status_lbl.FontColor = [0.8 0.8 0.3]; drawnow;

        try
            raw_data = read_numeric_csv_file(fpath);
        catch e
            status_lbl.Text = ['Read error: ' e.message];
            status_lbl.FontColor = [0.9 0.4 0.4]; return;
        end

        if isempty(raw_data)
            status_lbl.Text = 'No numeric data in file.';
            status_lbl.FontColor = [0.9 0.4 0.4]; return;
        end

        [~, n_cols] = size(raw_data);
        original_n_cols = n_cols;
        if n_cols ~= 2 && n_cols ~= 4 && n_cols ~= 17 && n_cols ~= 20 && n_cols ~= 21 && n_cols ~= 22 && n_cols ~= 23
            status_lbl.Text = sprintf('Unexpected columns: %d (expect 2, 4, 17, 20, 21, 22, or 23).', n_cols);
            status_lbl.FontColor = [0.9 0.4 0.4]; return;
        end

        % Sign correction — NXP PRINTF uint32 issue
        data = double(raw_data);
        for col = 2:n_cols
            mask = data(:,col) > 2147483647;
            data(mask,col) = data(mask,col) - 4294967296;
        end

        % Guard against malformed serial rows that contain values outside a
        % plausible signed ADC/IMU range even after uint32 sign correction.
        if n_cols == 21
            signal_cols = 4:21;
        elseif n_cols == 23
            signal_cols = 3:20;
        else
            signal_cols = 2:min(n_cols,20);
        end
        bad_rows = any(abs(data(:,signal_cols)) > 1e6, 2);
        dropped_bad_rows = nnz(bad_rows);
        if dropped_bad_rows > 0
            data = data(~bad_rows,:);
            if isempty(data)
                status_lbl.Text = 'All rows rejected as malformed serial data.';
                status_lbl.FontColor = [0.9 0.4 0.4]; return;
            end
        end

        % Normalize supported ECG/IMU files to the internal 20-column MAS layout.
        ads1293_21 = (n_cols == 21);
        ads1293_23 = (n_cols == 23);
        state.ch1_mV = [];
        state.ch2_mV = [];

        if ads1293_21
            state.ch1_mV = data(:,2) * ADS_SCALE_MV;
            state.ch2_mV = data(:,3) * ADS_SCALE_MV;
            data = [data(:,1:2), data(:,4:21)];
            n_cols = 20;
        elseif ads1293_23
            state.ch1_mV = data(:,21) * ADS_SCALE_MV;
            state.ch2_mV = data(:,22) * ADS_SCALE_MV;
            data = data(:,1:20);
            n_cols = 20;
        elseif n_cols == 22
            data = data(:,1:20);
            n_cols = 20;
        elseif n_cols == 4
            data = data(:,1:2);
            n_cols = 2;
        end

        % Timestamps
        t_us_raw = data(:,1);
        wrap = find(diff(t_us_raw) < 0, 1);
        if ~isempty(wrap)
            t_us_raw(wrap+1:end) = t_us_raw(wrap+1:end) + 4294967296;
        end
        t_us_raw = t_us_raw - t_us_raw(1);
        t_s_data = t_us_raw / 1e6;

        dt = diff(t_s_data); dt = dt(dt > 0);
        fs_data = 1 / median(dt);

        if ads1293_21 || ads1293_23
            ch_dd.Enable = 'on';
            state.ch1_mV = despike_ecg(state.ch1_mV, fs_data);
            state.ch2_mV = despike_ecg(state.ch2_mV, fs_data);
            if strcmp(ch_dd.Value, 'Lead II (CH2)')
                ecg_mV = state.ch2_mV;
            else
                ch_dd.Value = 'Lead I (CH1)';
                ecg_mV = state.ch1_mV;
            end
        else
            ch_dd.Enable = 'off';
            ch_dd.Value = 'Lead I (CH1)';
            ecg_mV = despike_ecg(data(:,2) * (1800 / 4096), fs_data);
        end

        [~, fname_only] = fileparts(fpath);
        cond = 'unknown';
        for c = {'resting','walking','vehicular','vibration'}
            if contains(lower(fname_only), c{1}), cond = c{1}; break; end
        end

        state.raw       = ecg_mV;
        state.raw_bl    = apply_display_baseline(ecg_mV, fs_data);
        state.t_s       = t_s_data;
        state.fs        = fs_data;
        state.condition = cond;
        state.file_path = fpath;
        state.loaded    = true;
        state.last.evaluated = false;

        if n_cols == 17 || n_cols == 20
            state.mode = 'ECG_IMU';
            parse_imu(data, fs_data);
            mas_list.Enable = 'on';
            if ads1293_21 || ads1293_23
                mas_status_lbl.Text = sprintf('ADS1293_IMU (%d cols) - MAS enabled. %s active.', ...
                    original_n_cols, ch_dd.Value);
            elseif original_n_cols == 17
                mas_status_lbl.Text = 'ECG_IMU (17 cols) — MAS enabled. IMU2 gyro is zero-filled.';
            else
                mas_status_lbl.Text = 'ECG_IMU (20 cols) — MAS enabled.';
            end
            mas_status_lbl.FontColor = [0.4 0.85 0.4];
        else
            state.mode = 'ECG_ONLY';
            mas_list.Enable  = 'off';
            mas_list.Value   = 'None (skip MAS)';
            mas_status_lbl.Text = 'ECG_ONLY - load 17/20/21/22/23-col ECG_IMU/ADS1293 file for MAS.';
            mas_status_lbl.FontColor = [0.65 0.65 0.4];
        end

        condition_label.Text = sprintf('Condition: %s  |  Fs=%.1f Hz  |  %d samples  (%.1f s)', ...
            cond, fs_data, numel(ecg_mV), t_s_data(end));
        condition_label.FontColor = [0.7 0.9 0.7];
        mode_label.Text = sprintf('Mode: %s', state.mode);
        mode_label.FontColor = [0.7 0.9 0.7];

        status_lbl.Text = sprintf('Loaded: %s%s', fname_only, ...
            ternary_str(dropped_bad_rows > 0, sprintf('  (%d malformed rows dropped)', dropped_bad_rows), ''));
        status_lbl.FontColor = [0.4 0.85 0.4];

        % Preview
        render_time_stages({get_display_ecg()}, {'Raw ECG'});
        time_slider.Limits = [0 max(t_s_data(end), 0.01)];
        time_slider.Value  = 0;
        update_time_view();
    end

    function parse_imu(data, Fs)
        % Supported layouts:
        %   17 columns: IMU0(6), IMU1(6), IMU2 accel only(3)
        %   20 columns: IMU0(6), IMU1(6), IMU2(6)
        [~, n_cols_imu] = size(data);

        ax0 = data(:,3)/LSB_PER_G;   ay0 = data(:,4)/LSB_PER_G;   az0 = data(:,5)/LSB_PER_G;
        gx0 = data(:,6)/LSB_PER_DPS; gy0 = data(:,7)/LSB_PER_DPS; gz0 = data(:,8)/LSB_PER_DPS;

        ax1 = data(:,9)/LSB_PER_G;    ay1 = data(:,10)/LSB_PER_G;   az1 = data(:,11)/LSB_PER_G;
        gx1 = data(:,12)/LSB_PER_DPS; gy1 = data(:,13)/LSB_PER_DPS; gz1 = data(:,14)/LSB_PER_DPS;

        ax2 = data(:,15)/LSB_PER_G; ay2 = data(:,16)/LSB_PER_G; az2 = data(:,17)/LSB_PER_G;

        if n_cols_imu >= 20
            gx2 = data(:,18)/LSB_PER_DPS;
            gy2 = data(:,19)/LSB_PER_DPS;
            gz2 = data(:,20)/LSB_PER_DPS;
        else
            gx2 = zeros(size(ax2));
            gy2 = zeros(size(ax2));
            gz2 = zeros(size(ax2));
        end

        % DC removal — IIR high-pass matching mas_filter.c DC blocker
        % cutoff ~ (1-DC_ALPHA)*Fs/(2*pi)
        dc_b = 1 - DC_ALPHA;  dc_a = [1, -DC_ALPHA];
        dc = @(x) x - filter(dc_b, dc_a, x);

        state.imu.ax0_ac = dc(ax0); state.imu.ay0_ac = dc(ay0); state.imu.az0_ac = dc(az0);
        state.imu.gx0_ac = dc(gx0); state.imu.gy0_ac = dc(gy0); state.imu.gz0_ac = dc(gz0);
        state.imu.ax1_ac = dc(ax1); state.imu.ay1_ac = dc(ay1); state.imu.az1_ac = dc(az1);
        state.imu.gx1_ac = dc(gx1); state.imu.gy1_ac = dc(gy1); state.imu.gz1_ac = dc(gz1);
        state.imu.ax2_ac = dc(ax2); state.imu.ay2_ac = dc(ay2); state.imu.az2_ac = dc(az2);
        state.imu.gx2_ac = dc(gx2); state.imu.gy2_ac = dc(gy2); state.imu.gz2_ac = dc(gz2);

        state.imu.mag0_ac  = sqrt(state.imu.ax0_ac.^2 + state.imu.ay0_ac.^2 + state.imu.az0_ac.^2);
        state.imu.mag1_ac  = sqrt(state.imu.ax1_ac.^2 + state.imu.ay1_ac.^2 + state.imu.az1_ac.^2);
        state.imu.mag2_ac  = sqrt(state.imu.ax2_ac.^2 + state.imu.ay2_ac.^2 + state.imu.az2_ac.^2);
        state.imu.gmag0_ac = sqrt(state.imu.gx0_ac.^2 + state.imu.gy0_ac.^2 + state.imu.gz0_ac.^2);
        state.imu.gmag1_ac = sqrt(state.imu.gx1_ac.^2 + state.imu.gy1_ac.^2 + state.imu.gz1_ac.^2);
        state.imu.gmag2_ac = sqrt(state.imu.gx2_ac.^2 + state.imu.gy2_ac.^2 + state.imu.gz2_ac.^2);

        % M13 velocity: cumtrapz of AC accel, then DC-remove drift
        dt = 1 / Fs;
        vx0 = dc(cumtrapz(state.imu.ax0_ac) * dt);
        vy0 = dc(cumtrapz(state.imu.ay0_ac) * dt);
        vz0 = dc(cumtrapz(state.imu.az0_ac) * dt);
        state.imu.vel0_ac = sqrt(vx0.^2 + vy0.^2 + vz0.^2);
    end

    function data_out = read_numeric_csv_file(path_in)
        % Robust CSV reader for numeric text recordings. Some MATLAB versions
        % mis-detect comma-delimited .txt files with readmatrix(...,'FileType','text')
        % and return the wrong column count. This parser splits each non-empty
        % line explicitly on commas.
        txt = fileread(path_in);
        if ~isempty(txt) && double(txt(1)) == 65279
            txt = txt(2:end);
        end
        lines_local = regexp(txt, '\r\n|\n|\r', 'split');
        lines_local = lines_local(~cellfun(@isempty, strtrim(lines_local)));
        if isempty(lines_local)
            data_out = [];
            return;
        end

        n_cols_local = 0;
        first_numeric = 0;
        for ii = 1:numel(lines_local)
            parts = strsplit(strtrim(lines_local{ii}), ',');
            row_vals = str2double(parts);
            if ~any(isnan(row_vals))
                n_cols_local = numel(row_vals);
                first_numeric = ii;
                break;
            end
        end

        if first_numeric == 0
            data_out = [];
            return;
        end

        data_out = NaN(numel(lines_local) - first_numeric + 1, n_cols_local);
        n_rows = 0;
        for ii = first_numeric:numel(lines_local)
            parts = strsplit(strtrim(lines_local{ii}), ',');
            if numel(parts) ~= n_cols_local
                continue;
            end
            row_vals = str2double(parts);
            if any(isnan(row_vals))
                continue;
            end
            n_rows = n_rows + 1;
            data_out(n_rows,:) = row_vals;
        end

        data_out = data_out(1:n_rows, :);
    end

    function run_evaluation()
        if ~state.loaded
            status_lbl.Text = 'Load a file first.';
            status_lbl.FontColor = [0.9 0.4 0.4]; return;
        end

        bpf_sel   = get_selected_idx(bpf_grp,   bpf_btn)   - 1;
        notch_sel = get_selected_idx(notch_grp, notch_btn) - 1;

        mas_items = mas_list.Items;
        mas_val   = mas_list.Value;
        mas_ui_sel = find(strcmp(mas_items, mas_val), 1) - 1;
        if isempty(mas_ui_sel), mas_ui_sel = 0; end
        mas_sel = MAS_LIST_IMPL(mas_ui_sel + 1);

        if bpf_sel == 0 && notch_sel == 0 && mas_sel == 0
            status_lbl.Text = 'Select at least one filter or MAS algorithm.';
            status_lbl.FontColor = [0.9 0.7 0.3]; return;
        end

        status_lbl.Text = 'Evaluating...';
        status_lbl.FontColor = [0.8 0.8 0.3];
        eval_btn.Enable = 'off'; drawnow;

        try
            do_evaluation(bpf_sel, notch_sel, mas_sel);
            status_lbl.Text = 'Done.';
            status_lbl.FontColor = [0.4 0.85 0.4];
        catch e
            status_lbl.Text = ['Error: ' e.message];
            status_lbl.FontColor = [0.9 0.4 0.4];
            disp(getReport(e));
        end

        eval_btn.Enable = 'on';
    end

    function y = apply_selected_notch(x, notch_idx, Fs, bpf_idx, sos_bpf_data, ref_override)
        if notch_idx <= 0
            y = x;
            return;
        end

        notch_type = NOTCH_TYPES{notch_idx};
        if strcmp(notch_type, 'N6') && nargin >= 6 && ~isempty(ref_override)
            % ref_override is the pre-BPF signal; N6 uses it for detection
            % so it can find 50 Hz that BPF has already attenuated in x.
            y = apply_notch(x, notch_type, Fs, ref_override);
        else
            y = apply_notch(x, notch_type, Fs);
        end
    end

    function do_evaluation(bpf_idx, notch_idx, mas_idx)
        raw_mv   = state.raw;
        t_s_data = state.t_s;
        Fs       = state.fs;
        N        = numel(raw_mv);
        NFFT     = 8192;
        notch_type = '';
        if notch_idx > 0
            notch_type = NOTCH_TYPES{notch_idx};
        end

        % ── Build label ───────────────────────────────────────────────
        if bpf_idx > 0 && notch_idx > 0
            combo_label = sprintf('%s  +  %s', BPF(bpf_idx).name, NOTCH_NAMES{notch_idx});
        elseif bpf_idx > 0
            combo_label = BPF(bpf_idx).name;
        elseif notch_idx > 0
            combo_label = NOTCH_NAMES{notch_idx};
        else
            combo_label = 'No BPF/notch';
        end

        % ── Pipeline order (from sidebar dropdown) ────────────────────
        order_val = order_dd.Value;
        if startsWith(order_val, 'A')
            order_tag = 'A';    % BPF -> Notch -> MAS
        elseif startsWith(order_val, 'B')
            order_tag = 'B';    % MAS -> BPF -> Notch
        elseif startsWith(order_val, 'C')
            order_tag = 'C';    % BPF -> MAS -> Notch
        else
            order_tag = 'D';    % MAS only; BPF/notch bypassed
            bpf_idx = 0;
            notch_idx = 0;
            notch_type = '';
            combo_label = 'MAS only (raw ECG; BPF/notch bypassed)';
        end

        sig_in = double(raw_mv);
        sos_bpf_data = [];
        if bpf_idx > 0
            sos_bpf_data = build_bpf_at_fs(bpf_idx, Fs);
        end

        do_mas = mas_idx > 0 && strcmp(state.mode,'ECG_IMU') && ~isempty(state.imu.mag0_ac);
        mas_in    = [];
        t_bpf = 0; t_notch = 0; t_mas = 0;
        after_bpf = sig_in; after_notch = sig_in; after_mas = sig_in;
        ref_display = []; ref_disp_lbl = '';
        mfanf_freq_log = [];

        pipe_sigs = {};
        pipe_lbls = {};

        switch order_tag
            case 'A'
                if bpf_idx > 0
                    tA = tic; after_bpf = apply_biquad(sos_bpf_data, sig_in); t_bpf = toc(tA);
                else
                    after_bpf = sig_in;
                end
                if notch_idx > 0
                    tA = tic; after_notch = apply_selected_notch(after_bpf, notch_idx, Fs, bpf_idx, sos_bpf_data, sig_in); t_notch = toc(tA);
                else
                    after_notch = after_bpf;
                end
                after_mas = after_notch;
                if do_mas
                    mas_in = after_notch;
                    tA = tic; [after_mas, ref_display, ref_disp_lbl] = apply_mas(mas_in, mas_idx, Fs); t_mas = toc(tA);
                end
                pipe_sigs{end+1} = sig_in;       pipe_lbls{end+1} = 'Raw ECG';
                if bpf_idx   > 0, pipe_sigs{end+1} = after_bpf;   pipe_lbls{end+1} = 'After BPF'; end
                if notch_idx > 0, pipe_sigs{end+1} = after_notch;  pipe_lbls{end+1} = 'After BPF+Notch'; end
                if do_mas,        pipe_sigs{end+1} = after_mas;    pipe_lbls{end+1} = ['After MAS  [' display_mas_name(mas_idx) ']']; end
                mas_input      = after_notch;   % signal entering MAS
                mas_direct_out = after_mas;     % signal exiting MAS (= final for order A)

            case 'B'
                mas_out = sig_in;
                if do_mas
                    mas_in = sig_in;
                    tA = tic; [mas_out, ref_display, ref_disp_lbl] = apply_mas(mas_in, mas_idx, Fs); t_mas = toc(tA);
                end
                if bpf_idx > 0
                    tA = tic; after_bpf = apply_biquad(sos_bpf_data, mas_out); t_bpf = toc(tA);
                else
                    after_bpf = mas_out;
                end
                if notch_idx > 0
                    tA = tic; after_notch = apply_selected_notch(after_bpf, notch_idx, Fs, bpf_idx, sos_bpf_data, sig_in); t_notch = toc(tA);
                else
                    after_notch = after_bpf;
                end
                after_mas = after_notch;
                pipe_sigs{end+1} = sig_in;       pipe_lbls{end+1} = 'Raw ECG';
                if do_mas,        pipe_sigs{end+1} = mas_out;      pipe_lbls{end+1} = ['After MAS  [' display_mas_name(mas_idx) ']']; end
                if bpf_idx   > 0, pipe_sigs{end+1} = after_bpf;   pipe_lbls{end+1} = 'After MAS+BPF'; end
                if notch_idx > 0, pipe_sigs{end+1} = after_notch;  pipe_lbls{end+1} = 'After MAS+BPF+Notch'; end
                mas_input      = sig_in;    % signal entering MAS (raw)
                mas_direct_out = mas_out;   % signal exiting MAS before BPF+Notch

            case 'C'
                if bpf_idx > 0
                    tA = tic; after_bpf = apply_biquad(sos_bpf_data, sig_in); t_bpf = toc(tA);
                else
                    after_bpf = sig_in;
                end
                mas_out = after_bpf;
                if do_mas
                    mas_in = after_bpf;
                    tA = tic; [mas_out, ref_display, ref_disp_lbl] = apply_mas(mas_in, mas_idx, Fs); t_mas = toc(tA);
                end
                if notch_idx > 0
                    tA = tic; after_notch = apply_selected_notch(mas_out, notch_idx, Fs, bpf_idx, sos_bpf_data, sig_in); t_notch = toc(tA);
                else
                    after_notch = mas_out;
                end
                after_mas = after_notch;
                pipe_sigs{end+1} = sig_in;       pipe_lbls{end+1} = 'Raw ECG';
                if bpf_idx   > 0, pipe_sigs{end+1} = after_bpf;   pipe_lbls{end+1} = 'After BPF'; end
                if do_mas,        pipe_sigs{end+1} = mas_out;      pipe_lbls{end+1} = ['After BPF+MAS  [' display_mas_name(mas_idx) ']']; end
                if notch_idx > 0, pipe_sigs{end+1} = after_notch;  pipe_lbls{end+1} = 'After BPF+MAS+Notch'; end
                mas_input      = after_bpf;   % signal entering MAS (after BPF only)
                mas_direct_out = mas_out;     % signal exiting MAS before Notch

            case 'D'
                mas_out = sig_in;
                if do_mas
                    mas_in = sig_in;
                    tA = tic; [mas_out, ref_display, ref_disp_lbl] = apply_mas(mas_in, mas_idx, Fs); t_mas = toc(tA);
                end
                after_bpf = sig_in;
                after_notch = sig_in;
                after_mas = mas_out;
                pipe_sigs{end+1} = sig_in;       pipe_lbls{end+1} = 'Raw ECG';
                if do_mas,        pipe_sigs{end+1} = mas_out;      pipe_lbls{end+1} = ['After MAS only  [' display_mas_name(mas_idx) ']']; end
                mas_input      = sig_in;     % raw ECG entering MAS
                mas_direct_out = mas_out;    % MAS output; no downstream filters
        end

        % "filtered" = full BPF+Notch baseline (without MAS), independent of
        % order. Used downstream for comparison PSDs and MAS baselines.
        if bpf_idx > 0
            baseline_bpf = apply_biquad(sos_bpf_data, sig_in);
        else
            baseline_bpf = sig_in;
        end
        if notch_idx > 0
            filtered = apply_selected_notch(baseline_bpf, notch_idx, Fs, bpf_idx, sos_bpf_data, sig_in);
        else
            filtered = baseline_bpf;
        end
        % Keep after_bpf/after_notch names consistent with downstream code:
        %  after_bpf  = BPF-only baseline
        %  after_notch = filtered (full BPF+Notch baseline)
        after_bpf   = baseline_bpf;
        after_notch = filtered;

        % Per-sample latency in microseconds, and total in ms
        latency_info.t_bpf_us   = (t_bpf   / max(N,1)) * 1e6;
        latency_info.t_notch_us = (t_notch / max(N,1)) * 1e6;
        latency_info.t_mas_us   = (t_mas   / max(N,1)) * 1e6;
        latency_info.t_total_us = latency_info.t_bpf_us + latency_info.t_notch_us + latency_info.t_mas_us;
        latency_info.order_tag  = order_tag;
        latency_info.order_str  = order_val;
        state.last.latency      = latency_info;

        % Store for scroll update
        state.last.sig_in    = sig_in;
        state.last.filtered  = filtered;
        state.last.after_mas = after_mas;
        state.last.ref_sig   = ref_display;
        state.last.ref_label = ref_disp_lbl;
        state.last.combo_label = combo_label;
        state.last.mas_idx = mas_idx;
        state.last.stage_sigs = pipe_sigs;
        state.last.stage_lbls = pipe_lbls;
        state.last.mas_input = mas_input;
        state.last.mas_direct_out = mas_direct_out;
        state.last.evaluated = true;

        % ── Frequency response ────────────────────────────────────────
        f_ax    = (0:NFFT/2) * Fs / NFFT;
        H_bpf   = ones(NFFT/2+1, 1);
        H_notch = ones(NFFT/2+1, 1);

        if bpf_idx > 0
            H_bpf = sos_freq_response(sos_bpf_data, NFFT);
        end

        if strcmp(notch_type, 'N1')
            sos_n   = build_notch_at_fs(notch_idx, Fs);
            H_notch = sos_freq_response(sos_n, NFFT);
        elseif notch_idx > 0 && ~strcmp(notch_type, 'N6')
            H_notch = adaptive_freq_response(notch_type, Fs, NFFT);
        end

        % ── PSDs ──────────────────────────────────────────────────────
        [Praw,     f_pw] = safe_pwelch(sig_in,        Fs, NFFT);
        [Pbpf,     ~   ] = safe_pwelch(after_bpf,     Fs, NFFT);
        [Pfilt,    ~   ] = safe_pwelch(filtered,      Fs, NFFT);
        [Pmas,     ~   ] = safe_pwelch(after_mas,     Fs, NFFT);
        [P_mas_in, ~   ] = safe_pwelch(mas_input,     Fs, NFFT);
        [P_mas_out,~   ] = safe_pwelch(mas_direct_out, Fs, NFFT);

        % ── N6 empirical response ─────────────────────────────────────
        detected_freqs = [];
        if strcmp(notch_type, 'N6')
            max_pow2 = 2^floor(log2(max(N,1)));
            nfft_lo  = min(max_pow2, 2^nextpow2(round(Fs/0.005))); nfft_lo = max(nfft_lo,64);
            freqs_z1 = auto_detect_interference(sig_in,Fs,0.01,min(0.4,Fs/2-1),6,3,nfft_lo);
            nfft_ib  = min(max_pow2, 2^nextpow2(round(Fs/0.1))); nfft_ib = max(nfft_ib,64);
            freqs_z2 = auto_detect_interference(sig_in,Fs,0.5,min(40.0,Fs/2-1),20,3,nfft_ib);
            hi_hi = max(46,Fs/2-5);
            if hi_hi > 46
                freqs_z3 = auto_detect_interference(sig_in,Fs,45,hi_hi,6,5,512);
            else
                freqs_z3 = [];
            end
            detected_freqs = [freqs_z1(:)', freqs_z2(:)', freqs_z3(:)'];
            notch_input_psd = Pbpf;
            H_notch_lin = sqrt((Pfilt+1e-30)./(notch_input_psd+1e-30));
            H_notch = H_notch_lin;
        end

        H_combined    = H_bpf .* H_notch;
        H_mag_db      = 20*log10(abs(H_combined) + 1e-12);
        H_phase_deg   = unwrap(angle(H_combined)) * (180/pi);
        H_group_delay = -diff(unwrap(angle(H_combined))) / (2*pi/NFFT);
        f_gd          = f_ax(1:end-1);

        % ── Clinical reference ────────────────────────────────────────
        is_diagnostic_bpf = (bpf_idx == 3);
        ref_signal = apply_biquad(build_bpf_at_fs(1, Fs), sig_in);
        if is_diagnostic_bpf
            ref_signal = apply_notch(ref_signal,'N1',Fs);
            ref_label  = 'B1+N1 (diagnostic context)';
        else
            ref_label  = 'B1 alone (monitoring context)';
        end

        nn    = min(numel(filtered), numel(ref_signal));
        s_ref = ref_signal(1:nn);
        f_flt = filtered(1:nn);
        err   = s_ref - f_flt;

        prd_v      = 100 * sqrt(sum(err.^2) / (sum(s_ref.^2) + 1e-12));
        rmse_v     = sqrt(mean(err.^2));
        r_v        = NaN;
        if std(s_ref) > 0 && std(f_flt) > 0, r_v = corr(s_ref, f_flt); end
        snr_vs_ref = 10*log10(sum(s_ref.^2) / (sum(err.^2) + 1e-12));

        % Within-band SNR
        inband  = f_pw >= 0.5 & f_pw <= 40;
        outband = ~inband;
        E_raw_in    = sum(Praw(inband));   E_raw_out  = sum(Praw(outband));
        E_filt_in   = sum(Pfilt(inband));  E_filt_out = sum(Pfilt(outband));
        wbsnr_raw   = 10*log10(E_raw_in  / (E_raw_out  + 1e-30));
        wbsnr_filt  = 10*log10(E_filt_in / (E_filt_out + 1e-30));
        wbsnr_impr  = wbsnr_filt - wbsnr_raw;

        notch_band   = f_pw >= 48 & f_pw <= 52;
        E_50hz_raw   = sum(Praw(notch_band));
        E_50hz_filt  = sum(Pfilt(notch_band));
        notch_effect = 10*log10(E_50hz_raw / (E_50hz_filt + 1e-30));

        pb_idx   = f_ax >= 2 & f_ax <= 35;
        H_pb     = H_mag_db(pb_idx);
        ripple   = max(H_pb) - min(H_pb);
        [~,i50]  = min(abs(f_ax - 50));
        [~,i100] = min(abs(f_ax - 100));
        notch_depth = H_mag_db(i50);
        atten_100   = H_mag_db(i100);

        % ── TAB 1: TIME DOMAIN — plot full trace, set xlim via slider ─
        render_time_stages(pipe_sigs, pipe_lbls);
        if false
        cla(ax_time); hold(ax_time,'on');
        plot(ax_time, t_s_data, display_trace(sig_in), ...
             'Color',[0.45 0.45 0.5],'LineWidth',0.5,'DisplayName','Raw ECG');
        plot(ax_time, t_s_data, display_trace(filtered), ...
             'Color',[0.3 0.75 0.95],'LineWidth',0.9, ...
             'DisplayName',['BPF+Notch: ' combo_label]);
        if mas_idx > 0 && ~isempty(mas_input_sig) && ~isempty(mas_output_sig)
            plot(ax_time, t_s_data, display_trace(after_mas), ...
                 'Color',[0.35 0.9 0.5],'LineWidth',1.1, ...
                 'DisplayName',['+ ' display_mas_name(mas_idx)]);
        end
        hold(ax_time,'off');
        title(ax_time, sprintf('Time Domain — %s  |  %s', state.condition, combo_label), ...
              'Color',[0.9 0.9 0.9]);
        legend(ax_time,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_time,'mV','Color',[0.8 0.8 0.8]);
        xlabel(ax_time,'Time (s)','Color',[0.8 0.8 0.8]);
        end

        time_slider.Limits = [0 max(t_s_data(end), 0.01)];
        time_slider.Value  = 0;
        update_time_view();

        % ── TAB 2: FREQUENCY DOMAIN ───────────────────────────────────
        cla(ax_psd); hold(ax_psd,'on');
        ax_psd.YScale = 'log';
        semilogy(ax_psd,f_pw,Praw, 'Color',[0.6 0.6 0.65],'LineWidth',0.8,'DisplayName','Raw');
        semilogy(ax_psd,f_pw,Pfilt,'Color',[0.3 0.75 0.95],'LineWidth',1.2,'DisplayName','BPF+Notch');
        if mas_idx > 0
            semilogy(ax_psd,f_pw,Pmas,'Color',[0.35 0.9 0.5],'LineWidth',1.2,'DisplayName',display_mas_name(mas_idx));
        end
        xline(ax_psd,0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz','HandleVisibility','off');
        xline(ax_psd,40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz','HandleVisibility','off');
        xline(ax_psd,50, 'Color',[0.8 0.4 0.4],'LineWidth',0.8,'LineStyle','--','Label','50 Hz','HandleVisibility','off');
        if ~isempty(detected_freqs)
            for df = detected_freqs
                xline(ax_psd,df,'Color',[0.9 0.85 0.2],'LineWidth',1.1,'LineStyle','--', ...
                      'Label',sprintf('%.1fHz',df),'HandleVisibility','off');
            end
        end
        hold(ax_psd,'off');
        psd_vals = [Praw(Praw>0); Pfilt(Pfilt>0)];
        if mas_idx > 0, psd_vals = [psd_vals; Pmas(Pmas>0)]; end
        if ~isempty(psd_vals)
            ylim(ax_psd, [min(psd_vals)*0.1, max(psd_vals)*100]);
        end
        xlim(ax_psd,[0 120]);
        title(ax_psd,'Power Spectral Density','Color',[0.9 0.9 0.9]);
        legend(ax_psd,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_psd,'PSD (mV²/Hz)','Color',[0.8 0.8 0.8]);
        xlabel(ax_psd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        cla(ax_mag); hold(ax_mag,'on');
        if bpf_idx > 0 && notch_idx > 0
            plot(ax_mag,f_ax,20*log10(abs(H_bpf)+1e-12), ...
                 'Color',[0.4 0.85 0.5],'LineWidth',0.9,'LineStyle','--','DisplayName',BPF(bpf_idx).name);
            plot(ax_mag,f_ax,20*log10(abs(H_notch)+1e-12), ...
                 'Color',[0.85 0.65 0.3],'LineWidth',0.9,'LineStyle','--','DisplayName',NOTCH_NAMES{notch_idx});
        end
        plot(ax_mag,f_ax,H_mag_db,'Color',[0.3 0.75 0.95],'LineWidth',1.5,'DisplayName','Combined');
        xline(ax_mag,0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_mag,40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xline(ax_mag,50, 'Color',[0.8 0.4 0.4],'LineWidth',0.8,'LineStyle','--','Label','50 Hz');
        yline(ax_mag,-3, 'Color',[0.5 0.5 0.5],'LineWidth',0.6,'LineStyle',':','Label','-3 dB');
        yline(ax_mag,-40,'Color',[0.5 0.5 0.5],'LineWidth',0.6,'LineStyle',':','Label','-40 dB');
        hold(ax_mag,'off');
        ylim(ax_mag,[-85 5]); xlim(ax_mag,[0 120]);
        title(ax_mag,sprintf('Filter Magnitude Response (Fs=%.1f Hz)',Fs),'Color',[0.9 0.9 0.9]);
        legend(ax_mag,'Location','southwest','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_mag,'Magnitude (dB)','Color',[0.8 0.8 0.8]);
        xlabel(ax_mag,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        % ── TAB 3: PHASE & GROUP DELAY ────────────────────────────────
        cla(ax_phase);
        plot(ax_phase,f_ax,H_phase_deg,'Color',[0.75 0.5 0.9],'LineWidth',1.3);
        xline(ax_phase,0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_phase,40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xlim(ax_phase,[0 120]);
        title(ax_phase,'Phase Response','Color',[0.9 0.9 0.9]);
        ylabel(ax_phase,'Phase (degrees)','Color',[0.8 0.8 0.8]);
        xlabel(ax_phase,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        cla(ax_gd);
        plot(ax_gd,f_gd,H_group_delay,'Color',[0.9 0.65 0.35],'LineWidth',1.3);
        xline(ax_gd,0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_gd,40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xlim(ax_gd,[0 120]);
        title(ax_gd,'Group Delay (constant = linear phase)','Color',[0.9 0.9 0.9]);
        ylabel(ax_gd,'Group Delay (samples)','Color',[0.8 0.8 0.8]);
        xlabel(ax_gd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        % ── TAB 4: MEASUREMENTS ───────────────────────────────────────
        sep  = repmat('─', 1, 65);
        sep2 = repmat('·', 1, 65);
        lines_out = {
            sep
            sprintf('  FILTER:     %s', combo_label)
            sprintf('  CONDITION:  %s  |  Fs=%.2f Hz  |  %d samples  (%.1f s)', ...
                    state.condition, Fs, N, t_s_data(end))
            sprintf('  MODE:       %s', state.mode)
            sep
            ''
            '  ① WITHIN-BAND SNR IMPROVEMENT  (primary metric)'
            sep2
            sprintf('  WBSNR (raw)      : %+.2f dB', wbsnr_raw)
            sprintf('  WBSNR (filtered) : %+.2f dB', wbsnr_filt)
            sprintf('  WBSNR improvement: %+.2f dB   %s', wbsnr_impr, ...
                    ternary_str(wbsnr_impr > 0, '✓ improved', '○ no improvement'))
            ''
            sep2
            ''
            '  ② MORPHOLOGY vs CLINICAL REFERENCE'
            sep2
            sprintf('  Reference: %s', ref_label)
            sprintf('  PRD      : %.3f %%   %s', prd_v, ...
                    ternary_str(prd_v < 9, '✓ < 9%% acceptable', '✗ > 9%%'))
            sprintf('  RMSE     : %.4f mV', rmse_v)
            sprintf('  Pearson r: %.5f   %s', r_v, ...
                    ternary_str(r_v > 0.98, '✓ > 0.98', '○ < 0.98'))
            sprintf('  SNR ref  : %+.2f dB', snr_vs_ref)
            ''
            sep2
            ''
            '  ③ 50 Hz NOTCH EFFECTIVENESS'
            sep2
            sprintf('  50 Hz attenuation: %+.2f dB   %s', notch_effect, ...
                    ternary_str(notch_effect > 10, '✓ significant', ...
                    ternary_str(notch_effect > 3,  '○ moderate', '○ minimal (recording may be clean)')))
            ''
            sep2
            ''
            '  ④ FILTER DESIGN CHARACTERISTICS'
            sep2
            sprintf('  Passband ripple  : %.4f dB   %s', ripple, ...
                    ternary_str(ripple < 0.5, '✓ < 0.5 dB', ...
                    ternary_str(ripple < 1.0, '✓ < 1.0 dB', '✗ > 1 dB')))
            sprintf('  Notch depth @ 50 Hz : %.2f dB', notch_depth)
            sprintf('  Stopband  @ 100 Hz  : %.2f dB', atten_100)
        };

        if bpf_idx > 0
            lines_out{end+1} = sprintf('  BPF passband : %.2f – %.0f Hz  (%d stages)  [%s]', ...
                BPF(bpf_idx).passband(1), BPF(bpf_idx).passband(2), ...
                BPF(bpf_idx).stages, BPF(bpf_idx).standard);
        end
        if strcmp(notch_type, 'N1')
            r_val = 0.990;
            bw3db = 2*(1 - r_val)*50/pi;
            lines_out{end+1} = sprintf('  Notch -3dB BW: %.3f Hz', bw3db);
        end
        lines_out{end+1} = sep;

        % ⑤ PIPELINE LATENCY — measured wall-clock per-sample cost of each
        % stage in the order selected. This is MATLAB timing; use as a
        % relative ordering cue between algorithms, not as a firm firmware
        % budget (RT1166 CMSIS will differ).
        li = state.last.latency;
        lines_out = [lines_out; {
            ''
            sep
            '  ⑤ PIPELINE LATENCY (MATLAB wall-clock, per sample)'
            sep
            sprintf('  Order          : %s', li.order_str)
            sprintf('  BPF            : %8.2f µs/sample', li.t_bpf_us)
            sprintf('  Notch          : %8.2f µs/sample', li.t_notch_us)
            sprintf('  MAS            : %8.2f µs/sample', li.t_mas_us)
            sprintf('  Total          : %8.2f µs/sample', li.t_total_us)
            sprintf('  Budget @ %.0f Hz : %.2f µs/sample available', Fs, 1e6/Fs)
            sep
        }];

        metric_txt.Value = lines_out;

        % ── TAB 5: QUANTITATIVE ───────────────────────────────────────
        abs_sig = sort(abs(sig_in(isfinite(sig_in))));
        if isempty(abs_sig)
            robust_peak = 1;
        else
            robust_peak = abs_sig(max(1, round(0.95 * numel(abs_sig))));
        end
        t_inj = (0:N-1)' / Fs;
        rng('shuffle');
        inj_freqs = generate_random_injection_freqs(Fs, state.inject_n_tones);

        % Scale injected tones by PSD, not only by time-domain amplitude.
        % A narrow sinusoid concentrates energy into a few PSD bins, so a
        % 6% time-domain tone can become an unrealistic 40 dB+ spectral spike.
        % Keep the synthetic interference around 18 dB above the local clean
        % PSD near the injected frequencies, capped at 3% robust ECG peak.
        unit_noise = zeros(N,1);
        noise_composite = zeros(N,1);
        for fi = 1:numel(inj_freqs)
            unit_noise = unit_noise + sin(2*pi*inj_freqs(fi)*t_inj);
        end
        [P_unit, f_unit] = safe_pwelch(unit_noise, Fs, NFFT);
        target_ratio = 10^(18/10);
        psd_scale = inf;
        for fi = 1:numel(inj_freqs)
            clean_band = f_pw >= inj_freqs(fi)-2 & f_pw <= inj_freqs(fi)+2;
            unit_band  = f_unit >= inj_freqs(fi)-2 & f_unit <= inj_freqs(fi)+2;
            clean_ref  = max(Praw(clean_band));
            unit_ref   = max(P_unit(unit_band));
            if isfinite(clean_ref) && isfinite(unit_ref) && unit_ref > 0
                psd_scale = min(psd_scale, sqrt(target_ratio * max(clean_ref, realmin) / unit_ref));
            end
        end
        amp_cap = 0.03 * max(robust_peak, 1e-3) / max(1, max(abs(unit_noise)));
        if ~isfinite(psd_scale)
            inject_scale = amp_cap;
        else
            inject_scale = min(psd_scale, amp_cap);
        end
        noise_composite = inject_scale * unit_noise;
        sig_noisy = sig_in + noise_composite;

        if bpf_idx > 0
            filt_noisy = apply_biquad(sos_bpf_data, sig_noisy);
        else
            filt_noisy = sig_noisy;
        end
        if notch_idx > 0
            inject_ref = [];
            if strcmp(notch_type, 'N6')
                % N6 detects from the pre-BPF noisy signal so it can find PLI
                % that the BPF has already attenuated in filt_noisy.
                inject_ref = sig_noisy;
            end
            filt_noisy = apply_selected_notch(filt_noisy, notch_idx, Fs, bpf_idx, sos_bpf_data, inject_ref);
        end

        [P_noisy,  f_ni] = safe_pwelch(sig_noisy,  Fs, NFFT);
        [P_fnoisy, ~   ] = safe_pwelch(filt_noisy, Fs, NFFT);
        rejection_db = zeros(1, numel(inj_freqs));
        for fi = 1:numel(inj_freqs)
            band = f_ni >= inj_freqs(fi)-2 & f_ni <= inj_freqs(fi)+2;
            rejection_db(fi) = 10*log10(sum(P_noisy(band)) / (sum(P_fnoisy(band)) + 1e-30));
        end

        % Noise injection plot — first 10 s window; show only filtered output.
        % Plotting the noisy trace alongside causes fit_ylim_to_window to scale
        % to the injected sinusoid amplitude, making the filtered ECG look tiny.
        t_show_q = min(10, t_s_data(end));
        idx_q    = t_s_data <= t_show_q;
        cla(ax_inject);
        plot(ax_inject,t_s_data(idx_q),filt_noisy(idx_q), ...
             'Color',[0.3 0.75 0.95],'LineWidth',1.1);
        freq_str = strjoin(arrayfun(@(f) sprintf('%.2f Hz',f),inj_freqs,'UniformOutput',false),' + ');
        title(ax_inject,sprintf('Filtered output after injecting %s at capped 18 dB PSD level',freq_str),'Color',[0.9 0.9 0.9]);
        ylabel(ax_inject,'mV','Color',[0.8 0.8 0.8]);
        xlabel(ax_inject,'Time (s)','Color',[0.8 0.8 0.8]);
        xlim(ax_inject,[0 t_show_q]);
        fit_ylim_to_window(ax_inject);

        cla(ax_noise); hold(ax_noise,'on');
        ax_noise.YScale = 'log';
        semilogy(ax_noise,f_pw,Praw, 'Color',[0.55 0.55 0.60],'LineWidth',0.8,'DisplayName','Clean ECG');
        semilogy(ax_noise,f_ni,P_noisy, 'Color',[0.85 0.45 0.15],'LineWidth',0.9,'DisplayName','+ noise');
        semilogy(ax_noise,f_ni,P_fnoisy,'Color',[0.3 0.75 0.95],'LineWidth',1.3,'DisplayName','Filtered');
        for fi = 1:numel(inj_freqs)
            xline(ax_noise,inj_freqs(fi),'Color',[0.9 0.8 0.2],'LineWidth',1.0,'LineStyle','--', ...
                  'Label',sprintf('%.2f Hz',inj_freqs(fi)),'HandleVisibility','off');
        end
        psd_n_vals = [Praw(Praw>0); P_noisy(P_noisy>0); P_fnoisy(P_fnoisy>0)];
        if ~isempty(psd_n_vals)
            ylim(ax_noise, [min(psd_n_vals)*0.1, max(psd_n_vals)*100]);
        end
        xlim(ax_noise,[0 min(130,Fs/2)]);
        hold(ax_noise,'off');
        legend(ax_noise,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        title(ax_noise,'Noise Injection PSD','Color',[0.9 0.9 0.9]);

        % R-peak + beat analysis
        thresh    = 0.5 * max(filtered);
        min_rr    = round(0.4*Fs);
        r_peaks   = [];
        i = 1;
        while i <= numel(filtered)
            if filtered(i) > thresh
                [~,lp] = max(filtered(i:min(i+round(0.05*Fs),numel(filtered))));
                pk = i + lp - 1;
                if isempty(r_peaks) || (pk - r_peaks(end)) > min_rr
                    r_peaks(end+1) = pk; %#ok<AGROW>
                end
                i = pk + min_rr;
            else
                i = i + 1;
            end
        end

        beat_len = round(0.6*Fs);
        pre_R    = round(0.2*Fs);
        end_margin = beat_len - pre_R;
        valid_beats = r_peaks(r_peaks + end_margin <= N & r_peaks - pre_R + 1 >= 1);
        n_beats = numel(valid_beats);

        qlines = {};
        sep_q  = repmat('-', 1, 70);
        qlines{end+1,1} = sep_q;
        qlines{end+1,1} = '  REFERENCE-FREE QUANTITATIVE METRICS';
        qlines{end+1,1} = sprintf('  Filter: %s', combo_label);
        qlines{end+1,1} = sep_q;
        qlines{end+1,1} = '';
        qlines{end+1,1} = '  1) SYNTHETIC NOISE INJECTION TEST';
        qlines{end+1,1} = sprintf('  Frequencies: %s', freq_str);
        for fi = 1:numel(inj_freqs)
            qlines{end+1,1} = sprintf('  %-22s  rejection: %+.1f dB   %s', ...
                sprintf('%.2f Hz', inj_freqs(fi)), rejection_db(fi), rejection_label(rejection_db(fi)));
        end
        qlines{end+1,1} = '';
        qlines{end+1,1} = sep_q;

        if n_beats >= 3
            beat_mat = zeros(beat_len, n_beats);
            for k = 1:n_beats
                pk  = valid_beats(k);
                beat_mat(:,k) = filtered(pk-pre_R+1 : pk-pre_R+beat_len);
            end
            median_beat = median(beat_mat, 2);
            t_beat_ms   = (-pre_R : beat_len-pre_R-1) / Fs * 1000;

            st_idx  = t_beat_ms >= 60 & t_beat_ms <= 200;
            pre_idx = t_beat_ms >= -300 & t_beat_ms <= -60;

            st_rms_vals  = zeros(1,n_beats);
            pre_rms_vals = zeros(1,n_beats);
            prd_beat_vals= zeros(1,n_beats);
            for k = 1:n_beats
                res = beat_mat(:,k) - median_beat;
                st_rms_vals(k)   = rms(res(st_idx));
                pre_rms_vals(k)  = rms(res(pre_idx));
                prd_beat_vals(k) = 100*sqrt(sum(res.^2)/(sum(median_beat.^2)+1e-12));
            end
            st_rms_mean  = mean(st_rms_vals)*1000;
            pre_rms_mean = mean(pre_rms_vals)*1000;
            beat_prd_mean= mean(prd_beat_vals);
            beat_prd_std = std(prd_beat_vals);
            st_ratio_db  = 20*log10((st_rms_mean+1e-9)/(pre_rms_mean+1e-9));

            cla(ax_beat); hold(ax_beat,'on');
            patch(ax_beat,[60 200 200 60], ...
                  [min(median_beat)*1.2 min(median_beat)*1.2 max(median_beat)*1.2 max(median_beat)*1.2], ...
                  [0.9 0.4 0.4],'FaceAlpha',0.12,'EdgeColor','none','DisplayName','ST window');
            patch(ax_beat,[-300 -60 -60 -300], ...
                  [min(median_beat)*1.2 min(median_beat)*1.2 max(median_beat)*1.2 max(median_beat)*1.2], ...
                  [0.3 0.7 0.3],'FaceAlpha',0.10,'EdgeColor','none','DisplayName','Baseline');
            plot(ax_beat,t_beat_ms,median_beat,'Color',[0.3 0.75 0.95],'LineWidth',1.5,'DisplayName','Median beat');
            plot(ax_beat,t_beat_ms,beat_mat(:,1:min(5,n_beats)),'Color',[0.55 0.55 0.6],'LineWidth',0.4);
            xline(ax_beat,0,'Color',[0.8 0.8 0.8],'LineWidth',0.8,'Label','R');
            hold(ax_beat,'off');
            legend(ax_beat,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
                   'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
            title(ax_beat,sprintf('Median Beat (%d)  |  ST=%.1f uV  Baseline=%.1f uV', ...
                  n_beats,st_rms_mean,pre_rms_mean),'Color',[0.9 0.9 0.9]);
            xlabel(ax_beat,'ms post-R','Color',[0.8 0.8 0.8]);
            ylabel(ax_beat,'mV','Color',[0.8 0.8 0.8]);

            qlines{end+1,1} = '';
            qlines{end+1,1} = '  2) ST-SEGMENT RINGING  (PMC3701603)';
            qlines{end+1,1} = sprintf('  Beats detected : %d', n_beats);
            qlines{end+1,1} = sprintf('  ST RMS         : %.2f uV', st_rms_mean);
            qlines{end+1,1} = sprintf('  Baseline RMS   : %.2f uV', pre_rms_mean);
            qlines{end+1,1} = sprintf('  ST/Baseline    : %+.2f dB  %s', st_ratio_db, st_ratio_label(st_ratio_db));
            qlines{end+1,1} = '';
            qlines{end+1,1} = sep_q;
            qlines{end+1,1} = '';
            qlines{end+1,1} = '  3) BEAT-TO-BEAT MORPHOLOGY CONSISTENCY';
            qlines{end+1,1} = sprintf('  Beat PRD mean  : %.3f %%', beat_prd_mean);
            qlines{end+1,1} = sprintf('  Beat PRD std   : %.3f %%', beat_prd_std);
            qlines{end+1,1} = sep_q;
        else
            cla(ax_beat);
            text(ax_beat,0.5,0.5, sprintf('Only %d R-peaks. Need >= 3.',n_beats), ...
                 'HorizontalAlignment','center','Color',[0.8 0.8 0.8], ...
                 'Units','normalized','FontSize',10);
            qlines{end+1,1} = sprintf('  Only %d R-peaks detected.',n_beats);
            qlines{end+1,1} = sep_q;
        end
        quant_txt.Value = qlines;

        % ── TAB 6: MAS ANALYSIS ───────────────────────────────────────
        update_mas_tab(sig_in, filtered, after_mas, ref_display, ref_disp_lbl, ...
                       mas_idx, combo_label, t_s_data, Fs, Pmas, Pfilt, f_pw, ...
                       mas_input, mas_direct_out, P_mas_in, P_mas_out, order_tag);

        % Pipeline stages are rendered directly in the Time Domain tab.
    end

    function show_comparison_figure(pipe_sigs, pipe_lbls, t_s_data, combo_label, condition)
        if isfield(state,'cmp_fig') && ~isempty(state.cmp_fig) && isgraphics(state.cmp_fig,'figure')
            clf(state.cmp_fig);
            fig = state.cmp_fig;
        else
            fig = figure('Name','ECG Signal Comparison', ...
                         'NumberTitle','off', ...
                         'Color',[0.14 0.14 0.16], ...
                         'Position',[120 80 1300 750]);
            state.cmp_fig = fig;
        end

        n = numel(pipe_sigs);
        if n == 0, return; end

        fig.Name = sprintf('ECG Pipeline  —  %s  |  %s', condition, combo_label);

        bg = [0.10 0.10 0.12];
        axs = gobjects(n, 1);
        for k = 1:n
            lbl = pipe_lbls{k};
            % colour by stage type
            if contains(lbl, 'MAS')
                clr = [0.35 0.90 0.50];
            elseif contains(lbl, 'Notch')
                clr = [0.30 0.75 0.95];
            elseif contains(lbl, 'BPF')
                clr = [0.50 0.65 0.90];
            else
                clr = [0.65 0.65 0.70];  % Raw
            end

            axs(k) = subplot(n, 1, k, 'Parent', fig);
            set(axs(k), 'Color', bg, ...
                        'XColor',[0.72 0.72 0.72], 'YColor',[0.72 0.72 0.72], ...
                        'GridColor',[0.28 0.28 0.28], 'XGrid','on', 'YGrid','on');
            plot(axs(k), t_s_data, pipe_sigs{k}, 'Color', clr, 'LineWidth', 0.8);
            title(axs(k), lbl, 'Color',[0.9 0.9 0.9], 'FontSize', 9);
            ylabel(axs(k), 'mV', 'Color',[0.72 0.72 0.72]);
            if k < n
                set(axs(k), 'XTickLabel', {});
            else
                xlabel(axs(k), 'Time (s)', 'Color',[0.72 0.72 0.72]);
            end
        end
        linkaxes(axs, 'x');
        set(fig, 'UserData', axs);
    end

    function [out, ref_d, ref_lbl] = apply_mas(ecg_filtered, mas_idx, Fs)
        % Apply the selected MAS algorithm. ecg_filtered is the BPF+notch output.
        % Returns cleaned signal, display reference, and label string.

        imu = state.imu;
        EPS = 1e-8;

        switch mas_idx
            case 32  % UI M1: LMS |a| 3-site baseline
                ref   = rt_condition_mas_reference([imu.mag0_ac, imu.mag1_ac, imu.mag2_ac], Fs);
                out   = mas_lms(ecg_filtered, ref, 0.001, 16);
                ref_d = ref(:,1); ref_lbl = '|a| IMU0 (motion-band z) [LMS 3-site]';

            % ── NLMS scalar |a| ─────────────────────────────────────────
            case 1   % M1: NLMS |a| IMU0
                ref   = rt_condition_mas_reference(imu.mag0_ac, Fs);
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = ref; ref_lbl = '|a| IMU0 (motion-band z)';

            case 2   % M2: NLMS |a| 2-site (LA+RA)
                ref   = [imu.mag1_ac, imu.mag2_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.mag1_ac; ref_lbl = '|a| IMU1/LA (g) [2-site]';

            case 3   % M3: NLMS |a| 3-site (LA+RA+LL)
                ref   = rt_condition_mas_reference([imu.mag0_ac, imu.mag1_ac, imu.mag2_ac], Fs);
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = ref(:,1); ref_lbl = '|a| IMU0 (motion-band z) [3-site]';

            % ── RLS scalar |a| ──────────────────────────────────────────
            case 4   % M4: RLS |a| IMU0
                ref   = imu.mag0_ac;
                out   = mas_rls(ecg_filtered, ref, 0.999, EPS);
                ref_d = ref; ref_lbl = '|a| IMU0 (g) [RLS]';

            case 5   % M5: RLS |a| 2-site (LA+RA)
                ref   = [imu.mag1_ac, imu.mag2_ac];
                out   = mas_rls(ecg_filtered, ref, 0.999, EPS);
                ref_d = imu.mag1_ac; ref_lbl = '|a| IMU1/LA (g) [RLS 2-site]';

            case 6   % M6: RLS |a| 3-site (LA+RA+LL)
                ref   = rt_condition_mas_reference([imu.mag0_ac, imu.mag1_ac, imu.mag2_ac], Fs);
                out   = mas_rls(ecg_filtered, ref, 0.999, EPS);
                ref_d = ref(:,1); ref_lbl = '|a| IMU0 (motion-band z) [RLS 3-site]';

            % ── NLMS 3-axis accel ───────────────────────────────────────
            case 7   % M7: NLMS 3-axis IMU0
                ref   = [imu.ax0_ac, imu.ay0_ac, imu.az0_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.mag0_ac; ref_lbl = '|a| IMU0 (g) [3-axis]';

            case 8   % M8: NLMS 3-axis 2-site (LA+RA)
                ref   = [imu.ax1_ac, imu.ay1_ac, imu.az1_ac, ...
                         imu.ax2_ac, imu.ay2_ac, imu.az2_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.mag1_ac; ref_lbl = '|a| IMU1/LA (g) [3-axis 2-site]';

            case 9   % M9: NLMS 3-axis 3-site (LA+RA+LL)
                ref   = rt_condition_mas_reference([imu.ax0_ac, imu.ay0_ac, imu.az0_ac, ...
                         imu.ax1_ac, imu.ay1_ac, imu.az1_ac, ...
                         imu.ax2_ac, imu.ay2_ac, imu.az2_ac], Fs);
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = ref(:,1); ref_lbl = 'ax0 (motion-band z) [3-axis 3-site]';

            % ── VS-NLMS scalar |a| ──────────────────────────────────────
            case 10  % M10: VS-NLMS |a| IMU0
                ref   = imu.mag0_ac - mean(imu.mag0_ac);
                out   = mas_vs_nlms(ecg_filtered, ref, 0.995, 0.005, 0.02, EPS, 16);
                ref_d = ref; ref_lbl = '|a| IMU0 (g) [VS-NLMS]';

            case 11  % M11: VS-NLMS |a| 2-site (LA+RA)
                ref0  = imu.mag1_ac - mean(imu.mag1_ac);
                ref1  = imu.mag2_ac - mean(imu.mag2_ac);
                out   = mas_vs_nlms(ecg_filtered, [ref0, ref1], 0.995, 0.005, 0.02, EPS, 16);
                ref_d = ref0; ref_lbl = '|a| IMU1/LA (g) [VS-NLMS 2-site]';

            case 12  % M12: VS-NLMS |a| 3-site (LA+RA+LL)
                ref0  = imu.mag0_ac - mean(imu.mag0_ac);
                ref1  = imu.mag1_ac - mean(imu.mag1_ac);
                ref2  = imu.mag2_ac - mean(imu.mag2_ac);
                out   = mas_vs_nlms(ecg_filtered, [ref0, ref1, ref2], 0.995, 0.005, 0.02, EPS, 16);
                ref_d = ref0; ref_lbl = '|a| IMU0 (g) [VS-NLMS 3-site]';

            % ── NLMS scalar |g| ─────────────────────────────────────────
            case 13  % M13: NLMS |g| IMU0
                ref   = imu.gmag0_ac;
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = ref; ref_lbl = '|g| IMU0 (deg/s)';

            case 14  % M14: NLMS |g| 2-site (LA+RA)
                ref   = [imu.gmag1_ac, imu.gmag2_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.gmag1_ac; ref_lbl = '|g| IMU1/LA (deg/s) [2-site]';

            case 15  % M15: NLMS |g| 3-site (LA+RA+LL)
                ref   = [imu.gmag0_ac, imu.gmag1_ac, imu.gmag2_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.gmag0_ac; ref_lbl = '|g| IMU0 (deg/s) [3-site]';

            % ── NLMS 6-axis ─────────────────────────────────────────────
            case 16  % M16: NLMS 6-axis IMU0
                ref   = [imu.ax0_ac, imu.ay0_ac, imu.az0_ac, ...
                         imu.gx0_ac, imu.gy0_ac, imu.gz0_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.mag0_ac; ref_lbl = '|a| IMU0 (g) [6-axis]';

            case 17  % M17: NLMS 6-axis 2-site (LA+RA)
                ref   = [imu.ax1_ac, imu.ay1_ac, imu.az1_ac, ...
                         imu.gx1_ac, imu.gy1_ac, imu.gz1_ac, ...
                         imu.ax2_ac, imu.ay2_ac, imu.az2_ac, ...
                         imu.gx2_ac, imu.gy2_ac, imu.gz2_ac];
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = imu.mag1_ac; ref_lbl = '|a| IMU1/LA (g) [6-axis 2-site]';

            case 18  % M18: NLMS 6-axis 3-site (LA+RA+LL)
                ref   = rt_condition_mas_reference([imu.ax0_ac, imu.ay0_ac, imu.az0_ac, ...
                         imu.gx0_ac, imu.gy0_ac, imu.gz0_ac, ...
                         imu.ax1_ac, imu.ay1_ac, imu.az1_ac, ...
                         imu.gx1_ac, imu.gy1_ac, imu.gz1_ac, ...
                         imu.ax2_ac, imu.ay2_ac, imu.az2_ac, ...
                         imu.gx2_ac, imu.gy2_ac, imu.gz2_ac], Fs);
                out   = mas_nlms(ecg_filtered, ref, 0.01, EPS);
                ref_d = ref(:,1); ref_lbl = 'ax0 (motion-band z) [6-axis 3-site]';

            % ── Blanked Leaky NLMS scalar |a| ───────────────────────────
            case 19  % M19: Blanked Leaky NLMS |a| IMU0
                ref   = imu.mag0_ac;
                out   = mas_blanked_leaky_nlms(ecg_filtered, ref, 0.05, 0.02, EPS, Fs);
                ref_d = ref; ref_lbl = '|a| IMU0 (g) [blanked+leaky]';

            case 20  % M20: Blanked Leaky NLMS |a| 2-site (LA+RA)
                ref   = [imu.mag1_ac, imu.mag2_ac];
                out   = mas_blanked_leaky_nlms(ecg_filtered, ref, 0.05, 0.02, EPS, Fs);
                ref_d = imu.mag1_ac; ref_lbl = '|a| IMU1/LA (g) [blanked+leaky 2-site]';

            case 21  % M21: Blanked Leaky NLMS |a| 3-site (LA+RA+LL)
                ref   = rt_condition_mas_reference([imu.mag0_ac, imu.mag1_ac, imu.mag2_ac], Fs);
                out   = mas_blanked_leaky_nlms(ecg_filtered, ref, 0.05, 0.02, EPS, Fs);
                ref_d = ref(:,1); ref_lbl = '|a| IMU0 (motion-band z) [blanked+leaky 3-site]';

            % ── Special ─────────────────────────────────────────────────
            case 22  % M22: narrowband selective gz1 IMU1
                ref   = imu.gz1_ac;
                out   = mas_selective_band_nlms(ecg_filtered, ref, 0.05, 0.02, EPS, Fs, 2.93, 0.60, 16);
                ref_d = ref; ref_lbl = 'gz1 IMU1 (deg/s) [selective 2.9 Hz]';

            % Streaming-shaped reference-quality experiments
            case 23  % M23: feature bank + causal lag selection
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                [out, ref_d, ref_lbl] = mas_rt_feature_select_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 4, 10.0, 300, 0.10, 0.03, 0.02, EPS, 16);

            case 24  % M24: feature bank + coherent-band pruning
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                [out, ref_d, ref_lbl] = mas_rt_coherence_band_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 10.0, 300, 0.40, 3, 0.60, 0.03, 0.02, EPS, 16, 0.85);

            case 25  % M25: staged active-electrode correction, LA then RA
                [ref0, names0] = build_rt_reference_bank(imu, Fs, 'site1');
                [ref1, names1] = build_rt_reference_bank(imu, Fs, 'site2');
                [out, ref_d, ref_lbl] = mas_rt_staged_feature_select_nlms( ...
                    ecg_filtered, ref0, names0, ref1, names1, Fs, 10.0, 300, 0.10, 0.03, 0.02, EPS, 16);

            case 26  % M26: differential active-electrode references only
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'diff12');
                [out, ref_d, ref_lbl] = mas_rt_coherence_band_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 10.0, 300, 0.35, 3, 0.60, 0.03, 0.02, EPS, 16, 0.85);

            case 27  % M27: aggressive all-IMU feature+lag NLMS
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                [out, ref_d, ref_lbl] = mas_rt_feature_select_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 8, 6.0, 500, 0.03, 0.08, 0.005, EPS, 32);

            case 28  % M28: aggressive all-IMU coherent-band subtraction
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                [out, ref_d, ref_lbl] = mas_rt_coherence_band_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 6.0, 500, 0.20, 6, 1.00, 0.08, 0.005, EPS, 32, 1.25);

            case 29  % M29: AD8233CB-EBZ OUT-band matched IMU references
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                ref_bank = rt_match_filter_bank(ref_bank, Fs);
                [out, ref_d, ref_lbl] = mas_rt_feature_select_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 8, 10.0, 500, 0.05, 0.07, 0.005, EPS, 32);
                if ~isempty(ref_lbl)
                    ref_lbl = ['M29 matched-filter refs: ' ref_lbl];
                end

            case 30  % M30: rolling adaptive event-band MAS
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                ref_bank = rt_match_filter_bank(ref_bank, Fs);
                [out, ref_d, ref_lbl] = mas_rt_rolling_event_band_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 8.0, 5.0, 500, 0.18, 3, 0.80, 0.06, 0.005, EPS, 32, 1.0);

            case 31  % M31: validated rolling adaptive event-band MAS
                [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, 'all');
                ref_matched = rt_match_filter_bank(ref_bank, Fs);
                ref_bank = [ref_bank, ref_matched];
                ref_names = [ref_names, strcat('out_', ref_names)];
                [out, ref_d, ref_lbl] = mas_rt_validated_event_band_nlms( ...
                    ecg_filtered, ref_bank, ref_names, Fs, 10.0, 5.0, 500, ...
                    0.22, 0.12, 0.08, 0.18, 0.15, 1, 0.70, 0.035, 0.010, EPS, 24, 0.55);

            otherwise
                out   = ecg_filtered;
                ref_d = []; ref_lbl = '';
        end
    end

    function [ref_bank, ref_names] = build_auto_mas_refs(imu)
        % Active-electrode reference bank. IMU1=LA, IMU2=RA only.
        % IMU0=LL excluded: lower-thorax motion is not an active ECG
        % electrode motion reference for Lead I/Lead II differential paths.
        ref_bank = [
            imu.ax1_ac, imu.ay1_ac, imu.az1_ac, imu.gx1_ac, imu.gy1_ac, imu.gz1_ac, ...
            imu.ax2_ac, imu.ay2_ac, imu.az2_ac, imu.gx2_ac, imu.gy2_ac, imu.gz2_ac, ...
            imu.ax1_ac-imu.ax2_ac, imu.ay1_ac-imu.ay2_ac, imu.az1_ac-imu.az2_ac, ...
            imu.gx1_ac-imu.gx2_ac, imu.gy1_ac-imu.gy2_ac, imu.gz1_ac-imu.gz2_ac
        ];
        ref_names = {
            'ax1','ay1','az1','gx1','gy1','gz1', ...
            'ax2','ay2','az2','gx2','gy2','gz2', ...
            'dax12','day12','daz12','dgx12','dgy12','dgz12'
        };

        good = false(1, size(ref_bank,2));
        for kk = 1:size(ref_bank,2)
            good(kk) = all(isfinite(ref_bank(:,kk))) && std(ref_bank(:,kk)) > 1e-10;
        end
        ref_bank = ref_bank(:, good);
        ref_names = ref_names(good);
    end

    function update_mas_tab(sig_in, filtered, after_mas, ref_display, ref_disp_lbl, ...
                            mas_idx, combo_label, t_s_data, Fs, Pmas, Pfilt, f_pw, ...
                            mas_input, mas_direct_out, P_mas_in, P_mas_out, order_tag)

        % Time trace — full recording, scroll controlled by mas_time_slider
        render_mas_before_after(mas_input, filtered, after_mas, mas_idx, combo_label);
        if false
        cla(ax_mas_time); hold(ax_mas_time,'on');
        plot(ax_mas_time, t_s_data, display_trace(sig_in), ...
             'Color',[0.45 0.45 0.5],'LineWidth',0.5,'DisplayName','Raw ECG');
        if strcmp(order_tag, 'D') || strcmp(combo_label, 'No BPF/notch')
            baseline_disp = 'Raw baseline';
        else
            baseline_disp = ['BPF+Notch: ' combo_label];
        end
        plot(ax_mas_time, t_s_data, display_trace(filtered), ...
             'Color',[0.3 0.75 0.95],'LineWidth',0.9,'DisplayName',baseline_disp);
        if mas_idx > 0 && ~isequal(after_mas, filtered)
            plot(ax_mas_time, t_s_data, display_trace(after_mas), ...
                 'Color',[0.35 0.9 0.5],'LineWidth',1.2,'DisplayName',display_mas_name(mas_idx));
        end
        hold(ax_mas_time,'off');
        title(ax_mas_time, sprintf('MAS Output — %s  |  %s', state.condition, combo_label), ...
              'Color',[0.9 0.9 0.9]);
        legend(ax_mas_time,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_mas_time,'mV','Color',[0.8 0.8 0.8]);
        xlabel(ax_mas_time,'Time (s)','Color',[0.8 0.8 0.8]);

        mas_time_slider.Limits = [0 max(t_s_data(end), 0.01)];
        mas_time_slider.Value  = 0;
        update_mas_time_view();
        end

        % IMU reference
        cla(ax_imu);
        if ~isempty(ref_display) && numel(ref_display) == numel(t_s_data)
            plot(ax_imu, t_s_data, ref_display, 'Color',[0.9 0.7 0.3],'LineWidth',0.8);
            title(ax_imu, sprintf('MAS Reference (selected/processed IMU) — %s', ref_disp_lbl), 'Color',[0.9 0.9 0.9]);
            ylabel(ax_imu, ref_disp_lbl, 'Color',[0.8 0.8 0.8]);
        else
            text(ax_imu, 0.5, 0.5, 'No MAS reference (MAS not applied).', ...
                 'HorizontalAlignment','center','Color',[0.7 0.7 0.7], ...
                 'Units','normalized','FontSize',10);
        end
        xlabel(ax_imu,'Time (s)','Color',[0.8 0.8 0.8]);

        % MAS metrics text
        sep_m = repmat('─', 1, 65);
        mlines = {};
        mlines{end+1,1} = sep_m;
        if mas_idx == 0
            mlines{end+1,1} = '  No MAS algorithm selected.';
            mlines{end+1,1} = sep_m;
            mas_txt.Value = mlines; return;
        end

        mlines{end+1,1} = sprintf('  MAS ALGORITHM: %s', display_mas_name(mas_idx));
        mlines{end+1,1} = sprintf('  PRE-MAS FILTER: %s', combo_label);
        mlines{end+1,1} = sprintf('  CONDITION:     %s  |  Fs=%.2f Hz  |  %d samples', ...
                           state.condition, Fs, numel(filtered));
        if ~isempty(ref_disp_lbl)
            mlines{end+1,1} = sprintf('  IMU REF:       %s', ref_disp_lbl);
        end
        mlines{end+1,1} = '  REF PREPROC:   IMU refs are causal 0.5-8 Hz motion-band filtered and z-scored.';
        mlines{end+1,1} = '                 ECG entering MAS follows the selected pipeline order.';
        mlines{end+1,1} = sep_m;
        mlines{end+1,1} = '';

        % ── Order-specific labels for what MAS sees ───────────────────
        switch order_tag
            case 'A'
                in_lbl  = 'BPF+Notch output';
                out_lbl = 'After MAS (final)';
            case 'B'
                in_lbl  = 'Raw ECG';
                out_lbl = 'After MAS only (pre-BPF+Notch)';
            case 'C'
                in_lbl  = 'After BPF';
                out_lbl = 'After BPF+MAS (pre-Notch)';
            case 'D'
                in_lbl  = 'Raw ECG';
                out_lbl = 'After MAS only (final)';
            otherwise
                in_lbl  = 'MAS input';
                out_lbl = 'MAS output';
        end

        % ── Band indices ───────────────────────────────────────────────
        ma_band  = f_pw >= 0.5 & f_pw <= 8;
        qrs_band = f_pw >= 8   & f_pw <= 35;

        % ① ISOLATED MAS POWER EFFECT (input vs direct output of MAS only)
        E_in_ma   = sum(P_mas_in(ma_band))   + 1e-30;
        E_out_ma  = sum(P_mas_out(ma_band))  + 1e-30;
        E_in_qrs  = sum(P_mas_in(qrs_band))  + 1e-30;
        E_out_qrs = sum(P_mas_out(qrs_band)) + 1e-30;
        mbpr_db = 10*log10(E_in_ma  / E_out_ma);   % positive = MA reduced
        qrs_db  = 10*log10(E_out_qrs / E_in_qrs);  % near 0 = QRS preserved

        % ② IMU-ECG COHERENCE — MAS input vs MAS direct output
        coh_before = NaN; coh_after = NaN;
        N_coh = min(numel(mas_input), numel(mas_direct_out));
        if ~isempty(ref_display) && numel(ref_display) >= N_coh
            imu_ref = ref_display(1:N_coh);
        elseif ~isempty(state.imu.mag0_ac) && numel(state.imu.mag0_ac) >= N_coh
            imu_ref = state.imu.mag0_ac(1:N_coh);
        else
            imu_ref = [];
        end
        if ~isempty(imu_ref)
            % QRS blanking before coherence: BCG at rest creates γ²≈0.9 at ~1 Hz
            % without blanking, making any adaptive filter look artificially effective.
            qm = rt_causal_qrs_mask(mas_input(1:N_coh), Fs);
            ecg_b_m  = mas_input(1:N_coh);       ecg_b_m  = ecg_b_m(qm);
            ecg_a_m  = mas_direct_out(1:N_coh);  ecg_a_m  = ecg_a_m(qm);
            imu_m    = imu_ref(qm);
            n_coh_v  = sum(qm);
            coh_win  = max(min(512, floor(n_coh_v/4)), 64);
            if n_coh_v >= 2 * coh_win
                [cxy_b, f_coh] = mscohere(ecg_b_m, imu_m, hamming(coh_win), floor(coh_win/2), [], Fs);
                [cxy_a, ~    ] = mscohere(ecg_a_m, imu_m, hamming(coh_win), floor(coh_win/2), [], Fs);
                cb = f_coh >= 0.5 & f_coh <= 8;
                coh_before = mean(cxy_b(cb));
                coh_after  = mean(cxy_a(cb));
            end
        end
        dcoh = coh_after - coh_before;

        % ③ R-PEAK COUNT — MAS input vs MAS direct output
        r_in  = detect_rpeaks(mas_input,      Fs);
        r_out = detect_rpeaks(mas_direct_out, Fs);
        rp_ratio = numel(r_out) / max(numel(r_in), 1);

        % ④ MORPHOLOGY PRD IN LOW-MOTION WINDOWS
        % Compare MAS input vs direct output only during low-IMU windows.
        prd_lm = NaN;
        N_lm = min(numel(mas_input), numel(mas_direct_out));
        if ~isempty(ref_display) && numel(ref_display) >= N_lm
            imu_env = abs(ref_display(1:N_lm));
        elseif ~isempty(state.imu.mag0_ac) && numel(state.imu.mag0_ac) >= N_lm
            imu_env = abs(state.imu.mag0_ac(1:N_lm));
        else
            imu_env = [];
        end
        if ~isempty(imu_env)
            lm_mask = imu_env < median(imu_env);
            sig_lm  = mas_input(1:N_lm);
            out_lm  = mas_direct_out(1:N_lm);
            if sum(lm_mask) > 50
                err_lm = sig_lm(lm_mask) - out_lm(lm_mask);
                prd_lm = 100 * sqrt(sum(err_lm.^2) / (sum(sig_lm(lm_mask).^2) + 1e-12));
            end
        end

        event_corr = NaN; event_lag_ms = NaN; event_overlap = NaN;
        event_motion_pct = NaN; event_distort_pct = NaN;
        if ~isempty(imu_ref)
            N_evt = min(numel(mas_input), numel(imu_ref));
            if N_evt > max(32, round(2*Fs))
                [event_corr, event_lag_ms, event_overlap, ...
                 event_motion_pct, event_distort_pct] = mas_event_alignment_metrics( ...
                    mas_input(1:N_evt), imu_ref(1:N_evt), Fs);
            end
        end

        % ── Format output ─────────────────────────────────────────────
        mlines{end+1,1} = sprintf('  COMPARING:  %s  →  %s', in_lbl, out_lbl);
        mlines{end+1,1} = sprintf('  (All metrics isolate the MAS step only, not BPF/Notch effects)');
        mlines{end+1,1} = sep_m;
        mlines{end+1,1} = '';

        mlines{end+1,1} = '  ① MOTION-BAND POWER  (0.5–8 Hz | 8–35 Hz QRS)';
        mlines{end+1,1} = repmat('·',1,65);
        mlines{end+1,1} = sprintf('  MA band  (%s → %s)', in_lbl, out_lbl);
        mlines{end+1,1} = sprintf('  Reduction: %+.2f dB   %s', mbpr_db, ...
                           ternary_str(mbpr_db > 2,  '✓ effective suppression', ...
                           ternary_str(mbpr_db > 0,  '○ mild reduction', '✗ MA content increased')));
        mlines{end+1,1} = sprintf('  QRS band change  : %+.2f dB   %s', qrs_db, ...
                           ternary_str(abs(qrs_db) < 1, '✓ QRS preserved', ...
                           ternary_str(qrs_db > -3,     '○ minor loss', '✗ QRS attenuated')));
        mlines{end+1,1} = '';

        mlines{end+1,1} = '  ② IMU–ECG COHERENCE  (0.5–8 Hz, γ², QRS-blanked)';
        mlines{end+1,1} = repmat('·',1,65);
        if isnan(coh_before)
            mlines{end+1,1} = '  (IMU data unavailable)';
        else
            mlines{end+1,1} = sprintf('  γ² into MAS  (%s): %.3f', in_lbl,  coh_before);
            mlines{end+1,1} = sprintf('  γ² out of MAS (%s): %.3f   %s', out_lbl, coh_after, ...
                               ternary_str(dcoh < -0.05, '✓ coupling broken', ...
                               ternary_str(dcoh <  0.01, '○ marginal',        '✗ unchanged')));
            mlines{end+1,1} = sprintf('  Δγ²: %+.3f', dcoh);
        end
        mlines{end+1,1} = '';

        mlines{end+1,1} = '  ③ R-PEAK DETECTABILITY';
        mlines{end+1,1} = repmat('·',1,65);
        mlines{end+1,1} = sprintf('  Peaks in  (%s): %d', in_lbl,  numel(r_in));
        mlines{end+1,1} = sprintf('  Peaks out (%s): %d   %s', out_lbl, numel(r_out), ...
                           ternary_str(rp_ratio >= 0.95, '✓ QRS intact', ...
                           ternary_str(rp_ratio >= 0.80, '○ minor loss', '✗ peaks disrupted')));
        mlines{end+1,1} = sprintf('  Ratio: %.2f', rp_ratio);
        mlines{end+1,1} = '';

        mlines{end+1,1} = '  ④ MORPHOLOGY IN LOW-MOTION WINDOWS';
        mlines{end+1,1} = repmat('·',1,65);
        if isnan(prd_lm)
            mlines{end+1,1} = '  (IMU unavailable — cannot isolate low-motion windows)';
        else
            mlines{end+1,1} = sprintf('  PRD: MAS input vs output when IMU |a| < median.');
            mlines{end+1,1} = '  High PRD here = MAS distorting ECG when motion is absent.';
            mlines{end+1,1} = sprintf('  PRD low-motion: %.3f %%   %s', prd_lm, ...
                               ternary_str(prd_lm < 3,  '✓ clean signal preserved', ...
                               ternary_str(prd_lm < 10, '○ moderate distortion',    '✗ over-adaptation')));
        end
        mlines{end+1,1} = '';

        mlines{end+1,1} = '  5) MOTION/DISTORTION BURST ALIGNMENT';
        mlines{end+1,1} = repmat('.',1,65);
        if isnan(event_corr)
            mlines{end+1,1} = '  (selected IMU reference unavailable or recording too short)';
        else
            mlines{end+1,1} = sprintf('  Envelope corr |IMU| vs |ECG motion-band|: %.3f', event_corr);
            mlines{end+1,1} = sprintf('  Best causal IMU lag: +%.0f ms', event_lag_ms);
            mlines{end+1,1} = sprintf('  Burst overlap: %.1f %% of ECG-distortion bursts overlap IMU bursts', 100*event_overlap);
            mlines{end+1,1} = sprintf('  Burst thresholds: IMU top %.1f %% | ECG top %.1f %%', ...
                               event_motion_pct, event_distort_pct);
            mlines{end+1,1} = '  This can be strong even when band-averaged gamma^2 is modest.';
        end
        mlines{end+1,1} = '';

        mlines{end+1,1} = '  6) ALGORITHM NOTES';
        mlines{end+1,1} = repmat('.',1,65);
        mlines{end+1,1} = get_mas_notes(mas_idx);
        mlines{end+1,1} = sep_m;
        mas_txt.Value = mlines;
    end

    function [best_corr, best_lag_ms, overlap, motion_pct, distort_pct] = mas_event_alignment_metrics(ecg_sig, imu_sig, Fs)
        ecg_sig = ecg_sig(:);
        imu_sig = imu_sig(:);
        N_evt = min(numel(ecg_sig), numel(imu_sig));
        ecg_sig = ecg_sig(1:N_evt);
        imu_sig = imu_sig(1:N_evt);

        hi = min(8.0, 0.45*Fs);
        if hi <= 0.5
            best_corr = NaN; best_lag_ms = NaN; overlap = NaN;
            motion_pct = NaN; distort_pct = NaN;
            return;
        end

        [bb, ba] = butter(2, [0.5 hi]/(Fs/2), 'bandpass');
        ecg_mb = filter(bb, ba, ecg_sig - mean(ecg_sig));
        imu_mb = filter(bb, ba, imu_sig - mean(imu_sig));

        env_len = max(4, round(0.250 * Fs));
        ecg_env = filter(ones(env_len,1)/env_len, 1, abs(ecg_mb));
        imu_env = filter(ones(env_len,1)/env_len, 1, abs(imu_mb));

        max_lag = max(1, round(0.500 * Fs));
        best_corr = -Inf;
        best_lag = 0;
        for lag = 0:max_lag
            idx = (lag+1):N_evt;
            if numel(idx) < 32
                continue;
            end
            r = rt_abs_corr(ecg_env(idx), imu_env(idx-lag));
            if r > best_corr
                best_corr = r;
                best_lag = lag;
            end
        end

        if ~isfinite(best_corr)
            best_corr = NaN; best_lag_ms = NaN; overlap = NaN;
            motion_pct = NaN; distort_pct = NaN;
            return;
        end

        imu_shift = rt_causal_delay(imu_env, best_lag);
        warmup = max(env_len, best_lag + 1);
        valid = false(N_evt, 1);
        valid(warmup:end) = true;
        if nnz(valid) < 32
            valid(:) = true;
        end

        motion_thr = prctile(imu_shift(valid), 85);
        distort_thr = prctile(ecg_env(valid), 85);
        motion_mask = imu_shift >= motion_thr & valid;
        distort_mask = ecg_env >= distort_thr & valid;
        overlap = nnz(motion_mask & distort_mask) / max(nnz(distort_mask), 1);
        motion_pct = 100 * nnz(motion_mask) / max(nnz(valid), 1);
        distort_pct = 100 * nnz(distort_mask) / max(nnz(valid), 1);
        best_lag_ms = 1000 * best_lag / Fs;
    end

    function notes = get_mas_notes(mas_idx)
        switch mas_idx
            case 1,  notes = '  M1  NLMS |a| IMU0 — baseline. μ=0.01 (Thakor & Zhu 1991).';
            case 2,  notes = '  M2  NLMS |a| 2-site (LA+RA) — spatial diversity vs M1. Same μ.';
            case 3,  notes = '  M2  NLMS baseline |a| 3-site - normalized LMS; divides the update by reference power so IMU amplitude changes do not dominate adaptation.';
            case 4,  notes = '  M4  RLS |a| IMU0 — λ=0.999 (Sayed 2003 §11.2). Faster convergence than M1.';
            case 5,  notes = '  M5  RLS |a| 2-site (LA+RA) — spatial diversity for RLS.';
            case 6,  notes = '  M3  RLS baseline |a| 3-site - recursively minimizes exponentially weighted least-squares error; faster convergence, heavier compute.';
            case 7,  notes = '  M7  NLMS 3-axis IMU0 — 3 coefficients vs 1; tests reference dimensionality.';
            case 8,  notes = '  M8  NLMS 3-axis 2-site — [ax,ay,az] from LA+RA (6 ref signals).';
            case 9,  notes = '  M9  NLMS 3-axis 3-site — [ax,ay,az] from LA+RA+LL (9 ref signals).';
            case 10, notes = '  M10 VS-NLMS |a| IMU0 — mean-removed |a|, alpha=0.995, beta=0.005, mu_max=0.02.';
            case 11, notes = '  M11 VS-NLMS |a| 2-site (LA+RA).';
            case 12, notes = '  M12 VS-NLMS |a| 3-site (LA+RA+LL).';
            case 13, notes = '  M13 NLMS |g| IMU0 — gyro vs accel as MA proxy (Beach 2021).';
            case 14, notes = '  M14 NLMS |g| 2-site (LA+RA).';
            case 15, notes = '  M15 NLMS |g| 3-site (LA+RA+LL).';
            case 16, notes = '  M16 NLMS 6-axis IMU0 — accel+gyro; upper bound for single-site (Ma et al. 2024 RSI).';
            case 17, notes = '  M17 NLMS 6-axis 2-site (LA+RA) — 12 ref signals.';
            case 18, notes = '  M18 NLMS 6-axis 3-site (LA+RA+LL) — 18 ref signals.';
            case 19, notes = '  M19 Blanked Leaky NLMS |a| IMU0 — weight decay γ=0.02 + QRS gate ±120 ms.';
            case 20, notes = '  M20 Blanked Leaky NLMS |a| 2-site (LA+RA).';
            case 21, notes = '  M21 Blanked Leaky NLMS |a| 3-site (LA+RA+LL).';
            case 22, notes = '  M22 Selective 2.9 Hz gz1 — empirical result from phase3_diagnose_advanced: narrowband held-out reduction where broadband MAS failed.';
            case 23, notes = '  M23 RT best feature+lag NLMS — 10 s calibration selects accel/gyro/velocity/jerk/angular-accel/differential refs with causal lag, then runs blanked leaky NLMS.';
            case 24, notes = '  M4  RT coherent-band NLMS - selects only IMU feature/lag/band candidates with strong ECG-IMU coherence, then subtracts those narrowband artefact estimates.';
            case 25, notes = '  M25 RT staged LA/RA NLMS - two-stage active-electrode correction using IMU1=LA then IMU2=RA feature+lag refs.';
            case 26, notes = '  M5  RT differential coherent-band - same coherent-band NLMS idea as M4, but uses IMU1-IMU2 differential references to match active-electrode ADS1293 ECG motion.';
            case 27, notes = '  M27 Aggressive all-IMU NLMS — all IMU sites/features, lower selection threshold, up to 8 refs, 500 ms lag, μ=0.08, 32 taps. Higher distortion risk.';
            case 28, notes = '  M28 Aggressive all-IMU bands — all features, lower gamma^2 threshold, up to 6 bands, wider 1 Hz bands, subtract gain 1.25. Diagnostic only if morphology degrades.';
            case 29, notes = '  M29 AD8233 OUT-matched all-IMU — filters IMU features through causal 7.2 Hz high-pass + 25 Hz low-pass shaping before selection, matching the AD8233CB-EBZ OUT path more closely.';
            case 30, notes = '  M30 Adaptive event-band all-IMU — rolling 8 s past-window selection re-estimates feature/lag/band every 5 s, then uses event-gated NLMS coefficients sample-by-sample.';
            case 31, notes = '  M6  Validated adaptive event-band - rolling train/validation MAS; subtracts only when coherence, envelope correlation, burst overlap, and held-out reduction pass.';
            case 32, notes = '  M1  LMS baseline |a| 3-site - classic stochastic-gradient adaptive noise canceller; simple and literature-backed, but more sensitive to IMU amplitude than NLMS.';
            otherwise, notes = '';
        end
    end

    function r = detect_rpeaks(sig, fs)
        thr    = 0.5 * max(sig);
        min_rr = round(0.4 * fs);
        r = [];
        ii = 1;
        while ii <= numel(sig)
            if sig(ii) > thr
                [~,lp] = max(sig(ii : min(ii + round(0.05*fs), numel(sig))));
                pk = ii + lp - 1;
                if isempty(r) || (pk - r(end)) > min_rr
                    r(end+1) = pk; %#ok<AGROW>
                end
                ii = pk + min_rr;
            else
                ii = ii + 1;
            end
        end
    end

%% ═══════════════════════════════════════════════════════════════════════
%% SCROLL UPDATE CALLBACKS
%% ═══════════════════════════════════════════════════════════════════════

    function ecg_clean = despike_ecg(ecg, Fs)
        ecg = double(ecg(:));
        if numel(ecg) < 8 || ~isfinite(Fs) || Fs <= 0
            ecg_clean = ecg;
            return;
        end
        win = odd_window(0.25, Fs, numel(ecg));
        baseline = movmedian(ecg, win, 'Endpoints','shrink');
        residual = ecg - baseline;
        med_res = median(residual, 'omitnan');
        mad_val = median(abs(residual - med_res), 'omitnan');
        if ~isfinite(mad_val) || mad_val < 1e-12
            ecg_clean = ecg;
            return;
        end
        bad = abs(residual - med_res) > max(8 * mad_val, 1.5);
        ecg_clean = ecg;
        if any(bad)
            ii = (1:numel(ecg))';
            good = ~bad & isfinite(ecg);
            if nnz(good) >= 2
                ecg_clean(bad) = interp1(ii(good), ecg(good), ii(bad), 'linear', 'extrap');
            end
        end
    end

    function y = apply_display_baseline(ecg, Fs)
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
        qrs_win = odd_window(0.20, Fs, numel(ecg));
        tw_win = odd_window(0.80, Fs, numel(ecg));
        baseline = movmedian(ecg, qrs_win, 'Endpoints','shrink');
        baseline = movmedian(baseline, tw_win, 'Endpoints','shrink');
        y = ecg - baseline;
    end

    function w = odd_window(seconds, Fs, N)
        w = max(3, round(seconds * Fs));
        w = min(w, max(3, N));
        if mod(w,2) == 0
            w = max(3, w - 1);
        end
    end

    function ecg_disp = get_display_ecg()
        if bl_cb.Value && ~isempty(state.raw_bl)
            ecg_disp = state.raw_bl;
        else
            ecg_disp = state.raw;
        end
    end

    function y = display_trace(x)
        x = x(:);
        if bl_cb.Value
            y = apply_display_baseline(x, state.fs);
        else
            y = x;
        end
    end

    function note = display_note()
        note = ternary_str(bl_cb.Value, ' [display baseline corrected]', '');
    end

    function label = display_mas_name(mas_idx)
        ui_idx = find(MAS_LIST_IMPL == mas_idx, 1);
        if isempty(ui_idx)
            if mas_idx + 1 <= numel(MAS_NAMES)
                label = MAS_NAMES{mas_idx+1};
            else
                label = sprintf('MAS %d', mas_idx);
            end
        else
            label = MAS_LIST_NAMES{ui_idx};
        end
    end

    function render_time_stages(stage_sigs, stage_lbls)
        if nargin < 1 || isempty(stage_sigs), stage_sigs = {}; end
        if nargin < 2 || isempty(stage_lbls), stage_lbls = {}; end
        colors = {[0.55 0.55 0.60], [0.30 0.75 0.95], [0.80 0.65 0.25], [0.35 0.90 0.50]};
        for ss = 1:4
            cla(ax_time(ss));
            if ss <= numel(stage_sigs) && ~isempty(stage_sigs{ss})
                plot(ax_time(ss), state.t_s, display_trace(stage_sigs{ss}), ...
                     'Color', colors{ss}, 'LineWidth', ternary_num(ss == 1, 0.65, 0.95));
                lbl = stage_lbls{min(ss, numel(stage_lbls))};
                title(ax_time(ss), sprintf('Row %d - %s%s', ss, lbl, display_note()), ...
                      'Color',[0.9 0.9 0.9]);
            else
                text(ax_time(ss), 0.5, 0.5, sprintf('Row %d - blank', ss), ...
                     'Units','normalized','HorizontalAlignment','center', ...
                     'Color',[0.45 0.45 0.48],'FontSize',10);
                title(ax_time(ss), sprintf('Row %d - blank', ss), 'Color',[0.65 0.65 0.68]);
            end
            ylabel(ax_time(ss),'mV','Color',[0.8 0.8 0.8]);
            if ss == 4
                xlabel(ax_time(ss),'Time (s)','Color',[0.8 0.8 0.8]);
            end
        end
        update_time_view();
    end

    function render_mas_before_after(mas_input_sig, filtered_sig, mas_output_sig, mas_idx, combo_label)
        cla(ax_mas_time(1)); cla(ax_mas_time(2));
        if mas_idx > 0
            before_sig = mas_input_sig;
            before_lbl = 'MAS input';
            after_sig = mas_output_sig;
            after_lbl = display_mas_name(mas_idx);
        else
            before_sig = state.raw;
            before_lbl = 'Raw ECG';
            after_sig = filtered_sig;
            after_lbl = ternary_str(strcmp(combo_label,'No BPF/notch'), 'No MAS selected', 'BPF+Notch baseline');
        end
        plot(ax_mas_time(1), state.t_s, display_trace(before_sig), ...
             'Color',[0.85 0.62 0.25],'LineWidth',0.85);
        title(ax_mas_time(1), sprintf('Before MAS - %s%s', before_lbl, display_note()), ...
              'Color',[0.9 0.9 0.9]);
        plot(ax_mas_time(2), state.t_s, display_trace(after_sig), ...
             'Color',[0.35 0.90 0.50],'LineWidth',0.95);
        title(ax_mas_time(2), sprintf('After MAS - %s%s', after_lbl, display_note()), ...
              'Color',[0.9 0.9 0.9]);
        for aa = 1:2
            ylabel(ax_mas_time(aa),'mV','Color',[0.8 0.8 0.8]);
            xlabel(ax_mas_time(aa),'Time (s)','Color',[0.8 0.8 0.8]);
        end
        mas_time_slider.Limits = [0 max(state.t_s(end), 0.01)];
        mas_time_slider.Value = 0;
        update_mas_time_view();
    end

    function redraw_time_display()
        if ~state.loaded, return; end
        if state.last.evaluated
            render_time_stages(state.last.stage_sigs, state.last.stage_lbls);
            render_mas_before_after(state.last.mas_input, state.last.filtered, state.last.mas_direct_out, ...
                                    state.last.mas_idx, state.last.combo_label);
            return;
            cla(ax_time); hold(ax_time,'on');
            plot(ax_time, state.t_s, display_trace(state.last.sig_in), ...
                 'Color',[0.45 0.45 0.5],'LineWidth',0.5,'DisplayName','Raw ECG');
            plot(ax_time, state.t_s, display_trace(state.last.filtered), ...
                 'Color',[0.3 0.75 0.95],'LineWidth',0.9, ...
                 'DisplayName',['BPF+Notch: ' state.last.combo_label]);
            if state.last.mas_idx > 0
                plot(ax_time, state.t_s, display_trace(state.last.after_mas), ...
                     'Color',[0.35 0.9 0.5],'LineWidth',1.1, ...
                 'DisplayName',['+ ' display_mas_name(state.last.mas_idx)]);
            end
            hold(ax_time,'off');
            title(ax_time, sprintf('Time Domain%s - %s  |  %s', ...
                  display_note(), state.condition, state.last.combo_label), ...
                  'Color',[0.9 0.9 0.9]);
            legend(ax_time,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
                   'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
            update_time_view();

            cla(ax_mas_time); hold(ax_mas_time,'on');
            plot(ax_mas_time, state.t_s, display_trace(state.last.sig_in), ...
                 'Color',[0.45 0.45 0.5],'LineWidth',0.5,'DisplayName','Raw ECG');
            plot(ax_mas_time, state.t_s, display_trace(state.last.filtered), ...
                 'Color',[0.3 0.75 0.95],'LineWidth',0.9,'DisplayName','BPF+Notch baseline');
            if state.last.mas_idx > 0 && ~isequal(state.last.after_mas, state.last.filtered)
                plot(ax_mas_time, state.t_s, display_trace(state.last.after_mas), ...
                     'Color',[0.35 0.9 0.5],'LineWidth',1.2, ...
                     'DisplayName',display_mas_name(state.last.mas_idx));
            end
            hold(ax_mas_time,'off');
            title(ax_mas_time, sprintf('MAS Output%s - %s  |  %s', ...
                  display_note(), state.condition, state.last.combo_label), ...
                  'Color',[0.9 0.9 0.9]);
            legend(ax_mas_time,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
                   'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
            update_mas_time_view();
        else
            render_time_stages({get_display_ecg()}, {'Raw ECG'});
            return;
            cla(ax_time);
            plot(ax_time, state.t_s, get_display_ecg(), ...
                 'Color',[0.4 0.6 0.9],'LineWidth',0.6);
            title(ax_time, sprintf('Raw ECG%s - %s  (Fs=%.1f Hz)', ...
                  display_note(), state.condition, state.fs), ...
                  'Color',[0.9 0.9 0.9]);
            update_time_view();
        end
    end

    function fit_ylim_to_window(ax)
        if isempty(ax.Children), return; end
        xl = ax.XLim;
        y_all = [];
        for kk = 1:numel(ax.Children)
            h = ax.Children(kk);
            if isprop(h,'XData') && isprop(h,'YData')
                x = h.XData(:);
                y = h.YData(:);
                keep = x >= xl(1) & x <= xl(2) & isfinite(y);
                y_all = [y_all; y(keep)]; %#ok<AGROW>
            end
        end
        if isempty(y_all), return; end
        y_all = sort(y_all);
        lo = y_all(max(1, round(0.01 * numel(y_all))));
        hi = y_all(min(numel(y_all), max(1, round(0.99 * numel(y_all)))));
        pad = max(0.05, 0.15 * max(hi - lo, eps));
        ylim(ax, [lo - pad, hi + pad]);
    end

    function update_time_view()
        if ~state.last.evaluated && ~state.loaded, return; end
        t_max = state.t_s(end);
        [win_w, use_all] = parse_window(win_dd.Value, t_max);
        if use_all
            for aa = 1:numel(ax_time), xlim(ax_time(aa), [0, t_max]); end
            time_slider.Value = 0;
        else
            t_start = max(0, min(time_slider.Value, t_max - win_w));
            for aa = 1:numel(ax_time), xlim(ax_time(aa), [t_start, t_start + win_w]); end
        end
        for aa = 1:numel(ax_time), fit_ylim_to_window(ax_time(aa)); end
    end

    function update_mas_time_view()
        if ~state.last.evaluated, return; end
        t_max = state.t_s(end);
        [win_w, use_all] = parse_window(mas_win_dd.Value, t_max);
        if use_all
            for aa = 1:numel(ax_mas_time), xlim(ax_mas_time(aa), [0, t_max]); end
            mas_time_slider.Value = 0;
        else
            t_start = max(0, min(mas_time_slider.Value, t_max - win_w));
            for aa = 1:numel(ax_mas_time), xlim(ax_mas_time(aa), [t_start, t_start + win_w]); end
        end
        for aa = 1:numel(ax_mas_time), fit_ylim_to_window(ax_mas_time(aa)); end
    end

    function [win_w, use_all] = parse_window(dd_val, t_max)
        use_all = strcmp(dd_val, 'All');
        if use_all
            win_w = t_max;
        else
            win_w = str2double(extractBefore(dd_val, ' s'));
            if isnan(win_w) || win_w <= 0, win_w = 30; use_all = false; end
        end
    end

%% ═══════════════════════════════════════════════════════════════════════
%% FREQUENCY RESPONSE HELPERS (from phase2)
%% ═══════════════════════════════════════════════════════════════════════

    function H = adaptive_freq_response(notch_type, Fs_design, Nfft)
        if strcmp(notch_type,'N6')
            H = ones(Nfft/2+1,1);
            return;
        end
        n_samp = 20000; rng(42);
        x_in  = randn(n_samp,1);
        y_out = apply_notch(x_in, notch_type, Fs_design);
        x_ss  = x_in(10001:end);  y_ss = y_out(10001:end);
        X     = fft(x_ss, Nfft);  Y    = fft(y_ss, Nfft);
        H     = Y(1:Nfft/2+1) ./ (X(1:Nfft/2+1) + 1e-15);
    end

    function H = sos_freq_response(sos_ml, Nfft)
        omega = 2*pi*(0:Nfft/2)'/Nfft;
        z1 = exp(-1j*omega);
        z2 = exp(-2j*omega);
        H = ones(numel(omega), 1);
        for st = 1:size(sos_ml, 1)
            b0 = sos_ml(st,1); b1 = sos_ml(st,2); b2 = sos_ml(st,3);
            a1 = sos_ml(st,5); a2 = sos_ml(st,6);
            H = H .* ((b0 + b1*z1 + b2*z2) ./ (1 + a1*z1 + a2*z2));
        end
        H(~isfinite(H)) = 0;
    end

    function [P, f] = safe_pwelch(x, Fs, Nfft)
        x = double(x(:));
        f = (0:Nfft/2)' * Fs / Nfft;
        if isempty(x)
            P = realmin * ones(numel(f), 1);
            return;
        end
        good = isfinite(x);
        if nnz(good) >= 2 && any(~good)
            xi = (1:numel(x))';
            x(~good) = interp1(xi(good), x(good), xi(~good), 'linear', 'extrap');
        elseif nnz(good) < 2
            x(~good) = 0;
        end
        x = x - mean(x, 'omitnan');
        if numel(x) < 4
            X = fft(x, Nfft);
            P = abs(X(1:Nfft/2+1)).^2 / max(Fs*numel(x), 1);
        else
            if numel(x) >= 256
                win_len = min(1024, max(64, floor(numel(x)/4)));
            else
                win_len = max(4, min(numel(x), 2^floor(log2(numel(x)))));
            end
            win_len = min(win_len, numel(x));
            pw_win = hamming(win_len);
            pw_nov = min(floor(win_len/2), win_len-1);
            [P, f] = pwelch(x, pw_win, pw_nov, Nfft, Fs);
        end
        P = double(P(:));
        P(~isfinite(P) | P <= 0) = realmin;
    end

    function idx = get_selected_idx(btn_grp, btn_array)
        selected = btn_grp.SelectedObject;
        idx = 1;
        for k = 1:numel(btn_array)
            if btn_array(k) == selected, idx = k; return; end
        end
    end

    function freqs = auto_detect_interference(x, Fs, lo, hi, thresh_db, max_f, Nfft)
        N_sig = numel(x);
        if N_sig < Nfft, Nfft = 2^nextpow2(N_sig); end
        Nfft  = 2*floor(Nfft/2);
        if Nfft < 4, freqs = []; return; end
        hop = Nfft/2; win_h = hann(Nfft);
        n_seg = max(1, floor((N_sig-Nfft)/hop)+1);
        P_sum = zeros(Nfft/2+1,1);
        for k = 1:n_seg
            i1 = (k-1)*hop+1; i2 = i1+Nfft-1;
            if i2 > N_sig, break; end
            X_k   = fft(double(x(i1:i2)).*win_h, Nfft);
            P_sum = P_sum + abs(X_k(1:Nfft/2+1)).^2;
        end
        P_avg  = P_sum / max(n_seg,1);
        f_axis = (0:Nfft/2)' * Fs / Nfft;
        win_bins = max(3, min(round(5*Nfft/Fs), round(numel(P_avg)/5)));
        win_bins = 2*floor(win_bins/2)+1;
        floor_lin = movmedian(P_avg, win_bins);
        prom_db   = 10*log10((P_avg+1e-30)./(floor_lin+1e-30));
        mask = f_axis >= lo & f_axis <= hi;
        if sum(mask) < 3, freqs = []; return; end
        above_floor = prom_db(mask); f_zone = f_axis(mask);
        if numel(above_floor) < 3, freqs = []; return; end
        min_sep = floor(max(1, 2*Nfft/Fs));
        if numel(above_floor) > 2*min_sep
            [pks,locs] = findpeaks(above_floor,'MinPeakHeight',thresh_db,'MinPeakDistance',min_sep);
        else
            [pks,locs] = findpeaks(above_floor,'MinPeakHeight',thresh_db);
        end
        if isempty(locs), freqs = []; return; end
        [~,si] = sort(pks,'descend'); top_locs = locs(si(1:min(max_f,numel(si))));
        bin_hz = Fs/Nfft; freqs = zeros(1,numel(top_locs));
        for qi = 1:numel(top_locs)
            k = top_locs(qi);
            if k > 1 && k < numel(above_floor)
                a = above_floor(k-1); b = above_floor(k); c = above_floor(k+1);
                denom = a-2*b+c;
                delta = 0;
                if abs(denom) > 1e-10, delta = max(-0.5,min(0.5,0.5*(a-c)/denom)); end
                freqs(qi) = f_zone(k) + delta*bin_hz;
            else
                freqs(qi) = f_zone(k);
            end
        end
        freqs = sort(freqs);
    end

    function freqs = generate_random_injection_freqs(Fs, n_tones)
        lo_hz = 2.0; hi_hz = max(lo_hz+1.0, Fs/2-5.0);
        n_tones = max(1, round(n_tones));
        if hi_hz <= lo_hz+0.5, freqs = linspace(lo_hz,hi_hz,n_tones); return; end
        min_sep = max(2.5, min(8.0,(hi_hz-lo_hz)/(n_tones+1)));
        freqs = zeros(1,n_tones); k = 0; tries = 0;
        while k < n_tones && tries < 5000
            tries = tries+1; f_try = lo_hz+(hi_hz-lo_hz)*rand();
            if k == 0 || all(abs(freqs(1:k)-f_try) >= min_sep), k=k+1; freqs(k)=f_try; end
        end
        if k < n_tones
            fb = linspace(lo_hz+min_sep,hi_hz-min_sep,n_tones);
            freqs(k+1:end) = fb(1:(n_tones-k));
        end
        freqs = sort(freqs(1:n_tones));
    end

    function freqs = generate_n9_injection_freqs(Fs, n_tones)
        % N6 targets PLI in Zone 3 (45 Hz – Nyquist). Always include 50 Hz;
        % additional tones fill Zone 3 only — never the ECG band. Injecting
        % ECG-band tones triggered Zone 2 detection and corrupted the ECG.
        n_tones = max(1, round(n_tones));
        lo_z3   = 50.0;
        hi_z3   = max(lo_z3 + 1, Fs/2 - 5);
        if lo_z3 >= Fs/2
            freqs = 45.0 * ones(1, n_tones);
            return;
        end
        freqs = 50.0;
        if n_tones > 1 && hi_z3 > 52.0
            extra = generate_random_injection_freqs_range(52.0, hi_z3, n_tones - 1);
            freqs = sort([freqs, extra]);
        end
        freqs = freqs(1:min(n_tones, numel(freqs)));
    end

    function freqs = generate_random_injection_freqs_range(lo_hz, hi_hz, n_tones)
        n_tones = max(1,round(n_tones));
        if hi_hz <= lo_hz+0.5, freqs = linspace(lo_hz,hi_hz,n_tones); return; end
        min_sep = max(2.5, min(8.0,(hi_hz-lo_hz)/(n_tones+1)));
        freqs = zeros(1,n_tones); k = 0; tries = 0;
        while k < n_tones && tries < 5000
            tries = tries+1; f_try = lo_hz+(hi_hz-lo_hz)*rand();
            if k == 0 || all(abs(freqs(1:k)-f_try) >= min_sep), k=k+1; freqs(k)=f_try; end
        end
        if k < n_tones
            fb = linspace(lo_hz+min_sep,hi_hz-min_sep,n_tones);
            freqs(k+1:end) = fb(1:(n_tones-k));
        end
        freqs = sort(freqs(1:n_tones));
    end

end  % end main function

%% ═══════════════════════════════════════════════════════════════════════
%% MAS ALGORITHM IMPLEMENTATIONS
%% ═══════════════════════════════════════════════════════════════════════

function y = mas_lms(d, x_ref, mu, filter_order)
% LMS adaptive noise canceller with tapped delay line.
% Literature baseline: lowest-cost stochastic-gradient update.
    if nargin < 4, filter_order = 16; end
    d = double(d(:));
    if isvector(x_ref), x_ref = x_ref(:); end
    x_ref = double(x_ref);
    N = numel(d);
    L = size(x_ref, 2);
    M = filter_order;
    w = zeros(L*M, 1);
    buf = zeros(L, M);
    y = zeros(N, 1);
    for n = 1:N
        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        x = buf(:);
        e = d(n) - w' * x;
        w = w + mu * e * x;
        y(n) = e;
    end
end

function y = mas_nlms(d, x_ref, mu, eps_reg, filter_order)
% NLMS adaptive noise canceller with tapped delay line.
% d:            Nx1 primary input (ECG after BPF+notch)
% x_ref:        NxL reference signal (IMU; L channels)
% filter_order: FIR tap depth per channel (default 16; covers ~32 ms at 500 Hz)
% Output y: Nx1 cleaned ECG (error signal)
% Sayed 2003 §9.2; Thakor & Zhu 1991 for ECG MAS application.
    if nargin < 5, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2);
    M = filter_order;
    w   = zeros(L*M, 1);
    buf = zeros(L, M);
    y   = zeros(N, 1);
    for n = 1:N
        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        x   = buf(:);
        xTx = x' * x + eps_reg;
        e   = d(n) - w' * x;
        w   = w + (mu / xTx) * e * x;
        y(n) = e;
    end
end

function y = mas_rls(d, x_ref, lambda, eps_reg, filter_order)
% RLS adaptive noise canceller with tapped delay line.
% lambda:       forgetting factor (0 < lambda < 1, typically 0.999)
% filter_order: FIR tap depth per channel (default 16)
% Sayed 2003 §11.2.
    if nargin < 5, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2);
    M = filter_order;
    w   = zeros(L*M, 1);
    % P0 = delta*I with delta moderate. Sayed 2003 §11.2 advises delta chosen
    % relative to reference power; 1/eps_reg (=1e8) previously used here gave
    % a huge initial gain causing w to spike on the first few updates before
    % lambda-decay could bring it back. delta=10 is a conservative stable seed.
    P   = 10 * eye(L*M);
    buf = zeros(L, M);
    y   = zeros(N, 1);
    for n = 1:N
        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        x   = buf(:);
        Px  = P * x;
        k   = Px / (lambda + x' * Px);    % Kalman gain
        e   = d(n) - w' * x;
        w   = w + k * e;
        P   = (P - k * x' * P) / lambda;
        y(n) = e;
    end
end

function y = mas_apa(d, x_ref, mu, order, eps_reg)
% APA order-P adaptive noise canceller.
% Ozeki & Umeda 1984. Uses P past reference vectors for faster convergence.
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2);
    P = order;
    w     = zeros(L, 1);
    X_buf = zeros(L, P);   % buffer of P most recent reference vectors
    d_buf = zeros(P, 1);   % buffer of P most recent desired samples
    y     = zeros(N, 1);
    for n = 1:N
        x_n   = x_ref(n, :)';
        X_buf = [x_n, X_buf(:, 1:end-1)];     % shift in newest column
        d_buf = [d(n); d_buf(1:end-1)];
        d_hat = X_buf' * w;
        e_vec = d_buf - d_hat;
        XtX   = X_buf' * X_buf + eps_reg * eye(P);
        w     = w + mu * X_buf * (XtX \ e_vec);
        y(n)  = d(n) - w' * x_n;
    end
end

function y = mas_vs_nlms(d, x_ref, alpha, beta, mu_max, eps_reg, filter_order)
% VS-NLMS adaptive noise canceller with tapped delay line.
% Step size adapts based on squared error power estimate.
% Kwong & Johnston 1992.
%   alpha:        forgetting factor for error power (0.9-0.999)
%   beta:         proportionality constant (step-size scaling)
%   mu_max:       maximum allowed step size
%   filter_order: FIR tap depth per channel (default 16)
    if nargin < 7, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2);
    M = filter_order;
    w       = zeros(L*M, 1);
    buf     = zeros(L, M);
    sigma_e = var(d(1:min(100,N)));   % seed error power estimate
    if sigma_e < eps_reg, sigma_e = 1.0; end
    y = zeros(N, 1);
    for n = 1:N
        buf  = [x_ref(n,:)', buf(:, 1:end-1)];
        x    = buf(:);
        xTx  = x' * x + eps_reg;
        e    = d(n) - w' * x;
        sigma_e = alpha * sigma_e + (1 - alpha) * e^2;
        mu   = min(mu_max, beta * sigma_e / xTx);
        w    = w + mu * e * x;
        y(n) = e;
    end
end

function y = mas_leaky_nlms(d, x_ref, mu, gamma_leak, eps_reg, filter_order)
% Leaky NLMS: adds weight decay to prevent random-walk growth under low
% d<->x coherence. Update rule:
%   w[n+1] = (1 - mu*gamma_leak) w[n] + (mu/||x||^2) e[n] x[n]
% gamma_leak ~ 0.02..0.05 is typical; higher = more decay.
% Causal, sample-by-sample.
    if nargin < 6, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2); M = filter_order;
    w = zeros(L*M, 1); buf = zeros(L, M); y = zeros(N, 1);
    decay = 1 - mu * gamma_leak;
    for n = 1:N
        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        xv  = buf(:);
        xTx = xv'*xv + eps_reg;
        e   = d(n) - w'*xv;
        w   = decay*w + (mu/xTx)*e*xv;
        y(n) = e;
    end
end

function y = mas_blanked_leaky_nlms(d, x_ref, mu, gamma_leak, eps_reg, Fs, filter_order)
% Leaky NLMS with causal QRS blanking. A causal energy-envelope detector
% opens a refractory blanking window for blank_ms after each detected
% R-peak; weight updates are frozen during blanking. Error is still
% emitted every sample so the output is continuous.
%
% Detector: derivative -> square -> 50 ms moving average -> adaptive
% threshold = 0.3 * running max (decayed). Refractory 250 ms.
    if nargin < 7, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2); M = filter_order;

    blank_len  = round(0.120 * Fs);    % 120 ms blanking after detection
    refrac_len = round(0.250 * Fs);    % 250 ms refractory between detections
    ma_len     = max(1, round(0.050 * Fs));
    decay      = 1 - mu * gamma_leak;

    w = zeros(L*M, 1); buf = zeros(L, M); y = zeros(N, 1);
    env_buf = zeros(ma_len, 1);
    prev_d  = 0;
    env_max = 0;                       % slow-decay running max
    env_max_tau = exp(-1/(2*Fs));      % ~2 s decay
    blank_left = 0; refrac_left = 0;
    prev_env = 0;

    for n = 1:N
        dn = d(n);
        dd = dn - prev_d; prev_d = dn;
        s  = dd*dd;
        env_buf = [s; env_buf(1:end-1)];
        env = mean(env_buf);

        env_max = max(env, env_max_tau * env_max);
        thr = 0.30 * env_max;

        if refrac_left > 0
            refrac_left = refrac_left - 1;
        elseif env > thr && env > prev_env
            blank_left  = blank_len;
            refrac_left = refrac_len;
        end
        prev_env = env;

        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        xv  = buf(:);
        xTx = xv'*xv + eps_reg;
        e   = dn - w'*xv;

        if blank_left > 0
            blank_left = blank_left - 1;
            % Weights frozen during QRS window; output the passthrough error.
        else
            w = decay*w + (mu/xTx)*e*xv;
        end
        y(n) = e;
    end
end

function y = mas_cw_nlms(d, x_ref, mu, gamma_leak, eps_reg, Fs, filter_order)
% Correlation-Weighted Leaky NLMS (Ghaleb et al. 2018, PLoS One
% 13(11):e0207176, PMCID PMC6245678, doi 10.1371/journal.pone.0207176).
% Scales update by an instantaneous Pearson correlation magnitude
% rho(n) = |cov(d,x_scalar)| / (std(d)*std(x_scalar) + eps), estimated
% over a causal ~200 ms sliding window. When coherence is low, rho->0
% and updates stop; when high, updates proceed at full step size.
%
% x_scalar is the first reference column (main IMU channel) — Tong uses
% a single accelerometer magnitude as the correlation probe even when
% the filter itself has multiple input channels.
    if nargin < 7, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2); M = filter_order;

    win_len = max(8, round(0.200 * Fs));    % 200 ms correlation window
    d_win = zeros(win_len, 1);
    x_win = zeros(win_len, 1);
    x_probe = x_ref(:, 1);
    decay = 1 - mu * gamma_leak;

    w = zeros(L*M, 1); buf = zeros(L, M); y = zeros(N, 1);

    for n = 1:N
        d_win = [d(n); d_win(1:end-1)];
        x_win = [x_probe(n); x_win(1:end-1)];

        if n >= win_len
            dm = mean(d_win); xm = mean(x_win);
            dd = d_win - dm;  dx = x_win - xm;
            denom = sqrt(sum(dd.*dd)*sum(dx.*dx)) + eps_reg;
            rho = abs(sum(dd.*dx) / denom);
        else
            rho = 0;
        end

        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        xv  = buf(:);
        xTx = xv'*xv + eps_reg;
        e   = d(n) - w'*xv;
        w   = decay*w + (rho * mu / xTx) * e * xv;
        y(n) = e;
    end
end

function y = mas_subband_nlms(d, x_ref, mu, gamma_leak, eps_reg, Fs, filter_order)
% Subband-matched Leaky NLMS. Both primary and reference are causally
% bandpassed to the motion band (0.5-5 Hz) before the update. The
% adapted MA estimate is then subtracted from the full-band primary.
%
% Rationale: ambulatory motion energy is concentrated <5 Hz. Adapting
% across the full ECG band lets QRS transients drive w; restricting the
% adapter's view to the motion band decouples QRS from adaptation while
% still cancelling the MA component present in the full-band output.
    if nargin < 7, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2); M = filter_order;

    lo = 0.5; hi = min(5, 0.45*Fs);
    if hi <= lo, hi = lo + 0.5; end
    [bb, ba] = butter(2, [lo hi]/(Fs/2), 'bandpass');

    d_mb = filter(bb, ba, d);
    x_mb = zeros(size(x_ref));
    for c = 1:L
        x_mb(:, c) = filter(bb, ba, x_ref(:, c));
    end

    decay = 1 - mu * gamma_leak;
    w = zeros(L*M, 1); buf_mb = zeros(L, M); buf = zeros(L, M);
    y = zeros(N, 1);
    for n = 1:N
        buf_mb = [x_mb(n,:)', buf_mb(:, 1:end-1)];
        buf    = [x_ref(n,:)', buf(:, 1:end-1)];
        xvmb = buf_mb(:); xv = buf(:);
        xTx  = xvmb'*xvmb + eps_reg;
        e_mb = d_mb(n) - w'*xvmb;
        w    = decay*w + (mu/xTx)*e_mb*xvmb;
        y(n) = d(n) - w'*xv;        % subtract in full band
    end
end

function y = mas_selective_band_nlms(d, x_ref, mu, gamma_leak, eps_reg, Fs, f0, bw, filter_order)
% Empirical narrowband MAS for the coherent walking component found by
% phase3_diagnose_advanced. The adaptive update sees only a tight band
% around f0, and only the estimated narrowband artefact is subtracted.
    if nargin < 9, filter_order = 16; end
    if nargin < 8, bw = 0.60; end
    if nargin < 7, f0 = 2.93; end

    N = numel(d);
    d = d(:);
    x_ref = x_ref(:);

    lo = max(0.5, f0 - bw/2);
    hi = min(0.45*Fs, f0 + bw/2);
    if hi <= lo
        y = d;
        return;
    end

    [bb, ba] = butter(2, [lo hi]/(Fs/2), 'bandpass');
    d_sb = filter(bb, ba, d);
    x_sb = filter(bb, ba, x_ref);

    M = filter_order;
    decay = 1 - mu * gamma_leak;
    w = zeros(M, 1);
    buf = zeros(M, 1);
    artefact_hat = zeros(N, 1);

    for n = 1:N
        buf = [x_sb(n); buf(1:end-1)];
        xTx = buf' * buf + eps_reg;
        e = d_sb(n) - w' * buf;
        w = decay*w + (mu/xTx) * e * buf;
        artefact_hat(n) = w' * buf;
    end

    y = d - artefact_hat;
end

function [y, ref_display, ref_lbl] = mas_auto_selective_gated_nlms( ...
    d, ref_bank, ref_names, Fs, peak_thr, max_bands, bw, mu, gamma_leak, eps_reg, filter_order, max_select_hz, subtract_gain)
% Auto selective/gated MAS.
% Screens the current recording for coherent motion-band IMU references,
% then subtracts only those narrowband artefact estimates. This is intended
% for the current dataset where broadband coherence is weak but narrowband
% motion/cable peaks can be high.
    if nargin < 13, subtract_gain = 1.0; end
    if nargin < 12, max_select_hz = 6.0; end
    if nargin < 11, filter_order = 16; end
    if nargin < 10, eps_reg = 1e-8; end
    if nargin < 9,  gamma_leak = 0.02; end
    if nargin < 8,  mu = 0.03; end
    if nargin < 7,  bw = 0.60; end
    if nargin < 6,  max_bands = 3; end
    if nargin < 5,  peak_thr = 0.50; end

    d = d(:);
    y = d;
    ref_display = [];
    ref_lbl = 'M10 bypass: no usable IMU reference';

    if isempty(ref_bank) || numel(d) < 512 || ~isfinite(Fs) || Fs <= 20
        return;
    end

    N = numel(d);
    if size(ref_bank,1) ~= N
        return;
    end

    d0 = d - mean(d);
    nper = min(2048, max(256, 2^floor(log2(max(256, min(floor(N/4), 2048))))));
    nfft = max(1024, 2^nextpow2(2*nper));
    win = hamming(nper);
    nover = floor(nper/2);
    f_hi = min(max_select_hz, 0.45*Fs);
    if f_hi <= 0.5
        ref_lbl = 'M10 bypass: Fs too low for selective band';
        return;
    end

    candidates = [];
    for rr = 1:size(ref_bank,2)
        x = ref_bank(:,rr);
        if any(~isfinite(x)) || std(x) <= 1e-10
            continue;
        end
        x = x - mean(x);
        try
            [cxy, f] = mscohere(d0, x, win, nover, nfft, Fs);
        catch
            continue;
        end

        band_low = f >= 0.5 & f <= f_hi & isfinite(cxy);
        band_all = f >= 0.5 & f <= min(20.0, 0.45*Fs) & isfinite(cxy);
        if ~any(band_low)
            continue;
        end

        c_low = cxy(band_low);
        f_low = f(band_low);
        [pk, ii] = max(c_low);
        if pk >= peak_thr
            mean_g2 = mean(cxy(band_all));
            candidates = [candidates; pk, f_low(ii), rr, mean_g2]; %#ok<AGROW>
        end
    end

    if isempty(candidates)
        ref_lbl = sprintf('M10 bypass: no <=%.1f Hz peak gamma^2 >= %.2f', f_hi, peak_thr);
        return;
    end

    [~, ord] = sort(candidates(:,1), 'descend');
    candidates = candidates(ord,:);

    selected = [];
    for cc = 1:size(candidates,1)
        f0 = candidates(cc,2);
        ref_idx = candidates(cc,3);
        if isempty(selected)
            selected = candidates(cc,:);
        else
            f_sep_ok = all(abs(selected(:,2) - f0) >= 0.50*bw);
            ref_new = all(selected(:,3) ~= ref_idx);
            if f_sep_ok && ref_new
                selected = [selected; candidates(cc,:)]; %#ok<AGROW>
            end
        end
        if size(selected,1) >= max_bands
            break;
        end
    end

    ref_display = ref_bank(:, selected(1,3));
    parts = cell(1, size(selected,1));
    for ss = 1:size(selected,1)
        ref_idx = selected(ss,3);
        f0 = selected(ss,2);
        y = mas_selective_band_gated_once(y, ref_bank(:,ref_idx), mu, gamma_leak, ...
                                          eps_reg, Fs, f0, bw, filter_order, subtract_gain);
        parts{ss} = sprintf('%s %.2fHz g2=%.2f', ref_names{ref_idx}, f0, selected(ss,1));
    end
    ref_lbl = ['M10 auto selective: ' strjoin(parts, '; ')];
end

function y = mas_selective_band_gated_once(d, x_ref, mu, gamma_leak, eps_reg, Fs, f0, bw, filter_order, subtract_gain)
% One narrowband gated leaky-NLMS stage. The adaptive filter estimates only
% the selected band, then subtraction is reduced when reference motion
% energy is near baseline.
    if nargin < 10, subtract_gain = 1.0; end
    if nargin < 9, filter_order = 16; end
    d = d(:);
    x_ref = x_ref(:);
    x_ref = x_ref - mean(x_ref);

    lo = max(0.5, f0 - bw/2);
    hi = min(0.45*Fs, f0 + bw/2);
    if hi <= lo
        y = d;
        return;
    end

    [bb, ba] = butter(2, [lo hi]/(Fs/2), 'bandpass');
    d_sb = filter(bb, ba, d);
    x_sb = filter(bb, ba, x_ref);

    N = numel(d);
    M = filter_order;
    decay = 1 - mu * gamma_leak;
    w = zeros(M, 1);
    buf = zeros(M, 1);
    artefact_hat = zeros(N, 1);

    for nn = 1:N
        buf = [x_sb(nn); buf(1:end-1)];
        xTx = buf' * buf + eps_reg;
        e = d_sb(nn) - w' * buf;
        w = decay*w + (mu/xTx) * e * buf;
        artefact_hat(nn) = w' * buf;
    end

    env_len = max(4, round(0.250 * Fs));
    env = filter(ones(env_len,1)/env_len, 1, abs(x_sb));
    env_med = median(env);
    env_mad = median(abs(env - env_med)) + eps_reg;
    gate = (env - (env_med - 0.2*env_mad)) / (0.8*env_mad);
    gate = min(1, max(0, gate));
    gate(1:min(round(0.05*Fs), numel(gate))) = 0;

    y = d - subtract_gain * gate .* artefact_hat;
end

function [ref_bank, ref_names] = build_rt_reference_bank(imu, Fs, scope)
% Build a streaming-feasible IMU feature bank for reference-quality tests.
% Features are causal transforms only: high-passed accel/gyro axes,
% integrated accel velocity, jerk, angular acceleration, magnitudes, and
% differential active-electrode motion.
    if nargin < 3, scope = 'all'; end

    [b0, n0] = rt_site_features( ...
        [imu.ax0_ac, imu.ay0_ac, imu.az0_ac], ...
        [imu.gx0_ac, imu.gy0_ac, imu.gz0_ac], Fs, '0');
    [b1, n1] = rt_site_features( ...
        [imu.ax1_ac, imu.ay1_ac, imu.az1_ac], ...
        [imu.gx1_ac, imu.gy1_ac, imu.gz1_ac], Fs, '1');
    [b2, n2] = rt_site_features( ...
        [imu.ax2_ac, imu.ay2_ac, imu.az2_ac], ...
        [imu.gx2_ac, imu.gy2_ac, imu.gz2_ac], Fs, '2');

    [bd01, nd01] = rt_diff_features(b0, n0, b1, n1, '01');
    [bd02, nd02] = rt_diff_features(b0, n0, b2, n2, '02');
    [bd12, nd12] = rt_diff_features(b1, n1, b2, n2, '12');

    switch lower(scope)
        case 'site0'
            ref_bank = b0; ref_names = n0;
        case 'site1'
            ref_bank = b1; ref_names = n1;
        case 'site2'
            ref_bank = b2; ref_names = n2;
        case 'diff01'
            ref_bank = bd01; ref_names = nd01;
        case 'diff02'
            ref_bank = bd02; ref_names = nd02;
        case 'diff12'
            ref_bank = bd12; ref_names = nd12;
        otherwise
            ref_bank = [b0, b1, b2, bd01, bd02, bd12];
            ref_names = [n0, n1, n2, nd01, nd02, nd12];
    end

    if isempty(ref_bank)
        ref_names = {};
        return;
    end

    good = all(isfinite(ref_bank), 1) & std(ref_bank, 0, 1) > 1e-10;
    ref_bank = ref_bank(:, good);
    ref_names = ref_names(good);
end

function [bank, names] = rt_site_features(accel_xyz, gyro_xyz, Fs, suffix)
    accel_xyz = double(accel_xyz);
    gyro_xyz  = double(gyro_xyz);
    if isempty(accel_xyz) || size(accel_xyz, 2) ~= 3
        bank = [];
        names = {};
        return;
    end

    dt = 1 / Fs;
    vel_xyz = rt_dc_block(cumtrapz(accel_xyz) * dt, 0.995);
    jerk_xyz = [zeros(1, 3); diff(accel_xyz, 1, 1) * Fs];
    angacc_xyz = [zeros(1, 3); diff(gyro_xyz, 1, 1) * Fs];
    amag = sqrt(sum(accel_xyz.^2, 2));
    gmag = sqrt(sum(gyro_xyz.^2, 2));

    bank = [accel_xyz, gyro_xyz, vel_xyz, jerk_xyz, angacc_xyz, amag, gmag];
    bank = rt_condition_mas_reference(bank, Fs);
    names = { ...
        ['ax' suffix], ['ay' suffix], ['az' suffix], ...
        ['gx' suffix], ['gy' suffix], ['gz' suffix], ...
        ['vx' suffix], ['vy' suffix], ['vz' suffix], ...
        ['jx' suffix], ['jy' suffix], ['jz' suffix], ...
        ['agx' suffix], ['agy' suffix], ['agz' suffix], ...
        ['amag' suffix], ['gmag' suffix]};
end

function [bank, names] = rt_diff_features(bank_a, names_a, bank_b, ~, suffix)
    n_common = min(size(bank_a, 2), size(bank_b, 2));
    if n_common == 0
        bank = [];
        names = {};
        return;
    end

    bank = bank_a(:, 1:n_common) - bank_b(:, 1:n_common);
    names = cell(1, n_common);
    for kk = 1:n_common
        base = regexprep(names_a{kk}, '\d+$', '');
        names{kk} = ['d' base suffix];
    end
end

function [y, ref_display, ref_lbl] = mas_rt_feature_select_nlms( ...
    d, ref_bank, ref_names, Fs, max_refs, cal_sec, max_lag_ms, min_corr, ...
    mu, gamma_leak, eps_reg, filter_order)
% Simulated streaming mode: the first cal_sec seconds are used to choose
% fixed causal feature+lag references. The full signal is then processed
% sample-by-sample by blanked leaky NLMS with those locked references.
    if nargin < 12, filter_order = 16; end
    if nargin < 11, eps_reg = 1e-8; end
    if nargin < 10, gamma_leak = 0.02; end
    if nargin < 9,  mu = 0.03; end
    if nargin < 8,  min_corr = 0.10; end
    if nargin < 7,  max_lag_ms = 300; end
    if nargin < 6,  cal_sec = 10.0; end
    if nargin < 5,  max_refs = 4; end

    d = d(:);
    y = d;
    ref_display = [];
    ref_lbl = 'M23 bypass: no streaming reference selected';
    if isempty(ref_bank) || numel(d) ~= size(ref_bank, 1)
        return;
    end

    selected = rt_select_features_by_corr(d, ref_bank, Fs, max_refs, cal_sec, max_lag_ms, min_corr);
    if isempty(selected)
        ref_lbl = sprintf('M23 bypass: no calibration |r| >= %.2f', min_corr);
        return;
    end

    [x_sel, parts] = rt_materialize_selected_refs(ref_bank, ref_names, selected, Fs);
    y = mas_blanked_leaky_nlms(d, x_sel, mu, gamma_leak, eps_reg, Fs, filter_order);
    ref_display = x_sel(:, 1);
    ref_lbl = ['M23 RT refs: ' strjoin(parts, '; ')];
end

function [y, ref_display, ref_lbl] = mas_rt_staged_feature_select_nlms( ...
    d, ref0, names0, ref1, names1, Fs, cal_sec, max_lag_ms, min_corr, ...
    mu, gamma_leak, eps_reg, filter_order)
% Streaming-shaped two-stage correction: choose one active-electrode
% reference and one reference-electrode reference, then run two causal NLMS
% stages in series.
    if nargin < 13, filter_order = 16; end
    d = d(:);
    y = d;
    ref_display = [];
    ref_lbl = 'M25 bypass: no staged reference selected';

    sel0 = rt_select_features_by_corr(d, ref0, Fs, 1, cal_sec, max_lag_ms, min_corr);
    if isempty(sel0)
        ref_lbl = sprintf('M25 bypass: no LA |r| >= %.2f', min_corr);
        return;
    end

    [x0, p0] = rt_materialize_selected_refs(ref0, names0, sel0, Fs);
    y1 = mas_blanked_leaky_nlms(d, x0, mu, gamma_leak, eps_reg, Fs, filter_order);
    ref_display = x0(:, 1);

    sel1 = rt_select_features_by_corr(d, ref1, Fs, 1, cal_sec, max_lag_ms, min_corr);
    if isempty(sel1)
        y = y1;
        ref_lbl = ['M25 RT staged: LA ' p0{1} '; RA bypass'];
        return;
    end

    [x1, p1] = rt_materialize_selected_refs(ref1, names1, sel1, Fs);
    y = mas_blanked_leaky_nlms(y1, x1, mu, gamma_leak, eps_reg, Fs, filter_order);
    ref_lbl = ['M25 RT staged: LA ' p0{1} '; RA ' p1{1}];
end

function [y, ref_display, ref_lbl] = mas_rt_coherence_band_nlms( ...
    d, ref_bank, ref_names, Fs, cal_sec, max_lag_ms, peak_thr, max_bands, bw, ...
    mu, gamma_leak, eps_reg, filter_order, subtract_gain)
% Simulated streaming mode for Xiong-style reference pruning. The
% calibration window selects coherent feature+lag+band candidates, then the
% locked bands are processed causally.
    if nargin < 14, subtract_gain = 0.85; end
    if nargin < 13, filter_order = 16; end
    if nargin < 12, eps_reg = 1e-8; end
    if nargin < 11, gamma_leak = 0.02; end
    if nargin < 10, mu = 0.03; end
    if nargin < 9,  bw = 0.60; end
    if nargin < 8,  max_bands = 3; end
    if nargin < 7,  peak_thr = 0.40; end

    d = d(:);
    y = d;
    ref_display = [];
    ref_lbl = 'RT-band bypass: no coherent streaming band selected';
    if isempty(ref_bank) || numel(d) ~= size(ref_bank, 1)
        return;
    end

    selected = rt_select_bands_by_coherence(d, ref_bank, Fs, cal_sec, max_lag_ms, peak_thr, max_bands, bw);
    if isempty(selected)
        ref_lbl = sprintf('RT-band bypass: no calibration peak gamma^2 >= %.2f', peak_thr);
        return;
    end

    parts = cell(1, size(selected, 1));
    for ss = 1:size(selected, 1)
        ref_idx = selected(ss, 3);
        lag_samp = selected(ss, 4);
        f0 = selected(ss, 2);
        x_ref = rt_causal_delay(ref_bank(:, ref_idx), lag_samp);
        if ss == 1
            ref_display = x_ref;
        end
        y = mas_selective_band_gated_once_rt(y, x_ref, mu, gamma_leak, eps_reg, ...
                                             Fs, f0, bw, filter_order, subtract_gain);
        parts{ss} = sprintf('%s %.2fHz +%dms g2=%.2f', ref_names{ref_idx}, ...
                            f0, round(1000*lag_samp/Fs), selected(ss, 1));
    end
    ref_lbl = ['RT bands: ' strjoin(parts, '; ')];
end

function selected = rt_select_features_by_corr(d, ref_bank, Fs, max_refs, cal_sec, max_lag_ms, min_corr)
    selected = [];
    N = numel(d);
    calN = rt_calibration_n(N, Fs, cal_sec);
    if calN < 64 || isempty(ref_bank)
        return;
    end

    band_hi = min(8.0, 0.45*Fs);
    d_probe = rt_bandpass_if_possible(d, Fs, [0.5, band_hi]);
    max_lag = max(0, round((max_lag_ms/1000) * Fs));
    lag_step = max(1, round(0.020 * Fs));
    rows = zeros(0, 3);  % score, ref_idx, lag_samp

    for rr = 1:size(ref_bank, 2)
        x_probe = rt_bandpass_if_possible(ref_bank(:, rr), Fs, [0.5, band_hi]);
        for lag_samp = 0:lag_step:max_lag
            x_lag = rt_causal_delay(x_probe, lag_samp);
            idx0 = max(1, lag_samp + 1);
            idx = idx0:calN;
            if numel(idx) < 32
                continue;
            end
            score = rt_abs_corr(d_probe(idx), x_lag(idx));
            if score >= min_corr
                rows = [rows; score, rr, lag_samp]; %#ok<AGROW>
            end
        end
    end

    if isempty(rows)
        return;
    end
    [~, ord] = sort(rows(:, 1), 'descend');
    rows = rows(ord, :);

    used_ref = false(1, size(ref_bank, 2));
    for ii = 1:size(rows, 1)
        rr = rows(ii, 2);
        if used_ref(rr)
            continue;
        end
        selected = [selected; rows(ii, :)]; %#ok<AGROW>
        used_ref(rr) = true;
        if size(selected, 1) >= max_refs
            break;
        end
    end
end

function selected = rt_select_bands_by_coherence(d, ref_bank, Fs, cal_sec, max_lag_ms, peak_thr, max_bands, bw)
    selected = [];
    N = numel(d);
    calN = rt_calibration_n(N, Fs, cal_sec);
    if calN < 96 || isempty(ref_bank) || Fs <= 20
        return;
    end

    band_hi = min(8.0, 0.45*Fs);
    if band_hi <= 0.5
        return;
    end

    d_cal_raw = d(1:calN) - mean(d(1:calN));
    % QRS blanking: removes BCG-driven cardiac-mechanical coherence at HR frequency.
    % Without this, resting γ² peaks near 0.9 at ~1 Hz, causing false band selection.
    qrs_mask = rt_causal_qrs_mask(d_cal_raw, Fs);
    n_valid = sum(qrs_mask);
    if n_valid < 96
        return;
    end
    d_cal = d_cal_raw(qrs_mask);

    nper = min(512, max(64, floor(n_valid/2)));
    nper = min(nper, n_valid);
    nfft = max(256, 2^nextpow2(2*nper));
    win = hamming(nper);
    nover = floor(nper/2);
    max_lag = max(0, round((max_lag_ms/1000) * Fs));
    lag_step = max(1, round(0.020 * Fs));
    candidates = zeros(0, 4);  % peak_g2, f0, ref_idx, lag_samp

    for rr = 1:size(ref_bank, 2)
        for lag_samp = 0:lag_step:max_lag
            x_lag = rt_causal_delay(ref_bank(:, rr), lag_samp);
            x_cal = x_lag(1:calN) - mean(x_lag(1:calN));
            x_cal = x_cal(qrs_mask);    % same mask applied to both signals
            if std(x_cal) <= 1e-10
                continue;
            end
            try
                [cxy, f] = mscohere(d_cal, x_cal, win, nover, nfft, Fs);
            catch
                continue;
            end
            band = f >= 0.5 & f <= band_hi & isfinite(cxy);
            if ~any(band)
                continue;
            end
            c_band = cxy(band);
            f_band = f(band);
            [pk, ii] = max(c_band);
            if pk >= peak_thr
                candidates = [candidates; pk, f_band(ii), rr, lag_samp]; %#ok<AGROW>
            end
        end
    end

    if isempty(candidates)
        return;
    end
    [~, ord] = sort(candidates(:, 1), 'descend');
    candidates = candidates(ord, :);

    used_ref = false(1, size(ref_bank, 2));
    for ii = 1:size(candidates, 1)
        f0 = candidates(ii, 2);
        rr = candidates(ii, 3);
        if used_ref(rr)
            continue;
        end
        if ~isempty(selected) && any(abs(selected(:, 2) - f0) < 0.50*bw)
            continue;
        end
        selected = [selected; candidates(ii, :)]; %#ok<AGROW>
        used_ref(rr) = true;
        if size(selected, 1) >= max_bands
            break;
        end
    end
end

function mask = rt_causal_qrs_mask(ecg, Fs)
% Returns logical vector (true = usable sample) with ±100 ms around each
% detected R-peak set to false. Mirrors qrs_blank in signal_diagnose_gui.m.
% Applied only to the calibration window, so all input data is past-only.
    half_win = round(0.100 * Fs);
    N = numel(ecg);
    mask = true(N, 1);
    if N < 6 * round(Fs) || Fs < 20
        return;
    end
    ecg = ecg(:);
    [b1, a1] = butter(2, [5 15] / (Fs/2), 'bandpass');
    xf = filter(b1, a1, ecg - ecg(1));
    xd = [0; diff(xf)];
    xs = xd .^ 2;
    xi = movmean(xs, max(3, round(0.150 * Fs)));
    th = 0.3 * movmax(xi, max(round(2*Fs), 5));
    locs = find(xi(2:end-1) > xi(1:end-2) & xi(2:end-1) > xi(3:end) & xi(2:end-1) > th(2:end-1)) + 1;
    if numel(locs) > 1
        keep = true(size(locs));
        last = locs(1);
        for k = 2:numel(locs)
            if locs(k) - last < round(0.25 * Fs)
                keep(k) = false;
            else
                last = locs(k);
            end
        end
        locs = locs(keep);
    end
    for k = 1:numel(locs)
        i1 = max(1, locs(k) - half_win);
        i2 = min(N, locs(k) + half_win);
        mask(i1:i2) = false;
    end
end

function keep_refs = rt_preselect_refs_by_corr(d, ref_bank, Fs, max_refs, max_lag_ms)
% Cheap training-window preselector before coherence scanning.
    keep_refs = [];
    if isempty(ref_bank) || isempty(d)
        return;
    end
    N = numel(d);
    if N < 64
        return;
    end

    band_hi = min(8.0, 0.45*Fs);
    d_probe = rt_bandpass_if_possible(d(:), Fs, [0.5, band_hi]);
    max_lag = max(0, round((max_lag_ms/1000) * Fs));
    lag_step = max(1, round(0.040 * Fs));
    scores = zeros(1, size(ref_bank, 2));

    for rr = 1:size(ref_bank, 2)
        x_probe = rt_bandpass_if_possible(ref_bank(:, rr), Fs, [0.5, band_hi]);
        best = 0;
        for lag_samp = 0:lag_step:max_lag
            x_lag = rt_causal_delay(x_probe, lag_samp);
            idx0 = max(1, lag_samp + 1);
            idx = idx0:N;
            if numel(idx) < 32
                continue;
            end
            best = max(best, rt_abs_corr(d_probe(idx), x_lag(idx)));
        end
        scores(rr) = best;
    end

    [scores_sorted, ord] = sort(scores, 'descend');
    ord = ord(scores_sorted > 0.02);
    if isempty(ord)
        return;
    end
    keep_refs = ord(1:min(numel(ord), max_refs));
end

function [x_sel, parts] = rt_materialize_selected_refs(ref_bank, ref_names, selected, Fs)
    N = size(ref_bank, 1);
    K = size(selected, 1);
    x_sel = zeros(N, K);
    parts = cell(1, K);
    for kk = 1:K
        ref_idx = selected(kk, 2);
        lag_samp = selected(kk, 3);
        x_sel(:, kk) = rt_causal_delay(ref_bank(:, ref_idx), lag_samp);
        parts{kk} = sprintf('%s +%dms r=%.2f', ref_names{ref_idx}, ...
                            round(1000*lag_samp/Fs), selected(kk, 1));
    end
end

function y = mas_selective_band_gated_once_rt(d, x_ref, mu, gamma_leak, eps_reg, Fs, f0, bw, filter_order, subtract_gain)
% Causal version of selective-band subtraction. Unlike the offline helper,
% the motion gate uses only past envelope estimates.
    if nargin < 10, subtract_gain = 0.85; end
    if nargin < 9, filter_order = 16; end
    d = d(:);
    x_ref = x_ref(:);

    lo = max(0.5, f0 - bw/2);
    hi = min(0.45*Fs, f0 + bw/2);
    if hi <= lo
        y = d;
        return;
    end

    [bb, ba] = butter(2, [lo hi]/(Fs/2), 'bandpass');
    d_sb = filter(bb, ba, d);
    x_sb = filter(bb, ba, x_ref);

    N = numel(d);
    M = filter_order;
    decay = 1 - mu * gamma_leak;
    w = zeros(M, 1);
    buf = zeros(M, 1);
    artefact_hat = zeros(N, 1);
    env_fast = 0;
    env_slow = 0;
    a_fast = exp(-1 / max(1, 0.120*Fs));
    a_slow = exp(-1 / max(1, 2.000*Fs));
    warmup = max(M, round(0.250 * Fs));

    for nn = 1:N
        buf = [x_sb(nn); buf(1:end-1)];
        xTx = buf' * buf + eps_reg;
        e = d_sb(nn) - w' * buf;
        w = decay*w + (mu/xTx) * e * buf;

        env_abs = abs(x_sb(nn));
        env_fast = a_fast*env_fast + (1-a_fast)*env_abs;
        env_slow = a_slow*env_slow + (1-a_slow)*env_abs;
        gate = (env_fast - 0.75*env_slow) / (1.25*env_slow + eps_reg);
        gate = min(1, max(0, gate));
        if nn <= warmup
            gate = 0;
        end
        artefact_hat(nn) = gate * (w' * buf);
    end

    y = d - subtract_gain * artefact_hat;
end

function [y, ref_display, ref_lbl] = mas_rt_rolling_event_band_nlms( ...
    d, ref_bank, ref_names, Fs, cal_sec, update_sec, max_lag_ms, peak_thr, ...
    max_bands, bw, mu, gamma_leak, eps_reg, filter_order, subtract_gain)
% Rolling adaptive event-band MAS. Every update_sec seconds, select the
% best feature/lag/band candidates using only the preceding cal_sec seconds,
% then process the next block with causal event-gated NLMS.
    if nargin < 15, subtract_gain = 1.0; end
    if nargin < 14, filter_order = 32; end
    if nargin < 13, eps_reg = 1e-8; end
    if nargin < 12, gamma_leak = 0.005; end
    if nargin < 11, mu = 0.06; end
    if nargin < 10, bw = 0.80; end
    if nargin < 9,  max_bands = 3; end
    if nargin < 8,  peak_thr = 0.18; end

    d = d(:);
    N = numel(d);
    y = d;
    ref_display = zeros(N, 1);
    ref_lbl = 'M30 bypass: no adaptive reference selected';

    if isempty(ref_bank) || size(ref_bank,1) ~= N || N < max(128, round(2*Fs))
        return;
    end

    calN = max(64, round(cal_sec * Fs));
    updN = max(16, round(update_sec * Fs));
    preN = max(round(2*Fs), round((max_lag_ms/1000)*Fs) + filter_order + 4);
    block_start = min(N, calN) + 1;
    if block_start > N
        return;
    end

    parts = {};
    update_count = 0;
    active_count = 0;

    while block_start <= N
        block_end = min(N, block_start + updN - 1);
        hist_start = max(1, block_start - calN);
        hist_end = block_start - 1;
        if hist_end - hist_start + 1 < 64
            block_start = block_end + 1;
            continue;
        end

        d_hist = d(hist_start:hist_end);
        r_hist = ref_bank(hist_start:hist_end, :);
        hist_sec = numel(d_hist) / Fs;
        selected = rt_select_bands_by_coherence(d_hist, r_hist, Fs, hist_sec, ...
                                                max_lag_ms, peak_thr, max_bands, bw);
        update_count = update_count + 1;

        if isempty(selected)
            block_start = block_end + 1;
            continue;
        end

        ctx_start = max(1, block_start - preN);
        ctx_idx = ctx_start:block_end;
        y_ctx = d(ctx_idx);
        ref_first = [];

        for ss = 1:size(selected, 1)
            ref_idx = selected(ss, 3);
            lag_samp = selected(ss, 4);
            f0 = selected(ss, 2);
            x_ctx = rt_causal_delay(ref_bank(ctx_idx, ref_idx), lag_samp);
            if isempty(ref_first)
                ref_first = x_ctx;
                if numel(parts) < 8
                    parts{end+1} = sprintf('%s %.2fHz +%dms g2=%.2f', ...
                        ref_names{ref_idx}, f0, round(1000*lag_samp/Fs), selected(ss,1)); %#ok<AGROW>
                end
            end
            y_ctx = mas_selective_band_gated_once_rt(y_ctx, x_ctx, mu, gamma_leak, ...
                                                     eps_reg, Fs, f0, bw, filter_order, subtract_gain);
        end

        out_start = block_start - ctx_start + 1;
        out_stop = block_end - ctx_start + 1;
        y(block_start:block_end) = y_ctx(out_start:out_stop);
        if ~isempty(ref_first)
            ref_display(block_start:block_end) = ref_first(out_start:out_stop);
        end
        active_count = active_count + 1;
        block_start = block_end + 1;
    end

    if active_count > 0
        ref_lbl = sprintf('M30 rolling adaptive: %d/%d updates active; %s', ...
                          active_count, update_count, strjoin(parts, '; '));
    end
end

function [y, ref_display, ref_lbl] = mas_rt_validated_event_band_nlms( ...
    d, ref_bank, ref_names, Fs, cal_sec, update_sec, max_lag_ms, train_peak_thr, ...
    val_peak_thr, min_env_corr, min_overlap, min_val_reduction_db, max_bands, bw, mu, gamma_leak, ...
    eps_reg, filter_order, subtract_gain)
% Rolling adaptive MAS with held-out validation. Each update uses only the
% preceding cal_sec seconds, selects on the older half, validates on the
% newer half, then processes the next block with fixed causal settings.
    if nargin < 19, subtract_gain = 0.55; end
    if nargin < 18, filter_order = 24; end
    if nargin < 17, eps_reg = 1e-8; end
    if nargin < 16, gamma_leak = 0.010; end
    if nargin < 15, mu = 0.035; end
    if nargin < 14, bw = 0.70; end
    if nargin < 13, max_bands = 1; end
    if nargin < 12, min_val_reduction_db = 0.15; end
    if nargin < 11, min_overlap = 0.18; end
    if nargin < 10, min_env_corr = 0.08; end
    if nargin < 9,  val_peak_thr = 0.12; end
    if nargin < 8,  train_peak_thr = 0.22; end

    d = d(:);
    N = numel(d);
    y = d;
    ref_display = zeros(N, 1);
    ref_lbl = 'M31 bypass: no validated adaptive reference selected';

    if isempty(ref_bank) || size(ref_bank,1) ~= N || N < max(128, round(3*Fs))
        return;
    end

    calN = max(128, round(cal_sec * Fs));
    updN = max(16, round(update_sec * Fs));
    preN = max(round(2*Fs), round((max_lag_ms/1000)*Fs) + filter_order + 4);
    block_start = min(N, calN) + 1;
    if block_start > N
        return;
    end

    parts = {};
    update_count = 0;
    active_count = 0;
    rejected_count = 0;

    while block_start <= N
        block_end = min(N, block_start + updN - 1);
        hist_start = max(1, block_start - calN);
        hist_end = block_start - 1;
        histN = hist_end - hist_start + 1;
        if histN < max(128, round(4*Fs))
            block_start = block_end + 1;
            continue;
        end

        split_local = floor(histN/2);
        train_idx = hist_start:(hist_start + split_local - 1);
        val_idx = (hist_start + split_local):hist_end;
        if numel(train_idx) < 64 || numel(val_idx) < 64
            block_start = block_end + 1;
            continue;
        end

        update_count = update_count + 1;
        train_refs = rt_preselect_refs_by_corr(d(train_idx), ref_bank(train_idx, :), ...
            Fs, min(size(ref_bank,2), 32), max_lag_ms);
        if isempty(train_refs)
            rejected_count = rejected_count + 1;
            block_start = block_end + 1;
            continue;
        end

        train_sec = numel(train_idx) / Fs;
        train_max = max(4, max_bands * 4);
        selected = rt_select_bands_by_coherence(d(train_idx), ref_bank(train_idx, train_refs), ...
            Fs, train_sec, max_lag_ms, train_peak_thr, train_max, bw);

        if isempty(selected)
            rejected_count = rejected_count + 1;
            block_start = block_end + 1;
            continue;
        end

        accepted = zeros(0, 8);  % train_g2, f0, ref_idx, lag, val_g2, env_r, overlap, val_reduction_db
        hist_idx = hist_start:hist_end;
        val_local = (split_local + 1):histN;
        for ss = 1:size(selected, 1)
            ref_idx = train_refs(selected(ss, 3));
            lag_samp = selected(ss, 4);
            f0 = selected(ss, 2);
            x_hist = rt_causal_delay(ref_bank(hist_idx, ref_idx), lag_samp);
            x_val = x_hist(val_local);
            [val_g2, env_r, overlap] = rt_validate_event_band( ...
                d(val_idx), x_val, Fs, f0, bw);
            y_val = mas_selective_band_gated_once_rt(d(val_idx), x_val, mu, gamma_leak, ...
                                                     eps_reg, Fs, f0, bw, filter_order, subtract_gain);
            val_reduction_db = rt_validation_reduction_db(d(val_idx), y_val, Fs, f0, bw, eps_reg);

            if val_g2 >= val_peak_thr && env_r >= min_env_corr && ...
                    overlap >= min_overlap && val_reduction_db >= min_val_reduction_db
                accepted = [accepted; selected(ss, 1:2), ref_idx, selected(ss, 4), ...
                            val_g2, env_r, overlap, val_reduction_db]; %#ok<AGROW>
            end
            if size(accepted, 1) >= max_bands
                break;
            end
        end

        if isempty(accepted)
            rejected_count = rejected_count + 1;
            block_start = block_end + 1;
            continue;
        end

        ctx_start = max(1, block_start - preN);
        ctx_idx = ctx_start:block_end;
        y_ctx = d(ctx_idx);
        ref_first = [];

        for ss = 1:size(accepted, 1)
            ref_idx = accepted(ss, 3);
            lag_samp = accepted(ss, 4);
            f0 = accepted(ss, 2);
            x_ctx = rt_causal_delay(ref_bank(ctx_idx, ref_idx), lag_samp);
            if isempty(ref_first)
                ref_first = x_ctx;
                if numel(parts) < 8
                    parts{end+1} = sprintf('%s %.2fHz +%dms train=%.2f val=%.2f env=%.2f ov=%.0f%% red=%.2fdB', ...
                        ref_names{ref_idx}, f0, round(1000*lag_samp/Fs), ...
                        accepted(ss,1), accepted(ss,5), accepted(ss,6), ...
                        100*accepted(ss,7), accepted(ss,8)); %#ok<AGROW>
                end
            end
            y_ctx = mas_selective_band_gated_once_rt(y_ctx, x_ctx, mu, gamma_leak, ...
                                                     eps_reg, Fs, f0, bw, filter_order, subtract_gain);
        end

        out_start = block_start - ctx_start + 1;
        out_stop = block_end - ctx_start + 1;
        y(block_start:block_end) = y_ctx(out_start:out_stop);
        if ~isempty(ref_first)
            ref_display(block_start:block_end) = ref_first(out_start:out_stop);
        end
        active_count = active_count + 1;
        block_start = block_end + 1;
    end

    if active_count > 0
        ref_lbl = sprintf('Validated adaptive MAS: %d/%d updates active, %d rejected; %s', ...
            active_count, update_count, rejected_count, strjoin(parts, '; '));
    elseif update_count > 0
        ref_lbl = sprintf('M31 bypass: validation rejected %d/%d updates (need val g2>=%.2f, env r>=%.2f, overlap>=%.0f%%, red>=%.2fdB)', ...
            rejected_count, update_count, val_peak_thr, min_env_corr, 100*min_overlap, min_val_reduction_db);
    end
end

function [peak_g2, env_corr, overlap] = rt_validate_event_band(d_seg, x_seg, Fs, f0, bw)
% Validate that coherence is event-aligned, not only spectrally similar.
    d_seg = d_seg(:);
    x_seg = x_seg(:);
    N = min(numel(d_seg), numel(x_seg));
    peak_g2 = 0;
    env_corr = 0;
    overlap = 0;
    if N < 64 || Fs <= 20
        return;
    end
    d_seg = d_seg(1:N);
    x_seg = x_seg(1:N);

    lo = max(0.5, f0 - bw/2);
    hi = min(0.45*Fs, f0 + bw/2);
    if hi <= lo
        return;
    end

    nper = min(256, max(64, floor(N/2)));
    nper = min(nper, N);
    nfft = max(256, 2^nextpow2(2*nper));
    win = hamming(nper);
    nover = floor(nper/2);
    try
        [cxy, f] = mscohere(d_seg - mean(d_seg), x_seg - mean(x_seg), win, nover, nfft, Fs);
        band = f >= lo & f <= hi & isfinite(cxy);
        if any(band)
            peak_g2 = max(cxy(band));
        end
    catch
        peak_g2 = 0;
    end

    d_band = rt_bandpass_if_possible(d_seg, Fs, [lo hi]);
    x_band = rt_bandpass_if_possible(x_seg, Fs, [lo hi]);
    env_len = max(4, round(0.250 * Fs));
    d_env = filter(ones(env_len,1)/env_len, 1, abs(d_band));
    x_env = filter(ones(env_len,1)/env_len, 1, abs(x_band));

    warmup = max(env_len, round(0.500 * Fs));
    valid = warmup:N;
    if numel(valid) < 32
        valid = 1:N;
    end
    env_corr = rt_signed_corr(d_env(valid), x_env(valid));

    d_thr = prctile(d_env(valid), 85);
    x_thr = prctile(x_env(valid), 85);
    d_mask = d_env(valid) >= d_thr;
    x_mask = x_env(valid) >= x_thr;
    overlap = nnz(d_mask & x_mask) / max(nnz(d_mask), 1);
end

function reduction_db = rt_validation_reduction_db(d_seg, y_seg, Fs, f0, bw, eps_reg)
% Held-out proof that the candidate lowers the same band it claims to model.
    lo = max(0.5, f0 - bw/2);
    hi = min(0.45*Fs, f0 + bw/2);
    if hi <= lo || isempty(d_seg) || isempty(y_seg)
        reduction_db = -Inf;
        return;
    end
    d_band = rt_bandpass_if_possible(d_seg(:), Fs, [lo hi]);
    y_band = rt_bandpass_if_possible(y_seg(:), Fs, [lo hi]);
    n = min(numel(d_band), numel(y_band));
    if n < 32
        reduction_db = -Inf;
        return;
    end
    p0 = mean(d_band(1:n).^2) + eps_reg;
    p1 = mean(y_band(1:n).^2) + eps_reg;
    reduction_db = 10 * log10(p0 / p1);
end

function y = rt_causal_delay(x, lag_samp)
    x = double(x);
    lag_samp = max(0, round(lag_samp));
    if lag_samp == 0
        y = x;
        return;
    end
    N = size(x, 1);
    if lag_samp >= N
        y = zeros(size(x));
    else
        y = [zeros(lag_samp, size(x, 2)); x(1:end-lag_samp, :)];
    end
end

function y = rt_bandpass_if_possible(x, Fs, band)
    x = double(x);
    lo = band(1);
    hi = min(band(2), 0.45*Fs);
    if hi <= lo || Fs <= 2*lo
        y = x - mean(x, 1);
        return;
    end
    try
        [bb, ba] = butter(2, [lo hi]/(Fs/2), 'bandpass');
        y = filter(bb, ba, x);
    catch
        y = x - mean(x, 1);
    end
end

function y = rt_condition_mas_reference(x, Fs)
% Shape IMU references into the motion-artifact band used for MAS selection.
% This keeps DC/gravity and unrelated high-frequency IMU content from driving
% the adaptive filter while preserving causal timing.
    x = double(x);
    if isempty(x)
        y = x;
        return;
    end
    band_hi = min(8.0, 0.45*Fs);
    if band_hi > 0.5 && Fs > 1
        y = rt_bandpass_if_possible(x, Fs, [0.5 band_hi]);
    else
        y = rt_dc_block(x, 0.995);
    end
    y(~isfinite(y)) = 0;
    mu = mean(y, 1);
    sig = std(y, 0, 1);
    sig(~isfinite(sig) | sig < 1e-10) = 1;
    y = (y - mu) ./ sig;
end

function y = rt_match_filter_bank(x, Fs)
% Causal AD8233CB-EBZ OUT-path shaping for IMU references. The eval board
% places the ECG OUT path through two high-pass poles near 7.2 Hz and a
% two-pole Sallen-Key low-pass near 25 Hz before the MCU ADC sees it.
    x = double(x);
    lo = 7.2;
    hi = min(25.0, 0.45*Fs);
    if hi <= lo || Fs <= 2*lo
        y = x;
        return;
    end
    try
        [bb, ba] = butter(2, [lo hi]/(Fs/2), 'bandpass');
        y = filter(bb, ba, x);
    catch
        y = x;
    end
end

function r = rt_abs_corr(a, b)
    a = a(:) - mean(a(:));
    b = b(:) - mean(b(:));
    denom = sqrt(sum(a.*a) * sum(b.*b));
    if denom <= 1e-12
        r = 0;
    else
        r = abs(sum(a.*b) / denom);
    end
end

function r = rt_signed_corr(a, b)
    a = a(:) - mean(a(:));
    b = b(:) - mean(b(:));
    denom = sqrt(sum(a.*a) * sum(b.*b));
    if denom <= 1e-12
        r = 0;
    else
        r = sum(a.*b) / denom;
    end
end

function y = rt_dc_block(x, alpha)
    lp = filter(1-alpha, [1, -alpha], x);
    y = x - lp;
end

function calN = rt_calibration_n(N, Fs, cal_sec)
    calN = min(N, max(64, round(cal_sec * Fs)));
end

function y = mas_cw_blank_leaky(d, x_ref, mu, gamma_leak, eps_reg, Fs, filter_order)
% Combined stabiliser: correlation-weighted + blanked + leaky NLMS.
% Applies all three stabilisation mechanisms simultaneously.
    if nargin < 7, filter_order = 16; end
    N = numel(d);
    if isvector(x_ref), x_ref = x_ref(:); end
    L = size(x_ref, 2); M = filter_order;

    win_len = max(8, round(0.200 * Fs));
    d_win = zeros(win_len, 1);
    x_win = zeros(win_len, 1);
    x_probe = x_ref(:, 1);

    blank_len  = round(0.120 * Fs);
    refrac_len = round(0.250 * Fs);
    ma_len     = max(1, round(0.050 * Fs));
    env_buf = zeros(ma_len, 1);
    env_max = 0; env_max_tau = exp(-1/(2*Fs));
    blank_left = 0; refrac_left = 0;
    prev_d = 0; prev_env = 0;

    decay = 1 - mu * gamma_leak;
    w = zeros(L*M, 1); buf = zeros(L, M); y = zeros(N, 1);

    for n = 1:N
        dn = d(n);

        % Causal QRS detector on primary signal
        dd = dn - prev_d; prev_d = dn;
        s  = dd*dd;
        env_buf = [s; env_buf(1:end-1)];
        env = mean(env_buf);
        env_max = max(env, env_max_tau * env_max);
        thr = 0.30 * env_max;
        if refrac_left > 0
            refrac_left = refrac_left - 1;
        elseif env > thr && env > prev_env
            blank_left = blank_len; refrac_left = refrac_len;
        end
        prev_env = env;

        % Instantaneous correlation
        d_win = [dn; d_win(1:end-1)];
        x_win = [x_probe(n); x_win(1:end-1)];
        if n >= win_len
            dm = mean(d_win); xm = mean(x_win);
            ddv = d_win - dm;  dxv = x_win - xm;
            denom = sqrt(sum(ddv.*ddv)*sum(dxv.*dxv)) + eps_reg;
            rho = abs(sum(ddv.*dxv) / denom);
        else
            rho = 0;
        end

        buf = [x_ref(n,:)', buf(:, 1:end-1)];
        xv  = buf(:);
        xTx = xv'*xv + eps_reg;
        e   = dn - w'*xv;

        if blank_left > 0
            blank_left = blank_left - 1;
        else
            w = decay*w + (rho * mu / xTx) * e * xv;
        end
        y(n) = e;
    end
end

function y = mas_cw_hampel(d, x_ref, mu, gamma_leak, eps_reg, Fs, filter_order)
% Two-stage per Ghaleb et al. 2018 (PLoS One 13(11):e0207176):
%   Stage 1: correlation-weighted leaky NLMS (mas_cw_nlms)
%   Stage 2: causal recursive Hampel outlier filter on the residual
% Stage 2 suppresses residual spikes (EMG bursts, cable pops) that the
% adaptive stage cannot cancel because they are uncorrelated with the
% IMU reference.
%
% Causal Hampel: sliding 500 ms window, median m and MAD sigma computed
% on the past samples only. If |y - m| > k*sigma, replace with m.
    if nargin < 7, filter_order = 16; end
    y1 = mas_cw_nlms(d, x_ref, mu, gamma_leak, eps_reg, Fs, filter_order);

    win_len = max(8, round(0.500 * Fs));
    k_sig   = 3.0;
    N = numel(y1);
    y = zeros(N, 1);
    buf = zeros(win_len, 1);
    for n = 1:N
        buf = [y1(n); buf(1:end-1)];
        if n >= win_len
            m = median(buf);
            sigma_h = 1.4826 * median(abs(buf - m));
            if sigma_h > eps_reg && abs(y1(n) - m) > k_sig * sigma_h
                y(n) = m;
            else
                y(n) = y1(n);
            end
        else
            y(n) = y1(n);
        end
    end
end

%% ═══════════════════════════════════════════════════════════════════════
%% FILTER HELPERS (carried over from phase2_analyzer)
%% ═══════════════════════════════════════════════════════════════════════

function out = rejection_label(rdb)
    if rdb > 40, out = 'OK: excellent';
    elseif rdb > 20, out = 'OK: good';
    elseif rdb > 6,  out = 'Partial';
    else,            out = 'Minimal';
    end
end

function out = st_ratio_label(st_ratio_db)
    if st_ratio_db < 6,  out = 'OK: within 6 dB of baseline';
    elseif st_ratio_db < 12, out = 'Moderate — possible ringing';
    else,                out = 'High — likely ringing';
    end
end

function divider_line(parent, y_pos, width)
    uipanel(parent,'Position',[8 y_pos width 1], ...
        'BackgroundColor',[0.35 0.35 0.4],'BorderType','none');
end

function out = ternary_str(cond, a, b)
    if cond, out = a; else, out = b; end
end

function out = ternary_num(cond, a, b)
    if cond, out = a; else, out = b; end
end

function BPF = build_bpf_struct()
    names     = {'B1: Butterworth 8th  0.5-40 Hz', ...
                 'B2: Butterworth 4th  0.5-40 Hz', ...
                 'B3: Butterworth 8th  0.05-150 Hz', ...
                 'B4: Chebyshev II 10th  0.5-40 Hz', ...
                 'B5: Elliptic 4th  0.5-40 Hz', ...
                 'B6: Butterworth 8th  0.05-40 Hz', ...
                 'B7: Butterworth 8th  0.75-40 Hz', ...
                 'B8: Butterworth 12th  0.5-40 Hz'};
    passbands = {[0.5 40],[0.5 40],[0.05 150],[0.5 40],[0.5 40],[0.05 40],[0.75 40],[0.5 40]};
    standards = {'IEC 60601-2-27','Lightweight','IEC 60601-2-25','AHA monitor','Min-order','ST-segment','Aggressive baseline','High-attenuation'};
    for b = 1:numel(names)
        c = build_bpf_at_fs(b, 500); n_stg = size(c,1);
        BPF(b).sos      = c; %#ok<AGROW>
        BPF(b).name     = names{b};
        BPF(b).stages   = n_stg;
        BPF(b).passband = passbands{b};
        BPF(b).standard = standards{b};
    end
end

function sos_ml = build_bpf_at_fs(bpf_idx, Fs)
    Ny = Fs / 2;
    passbands = {[0.5 40],[0.5 40],[0.05 150],[0.5 40],[0.5 40],[0.05 40],[0.75 40],[0.5 40]};
    pb = passbands{bpf_idx};
    pb(1) = max(pb(1), 0.01);
    pb(2) = min(pb(2), 0.99*Ny);
    if pb(1) >= pb(2)
        sos_ml = [1 0 0 1 0 0]; return;
    end
    Wn = pb / Ny;
    try
        switch bpf_idx
            case 1, [z,p,k] = butter(4,  Wn, 'bandpass');
            case 2, [z,p,k] = butter(2,  Wn, 'bandpass');
            case 3, [z,p,k] = butter(4,  Wn, 'bandpass');
            case 4
                if Wn(2) >= 0.90
                    [z,p,k] = butter(4, Wn, 'bandpass');
                else
                    Ws = [max(0.05, 0.20*pb(1)), min(0.99*Ny, max(60, 2.0*pb(2)))] / Ny;
                    if Ws(2) <= Wn(2), Ws(2) = min(0.99, Wn(2) + 0.10*(1-Wn(2))); end
                    [n4, Wn4] = cheb2ord(Wn, Ws, 0.5, 40);
                    [z,p,k] = cheby2(n4, 40, Wn4, 'bandpass');
                end
            case 5, [z,p,k] = ellip(2, 0.5, 40, Wn, 'bandpass');
            case 6, [z,p,k] = butter(4,  Wn, 'bandpass');
            case 7, [z,p,k] = butter(4,  Wn, 'bandpass');
            case 8, [z,p,k] = butter(6,  Wn, 'bandpass');
        end
        [sos_ml, g] = zp2sos(z, p, k);
        sos_ml(1,1:3) = sos_ml(1,1:3) * g;
    catch
        sos_ml = [1 0 0 1 0 0];
    end
end

function sos_notch = build_notch_at_fs(notch_idx, Fs)
    omega0 = 2*pi*50/Fs;
    b_n    = [1, -2*cos(omega0), 1];
    r_vals = [0.990, 0.995];
    r      = r_vals(min(notch_idx, 2));
    sos_notch = repmat([b_n, 1, -2*r*cos(omega0), r^2], 6, 1);
end
