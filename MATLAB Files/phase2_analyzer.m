%% phase2_analyzer.m
%
% AUTHOR:   Marvin Christian
% TITLE:    Phase 2 — Unified ECG Filter Analysis GUI
% DATE:     12/04/2026
%
% SUMMARY:
%   Single-script GUI for bandpass and notch filter evaluation.
%   Load a Phase 1 recording, select one BPF and/or one notch filter,
%   press Evaluate. All analysis panels update automatically.
%
% DEPENDENCIES (must be in the same folder):
%   apply_biquad.m
%   apply_notch.m
%
% USAGE:
%   Run this script: phase2_analyzer
%   No other scripts need to be run first.

function phase2_analyzer()

%% ═══════════════════════════════════════════════════════════════════════
%% FILTER DEFINITIONS  (all embedded — no external coefficient file needed)
%% ═══════════════════════════════════════════════════════════════════════

BPF = build_bpf_struct();
NOTCH_NAMES = {
    'N1: IIR ×6  r=0.990',
    'N2: IIR ×6  r=0.995',
    'N3: NLMS  μ=0.005',
    'N4: NLMS  μ=0.010',
    'N5: Hybrid IIR+NLMS',
    'N6: RLS  λ=0.990',
    'N7: Sign-Sign LMS',
    'N8: Hybrid IIR+RLS',
    'N9: Auto-detect multi-freq'
};
NOTCH_TYPES = {'N1','N2','N3','N4','N5','N6','N7','N8','N9'};

%% ═══════════════════════════════════════════════════════════════════════
%% SHARED STATE
%% ═══════════════════════════════════════════════════════════════════════
state.raw            = [];
state.t_s            = [];
state.fs             = 500;
state.condition      = 'unknown';
state.loaded         = false;
state.inject_n_tones = 4;

%% ═══════════════════════════════════════════════════════════════════════
%% FIGURE AND LAYOUT
%% ═══════════════════════════════════════════════════════════════════════

fig = uifigure('Name','Phase 2 — ECG Filter Analyser', ...
               'Position',[60 60 1500 870], ...
               'Color',[0.14 0.14 0.16]);

% ── Left sidebar ──────────────────────────────────────────────────────
sidebar = uipanel(fig, ...
    'Position',[8 8 300 854], ...
    'BackgroundColor',[0.18 0.18 0.21], ...
    'BorderType','none');

% Title
uilabel(sidebar, 'Text','ECG Filter Analyser', ...
    'Position',[10 820 280 24], ...
    'FontSize',14, 'FontWeight','bold', 'FontColor',[0.9 0.9 0.9], ...
    'HorizontalAlignment','center');

