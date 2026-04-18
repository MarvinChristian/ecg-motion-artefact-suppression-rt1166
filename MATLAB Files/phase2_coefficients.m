%% phase2_coefficients.m
%
% AUTHOR:   Marvin Christian
% TITLE:    Phase 2 — Bandpass and notch filter coefficient definitions
% DATE:     11/04/2026
%
% SUMMARY:
%   Defines the BPF and NOTCH structs used by all Phase 2 analysis scripts.
%   Converts firmware CMSIS-format SOS coefficients to MATLAB format using
%   cmsis2matlab(). Produces an overlaid magnitude response figure and
%   provides show_fvtool_bpf() / show_fvtool_notch() for interactive analysis.
%
% RUN FIRST — then run phase2_bpf_eval.m, phase2_notch_eval.m,
%             phase2_combinations.m in that order.
%
% HOW TO USE fvtool AFTER RUNNING THIS SCRIPT:
%   show_fvtool_bpf(1:6)       all 6 BPFs overlaid
%   show_fvtool_bpf([1 5])     B1 vs B5 (Butterworth 8th vs Elliptic 4th)
%   show_fvtool_bpf([2 5])     B2 vs B5 (same passband, compare orders)
%   show_fvtool_notch(1:2)     N1 vs N2 (r=0.990 vs r=0.995)
%
%   In the fvtool window — Analysis menu:
%     Magnitude Response  → passband flatness and stopband attenuation
%     Phase Response      → phase linearity (non-linear = waveform distortion)
%     Group Delay         → flat = no frequency-dependent delay = no distortion
%     Impulse Response    → settling time after a sharp transient (like QRS)
%   Right-click → Measurements for numeric readouts on the plot.

clear; clc;
fprintf('=== Phase 2: Filter Coefficients ===\n\n');
FS = 500;   % Hz — matches APP_ECG_FS_HZ in app_config_phase1.h

%% ── BANDPASS FILTERS B1–B6 (CMSIS → MATLAB conversion) ──────────────────────
% Coefficients copied from bandpass_filter.c in the firmware.
% cmsis2matlab() negates a1/a2 and prepends the leading 1 for MATLAB format.

B1_cmsis = [
    2.1387987327e-03,  4.2775974654e-03,  2.1387987327e-03,  1.2278758791e+00, -3.9352306025e-01;
    1.0000000000e+00,  2.0000000000e+00,  1.0000000000e+00,  1.4866636732e+00, -6.9496755803e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9882154715e+00, -9.8825641566e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9952467490e+00, -9.9528640681e-01];

B2_cmsis = [
    4.5140667948e-02,  9.0281335896e-02,  4.5140667948e-02,  1.3191386279e+00, -5.0059036426e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9911187667e+00, -9.9115903129e-01];

B3_cmsis = [
    1.6700163307e-01,  3.3400326614e-01,  1.6700163307e-01, -3.2859212077e-01, -6.4561047028e-02;
    1.0000000000e+00,  2.0000000000e+00,  1.0000000000e+00, -4.5307552772e-01, -4.6646996969e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9988389231e+00, -9.9883931795e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9995189819e+00, -9.9951937664e-01];

B4_cmsis = [
    6.9581542841e-03, -1.1680047135e-02,  6.9581542841e-03,  1.8317399972e+00, -8.6239647496e-01;
    1.0000000000e+00,  0.0000000000e+00, -1.0000000000e+00,  1.8331216942e+00, -8.3608137083e-01;
    1.0000000000e+00, -1.9999702109e+00,  1.0000000000e+00,  1.9853115238e+00, -9.8562285918e-01];

B5_cmsis = [
    7.0166798142e-02,  1.1292485589e-01,  7.0166798142e-02,  1.2391752854e+00, -5.0972928164e-01;
    1.0000000000e+00, -1.9999997183e+00,  1.0000000000e+00,  1.9941439653e+00, -9.9417033109e-01];

B6_cmsis = [
    2.2251523523e-03,  4.4503047046e-03,  2.2251523523e-03,  1.2143023932e+00, -3.8493902657e-01;
    1.0000000000e+00,  2.0000000000e+00,  1.0000000000e+00,  1.4804920886e+00, -6.8930831592e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9988372871e+00, -9.9883768330e-01;
    1.0000000000e+00, -2.0000000000e+00,  1.0000000000e+00,  1.9995196592e+00, -9.9952005420e-01];

% Store in struct array — index matches app_config.h BPF_B1_* through BPF_B6_*
BPF(1).sos = cmsis2matlab(B1_cmsis); BPF(1).name = 'B1: Butterworth 8th 0.5-40 Hz';
BPF(1).stages = 4; BPF(1).passband = [0.5 40];  BPF(1).standard = 'IEC 60601-2-27';

BPF(2).sos = cmsis2matlab(B2_cmsis); BPF(2).name = 'B2: Butterworth 4th 0.5-40 Hz';
BPF(2).stages = 2; BPF(2).passband = [0.5 40];  BPF(2).standard = 'Lightweight ref';

BPF(3).sos = cmsis2matlab(B3_cmsis); BPF(3).name = 'B3: Butterworth 8th 0.05-150 Hz';
BPF(3).stages = 4; BPF(3).passband = [0.05 150]; BPF(3).standard = 'IEC 60601-2-25';

