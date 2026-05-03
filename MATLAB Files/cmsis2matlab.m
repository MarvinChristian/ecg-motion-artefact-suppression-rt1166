function sos_ml = cmsis2matlab(sos_cmsis)
% CMSIS2MATLAB  Convert CMSIS-format SOS to MATLAB SOS format.
%
%   sos_ml = cmsis2matlab(sos_cmsis)
%
%   The NXP firmware (bandpass_filter.c, notch_filter.c) stores biquad
%   coefficients in CMSIS format where a1 and a2 are stored with their
%   signs NEGATED relative to the standard difference equation. MATLAB's
%   sosfilt(), freqz(), fvtool, and apply_biquad() all expect the standard
%   convention with a leading 1 in the denominator row.
%
%   CMSIS format  (N × 5): [b0  b1  b2  a1_cmsis  a2_cmsis]
%   MATLAB format (N × 6): [b0  b1  b2  1  -a1_cmsis  -a2_cmsis]
%
%   The negation recovers the original scipy/standard a1 and a2.
%   The leading 1 is added as MATLAB's SOS convention expects it.
%
%   EXAMPLE:
%     % B1 first stage from bandpass_filter.c:
%     row_cmsis = [2.1388e-03, 4.2776e-03, 2.1388e-03, 1.2279, -0.3935];
%     row_ml    = cmsis2matlab(row_cmsis);
%     % row_ml = [2.1388e-03, 4.2776e-03, 2.1388e-03, 1, -1.2279, 0.3935]

n       = size(sos_cmsis, 1);
sos_ml  = [sos_cmsis(:,1:3),  ones(n,1),  -sos_cmsis(:,4),  -sos_cmsis(:,5)];
end