function show_fvtool_notch(indices, NOTCH)
% SHOW_FVTOOL_NOTCH  Launch fvtool for the IIR notch filter N1.
%
%   show_fvtool_notch(indices, NOTCH)
%
%   Only N1 has an SOS matrix suitable for fvtool.
%   N2-N6 are adaptive or FFT-based and have no fixed frequency response.
%
%   INPUTS:
%     indices : 1 (only N1 is valid)
%     NOTCH   : the NOTCH struct array from phase2_coefficients.m
%
%   EXAMPLES:
%     show_fvtool_notch(1, NOTCH)     % N1 only

if nargin < 2
    error(['Pass the NOTCH struct as the second argument.\n' ...
           'Usage: show_fvtool_notch(1:2, NOTCH)\n' ...
           'Run phase2_coefficients.m first to create NOTCH.']);
end

valid = indices(indices <= 2);
if isempty(valid)
    warning('Only N1 has SOS for fvtool. N2-N6 are adaptive or FFT-based.');
    return;
end

dfilt_objs = {};
names      = {};

for k = valid(:)'
    dfilt_objs{end+1} = dfilt.df2tsos(NOTCH(k).sos); %#ok<AGROW>
    names{end+1}      = NOTCH(k).name;               %#ok<AGROW>
end

hf = fvtool(dfilt_objs{:}, 'Fs', 500);
legend(hf, names{:});
title(hf, 'IIR Notch Filter Frequency Response  (Fs = 500 Hz)');
end