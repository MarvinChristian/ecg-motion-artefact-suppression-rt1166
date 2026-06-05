function ecg_imu_scroll_gui()
% ECG_IMU_SCROLL_GUI  Scrolling viewer: CH1, CH2, and 6 separate IMU axes.
%
%   Purpose: visual timing inspection between ECG artefact and IMU signals.
%   Layout (top to bottom): CH1, CH2, ax, ay, az, gx, gy, gz.
%   ECG axes auto-scale to the current window.
%   IMU axes are fixed to the full-recording min/max so scale is stable.
%
%   Controls:
%     Load file  — txt/csv, 17/20/21/22/23/24-col formats
%     Window (s) — view width
%     IMU        — select IMU device 0 / 1 / 2
%     Slider     — scroll; ← → step 20%;  ↑ ↓ widen/narrow 50%

%% Constants
LSB_G   = 16384;
LSB_DPS = 131;
ADS_MV  = 1400 / 8388607;
AD_MV   = 1800 / 4096;

%% Colours
C_BG  = [0.10 0.11 0.13];
C_AX  = [0.11 0.12 0.14];
C_FG  = [0.85 0.85 0.85];
C_DIM = [0.55 0.60 0.65];
C_BTN = [0.22 0.44 0.64];
C_IN  = [0.17 0.17 0.20];
C_CH1 = [0.35 0.75 0.95];
C_CH2 = [0.95 0.65 0.30];

% One colour per IMU row: ax ay az gx gy gz
ACOLORS = [
    0.95 0.38 0.38;   % ax
    0.38 0.88 0.48;   % ay
    0.38 0.58 0.95;   % az
    0.95 0.78 0.22;   % gx
    0.78 0.38 0.95;   % gy
    0.30 0.90 0.88;   % gz
];
ALABELS = {'ax (g)','ay (g)','az (g)','gx (dps)','gy (dps)','gz (dps)'};

%% Figure geometry
FW   = 1500;
FH   = 980;
PAD  = 5;
TB   = 40;    % top bar
SB   = 44;    % bottom slider bar
AVAIL = FH - TB - SB - PAD * 10;   % 10 gaps for 8 axes + top/bottom

ECG_H = floor(AVAIL * 0.145);      % CH1 and CH2 slightly taller
IMU_H = floor((AVAIL - 2*ECG_H) / 6);

% Axis left edge and width
AX_L = PAD;
AX_W = FW - PAD*2;

% Y positions — build from bottom upward
% order bottom→top: gz gy gx az ay ax CH2 CH1
heights = [IMU_H IMU_H IMU_H IMU_H IMU_H IMU_H ECG_H ECG_H];
ypos    = zeros(1,8);
ypos(1) = PAD + SB;
for k = 2:8
    ypos(k) = ypos(k-1) + heights(k-1) + PAD;
end
% ypos(1)=gz, ypos(2)=gy, ..., ypos(7)=CH2, ypos(8)=CH1

%% Build figure
fig = uifigure('Name','ECG + IMU Scroll Viewer', ...
    'Position',[40 40 FW FH], 'Color',C_BG, ...
    'KeyPressFcn', @on_key);

%% Axes — 8 total
make_ax = @(yp, h) uiaxes(fig, 'Position',[AX_L yp AX_W h], ...
    'Color',C_AX, 'XColor',C_DIM, 'YColor',C_DIM, ...
    'FontSize',8, 'GridColor',[0.22 0.22 0.26], 'GridAlpha',0.45, ...
    'XGrid','on', 'YGrid','on', 'Box','on', 'NextPlot','add');

ui.ax_ch1 = make_ax(ypos(8), ECG_H);
ui.ax_ch2 = make_ax(ypos(7), ECG_H);
ui.ax_imu = arrayfun(@(k) make_ax(ypos(k), IMU_H), 1:6);

% Suppress x tick labels except bottom axis
ui.ax_ch1.XTickLabel = {};
ui.ax_ch2.XTickLabel = {};
for k = 2:6
    ui.ax_imu(k).XTickLabel = {};
end
xlabel(ui.ax_imu(1), 'Time (s)', 'Color',C_DIM, 'FontSize',8);

% Y-axis labels
ylabel(ui.ax_ch1, 'CH1', 'Color',C_CH1, 'FontSize',8);
ylabel(ui.ax_ch2, 'CH2', 'Color',C_CH2, 'FontSize',8);
for k = 1:6
    ylabel(ui.ax_imu(k), ALABELS{7-k}, 'Color',ACOLORS(7-k,:), 'FontSize',8);
