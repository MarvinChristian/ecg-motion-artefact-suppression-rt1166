%% phase2_bpf_eval.m
%
% AUTHOR:   Marvin Christian
% TITLE:    Phase 2 — Bandpass filter evaluation on recorded ECG
% DATE:     11/04/2026
%
% PREREQUISITE:
%   1. load('resting.mat')          from phase1_import.m
%   2. run('phase2_coefficients.m') defines BPF struct
%
% OUTPUT:
%   BPF_out   : N × 6 matrix — filtered ECG for each BPF (ADC counts)
%   Figure 1  : waveform comparison, first 5 s
%   Figure 2  : PSD overlay (Welch)
%   Figure 3  : passband magnitude response + ripple measurement
%   Figure 4  : startup transient, first 3 s
%   Command window: metrics table (SNR, PRD, RMSE, r)

if ~exist('ecg_corr','var')
    error('Load resting.mat first:  load(''resting.mat'')');
end
if ~exist('BPF','var')
    run('phase2_coefficients.m');
end

fprintf('=== Phase 2: BPF Evaluation ===\n');
fprintf('Signal: %d samples  Fs=%.1f Hz  Duration=%.1f s\n\n', ...
        numel(ecg_corr), fs_meas, t_s(end)-t_s(1));

FS       = fs_meas;
MV       = 1800/4096;   % counts → mV
N        = numel(ecg_corr);
sig_in   = double(ecg_corr);
t_rel    = t_s - t_s(1);   % start at 0

%% ── Apply all 6 BPFs ────────────────────────────────────────────────────────
BPF_out  = zeros(N, 6);
fprintf('Applying filters (sample-by-sample, matching CMSIS TDF-II)...\n');
for b = 1:6
    BPF_out(:,b) = apply_biquad(BPF(b).sos, sig_in);
    fprintf('  %s\n', BPF(b).name);
end
fprintf('\n');

% B1 is the reference — all metrics measured relative to B1
ref = BPF_out(:,1);

%% ── Figure 1: Waveform comparison ───────────────────────────────────────────
% What to look for:
%   QRS peak sharpness — rounding means the filter cutoff is too low
%   Baseline stability — slow drift visible in B3/B6 (lower HP cutoff)
%   Post-QRS ringing  — elliptic and Chebyshev II can oscillate after sharp transients
%   Overlap with B1   — B2 should closely match B1 but with slightly less attenuation

N_show = min(round(5*FS), N);
t_show = t_rel(1:N_show);
cols   = lines(6);

figure('Name','BPF Waveform Comparison','NumberTitle','off',...
       'Position',[40 80 1400 860]);
for b = 1:6
    subplot(3,2,b);
    plot(t_show, sig_in(1:N_show)*MV, 'Color',[0.65 0.65 0.65], ...
         'LineWidth',0.5,'DisplayName','Raw');
    hold on;
    plot(t_show, BPF_out(1:N_show,b)*MV, 'Color',cols(b,:), ...
         'LineWidth',0.9,'DisplayName',BPF(b).name);
    if b > 1   % overlay B1 reference
        plot(t_show, BPF_out(1:N_show,1)*MV, 'r--', ...
             'LineWidth',0.6,'DisplayName','B1 ref');
    end
    hold off;
    xlabel('Time (s)'); ylabel('mV');
    title(sprintf('%s  (%d stages)', BPF(b).name, BPF(b).stages), 'FontSize',9);
    legend('Location','northeast','FontSize',7,'Box','off');
    grid on;
end
sgtitle('Bandpass Filter Waveform Comparison — First 5 Seconds', 'FontSize',11);

%% ── Figure 2: Power Spectral Density ────────────────────────────────────────
% Welch's method — more reliable than raw FFT for physiological signals.
% What to look for:
%   50 Hz spike  — should be clearly visible in raw signal if recorded indoors
%   QRS energy   — concentrated around 5–15 Hz (Pan & Tompkins 1985 BPF passband)
%   Baseline wander energy — below 1 Hz, more visible in B3/B6
% Note: the AD8233 analog chain already attenuates above ~25 Hz (Sallen-Key
% LP cutoff on the eval board), so the PSD above 25 Hz is shaped by that
% analog filter before any digital BPF is applied.

win_len = min(1024, floor(N/4));
pw_win  = hamming(win_len);
pw_nov  = floor(win_len/2);
NFFT_pw = 2048;

figure('Name','PSD Comparison','NumberTitle','off',...
       'Position',[40 80 1100 520]);
hold on;
[Pxx_raw, f_pw] = pwelch(sig_in*MV, pw_win, pw_nov, NFFT_pw, FS);
semilogy(f_pw, Pxx_raw, 'Color',[0.55 0.55 0.55], 'LineWidth',0.8, 'DisplayName','Raw ECG');
for b = 1:6
    [Pxx,~] = pwelch(BPF_out(:,b)*MV, pw_win, pw_nov, NFFT_pw, FS);
    semilogy(f_pw, Pxx, 'Color',cols(b,:), 'LineWidth',1.2, 'DisplayName',BPF(b).name);
