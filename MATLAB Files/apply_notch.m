function y = apply_notch(x, type, Fs)
% APPLY_NOTCH  Apply one of the 8 notch filter configurations sample-by-sample.
%
%   y = apply_notch(x, type)
%   y = apply_notch(x, type, Fs)
%
%   INPUTS:
%     x    : input signal (column vector)
%     type : 'N1' through 'N8'
%     Fs   : sample rate in Hz (default 500). MUST match the rate the data
%            was recorded at. Using wrong Fs shifts the notch frequency:
%            notch_Hz = 50 * (Fs_used / Fs_actual)

if nargin < 3, Fs = 500; end

x        = double(x(:));
N        = length(x);
y        = zeros(N, 1);
OMEGA    = 2*pi*50/Fs;   % 50 Hz target at actual sample rate

% ── Build IIR SOS at actual Fs ─────────────────────────────────────────────
b_notch = [1, -2*cos(OMEGA), 1];   % zeros on unit circle at 50 Hz

sos_N1 = repmat([b_notch, 1, -2*0.990*cos(OMEGA), 0.990^2], 6, 1);
sos_N2 = repmat([b_notch, 1, -2*0.995*cos(OMEGA), 0.995^2], 6, 1);

switch upper(type)

    % ── N1: IIR cascade ×6, r=0.990 ────────────────────────────────────────
    case 'N1'
        y = sosfilt(sos_N1, x);

    % ── N2: IIR cascade ×6, r=0.995 ────────────────────────────────────────
    case 'N2'
        y = sosfilt(sos_N2, x);

    % ── N3: NLMS, μ=0.005 ──────────────────────────────────────────────────
    % Adaptive notch using synthesised [cos, sin] reference at 50 Hz.
    % Since ||r||² = cos² + sin² = 1 always, NLMS simplifies to standard LMS.
    % Step size μ=0.005: slower convergence (~250 samples), lower misadjustment.
    case 'N3'
        mu = 0.005;
        y  = nlms_notch(x, mu, OMEGA);

    % ── N4: NLMS, μ=0.010 ──────────────────────────────────────────────────
    % Larger step size: faster convergence (~125 samples), slightly higher
    % steady-state misadjustment than N3.
    case 'N4'
        y = nlms_notch(x, 0.010, OMEGA);

    % ── N5: Hybrid IIR + NLMS ───────────────────────────────────────────────
    % IIR removes the bulk of 50 Hz energy instantly (no convergence needed).
    % NLMS then cancels the residual caused by mains frequency drift (±0.5 Hz)
    % that the fixed IIR would miss. Recommended by Ahlstrom & Tompkins (1985).
    case 'N5'
        x_iir = sosfilt(sos_N1, x);
        y     = nlms_notch(x_iir, 0.005, OMEGA);

    % ── N6: RLS, λ=0.990 ───────────────────────────────────────────────────
    % Recursive Least Squares — minimises exponentially weighted cost.
    % Forgetting window ≈ 1/(1-λ) = 100 samples.
    % Converges ~5× faster than NLMS (Dai et al. 2019: 19.75 dB improvement).
    case 'N6'
        y = rls_notch(x, 0.990, 10.0, OMEGA);

    % ── N7: Sign-Sign LMS ──────────────────────────────────────────────────
    % Replaces both error and reference with their signs, eliminating all
    % multiplications in the weight update. Lowest compute; slowest convergence
    % (~750 samples). Suitable for M4 core at 240 MHz (Sharma, 2023).
    case 'N7'
        y = signlms_notch(x, 0.005, OMEGA);

    % ── N8: Hybrid IIR + RLS ────────────────────────────────────────────────
    % IIR removes bulk → RLS cancels residual drift. Best rejection and fastest
    % tracking of the 8 configurations; highest computational cost (~210 cycles).
    case 'N8'
        x_iir = sosfilt(sos_N1, x);
        y     = rls_notch(x_iir, 0.990, 10.0, OMEGA);

    case 'N9'
    % ── N9: Auto-detect narrowband interference + multi-freq NLMS ───────────
    %
    % Searches THREE spectral zones independently:
    %
    % Zone 1 — BELOW ECG PASSBAND  [0.01 – 0.4 Hz]:
    %   Very low-frequency periodic oscillation (baseline drift with a
    %   dominant periodic component, mechanical resonance below respiration).
    %   Requires very high FFT resolution → large window.
    %   Threshold: 6 dB above zone median.
    %
    % Zone 2 — WITHIN ECG PASSBAND  [0.5 – 40 Hz]:
    %   In-band narrowband interference: TETRA radio burst rate (17.65 Hz),
    %   mechanical vibration at a specific frequency, electrical equipment
    %   operating at a frequency that falls inside the ECG band.
    %
    %   *** FUNDAMENTAL LIMITATION ***
    %   An adaptive notch CANNOT distinguish between ECG content and
    %   interference at the same frequency. It removes BOTH. In-band notches
    %   are only justified when the interference is >> ECG amplitude at that
    %   frequency (e.g. TETRA at 17.65 Hz can be 50-100× the ECG at that bin).
    %   Threshold is therefore set MUCH HIGHER (20 dB) than Zones 1 and 3
    %   to avoid false positives on normal ECG harmonics.
    %
    %   Reference: TETRA TDMA frame rate ≈ 17.65 Hz — ETSI EN 300 392-2.
    %
    % Zone 3 — ABOVE ECG PASSBAND  [45 Hz – Nyquist-5 Hz]:
    %   Powerline (50 Hz), harmonics (100, 150 Hz), ambulance inverter noise,
    %   DC-DC converter subharmonics, defibrillator charging artefacts.
    %   Threshold: 6 dB above zone median.

    MU_AUTO   = 0.05;

    % Largest power-of-2 that fits within signal length — guarantees Nfft/2 is integer.
    max_pow2 = 2^floor(log2(max(numel(x), 1)));

    % ── Zone 1: below ECG passband (high resolution needed) ──────────────
    nfft_lo  = min(max_pow2, 2^nextpow2(round(Fs / 0.005)));
    nfft_lo  = max(nfft_lo, 64);
    hi_lo    = min(0.4, Fs/2 - 1);
    freqs_z1 = auto_detect_interference(x, Fs, 0.01, hi_lo, 6, 3, nfft_lo);

    % ── Zone 2: within ECG passband (HIGH threshold — in-band notch is risky)
    nfft_ib  = min(max_pow2, 2^nextpow2(round(Fs / 0.1)));
    nfft_ib  = max(nfft_ib, 64);
    hi_ib    = min(40.0, Fs/2 - 1);
    freqs_z2 = auto_detect_interference(x, Fs, 0.5, hi_ib, 20, 3, nfft_ib);

    % ── Zone 3: above ECG passband (standard detection) ──────────────────
    hi_hi    = max(46, Fs/2 - 5);
    if hi_hi > 46
        freqs_z3 = auto_detect_interference(x, Fs, 45, hi_hi, 6, 5, 512);
    else
        freqs_z3 = [];
    end

    detected_freqs_n9 = [freqs_z1(:)', freqs_z2(:)', freqs_z3(:)'];

    if isempty(detected_freqs_n9)
        y = x;
    else
        y = multi_freq_nlms(x, detected_freqs_n9, Fs, MU_AUTO);
    end

    otherwise
        error('apply_notch: unknown type ''%s''. Use N1–N9.', type);
end
end

% ─────────────────────────────────────────────────────────────────────────────
% N9 SUPPORT: SPECTRAL INTERFERENCE DETECTOR
% ─────────────────────────────────────────────────────────────────────────────
function freqs = auto_detect_interference(x, Fs, lo, hi, thresh_db, max_f, Nfft)
% AUTO_DETECT_INTERFERENCE  Find narrowband spikes in the search zone.
%
% APPROACH:
%   1. Build an average Welch periodogram with overlapping Hanning windows.
%   2. Extract the search zone [lo, hi] Hz from the PSD.
%   3. Estimate the broadband floor as the MEDIAN of the search zone (dB).
%      Using the zone median (not a bin-by-bin sliding median) is more
%      robust: with one or two narrow spikes present, the zone median
%      correctly represents the background floor without being pulled up.
%   4. Find peaks where (P_bin - floor) > thresh_db dB.

    N = numel(x);
    if N < Nfft
        Nfft = 2^nextpow2(max(N, 8));
    end
    % Nfft MUST be even for the half-spectrum indexing (1:Nfft/2+1).
    % If signal length was passed as Nfft and is odd, round down to nearest even.
    Nfft = 2 * floor(Nfft / 2);
    if Nfft < 4, freqs = []; return; end

    % Average periodogram (Welch)
    win   = hann(Nfft);
    hop   = max(1, floor(Nfft/2));
    n_seg = max(1, floor((N - Nfft) / hop) + 1);
    P_sum = zeros(Nfft/2+1, 1);
    for k = 1:n_seg
        i1  = (k-1)*hop + 1;
        i2  = i1 + Nfft - 1;
        if i2 > N, break; end
        seg   = x(i1:i2);
        X     = fft(double(seg) .* win, Nfft);
        P_sum = P_sum + abs(X(1:Nfft/2+1)).^2;
    end
    P_avg  = P_sum / max(n_seg, 1);
    f_axis = (0:Nfft/2)' * Fs / Nfft;

    % Extract search zone
    mask = f_axis >= lo & f_axis <= hi;
    if sum(mask) < 3
        freqs = [];
        return;
    end

    P_zone   = P_avg(mask);
    f_zone   = f_axis(mask);

    if numel(P_zone) < 3   % need at least 3 bins to find a local maximum
        freqs = [];
        return;
    end

    Pdb_zone = 10*log10(P_zone + 1e-30);

    % Floor = median of zone (robust: median ignores isolated spikes)
    floor_db    = median(Pdb_zone);
    above_floor = Pdb_zone - floor_db;

    % Use MinPeakDistance only when zone has enough bins to matter.
    % For narrow zones (e.g. Zone 1 has ~18 bins) the constraint
    % MinPeakDistance < numel(data) is hard to satisfy reliably due to
    % floating-point rounding, so just skip it — with ~18 bins there
    % can be at most one or two peaks regardless.
    min_sep = floor(max(1, 2 * Nfft / Fs));   % floor → guaranteed integer

    if numel(above_floor) > 2 * min_sep
        [pks, locs] = findpeaks(above_floor, ...
            'MinPeakHeight',   thresh_db, ...
            'MinPeakDistance', min_sep);
    else
        % Zone too narrow to use MinPeakDistance safely — omit it
        [pks, locs] = findpeaks(above_floor, ...
            'MinPeakHeight', thresh_db);
    end

    if isempty(locs)
        freqs = [];
        return;
    end

    % Keep up to max_f strongest peaks, sorted by frequency
    [~, si]   = sort(pks, 'descend');
    top_locs  = locs(si(1:min(max_f, numel(si))));
    freqs     = sort(f_zone(top_locs))';
end

% ─────────────────────────────────────────────────────────────────────────────
% N9 SUPPORT: MULTI-FREQUENCY NLMS NOTCH CHAIN
% ─────────────────────────────────────────────────────────────────────────────
function y = multi_freq_nlms(x, freqs_hz, Fs, mu)
% MULTI_FREQ_NLMS  Chain independent NLMS notches at each detected frequency.
%
% Each notch synthesises [cos(ω_k·n), sin(ω_k·n)] internally and adapts
% weights to cancel the component at ω_k. The outputs are chained in series:
%   x → notch(ω_1) → notch(ω_2) → ... → notch(ω_K) → y
%
% Chaining is correct because each NLMS notch is a BSF — it removes only its
% target frequency and leaves all others intact, so the order does not matter.
%
% The weights converge independently per channel. Slow frequency drift is
% tracked automatically because the synthesised reference always follows the
% current phase — only the amplitude and phase of the interference needs to
% be learned by w0, w1.

    y = double(x(:));
    for k = 1:numel(freqs_hz)
        omega = 2*pi*freqs_hz(k) / Fs;
        y     = nlms_notch_single(y, omega, mu);
    end
end

function y = nlms_notch_single(x, omega, mu)
% Single-frequency NLMS adaptive notch — identical to N3 but at arbitrary ω.
    N  = numel(x);
    y  = zeros(N, 1);
    w0 = 0; w1 = 0; ph = 0;
    for i = 1:N
        cr = cos(ph); sr = sin(ph);
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end
        e  = x(i) - (w0*cr + w1*sr);
        w0 = w0 + mu*e*cr;
        w1 = w1 + mu*e*sr;
        y(i) = e;
    end
end

% ─────────────────────────────────────────────────────────────────────────────
function y = nlms_notch(x, mu, omega)
    N  = length(x);
    y  = zeros(N,1);
    w0 = 0; w1 = 0; ph = 0;
    for i = 1:N
        cr = cos(ph); sr = sin(ph);
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end
        noise_est = w0*cr + w1*sr;
        e  = x(i) - noise_est;
        w0 = w0 + mu*e*cr;
        w1 = w1 + mu*e*sr;
        y(i) = e;
    end
end

function y = rls_notch(x, lambda, P0, omega)
    N   = length(x);
    y   = zeros(N,1);
    w0  = 0; w1 = 0; ph = 0;
    P00 = P0; P01 = 0; P11 = P0;
    for i = 1:N
        cr = cos(ph); sr = sin(ph);
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end
        Pr0   = P00*cr + P01*sr;
        Pr1   = P01*cr + P11*sr;
        rTPr  = cr*Pr0 + sr*Pr1;
        denom = lambda + rTPr;
        k0 = Pr0/denom; k1 = Pr1/denom;
        e  = x(i) - (w0*cr + w1*sr);
        w0 = w0 + k0*e; w1 = w1 + k1*e;
        rTP0  = cr*P00 + sr*P01;
        rTP1  = cr*P01 + sr*P11;
        P00   = (P00 - k0*rTP0)/lambda;
        P01   = (P01 - k0*rTP1)/lambda;
        P11   = (P11 - k1*rTP1)/lambda;
        y(i) = e;
    end
end

function y = signlms_notch(x, mu, omega)
    N  = length(x);
    y  = zeros(N,1);
    w0 = 0; w1 = 0; ph = 0;
    for i = 1:N
        cr = cos(ph); sr = sin(ph);
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end
        e  = x(i) - (w0*cr + w1*sr);
        sgn_e = sign(e);
        w0 = w0 + mu*sgn_e*sign(cr);
        w1 = w1 + mu*sgn_e*sign(sr);
        y(i) = e;
    end
end