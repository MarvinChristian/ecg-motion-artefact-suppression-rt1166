%% phase2_combinations.m
%
% AUTHOR:   Marvin Christian
% TITLE:    Phase 2 — Full BPF × Notch combination matrix (48 combinations)
% DATE:     11/04/2026
%
% PREREQUISITE:
%   1. load('resting.mat')
%   2. run('phase2_coefficients.m')
%   3. run('phase2_bpf_eval.m')    → BPF_out in workspace
%   4. run('phase2_notch_eval.m')  → NOTCH_out, notch_in in workspace
%
% OUTPUT:
%   SNR_mat, PRD_mat, R_mat : 6×8 metric matrices
%   Figure 1  : SNR heatmap
%   Figure 2  : PRD heatmap
%   Figure 3  : Pearson r heatmap
%   Figure 4  : top 3 combinations waveform overlay
%   Command window: ranked top-10 table
%   Saved: phase2_results.mat

if ~exist('BPF_out','var') || ~exist('NOTCH_out','var')
    error('Run phase2_bpf_eval.m and phase2_notch_eval.m first.');
end

fprintf('=== Phase 2: BPF × Notch Combination Matrix ===\n\n');

FS  = fs_meas;
MV  = 1800/4096;
N   = numel(ecg_corr);

notch_types = {'N1','N2','N3','N4','N5','N6','N7','N8'};
bpf_labels  = {BPF.name};
notch_labels= {'N1 IIR 0.990','N2 IIR 0.995','N3 NLMS 0.005','N4 NLMS 0.010',...
               'N5 Hyb IIR+NLMS','N6 RLS 0.990','N7 SignLMS','N8 Hyb IIR+RLS'};

% Reference: B1 + N1
ref = NOTCH_out(:,1);   % already B1 → N1

%% ── Compute all 48 combinations ─────────────────────────────────────────────
SNR_mat  = zeros(6,8);
PRD_mat  = zeros(6,8);
R_mat    = zeros(6,8);
RMSE_mat = zeros(6,8);

fprintf('Computing 48 combinations...\n');
for b = 1:6
    bpf_out_b = apply_biquad(BPF(b).sos, double(ecg_corr));
    for n = 1:8
        combo = apply_notch(bpf_out_b, notch_types{n});
        [snr_v, prd_v, rmse_v, r_v] = ecg_metrics(ref, combo, MV);
        SNR_mat(b,n)  = snr_v;
        PRD_mat(b,n)  = prd_v;
        R_mat(b,n)    = r_v;
        RMSE_mat(b,n) = rmse_v;
    end
    fprintf('  B%d done\n', b);
end
fprintf('\n');

%% ── Figure 1: SNR heatmap ────────────────────────────────────────────────────
% Higher = output more similar to B1+N1 reference.
% Look for which row (BPF) and column (Notch) consistently scores highest.

figure('Name','SNR Heatmap','NumberTitle','off','Position',[40 80 1050 400]);
heatmap(notch_labels, bpf_labels, SNR_mat, ...
        'Title', 'SNR (dB) relative to B1+N1   [higher = better]', ...
        'XLabel','Notch Filter','YLabel','Bandpass Filter', ...
        'Colormap', parula, 'FontSize', 8, 'ColorbarVisible','on');

%% ── Figure 2: PRD heatmap ────────────────────────────────────────────────────
% Lower = less waveform distortion relative to B1+N1.
% PRD < 9% — evaluation convention (Reddy & Murthy 1986); not a clinical standard.

figure('Name','PRD Heatmap','NumberTitle','off','Position',[40 80 1050 400]);
heatmap(notch_labels, bpf_labels, PRD_mat, ...
        'Title', 'PRD (%) relative to B1+N1   [lower = less distortion]', ...
        'XLabel','Notch Filter','YLabel','Bandpass Filter', ...
        'Colormap', flipud(hot), 'FontSize', 8, 'ColorbarVisible','on');

%% ── Figure 3: Pearson r heatmap ─────────────────────────────────────────────
% Higher = better morphological similarity to reference.
% Target: r > 0.98.

figure('Name','Pearson r Heatmap','NumberTitle','off','Position',[40 80 1050 400]);
heatmap(notch_labels, bpf_labels, R_mat, ...
        'Title', 'Pearson r relative to B1+N1   [higher = better morphology match]', ...
        'XLabel','Notch Filter','YLabel','Bandpass Filter', ...
        'Colormap', parula, 'FontSize', 8, 'ColorbarVisible','on');