end

%% Top bar
TB_Y = FH - TB + 4;

uibutton(fig, 'Text','Load file...', ...
    'Position',[PAD TB_Y 110 30], ...
    'BackgroundColor',C_BTN, 'FontColor','w', 'FontWeight','bold', ...
    'ButtonPushedFcn', @(~,~) on_load(fig));

ui.file_lbl = uilabel(fig, 'Text','No file loaded.', ...
    'Position',[128 TB_Y 840 30], 'FontColor',C_DIM, 'FontSize',9);

uilabel(fig, 'Text','Window (s):', ...
    'Position',[975 TB_Y 78 30], 'FontColor',C_DIM, 'FontSize',9);
ui.win_ef = uieditfield(fig, 'numeric', ...
    'Value',5, 'Limits',[0.25 120], ...
    'Position',[1056 TB_Y 60 28], ...
    'BackgroundColor',C_IN, 'FontColor',C_FG, ...
    'ValueChangedFcn', @(src,~) on_win(fig, src.Value));

uilabel(fig, 'Text','IMU:', ...
    'Position',[1130 TB_Y 36 30], 'FontColor',C_DIM, 'FontSize',9);
ui.imu_dd = uidropdown(fig, ...
    'Items',{'IMU 0','IMU 1','IMU 2'}, 'Value','IMU 0', ...
    'Position',[1166 TB_Y 78 28], ...
    'BackgroundColor',C_IN, 'FontColor',C_FG, 'FontSize',9, ...
    'ValueChangedFcn', @(src,~) on_imu(fig, src.Value));

uilabel(fig, 'Text','← → scroll   ↑ ↓ zoom', ...
    'Position',[1256 TB_Y 220 30], 'FontColor',C_DIM, 'FontSize',8);

%% Bottom slider bar
ui.slider = uislider(fig, ...
    'Limits',[0 1], 'Value',0, ...
    'Position',[PAD PAD+22 FW-PAD*2-150 3], ...
    'ValueChangedFcn',  @(src,~) on_slide(fig, src.Value), ...
    'ValueChangingFcn', @(src,~) on_slide(fig, src.Value));

ui.time_lbl = uilabel(fig, 'Text','–', ...
    'Position',[FW-148 PAD+10 144 24], ...
    'FontColor',C_DIM, 'FontSize',9);

%% Store state
st.rec   = [];
st.t0    = 0;
st.win   = 5;
st.imu   = 0;

fig.UserData.st      = st;
fig.UserData.ui      = ui;
fig.UserData.ACOLORS = ACOLORS;
fig.UserData.ALABELS = ALABELS;
fig.UserData.C_CH1   = C_CH1;
fig.UserData.C_CH2   = C_CH2;
fig.UserData.consts  = struct('LSB_G',LSB_G,'LSB_DPS',LSB_DPS, ...
                               'ADS_MV',ADS_MV,'AD_MV',AD_MV);


%% Callbacks
function on_load(fig)
[name, path] = uigetfile({'*.txt;*.csv','Recording (*.txt,*.csv)'},'Select recording');
if isequal(name,0), return; end
try
    rec = load_rec(fullfile(path,name), fig.UserData.consts);
catch e
    uialert(fig, e.message, 'Load failed'); return;
end
st = fig.UserData.st;
st.rec = rec;
st.t0  = 0;
fig.UserData.st = st;
ui = fig.UserData.ui;
ui.file_lbl.Text = sprintf('%s  |  %d col  Fs=%.1f Hz  dur=%.1f s  N=%d', ...
    name, rec.ncols, rec.Fs, rec.duration_s, rec.N);
ui.slider.Limits = [0, max(0, rec.duration_s - st.win)];
ui.slider.Value  = 0;
fig.UserData.ui = ui;
refresh(fig);
end

function on_win(fig, val)
st = fig.UserData.st;
st.win = val;
if ~isempty(st.rec)
    lim = max(0, st.rec.duration_s - val);
    fig.UserData.ui.slider.Limits = [0 lim];
    st.t0 = min(st.t0, lim);
    fig.UserData.ui.slider.Value = st.t0;
end
fig.UserData.st = st;
refresh(fig);
end

function on_imu(fig, val)
st = fig.UserData.st;
st.imu = str2double(val(end));
fig.UserData.st = st;
refresh(fig);
end

