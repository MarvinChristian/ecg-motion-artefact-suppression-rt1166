function y = apply_biquad(sos_matlab, x)
if nargin < 2
    error('apply_biquad requires two inputs: y = apply_biquad(sos_matlab, x). Run phase3_analyzer for the GUI.');
end
% APPLY_BIQUAD  Apply a MATLAB-format SOS filter sample-by-sample.
%
%   y = apply_biquad(sos_matlab, x)
%
%   Implements the Transposed Direct Form II biquad cascade - the same
%   structure used by arm_biquad_cascade_df2T_f32 in the NXP firmware.
%   Running sample-by-sample (rather than using MATLAB's filter() or
%   sosfilt() which process the whole signal at once) ensures numerical
%   agreement with the firmware and reveals startup transients correctly.
%
%   INPUTS:
%     sos_matlab : N_stages x 6 matrix in MATLAB SOS format:
%                  [b0 b1 b2  1  a1 a2]  per row
%                  NOTE: if your coefficients come from the firmware
%                  (CMSIS format), convert first with cmsis2matlab().
%     x          : input signal, any length, column or row vector
%
%   OUTPUT:
%     y          : filtered signal, same size as x
%
%   CMSIS vs MATLAB sign convention:
%     CMSIS stores a1, a2 with their signs FLIPPED relative to MATLAB.
%     CMSIS: [b0 b1 b2  a1_cmsis  a2_cmsis]
%     MATLAB: [b0 b1 b2  1  -a1_cmsis  -a2_cmsis]
%     Use cmsis2matlab() to convert before passing to this function.
%
%   REFERENCE:
%     ARM CMSIS-DSP: arm_biquad_cascade_df2T_f32 (Transposed DF-II)
%     Proakis & Manolakis, DSP 4th ed., section 6.1 (direct form structures)

x        = double(x(:));   % ensure column vector
N        = length(x);
n_stages = size(sos_matlab, 1);
y        = zeros(N, 1);

% Initialise state registers to steady-state for the first sample. This
% matches a continuously running firmware filter and avoids artificial
% recording-start transients in offline analysis.
w  = zeros(n_stages, 2);
s0 = x(1);
for st = 1:n_stages
    b0 = sos_matlab(st,1); b1 = sos_matlab(st,2); b2 = sos_matlab(st,3);
    a1 = sos_matlab(st,5); a2 = sos_matlab(st,6);
    denom = 1 + a1 + a2;
    bsum = b0 + b1 + b2;
    if abs(denom) < 1e-12
        if abs(bsum) < 1e-12
            out0 = 0;
        else
            out0 = s0;
        end
    else
        out0 = s0 * bsum / denom;
    end
    w(st,1) = out0 - b0*s0;
    w(st,2) = b2*s0 - a2*out0;
    s0 = out0;
end

for i = 1:N
    s = x(i);
    for st = 1:n_stages
        b0 = sos_matlab(st,1);  b1 = sos_matlab(st,2);  b2 = sos_matlab(st,3);
        % sos_matlab(st,4) = 1 (leading denominator - ignored in TDF-II)
        a1 = sos_matlab(st,5);  a2 = sos_matlab(st,6);

        % Transposed Direct Form II update equations:
        %   out    = b0*s  + w1
        %   w1_new = b1*s  - a1*out + w2
        %   w2_new = b2*s  - a2*out
        out     = b0*s + w(st,1);
        w(st,1) = b1*s - a1*out + w(st,2);
        w(st,2) = b2*s - a2*out;
        s = out;
    end
    y(i) = s;
end
end
