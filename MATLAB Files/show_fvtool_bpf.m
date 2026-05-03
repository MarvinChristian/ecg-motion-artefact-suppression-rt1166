function show_fvtool_bpf(indices, BPF)
% SHOW_FVTOOL_BPF  Launch fvtool for selected bandpass filters.
%
%   show_fvtool_bpf(indices, BPF)
%
%   INPUTS:
%     indices : scalar or vector of BPF indices to show, e.g. 1:6 or [1 5]
%     BPF     : the BPF struct array from phase2_coefficients.m
%
%   EXAMPLES:
%     show_fvtool_bpf(1:6, BPF)      % all 6 overlaid
%     show_fvtool_bpf([1 5], BPF)    % B1 vs B5
%     show_fvtool_bpf(2, BPF)        % B2 only
%
%   In the fvtool window use the Analysis menu:
%     Magnitude Response  — passband flatness and stopband attenuation
%     Phase Response      — phase linearity
%     Group Delay         — constant = no frequency-dependent distortion
%     Impulse Response    — settling time after a transient

if nargin < 2
    error(['Pass the BPF struct as the second argument.\n' ...
           'Usage: show_fvtool_bpf(1:6, BPF)\n' ...
           'Run phase2_coefficients.m first to create BPF.']);
end

dfilt_objs = {};
names      = {};

for k = indices(:)'
    dfilt_objs{end+1} = dfilt.df2tsos(BPF(k).sos); %#ok<AGROW>
    names{end+1}      = BPF(k).name;               %#ok<AGROW>
end

hf = fvtool(dfilt_objs{:}, 'Fs', 500);
legend(hf, names{:});
title(hf, 'Bandpass Filter Frequency Response  (Fs = 500 Hz)');
end