function on_slide(fig, val)
st = fig.UserData.st;
st.t0 = val;
fig.UserData.st = st;
refresh(fig);
end

function on_key(fig, evt)
st = fig.UserData.st;
if isempty(st.rec), return; end
step = st.win * 0.2;
maxT = max(0, st.rec.duration_s - st.win);
switch evt.Key
    case 'rightarrow', st.t0 = min(st.t0 + step, maxT);
    case 'leftarrow',  st.t0 = max(st.t0 - step, 0);
    case 'uparrow'
        st.win = min(st.win * 1.5, 120);
        fig.UserData.ui.win_ef.Value = st.win;
        maxT = max(0, st.rec.duration_s - st.win);
        fig.UserData.ui.slider.Limits = [0 maxT];
        st.t0 = min(st.t0, maxT);
    case 'downarrow'
        st.win = max(st.win / 1.5, 0.25);
        fig.UserData.ui.win_ef.Value = st.win;
        maxT = max(0, st.rec.duration_s - st.win);
        fig.UserData.ui.slider.Limits = [0 maxT];
end
fig.UserData.ui.slider.Value = st.t0;
fig.UserData.st = st;
refresh(fig);
end


%% Refresh
function refresh(fig)
st     = fig.UserData.st;
ui     = fig.UserData.ui;
rec    = st.rec;
ACOLS  = fig.UserData.ACOLORS;

if isempty(rec), return; end

t0   = st.t0;
t1   = t0 + st.win;
mask = rec.t_s >= t0 & rec.t_s <= t1;
t    = rec.t_s(mask);

% CH1 — auto-scale to current window, data centred by MATLAB default
cla(ui.ax_ch1);
plot(ui.ax_ch1, t, rec.ch1(mask), 'Color',fig.UserData.C_CH1, 'LineWidth',0.7);
xlim(ui.ax_ch1, [t0 t1]);
% Let MATLAB auto-scale y so the ECG sits naturally without normalisation

% CH2
cla(ui.ax_ch2);
if ~isempty(rec.ch2)
    plot(ui.ax_ch2, t, rec.ch2(mask), 'Color',fig.UserData.C_CH2, 'LineWidth',0.7);
else
    text(ui.ax_ch2, mean([t0 t1]), 0, 'CH2 absent', ...
        'Color',fig.UserData.C_CH2, 'HorizontalAlignment','center', 'FontSize',8);
end
xlim(ui.ax_ch2, [t0 t1]);

% IMU — 6 separate axes, y fixed to full-recording limits
idx   = st.imu + 1;
idata = {rec.imu(idx).ax, rec.imu(idx).ay, rec.imu(idx).az, ...
         rec.imu(idx).gx, rec.imu(idx).gy, rec.imu(idx).gz};
ilims = squeeze(rec.imu_lims(idx,:,:));   % [6×2]: rows=ax..gz, cols=min/max

% axes are ordered bottom→top in ui.ax_imu: [gz gy gx az ay ax]
% so ui.ax_imu(k) displays axis (7-k): k=1→gz(6), k=6→ax(1)
for k = 1:6
    sig_idx = 7 - k;   % 1=ax..6=gz; k=1→gz(6), k=6→ax(1)
    ax = ui.ax_imu(k);
    cla(ax);
    plot(ax, t, idata{sig_idx}(mask), 'Color',ACOLS(sig_idx,:), 'LineWidth',0.7);
    xlim(ax, [t0 t1]);
    mn = ilims(sig_idx, 1);
    mx = ilims(sig_idx, 2);
    if mx > mn
        ylim(ax, [mn mx]);
    end
end

ui.time_lbl.Text = sprintf('%.2f – %.2f s', t0, t1);
end


%% Recording loader
function rec = load_rec(fpath, C)
raw = readmatrix(fpath, 'FileType','text');
if isempty(raw), error('No numeric rows in file.'); end

[~, ncols] = size(raw);
if ~ismember(ncols, [17 20 21 22 23 24])
    error('Unsupported column count %d (expected 17/20/21/22/23/24).', ncols);
end

data = double(raw);
for c = 2:ncols
    bad = data(:,c) > 2147483647;
    data(bad,c) = data(bad,c) - 4294967296;
end

% Drop rows with implausible IMU values
if ncols == 21 || ncols == 24
    sig_cols = 4:21;
elseif ncols == 23
    sig_cols = 3:20;