% ── FILE SECTION ──────────────────────────────────────────────────────
uilabel(sidebar,'Text','RECORDING FILE','Position',[10 792 280 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

file_field = uieditfield(sidebar,'text', ...
    'Position',[10 768 230 24], ...
    'Value','Paste path or use Browse...', ...
    'FontSize',8.5, 'FontColor',[0.7 0.7 0.7], ...
    'BackgroundColor',[0.12 0.12 0.14]);

uibutton(sidebar,'Text','Browse', ...
    'Position',[245 768 50 24], ...
    'BackgroundColor',[0.25 0.45 0.65], 'FontColor','w', ...
    'FontSize',8, ...
    'ButtonPushedFcn', @(~,~) browse_file());

condition_label = uilabel(sidebar,'Text','Condition: (load file first)', ...
    'Position',[10 748 280 16], ...
    'FontSize',8,'FontColor',[0.6 0.6 0.6]);

load_btn = uibutton(sidebar,'Text','Load File', ...
    'Position',[10 722 280 28], ...
    'BackgroundColor',[0.2 0.55 0.3], 'FontColor','w', ...
    'FontWeight','bold','FontSize',10, ...
    'ButtonPushedFcn', @(~,~) load_file());

status_lbl = uilabel(sidebar,'Text','No file loaded.', ...
    'Position',[10 702 280 18], ...
    'FontSize',8,'FontColor',[0.55 0.55 0.55], ...
    'HorizontalAlignment','center');

% ── DIVIDER ───────────────────────────────────────────────────────────
divider_line(sidebar, 690, 280);

% ── BPF SECTION — uibuttongroup handles mutual exclusion automatically ─
uilabel(sidebar,'Text','BANDPASS FILTER  (choose one or none)', ...
    'Position',[10 675 280 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

% BPF has 7 items: None + B1-B6.  Height = 7 * 22 = 154 px
bpf_grp = uibuttongroup(sidebar, ...
    'Position',[10 519 280 155], ...
    'BackgroundColor',[0.18 0.18 0.21], ...
    'ForegroundColor',[0.55 0.75 0.95], ...
    'BorderType','none');

bpf_btn = gobjects(numel(BPF)+1, 1);
bpf_labels = {BPF.name};
bpf_btn(1) = uiradiobutton(bpf_grp, 'Text','None (skip BPF)', ...
    'Position',[4 133 272 20], 'Value',true, ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
for b = 1:numel(BPF)
    bpf_btn(b+1) = uiradiobutton(bpf_grp, 'Text', bpf_labels{b}, ...
        'Position',[4 133-b*22 272 20], 'Value',false, ...
        'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
end

% ── DIVIDER ───────────────────────────────────────────────────────────
divider_line(sidebar, 507, 280);

% ── NOTCH SECTION — uibuttongroup handles mutual exclusion automatically
uilabel(sidebar,'Text','NOTCH FILTER  (choose one or none)', ...
    'Position',[10 493 280 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

% Notch has 10 items: None + N1-N9.  Height = 10 * 21 = 210 px
notch_grp = uibuttongroup(sidebar, ...
    'Position',[10 275 280 217], ...
    'BackgroundColor',[0.18 0.18 0.21], ...
    'ForegroundColor',[0.55 0.75 0.95], ...
    'BorderType','none');

notch_btn = gobjects(numel(NOTCH_NAMES)+1, 1);
notch_btn(1) = uiradiobutton(notch_grp, 'Text','None (skip Notch)', ...
    'Position',[4 195 272 20], 'Value',true, ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
for n = 1:numel(NOTCH_NAMES)
    notch_btn(n+1) = uiradiobutton(notch_grp, 'Text', NOTCH_NAMES{n}, ...
        'Position',[4 195-n*21 272 20], 'Value',false, ...
        'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);
end

% No need to wire ValueChangedFcn — uibuttongroup enforces mutual exclusion.

% ── DIVIDER ───────────────────────────────────────────────────────────
divider_line(sidebar, 263, 280);

% ── NOISE INJECTION TEST SECTION ──────────────────────────────────────
uilabel(sidebar,'Text','NOISE INJECTION TEST  (random tones per Evaluate)', ...
    'Position',[10 243 280 16], ...
    'FontSize',9,'FontWeight','bold','FontColor',[0.55 0.75 0.95]);

inject_count_lbl = uilabel(sidebar, ...
    'Text',sprintf('Random tone count: %d', state.inject_n_tones), ...
    'Position',[10 221 280 16], ...
    'FontSize',8.5,'FontColor',[0.82 0.82 0.82]);

noise_slider = uislider(sidebar, ...
    'Position',[18 212 264 3], ...
    'Limits',[1 8], ...
    'MajorTicks',1:8, ...
    'MinorTicks',[], ...
    'Value',state.inject_n_tones, ...
    'ValueChangedFcn',@(src,~) update_injection_controls(src.Value), ...
    'ValueChangingFcn',@(~,event) update_injection_controls(event.Value));

uilabel(sidebar,'Text','Frequencies are randomized each time you press Evaluate.', ...
    'Position',[10 184 280 16], ...
    'FontSize',8,'FontColor',[0.62 0.62 0.62]);

uilabel(sidebar,'Text','Total injected level is held near 30% of ECG peak.', ...
    'Position',[10 168 280 16], ...
    'FontSize',8,'FontColor',[0.62 0.62 0.62]);

% ── EVALUATE BUTTON ───────────────────────────────────────────────────
eval_btn = uibutton(sidebar,'Text','▶  EVALUATE', ...
    'Position',[10 14 280 38], ...
    'BackgroundColor',[0.2 0.45 0.75], 'FontColor','w', ...
    'FontWeight','bold','FontSize',13, ...
    'ButtonPushedFcn', @(~,~) run_evaluation());

% ── RIGHT PANEL — TABBED PLOTS ─────────────────────────────────────────
tabgrp = uitabgroup(fig, 'Position',[318 8 1174 854]);

tab_time   = uitab(tabgrp, 'Title','  Time Domain  ',   'BackgroundColor',[0.12 0.12 0.14]);
tab_freq   = uitab(tabgrp, 'Title','  Frequency Domain  ', 'BackgroundColor',[0.12 0.12 0.14]);
tab_phase  = uitab(tabgrp, 'Title','  Phase & Group Delay  ', 'BackgroundColor',[0.12 0.12 0.14]);
tab_metric = uitab(tabgrp, 'Title','  Measurements  ',  'BackgroundColor',[0.12 0.12 0.14]);
tab_quant  = uitab(tabgrp, 'Title','  Quantitative Comparison  ', 'BackgroundColor',[0.12 0.12 0.14]);

% Time domain axes
ax_time = uiaxes(tab_time, 'Position',[10 10 1150 820], ...
    'Color',[0.08 0.08 0.10], 'XColor',[0.7 0.7 0.7], 'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3], 'MinorGridColor',[0.2 0.2 0.2]);
ax_time.XGrid = 'on'; ax_time.YGrid = 'on';
xlabel(ax_time,'Time (s)','Color',[0.8 0.8 0.8]);
ylabel(ax_time,'mV','Color',[0.8 0.8 0.8]);
title(ax_time,'Time Domain — load a file and press Evaluate','Color',[0.9 0.9 0.9]);

% Frequency domain: two stacked axes
ax_psd = uiaxes(tab_freq, 'Position',[10 430 1150 400], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_psd.XGrid = 'on'; ax_psd.YGrid = 'on';
xlabel(ax_psd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_psd,'PSD (mV²/Hz)','Color',[0.8 0.8 0.8]);
title(ax_psd,'Power Spectral Density — before vs after','Color',[0.9 0.9 0.9]);

ax_mag = uiaxes(tab_freq, 'Position',[10 10 1150 400], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_mag.XGrid = 'on'; ax_mag.YGrid = 'on';
xlabel(ax_mag,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_mag,'Magnitude (dB)','Color',[0.8 0.8 0.8]);
title(ax_mag,'Filter Magnitude Response (frequency sweep)','Color',[0.9 0.9 0.9]);

% Phase & group delay: two stacked axes
ax_phase = uiaxes(tab_phase, 'Position',[10 430 1150 400], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_phase.XGrid = 'on'; ax_phase.YGrid = 'on';
xlabel(ax_phase,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_phase,'Phase (degrees)','Color',[0.8 0.8 0.8]);
title(ax_phase,'Phase Response','Color',[0.9 0.9 0.9]);

ax_gd = uiaxes(tab_phase, 'Position',[10 10 1150 400], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7], ...
    'GridColor',[0.3 0.3 0.3]);
ax_gd.XGrid = 'on'; ax_gd.YGrid = 'on';
xlabel(ax_gd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_gd,'Group Delay (samples)','Color',[0.8 0.8 0.8]);
title(ax_gd,'Group Delay','Color',[0.9 0.9 0.9]);

% Metrics tab — text area
metric_txt = uitextarea(tab_metric, ...
    'Position',[10 10 1150 820], ...
    'Editable','off', ...
    'FontSize',10.5, 'FontName','Courier New', ...
    'BackgroundColor',[0.08 0.08 0.10], 'FontColor',[0.85 0.85 0.85], ...
    'Value',{'Load a file and press Evaluate to see measurements.'});

% Quantitative comparison tab — four panels
ax_beat = uiaxes(tab_quant, 'Position',[10 590 555 240], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7],'GridColor',[0.3 0.3 0.3]);
ax_beat.XGrid = 'on'; ax_beat.YGrid = 'on';
xlabel(ax_beat,'Time after R-peak (ms)','Color',[0.8 0.8 0.8]);
ylabel(ax_beat,'mV','Color',[0.8 0.8 0.8]);
title(ax_beat,'Median Beat + ST Ringing Window','Color',[0.9 0.9 0.9]);

ax_noise = uiaxes(tab_quant, 'Position',[590 590 555 240], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7],'GridColor',[0.3 0.3 0.3]);
ax_noise.XGrid = 'on'; ax_noise.YGrid = 'on';
xlabel(ax_noise,'Frequency (Hz)','Color',[0.8 0.8 0.8]);
ylabel(ax_noise,'PSD (mV²/Hz)','Color',[0.8 0.8 0.8]);
title(ax_noise,'Noise Injection Test — PSD Before vs After','Color',[0.9 0.9 0.9]);

% Full-width time-domain trace: clean | noisy | filtered
ax_inject = uiaxes(tab_quant, 'Position',[10 325 1150 250], ...
    'Color',[0.08 0.08 0.10],'XColor',[0.7 0.7 0.7],'YColor',[0.7 0.7 0.7],'GridColor',[0.3 0.3 0.3]);
ax_inject.XGrid = 'on'; ax_inject.YGrid = 'on';
xlabel(ax_inject,'Time (s)','Color',[0.8 0.8 0.8]);
ylabel(ax_inject,'mV','Color',[0.8 0.8 0.8]);
title(ax_inject,'Noise Injection Test — Time Domain  (grey=clean  orange=+noise  blue=filtered)', ...
    'Color',[0.9 0.9 0.9]);

quant_txt = uitextarea(tab_quant, ...
    'Position',[10 10 1150 300], ...
    'Editable','off', ...
    'FontSize',10.5, 'FontName','Courier New', ...
    'BackgroundColor',[0.08 0.08 0.10], 'FontColor',[0.85 0.85 0.85], ...
    'Value',{'Run Evaluate to see reference-free quantitative metrics.'});

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
        [fname, fpath] = uigetfile({'*.txt;*.csv','Recording files (*.txt, *.csv)'; ...
                                    '*.*','All files'}, 'Select Phase 1 recording');
        if isequal(fname, 0), return; end
        file_field.Value = fullfile(fpath, fname);
    end

    function load_file()
        fpath = strtrim(file_field.Value);
        if isempty(fpath) || strcmp(fpath,'Paste path or use Browse...')
            status_lbl.Text = 'Please enter or browse for a file.';
            status_lbl.FontColor = [0.9 0.4 0.4];
            return;
        end
        if ~isfile(fpath)
            status_lbl.Text = 'File not found. Check the path.';
            status_lbl.FontColor = [0.9 0.4 0.4];
            return;
        end

        status_lbl.Text = 'Reading...';
        status_lbl.FontColor = [0.8 0.8 0.3];
        drawnow;

        try
            raw_data = readmatrix(fpath, 'FileType','text');
        catch e
            status_lbl.Text = ['Read error: ' e.message];
            status_lbl.FontColor = [0.9 0.4 0.4];
            return;
        end

        if isempty(raw_data)
            status_lbl.Text = 'No numeric data in file.';
            status_lbl.FontColor = [0.9 0.4 0.4];
            return;
        end

        [~, n_cols] = size(raw_data);
        if n_cols < 2
            status_lbl.Text = 'Need at least 2 columns (t_us, ecg_corr).';
            status_lbl.FontColor = [0.9 0.4 0.4];
            return;
        end

        % Sign correction (NXP PRINTF uint32 bug)
        data = double(raw_data);
        for col = 2:n_cols
            mask = data(:,col) > 2147483647;
            data(mask,col) = data(mask,col) - 4294967296;
        end

        % Timestamps
        t_us_raw = data(:,1);
        wrap = find(diff(t_us_raw) < 0, 1);
        if ~isempty(wrap)
            t_us_raw(wrap+1:end) = t_us_raw(wrap+1:end) + 4294967296;
        end
        t_us_raw = t_us_raw - t_us_raw(1);
        t_s_data = t_us_raw / 1e6;

        ecg_raw  = data(:,2);
        ecg_mV   = ecg_raw * (1800/4096);

        % Measured Fs
        dt = diff(t_s_data); dt = dt(dt > 0);
        fs_data = 1 / median(dt);

        % Infer condition from filename
        [~, fname_only] = fileparts(fpath);
        cond = 'unknown';
        for c = {'resting','walking','arm_movement','arm','vibration'}
            if contains(lower(fname_only), c{1})
                cond = c{1}; break;
            end
        end

        % Store in state
        state.raw       = ecg_mV;
        state.t_s       = t_s_data;
        state.fs        = fs_data;
        state.condition = cond;
        state.loaded    = true;

        condition_label.Text = sprintf('Condition: %s  |  Fs=%.1f Hz  |  %d samples', ...
            cond, fs_data, numel(ecg_mV));
        condition_label.FontColor = [0.7 0.9 0.7];

        status_lbl.Text = sprintf('Loaded: %s', fname_only);
        status_lbl.FontColor = [0.4 0.85 0.4];

        % Quick preview in time domain
        cla(ax_time);
        plot(ax_time, t_s_data, ecg_mV, 'Color',[0.4 0.6 0.9], 'LineWidth',0.7);
        title(ax_time, sprintf('Raw ECG — %s  (Fs=%.1f Hz)', cond, fs_data), ...
              'Color',[0.9 0.9 0.9]);
        ylabel(ax_time,'mV','Color',[0.8 0.8 0.8]);
        xlabel(ax_time,'Time (s)','Color',[0.8 0.8 0.8]);
    end

    function run_evaluation()
        if ~state.loaded
            status_lbl.Text = 'Load a file first.';
            status_lbl.FontColor = [0.9 0.4 0.4];
            return;
        end

        % Get selections via SelectedObject on the buttongroup
        bpf_sel   = get_selected_idx(bpf_grp,   bpf_btn)   - 1;  % 0=None, 1-6=B1-B6
        notch_sel = get_selected_idx(notch_grp, notch_btn) - 1;  % 0=None, 1-8=N1-N8

        if bpf_sel == 0 && notch_sel == 0
            status_lbl.Text = 'Select at least one filter.';
            status_lbl.FontColor = [0.9 0.7 0.3];
            return;
        end

        status_lbl.Text = 'Evaluating...';
        status_lbl.FontColor = [0.8 0.8 0.3];
        eval_btn.Enable = 'off';
        drawnow;

        try
            do_evaluation(bpf_sel, notch_sel);
            status_lbl.Text = 'Done.';
            status_lbl.FontColor = [0.4 0.85 0.4];
        catch e
            status_lbl.Text = ['Error: ' e.message];
            status_lbl.FontColor = [0.9 0.4 0.4];
            disp(getReport(e));
        end

        eval_btn.Enable = 'on';
    end

    function do_evaluation(bpf_idx, notch_idx)
        raw_mv   = state.raw;
        t_s_data = state.t_s;
        Fs       = state.fs;
        % NOTE: FS_DESIGN is removed. All filters are now designed at actual Fs.
        % The firmware always ran at 500 Hz, but the UART output rate (Fs) may differ.
        % Digital filter SOS coefficients encode normalised frequency, not physical Hz.
        % Applying 500 Hz-designed coefficients to data at Fs ≠ 500 Hz shifts all
        % cutoffs by the ratio Fs/500. Fix: always redesign at actual Fs.
        MV   = 1;
        N    = numel(raw_mv);
        NFFT = 8192;

        % Build label string for the title
        if bpf_idx > 0 && notch_idx > 0
            combo_label = sprintf('%s  +  %s', BPF(bpf_idx).name, NOTCH_NAMES{notch_idx});
        elseif bpf_idx > 0
            combo_label = BPF(bpf_idx).name;
        else
            combo_label = NOTCH_NAMES{notch_idx};
        end

        % ── Apply filters (designed at actual Fs) ────────────────────
        sig_in = double(raw_mv);

        % Stage 1: BPF — redesign at actual Fs
        if bpf_idx > 0
            sos_bpf_data = build_bpf_at_fs(bpf_idx, Fs);
            after_bpf    = apply_biquad(sos_bpf_data, sig_in);
        else
            after_bpf    = sig_in;
            sos_bpf_data = [];
        end

        % Stage 2: Notch — redesign at actual Fs
        mfanf_freq_log = [];
        if notch_idx > 0
            % All notch types including N9 (auto-detect) are handled inside apply_notch.
            % N9 calls auto_detect_interference + multi_freq_nlms internally.
            after_notch = apply_notch(after_bpf, NOTCH_TYPES{notch_idx}, Fs);
        else
            after_notch = after_bpf;
        end

        filtered = after_notch;

        % ── Frequency response (impulse response at actual Fs) ────────
        % f_ax uses actual Fs so magnitude response and PSD share the same
        % physical frequency axis — this was the cause of the 16 Hz notch bug.
        f_ax    = (0:NFFT/2) * Fs / NFFT;
        H_bpf   = ones(NFFT/2+1, 1);
        H_notch = ones(NFFT/2+1, 1);

        if bpf_idx > 0
            imp        = [1; zeros(NFFT-1,1)];
            resp       = apply_biquad(sos_bpf_data, imp);
            H_bpf_full = fft(resp, NFFT);
            H_bpf      = H_bpf_full(1:NFFT/2+1);
        end

        if notch_idx > 0 && notch_idx <= 2
            % IIR notch: build at actual Fs → correct physical frequency
            sos_n   = build_notch_at_fs(notch_idx, Fs);
            imp     = [1; zeros(NFFT-1,1)];
            resp    = sosfilt(sos_n, imp);
            H_notch = fft(resp, NFFT);
            H_notch = H_notch(1:NFFT/2+1);
        elseif notch_idx > 2 && notch_idx <= 8
            % Adaptive notch: estimate response at actual Fs
            H_notch = adaptive_freq_response(NOTCH_TYPES{notch_idx}, Fs, NFFT);
        end

        % ── PSDs — computed before H_combined so N9 can use them ─────
        pw_win  = hamming(min(1024, floor(N/4)));
        pw_nov  = floor(length(pw_win)/2);
        [Praw,  f_pw] = pwelch(sig_in,    pw_win, pw_nov, NFFT, Fs);
        [Pbpf,  ~   ] = pwelch(after_bpf, pw_win, pw_nov, NFFT, Fs);
        [Pfilt, ~   ] = pwelch(filtered,  pw_win, pw_nov, NFFT, Fs);

        % ── N9: empirical H_notch + three-zone detection ──────────────
        % N9 has no fixed frequency response — it adapts to the data.
        % Magnitude response is estimated empirically from PSD ratio.
        % Three zones: below ECG, within ECG (high threshold), above ECG.
        detected_freqs = [];
        if notch_idx == 9
            max_pow2 = 2^floor(log2(max(N, 1)));
            % Zone 1 — below ECG passband (0.01–0.4 Hz)
            nfft_lo  = min(max_pow2, 2^nextpow2(round(Fs / 0.005)));
            nfft_lo  = max(nfft_lo, 64);
            freqs_z1 = auto_detect_interference(sig_in, Fs, 0.01, min(0.4, Fs/2-1), 6, 3, nfft_lo);
            % Zone 2 — WITHIN ECG passband (0.5–40 Hz) HIGH threshold=20 dB
            % Only flags interference that is 100x stronger than local ECG floor.
            nfft_ib  = min(max_pow2, 2^nextpow2(round(Fs / 0.1)));
            nfft_ib  = max(nfft_ib, 64);
            freqs_z2 = auto_detect_interference(sig_in, Fs, 0.5, min(40.0, Fs/2-1), 20, 3, nfft_ib);
            % Zone 3 — above ECG passband (45 Hz to Nyquist-5)
            hi_hi    = max(46, Fs/2 - 5);
            if hi_hi > 46
                freqs_z3 = auto_detect_interference(sig_in, Fs, 45, hi_hi, 6, 5, 512);
            else
                freqs_z3 = [];
            end
            detected_freqs = [freqs_z1(:)', freqs_z2(:)', freqs_z3(:)'];

            % Empirical H_notch from PSD ratio (notch input → output)
            notch_input_psd = Pbpf;
            H_notch_lin = sqrt((Pfilt + 1e-30) ./ (notch_input_psd + 1e-30));
            H_notch     = H_notch_lin;
        end

        H_combined    = H_bpf .* H_notch;
        H_mag_db      = 20*log10(abs(H_combined) + 1e-12);
        H_phase_deg   = unwrap(angle(H_combined)) * (180/pi);
        H_group_delay = -diff(unwrap(angle(H_combined))) / (2*pi/NFFT);
        f_gd          = f_ax(1:end-1);

        % ── CLINICAL REFERENCE — context-aware ───────────────────────
        %
        % The reference must be the BEST ACHIEVABLE output for the given
        % passband context, not an arbitrary fixed combination.
        %
        % For monitoring-grade passband (BPF upper cutoff ≤ 40 Hz):
        %   Reference = B1 alone (Butterworth 8th, 0.5-40 Hz).
        %   Reason: 50 Hz is already rejected ~50 dB by the BPF transition
        %   band. Adding N1 introduces post-QRS IIR ringing (0-40 μV,
        %   PMC3701603) with zero benefit. B1 alone IS the gold standard.
        %
        % For diagnostic-grade passband (BPF upper cutoff > 40 Hz, i.e. B3):
        %   Reference = B1+N1.
        %   Reason: 50 Hz falls inside the B3 passband and must be notched.
        %   B1+N1 is used as the clinical baseline because B3 passes content
        %   that B1 does not, making a direct B3-vs-B1 comparison misleading.
        %
        % Using B1+N1 as the universal reference when the notch actually
        % degrades the output (as empirically observed) is logically wrong —
        % it would penalise cleaner outputs for being closer to a degraded ref.

        is_diagnostic_bpf = (bpf_idx == 3);   % B3 = 0.05-150 Hz only

        ref_signal = apply_biquad(build_bpf_at_fs(1, Fs), sig_in);   % B1 at actual Fs
        if is_diagnostic_bpf
            ref_signal = apply_notch(ref_signal, 'N1', Fs);   % N1 at actual Fs
            ref_label  = 'B1+N1  (diagnostic context)';
        else
            ref_label  = 'B1 alone  (monitoring context, notch redundant)';
        end

        nn    = min(numel(filtered), numel(ref_signal));
        s_ref = ref_signal(1:nn);
        f_flt = filtered(1:nn);
        err   = s_ref - f_flt;

        % PRD vs reference
        prd_v  = 100 * sqrt(sum(err.^2) / (sum(s_ref.^2) + 1e-12));
        rmse_v = sqrt(mean(err.^2));
        if std(s_ref) > 0 && std(f_flt) > 0
            r_v = corr(s_ref, f_flt);
        else
            r_v = NaN;
        end
        snr_vs_ref = 10*log10(sum(s_ref.^2) / (sum(err.^2) + 1e-12));

        % ── WITHIN-BAND SNR IMPROVEMENT ───────────────────────────────
        % This metric does NOT require a clean reference signal.
        % It measures how well the filter concentrates signal energy into
        % the ECG passband (0.5-40 Hz) relative to out-of-band noise.
        %
        % WBSNR = 10*log10(E_inband / E_outband)
        % Improvement = WBSNR(filtered) - WBSNR(raw)
        % Positive improvement = filter increased in-band SNR = working correctly
        %
        % Reference: Reddy & Murthy 1986 — note that their PRD uses a CLEAN
        % reference signal (synthetically noisy ECG compared back to clean).
        % Since we record real signals with unknown noise level, within-band
        % SNR is the correct metric for our use case.
        inband  = f_pw >= 0.5  & f_pw <= 40;
        outband = ~inband;

        E_raw_in    = sum(Praw(inband));
        E_raw_out   = sum(Praw(outband));
        E_filt_in   = sum(Pfilt(inband));
        E_filt_out  = sum(Pfilt(outband));

        wbsnr_raw  = 10*log10(E_raw_in  / (E_raw_out  + 1e-30));
        wbsnr_filt = 10*log10(E_filt_in / (E_filt_out + 1e-30));
        wbsnr_impr = wbsnr_filt - wbsnr_raw;

        % ── 50 HZ ENERGY ATTENUATION (notch effectiveness) ────────────
        % Measures how much power was removed at 50 Hz in the actual data.
        % If recording has little 50 Hz interference, this will be small —
        % that is correct behaviour, not a bug. The notch filter is working;
        % there is simply nothing for it to remove.
        notch_band    = f_pw >= 48 & f_pw <= 52;
        E_50hz_raw    = sum(Praw(notch_band));
        E_50hz_filt   = sum(Pfilt(notch_band));
        notch_effect  = 10*log10(E_50hz_raw / (E_50hz_filt + 1e-30));

        % ── FILTER DESIGN CHARACTERISTICS (impulse response, Fs=500 Hz) ──────
        % Measure passband ripple in the INTERIOR of the passband only,
        % excluding the -3 dB edge frequencies. The spec cutoffs (0.5 Hz and
        % 40 Hz) are by definition the -3 dB points for Butterworth filters,
        % so including them gives ~3 dB "ripple" for any correctly-designed
        % Butterworth — this is a measurement artifact, not real ripple.
        % Measuring at 2–35 Hz captures the flat interior where true ripple
        % matters for ECG morphology (QRS, P, T waves all live here).
        pb_idx = f_ax >= 2 & f_ax <= 35;
        H_pb   = H_mag_db(pb_idx);
        ripple = max(H_pb) - min(H_pb);

        [~, idx_100] = min(abs(f_ax - 100));
        [~, idx_50]  = min(abs(f_ax - 50));
        atten_100    = H_mag_db(idx_100);
        notch_depth  = H_mag_db(idx_50);

        % ── TAB 1: TIME DOMAIN ────────────────────────────────────────
        t_show = min(15, t_s_data(end));
        idx    = t_s_data <= t_show;
        cla(ax_time);
        hold(ax_time,'on');
        plot(ax_time, t_s_data(idx), sig_in(idx), ...
             'Color',[0.5 0.5 0.55],'LineWidth',0.6,'DisplayName','Raw ECG');
        plot(ax_time, t_s_data(idx), filtered(idx), ...
             'Color',[0.3 0.75 0.95],'LineWidth',1.0,'DisplayName',['Filtered: ' combo_label]);
        hold(ax_time,'off');
        title(ax_time, sprintf('Time Domain — %s  |  %s  |  First %.0f s', ...
              state.condition, combo_label, t_show), 'Color',[0.9 0.9 0.9]);
        legend(ax_time,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_time,'mV','Color',[0.8 0.8 0.8]);
        xlabel(ax_time,'Time (s)','Color',[0.8 0.8 0.8]);

        % ── TAB 2: FREQUENCY DOMAIN ───────────────────────────────────
        % PSD (top)
        cla(ax_psd);
        hold(ax_psd,'on');
        semilogy(ax_psd, f_pw, Praw,  'Color',[0.6 0.6 0.65],'LineWidth',0.8,'DisplayName','Raw');
        semilogy(ax_psd, f_pw, Pfilt, 'Color',[0.3 0.75 0.95],'LineWidth',1.2,'DisplayName',['Filtered: ' combo_label]);
        xline(ax_psd, 0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_psd, 40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xline(ax_psd, 50, 'Color',[0.8 0.4 0.4],'LineWidth',0.8,'LineStyle','--','Label','50 Hz');
        hold(ax_psd,'off');
        xlim(ax_psd,[0 120]);
        title(ax_psd,'Power Spectral Density — Raw vs Filtered','Color',[0.9 0.9 0.9]);

        % Mark N9 detected frequencies on PSD plot
        if ~isempty(detected_freqs)
            hold(ax_psd,'on');
            for df = detected_freqs
                xline(ax_psd, df, 'Color',[0.9 0.85 0.2],'LineWidth',1.2, ...
                      'LineStyle','--','Label',sprintf('%.1f Hz', df));
            end
            hold(ax_psd,'off');
        end
        legend(ax_psd,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_psd,'PSD (mV²/Hz)','Color',[0.8 0.8 0.8]);
        xlabel(ax_psd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        % Magnitude response (bottom)
        cla(ax_mag);
        hold(ax_mag,'on');
        if bpf_idx > 0 && notch_idx > 0
            plot(ax_mag, f_ax, 20*log10(abs(H_bpf)+1e-12), ...
                 'Color',[0.4 0.85 0.5],'LineWidth',0.9,'LineStyle','--','DisplayName',BPF(bpf_idx).name);
            plot(ax_mag, f_ax, 20*log10(abs(H_notch)+1e-12), ...
                 'Color',[0.85 0.65 0.3],'LineWidth',0.9,'LineStyle','--','DisplayName',NOTCH_NAMES{notch_idx});
        end
        plot(ax_mag, f_ax, H_mag_db, ...
             'Color',[0.3 0.75 0.95],'LineWidth',1.5,'DisplayName','Combined');
        xline(ax_mag, 0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_mag, 40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xline(ax_mag, 50, 'Color',[0.8 0.4 0.4],'LineWidth',0.8,'LineStyle','--','Label','50 Hz');
        yline(ax_mag, -3,  'Color',[0.5 0.5 0.5],'LineWidth',0.6,'LineStyle',':','Label','-3 dB');
        yline(ax_mag, -40, 'Color',[0.5 0.5 0.5],'LineWidth',0.6,'LineStyle',':','Label','-40 dB');
        hold(ax_mag,'off');
        ylim(ax_mag,[-85 5]);
        xlim(ax_mag,[0 120]);
        if notch_idx == 9
            mag_title = sprintf('Filter Magnitude Response  (N9: empirical from data, Fs=%.1f Hz)', Fs);
        else
            mag_title = sprintf('Filter Magnitude Response  (designed at Fs=%.1f Hz)', Fs);
        end
        title(ax_mag, mag_title, 'Color',[0.9 0.9 0.9]);
        legend(ax_mag,'Location','southwest','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        ylabel(ax_mag,'Magnitude (dB)','Color',[0.8 0.8 0.8]);
        xlabel(ax_mag,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        % ── TAB 3: PHASE & GROUP DELAY ────────────────────────────────
        cla(ax_phase);
        plot(ax_phase, f_ax, H_phase_deg, 'Color',[0.75 0.5 0.9],'LineWidth',1.3);
        xline(ax_phase, 0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_phase, 40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xlim(ax_phase,[0 120]);
        title(ax_phase,'Phase Response','Color',[0.9 0.9 0.9]);
        ylabel(ax_phase,'Phase (degrees)','Color',[0.8 0.8 0.8]);
        xlabel(ax_phase,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        cla(ax_gd);
        plot(ax_gd, f_gd, H_group_delay, 'Color',[0.9 0.65 0.35],'LineWidth',1.3);
        xline(ax_gd, 0.5,'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','0.5 Hz');
        xline(ax_gd, 40, 'Color',[0.8 0.7 0.3],'LineWidth',0.8,'Label','40 Hz');
        xlim(ax_gd,[0 120]);
        title(ax_gd,'Group Delay  (constant = linear phase = no waveform distortion)', ...
              'Color',[0.9 0.9 0.9]);
        ylabel(ax_gd,'Group Delay (samples)','Color',[0.8 0.8 0.8]);
        xlabel(ax_gd,'Frequency (Hz)','Color',[0.8 0.8 0.8]);

        % ── TAB 4: METRICS ────────────────────────────────────────────
        sep  = repmat('─', 1, 65);
        sep2 = repmat('·', 1, 65);
        lines_out = {
            sep
            sprintf('  FILTER:     %s', combo_label)
            sprintf('  CONDITION:  %s  |  File Fs: %.2f Hz  |  %d samples  (%.1f s)', ...
                    state.condition, Fs, N, t_s_data(end))
            sep
            ''
            '  ① WITHIN-BAND SNR IMPROVEMENT  (primary metric — no ground truth needed)'
            '  ─────────────────────────────────────────────────────────────────'
            '  Measures how well the filter concentrates signal energy into'
            '  the ECG passband (0.5–40 Hz) relative to out-of-band noise.'
            '  A positive improvement confirms the filter is removing noise correctly.'
            ''
            sprintf('  WBSNR (raw)      : %+.2f dB', wbsnr_raw)
            sprintf('  WBSNR (filtered) : %+.2f dB', wbsnr_filt)
            sprintf('  WBSNR improvement: %+.2f dB   %s', wbsnr_impr, ...
                    ternary_str(wbsnr_impr > 0, '✓ filter improved in-band SNR', ...
                                               '○ no improvement (noise not in passband?'))
            ''
            sep2
            ''
            '  ② MORPHOLOGY vs CLINICAL REFERENCE'
            '  ─────────────────────────────────────────────────────────────────'
            sprintf('  Reference used: %s', ref_label)
            ''
            '  WHY NOT B1+N1 as universal reference:'
            '  The IIR notch introduces post-QRS ringing (0-40 uV) even when'
            '  50 Hz is already rejected by the BPF. This is a known inherent'
            '  contradiction: narrower notch = longer ringing tail (PMC3701603).'
            '  When the notch degrades the output, using it as a reference'
            '  would penalise cleaner signals for being closer to a worse signal.'
            '  Reference is B1 alone for monitoring-grade, B1+N1 for diagnostic.'
            ''
            sprintf('  PRD vs reference : %.3f %%   %s', prd_v, ...
                    ternary_str(prd_v < 2,  '✓ very close to reference', ...
                    ternary_str(prd_v < 9,  '✓ clinically acceptable (< 9%% threshold)', ...
                                            '✗ deviates from reference (> 9%%)')))
            sprintf('  RMSE vs reference: %.4f mV', rmse_v)
            sprintf('  Pearson r        : %.5f   %s', r_v, ...
                    ternary_str(r_v > 0.98, '✓ morphology well preserved', ...
                                            '○ morphology differs from reference'))
            sprintf('  SNR vs reference : %+.2f dB', snr_vs_ref)
            ''
            sep2
            ''
            '  ③ 50 Hz NOTCH EFFECTIVENESS  (on actual recorded data)'
            '  ─────────────────────────────────────────────────────────────────'
            sprintf('  50 Hz attenuation: %+.2f dB   %s', notch_effect, ...
                    ternary_str(notch_effect > 10, '✓ significant 50 Hz reduction', ...
                    ternary_str(notch_effect > 3,  '○ moderate 50 Hz reduction', ...
                                                   '○ minimal reduction — recording may have little 50 Hz interference')))
            '  NOTE: If attenuation is low, the notch filter IS working correctly.'
            '  Low attenuation means there was no significant 50 Hz in the recording'
            '  (the AD8233 front-end differential input and RLD suppress powerline noise).'
            '  This is physically correct — not a bug.'
            ''
            sep2
            ''
            '  ④ FILTER DESIGN CHARACTERISTICS  (from impulse response, Fs=500 Hz)'
            '  ─────────────────────────────────────────────────────────────────'
            sprintf('  Passband ripple  : %.4f dB   %s', ripple, ...
                    ternary_str(ripple < 0.5, '✓ excellent (< 0.5 dB)', ...
                    ternary_str(ripple < 1.0, '✓ acceptable (< 1.0 dB)', ...
                                              '✗ high ripple (> 1 dB)')))
            sprintf('  Magnitude @ 50 Hz: %.2f dB   (filter design notch depth)', notch_depth)
            sprintf('  Magnitude @ 100Hz: %.2f dB   (stopband attenuation)', atten_100)
        };

        if bpf_idx > 0
            lines_out{end+1} = sprintf('  BPF passband     : %.2f – %.0f Hz  (%d biquad stages)  [%s]', ...
                BPF(bpf_idx).passband(1), BPF(bpf_idx).passband(2), ...
                BPF(bpf_idx).stages, BPF(bpf_idx).standard);
        end
        if notch_idx > 0
            if notch_idx <= 2
                r_vals = [0.990, 0.995];
                bw3db  = 2*(1 - r_vals(notch_idx))*50/pi;
                lines_out{end+1} = sprintf('  Notch -3dB BW    : ≈ %.3f Hz  (r=%.3f, narrower = more selective)', ...
                    bw3db, r_vals(notch_idx));
            elseif notch_idx == 9
                lines_out{end+1} = '';
                lines_out{end+1} = sep;
                lines_out{end+1} = '  N9 AUTO-DETECTION RESULTS  (three-zone search)';
                lines_out{end+1} = '  ─────────────────────────────────────────────────────────────────';
                lines_out{end+1} = '  Zone 1: 0.01-0.40 Hz  below ECG passband    threshold: 6 dB';
                lines_out{end+1} = '  Zone 2: 0.5 -40  Hz   WITHIN ECG passband   threshold: 20 dB';
                lines_out{end+1} = '  Zone 3: 45  -Nyq  Hz  above ECG passband    threshold: 6 dB';
                lines_out{end+1} = '';
                lines_out{end+1} = '  Zone 2 (in-band) uses 20 dB threshold — only flags';
                lines_out{end+1} = '  interference 100x stronger than local ECG floor.';
                lines_out{end+1} = '  IN-BAND NOTCH REMOVES ECG CONTENT AT THAT FREQUENCY.';
                lines_out{end+1} = '';
                if isempty(detected_freqs)
                    lines_out{end+1} = '  No narrowband interference detected in any zone.';
                    lines_out{end+1} = '  Signal is clean or interference is broadband (use BPF).';
                else
                    z1 = detected_freqs(detected_freqs < 0.5);
                    z2 = detected_freqs(detected_freqs >= 0.5 & detected_freqs < 45);
                    z3 = detected_freqs(detected_freqs >= 45);
                    if ~isempty(z1)
                        lines_out{end+1} = sprintf('  Zone 1 (%d): sub-ECG hum', numel(z1));
                        for fi = 1:numel(z1)
                            lines_out{end+1} = sprintf('    %.4f Hz', z1(fi));
                        end
                    end
                    if ~isempty(z2)
                        lines_out{end+1} = sprintf('  Zone 2 (%d): IN-BAND — morphology affected', numel(z2));
                        for fi = 1:numel(z2)
                            lines_out{end+1} = sprintf('    %.2f Hz  *** verify waveform quality', z2(fi));
                        end
                    end
                    if ~isempty(z3)
                        lines_out{end+1} = sprintf('  Zone 3 (%d): powerline / inverter', numel(z3));
                        for fi = 1:numel(z3)
                            lines_out{end+1} = sprintf('    %.2f Hz', z3(fi));
                        end
                    end
                    lines_out{end+1} = '  Each: NLMS adaptive notch (mu=0.05). Empirical mag resp.';
                end
            else
                lines_out{end+1} = sprintf('  Notch type       : adaptive (%s) — tracks mains frequency drift', ...
                    NOTCH_TYPES{notch_idx});
            end
        end

        lines_out{end+1} = sep;
        metric_txt.Value = lines_out;

        % ── TAB 5: QUANTITATIVE COMPARISON ───────────────────────────
        % Three reference-free metrics that produce real numbers without
        % needing B1 as a ground truth.

        % ── METRIC A: Synthetic multi-frequency noise injection ───────
        % Inject random single-frequency tones at controlled amplitude.
        % The number of tones is user-controlled by the sidebar slider and
        % new frequencies are generated on each Evaluate press.
        total_inject_amp = 0.30 * max(abs(sig_in));
        t_inj            = (0:N-1)' / Fs;
        rng('shuffle');
        inj_freqs        = generate_random_injection_freqs(Fs, state.inject_n_tones);
        inject_amp       = total_inject_amp / sqrt(max(numel(inj_freqs), 1));
        inj_labels       = arrayfun(@(f) sprintf('%.2f Hz (random tone)', f), ...
                                    inj_freqs, 'UniformOutput', false);

        noise_composite = zeros(N, 1);
        for fi = 1:numel(inj_freqs)
            noise_composite = noise_composite + inject_amp * sin(2*pi*inj_freqs(fi)*t_inj);
        end
        sig_noisy = sig_in + noise_composite;

        % Filter the noisy signal with the selected filter(s)
        if bpf_idx > 0
            filt_noisy = apply_biquad(sos_bpf_data, sig_noisy);   % use Fs-correct SOS
        else
            filt_noisy = sig_noisy;
        end
        if notch_idx > 0
            filt_noisy = apply_notch(filt_noisy, NOTCH_TYPES{notch_idx}, Fs);
        end

        % Measure power rejection at each injected frequency
        [P_noisy,  f_ni] = pwelch(sig_noisy,  pw_win, pw_nov, NFFT, Fs);
        [P_fnoisy, ~   ] = pwelch(filt_noisy, pw_win, pw_nov, NFFT, Fs);

        rejection_db = zeros(1, numel(inj_freqs));
        for fi = 1:numel(inj_freqs)
            band = f_ni >= inj_freqs(fi)-2 & f_ni <= inj_freqs(fi)+2;
            E_b  = sum(P_noisy(band));
            E_a  = sum(P_fnoisy(band));
            rejection_db(fi) = 10*log10(E_b / (E_a + 1e-30));
        end

        % ── Time domain trace ─────────────────────────────────────────
        % Show first 10 seconds: clean ECG, noisy ECG, filtered result.
        t_show_q = min(10, t_s_data(end));
        idx_q    = t_s_data <= t_show_q;

        cla(ax_inject); hold(ax_inject,'on');
        plot(ax_inject, t_s_data(idx_q), sig_in(idx_q), ...
             'Color',[0.5 0.5 0.55],'LineWidth',0.5,'DisplayName','Clean ECG (no injection)');
        plot(ax_inject, t_s_data(idx_q), sig_noisy(idx_q), ...
             'Color',[0.85 0.45 0.15],'LineWidth',0.7,'DisplayName', ...
             sprintf('ECG + injected random tones (%d tones, total level %.0f%% peak)', ...
                     numel(inj_freqs), 100*total_inject_amp/max(abs(sig_in))));
        plot(ax_inject, t_s_data(idx_q), filt_noisy(idx_q), ...
             'Color',[0.3 0.75 0.95],'LineWidth',1.1,'DisplayName', ...
             ['Filtered: ' combo_label]);
        hold(ax_inject,'off');
        legend(ax_inject,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35],'FontSize',8);
        ylabel(ax_inject,'mV','Color',[0.8 0.8 0.8]);
        xlabel(ax_inject,'Time (s)','Color',[0.8 0.8 0.8]);

        % Build injection frequencies string for title
        freq_str = strjoin(arrayfun(@(f) sprintf('%.2f Hz',f), inj_freqs, 'UniformOutput',false), ' + ');
        title(ax_inject, ...
            sprintf('Noise Injection Time Domain  |  Random tones: %s  |  Total level: 30%% of ECG peak', freq_str), ...
            'Color',[0.9 0.9 0.9]);

        % ── PSD plot ──────────────────────────────────────────────────
        cla(ax_noise); hold(ax_noise,'on');
        semilogy(ax_noise, f_ni, P_noisy,  'Color',[0.85 0.45 0.15],'LineWidth',0.9, ...
                 'DisplayName','ECG + injected noise');
        semilogy(ax_noise, f_ni, P_fnoisy, 'Color',[0.3 0.75 0.95],'LineWidth',1.3, ...
                 'DisplayName',['After filter: ' combo_label]);
        for fi = 1:numel(inj_freqs)
            xline(ax_noise, inj_freqs(fi), 'Color',[0.9 0.8 0.2],'LineWidth',1.0, ...
                  'LineStyle','--','Label', sprintf('%.2f Hz', inj_freqs(fi)));
        end
        xlim(ax_noise,[0 min(130, Fs/2)]);
        hold(ax_noise,'off');
        legend(ax_noise,'Location','northeast','TextColor',[0.8 0.8 0.8], ...
               'Color',[0.1 0.1 0.12],'EdgeColor',[0.35 0.35 0.35]);
        title(ax_noise,'Noise Injection PSD  (yellow dashes = injected frequencies)', ...
              'Color',[0.9 0.9 0.9]);

        % ── METRIC B: Post-QRS ringing energy (ST-segment disturbance) ─
        % Detect R-peaks via simple threshold on filtered signal.
        % For each beat: measure RMS in pre-QRS baseline window vs
        % post-QRS ST window (60-200 ms after R-peak).
        % Ratio = how much the filter disturbed the ST segment relative
        % to baseline. Higher ratio = more ringing = worse.

        thresh     = 0.5 * max(filtered);
        min_rr_smp = round(0.4 * Fs);   % 400ms minimum RR
        r_peaks    = [];
        i = 1;
        while i <= numel(filtered)
            if filtered(i) > thresh
                [~, local_pk] = max(filtered(i:min(i+round(0.05*Fs), numel(filtered))));
                pk_idx = i + local_pk - 1;
                if isempty(r_peaks) || (pk_idx - r_peaks(end)) > min_rr_smp
                    r_peaks(end+1) = pk_idx; %#ok<AGROW>
                end
                i = pk_idx + min_rr_smp;
            else
                i = i + 1;
            end
        end

        % Windows — define BEFORE valid_beats so the bounds check matches extraction
        beat_len = round(0.6*Fs);   % total window: 600 ms
        pre_R    = round(0.2*Fs);   % 200 ms before R-peak
        pre_lo   = -round(0.30*Fs); pre_hi  = -round(0.06*Fs);
        st_lo    =  round(0.06*Fs); st_hi   =  round(0.20*Fs);

        % Guard: beat must fit entirely within signal
        % Extraction goes from pk-pre_R+1 to pk-pre_R+beat_len = pk+(beat_len-pre_R)
        end_margin = beat_len - pre_R;   % = 0.4*Fs samples after R-peak
        valid_beats = r_peaks( ...
            r_peaks + end_margin <= N & ...   % end of window in bounds
            r_peaks - pre_R + 1  >= 1  );     % start of window in bounds
        n_beats = numel(valid_beats);

        qlines = {};
        if n_beats >= 3
            % Build median beat template
            beat_mat = zeros(beat_len, n_beats);
            for k = 1:n_beats
                pk = valid_beats(k);
                seg = filtered(pk-pre_R+1 : pk-pre_R+beat_len);
                beat_mat(:,k) = seg;
            end
            median_beat = median(beat_mat, 2);
            t_beat_ms   = (-pre_R : beat_len-pre_R-1) / Fs * 1000;

            % ST ringing: RMS of (beat - median_beat) in ST window
            st_idx  = t_beat_ms >= 60 & t_beat_ms <= 200;
            pre_idx = t_beat_ms >= -300 & t_beat_ms <= -60;

            st_rms_vals   = zeros(1, n_beats);
            pre_rms_vals  = zeros(1, n_beats);
            prd_beat_vals = zeros(1, n_beats);

            for k = 1:n_beats
                residual = beat_mat(:,k) - median_beat;
                st_rms_vals(k)   = rms(residual(st_idx));
                pre_rms_vals(k)  = rms(residual(pre_idx));
                prd_beat_vals(k) = 100 * sqrt(sum(residual.^2) / (sum(median_beat.^2) + 1e-12));
            end

            st_rms_mean   = mean(st_rms_vals) * 1000;   % -> uV
            pre_rms_mean  = mean(pre_rms_vals) * 1000;
            beat_prd_mean = mean(prd_beat_vals);
            beat_prd_std  = std(prd_beat_vals);
            st_ratio_db   = 20 * log10((st_rms_mean + 1e-9) / (pre_rms_mean + 1e-9));

            % Plot median beat
            cla(ax_beat);
            hold(ax_beat, 'on');
            patch(ax_beat, [60 200 200 60], ...
                  [min(median_beat)*1.2 min(median_beat)*1.2 max(median_beat)*1.2 max(median_beat)*1.2], ...
                  [0.9 0.4 0.4], 'FaceAlpha', 0.12, 'EdgeColor', 'none', ...
                  'DisplayName', 'ST window (ringing zone)');
            patch(ax_beat, [-300 -60 -60 -300], ...
                  [min(median_beat)*1.2 min(median_beat)*1.2 max(median_beat)*1.2 max(median_beat)*1.2], ...
                  [0.3 0.7 0.3], 'FaceAlpha', 0.10, 'EdgeColor', 'none', ...
                  'DisplayName', 'Baseline window');
            plot(ax_beat, t_beat_ms, median_beat, ...
                 'Color', [0.3 0.75 0.95], 'LineWidth', 1.5, 'DisplayName', 'Median beat');
            plot(ax_beat, t_beat_ms, beat_mat(:,1:min(5,n_beats)), ...
                 'Color', [0.55 0.55 0.6], 'LineWidth', 0.4);
            xline(ax_beat, 0, 'Color', [0.8 0.8 0.8], 'LineWidth', 0.8, 'Label', 'R-peak');
            hold(ax_beat, 'off');
            legend(ax_beat, 'Location', 'northeast', 'TextColor', [0.8 0.8 0.8], ...
                   'Color', [0.1 0.1 0.12], 'EdgeColor', [0.35 0.35 0.35]);
            title(ax_beat, sprintf('Median Beat  (%d beats)  |  ST RMS=%.1f uV  |  Baseline RMS=%.1f uV', ...
                  n_beats, st_rms_mean, pre_rms_mean), 'Color', [0.9 0.9 0.9]);
            xlabel(ax_beat, 'Time after R-peak (ms)', 'Color', [0.8 0.8 0.8]);
            ylabel(ax_beat, 'mV', 'Color', [0.8 0.8 0.8]);

            % Build quantitative summary text without nested cell concatenation
            sep_q = repmat('-', 1, 70);
            qlines{end+1,1} = sep_q;
            qlines{end+1,1} = '  REFERENCE-FREE QUANTITATIVE METRICS';
            qlines{end+1,1} = sprintf('  Filter: %s', combo_label);
            qlines{end+1,1} = sep_q;
            qlines{end+1,1} = '';
            qlines{end+1,1} = '  1) MULTI-FREQUENCY SYNTHETIC INJECTION TEST  (unambiguous ground truth)';
            qlines{end+1,1} = '  -------------------------------------------------------------';
            qlines{end+1,1} = sprintf('  %d random tones injected across the usable band on this run:', numel(inj_freqs));
            qlines{end+1,1} = sprintf('  Frequencies: %s', freq_str);
            qlines{end+1,1} = sprintf('  Per-tone amplitude: %.4f mV', inject_amp);
            qlines{end+1,1} = sprintf('  Composite target level: %.4f mV  (30%% of ECG peak)', total_inject_amp);
            qlines{end+1,1} = '  New frequencies are generated each time Evaluate is pressed.';
            qlines{end+1,1} = '';

            for fi = 1:numel(inj_freqs)
                rdb = rejection_db(fi);
                qlines{end+1,1} = sprintf('  %-22s  rejection: %+.1f dB   %s', ...
                    inj_labels{fi}, rdb, rejection_label(rdb));
            end

            qlines{end+1,1} = '';
            qlines{end+1,1} = sprintf('  Total injected level : %.4f mV  (shared across %d tones)', total_inject_amp, numel(inj_freqs));
            qlines{end+1,1} = '  NOTE: Rejection depends on where the random tones land relative to the';
            qlines{end+1,1} = '  selected passband and notch. In-band tones are the hardest to remove';
            qlines{end+1,1} = '  without morphology distortion. Out-of-band tones are usually strongly';
            qlines{end+1,1} = '  attenuated by the BPF alone.';
            qlines{end+1,1} = '';
            qlines{end+1,1} = sep_q;
            qlines{end+1,1} = '';
            qlines{end+1,1} = '  2) POST-QRS ST-SEGMENT RINGING ENERGY  (notch artifact detector)';
            qlines{end+1,1} = '  -------------------------------------------------------------';
            qlines{end+1,1} = '  Method: detect R-peaks, measure RMS of (beat - median_beat) in';
            qlines{end+1,1} = '  the ST window (60-200 ms post-R) vs pre-QRS baseline (-300 to -60 ms).';
            qlines{end+1,1} = '  Higher ST RMS vs baseline = more filter-induced ringing in ST segment.';
            qlines{end+1,1} = '  Reference: PMC3701603 - IIR notch ringing in ST region.';
            qlines{end+1,1} = '';
            qlines{end+1,1} = sprintf('  Beats detected  : %d', n_beats);
            qlines{end+1,1} = sprintf('  ST RMS          : %.2f uV  (energy in 60-200 ms post-R window)', st_rms_mean);
            qlines{end+1,1} = sprintf('  Baseline RMS    : %.2f uV  (energy in -300 to -60 ms window)', pre_rms_mean);
            qlines{end+1,1} = sprintf('  ST/Baseline dB  : %+.2f dB  %s', st_ratio_db, st_ratio_label(st_ratio_db));
            qlines{end+1,1} = '';
            qlines{end+1,1} = sep_q;
            qlines{end+1,1} = '';
            qlines{end+1,1} = '  3) BEAT-TO-BEAT MORPHOLOGY CONSISTENCY  (template PRD)';
            qlines{end+1,1} = '  ------------------------------------------------------';
            qlines{end+1,1} = '  Method: compute median beat template, measure PRD of each';
            qlines{end+1,1} = '  individual beat against it. Lower = more consistent shape.';
            qlines{end+1,1} = '  Reference: self-referential, needs no external ground truth.';
            qlines{end+1,1} = '  High variance = filter disturbing beat morphology unevenly.';
            qlines{end+1,1} = '';
            qlines{end+1,1} = sprintf('  Beat PRD mean   : %.3f %%', beat_prd_mean);
            qlines{end+1,1} = sprintf('  Beat PRD std    : %.3f %%  (lower = consistent morphology)', beat_prd_std);
            qlines{end+1,1} = sep_q;
        else
            % Not enough beats for analysis
            cla(ax_beat);
            text(ax_beat, 0.5, 0.5, ...
                 sprintf('R-peak detection found %d beats.\nNeed >= 3. Check signal amplitude.', n_beats), ...
                 'HorizontalAlignment', 'center', ...
                 'Color', [0.8 0.8 0.8], ...
                 'Units', 'normalized', ...
                 'FontSize', 10);
            qlines{end+1,1} = sep;
            qlines{end+1,1} = sprintf('  Only %d R-peaks detected. Need at least 3.', n_beats);
            qlines{end+1,1} = '  Ensure the signal is in mV and properly loaded.';
            qlines{end+1,1} = sep;
            rejection_db = 0;
            st_rms_mean = 0;
            pre_rms_mean = 0;
            beat_prd_mean = 0;
        end

        quant_txt.Value = qlines;
    end

%% ═══════════════════════════════════════════════════════════════════════
%% HELPER: get adaptive filter freq response via sweep
%% ═══════════════════════════════════════════════════════════════════════
    function H = adaptive_freq_response(notch_type, Fs_design, Nfft)
        % Measure effective frequency response of adaptive notch (N3-N8 only).
        % N9 is excluded — it uses spectral detection so its "response" is
        % data-dependent and meaningless on white noise input.
        if strcmp(notch_type, 'N9')
            H = ones(Nfft/2+1, 1);   % treat as flat (pass-through for display)
            return;
        end
        n_samp = 20000;
        rng(42);
        x_in  = randn(n_samp, 1);
        y_out = apply_notch(x_in, notch_type, Fs_design);   % pass actual Fs
        x_ss  = x_in(10001:end);
        y_ss  = y_out(10001:end);
        X     = fft(x_ss, Nfft);
        Y     = fft(y_ss, Nfft);
        H     = Y(1:Nfft/2+1) ./ (X(1:Nfft/2+1) + 1e-15);
    end

%% ═══════════════════════════════════════════════════════════════════════
%% HELPERS
%% ═══════════════════════════════════════════════════════════════════════

    function idx = get_selected_idx(btn_grp, btn_array)
        % Returns the 1-based index of the selected radio button in the group.
        % btn_grp is the uibuttongroup; btn_array is the array of uiradiobutton handles.
        selected = btn_grp.SelectedObject;
        idx = 1;  % default = None (first button)
        for k = 1:numel(btn_array)
            if btn_array(k) == selected
                idx = k;
                return;
            end
        end
    end

    function freqs = auto_detect_interference(x, Fs, lo, hi, thresh_db, max_f, Nfft)
    % AUTO_DETECT_INTERFERENCE  Find narrowband spikes above spectral floor.
    % Duplicates the logic in apply_notch.m so the GUI can call it directly
    % to retrieve and display the detected frequencies separately from filtering.
        N_sig = numel(x);
        if N_sig < Nfft, Nfft = 2^nextpow2(N_sig); end
        hop   = Nfft/2;
        win_h = hann(Nfft);
        n_seg = max(1, floor((N_sig - Nfft)/hop) + 1);
        P_sum = zeros(Nfft/2+1, 1);
        for k = 1:n_seg
            seg   = x((k-1)*hop+1 : min((k-1)*hop+Nfft, N_sig));
            if numel(seg) < Nfft
                seg(end+1:Nfft) = 0;
            end
            X     = fft(double(seg) .* win_h, Nfft);
            P_sum = P_sum + abs(X(1:Nfft/2+1)).^2;
        end
        P_avg   = P_sum / n_seg;
        f_axis  = (0:Nfft/2)' * Fs / Nfft;
        floor_e = movmedian(P_avg, 21);
        prom_db = 10*log10((P_avg+1e-30)./(floor_e+1e-30));
        mask    = f_axis >= lo & f_axis <= hi;
        psearch = prom_db .* mask;
        min_sep = max(1, round(2*Nfft/Fs));
        [pks, locs] = findpeaks(psearch,'MinPeakHeight',thresh_db,'MinPeakDistance',min_sep);
        if isempty(locs), freqs = []; return; end
        [~,si]  = sort(pks,'descend');
        top_loc = locs(si(1:min(max_f,numel(si))));
        freqs   = sort(f_axis(top_loc))';
    end

    function freqs = generate_random_injection_freqs(Fs, n_tones)
        lo_hz   = 2.0;
        hi_hz   = max(lo_hz + 1.0, Fs/2 - 5.0);
        n_tones = max(1, round(n_tones));

        if hi_hz <= lo_hz + 0.5
            freqs = linspace(lo_hz, hi_hz, n_tones);
            return;
        end

        min_sep = max(2.5, min(8.0, (hi_hz - lo_hz) / (n_tones + 1)));
        freqs   = zeros(1, n_tones);
        k       = 0;
        tries   = 0;

        while k < n_tones && tries < 5000
            tries = tries + 1;
            f_try = lo_hz + (hi_hz - lo_hz) * rand();
            if k == 0 || all(abs(freqs(1:k) - f_try) >= min_sep)
                k = k + 1;
                freqs(k) = f_try;
            end
        end

        if k < n_tones
            fallback = linspace(lo_hz + min_sep, hi_hz - min_sep, n_tones);
            freqs(1:k) = sort(freqs(1:k));
            freqs(k+1:end) = fallback(1:(n_tones-k));
        end

        freqs = sort(freqs(1:n_tones));
    end

end   % end main function

%% ═══════════════════════════════════════════════════════════════════════
%% DIVIDER LINE HELPER
%% ═══════════════════════════════════════════════════════════════════════

function out = rejection_label(rdb)
    if rdb > 40
        out = 'OK: excellent';
    elseif rdb > 20
        out = 'OK: good';
    elseif rdb > 6
        out = 'Partial';
    else
        out = 'Minimal';
    end
end

function out = st_ratio_label(st_ratio_db)
    if st_ratio_db < 6
        out = 'OK: ST ringing within 6 dB of baseline';
    elseif st_ratio_db < 12
        out = 'Moderate ST elevation (possible ringing)';
    else
        out = 'High ST disturbance, likely ringing';
    end
end

function divider_line(parent, y_pos, width)
    uipanel(parent, ...
        'Position', [8 y_pos width 1], ...
        'BackgroundColor', [0.35 0.35 0.4], ...
        'BorderType', 'none');
end

%% ═══════════════════════════════════════════════════════════════════════
%% TERNARY STRING HELPER
%% ═══════════════════════════════════════════════════════════════════════
function out = ternary_str(cond, a, b)
    if cond
        out = a;
    else
        out = b;
    end
end

%% ═══════════════════════════════════════════════════════════════════════
%% EMBEDDED FILTER DEFINITIONS  (firmware reference at 500 Hz only)
%% ═══════════════════════════════════════════════════════════════════════
function BPF = build_bpf_struct()
% Returns the firmware SOS coefficients converted to MATLAB format.
% These are ONLY used for display purposes (BPF.name, BPF.passband etc.)
% and as the 500 Hz reference design.
% For actual data filtering, build_bpf_at_fs(idx, Fs) is used instead.
    B1c = [2.1387987327e-03,4.2775974654e-03,2.1387987327e-03,1.2278758791e+00,-3.9352306025e-01;
           1.0000000000e+00,2.0000000000e+00,1.0000000000e+00,1.4866636732e+00,-6.9496755803e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9882154715e+00,-9.8825641566e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9952467490e+00,-9.9528640681e-01];
    B2c = [4.5140667948e-02,9.0281335896e-02,4.5140667948e-02,1.3191386279e+00,-5.0059036426e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9911187667e+00,-9.9115903129e-01];
    B3c = [1.6700163307e-01,3.3400326614e-01,1.6700163307e-01,-3.2859212077e-01,-6.4561047028e-02;
           1.0000000000e+00,2.0000000000e+00,1.0000000000e+00,-4.5307552772e-01,-4.6646996969e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9988389231e+00,-9.9883931795e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9995189819e+00,-9.9951937664e-01];
    B4c = [6.9581542841e-03,-1.1680047135e-02,6.9581542841e-03,1.8317399972e+00,-8.6239647496e-01;
           1.0000000000e+00,0.0000000000e+00,-1.0000000000e+00,1.8331216942e+00,-8.3608137083e-01;
           1.0000000000e+00,-1.9999702109e+00,1.0000000000e+00,1.9853115238e+00,-9.8562285918e-01];
    B5c = [7.0166798142e-02,1.1292485589e-01,7.0166798142e-02,1.2391752854e+00,-5.0972928164e-01;
           1.0000000000e+00,-1.9999997183e+00,1.0000000000e+00,1.9941439653e+00,-9.9417033109e-01];
    B6c = [2.2251523523e-03,4.4503047046e-03,2.2251523523e-03,1.2143023932e+00,-3.8493902657e-01;
           1.0000000000e+00,2.0000000000e+00,1.0000000000e+00,1.4804920886e+00,-6.8930831592e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9988372871e+00,-9.9883768330e-01;
           1.0000000000e+00,-2.0000000000e+00,1.0000000000e+00,1.9995196592e+00,-9.9952005420e-01];

    all_cmsis = {B1c,B2c,B3c,B4c,B5c,B6c};
    names     = {'B1: Butterworth 8th  0.5-40 Hz', ...
                 'B2: Butterworth 4th  0.5-40 Hz', ...
                 'B3: Butterworth 8th  0.05-150 Hz', ...
                 'B4: Chebyshev II 6th  0.5-40 Hz', ...
                 'B5: Elliptic 4th  0.5-40 Hz', ...
                 'B6: Butterworth 8th  0.05-40 Hz'};
    stages    = [4 2 4 3 2 4];
    passbands = {[0.5 40],[0.5 40],[0.05 150],[0.5 40],[0.5 40],[0.05 40]};
    standards = {'IEC 60601-2-27','Lightweight','IEC 60601-2-25','AHA monitor','Min-order','ST-segment'};

    for b = 1:6
        c = all_cmsis{b};
        n_stg = size(c,1);
        BPF(b).sos      = [c(:,1:3), ones(n_stg,1), -c(:,4), -c(:,5)]; %#ok<AGROW>
        BPF(b).name     = names{b};
        BPF(b).stages   = stages(b);
        BPF(b).passband = passbands{b};
        BPF(b).standard = standards{b};
    end
end

%% ═══════════════════════════════════════════════════════════════════════
%% FS-AWARE FILTER DESIGN  (redesigns at actual data sample rate)
%% ═══════════════════════════════════════════════════════════════════════
function sos_ml = build_bpf_at_fs(bpf_idx, Fs)
% Design the selected BPF at the actual measured sample rate using MATLAB's
% filter design functions. This is what is actually applied to the data.
%
% WHY NOT USE THE FIRMWARE COEFFICIENTS DIRECTLY:
%   Digital filter coefficients encode normalised frequency (0–π rad/sample),
%   not physical Hz. The firmware coefficients were designed for Fs=500 Hz.
%   If the recorded data has a different Fs (e.g. 166.7 Hz in ECG_IMU mode),
%   applying those coefficients shifts all cutoffs proportionally:
%     BPF cutoff = 40 × (Fs_actual / 500) Hz
%   At 166.7 Hz this gives 13.3 Hz — completely wrong.
%   Solution: redesign the same filter topology at the actual data Fs.

    Ny = Fs / 2;   % Nyquist frequency

    passbands = {[0.5 40],[0.5 40],[0.05 150],[0.5 40],[0.5 40],[0.05 40]};
    pb = passbands{bpf_idx};

    % Cap upper frequency at 0.99*Nyquist (B3 can exceed Nyquist at low Fs)
    pb(1) = max(pb(1), 0.01);
    pb(2) = min(pb(2), 0.99 * Ny);

    % Warn if passband is impossible
    if pb(1) >= pb(2)
        warning('B%d: passband [%.2f %.2f] Hz invalid at Fs=%.1f Hz. Using raw signal.', ...
                bpf_idx, pb(1), pb(2), Fs);
        sos_ml = [1 0 0 1 0 0];   % identity (pass-through)
        return;
    end

    Wn = pb / Ny;   % normalised to [0 1] for MATLAB's filter design

    try
        switch bpf_idx
            case 1  % B1: Butterworth 8th order
                [z,p,k] = butter(4, Wn, 'bandpass');
            case 2  % B2: Butterworth 4th order
                [z,p,k] = butter(2, Wn, 'bandpass');
            case 3  % B3: Butterworth 8th order, wide passband
                [z,p,k] = butter(4, Wn, 'bandpass');
            case 4  % B4: Chebyshev II 6th order, 40 dB stopband
                [z,p,k] = cheby2(3, 40, Wn, 'bandpass');
            case 5  % B5: Elliptic 4th order, 0.5 dB pass / 40 dB stop
                [z,p,k] = ellip(2, 0.5, 40, Wn, 'bandpass');
            case 6  % B6: Butterworth 8th order
                [z,p,k] = butter(4, Wn, 'bandpass');
        end
        [sos_ml, g] = zp2sos(z, p, k);
        sos_ml(1,1:3) = sos_ml(1,1:3) * g;   % absorb gain into first stage
    catch e
        warning('Filter design failed at Fs=%.1f Hz: %s', Fs, e.message);
        sos_ml = [1 0 0 1 0 0];
    end
end

function sos_notch = build_notch_at_fs(notch_idx, Fs)
% Build IIR notch SOS at actual Fs. Only valid for N1 (idx=1) and N2 (idx=2).
% Adaptive notches (N3-N8) handle Fs internally via apply_notch(x, type, Fs).
    omega0 = 2*pi*50/Fs;   % 50 Hz target in rad/sample AT ACTUAL FS
    b_n    = [1, -2*cos(omega0), 1];
    r_vals = [0.990, 0.995];
    r      = r_vals(min(notch_idx, 2));
    sos_notch = repmat([b_n, 1, -2*r*cos(omega0), r^2], 6, 1);
end