end
xline(0.5,'k--','LineWidth',0.7); xline(40,'k--','LineWidth',0.7);
xline(25, 'm:', 'AD8233 analog LP (~25 Hz)','LineWidth',0.9);
xline(50, 'r:', '50 Hz','LineWidth',0.9);
xlim([0 80]); grid on; box on;
xlabel('Frequency (Hz)'); ylabel('PSD (mV²/Hz)');
title('Power Spectral Density — Raw vs Filtered');
legend('Location','southwest','FontSize',8);

%% ── Figure 3: Passband magnitude + ripple ───────────────────────────────────
NFFT_ir = 8192;
f_axis  = (0:NFFT_ir/2) * FS / NFFT_ir;

figure('Name','BPF Passband Ripple','NumberTitle','off',...
       'Position',[40 80 1100 480]);

subplot(1,2,1); hold on;
ripple = zeros(1,6);
for b = 1:6
    imp  = [1; zeros(NFFT_ir-1,1)];
    resp = apply_biquad(BPF(b).sos, imp);
    H_db = 20*log10(abs(fft(resp,NFFT_ir)) + 1e-12);
    H_db = H_db(1:NFFT_ir/2+1);
    pb   = f_axis >= BPF(b).passband(1) & f_axis <= BPF(b).passband(2);
    ripple(b) = max(H_db(pb)) - min(H_db(pb));
    plot(f_axis, H_db, 'Color',cols(b,:), 'LineWidth',1.4, ...
         'DisplayName', sprintf('%s (%.3f dB)', BPF(b).name, ripple(b)));
end
xline(0.5,'k--'); xline(40,'k--');
xlim([0.2 60]); ylim([-5 3]);
xlabel('Frequency (Hz)'); ylabel('Magnitude (dB)');
title('Passband Region (zoom)'); legend('Location','southwest','FontSize',7); grid on; box on;

subplot(1,2,2);
bar(ripple, 'FaceColor', [0.3 0.55 0.8]);
set(gca,'XTickLabel',{'B1','B2','B3','B4','B5','B6'});
xlabel('Filter'); ylabel('Passband Ripple (dB)');
title('Peak-to-peak Passband Ripple');
yline(0.5,'r--','0.5 dB limit','LineWidth',1.0);
yline(1.0,'r:','1.0 dB','LineWidth',0.8);
grid on; box on;
% Note: Butterworth = ~0 dB (maximally flat).
%       Elliptic B5 allows 0.5 dB by design.
%       Any filter > 1 dB is clinically problematic for waveform morphology.

%% ── Figure 4: Startup transient ─────────────────────────────────────────────
% IIR filters initialised with zero state produce a transient at recording
% start. This shows how many samples each filter needs before it settles.
% A long transient (> 1 s) could cause missed beats if the recording begins
% immediately when electrodes are attached. Phase 4 firmware uses warm-start
% Kalman initialisation to mitigate this.

N_tr = min(round(3*FS), N);
figure('Name','BPF Startup Transient','NumberTitle','off',...
       'Position',[40 80 1000 380]);
hold on;
for b = 1:6
    plot(t_rel(1:N_tr), BPF_out(1:N_tr,b)*MV, 'Color',cols(b,:), ...
         'LineWidth',0.9,'DisplayName',BPF(b).name);
end
xlabel('Time (s)'); ylabel('mV');
title('Filter Startup Transient — First 3 s (zero initial conditions)');
legend('Location','northeast','FontSize',8); grid on; box on;

%% ── Metrics table ────────────────────────────────────────────────────────────
fprintf('=== BANDPASS FILTER PERFORMANCE TABLE ===\n');
fprintf('Reference: B1 (Butterworth 8th, 0.5–40 Hz)\n');
fprintf('PRD < 9%% = evaluation convention from ECG compression literature (Reddy & Murthy 1986)\n\n');
fprintf('%-32s  %4s  %8s  %7s  %8s  %6s  %8s\n', ...
        'Filter','Stg','SNR(dB)','PRD(%%)','RMSE(mV)','r','Ripple(dB)');
fprintf('%s\n', repmat('-',1,82));

BPF_metrics = zeros(6,4);
for b = 1:6
    [snr_v, prd_v, rmse_v, r_v] = ecg_metrics(ref, BPF_out(:,b), MV);
    BPF_metrics(b,:) = [snr_v, prd_v, rmse_v, r_v];
    flag = '';
    if prd_v > 9, flag = '  ← exceeds 9%%'; end
    fprintf('%-32s  %4d  %8.2f  %7.3f  %8.4f  %6.4f  %8.4f%s\n', ...
            BPF(b).name, BPF(b).stages, snr_v, prd_v, rmse_v, r_v, ripple(b), flag);
end

[~, best_b] = min(BPF_metrics(:,2));
fprintf('\nBest by PRD: %s\n', BPF(best_b).name);
fprintf('\nRun phase2_notch_eval.m next.\n');