BPF(4).sos = cmsis2matlab(B4_cmsis); BPF(4).name = 'B4: Chebyshev II 6th 0.5-40 Hz';
BPF(4).stages = 3; BPF(4).passband = [0.5 40];  BPF(4).standard = 'Chebyshev II flat-passband variant';

BPF(5).sos = cmsis2matlab(B5_cmsis); BPF(5).name = 'B5: Elliptic 4th 0.5-40 Hz';
BPF(5).stages = 2; BPF(5).passband = [0.5 40];  BPF(5).standard = 'Elliptic minimum-order variant';

BPF(6).sos = cmsis2matlab(B6_cmsis); BPF(6).name = 'B6: Butterworth 8th 0.05-40 Hz';
BPF(6).stages = 4; BPF(6).passband = [0.05 40]; BPF(6).standard = 'ST-segment';

fprintf('BPF: B1–B6 defined\n');

%% ── NOTCH FILTER IIR SOS (N1, N2) ───────────────────────────────────────────
omega0  = 2*pi*50/FS;
b_n     = [1, -2*cos(omega0), 1];
NOTCH(1).sos  = repmat([b_n, 1, -2*0.990*cos(omega0), 0.990^2], 6, 1);
NOTCH(1).name = 'N1: IIR x6 r=0.990';
NOTCH(2).sos  = repmat([b_n, 1, -2*0.995*cos(omega0), 0.995^2], 6, 1);
NOTCH(2).name = 'N2: IIR x6 r=0.995';
% N3–N8 are adaptive — implemented in apply_notch.m, no SOS here
NOTCH(3).sos=[]; NOTCH(3).name='N3: NLMS mu=0.005';
NOTCH(4).sos=[]; NOTCH(4).name='N4: NLMS mu=0.010';
NOTCH(5).sos=[]; NOTCH(5).name='N5: Hybrid IIR+NLMS';
NOTCH(6).sos=[]; NOTCH(6).name='N6: RLS lambda=0.990';
NOTCH(7).sos=[]; NOTCH(7).name='N7: Sign-Sign LMS';
NOTCH(8).sos=[]; NOTCH(8).name='N8: Hybrid IIR+RLS';

fprintf('Notch: N1–N8 defined\n\n');

%% ── OVERLAID MAGNITUDE RESPONSE FIGURE ──────────────────────────────────────
NFFT   = 8192;
f_axis = (0:NFFT/2) * FS / NFFT;
cols   = lines(6);

figure('Name','BPF Magnitude Responses','NumberTitle','off',...
       'Position',[60 100 1200 500]);
hold on;
for b = 1:6
    imp  = [1; zeros(NFFT-1,1)];
    resp = apply_biquad(BPF(b).sos, imp);
    H_db = 20*log10(abs(fft(resp, NFFT)) + 1e-12);
    plot(f_axis, H_db(1:NFFT/2+1), 'Color', cols(b,:), 'LineWidth', 1.5, ...
         'DisplayName', BPF(b).name);
end
xline(0.5, 'k--', '0.5 Hz', 'LineWidth',0.8);
xline(40,  'k--', '40 Hz',  'LineWidth',0.8);
xline(50,  'r:',  '50 Hz',  'LineWidth',0.8);
yline(-3,  'k:',  '-3 dB',  'LineWidth',0.6);
yline(-40, 'k:',  '-40 dB', 'LineWidth',0.6);
xlim([0 120]); ylim([-80 5]);
xlabel('Frequency (Hz)'); ylabel('Magnitude (dB)');
title('Bandpass Filters B1–B6 — Magnitude Response  (Fs = 500 Hz)');
legend('Location','southwest','FontSize',8,'Box','on');
grid on; box on;

figure('Name','IIR Notch (N1 vs N2)','NumberTitle','off',...
       'Position',[60 100 900 380]);
hold on;
for n = 1:2
    imp  = [1; zeros(NFFT-1,1)];
    resp = sosfilt(NOTCH(n).sos, imp);
    H_db = 20*log10(abs(fft(resp, NFFT)) + 1e-12);
    plot(f_axis, H_db(1:NFFT/2+1), 'LineWidth',1.5, 'DisplayName', NOTCH(n).name);
end
xline(50,'r--','50 Hz target','LineWidth',1.0);
xlim([45 55]); ylim([-80 2]);
xlabel('Frequency (Hz)'); ylabel('Magnitude (dB)');
title('IIR Notch Filters — Zoomed to 45–55 Hz'); legend; grid on; box on;

fprintf('=== fvtool commands ===\n');
fprintf('  show_fvtool_bpf(1:6, BPF)     all BPFs overlaid\n');
fprintf('  show_fvtool_bpf([1 5], BPF)   B1 vs B5\n');
fprintf('  show_fvtool_notch(1:2, NOTCH)  N1 vs N2\n\n');
fprintf('BPF and NOTCH structs are in the workspace.\n');
fprintf('Run phase2_bpf_eval.m next (load your resting .mat first).\n');
% NOTE: show_fvtool_bpf and show_fvtool_notch are standalone .m files.
% They must be in the same folder as this script.
% MATLAB local functions cannot access the script workspace, so they
% are implemented as separate files that take BPF/NOTCH as arguments.