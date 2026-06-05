function y = apply_notch(x, type, Fs, ref)
% APPLY_NOTCH  Apply one notch filter configuration (N1-N6).
%
%   y = apply_notch(x, type)
%   y = apply_notch(x, type, Fs)
%   y = apply_notch(x, type, Fs, ref)
%
%   INPUTS:
%     x    : input signal (column vector)
%     type : 'N1' | 'N2' | 'N3' | 'N4' | 'N5' | 'N6'
%     Fs   : sample rate in Hz (default 500). Wrong Fs shifts notch frequency.
%     ref  : reference signal for N6 detection (pre-BPF); ignored by N1-N5.
%
%   N6 implementation notes (2026-05-07):
%     1. A fixed 50 Hz notch section is always active.
%     2. Each notch section is no-boost normalized: max |H(f)| <= 1.
%     3. The ECG output path is a direct-form streaming biquad cascade.
%     4. Tone detection uses past samples only and updates the auto biquad
%        frequencies at block boundaries.
%     5. This maps to NXP/CMSIS as RFFT or Goertzel detection plus
%        arm_biquad_cascade_df2T_f32 filtering.

if nargin < 3, Fs = 500; end
if nargin < 4, ref = []; end

x     = double(x(:));
OMEGA = 2*pi*50/Fs;

b_notch = [1, -2*cos(OMEGA), 1];
sos_N1  = repmat([b_notch, 1, -2*0.990*cos(OMEGA), 0.990^2], 6, 1);

switch upper(type)

    % N1: IIR cascade x6, r=0.990
    % Fixed-frequency deterministic filter. Instant startup. ST ringing
    % artefact from recursive feedback; fixed pole cannot track mains drift.
    case 'N1'
        y = sosfilt(sos_N1, x);

    % N2: NLMS mu=0.005, fixed 50 Hz
    % Adaptive amplitude/phase; notch centre fixed. Conservative step size:
    % slow convergence (~250 samples), low misadjustment.
    % Biswas & Maniruzzaman 2014: NLMS > RLS > IIR on MIT-BIH benchmark.
    case 'N2'
        y = nlms_notch(x, 0.005, OMEGA);

    % N3: Hybrid IIR + NLMS
    % IIR removes bulk of 50 Hz energy instantly (no convergence delay).
    % NLMS then cancels residual caused by +/-0.5 Hz mains frequency drift.
    % Ahlstrom & Tompkins 1985: recommended design for frequency-drift context.
    case 'N3'
        x_iir = sosfilt(sos_N1, x);
        y     = nlms_notch(x_iir, 0.005, OMEGA);

    % N4: RLS lambda=0.990
    % Exponentially weighted cost; forgetting window approx 1/(1-lambda) = 100 samples.
    % About 5x faster convergence than NLMS. Dai et al. 2019: 19.75 dB improvement.
    case 'N4'
        y = rls_notch(x, 0.990, 10.0, OMEGA);

    % N5: Hybrid IIR + RLS
    % IIR for immediate deep rejection; RLS for fastest drift correction.
    % Upper-bound combination: highest compute cost in the set.
    case 'N5'
        x_iir = sosfilt(sos_N1, x);
        y     = rls_notch(x_iir, 0.990, 10.0, OMEGA);

    % N6: Direct causal multi-frequency biquad notch
    % Always applies a static 50 Hz notch, then adds tracked mains/extra
    % high-frequency notch sections from past-only tone detection.
    case 'N6'
        if nargin >= 4 && ~isempty(ref)
            y = n9_pipeline_causal(x, Fs, ref);
        else
            y = n9_pipeline_causal(x, Fs);
        end

    otherwise
        error('apply_notch: unknown type ''%s''. Valid: N1 N2 N3 N4 N5 N6.', type);
end
end

% =============================================================================
% N6 PIPELINE
% =============================================================================