else
    sig_cols = 2:min(ncols, 20);
end
data(any(abs(data(:,sig_cols)) > 1e6, 2), :) = [];
if isempty(data), error('All rows filtered as malformed.'); end

% Timestamps
t_us = data(:,1);
wrap = find(diff(t_us) < 0, 1);
if ~isempty(wrap)
    t_us(wrap+1:end) = t_us(wrap+1:end) + 4294967296;
end
t_us = t_us - t_us(1);
t_s  = t_us / 1e6;
dt   = diff(t_s); dt = dt(dt > 0 & dt < 0.1);
Fs   = 1 / median(dt);
if ~isfinite(Fs) || Fs < 50 || Fs > 2000
    error('Implausible Fs = %.2f Hz.', Fs);
end

% ECG columns
switch ncols
    case {17, 20, 22, 23}
        ch1 = data(:,2) * C.AD_MV;
        ch2 = [];
        imu_off = 3;
    case {21, 24}
        ch1 = data(:,2) * C.ADS_MV;
        ch2 = data(:,3) * C.ADS_MV;
        imu_off = 4;
end

ch1 = despike(ch1);
if ~isempty(ch2), ch2 = despike(ch2); end

% IMU — HP filter removes DC gravity (~0.5 Hz), preserves all motion timing
alpha = 0.995;
hp = @(x) filter(1-alpha, [1 -alpha], x);

imu(3) = struct('ax',[],'ay',[],'az',[],'gx',[],'gy',[],'gz',[]);
for d = 0:2
    o = imu_off + d*6;
    if (o+5) <= ncols
        imu(d+1).ax = hp(data(:,o  ) / C.LSB_G);
        imu(d+1).ay = hp(data(:,o+1) / C.LSB_G);
        imu(d+1).az = hp(data(:,o+2) / C.LSB_G);
        imu(d+1).gx = hp(data(:,o+3) / C.LSB_DPS);
        imu(d+1).gy = hp(data(:,o+4) / C.LSB_DPS);
        imu(d+1).gz = hp(data(:,o+5) / C.LSB_DPS);
    else
        z = zeros(size(ch1));
        imu(d+1).ax = z; imu(d+1).ay = z; imu(d+1).az = z;
        imu(d+1).gx = z; imu(d+1).gy = z; imu(d+1).gz = z;
    end
end

% Pre-compute per-axis global limits for all 3 IMU devices: [3 × 6 × 2]
% imu_lims(device, axis, 1=min/2=max)
% Store as a [3×6×2] array; in refresh we index as imu_lims(idx, :)
% Actually store as a struct field: rec.imu_lims is [3×6] struct with .mn .mx,
% but simplest is a [3×6×2] numeric: imu_lims(dev, axis, 1)=min, (dev,axis,2)=max
imu_lims = zeros(3, 6, 2);
for d = 1:3
    sigs = {imu(d).ax, imu(d).ay, imu(d).az, ...
            imu(d).gx, imu(d).gy, imu(d).gz};
    for a = 1:6
        v = sigs{a};
        v = v(isfinite(v));
        if isempty(v)
            imu_lims(d,a,:) = [-1 1];
        else
            pad = max(range(v)*0.05, 1e-4);
            imu_lims(d,a,1) = min(v) - pad;
            imu_lims(d,a,2) = max(v) + pad;
        end
    end
end

% Reshape imu_lims so refresh can index as imu_lims(idx,:) -> [6×2]
% We'll store it as a [3×6×2] and slice in refresh
rec.path       = fpath;
rec.ncols      = ncols;
rec.t_s        = t_s;
rec.Fs         = Fs;
rec.N          = numel(t_s);
rec.duration_s = t_s(end);
rec.ch1        = ch1;
rec.ch2        = ch2;
rec.imu        = imu;
rec.imu_lims   = imu_lims;   % [3 × 6 × 2]
end


function y = despike(x)
y = x;
sx = sort(x(isfinite(x)));
n  = numel(sx);
if n < 8, return; end
q1  = sx(floor(n/4));
q3  = sx(ceil(3*n/4));
thr = 6 * (q3 - q1);
if thr < 1e-9, return; end
bad = abs(x - median(x)) > thr;
if ~any(bad), return; end
idx = (1:numel(x))';
y(bad) = interp1(idx(~bad), x(~bad), idx(bad), 'linear', 'extrap');
end

end % ecg_imu_scroll_gui
