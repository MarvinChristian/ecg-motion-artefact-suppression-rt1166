function imu_ecg_sim_gui()
% IMU_ECG_SIM_GUI  Lightweight ADS1293+IMU replay with selectable filters.
%
% Loads a 21-column ADS1293_IMU recording and replays it with fixed axes.
% ECG filtering is cached when BPF/notch dropdowns change; timer ticks only
% move the cursor and update plotted window data.

LSB_PER_G = 16384;
ADS_SCALE = 1400 / 8388607;
WINDOW_S = 10;
REFRESH_MS = 40;
SPEED_OPTS = {'0.5x','1x','2x','4x'};
SPEED_VALS = [0.5 1 2 4];
ECG_YLIM = [-1.8 1.8];
IMU_YLIM = [0.4 1.8];
BG = [0.10 0.10 0.12];
BG2 = [0.14 0.14 0.17];
FG = [0.88 0.88 0.88];
DIM = [0.58 0.58 0.58];

BPF_NAMES = {'B1: Butterworth 8th 0.5-40 Hz', ...
             'B2: Butterworth 4th 0.5-40 Hz', ...
             'B3: Butterworth 8th 0.05-150 Hz', ...
             'B4: Chebyshev II 10th 0.5-40 Hz', ...
             'B5: Elliptic 4th 0.5-40 Hz', ...
             'B6: Butterworth 8th 0.05-40 Hz', ...
             'B7: Butterworth 8th 0.75-40 Hz'};
BPF_ITEMS = [{'No BPF'}, BPF_NAMES];
NOTCH_NAMES = {'N1: IIR x6 r=0.990', ...
               'N3: NLMS mu=0.005', ...
               'N5: Hybrid IIR+NLMS', ...
               'N6: RLS lambda=0.990', ...
               'N8: Hybrid IIR+RLS', ...
               'N9: Auto-detect multi-freq'};
NOTCH_ITEMS = [{'No notch'}, NOTCH_NAMES];
NOTCH_TYPES = {'N1','N3','N5','N6','N8','N9'};

d = [];
pos = 1;
playing = false;
speed_v = 1;

fig = uifigure('Name','IMU-ECG Streaming Simulation', ...
    'Position',[40 40 1440 900], 'Color',BG);
ctrl = uipanel(fig,'Position',[0 858 1440 42], ...
    'BackgroundColor',BG2,'BorderType','none');

uibutton(ctrl,'Text','Browse / Load','Position',[8 8 120 26], ...
    'BackgroundColor',[0.20 0.48 0.28],'FontColor','w', ...
    'ButtonPushedFcn',@(~,~)load_file());
play_btn = uibutton(ctrl,'Text','Play','Position',[136 8 80 26], ...
    'BackgroundColor',[0.22 0.40 0.68],'FontColor','w','Enable','off', ...
    'ButtonPushedFcn',@(~,~)play_pause());
uibutton(ctrl,'Text','Reset','Position',[224 8 65 26], ...
    'BackgroundColor',[0.28 0.28 0.32],'FontColor',FG, ...
    'ButtonPushedFcn',@(~,~)reset_playback());

uilabel(ctrl,'Text','Speed:','Position',[302 12 46 18], ...
    'FontColor',DIM,'FontSize',9);
speed_dd = uidropdown(ctrl,'Items',SPEED_OPTS,'Value','1x', ...
    'Position',[350 8 62 26], 'BackgroundColor',[0.16 0.16 0.20], ...
    'FontColor',FG, 'ValueChangedFcn',@(~,~)set_speed());

uilabel(ctrl,'Text','BPF:','Position',[426 12 32 18], ...
    'FontColor',DIM,'FontSize',9);
bpf_dd = uidropdown(ctrl,'Items',BPF_ITEMS,'Value','No BPF', ...
    'Position',[460 8 220 26], 'BackgroundColor',[0.16 0.16 0.20], ...
    'FontColor',FG, 'ValueChangedFcn',@(~,~)refresh_filters());
uilabel(ctrl,'Text','Notch:','Position',[692 12 42 18], ...
    'FontColor',DIM,'FontSize',9);