function y = n9_pipeline_causal(x, Fs, detect_from)
% N6 (n9_pipeline_causal)  Streaming biquad notch with past-window detection.
%
% The output sample is produced by causal biquad sections only. Detection is
% allowed to run blockwise, but it reads only samples that arrived before the
% block being filtered. Firmware mapping:
%   - detector: CMSIS RFFT/Goertzel on the previous history buffer
%   - output:  arm_biquad_cascade_df2T_f32, coefficients changed per block

    MAINS_HZ     = 50;
    STATIC_50_HZ = 50;
    DETECT_NFFT  = 512;
    UPDATE_SEC    = 0.50;
    HIST_SEC     = 1.5;
    DETECT_DB    = 3.5;
    MAX_EXTRA    = 3;
    MIN_SEP_HZ   = 5.0;
    R_STATIC50   = 0.975;
    R_MAINS      = 0.980;
    R_EXTRA      = 0.975;
    MAIN_TRACK_HZ = 3.0;
    TRACK_GAP_HZ = 0.25;

    if nargin < 3 || isempty(detect_from)
        detect_from = x;
    else
        detect_from = double(detect_from(:));
    end

    x = double(x(:));
    N = numel(x);
    detect_from = finite_column(detect_from);
    if isempty(detect_from)
        detect_from = zeros(max(N, 1), 1);
    end
    if numel(detect_from) < N
        detect_from(end+1:N, 1) = detect_from(end);
    elseif numel(detect_from) > N
        detect_from = detect_from(1:N);
    end

    update_len = max(32, round(UPDATE_SEC * Fs));
    hist_len  = max(DETECT_NFFT, round(HIST_SEC * Fs));
    hi_z3     = max(49, Fs/2 - 5);
    if N == 0
        y = x;
        return;
    end

    max_sections = 2 + MAX_EXTRA;
    y = zeros(N, 1);
    z = zeros(max_sections, 2);
    last_freqs = NaN(max_sections, 1);

    for i1 = 1:update_len:N
        i2 = min(N, i1 + update_len - 1);
        h2 = i1 - 1;
        h1 = max(1, h2 - hist_len + 1);

        main_f = NaN;
        extra_f = [];
        if hi_z3 > 49 && h2 >= h1 && (h2 - h1 + 1) >= max(64, round(0.75 * DETECT_NFFT))
            detect_seg = finite_column(detect_from(h1:h2));
            [fz3, pz3] = detect_zone(detect_seg, Fs, 48, hi_z3, DETECT_DB, 5, DETECT_NFFT);

            mains_mask = abs(fz3 - MAINS_HZ) <= MAIN_TRACK_HZ;
            if any(mains_mask)
                f_main = fz3(mains_mask);
                p_main = pz3(mains_mask);
                [~, best_main] = max(p_main);
                main_f = min(max(f_main(best_main), MAINS_HZ - MAIN_TRACK_HZ), MAINS_HZ + MAIN_TRACK_HZ);
            end

            main_for_sep = MAINS_HZ;
            if isfinite(main_f)
                main_for_sep = main_f;
            end
            extra_mask = ~mains_mask & abs(fz3 - main_for_sep) >= MIN_SEP_HZ;
            f_extra = fz3(extra_mask);
            p_extra = pz3(extra_mask);
            if ~isempty(f_extra)
                [~, ord] = sort(p_extra, 'descend');
                f_extra = f_extra(ord);
                for kk = 1:numel(f_extra)
                    if numel(extra_f) >= MAX_EXTRA
                        break;
                    end
                    if isempty(extra_f) || all(abs(extra_f - f_extra(kk)) >= MIN_SEP_HZ)
                        extra_f(end+1) = f_extra(kk); %#ok<AGROW>
                    end
                end
                extra_f = sort(extra_f);
            end
        end

        freqs = NaN(1, max_sections);
        radii = NaN(1, max_sections);
        n_slots = 1;
        freqs(n_slots) = STATIC_50_HZ;
        radii(n_slots) = R_STATIC50;
        if isfinite(main_f) && abs(main_f - STATIC_50_HZ) > TRACK_GAP_HZ
            n_slots = min(n_slots + 1, max_sections);
            freqs(n_slots) = main_f;
            radii(n_slots) = R_MAINS;
        end
        n_extra = min(numel(extra_f), max_sections - n_slots);
        if n_extra > 0
            idx = (n_slots + 1):(n_slots + n_extra);
            freqs(idx) = extra_f(1:n_extra);
            radii(idx) = R_EXTRA;
        end
        [sos, freq_slots] = streaming_notch_sos(freqs, radii, Fs, max_sections);
        changed = ~isfinite(last_freqs) | ~isfinite(freq_slots) | abs(freq_slots - last_freqs) > 0.25;
        z(changed, :) = 0;
        last_freqs = freq_slots;

        for n = i1:i2
            [y(n), z] = sos_step(x(n), sos, z);
        end
    end
