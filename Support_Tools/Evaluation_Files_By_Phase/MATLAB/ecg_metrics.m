function [snr_db, prd, rmse_mv, r] = ecg_metrics(ref, filtered, mv_scale)
% ECG_METRICS  Compute standard ECG signal processing performance metrics.
%
%   [snr_db, prd, rmse_mv, r] = ecg_metrics(ref, filtered, mv_scale)
%
%   All metrics compare 'filtered' against 'ref' (the reference signal).
%   In Phase 2: ref = B1+N1 output, filtered = any other combination.
%   In Phase 3: ref = BPF+Notch output (before MAS), filtered = MAS output.
%
%   INPUTS:
%     ref       : reference signal (column vector, ADC counts or mV)
%     filtered  : signal under evaluation (same units as ref)
%     mv_scale  : multiply to convert counts to mV (= 1800/4096 = 0.4395)
%                 Pass 1 if both signals are already in mV.
%                 Pass [] to skip RMSE mV conversion (returns RMSE in input units).
%
%   OUTPUTS:
%     snr_db   : output SNR in dB. Higher = filtered signal closer to ref.
%                Evaluation target > 20 dB (Elouaham et al. 2024); not a
%                standardised clinical threshold.
%     prd      : Percentage Root-mean-square Difference (%).
%                Lower = less distortion. Evaluation convention < 9%
%                carried over from ECG compression literature
%                (Reddy & Murthy, IEEE Trans. Biomed. Eng., 1986).
%     rmse_mv  : Root Mean Square Error in mV. No fixed threshold; minimise
%                relative to reference. No citable source for a specific limit.
%     r        : Pearson correlation coefficient.
%                Higher = better morphology preservation. Evaluation value
%                > 0.98 reported in Martins & Bauer 2025 for textile-electrode
%                ECG quality; whether this is a threshold or a measured result
%                has not been confirmed from the full text.
%
%   REFERENCES:
%     Reddy & Murthy, IEEE Trans. Biomed. Eng., 1986 — PRD definition
%                (ECG data compression context; 9% convention)
%     Elouaham et al., J. Elec. Comp. Eng., 2024 — SNR/PRD evaluation targets
%     Martins & Bauer, Sci. Rep. 15(1), 2025 (DOI: 10.1038/s41598-025-25365-x)
%                — Pearson r > 0.98 ECG quality evaluation value

if nargin < 3, mv_scale = 1; end

n   = min(length(ref), length(filtered));
s   = double(ref(1:n));
f   = double(filtered(1:n));
err = s - f;

sig_power = sum(s.^2);
err_power = sum(err.^2);

snr_db  = 10 * log10(sig_power / (err_power + 1e-12));
prd     = 100 * sqrt(err_power / (sig_power + 1e-12));

if isempty(mv_scale)
    rmse_mv = sqrt(mean(err.^2));
else
    rmse_mv = sqrt(mean(err.^2)) * mv_scale;
end

if std(s) > 0 && std(f) > 0
    r = corr(s, f);
else
    r = NaN;
end
end