notch_dd = uidropdown(ctrl,'Items',NOTCH_ITEMS,'Value','No notch', ...
    'Position',[738 8 220 26], 'BackgroundColor',[0.16 0.16 0.20], ...
    'FontColor',FG, 'ValueChangedFcn',@(~,~)refresh_filters());
uilabel(ctrl,'Text','Lead:','Position',[970 12 36 18], ...
    'FontColor',DIM,'FontSize',9);
lead_dd = uidropdown(ctrl,'Items',{'Lead I (CH1)','Lead II (CH2)'}, ...
    'Value','Lead I (CH1)', 'Position',[1008 8 132 26], ...
    'BackgroundColor',[0.16 0.16 0.20], 'FontColor',FG, ...
    'ValueChangedFcn',@(~,~)update_display());
file_lbl = uilabel(ctrl,'Text','No file loaded.', ...
    'Position',[1150 12 280 18], 'FontColor',DIM, 'FontSize',8.5);

prog = uislider(fig,'Position',[8 850 1424 3], 'Limits',[0 1], ...
    'Value',0,'MajorTicks',[],'MinorTicks',[],'Enable','off', ...
    'ValueChangedFcn',@(src,~)seek(src.Value), ...
    'ValueChangingFcn',@(~,evt)seek(evt.Value));

ax_ecg = uiaxes(fig,'Position',[10 450 990 392], ...
    'Color',[0.07 0.07 0.09],'XColor',DIM,'YColor',DIM, ...
    'GridColor',[0.22 0.22 0.22],'XGrid','on','YGrid','on');
ax_ecg.XLim = [0 WINDOW_S]; ax_ecg.YLim = ECG_YLIM;
ax_ecg.XLimMode = 'manual'; ax_ecg.YLimMode = 'manual';
xlabel(ax_ecg,'Time in window (s)','Color',DIM);
ylabel(ax_ecg,'mV','Color',DIM);
title(ax_ecg,'ECG - load a file','Color',FG);
ecg_ln = line(ax_ecg,NaN,NaN,'Color',[0.40 0.65 0.95],'LineWidth',0.9);
rpk_ln = line(ax_ecg,NaN,NaN,'Color',[0.95 0.50 0.28], ...
    'LineStyle','none','Marker','v','MarkerSize',7);

ax_imu = uiaxes(fig,'Position',[10 55 990 385], ...
    'Color',[0.07 0.07 0.09],'XColor',DIM,'YColor',DIM, ...
    'GridColor',[0.22 0.22 0.22],'XGrid','on','YGrid','on');
ax_imu.XLim = [0 WINDOW_S]; ax_imu.YLim = IMU_YLIM;
ax_imu.XLimMode = 'manual'; ax_imu.YLimMode = 'manual';
xlabel(ax_imu,'Time in window (s)','Color',DIM);
ylabel(ax_imu,'|a| (g)','Color',DIM);
title(ax_imu,'IMU Acceleration Magnitude','Color',FG);
imu_clr = {[0.90 0.35 0.35],[0.35 0.88 0.45],[0.35 0.65 0.95]};
imu_lbl = {'LL (IMU0)','LA (IMU1)','RA (IMU2)'};
imu_ln = gobjects(3,1);
for k = 1:3
    imu_ln(k) = line(ax_imu,NaN,NaN,'Color',imu_clr{k}, ...
        'LineWidth',0.8,'DisplayName',imu_lbl{k});
end
legend(ax_imu,'Location','northeast','TextColor',FG, ...
    'Color',[0.10 0.10 0.13],'EdgeColor',[0.28 0.28 0.32]);

panel = uipanel(fig,'Position',[1010 55 422 787], ...
    'BackgroundColor',BG2,'BorderType','none');
hr_lbl = uilabel(panel,'Text','-- bpm','Position',[10 720 402 42], ...
    'FontSize',30,'FontWeight','bold','FontColor',[0.35 0.85 0.55], ...
    'HorizontalAlignment','center');
rr_lbl = uilabel(panel,'Text','RR: -- ms','Position',[10 690 402 22], ...
    'FontSize',11,'FontColor',DIM,'HorizontalAlignment','center');
