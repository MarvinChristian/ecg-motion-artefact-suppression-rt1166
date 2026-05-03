function signal_diagnose_gui()
% signal_diagnose_gui  Combined ECG/IMU diagnostic GUI.
%
%   Replaces the legacy phase3_diagnose, phase3_diagnose_advanced, and
%   phase3_mas_ceiling scripts and the Python mas_coherence_audit.
%
% ACQUISITION ASSUMPTIONS (validated against firmware):
%   ADS1293:
%     * 24-bit signed codes printed by main_phase1.c as %d (already signed).
%     * LSB scale 1400/8388607 mV/code is the Protocentral default-gain
%       assumption. Verify against the active CHx_GN/REFOUT config; absolute
%       mV may shift, but coherence and dB-reduction results do not depend
%       on the absolute scale.
%     * Effective Fs is always derived from t_us. The "SPS_128" label is
%       not the actual ODR (R1*R2*R3 product + polling latency).
%   MPU-6500:
%     * 16-bit signed registers, /16384 g, /131 dps.
%     * Sampled whenever ADS1293 has data ready (~166 Hz). Internal ODR is
%       500 Hz, so the register holds the most recent <2 ms sample. Phase
%       jitter vs ECG is negligible below 25 Hz.
%     * Hardware DLPF 92 Hz: marginal alias band at 83-92 Hz at Fs=166 Hz,
%       well above the motion band of interest.
%
% DIAGNOSTIC ROBUSTNESS (built into this file):
%     * Welch coherence with Hann window, 4 s segments, 50% overlap.
%     * MISO coherence with PCA rank cap at floor(nseg/3) to avoid
%       rank-deficient spectral matrices producing spurious gamma^2 = 1.
%     * Causal filter() throughout (no zero-phase peeking). Lag search
%       widened to span up to 100 ms to absorb causal group delay.
%     * QRS-blanking option (default on for coherence) zeros +/-100 ms
%       around each R-peak so BCG cardiac mechanical pulse does not inflate
%       gamma^2 at HR harmonics.
%     * Shuffled-segment null and circular-shift null overlays for every
%       coherence trace.
%     * Held-out multi-reference prediction uses a 70/30 time-block split,
%       not random, since adjacent samples are autocorrelated.
%
% TABS:
%     1. Browse    - time-domain ECG + IMU
%     2. Spectrum  - PSD, marked motion/QRS/mains bands
%     3. Coherence - gamma^2(f) per axis, with QRS-blanking + null controls
%     4. Wiener    - MISO Wiener ceiling per band, dB
%     5. Batch     - process a list of files, write CSV summary
%
% ALL FILTERING IS CAUSAL (matches firmware fidelity).

%% Constants
LSB_PER_G        = 16384;
LSB_PER_DPS      = 131;
% ADS1293: same scale as phase2_analyzer (1400 mV full-scale, 24-bit signed).
% No empirical gain correction — display is autoscaled so absolute mV is irrelevant,
% and applying a multiplier before despike_ecg pushes QRS above the 1.5 mV spike
% threshold, causing QRS peaks to be interpolated away.
ADS_SCALE_MV_DEF = 1400 / 8388607;
AD_SCALE_MV_DEF  = 1800 / 4096;      % AD8233 12-bit ADC default

state.recording        = [];
state.batch_files      = {};
state.batch_results    = [];
state.params           = default_params();
state.params.lsb_g     = LSB_PER_G;
state.params.lsb_dps   = LSB_PER_DPS;
state.params.ads_mv    = ADS_SCALE_MV_DEF;
state.params.ad8233_mv = AD_SCALE_MV_DEF;

%% Build GUI
fig = uifigure('Name','Signal Diagnostics','Position',[100 100 1500 900], ...
    'Color',[0.14 0.14 0.16]);
fig.UserData = state;

main = uigridlayout(fig, [1 2]);
main.ColumnWidth = {340, '1x'};
main.Padding = [10 10 10 10];
main.ColumnSpacing = 10;
main.BackgroundColor = [0.14 0.14 0.16];

%% Left: settings panel
left = uipanel(main, 'BackgroundColor',[0.18 0.18 0.21], 'BorderType','none');
lay = uigridlayout(left, [22 2]);
lay.RowHeight = repmat({30}, 1, 22);
lay.ColumnWidth = {130, '1x'};
lay.Padding = [10 10 10 10];
lay.RowSpacing = 4;
lay.BackgroundColor = [0.18 0.18 0.21];

addlabel(lay, 1, 1, 'File:');
file_btn = uibutton(lay,'Text','Load file...','BackgroundColor',[0.25 0.45 0.65],'FontColor','w','FontWeight','bold');
file_btn.Layout.Row = 1; file_btn.Layout.Column = 2;
file_btn.ButtonPushedFcn = @(~,~) on_load_file(fig);

file_lbl = uilabel(lay,'Text','(no file)','FontColor',[0.85 0.85 0.85], ...
    'FontSize',9);
file_lbl.Layout.Row = 2; file_lbl.Layout.Column = [1 2];
fig.UserData.ui.file_lbl = file_lbl;

addlabel(lay, 3, 1, 'Lead:');
lead_dd = uidropdown(lay,'Items',{'CH1 (ADS / AD8233)','CH2 (ADS only)','CH1-CH2 diff'}, ...
    'Value','CH1 (ADS / AD8233)', ...
    'BackgroundColor',[0.13 0.13 0.16],'FontColor',[0.85 0.85 0.85]);
lead_dd.Layout.Row = 3; lead_dd.Layout.Column = 2;
fig.UserData.ui.lead_dd = lead_dd;

