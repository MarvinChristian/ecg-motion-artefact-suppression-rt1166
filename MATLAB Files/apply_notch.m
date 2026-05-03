function y = apply_notch(x, type, Fs, ref)
% APPLY_NOTCH  Apply one notch filter configuration (N1, N3, N5, N6, N8, N9).
%
%   y = apply_notch(x, type)
%   y = apply_notch(x, type, Fs)
%   y = apply_notch(x, type, Fs, ref)
%
%   INPUTS:
%     x    : input signal (column vector)
%     type : 'N1' | 'N3' | 'N5' | 'N6' | 'N8' | 'N9'
%            N2 (IIR r=0.995), N4 (NLMS μ=0.010), N7 (Sign-Sign LMS) removed.
%            N2: narrower notch worsens ST ringing and drift tolerance vs N1.
%            N4: step-size variant of N3, not a distinct algorithm.
%            N7: no compute advantage on Cortex-M7 with hardware FPU.
%     Fs   : sample rate in Hz (default 500). Wrong Fs shifts notch frequency.
%     ref  : reserved for older experimental filters; ignored by current set.
%
%   N9 improvements over initial implementation (2026-04-23):
%     1. Frequency-tracking NLMS — notch centre adapts to interference drift
%        via a normalised gradient update on omega at each sample. Corrects the
%        prior fixed-omega oscillator, which tracked amplitude and phase only.
%        Reference: Ferdjallah & Barr, IEEE TBME 41(6):529-536, 1994,
%        DOI 10.1109/10.293240.
%     2. Adaptive per-frequency step size — mu calibrated from Welch detection
%        prominence: strong/clear peaks get larger mu; marginal detections get
%        smaller mu to limit ECG distortion risk.
%     3. Harmonic-aware detection — after Zone 3 peak detection, harmonics
%        (2nd–4th order) are checked against a lower 3 dB threshold and added
%        to the notch chain if present. Catches weaker harmonics of inverter
%        or mains waveforms that would not independently clear 6 dB.
%     4. Two-pass residual check — a second Welch detection on the Stage 3
%        output identifies frequencies masked in the first pass. A second NLMS
%        pass suppresses them. Concept: Ben Slimane & Ouled Zaid, J Med Signals
%        Sensors 11(1):68-77, 2021, DOI 10.4103/jmss.JMSS_3_20.

if nargin < 3, Fs = 500; end
if nargin < 4, ref = []; end

x     = double(x(:));
OMEGA = 2*pi*50/Fs;

b_notch = [1, -2*cos(OMEGA), 1];
sos_N1  = repmat([b_notch, 1, -2*0.990*cos(OMEGA), 0.990^2], 6, 1);

switch upper(type)

    % ── N1: IIR cascade ×6, r=0.990 ────────────────────────────────────────
    % Fixed-frequency deterministic filter. Instant startup. ST ringing
    % artefact from recursive feedback; fixed pole cannot track mains drift.
    case 'N1'
        y = sosfilt(sos_N1, x);

    % ── N3: NLMS μ=0.005, fixed 50 Hz ──────────────────────────────────────
    % Adaptive amplitude/phase; notch centre fixed. Conservative step size:
    % slow convergence (~250 samples), low misadjustment.
    % Biswas & Maniruzzaman 2014: NLMS > RLS > IIR on MIT-BIH benchmark.
    case 'N3'
        y = nlms_notch(x, 0.005, OMEGA);

    % ── N5: Hybrid IIR + NLMS ───────────────────────────────────────────────
    % IIR removes bulk of 50 Hz energy instantly (no convergence delay).
    % NLMS then cancels residual caused by ±0.5 Hz mains frequency drift.
    % Ahlstrom & Tompkins 1985 — recommended design for frequency-drift context.
    case 'N5'
        x_iir = sosfilt(sos_N1, x);
        y     = nlms_notch(x_iir, 0.005, OMEGA);

    % ── N6: RLS λ=0.990 ────────────────────────────────────────────────────
    % Exponentially weighted cost; forgetting window ≈ 1/(1-λ) = 100 samples.
    % ~5× faster convergence than NLMS. Dai et al. 2019: 19.75 dB improvement.
    case 'N6'
        y = rls_notch(x, 0.990, 10.0, OMEGA);

    % ── N8: Hybrid IIR + RLS ────────────────────────────────────────────────
    % IIR for immediate deep rejection; RLS for fastest drift correction.
    % Upper-bound combination: highest compute cost in the set.
    case 'N8'
        x_iir = sosfilt(sos_N1, x);
        y     = rls_notch(x_iir, 0.990, 10.0, OMEGA);

    % ── N9: Auto-detect + frequency-tracking multi-freq NLMS ────────────────
    % Detects narrowband interference across three spectral zones, then
    % suppresses each detected frequency with a frequency-tracking NLMS notch.
    % The only filter in the set that handles non-predetermined interference
    % frequencies (vehicle electronics, TETRA 17.65 Hz, inverter harmonics).
    case 'N9'
        y = n9_pipeline(x, Fs);

    otherwise
        error('apply_notch: unknown type ''%s''. Valid: N1 N3 N5 N6 N8 N9.', type);