%% ── Ranked top-10 table ──────────────────────────────────────────────────────
% Sort by PRD (ascending) then r (descending) as tiebreaker.
% B1+N1 scores PRD≈0 by definition — excluded from ranking.

[b_rank, n_rank] = ind2sub([6,8], sortrows([PRD_mat(:), 1-R_mat(:)]));

fprintf('=== TOP 10 COMBINATIONS (lowest PRD vs B1+N1) ===\n');
fprintf('Excluding B1+N1 self-reference (PRD≈0 by definition)\n\n');
fprintf('%-3s  %-20s  %-22s  %8s  %7s  %6s  %8s\n', ...
        'Rnk','BPF','Notch','SNR(dB)','PRD(%%)','r','RMSE(mV)');
fprintf('%s\n', repmat('-',1,80));

shown = 0;
for k = 1:48
    b = b_rank(k); n = n_rank(k);
    if b==1 && n==1, continue; end
    shown = shown + 1;
    fprintf('%-3d  %-20s  %-22s  %8.2f  %7.3f  %6.4f  %8.5f\n', ...
            shown, sprintf('B%d',b), notch_labels{n}, ...
            SNR_mat(b,n), PRD_mat(b,n), R_mat(b,n), RMSE_mat(b,n));
    if shown >= 10, break; end
end

%% ── Figure 4: Top 3 waveform comparison ─────────────────────────────────────
t_rel  = t_s - t_s(1);
N_show = min(round(5*FS), N);
t_show = t_rel(1:N_show);

figure('Name','Top 3 Combinations','NumberTitle','off',...
       'Position',[40 80 1300 660]);

shown = 0;
for k = 1:48
    b = b_rank(k); n = n_rank(k);
    if b==1 && n==1, continue; end
    shown = shown + 1;
    if shown > 3, break; end

    bpf_b = apply_biquad(BPF(b).sos, double(ecg_corr));
    combo = apply_notch(bpf_b, notch_types{n});

    subplot(3,1,shown);
    plot(t_show, ref(1:N_show)*MV, 'r--', 'LineWidth',0.8, 'DisplayName','B1+N1 ref');
    hold on;
    plot(t_show, combo(1:N_show)*MV, 'b', 'LineWidth',0.9, ...
         'DisplayName', sprintf('B%d + %s', b, notch_labels{n}));
    hold off;
    xlabel('Time (s)'); ylabel('mV');
    title(sprintf('Rank %d: B%d + %s  |  PRD=%.3f%%  r=%.4f', ...
          shown, b, notch_labels{n}, PRD_mat(b,n), R_mat(b,n)), 'FontSize',9);
    legend('Location','northeast','FontSize',8,'Box','off'); grid on;
end
sgtitle('Top 3 BPF × Notch Combinations vs B1+N1 Reference','FontSize',11);

%% ── Save and print recommendation ───────────────────────────────────────────
save('phase2_results.mat', 'SNR_mat','PRD_mat','RMSE_mat','R_mat', ...
     'bpf_labels','notch_labels','b_rank','n_rank');

% Find best non-self-reference combination
best_k = find(~(b_rank==1 & n_rank==1), 1);
best_b = b_rank(best_k);
best_n = n_rank(best_k);

fprintf('\n=== PHASE 2 RECOMMENDATION ===\n');
fprintf('Best BPF+Notch combination (lowest PRD, highest morphology fidelity):\n');
fprintf('  BPF   : B%d — %s\n', best_b, BPF(best_b).name);
fprintf('  Notch : N%d — %s\n', best_n, notch_labels{best_n});
fprintf('  PRD   : %.3f%%  SNR: %.2f dB  r: %.4f\n', ...
        PRD_mat(best_b,best_n), SNR_mat(best_b,best_n), R_mat(best_b,best_n));
fprintf('\nSet in app_config.h for Phase 4:\n');
fprintf('  #define APP_BPF_CONFIG   APP_BPF_B%d\n', best_b);
fprintf('  #define APP_NOTCH_CONFIG APP_NOTCH_N%d\n', best_n);
fprintf('\nResults saved: phase2_results.mat\n');
fprintf('Next: run the Phase 3 MAS scripts on your motion recordings.\n');