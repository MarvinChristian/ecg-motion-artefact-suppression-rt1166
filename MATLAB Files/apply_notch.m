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
%   N6 implementation notes (2026-04-23):
%     1. Past-window FFT detection: non-mains tones are selected from prior
%        samples only, then applied to the next processing block.
%     2. No-boost FFT attenuation: smooth Gaussian masks with gain clipped to
%        [0, 1]; avoids adaptive misadjustment that can raise broadband energy.
%     3. Fixed 50 Hz attenuation: unconditional smooth notch always applied.

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

    % N6: Causal FFT no-boost multi-frequency attenuation
    % Always attenuates 50 Hz. Detects non-mains narrowband interference from
    % past samples and applies smooth FFT-bin attenuation with gain <= 1.
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
% N6 (n9_pipeline_causal)  Streaming-style causal FFT notch with past-window detection.
%
% Fixed 50 Hz cancellation is always applied. Extra non-mains narrowband
% frequencies are selected from prior samples only, using an FFT/Welch window
% that ends before the block being filtered. Very large in-band spikes are
% capped toward the local spectral floor within the current output frame; in
% firmware this maps to normal block processing with one-frame latency.

    MAINS_HZ     = 50;
    DETECT_NFFT  = 512;
    FRAME_SEC    = 1.0;
    HIST_SEC     = 4.0;
    DETECT_DB    = 8.0;
    INBAND_DB    = 12.0;
    MAX_EXTRA    = 2;
    MAX_INBAND   = 5;
    MIN_SEP_HZ   = 6.0;
    NOTCH_WIDTH  = 0.75;
    INBAND_WIDTH = 2.0;
    MAINS_DEPTH  = 0.92;
    EXTRA_DEPTH_MAX = 0.85;
    INBAND_DEPTH_MAX = 0.60;

    if nargin < 3 || isempty(detect_from)
        detect_from = x;
    else
        detect_from = double(detect_from(:));
    end

    x = double(x(:));
    N = numel(x);

    frame_len = max(128, round(FRAME_SEC * Fs));
    frame_len = 2^nextpow2(frame_len);
    hop_len   = max(1, frame_len / 2);
    nfft      = max(DETECT_NFFT, frame_len);
    hist_len  = max(DETECT_NFFT, round(HIST_SEC * Fs));
    hi_z3     = max(49, Fs/2 - 5);
    if N == 0
        y = x;
        return;
    end

    win = sin(pi*((0:frame_len-1)' + 0.5) / frame_len);
    y_acc = zeros(N, 1);
    w_acc = zeros(N, 1);

    for i1 = 1:hop_len:N
        i2 = min(N, i1 + frame_len - 1);
        valid_len = i2 - i1 + 1;
        h2 = i1 - 1;
        h1 = max(1, h2 - hist_len + 1);

        detected_f = [];
        detected_p = [];
        inband_f = [];
        inband_p = [];
        if hi_z3 > 49 && h2 >= h1 && (h2 - h1 + 1) >= max(64, round(0.75 * DETECT_NFFT))
            detect_seg = detect_from(h1:h2);
            [fz3, pz3] = detect_zone(detect_seg, Fs, 48, hi_z3, DETECT_DB, 5, DETECT_NFFT);

            mains_mask = abs(fz3 - MAINS_HZ) < MIN_SEP_HZ;
            fz3 = fz3(~mains_mask);
            pz3 = pz3(~mains_mask);
            if ~isempty(fz3)
                [pz3, ord] = sort(pz3, 'descend');
                fz3 = fz3(ord);
                for kk = 1:numel(fz3)
                    if numel(detected_f) >= MAX_EXTRA
                        break;
                    end
                    if isempty(detected_f) || all(abs(detected_f - fz3(kk)) >= MIN_SEP_HZ)
                        detected_f(end+1) = fz3(kk); %#ok<AGROW>
                        detected_p(end+1) = pz3(kk); %#ok<AGROW>
                    end
                end
            end

            hi_in = min(44.0, Fs/2 - 6.0);
            if hi_in > 1.0
                [fin, pin] = detect_zone(detect_seg, Fs, 1.0, hi_in, INBAND_DB, MAX_INBAND + 2, DETECT_NFFT);
                if ~isempty(fin)
                    [pin, ord_in] = sort(pin, 'descend');
                    fin = fin(ord_in);
                    inband_f = fin(1:min(MAX_INBAND, numel(fin)));
                    inband_p = pin(1:numel(inband_f));
                end
            end
        end

        x_frame = zeros(frame_len, 1);
        x_frame(1:valid_len) = x(i1:i2);
        X = fft(x_frame .* win, nfft);
        frame_power = abs(X).^2 + realmin;
        f = (0:nfft-1)' * Fs / nfft;
        f_fold = min(f, Fs - f);
        gain = ones(nfft, 1);

        gain = min(gain, 1 - MAINS_DEPTH * exp(-0.5*((f_fold - MAINS_HZ)/NOTCH_WIDTH).^2));
        for kk = 1:numel(detected_f)
            depth = min(EXTRA_DEPTH_MAX, 0.25 + 0.03 * detected_p(kk));
            gain = min(gain, 1 - depth * exp(-0.5*((f_fold - detected_f(kk))/NOTCH_WIDTH).^2));
        end
        for kk = 1:numel(inband_f)
            gain = min(gain, 1 - INBAND_DEPTH_MAX * exp(-0.5*((f_fold - inband_f(kk))/INBAND_WIDTH).^2));
        end

        % No-boost guarantee: every FFT-bin gain is clipped to [0, 1].
        gain = max(0, min(1, gain));
        y_frame = real(ifft(X .* gain, nfft));
        y_frame = y_frame(1:frame_len) .* win;
        y_acc(i1:i2) = y_acc(i1:i2) + y_frame(1:valid_len);
        w_acc(i1:i2) = w_acc(i1:i2) + win(1:valid_len).^2;
    end

    y = x;
    ok = w_acc > 1e-8;
    y(ok) = y_acc(ok) ./ w_acc(ok);
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
