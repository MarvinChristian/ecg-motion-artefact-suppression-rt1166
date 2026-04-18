%% phase2_notch_eval.m
%
% AUTHOR:   Marvin Christian
% TITLE:    Phase 2 — Notch filter evaluation on recorded ECG
% DATE:     11/04/2026
%
% PREREQUISITE:
%   1. load('resting.mat')
%   2. run('phase2_coefficients.m')
%   3. run('phase2_bpf_eval.m')   → produces BPF_out
%
% OUTPUT:
%   NOTCH_out : N × 8 matrix (notch output for each configuration)
%   Figure 1  : waveform comparison
%   Figure 2  : convergence curves for adaptive filters (N3–N8)
%   Figure 3  : notch depth zoomed to 45–55 Hz
%   Command window: metrics table

if ~exist('BPF_out','var')
    error('Run phase2_bpf_eval.m first — it produces BPF_out.');
end

fprintf('=== Phase 2: Notch Filter Evaluation ===\n\n');

FS         = 500;
MV         = 1800/4096;
N          = numel(ecg_corr);
notch_in   = BPF_out(:,1);   % B1 output is the notch input (BPF → Notch in pipeline)
t_rel      = t_s - t_s(1);
notch_types = {'N1','N2','N3','N4','N5','N6','N7','N8'};
notch_names = {'N1: IIR r=0.990','N2: IIR r=0.995', ...
               'N3: NLMS μ=0.005','N4: NLMS μ=0.010', ...
               'N5: Hybrid IIR+NLMS','N6: RLS λ=0.990', ...
               'N7: Sign-Sign LMS','N8: Hybrid IIR+RLS'};

%% ── Apply all 8 notch filters ───────────────────────────────────────────────
NOTCH_out = zeros(N, 8);
fprintf('Applying notch filters to B1-filtered ECG...\n');
for n = 1:8
    NOTCH_out(:,n) = apply_notch(notch_in, notch_types{n});
    fprintf('  %s\n', notch_names{n});
end
fprintf('\n');

notch_ref = NOTCH_out(:,1);   % N1 is the notch reference (IIR, deterministic)

%% ── Figure 1: Waveform comparison ───────────────────────────────────────────
N_show = min(round(5*FS), N);
t_show = t_rel(1:N_show);
cols   = lines(8);

figure('Name','Notch Waveform Comparison','NumberTitle','off',...
       'Position',[40 80 1400 900]);
for n = 1:8
    subplot(4,2,n);
    plot(t_show, notch_in(1:N_show)*MV, 'Color',[0.65 0.65 0.65], ...
         'LineWidth',0.5,'DisplayName','B1 input');
    hold on;
    plot(t_show, NOTCH_out(1:N_show,n)*MV, 'Color',cols(n,:), ...
         'LineWidth',0.9,'DisplayName',notch_names{n});
    hold off;
    xlabel('Time (s)'); ylabel('mV');
    title(notch_names{n},'FontSize',8);
    legend('FontSize',7,'Box','off','Location','northeast');
    grid on;
end
sgtitle('Notch Filter Waveform Comparison (input: B1 output)', 'FontSize',11);

%% ── Figure 2: Adaptive filter convergence curves ────────────────────────────
% Feed a pure 50 Hz sine into each adaptive notch and plot the running
% residual power. Shows how many samples each filter needs to converge.
%
% Interpretation:
%   Steep drop = fast convergence
%   RLS (N6) should drop fastest (~50 samples / 0.1 s at 500 Hz)
%   NLMS μ=0.005 (N3) ~250 samples / 0.5 s
%   Sign-Sign LMS (N7) ~750 samples / 1.5 s

test_len  = 4000;
t_test    = (0:test_len-1)' / FS;
sine50    = 0.5 * sin(2*pi*50*t_test);
win_rms   = 50;   % running window length for residual RMS

figure('Name','Adaptive Notch Convergence','NumberTitle','off',...
       'Position',[40 80 1200 560]);