end
end

% =============================================================================
% N9 PIPELINE
% =============================================================================

function y = n9_pipeline(x, Fs)
% N9_PIPELINE  Four-stage auto-detect + frequency-tracking notch suppression.
%
% Stage 1 — Welch detection across three spectral zones.
% Stage 2 — Harmonic check: add sub-threshold Zone 3 harmonics.
% Stage 3 — Frequency-tracking NLMS chain with per-frequency step sizes.
% Stage 4 — Residual check: second Welch pass on Stage 3 output; second
%            NLMS pass if new frequencies emerge after first cancellation.
%
% Zone definitions:
%   Zone 1  [0.01 – 0.4  Hz]  sub-passband periodic oscillation     6 dB
%   Zone 2  [0.5  – 40   Hz]  in-band interference — HIGH threshold  20 dB
%   Zone 3  [45   – Ny-5 Hz]  supra-passband: mains + harmonics      6 dB

    MU_BASE      = 0.05;   % maximum NLMS step size
    MU_MIN       = 0.01;   % minimum step size (marginal detections)
    MU_W         = 1e-3;   % frequency-tracking step (normalised gradient)
    HARM_THRESH  = 3.0;    % dB — harmonic acceptance threshold
    MAX_HARM_ORD = 4;      % highest harmonic order to check

    max_pow2 = 2^floor(log2(max(numel(x), 1)));

    % Stage 1: Zone detection
    nfft_lo = max(64, min(max_pow2, 2^nextpow2(round(Fs / 0.005))));
    nfft_lo = 2 * floor(nfft_lo / 2);
    [fz1, pz1] = detect_zone(x, Fs, 0.01, min(0.4, Fs/2-1), 6, 3, nfft_lo);

    nfft_ib = max(64, min(max_pow2, 2^nextpow2(round(Fs / 0.1))));
    nfft_ib = 2 * floor(nfft_ib / 2);
    [fz2, pz2] = detect_zone(x, Fs, 0.5, min(40, Fs/2-1), 20, 3, nfft_ib);

    hi_z3 = max(46, Fs/2 - 5);
    if hi_z3 > 46
        [fz3, pz3, P512, fax512] = detect_zone_with_spectrum(x, Fs, 45, hi_z3, 6, 5, 512);
    else
        [fz3, pz3, P512, fax512] = deal([], [], [], []);
    end

    % Stage 2: Harmonic check on Zone 3 detections
    if ~isempty(fz3) && ~isempty(P512)
        existing = [fz1(:)', fz2(:)', fz3(:)'];
        [fharm, pharm] = find_harmonics(fz3, P512, fax512, Fs, ...
                                        HARM_THRESH, MAX_HARM_ORD, existing);
    else
        fharm = []; pharm = [];
    end

    all_freqs = [fz1(:)', fz2(:)', fz3(:)', fharm(:)'];
    all_proms = [pz1(:)', pz2(:)', pz3(:)', pharm(:)'];

    if isempty(all_freqs)
        y = x;
        return;
    end

    % Per-frequency step size: linear from MU_MIN (at threshold) to MU_BASE
    % (at 20 dB prominence). Limits misadjustment for marginal in-band detections.
    mu_vec = MU_MIN + (MU_BASE - MU_MIN) * min(1, all_proms / 20);

    % Stage 3: Frequency-tracking NLMS chain
    y = nlms_chain_tracking(x, all_freqs, mu_vec, MU_W, Fs);

    % Stage 4: Residual check — second detection on Stage 3 output
    if hi_z3 > 46
        [fz3b, pz3b] = detect_zone(y, Fs, 45, hi_z3, 6, 5, 512);
        % Retain only frequencies not already notched (separation > 1 Hz)
        keep = true(1, numel(fz3b));
        for k = 1:numel(fz3b)
            if any(abs(all_freqs - fz3b(k)) < 1.0)
                keep(k) = false;
            end
        end
        fz3b = fz3b(keep);  pz3b = pz3b(keep);
        if ~isempty(fz3b)
            mu_b = MU_MIN + (MU_BASE - MU_MIN) * min(1, pz3b / 20);
            y    = nlms_chain_tracking(y, fz3b, mu_b, MU_W, Fs);
        end
    end

    % Stage 4b: Second pass on Zone 2 (in-band) detections only.
    % Targets the exact frequencies from Stage 1 fz2 — no new detection.
    % Uses MU_MIN throughout: conservative enough to limit ECG distortion
    % while giving a second convergence opportunity for partially rejected
    % in-band tones. In-band tones overlapping QRS/T-wave energy will still
    % not be fully rejected; this is unavoidable without morphology cost.
    if ~isempty(fz2)
        mu_b2 = repmat(MU_MIN, 1, numel(fz2));
        y     = nlms_chain_tracking(y, fz2, mu_b2, MU_W, Fs);
    end
end

% =============================================================================
% SPECTRAL ZONE DETECTOR
% =============================================================================

function [freqs, proms] = detect_zone(x, Fs, lo, hi, thresh_db, max_f, Nfft)
% Thin wrapper — calls detect_zone_with_spectrum and discards spectrum outputs.
    [freqs, proms, ~, ~] = detect_zone_with_spectrum(x, Fs, lo, hi, thresh_db, max_f, Nfft);
end

function [freqs, proms, P_avg, f_axis] = detect_zone_with_spectrum(x, Fs, lo, hi, thresh_db, max_f, Nfft)
% DETECT_ZONE_WITH_SPECTRUM  Welch-based narrowband interference detector.
%
%   Returns detected frequencies (Hz), their prominence above the local
%   spectral floor (dB), and the full one-sided Welch power spectrum.
%
%   Algorithm:
%     1. Averaged Welch periodogram — 50% overlapping Hanning windows.
%     2. Local 5-Hz sliding-median floor prevents clustered harmonics
%        (50/100/150 Hz) from inflating each other's noise floor.
%     3. Zone [lo, hi] Hz isolated; peaks above thresh_db selected.
%     4. Quadratic sub-bin frequency refinement (Jacobsen & Lyons 2004).
%     5. Frequencies and prominences returned in ascending frequency order.

    N    = numel(x);
    Nfft = 2 * floor(max(Nfft, 4) / 2);
    if N < Nfft
        Nfft = 2 * floor(2^nextpow2(max(N, 8)) / 2);
    end
    if Nfft < 4
        freqs = []; proms = []; P_avg = []; f_axis = []; return;
    end

    win   = hann(Nfft);
    hop   = max(1, floor(Nfft / 2));
    n_seg = max(1, floor((N - Nfft) / hop) + 1);
    P_sum = zeros(Nfft/2 + 1, 1);
    for k = 1:n_seg
        i1 = (k-1)*hop + 1;  i2 = i1 + Nfft - 1;
        if i2 > N, break; end
        seg   = x(i1:i2);
        X     = fft(double(seg) .* win, Nfft);
        P_sum = P_sum + abs(X(1:Nfft/2+1)).^2;
    end
    P_avg  = P_sum / max(n_seg, 1);
    f_axis = (0 : Nfft/2)' * Fs / Nfft;

    win_bins  = max(3, min(round(5*Nfft/Fs), round(numel(P_avg)/5)));
    win_bins  = 2*floor(win_bins/2) + 1;
    floor_lin = movmedian(P_avg, win_bins);
    prom_db   = 10*log10((P_avg + 1e-30) ./ (floor_lin + 1e-30));

    mask = f_axis >= lo & f_axis <= hi;
    if sum(mask) < 3
        freqs = []; proms = []; return;
    end
    af    = prom_db(mask);
    fzone = f_axis(mask);
    if numel(af) < 3
        freqs = []; proms = []; return;
    end

    min_sep = floor(max(1, 2 * Nfft / Fs));
    ws = warning('off', 'signal:findpeaks:largeMinPeakHeight');
    if numel(af) > 2 * min_sep
        [pks, locs] = findpeaks(af, 'MinPeakHeight', thresh_db, ...
                                    'MinPeakDistance', min_sep);
    else
        [pks, locs] = findpeaks(af, 'MinPeakHeight', thresh_db);
    end
    warning(ws);
    if isempty(locs)
        freqs = []; proms = []; return;
    end

    % Keep top max_f by prominence
    [~, si]  = sort(pks, 'descend');
    sel      = si(1:min(max_f, numel(si)));
    sel_locs = locs(sel);
    sel_pks  = pks(sel);

    % Quadratic sub-bin refinement (Jacobsen & Lyons 2004)
    bin_hz = Fs / Nfft;
    raw_f  = zeros(1, numel(sel_locs));
    for qi = 1:numel(sel_locs)
        k = sel_locs(qi);
        if k > 1 && k < numel(af)
            a = af(k-1); b = af(k); c = af(k+1);
            denom = a - 2*b + c;
            if abs(denom) > 1e-10
                delta = max(-0.5, min(0.5, 0.5*(a - c) / denom));
            else
                delta = 0;
            end
            raw_f(qi) = fzone(k) + delta*bin_hz;
        else
            raw_f(qi) = fzone(k);
        end
    end

    % Sort by frequency; reorder prominences to match
    [freqs, ord] = sort(raw_f);
    proms = sel_pks(ord);
end

% =============================================================================
% HARMONIC CHECKER
% =============================================================================

function [harm_freqs, harm_proms] = find_harmonics(base_freqs, P_avg, f_axis, ...
                                                    Fs, thresh_db, max_order, existing_freqs)
% FIND_HARMONICS  Check for sub-threshold harmonics of detected Zone 3 peaks.
%
%   For each base frequency f_k, evaluates bins near h*f_k (h = 2..max_order)
%   within Zone 3 [45 Hz – Nyquist-5 Hz]. Accepts harmonics above thresh_db
%   that are not already within 1 Hz of an existing detected frequency.
%
%   Uses the same Welch spectrum and local-median floor from Zone 3 detection
%   — no additional FFT computation required.

    Nfft = 2 * (numel(P_avg) - 1);

    win_bins  = max(3, min(round(5*Nfft/Fs), round(numel(P_avg)/5)));
    win_bins  = 2*floor(win_bins/2) + 1;
    floor_lin = movmedian(P_avg, win_bins);
    prom_db   = 10*log10((P_avg + 1e-30) ./ (floor_lin + 1e-30));

    harm_freqs = [];
    harm_proms = [];

    for k = 1:numel(base_freqs)
        f0 = base_freqs(k);
        for h = 2:max_order
            f_harm = h * f0;
            if f_harm < 45 || f_harm > Fs/2 - 5
                continue;
            end
            if ~isempty(existing_freqs) && any(abs(existing_freqs - f_harm) < 1.0)
                continue;
            end
            [~, idx] = min(abs(f_axis - f_harm));
            if prom_db(idx) >= thresh_db
                harm_freqs(end+1) = f_axis(idx); %#ok<AGROW>
                harm_proms(end+1) = prom_db(idx); %#ok<AGROW>
            end
        end
    end
end

% =============================================================================
% FREQUENCY-TRACKING NLMS CHAIN
% =============================================================================

function y = nlms_chain_tracking(x, freqs_hz, mu_vec, mu_w, Fs)
% NLMS_CHAIN_TRACKING  Series chain of frequency-tracking NLMS notches.
%
%   Each stage receives the output of the previous, removing only its target
%   frequency. The order of stages does not affect steady-state performance
%   for non-overlapping narrow notches.

    y = double(x(:));
    for k = 1:numel(freqs_hz)
        omega_init = 2*pi * freqs_hz(k) / Fs;
        omega_lo   = 2*pi * max(1,        freqs_hz(k) - 5) / Fs;
        omega_hi   = 2*pi * min(Fs/2 - 1, freqs_hz(k) + 5) / Fs;
        y = nlms_notch_tracking(y, omega_init, mu_vec(k), mu_w, omega_lo, omega_hi);
    end
end

function y = nlms_notch_tracking(x, omega_init, mu, mu_w, omega_lo, omega_hi)
% NLMS_NOTCH_TRACKING  Single-frequency adaptive notch with frequency tracking.
%
%   Extends the fixed-omega NLMS notch by adding a normalised gradient-based
%   frequency update at each sample. The notch centre omega tracks slow
%   interference drift (e.g. mains frequency variation in vehicle inverters).
%
%   Weight update (amplitude/phase):
%     w0 += mu * e * cos(ph)
%     w1 += mu * e * sin(ph)
%
%   Frequency update (normalised gradient):
%     omega += mu_w * e * (-w0*sin(ph) + w1*cos(ph)) / (w0^2 + w1^2 + eps)
%     omega  = clamp(omega, omega_lo, omega_hi)
%
%   Normalisation by (w0^2 + w1^2) makes the frequency step scale-invariant
%   with respect to interference amplitude, analogous to the NLMS step
%   normalisation by reference power.
%
%   Frequency update computed before weight update so it uses pre-update
%   weights, preventing coupling between the two adaptation loops.
%
%   Reference: Ferdjallah & Barr, IEEE TBME 41(6):529-536, 1994,
%   DOI 10.1109/10.293240. CLMS frequency-tracking notch for biomedical PLI.
%   Gradient structure adapted to the FIR direct-form synthesis used here.

    N     = numel(x);
    y     = zeros(N, 1);
    w0    = 0;  w1 = 0;  ph = 0;
    omega = omega_init;

    for i = 1:N
        cr = cos(ph);
        sr = sin(ph);
        e  = x(i) - (w0*cr + w1*sr);

        % Frequency update — before weight update, using pre-update weights
        freq_grad = -w0*sr + w1*cr;
        interf_pw = w0*w0 + w1*w1 + 1e-6;
        omega     = omega + mu_w * e * freq_grad / interf_pw;
        omega     = max(omega_lo, min(omega_hi, omega));

        % Amplitude/phase weight update (||r||^2 = 1, NLMS reduces to LMS)
        w0 = w0 + mu*e*cr;
        w1 = w1 + mu*e*sr;

        % Advance phase accumulator
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end

        y(i) = e;
    end
end

% =============================================================================
% N10 PSD-CAP PIPELINE
% =============================================================================

function y = n10_psd_cap(x, Fs, ref)
% N10_PSD_CAP  Streaming-style attenuation of excess ECG-band and line PSD.
%
%   The method operates on short overlapped FFT blocks. In 0.5-40 Hz and the
%   45-55 Hz line band, bins above a normal/reference PSD are attenuated down
%   toward that cap. It never boosts bins and never applies a hard null. If no
%   reference is supplied, the cap falls back to a local spectral envelope from
%   each block; that fallback mainly limits narrow excess rather than true
%   broadband noise.

    x = double(x(:));
    if isempty(x)
        y = x;
        return;
    end

    INBAND_LO_HZ = 0.5;
    INBAND_HI_HZ = min(40.0, Fs/2 - 1.0);
    QRS_LO_HZ    = 5.0;
    QRS_HI_HZ    = 15.0;
    LINE_LO_HZ   = 45.0;
    LINE_HI_HZ   = min(55.0, Fs/2 - 1.0);
    MARGIN       = 1.05;  % +0.2 dB headroom above normal PSD
    GMIN         = 0.12;  % max attenuation about 18.4 dB
    GMIN_QRS     = 0.35;  % max attenuation about 9.1 dB in QRS band
    GMIN_LINE    = 0.03;  % max attenuation about 30.5 dB in 50 Hz band
    TIME_ALPHA   = 0.30;  % gain smoothing across streaming blocks

    win_len = 2^nextpow2(max(128, round(2.0 * Fs)));
    win_len = min(win_len, max(128, 2^floor(log2(max(numel(x), 128)))));
    if numel(x) < win_len
        win_len = 2^nextpow2(max(numel(x), 16));
    end
    win_len = max(16, win_len);
    nfft    = win_len;
    hop     = max(1, floor(win_len / 2));
    win     = hann(win_len);

    freq = (0:nfft-1)' * Fs / nfft;
    freq_fold = min(freq, Fs - freq);
    inband = freq_fold >= INBAND_LO_HZ & freq_fold <= INBAND_HI_HZ;
    lineband = freq_fold >= LINE_LO_HZ & freq_fold <= LINE_HI_HZ;
    activeband = inband | lineband;
    qrsband = freq_fold >= QRS_LO_HZ & freq_fold <= QRS_HI_HZ;
    gmin_vec = GMIN * ones(nfft, 1);
    gmin_vec(qrsband) = GMIN_QRS;
    gmin_vec(lineband) = GMIN_LINE;

    ref_cap = [];
    if ~isempty(ref)
        ref_cap = n10_reference_cap(ref, Fs, nfft, win, hop, MARGIN);
    end

    x_pad = [zeros(hop, 1); x; zeros(win_len, 1)];
    y_pad = zeros(size(x_pad));
    w_sum = zeros(size(x_pad));
    prev_gain = ones(nfft, 1);

    last_start = numel(x_pad) - win_len + 1;
    for i1 = 1:hop:last_start
        idx = i1:i1+win_len-1;
        frame = x_pad(idx) .* win;
        X = fft(frame, nfft);
        P = abs(X).^2;

        if isempty(ref_cap)
            cap = n10_local_cap(P, Fs, MARGIN);
        else
            cap = ref_cap;
        end

        gain = ones(nfft, 1);
        raw_gain = sqrt((cap + 1e-30) ./ (P + 1e-30));
        gain(activeband) = min(1.0, raw_gain(activeband));
        line_gain = max(gmin_vec(lineband), gain(lineband));
        gain = max(gain, gmin_vec);
        gain(~activeband) = 1.0;
        gain = n10_smooth_gain(gain, Fs);
        gain(lineband) = min(gain(lineband), line_gain);
        gain = max(gain, gmin_vec);

        gain = TIME_ALPHA * prev_gain + (1 - TIME_ALPHA) * gain;
        gain(lineband) = min(gain(lineband), line_gain);
        gain = max(gain, gmin_vec);
        gain(~activeband) = 1.0;
        prev_gain = gain;

        y_frame = real(ifft(X .* gain, nfft));
        y_pad(idx) = y_pad(idx) + y_frame(1:win_len) .* win;
        w_sum(idx) = w_sum(idx) + win.^2;
    end

    valid = w_sum > 1e-12;
    y_pad(valid) = y_pad(valid) ./ w_sum(valid);
    y = y_pad(hop+1:hop+numel(x));
end

function cap = n10_reference_cap(ref, Fs, nfft, win, hop, margin)
% Build a robust normal PSD cap from a supplied reference ECG vector.
    ref = double(ref(:));
    if isempty(ref)
        cap = [];
        return;
    end
    if numel(ref) < nfft
        ref = [ref; zeros(nfft-numel(ref), 1)];
    end

    n_frames = max(1, floor((numel(ref) - nfft) / hop) + 1);
    P_ref = zeros(nfft, n_frames);
    used = 0;
    for k = 1:n_frames
        i1 = (k-1)*hop + 1;
        i2 = i1 + nfft - 1;
        if i2 > numel(ref), break; end
        used = used + 1;
        X = fft(ref(i1:i2) .* win, nfft);
        P_ref(:, used) = abs(X).^2;
    end
    if used == 0
        cap = [];
        return;
    end

    ref_psd = median(P_ref(:, 1:used), 2);
    ref_env = n10_smooth_power(ref_psd, Fs);
    cap = max(ref_psd, ref_env) * margin;

    freq = (0:nfft-1)' * Fs / nfft;
    freq_fold = min(freq, Fs - freq);
    lineband = freq_fold >= 45.0 & freq_fold <= min(55.0, Fs/2 - 1.0);
    cap(lineband) = ref_env(lineband) * margin;
end

function cap = n10_local_cap(P, Fs, margin)
% Fallback cap from the local spectral envelope of the current block.
    cap = n10_smooth_power(P, Fs) * margin;
end

function P_s = n10_smooth_power(P, Fs)
% Smooth one-sided power and mirror it to preserve a real-valued output.
    nfft = numel(P);
    npos = floor(nfft/2) + 1;
    bin_hz = Fs / nfft;
    width_bins = max(3, round(5.0 / max(bin_hz, eps)));
    width_bins = 2 * floor(width_bins / 2) + 1;

    P_pos = P(1:npos);
    P_pos = movmedian(P_pos, width_bins);
    P_pos = movmean(P_pos, max(3, round(width_bins / 3)));

    P_s = zeros(nfft, 1);
    P_s(1:npos) = P_pos;
    if rem(nfft, 2) == 0
        P_s(npos+1:end) = flipud(P_pos(2:end-1));
    else
        P_s(npos+1:end) = flipud(P_pos(2:end));
    end
end

function g_s = n10_smooth_gain(gain, Fs)
% Light gain smoothing avoids isolated-bin musical artefacts.
    nfft = numel(gain);
    npos = floor(nfft/2) + 1;
    bin_hz = Fs / nfft;
    width_bins = max(3, round(1.0 / max(bin_hz, eps)));
    width_bins = 2 * floor(width_bins / 2) + 1;

    g_pos = movmean(gain(1:npos), width_bins);
    g_s = ones(nfft, 1);
    g_s(1:npos) = g_pos;
    if rem(nfft, 2) == 0
        g_s(npos+1:end) = flipud(g_pos(2:end-1));
    else
        g_s(npos+1:end) = flipud(g_pos(2:end));
    end
end

% =============================================================================
% FIXED-FREQUENCY HELPERS (N3, N5, N6, N8)
% =============================================================================

function y = nlms_notch(x, mu, omega)
% Fixed-frequency NLMS adaptive notch — N3 and N5.
% Adapts amplitude and phase only; notch centre is fixed at omega.
    N  = length(x);
    y  = zeros(N, 1);
    w0 = 0;  w1 = 0;  ph = 0;
    for i = 1:N
        cr = cos(ph);  sr = sin(ph);
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end
        e  = x(i) - (w0*cr + w1*sr);
        w0 = w0 + mu*e*cr;
        w1 = w1 + mu*e*sr;
        y(i) = e;
    end
end

function y = rls_notch(x, lambda, P0, omega)
% Fixed-frequency RLS adaptive notch — N6 and N8.
% Minimises exponentially weighted cost; window ≈ 1/(1-lambda) samples.
    N   = length(x);
    y   = zeros(N, 1);
    w0  = 0;  w1 = 0;  ph = 0;
    P00 = P0;  P01 = 0;  P11 = P0;
    for i = 1:N
        cr = cos(ph);  sr = sin(ph);
        ph = ph + omega;
        if ph >= 2*pi, ph = ph - 2*pi; end
        Pr0   = P00*cr + P01*sr;
        Pr1   = P01*cr + P11*sr;
        denom = lambda + cr*Pr0 + sr*Pr1;
        k0 = Pr0/denom;  k1 = Pr1/denom;
        e  = x(i) - (w0*cr + w1*sr);
        w0 = w0 + k0*e;  w1 = w1 + k1*e;
        rTP0  = cr*P00 + sr*P01;
        rTP1  = cr*P01 + sr*P11;
        P00   = (P00 - k0*rTP0) / lambda;
        P01   = (P01 - k0*rTP1) / lambda;
        P11   = (P11 - k1*rTP1) / lambda;
        y(i)  = e;
    end
end