qrs_lbl = uilabel(panel,'Text','QRS: -- mV','Position',[10 650 402 24], ...
    'FontSize',14,'FontColor',FG,'HorizontalAlignment','center');
qual_lbl = uilabel(panel,'Text','--','Position',[10 590 402 36], ...
    'FontSize',22,'FontWeight','bold','FontColor',DIM, ...
    'HorizontalAlignment','center');
time_lbl = uilabel(panel,'Text','0.0 s / -- s','Position',[10 540 402 24], ...
    'FontSize',13,'FontColor',FG,'HorizontalAlignment','center');
info_lbl = uilabel(panel,'Text','Load a file to begin.', ...
    'Position',[10 10 402 500],'FontSize',9,'FontColor',DIM, ...
    'VerticalAlignment','top','WordWrap','on','FontName','Courier New');

tmr = timer('Name','EcgSimTimer','ExecutionMode','fixedRate', ...
    'Period',REFRESH_MS/1e3,'TimerFcn',@on_tick);
fig.CloseRequestFcn = @close_gui;

    function load_file()
        [fn, fp] = uigetfile({'*.txt;*.csv','Recording files (*.txt, *.csv)'; '*.*','All files'}, ...
            'Select ADS1293_IMU recording');
        if isequal(fn,0), return; end
        file_lbl.Text = ['Loading ' fn ' ...']; drawnow;
        try
            precompute(fullfile(fp, fn));
            update_filter_cache();
            pos = 1;
            play_btn.Enable = 'on';
            prog.Enable = 'on';
            update_display();
            file_lbl.Text = sprintf('%s | Fs %.0f Hz | %.1f s', fn, d.Fs, d.t_s(end));
        catch e
            file_lbl.Text = ['Error: ' e.message];
        end
    end

    function play_pause()
        if isempty(d), return; end
        if playing
            stop(tmr); playing = false;
            play_btn.Text = 'Play';
        else
            if pos >= d.N, pos = 1; end
            playing = true;
            play_btn.Text = 'Pause';
            if strcmp(tmr.Running,'off'), start(tmr); end
        end
    end

    function reset_playback()
        if strcmp(tmr.Running,'on'), stop(tmr); end
        playing = false; play_btn.Text = 'Play'; pos = 1; prog.Value = 0;
        if ~isempty(d), update_display(); end
    end

    function set_speed()
        idx = strcmp(SPEED_OPTS, speed_dd.Value);
        if any(idx), speed_v = SPEED_VALS(idx); end
    end

    function seek(frac)
        if isempty(d), return; end
        pos = max(1, min(d.N, round(frac * d.N)));
        update_display();
    end

    function refresh_filters()
        if isempty(d), return; end
        was_playing = playing;
        if strcmp(tmr.Running,'on'), stop(tmr); end
        playing = false; play_btn.Text = 'Filtering...'; drawnow limitrate;
        update_filter_cache();
        update_display();
        play_btn.Text = ternary(was_playing, 'Pause', 'Play');
        playing = was_playing;
        if was_playing && strcmp(tmr.Running,'off'), start(tmr); end
    end

    function on_tick(~,~)
        if ~playing || isempty(d), return; end
        pos = pos + max(1, round(d.Fs * REFRESH_MS/1e3 * speed_v));
        if pos >= d.N
            pos = d.N; playing = false; stop(tmr); play_btn.Text = 'Play';
        end
        update_display();
    end

    function update_display()
        if isempty(d), return; end
        t_now = d.t_s(pos);
        t0 = max(0, t_now - WINDOW_S);
        wm = d.t_s >= t0 & d.t_s <= t_now;
        if ~any(wm), return; end
        t_rel = d.t_s(wm) - t0;
        ch = 1 + strcmp(lead_dd.Value, 'Lead II (CH2)');
        esrc = d.ecg_view(:, ch);

        set(ecg_ln,'XData',t_rel,'YData',esrc(wm));
        ax_ecg.XLim = [0 WINDOW_S]; ax_ecg.YLim = ECG_YLIM;
        i_lo = find(wm,1,'first'); i_hi = find(wm,1,'last');
        rp_w = d.rpeak_idx(d.rpeak_idx >= i_lo & d.rpeak_idx <= i_hi);
        if isempty(rp_w)
            set(rpk_ln,'XData',NaN,'YData',NaN);
        else
            set(rpk_ln,'XData',d.t_s(rp_w)-t0,'YData',esrc(rp_w));
        end

        for kk = 1:3
            set(imu_ln(kk),'XData',t_rel,'YData',d.imag(wm,kk));
        end
        ax_imu.XLim = [0 WINDOW_S]; ax_imu.YLim = IMU_YLIM;

        rp_b = d.rpeak_idx(d.rpeak_idx <= pos);
        if numel(rp_b) >= 2
            rr = d.t_s(rp_b(end)) - d.t_s(rp_b(end-1));
            hr_lbl.Text = sprintf('%.0f bpm', 60/rr);
            rr_lbl.Text = sprintf('RR: %.0f ms', rr*1000);
        else
            hr_lbl.Text = '-- bpm'; rr_lbl.Text = 'RR: -- ms';
        end
        if ~isempty(rp_b)
            pk = rp_b(end);
            seg = esrc(max(1,pk-10):min(numel(esrc),pk+10));
            qrs_lbl.Text = sprintf('QRS: %.3f mV', max(seg)-min(seg));
        else
            qrs_lbl.Text = 'QRS: -- mV';
        end

        mr = d.motion_rms(pos,:);
        if max(mr) < 0.05
            qual_lbl.Text = 'CLEAN'; qual_lbl.FontColor = [0.28 0.85 0.45];
        elseif max(mr) < 0.20
            qual_lbl.Text = 'MOTION-RISK'; qual_lbl.FontColor = [0.90 0.75 0.22];
        else
            qual_lbl.Text = 'CORRUPTED'; qual_lbl.FontColor = [0.90 0.35 0.35];
        end
        prog.Value = (pos-1) / max(d.N-1, 1);
        time_lbl.Text = sprintf('%.1f s / %.1f s', t_now, d.t_s(end));
        title(ax_ecg, sprintf('ECG - %s | %s | %s', ...
            lead_dd.Value, bpf_dd.Value, notch_dd.Value), 'Color',FG);
    end

    function precompute(fpath)
        raw = readmatrix(fpath,'NumHeaderLines',1,'Delimiter',',','FileType','text');
        if isempty(raw), error('No numeric data found.'); end
        if size(raw,2) ~= 21
            error('Expected 21-column ADS1293_IMU file, got %d columns.', size(raw,2));
        end
        raw = double(raw);
        for c = 2:size(raw,2)
            m = raw(:,c) > 2147483647;
            raw(m,c) = raw(m,c) - 4294967296;
        end
        bad = any(abs(raw(:,4:21)) > 1e6, 2);
        raw = raw(~bad,:);
        if isempty(raw), error('All rows rejected as malformed.'); end
        tu = raw(:,1);
        w = find(diff(tu) < 0, 1);
        if ~isempty(w), tu(w+1:end) = tu(w+1:end) + 4294967296; end
        tu = tu - tu(1);
        ts = tu / 1e6;
        dt = diff(ts); dt = dt(dt > 0);
        Fs = 1 / median(dt);
        N = numel(ts);

        ecg = zeros(N,2);
        for ch = 1:2
            x = raw(:,1+ch) * ADS_SCALE;
            x = despike(x, Fs);
            ecg(:,ch) = x - median(x,'omitnan');
        end

        imag = zeros(N,3);
        for kk = 1:3
            c0 = 4 + (kk-1)*6;
            ax = raw(:,c0) / LSB_PER_G;
            ay = raw(:,c0+1) / LSB_PER_G;
            az = raw(:,c0+2) / LSB_PER_G;
            imag(:,kk) = sqrt(ax.^2 + ay.^2 + az.^2);
        end
        ws = max(3, round(5 * Fs));
        mr = zeros(N,3);
        for kk = 1:3
            ac = imag(:,kk) - movmean(imag(:,kk), ws);
            mr(:,kk) = sqrt(max(0, movmean(ac.^2, ws)));
        end

        d.t_s = ts; d.Fs = Fs; d.N = N;
        d.ecg_base = ecg; d.ecg_view = ecg;
        d.imag = imag; d.motion_rms = mr;
        d.rpeak_idx = detect_rpeaks(apply_biquad(build_bpf(1, Fs), ecg(:,1)), Fs);
        info_lbl.Text = sprintf('Fs: %.1f Hz\nDuration: %.1f s\nSamples: %d\n\nFixed axes: ECG %.1f..%.1f mV, IMU %.1f..%.1f g', ...
            Fs, ts(end), N, ECG_YLIM(1), ECG_YLIM(2), IMU_YLIM(1), IMU_YLIM(2));
    end

    function update_filter_cache()
        [bpf_idx, notch_idx] = selected_filters();
        yv = zeros(size(d.ecg_base));
        sos = [];
        if bpf_idx > 0, sos = build_bpf(bpf_idx, d.Fs); end
        for ch = 1:2
            y = d.ecg_base(:,ch);
            if bpf_idx > 0, y = apply_biquad(sos, y); end
            if notch_idx > 0, y = apply_notch(y, NOTCH_TYPES{notch_idx}, d.Fs); end
            yv(:,ch) = y;
        end
        d.ecg_view = yv;
        d.rpeak_idx = detect_rpeaks(yv(:,1), d.Fs);
    end

    function [bpf_idx, notch_idx] = selected_filters()
        bpf_idx = find(strcmp(BPF_ITEMS, bpf_dd.Value), 1) - 1;
        notch_idx = find(strcmp(NOTCH_ITEMS, notch_dd.Value), 1) - 1;
        if isempty(bpf_idx), bpf_idx = 0; end
        if isempty(notch_idx), notch_idx = 0; end
    end

    function sos = build_bpf(idx, Fs)
        Ny = Fs / 2;
        pbs = {[0.5 40],[0.5 40],[0.05 150],[0.5 40],[0.5 40],[0.05 40],[0.75 40]};
        pb = pbs{idx};
        pb(1) = max(pb(1), 0.01);
        pb(2) = min(pb(2), 0.99*Ny);
        if pb(1) >= pb(2), sos = [1 0 0 1 0 0]; return; end
        Wn = pb / Ny;
        switch idx
            case 1, [z,p,k] = butter(4, Wn, 'bandpass');
            case 2, [z,p,k] = butter(2, Wn, 'bandpass');
            case 3, [z,p,k] = butter(4, Wn, 'bandpass');
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
            case {6,7}, [z,p,k] = butter(4, Wn, 'bandpass');
        end
        [sos,g] = zp2sos(z,p,k);
        sos(1,1:3) = sos(1,1:3) * g;
    end

    function r = detect_rpeaks(x, Fs)
        x = double(x(:));
        hi = min(35, 0.48*Fs);
        lo = min(10, 0.45*hi);
        if lo < hi
            [b,a] = butter(2, [lo hi]/(Fs/2), 'bandpass');
            q = filter(b,a,x);
        else
            q = x;
        end
        env = movmean(q.^2, max(3, round(0.08*Fs)));
        th = max(0.01*max(env), 0.5*movmax(env, max(3, round(2*Fs))));
        [~,r] = findpeaks(env .* double(env > th), ...
            'MinPeakDistance', round(0.25*Fs));
    end

    function y = despike(x, Fs)
        x = double(x(:));
        win = max(3, 2*floor(0.25*Fs)+1);
        bl = medfilt1(x, win, 'truncate');
        res = x - bl;
        madv = median(abs(res - median(res)));
        if madv < 1e-12, y = x; return; end
        bad = abs(res) > max(5*madv, 1.5);
        y = x;
        if any(bad)
            good = find(~bad);
            if numel(good) >= 2
                y(bad) = interp1(good, y(good), find(bad), 'linear','extrap');
            end
        end
    end

    function s = ternary(cond, a, b)
        if cond, s = a; else, s = b; end
    end

    function close_gui(~,~)
        if strcmp(tmr.Running,'on'), stop(tmr); end
        delete(tmr);
        delete(fig);
    end
end