addlabel(lay, 4, 1, 'BPF lo (Hz):');
bpf_lo = uieditfield(lay,'numeric','Value',0.5,'BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
bpf_lo.Layout.Row = 4; bpf_lo.Layout.Column = 2;
fig.UserData.ui.bpf_lo = bpf_lo;

addlabel(lay, 5, 1, 'BPF hi (Hz):');
bpf_hi = uieditfield(lay,'numeric','Value',40,'BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
bpf_hi.Layout.Row = 5; bpf_hi.Layout.Column = 2;
fig.UserData.ui.bpf_hi = bpf_hi;

addlabel(lay, 6, 1, 'BPF order:');
bpf_ord = uieditfield(lay,'numeric','Value',4,'Limits',[2 8],'BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
bpf_ord.Layout.Row = 6; bpf_ord.Layout.Column = 2;
fig.UserData.ui.bpf_ord = bpf_ord;

addlabel(lay, 7, 1, 'Notch (Hz):');
notch_ef = uieditfield(lay,'text','Value','50,100','BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
notch_ef.Layout.Row = 7; notch_ef.Layout.Column = 2;
fig.UserData.ui.notch_ef = notch_ef;

addlabel(lay, 8, 1, 'Motion band (Hz):');
mb = uieditfield(lay,'text','Value','0.5, 8','BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
mb.Layout.Row = 8; mb.Layout.Column = 2;
fig.UserData.ui.motion_band = mb;

addlabel(lay, 9, 1, 'Welch seg (s):');
seg = uieditfield(lay,'numeric','Value',4,'BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
seg.Layout.Row = 9; seg.Layout.Column = 2;
fig.UserData.ui.welch_seg = seg;

addlabel(lay, 10, 1, 'QRS blank:');
qrs_cb = uicheckbox(lay,'Text','+/-100 ms','Value',true, ...
    'FontColor',[0.85 0.85 0.85]);
qrs_cb.Layout.Row = 10; qrs_cb.Layout.Column = 2;
fig.UserData.ui.qrs_blank = qrs_cb;

addlabel(lay, 11, 1, 'Null ctrls:');
null_cb = uicheckbox(lay,'Text','shuffle + shift','Value',true, ...
    'FontColor',[0.85 0.85 0.85]);
null_cb.Layout.Row = 11; null_cb.Layout.Column = 2;
fig.UserData.ui.null_ctrl = null_cb;

addlabel(lay, 12, 1, 'ADS LSB (mV):');
ads_lsb = uieditfield(lay,'numeric','Value',ADS_SCALE_MV_DEF, ...
    'ValueDisplayFormat','%.4e','BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
ads_lsb.Layout.Row = 12; ads_lsb.Layout.Column = 2;
fig.UserData.ui.ads_lsb = ads_lsb;

addlabel(lay, 13, 1, 'AD8233 LSB (mV):');
ad_lsb = uieditfield(lay,'numeric','Value',AD_SCALE_MV_DEF, ...
    'ValueDisplayFormat','%.4f','BackgroundColor',[0.12 0.12 0.14],'FontColor',[0.85 0.85 0.85]);
ad_lsb.Layout.Row = 13; ad_lsb.Layout.Column = 2;
fig.UserData.ui.ad_lsb = ad_lsb;

% Run buttons
run_browse = uibutton(lay,'Text','Update Browse', ...
    'BackgroundColor',[0.20 0.55 0.30],'FontColor','w','FontWeight','bold');
run_browse.Layout.Row = 15; run_browse.Layout.Column = [1 2];
run_browse.ButtonPushedFcn = @(~,~) on_browse(fig);

run_spec = uibutton(lay,'Text','Update Spectrum', ...
    'BackgroundColor',[0.20 0.55 0.30],'FontColor','w','FontWeight','bold');
run_spec.Layout.Row = 16; run_spec.Layout.Column = [1 2];
run_spec.ButtonPushedFcn = @(~,~) on_spectrum(fig);

run_coh = uibutton(lay,'Text','Compute Coherence', ...
    'BackgroundColor',[0.20 0.45 0.75],'FontColor','w','FontWeight','bold');
run_coh.Layout.Row = 17; run_coh.Layout.Column = [1 2];
run_coh.ButtonPushedFcn = @(~,~) on_coherence(fig);

run_wiener = uibutton(lay,'Text','Compute Wiener Ceiling', ...
    'BackgroundColor',[0.55 0.40 0.15],'FontColor','w','FontWeight','bold');
run_wiener.Layout.Row = 18; run_wiener.Layout.Column = [1 2];
run_wiener.ButtonPushedFcn = @(~,~) on_wiener(fig);

% Batch
batch_btn = uibutton(lay,'Text','Pick batch files...', ...
    'BackgroundColor',[0.25 0.45 0.65],'FontColor','w');
batch_btn.Layout.Row = 20; batch_btn.Layout.Column = [1 2];
batch_btn.ButtonPushedFcn = @(~,~) on_pick_batch(fig);

batch_run = uibutton(lay,'Text','Run batch + write CSV', ...
    'BackgroundColor',[0.55 0.20 0.20],'FontColor','w','FontWeight','bold');
batch_run.Layout.Row = 21; batch_run.Layout.Column = [1 2];
batch_run.ButtonPushedFcn = @(~,~) on_run_batch(fig);

batch_lbl = uilabel(lay,'Text','batch: 0 files', ...
    'FontColor',[0.85 0.85 0.85],'FontSize',9);
batch_lbl.Layout.Row = 22; batch_lbl.Layout.Column = [1 2];
fig.UserData.ui.batch_lbl = batch_lbl;

%% Right: tabs
right = uitabgroup(main, 'TabLocation','top');

tab1 = uitab(right,'Title','1. Browse','BackgroundColor',[0.12 0.12 0.14]);
ax1a = uiaxes(tab1,'Position',[20 555 1100 290]);
ax1b = uiaxes(tab1,'Position',[20 305 1100 240]);
ax1c = uiaxes(tab1,'Position',[20 70 1100 228]);
fig.UserData.ui.ax_browse_ecg  = ax1a;
fig.UserData.ui.ax_browse_imu  = ax1b;
fig.UserData.ui.ax_browse_gyro = ax1c;
style_axes(ax1a,'time (s)','ECG (mV)','ECG');
style_axes(ax1b,'time (s)','|a| (g)','Accelerometer magnitudes (DC-removed)');
style_axes(ax1c,'time (s)','|g| (dps)','Gyroscope magnitudes (DC-removed)');

uilabel(tab1,'Text','Window:', 'Position',[20 14 58 20], ...
    'FontSize',9,'FontColor',[0.75 0.75 0.75]);
browse_win_dd = uidropdown(tab1, ...
    'Items',{'5 s','10 s','30 s','All'}, 'Value','10 s', ...
    'Position',[80 11 68 26], ...
    'FontSize',9,'BackgroundColor',[0.16 0.16 0.18],'FontColor',[0.85 0.85 0.85], ...
    'ValueChangedFcn',@(~,~) on_browse_scroll(fig));
uilabel(tab1,'Text','Position:', 'Position',[158 14 58 20], ...
    'FontSize',9,'FontColor',[0.75 0.75 0.75]);
browse_slider = uislider(tab1, ...
    'Position',[220 20 680 3], ...
    'Limits',[0 1],'Value',0, ...
    'MajorTicks',[],'MinorTicks',[], ...
    'ValueChangedFcn', @(~,~) on_browse_scroll(fig), ...
    'ValueChangingFcn',@(~,~) on_browse_scroll(fig));
browse_bl_cb = uicheckbox(tab1, ...
    'Text','Display baseline correction', ...
    'Value',false, ...
    'Position',[912 11 210 22], ...
    'FontSize',9,'FontColor',[0.82 0.82 0.82], ...
    'ValueChangedFcn',@(~,~) on_browse(fig));
fig.UserData.ui.browse_win_dd = browse_win_dd;
fig.UserData.ui.browse_slider  = browse_slider;
fig.UserData.ui.browse_bl_cb   = browse_bl_cb;

uilabel(tab1,'Text','Show:', 'Position',[20 42 38 18],'FontSize',9,'FontColor',[0.75 0.75 0.75]);
cb_a0 = uicheckbox(tab1,'Text','|a|_0','Value',true,'Position',[62 40 52 22],'FontSize',9, ...
    'FontColor',[0.40 0.70 1.00],'ValueChangedFcn',@(~,~) on_browse(fig));
cb_a1 = uicheckbox(tab1,'Text','|a|_1','Value',true,'Position',[118 40 52 22],'FontSize',9, ...
    'FontColor',[1.00 0.60 0.20],'ValueChangedFcn',@(~,~) on_browse(fig));
cb_a2 = uicheckbox(tab1,'Text','|a|_2','Value',true,'Position',[174 40 52 22],'FontSize',9, ...
    'FontColor',[0.80 0.40 0.80],'ValueChangedFcn',@(~,~) on_browse(fig));
cb_g0 = uicheckbox(tab1,'Text','|g|_0','Value',true,'Position',[240 40 52 22],'FontSize',9, ...
    'FontColor',[1.00 0.80 0.20],'ValueChangedFcn',@(~,~) on_browse(fig));
cb_g1 = uicheckbox(tab1,'Text','|g|_1','Value',true,'Position',[296 40 52 22],'FontSize',9, ...
    'FontColor',[0.60 1.00 0.60],'ValueChangedFcn',@(~,~) on_browse(fig));
cb_g2 = uicheckbox(tab1,'Text','|g|_2','Value',true,'Position',[352 40 52 22],'FontSize',9, ...
    'FontColor',[1.00 0.50 0.50],'ValueChangedFcn',@(~,~) on_browse(fig));
fig.UserData.ui.imu_ch = {cb_a0, cb_a1, cb_a2, cb_g0, cb_g1, cb_g2};

tab2 = uitab(right,'Title','2. Spectrum','BackgroundColor',[0.12 0.12 0.14]);
ax2a = uiaxes(tab2,'Position',[20 460 1100 380]);
ax2b = uiaxes(tab2,'Position',[20 40 1100 380]);
fig.UserData.ui.ax_spec_ecg = ax2a;
fig.UserData.ui.ax_spec_imu = ax2b;
style_axes(ax2a,'frequency (Hz)','PSD (dB)','ECG PSD');
style_axes(ax2b,'frequency (Hz)','PSD (dB)','IMU PSD');

tab3 = uitab(right,'Title','3. Coherence','BackgroundColor',[0.12 0.12 0.14]);
ax3 = uiaxes(tab3,'Position',[20 115 1100 725]);
fig.UserData.ui.ax_coh = ax3;
style_axes(ax3,'frequency (Hz)','\gamma^2','ECG <-> IMU coherence (Welch + nulls)');

uilabel(tab3,'Text','Channels:', 'Position',[20 85 65 22],'FontSize',9,'FontColor',[0.75 0.75 0.75]);
coh_a = lines(6);
coh_ch{1} = uicheckbox(tab3,'Text','mag0', 'Value',true,'Position',[ 90 83 62 22],'FontSize',9, ...
    'FontColor',coh_a(1,:),'ValueChangedFcn',@(~,~) on_coherence(fig));
coh_ch{2} = uicheckbox(tab3,'Text','mag1', 'Value',true,'Position',[156 83 62 22],'FontSize',9, ...
    'FontColor',coh_a(2,:),'ValueChangedFcn',@(~,~) on_coherence(fig));
coh_ch{3} = uicheckbox(tab3,'Text','mag2', 'Value',true,'Position',[222 83 62 22],'FontSize',9, ...
    'FontColor',coh_a(3,:),'ValueChangedFcn',@(~,~) on_coherence(fig));
coh_ch{4} = uicheckbox(tab3,'Text','gmag0','Value',true,'Position',[296 83 70 22],'FontSize',9, ...
    'FontColor',coh_a(4,:),'ValueChangedFcn',@(~,~) on_coherence(fig));
coh_ch{5} = uicheckbox(tab3,'Text','gmag1','Value',true,'Position',[370 83 70 22],'FontSize',9, ...
    'FontColor',coh_a(5,:),'ValueChangedFcn',@(~,~) on_coherence(fig));
coh_ch{6} = uicheckbox(tab3,'Text','gmag2','Value',true,'Position',[444 83 70 22],'FontSize',9, ...
    'FontColor',coh_a(6,:),'ValueChangedFcn',@(~,~) on_coherence(fig));
fig.UserData.ui.coh_ch = coh_ch;

tab4 = uitab(right,'Title','4. Wiener ceiling','BackgroundColor',[0.12 0.12 0.14]);
ax4 = uiaxes(tab4,'Position',[20 460 1100 380]);
fig.UserData.ui.ax_wiener = ax4;
style_axes(ax4,'frequency (Hz)','\gamma^2_{MISO}','MISO multi-channel coherence');
table4 = uitable(tab4,'Position',[20 40 1100 380], ...
    'BackgroundColor',[0.10 0.10 0.13]);
fig.UserData.ui.tbl_wiener = table4;

tab5 = uitab(right,'Title','5. Batch','BackgroundColor',[0.12 0.12 0.14]);
table5 = uitable(tab5,'Position',[20 40 1100 800], ...
    'BackgroundColor',[0.10 0.10 0.13]);
fig.UserData.ui.tbl_batch = table5;
end


%% ───────────────────────────────────────────────────────────────────────
%% Callbacks
%% ───────────────────────────────────────────────────────────────────────

function on_load_file(fig)
[name, path] = uigetfile({'*.txt;*.csv','Recording'}, 'Pick recording');
if isequal(name, 0), return; end
fpath = fullfile(path, name);
try
    rec = load_recording(fpath, fig.UserData.ui.ads_lsb.Value, ...
                                fig.UserData.ui.ad_lsb.Value);
catch e
    uialert(fig, e.message, 'Load failed');
    return;
end
fig.UserData.recording = rec;
fig.UserData.ui.file_lbl.Text = sprintf('%s   |   %d cols  Fs=%.2f Hz  N=%d  dur=%.1fs', ...
    name, rec.ncols, rec.Fs, rec.N, rec.duration_s);
on_browse(fig);
on_spectrum(fig);
end

function on_pick_batch(fig)
[names, path] = uigetfile({'*.txt;*.csv','Recordings'}, ...
    'Pick batch files', 'MultiSelect','on');
if isequal(names, 0), return; end
if ischar(names), names = {names}; end
files = cellfun(@(n) fullfile(path, n), names, 'UniformOutput', false);
fig.UserData.batch_files = files;
fig.UserData.ui.batch_lbl.Text = sprintf('batch: %d files', numel(files));
end

function on_browse(fig)
rec = fig.UserData.recording; if isempty(rec), return; end
ui = fig.UserData.ui;
[ecg, ~] = pick_lead(rec, ui.lead_dd.Value);
if ui.browse_bl_cb.Value
    ecg_disp = apply_display_baseline(ecg, rec.Fs);
    note = ' [display baseline corrected]';
else
    ecg_disp = ecg;
    note = '';
end

ax = ui.ax_browse_ecg; cla(ax);
plot(ax, rec.t_s, ecg_disp, 'Color',[0.30 0.85 0.50], 'LineWidth', 0.9);
title(ax, sprintf('ECG  Fs=%.2f Hz%s', rec.Fs, note));

ch = ui.imu_ch;
ax = ui.ax_browse_imu; cla(ax); hold(ax, 'on');
if ch{1}.Value, plot(ax, rec.t_s, rec.refs.mag0, 'Color',[0.40 0.70 1.00],'DisplayName','|a|_0'); end
if ch{2}.Value, plot(ax, rec.t_s, rec.refs.mag1, 'Color',[1.00 0.60 0.20],'DisplayName','|a|_1'); end
if ch{3}.Value, plot(ax, rec.t_s, rec.refs.mag2, 'Color',[0.80 0.40 0.80],'DisplayName','|a|_2'); end
hold(ax, 'off');
if ~isempty(ax.Children)
    legend(ax,'TextColor',[0.85 0.85 0.85],'Color',[0.14 0.14 0.16],'EdgeColor',[0.35 0.35 0.35]);
end

ax = ui.ax_browse_gyro; cla(ax); hold(ax, 'on');
if ch{4}.Value, plot(ax, rec.t_s, rec.refs.gmag0,'Color',[1.00 0.80 0.20],'DisplayName','|g|_0'); end
if ch{5}.Value, plot(ax, rec.t_s, rec.refs.gmag1,'Color',[0.60 1.00 0.60],'DisplayName','|g|_1'); end
if ch{6}.Value, plot(ax, rec.t_s, rec.refs.gmag2,'Color',[1.00 0.50 0.50],'DisplayName','|g|_2'); end
hold(ax, 'off');
if ~isempty(ax.Children)
    legend(ax,'TextColor',[0.85 0.85 0.85],'Color',[0.14 0.14 0.16],'EdgeColor',[0.35 0.35 0.35]);
end

t_max = rec.t_s(end);
ui.browse_slider.Limits = [0 max(t_max, 0.01)];
ui.browse_slider.Value  = 0;
on_browse_scroll(fig);
end

function on_browse_scroll(fig)
rec = fig.UserData.recording; if isempty(rec), return; end
ui  = fig.UserData.ui;
t_max = rec.t_s(end);
win_str = ui.browse_win_dd.Value;
if strcmp(win_str, 'All')
    xlim(ui.ax_browse_ecg,  [0 t_max]);
    xlim(ui.ax_browse_imu,  [0 t_max]);
    xlim(ui.ax_browse_gyro, [0 t_max]);
else
    win_w = str2double(extractBefore(win_str, ' s'));
    if isnan(win_w) || win_w <= 0, win_w = 10; end
    win_w   = min(win_w, t_max);
    t_start = max(0, min(ui.browse_slider.Value, t_max - win_w));
    xlim(ui.ax_browse_ecg,  [t_start, t_start + win_w]);
    xlim(ui.ax_browse_imu,  [t_start, t_start + win_w]);
    xlim(ui.ax_browse_gyro, [t_start, t_start + win_w]);
end
fit_ylim_to_window(ui.ax_browse_ecg);
fit_ylim_to_window(ui.ax_browse_imu);
fit_ylim_to_window(ui.ax_browse_gyro);
end

function on_spectrum(fig)
rec = fig.UserData.recording; if isempty(rec), return; end
ui = fig.UserData.ui;
[ecg, ~] = pick_lead(rec, ui.lead_dd.Value);
ecg_f = causal_bpf(ecg, rec.Fs, ui.bpf_lo.Value, ui.bpf_hi.Value, ui.bpf_ord.Value);
ecg_f = causal_notch_chain(ecg_f, rec.Fs, parse_csv_num(ui.notch_ef.Value));

[Pe_raw, f]   = welch_psd(ecg, rec.Fs, ui.welch_seg.Value);
[Pe_filt, ~]  = welch_psd(ecg_f, rec.Fs, ui.welch_seg.Value);

ax = ui.ax_spec_ecg; cla(ax); hold(ax,'on');
plot(ax, f, 10*log10(Pe_raw + eps), 'Color',[0.6 0.6 0.6], 'DisplayName','raw');
plot(ax, f, 10*log10(Pe_filt + eps), 'Color',[0.30 0.85 0.50], 'DisplayName','BPF+notch');
mb = parse_csv_num(ui.motion_band.Value);
if numel(mb) >= 2
    xline(ax, mb(1),'b--','motion lo'); xline(ax, mb(2),'b--','motion hi');
end
xline(ax, 50,'r:','50 Hz'); xline(ax, 100,'r:','100 Hz');
hold(ax,'off'); legend(ax,'TextColor',[0.85 0.85 0.85],'Color',[0.14 0.14 0.16],'EdgeColor',[0.35 0.35 0.35]); xlim(ax, [0 min(rec.Fs/2, 80)]);

[Pa, fa] = welch_psd(rec.refs.mag0, rec.Fs, ui.welch_seg.Value);
[Pg, ~]  = welch_psd(rec.refs.gmag0, rec.Fs, ui.welch_seg.Value);
ax = ui.ax_spec_imu; cla(ax); hold(ax,'on');
plot(ax, fa, 10*log10(Pa + eps),'DisplayName','|a|_0');
plot(ax, fa, 10*log10(Pg + eps),'DisplayName','|g|_0');
hold(ax,'off'); legend(ax,'TextColor',[0.85 0.85 0.85],'Color',[0.14 0.14 0.16],'EdgeColor',[0.35 0.35 0.35]); xlim(ax,[0 min(rec.Fs/2, 80)]);
end

function on_coherence(fig)
rec = fig.UserData.recording; if isempty(rec), return; end
ui = fig.UserData.ui;
[ecg, ~] = pick_lead(rec, ui.lead_dd.Value);
ecg_f = causal_bpf(ecg, rec.Fs, ui.bpf_lo.Value, ui.bpf_hi.Value, ui.bpf_ord.Value);
ecg_f = causal_notch_chain(ecg_f, rec.Fs, parse_csv_num(ui.notch_ef.Value));

if ui.qrs_blank.Value
    [ecg_for_coh, mask] = qrs_blank(ecg_f, rec.Fs, 0.100);
else
    ecg_for_coh = ecg_f; mask = true(size(ecg_f));
end

ref_names_all = {'mag0','mag1','mag2','gmag0','gmag1','gmag2'};
cmap_all = lines(numel(ref_names_all));
sel = cellfun(@(c) c.Value, ui.coh_ch);
ref_names = ref_names_all(sel);
cmap = cmap_all(sel, :);

ax = ui.ax_coh; cla(ax); hold(ax,'on');
for k = 1:numel(ref_names)
    rn = ref_names{k};
    if ~isfield(rec.refs, rn), continue; end
    x = rec.refs.(rn);
    [g2, f] = welch_coherence(ecg_for_coh(mask), x(mask), rec.Fs, ui.welch_seg.Value);
    plot(ax, f, g2, 'Color', cmap(k,:), 'LineWidth', 1.2, 'DisplayName', rn);
end

if ui.null_ctrl.Value
    rn = ref_names{1};
    if isfield(rec.refs, rn)
        x = rec.refs.(rn);
        % shuffle null
        x_sh = x(randperm(numel(x)));
        [gs, fs] = welch_coherence(ecg_for_coh(mask), x_sh(mask), rec.Fs, ui.welch_seg.Value);
        plot(ax, fs, gs, 'Color',[0.5 0.5 0.5], 'LineStyle',':', 'DisplayName','shuffle null');
        % circular shift null (preserves spectrum)
        sh = randi([round(rec.Fs*1) round(rec.Fs*5)]);
        x_cs = circshift(x, sh);
        [gc, fc] = welch_coherence(ecg_for_coh(mask), x_cs(mask), rec.Fs, ui.welch_seg.Value);
        plot(ax, fc, gc, 'Color',[0.7 0.4 0.4], 'LineStyle',':', 'DisplayName','shift null');
    end
end

mb = parse_csv_num(ui.motion_band.Value);
if numel(mb) >= 2
    xline(ax, mb(1),'b--'); xline(ax, mb(2),'b--');
end
hold(ax,'off'); legend(ax,'TextColor',[0.85 0.85 0.85],'Color',[0.14 0.14 0.16],'EdgeColor',[0.35 0.35 0.35],'Location','northeast');
ylim(ax,[0 1]); xlim(ax,[0 min(40, rec.Fs/2)]);
title(ax, sprintf('Coherence  Fs=%.2f Hz  segL=%.1f s  QRS-blank=%d', ...
    rec.Fs, ui.welch_seg.Value, ui.qrs_blank.Value));
end

function on_wiener(fig)
rec = fig.UserData.recording; if isempty(rec), return; end
ui = fig.UserData.ui;
[ecg, ~] = pick_lead(rec, ui.lead_dd.Value);
ecg_bp = causal_bpf(ecg, rec.Fs, ui.bpf_lo.Value, ui.bpf_hi.Value, ui.bpf_ord.Value);
ecg_bp = causal_notch_chain(ecg_bp, rec.Fs, parse_csv_num(ui.notch_ef.Value));

if ui.qrs_blank.Value
    [ecg_for_coh, mask] = qrs_blank(ecg_bp, rec.Fs, 0.100);
else
    ecg_for_coh = ecg_bp; mask = true(size(ecg_bp));
end

[ref_names, X] = build_ref_matrix(rec.refs);
X = X(mask, :);
[g2_M, f] = miso_coherence(ecg_for_coh(mask), X, rec.Fs, ui.welch_seg.Value);

ax = ui.ax_wiener; cla(ax); hold(ax,'on');
plot(ax, f, g2_M, 'Color',[0.30 0.85 0.50], 'LineWidth', 1.4);
yline(ax, 0.95, 'r--','full cancel');
yline(ax, 0.70, 'b--','high coh');
hold(ax,'off'); ylim(ax,[0 1]); xlim(ax,[0 min(40, rec.Fs/2)]);
title(ax, sprintf('MISO Wiener coherence (PCA-capped, %d refs)', numel(ref_names)));

bands.lf     = [0.5 2];
bands.walk   = [2 8];
bands.mid    = [8 20];
bands.hf     = [20 40];
bands.motion = [0.5 20];
[Pe, fe] = welch_psd_aligned(ecg_for_coh(mask), rec.Fs, f);

bn = fieldnames(bands);
T = cell(numel(bn), 4);
for i = 1:numel(bn)
    bf = bn{i};
    msk_b = (f >= bands.(bf)(1)) & (f <= bands.(bf)(2));
    if ~any(msk_b)
        T(i,:) = {bf, NaN, NaN, NaN}; continue;
    end
    P = Pe(msk_b); g = g2_M(msk_b);
    if sum(P) < eps, ratio = 1; else, ratio = sum(P .* (1 - g)) / sum(P); end
    ratio = max(ratio, 1e-12);
    ceiling = -10*log10(ratio);
    fhi = sum(P(g >= 0.70)) / max(sum(P), eps);
    ffull = sum(P(g >= 0.95)) / max(sum(P), eps);
    T(i,:) = {bf, ceiling, 100*fhi, 100*ffull};
end
ui.tbl_wiener.Data = T;
ui.tbl_wiener.ColumnName = {'band','ceiling (dB)','frac >=0.70 (%)','frac >=0.95 (%)'};
addStyle(ui.tbl_wiener, uistyle('FontColor',[0.85 0.85 0.85]));
end

function on_run_batch(fig)
files = fig.UserData.batch_files;
if isempty(files)
    uialert(fig, 'No files selected. Use "Pick batch files..." first.', 'Empty batch');
    return;
end
ui = fig.UserData.ui;
folder = uigetdir(pwd, 'Pick output folder for batch CSV');
if isequal(folder, 0), return; end

rows = cell(numel(files), 0);
hdr  = {'file','status','Fs','duration_s','n_refs','ecg_band_rms_mV', ...
        'ceil_lf_dB','ceil_walk_dB','ceil_mid_dB','ceil_motion_dB', ...
        'fracHi_motion','fracFull_motion'};
T = cell(numel(files), numel(hdr));

for k = 1:numel(files)
    fp = files{k};
    [~, name, ext] = fileparts(fp);
    fprintf('[%d/%d] %s\n', k, numel(files), [name ext]);
    try
        rec = load_recording(fp, ui.ads_lsb.Value, ui.ad_lsb.Value);
        [ecg, ~] = pick_lead(rec, ui.lead_dd.Value);
        ecg_bp = causal_bpf(ecg, rec.Fs, ui.bpf_lo.Value, ui.bpf_hi.Value, ui.bpf_ord.Value);
        ecg_bp = causal_notch_chain(ecg_bp, rec.Fs, parse_csv_num(ui.notch_ef.Value));
        if ui.qrs_blank.Value
            [ecg_q, mask] = qrs_blank(ecg_bp, rec.Fs, 0.100);
        else
            ecg_q = ecg_bp; mask = true(size(ecg_bp));
        end
        [ref_names, X] = build_ref_matrix(rec.refs);
        X = X(mask, :);
        [g2_M, f] = miso_coherence(ecg_q(mask), X, rec.Fs, ui.welch_seg.Value);
        [Pe, ~] = welch_psd_aligned(ecg_q(mask), rec.Fs, f);

        bands = {[0.5 2], [2 8], [8 20], [0.5 20]};
        ceil_db = nan(1, 4);
        for b = 1:numel(bands)
            msk_b = (f >= bands{b}(1)) & (f <= bands{b}(2));
            if any(msk_b)
                P = Pe(msk_b); g = g2_M(msk_b);
                ratio = sum(P .* (1 - g)) / max(sum(P), eps);
                ratio = max(ratio, 1e-12);
                ceil_db(b) = -10*log10(ratio);
            end
        end
        msk_m = (f >= 0.5) & (f <= 20);
        Pm = Pe(msk_m); gm = g2_M(msk_m);
        fHi = sum(Pm(gm >= 0.70)) / max(sum(Pm), eps);
        fFull = sum(Pm(gm >= 0.95)) / max(sum(Pm), eps);

        T(k, :) = {[name ext], 'ok', rec.Fs, rec.duration_s, numel(ref_names), ...
                   rms(ecg_bp), ceil_db(1), ceil_db(2), ceil_db(3), ceil_db(4), ...
                   100*fHi, 100*fFull};
    catch e
        T(k, :) = {[name ext], ['skip:' e.message], NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN};
        fprintf('  skipped: %s\n', e.message);
    end
end

ui.tbl_batch.Data = T;
ui.tbl_batch.ColumnName = hdr;
addStyle(ui.tbl_batch, uistyle('FontColor',[0.85 0.85 0.85]));

ts = char(datetime('now', 'Format','yyyyMMdd_HHmmss'));
out = fullfile(folder, sprintf('signal_diagnose_batch_%s.csv', ts));
fid = fopen(out, 'w');
if fid > 0
    fprintf(fid, '%s\n', strjoin(hdr, ','));
    for k = 1:size(T,1)
        row = T(k, :);
        cells = cell(size(row));
        for c = 1:numel(row)
            v = row{c};
            if ischar(v) || isstring(v)
                cells{c} = char(v);
            elseif isnumeric(v) && isscalar(v) && isnan(v)
                cells{c} = '';
            else
                cells{c} = num2str(v);
            end
        end
        fprintf(fid, '%s\n', strjoin(cells, ','));
    end
    fclose(fid);
    uialert(fig, sprintf('Wrote %s', out), 'Batch done', 'Icon','success');
end
end


%% ───────────────────────────────────────────────────────────────────────
%% Recording loader (handles 17/20/21/22/23 column formats)
%% ───────────────────────────────────────────────────────────────────────

function rec = load_recording(fpath, ads_lsb_mv, ad_lsb_mv)
raw = readmatrix(fpath, 'FileType','text');
if isempty(raw), error('No numeric rows in file.'); end
[~, ncols] = size(raw);
if ~ismember(ncols, [17 20 21 22 23])
    error('Unsupported column count %d (need 17/20/21/22/23).', ncols);
end

% Belt-and-braces u32 -> i32 fixup for any column past timestamp.
data = double(raw);
for c = 2:ncols
    bad = data(:, c) > 2147483647;
    data(bad, c) = data(bad, c) - 4294967296;
end

% Drop malformed rows. ADS1293 ECG columns (24-bit, up to ±8.4e6) are excluded
% from the range check — only IMU columns (16-bit, max ±32768) are checked.
if ncols == 21
    sig_cols = 4:21;
elseif ncols == 23
    sig_cols = 3:20;
else
    sig_cols = 2:min(ncols, 20);
end
bad_rows = any(abs(data(:, sig_cols)) > 1e6, 2);
data(bad_rows, :) = [];
if isempty(data), error('All rows filtered as malformed.'); end

t_us = data(:, 1);
wrap = find(diff(t_us) < 0, 1);
if ~isempty(wrap), t_us(wrap+1:end) = t_us(wrap+1:end) + 4294967296; end
t_us = t_us - t_us(1);
t_s = t_us / 1e6;
dt = diff(t_s); dt = dt(dt > 0);
Fs = 1 / median(dt);
if ~isfinite(Fs) || Fs < 50 || Fs > 1500
    error('Implausible Fs=%.3f', Fs);
end

% Layout-specific extraction
switch ncols
    case {17}
        ecg_mV = data(:,2) * ad_lsb_mv;
        ch1 = ecg_mV; ch2 = []; imu_off = 3;
    case {20, 22}
        ecg_mV = data(:,2) * ad_lsb_mv;
        ch1 = ecg_mV; ch2 = []; imu_off = 3;
    case 21
        % t_us, ads_ch1, ads_ch2, IMU0..IMU2 (6-axis each)
        ch1 = data(:,2) * ads_lsb_mv;
        ch2 = data(:,3) * ads_lsb_mv;
        ecg_mV = ch1;        % default; pick_lead handles selection
        imu_off = 4;
    case 23
        ch1 = data(:,2) * ad_lsb_mv;
        ch2 = []; imu_off = 3;
        ecg_mV = ch1;
end

% IQR despike: ADS1293 traces have transient spikes that swamp Y-axis
% autoscale and inflate variance estimates. Without this, ECG features
% are invisible. Same despike used by phase2_analyzer.
ch1 = despike_ecg(ch1, Fs);
if ~isempty(ch2), ch2 = despike_ecg(ch2, Fs); end
ecg_mV = ch1;

% IMU columns
LSB_PER_G = 16384; LSB_PER_DPS = 131;
DC_ALPHA  = 0.995;
hp = @(x) x - filter([1-DC_ALPHA], [1 -DC_ALPHA], x);

% IMU0
ax0 = hp(data(:, imu_off  )/LSB_PER_G);
ay0 = hp(data(:, imu_off+1)/LSB_PER_G);
az0 = hp(data(:, imu_off+2)/LSB_PER_G);
gx0 = hp(data(:, imu_off+3)/LSB_PER_DPS);
gy0 = hp(data(:, imu_off+4)/LSB_PER_DPS);
gz0 = hp(data(:, imu_off+5)/LSB_PER_DPS);

% IMU1
o1 = imu_off + 6;
ax1 = hp(data(:, o1  )/LSB_PER_G);
ay1 = hp(data(:, o1+1)/LSB_PER_G);
az1 = hp(data(:, o1+2)/LSB_PER_G);
gx1 = hp(data(:, o1+3)/LSB_PER_DPS);
gy1 = hp(data(:, o1+4)/LSB_PER_DPS);
gz1 = hp(data(:, o1+5)/LSB_PER_DPS);

% IMU2 (only 3-axis if ncols=17)
o2 = imu_off + 12;
if ncols == 17
    ax2 = hp(data(:, o2  )/LSB_PER_G);
    ay2 = hp(data(:, o2+1)/LSB_PER_G);
    az2 = hp(data(:, o2+2)/LSB_PER_G);
    gx2 = zeros(size(ax2)); gy2 = zeros(size(ax2)); gz2 = zeros(size(ax2));
else
    if (o2 + 5) <= size(data, 2)
        ax2 = hp(data(:, o2  )/LSB_PER_G);
        ay2 = hp(data(:, o2+1)/LSB_PER_G);
        az2 = hp(data(:, o2+2)/LSB_PER_G);
        gx2 = hp(data(:, o2+3)/LSB_PER_DPS);
        gy2 = hp(data(:, o2+4)/LSB_PER_DPS);
        gz2 = hp(data(:, o2+5)/LSB_PER_DPS);
    else
        ax2 = zeros(size(ax0)); ay2 = ax2; az2 = ax2;
        gx2 = ax2; gy2 = ax2; gz2 = ax2;
    end
end

refs.ax0 = ax0; refs.ay0 = ay0; refs.az0 = az0;
refs.gx0 = gx0; refs.gy0 = gy0; refs.gz0 = gz0;
refs.ax1 = ax1; refs.ay1 = ay1; refs.az1 = az1;
refs.gx1 = gx1; refs.gy1 = gy1; refs.gz1 = gz1;
refs.ax2 = ax2; refs.ay2 = ay2; refs.az2 = az2;
refs.gx2 = gx2; refs.gy2 = gy2; refs.gz2 = gz2;
refs.mag0  = sqrt(ax0.^2 + ay0.^2 + az0.^2);
refs.mag1  = sqrt(ax1.^2 + ay1.^2 + az1.^2);
refs.mag2  = sqrt(ax2.^2 + ay2.^2 + az2.^2);
refs.gmag0 = sqrt(gx0.^2 + gy0.^2 + gz0.^2);
refs.gmag1 = sqrt(gx1.^2 + gy1.^2 + gz1.^2);
refs.gmag2 = sqrt(gx2.^2 + gy2.^2 + gz2.^2);
refs.dax01 = ax0 - ax1;  refs.day01 = ay0 - ay1;  refs.daz01 = az0 - az1;
refs.dgx01 = gx0 - gx1;  refs.dgy01 = gy0 - gy1;  refs.dgz01 = gz0 - gz1;
refs.dax02 = ax0 - ax2;  refs.day02 = ay0 - ay2;  refs.daz02 = az0 - az2;
refs.dax12 = ax1 - ax2;  refs.day12 = ay1 - ay2;  refs.daz12 = az1 - az2;

rec.path     = fpath;
rec.ncols    = ncols;
rec.t_s      = t_s;
rec.Fs       = Fs;
rec.N        = numel(t_s);
rec.duration_s = t_s(end);
rec.ecg_mV   = ecg_mV;
rec.ch1_mV   = ch1;
rec.ch2_mV   = ch2;
rec.refs     = refs;
end

function [ecg, label] = pick_lead(rec, choice)
switch choice
    case 'CH1 (ADS / AD8233)'
        ecg = rec.ch1_mV; label = 'CH1';
    case 'CH2 (ADS only)'
        if ~isempty(rec.ch2_mV), ecg = rec.ch2_mV; label = 'CH2';
        else, ecg = rec.ch1_mV; label = 'CH1 (CH2 absent)'; end
    case 'CH1-CH2 diff'
        if ~isempty(rec.ch2_mV)
            ecg = rec.ch1_mV - rec.ch2_mV; label = 'CH1-CH2';
        else
            ecg = rec.ch1_mV; label = 'CH1 (no diff possible)';
        end
    otherwise
        ecg = rec.ch1_mV; label = 'CH1';
end
end


%% ───────────────────────────────────────────────────────────────────────
%% Filtering helpers (causal)
%% ───────────────────────────────────────────────────────────────────────

function y = causal_bpf(x, Fs, lo, hi, ord)
y = x(:);
nyq = Fs / 2;
hi = min(hi, 0.95 * nyq);
lo = max(lo, 0.005);
if lo >= hi, return; end
[b, a] = butter(ord, [lo hi] / nyq, 'bandpass');
% ADS1293 has a large DC offset (~1000s of mV). Subtracting the first sample
% before filtering prevents a 20-30 s initial transient that would corrupt
% the first portion of every recording. The BPF removes DC regardless,
% so the output is identical after transient decay.
y = filter(b, a, y - y(1));
end

function y = causal_notch_chain(x, Fs, freqs)
y = x(:);
for i = 1:numel(freqs)
    f0 = freqs(i);
    if f0 <= 0 || f0 >= Fs/2 - 1, continue; end
    bw  = 2;        % notch -3dB width (Hz)
    Q   = f0 / bw;
    [b, a] = iirnotch(f0/(Fs/2), 1/Q);
    y = filter(b, a, y);
end
end


%% ───────────────────────────────────────────────────────────────────────
%% QRS blanking (Pan-Tompkins-lite envelope detector)
%% ───────────────────────────────────────────────────────────────────────

function [y, mask] = qrs_blank(x, Fs, half_window_s)
x = x(:);
% Bandpass to QRS band (5-15 Hz), differentiate, square, integrate
[b1, a1] = butter(2, [5 15]/(Fs/2), 'bandpass');
xf = filter(b1, a1, x);
xd = [0; diff(xf)];
xs = xd.^2;
win = max(3, round(0.150 * Fs));
xi = movmean(xs, win);
% Adaptive threshold
th = 0.3 * movmax(xi, max(round(2*Fs), 5));
locs = find(xi(2:end-1) > xi(1:end-2) & xi(2:end-1) > xi(3:end) & xi(2:end-1) > th(2:end-1)) + 1;
% Refractory: enforce min 250 ms between R-peaks
if numel(locs) > 1
    keep = true(size(locs));
    last = locs(1);
    for k = 2:numel(locs)
        if (locs(k) - last) < round(0.25 * Fs)
            keep(k) = false;
        else
            last = locs(k);
        end
    end
    locs = locs(keep);
end
% Build mask
hw = round(half_window_s * Fs);
mask = true(size(x));
for k = 1:numel(locs)
    a = max(1, locs(k) - hw);
    b = min(numel(x), locs(k) + hw);
    mask(a:b) = false;
end
y = x;          % returned full signal; use mask to subset for Welch
end


%% ───────────────────────────────────────────────────────────────────────
%% Welch PSD / coherence / MISO
%% ───────────────────────────────────────────────────────────────────────

function [P, f] = welch_psd(x, Fs, seg_s)
x = x(:);
nfft = max(256, 2^nextpow2(round(Fs * seg_s)));
nfft = min(nfft, numel(x));
nover = floor(nfft/2);
win = hanning_safe(nfft);
P = welch_psd_window(x, win, nover, nfft, Fs);
f = (0:nfft/2)' * (Fs / nfft);
end

function [P, f] = welch_psd_aligned(x, Fs, f_target)
nfft = (numel(f_target) - 1) * 2;
nfft = max(nfft, 256);
win = hanning_safe(nfft);
nover = floor(nfft/2);
P = welch_psd_window(x, win, nover, nfft, Fs);
f = (0:nfft/2)' * (Fs / nfft);
end

function P = welch_psd_window(x, win, nover, nfft, Fs)
x = x(:);
N = numel(x);
step = nfft - nover;
nseg = max(1, floor((N - nover) / step));
U = sum(win.^2);
P = zeros(nfft/2 + 1, 1);
for s = 0:nseg-1
    seg = x(s*step + (1:nfft)) .* win;
    F = fft(seg);
    F = F(1:nfft/2 + 1);
    P = P + abs(F).^2;
end
P = P / (nseg * U * Fs);
P(2:end-1) = P(2:end-1) * 2;
end

function [g2, f] = welch_coherence(x, y, Fs, seg_s)
x = x(:); y = y(:);
N = min(numel(x), numel(y)); x = x(1:N); y = y(1:N);
nfft = max(256, 2^nextpow2(round(Fs * seg_s)));
nfft = min(nfft, N);
nover = floor(nfft/2);
win = hanning_safe(nfft);

step = nfft - nover;
nseg = max(1, floor((N - nover) / step));
U = sum(win.^2);
Sxx = zeros(nfft/2 + 1, 1);
Syy = zeros(nfft/2 + 1, 1);
Sxy = zeros(nfft/2 + 1, 1);
for s = 0:nseg-1
    sx = x(s*step + (1:nfft)) .* win;
    sy = y(s*step + (1:nfft)) .* win;
    Fx = fft(sx); Fx = Fx(1:nfft/2 + 1);
    Fy = fft(sy); Fy = Fy(1:nfft/2 + 1);
    Sxx = Sxx + abs(Fx).^2;
    Syy = Syy + abs(Fy).^2;
    Sxy = Sxy + Fx .* conj(Fy);
end
Sxx = Sxx / (nseg * U * Fs);
Syy = Syy / (nseg * U * Fs);
Sxy = Sxy / (nseg * U * Fs);
g2 = abs(Sxy).^2 ./ max(Sxx .* Syy, eps);
g2 = max(0, min(1, g2));
f = (0:nfft/2)' * (Fs / nfft);
end

function [g2_M, f] = miso_coherence(d, X, Fs, seg_s)
d = d(:);
[N, P] = size(X);
if N ~= numel(d), error('miso_coherence length mismatch'); end

nfft = max(256, 2^nextpow2(round(Fs * seg_s)));
nfft = min(nfft, N);
nover = floor(nfft/2);
step = nfft - nover;
nseg = max(1, floor((N - nover) / step));

% PCA rank cap. Keep well below nseg/2 so the spectral matrix is not rank-deficient.
% Hard cap at 4 components regardless of recording length — more components inflate γ²
% towards 1 through overfitting without adding diagnostic value.
K_max = max(1, min(4, floor(nseg / 4)));
if P > K_max
    Xc = X - mean(X, 1);
    [~, ~, V] = svd(Xc, 'econ');
    X = Xc * V(:, 1:K_max);
    P = K_max;
end

win = hanning_safe(nfft);
f = (0:nfft/2)' * (Fs / nfft);

S_dd = welch_psd_window(d, win, nover, nfft, Fs);
S_xx = zeros(numel(f), P, P);
S_dx = zeros(numel(f), P);
for i = 1:P
    S_dx(:, i) = welch_csd_window(d, X(:, i), win, nover, nfft, Fs);
    for j = i:P
        Cij = welch_csd_window(X(:, i), X(:, j), win, nover, nfft, Fs);
        S_xx(:, i, j) = Cij;
        if j > i, S_xx(:, j, i) = conj(Cij); end
    end
end

g2_M = zeros(numel(f), 1);
% 5% diagonal loading: prevents spectral matrix blow-up when K_seg is small
% relative to P. Without this, γ²_MISO saturates at 1 due to inversion noise.
reg = 0.05;
for k = 1:numel(f)
    Sxx = squeeze(S_xx(k, :, :));
    Sdx = squeeze(S_dx(k, :)).';
    tr = max(real(trace(Sxx)) / max(P, 1), eps);
    Sxx = (Sxx + Sxx')/2 + reg * tr * eye(P);
    num = real(Sdx' * (Sxx \ Sdx));
    den = max(real(S_dd(k)), eps);
    g2_M(k) = max(0, min(1, num / den));
end
end

function S = welch_csd_window(x, y, win, nover, nfft, Fs)
x = x(:); y = y(:);
N = min(numel(x), numel(y));
x = x(1:N); y = y(1:N);
step = nfft - nover;
nseg = max(1, floor((N - nover) / step));
U = sum(win.^2);
S = zeros(nfft/2 + 1, 1);
for s = 0:nseg-1
    sx = x(s*step + (1:nfft)) .* win;
    sy = y(s*step + (1:nfft)) .* win;
    Fx = fft(sx); Fy = fft(sy);
    Fx = Fx(1:nfft/2 + 1); Fy = Fy(1:nfft/2 + 1);
    S = S + Fx .* conj(Fy);
end
S = S / (nseg * U * Fs);
S(2:end-1) = S(2:end-1) * 2;
end


%% ───────────────────────────────────────────────────────────────────────
%% Reference matrix builder
%% ───────────────────────────────────────────────────────────────────────

function [names, X] = build_ref_matrix(refs)
candidates = {'ax0','ay0','az0','gx0','gy0','gz0', ...
              'ax1','ay1','az1','gx1','gy1','gz1', ...
              'ax2','ay2','az2','gx2','gy2','gz2', ...
              'mag0','mag1','mag2','gmag0','gmag1','gmag2', ...
              'dax01','day01','daz01','dgx01','dgy01','dgz01'};
names = {};
N = numel(refs.ax0);
X = [];
for i = 1:numel(candidates)
    c = candidates{i};
    if isfield(refs, c) && numel(refs.(c)) == N
        v = refs.(c);
        if std(v) > 1e-8
            names{end+1} = c; %#ok<AGROW>
            X = [X, v(:)]; %#ok<AGROW>
        end
    end
end
% Z-score for numerical stability of MISO
mu = mean(X, 1, 'omitnan');
sg = std(X, 0, 1, 'omitnan');
sg(sg < eps) = 1;
X = (X - mu) ./ sg;
end


%% ───────────────────────────────────────────────────────────────────────
%% Misc helpers
%% ───────────────────────────────────────────────────────────────────────

function p = default_params()
p.welch_seg_s = 4;
end

function v = parse_csv_num(str)
str = strtrim(str);
if isempty(str), v = []; return; end
toks = strsplit(str, ',');
v = zeros(1, numel(toks));
for i = 1:numel(toks)
    v(i) = str2double(strtrim(toks{i}));
end
v = v(isfinite(v));
end

function w = hanning_safe(N)
n = (0:N-1)';
w = 0.5 - 0.5*cos(2*pi*n/(N-1));
end

function fit_ylim_to_window(ax)
if isempty(ax.Children), return; end
xl = ax.XLim;
y_all = [];
for kk = 1:numel(ax.Children)
    h = ax.Children(kk);
    if isprop(h,'XData') && isprop(h,'YData')
        x = h.XData(:); y = h.YData(:);
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

function y = apply_display_baseline(ecg, Fs)
% Removes baseline wander with a double movmedian (same method as phase2_analyzer).
% QRS window 0.20 s removes the QRS peak from the baseline estimate;
% T-wave window 0.80 s then removes slower wander.
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
qrs_win = odd_window_bl(0.20, Fs, numel(ecg));
tw_win  = odd_window_bl(0.80, Fs, numel(ecg));
baseline = movmedian(ecg, qrs_win, 'Endpoints','shrink');
baseline = movmedian(baseline, tw_win, 'Endpoints','shrink');
y = ecg - baseline;
end

function w = odd_window_bl(seconds, Fs, N)
w = max(3, round(seconds * Fs));
w = min(w, max(3, N));
if mod(w,2) == 0, w = max(3, w - 1); end
end

function ecg_clean = despike_ecg(ecg, Fs)
% IQR/MAD despike. Removes outliers >8 MAD from a 0.25 s movmedian baseline,
% interpolates linearly across the gaps. Keeps QRS intact, removes transients
% that ruin Y-axis autoscale and inflate variance estimates on ADS1293 data.
ecg = double(ecg(:));
if numel(ecg) < 8 || ~isfinite(Fs) || Fs <= 0
    ecg_clean = ecg; return;
end
win = max(3, round(0.25 * Fs));
if mod(win, 2) == 0, win = win + 1; end
win = min(win, max(3, numel(ecg)));
baseline = movmedian(ecg, win, 'Endpoints','shrink');
residual = ecg - baseline;
med_res = median(residual, 'omitnan');
mad_val = median(abs(residual - med_res), 'omitnan');
if ~isfinite(mad_val) || mad_val < 1e-12
    ecg_clean = ecg; return;
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

function addlabel(lay, r, c, txt)
l = uilabel(lay,'Text',txt,'FontColor',[0.85 0.85 0.85],'FontSize',9);
l.Layout.Row = r; l.Layout.Column = c;
end

function style_axes(ax, xl, yl, t)
ax.XLabel.String = xl; ax.YLabel.String = yl; ax.Title.String = t;
ax.XColor = [0.7 0.7 0.7]; ax.YColor = [0.7 0.7 0.7];
ax.XLabel.Color = [0.7 0.7 0.7]; ax.YLabel.Color = [0.7 0.7 0.7];
ax.Color = [0.08 0.08 0.10]; ax.GridColor = [0.3 0.3 0.3];
ax.Title.Color = [0.9 0.9 0.9];
grid(ax, 'on');
end