hold on;
adaptive_idx = [3 4 5 6 7 8];
for n = adaptive_idx
    out_c   = apply_notch(sine50, notch_types{n});
    rms_run = sqrt(movmean(out_c.^2, win_rms));
    plot(1:test_len, 20*log10(rms_run + 1e-9), ...
         'Color',cols(n,:),'LineWidth',1.4,'DisplayName',notch_names{n});
end

% Reference lines
xline(50,  'k:','LineWidth',0.9,'Label','50 smp (0.1 s)');
xline(250, 'k:','LineWidth',0.9,'Label','250 smp (0.5 s)');
xline(750, 'k:','LineWidth',0.9,'Label','750 smp (1.5 s)');

xlabel('Sample number'); ylabel('Residual power (dB)');
title(sprintf(['Adaptive Notch Convergence on pure 50 Hz sine\n'...
               'Lower = more interference cancelled  (Fs=%d Hz)'], FS));
legend('Location','northeast','FontSize',9); grid on; box on;

%% ── Figure 3: Notch depth zoomed to 45–55 Hz ────────────────────────────────
% For IIR notches (N1, N2) — compute from impulse response.
% For adaptive notches — estimate from steady-state PSD of the test signal.

NFFT_ir = 8192;
f_axis  = (0:NFFT_ir/2) * FS / NFFT_ir;

figure('Name','Notch Depth 45-55 Hz','NumberTitle','off',...
       'Position',[40 80 1000 460]);
hold on;

for n = 1:2
    imp  = [1; zeros(NFFT_ir-1,1)];
    resp = sosfilt(NOTCH(n).sos, imp);
    H_db = 20*log10(abs(fft(resp,NFFT_ir)) + 1e-12);
    plot(f_axis, H_db(1:NFFT_ir/2+1), 'Color',cols(n,:),'LineWidth',1.6,...
         'DisplayName',notch_names{n});
end

% For adaptive: run on a steady-state sinusoidal test and show output PSD
for n = adaptive_idx
    long_test = 0.5*sin(2*pi*50*(0:10000-1)'/FS);
    out_ss    = apply_notch(long_test, notch_types{n});
    steady    = out_ss(5000:end);   % last half = steady state
    [Pxx,f_pw] = pwelch(steady, hamming(512), 256, NFFT_ir, FS);
    % Normalize to dB relative to passband
    semilogy(f_pw, Pxx, 'Color',cols(n,:),'LineWidth',1.2,...
             'LineStyle','--','DisplayName',notch_names{n});
end

xline(50,'r--','50 Hz','LineWidth',1.2);
xlim([45 55]); grid on; box on;
xlabel('Frequency (Hz)'); ylabel('Magnitude');
title('Notch Depth — Zoomed 45–55 Hz  (solid=IIR, dashed=adaptive PSD)');
legend('Location','south','FontSize',8,'NumColumns',2);

%% ── Metrics table ────────────────────────────────────────────────────────────
fprintf('=== NOTCH FILTER PERFORMANCE TABLE ===\n');
fprintf('Reference: N1 (IIR x6 r=0.990 applied to B1 output)\n\n');
fprintf('%-25s  %8s  %7s  %8s  %6s  %12s\n', ...
        'Filter','SNR(dB)','PRD(%%)','RMSE(mV)','r','Conv~(smp)');
fprintf('%s\n', repmat('-',1,75));

conv_est = [0 0 250 125 250 50 750 50];   % approximate, order-of-magnitude;
                                           % the thesis-supported claim is
                                           % RLS/NLMS ~5× ratio (Dai 2019).

for n = 1:8
    [snr_v, prd_v, rmse_v, r_v] = ecg_metrics(notch_ref, NOTCH_out(:,n), 1800/4096);
    conv_str = 'instant';
    if conv_est(n) > 0, conv_str = sprintf('~%d', conv_est(n)); end
    fprintf('%-25s  %8.2f  %7.3f  %8.4f  %6.4f  %12s\n', ...
            notch_names{n}, snr_v, prd_v, rmse_v, r_v, conv_str);
end

fprintf('\nRun phase2_combinations.m next.\n');