end

function [sos, freq_slots] = streaming_notch_sos(freqs, radii, Fs, max_sections)
    sos = repmat([1 0 0 1 0 0], max_sections, 1);
    freq_slots = NaN(max_sections, 1);
    n_active = min([numel(freqs), numel(radii), max_sections]);
    for kk = 1:n_active
        f0 = double(freqs(kk));
        if ~isfinite(f0) || f0 <= 0 || f0 >= 0.49 * Fs
            continue;
        end
        r = min(0.9995, max(0.90, double(radii(kk))));
        w0 = 2 * pi * f0 / Fs;
        cw = cos(w0);
        b = [1, -2*cw, 1];
        a = [1, -2*r*cw, r^2];
        b = normalize_notch_no_boost(b, a);
        sos(kk, :) = [b, 1, a(2), a(3)];
        freq_slots(kk) = f0;
    end
end

function b = normalize_notch_no_boost(b, a)
% Scale numerator so this section cannot amplify any frequency bin.
    grid_n = 4096;
    w = linspace(0, pi, grid_n);
    z1 = exp(-1i * w);
    z2 = exp(-2i * w);
    H = (b(1) + b(2) * z1 + b(3) * z2) ./ (a(1) + a(2) * z1 + a(3) * z2);
    Hgood = H(isfinite(H));
    if isempty(Hgood)
        return;
    end
    peak_gain = max(abs(Hgood));
    if isfinite(peak_gain) && peak_gain > 1
        b = b / peak_gain;
    end
end

function [out, z] = sos_step(sample, sos, z)
    s = sample;
    if ~isfinite(s)
        s = 0;
    end
    for st = 1:size(sos, 1)
        b0 = sos(st, 1); b1 = sos(st, 2); b2 = sos(st, 3);
        a1 = sos(st, 5); a2 = sos(st, 6);
        out = b0 * s + z(st, 1);
        z(st, 1) = b1 * s - a1 * out + z(st, 2);
        z(st, 2) = b2 * s - a2 * out;
        s = out;
    end
    out = s;
    if ~isfinite(out)
        out = 0;
    end
end

function x = finite_column(x)
    x = double(x(:));
    if isempty(x)
        return;
    end
    last = 0;
    for ii = 1:numel(x)
        if isfinite(x(ii))
            last = x(ii);
        else
            x(ii) = last;
        end
    end
    x(~isfinite(x)) = 0;
end


% =============================================================================
% SPECTRAL ZONE DETECTOR
% =============================================================================

function [freqs, proms] = detect_zone(x, Fs, lo, hi, thresh_db, max_f, Nfft)
% Thin wrapper: calls detect_zone_with_spectrum and discards spectrum outputs.
    [freqs, proms, ~, ~] = detect_zone_with_spectrum(x, Fs, lo, hi, thresh_db, max_f, Nfft);
end

function [freqs, proms, P_avg, f_axis] = detect_zone_with_spectrum(x, Fs, lo, hi, thresh_db, max_f, Nfft)
% DETECT_ZONE_WITH_SPECTRUM  Welch-based narrowband interference detector.
%
%   Returns detected frequencies (Hz), their prominence above the local
%   spectral floor (dB), and the full one-sided Welch power spectrum.
%
%   Algorithm:
%     1. Averaged Welch periodogram: 50% overlapping Hanning windows.
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
% FIXED-FREQUENCY HELPERS (N3, N5, N6, N8)
% =============================================================================

function y = nlms_notch(x, mu, omega)
% Fixed-frequency NLMS adaptive notch: N3 and N5.
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
% Fixed-frequency RLS adaptive notch: N6 and N8.
% Minimises exponentially weighted cost; window approx 1/(1-lambda) samples.
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
