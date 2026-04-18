function show_fvtool_notch(indices, NOTCH)
% SHOW_FVTOOL_NOTCH  Launch fvtool for IIR notch filters N1 and/or N2.
%
%   show_fvtool_notch(indices, NOTCH)
%
%   Only N1 and N2 have SOS matrices suitable for fvtool.
%   N3-N8 are adaptive and have no fixed frequency response to display.
%
%   INPUTS:
%     indices : 1 or 2, or [1 2] for both overlaid
%     NOTCH   : the NOTCH struct array from phase2_coefficients.m
%
%   EXAMPLES:
%     show_fvtool_notch(1:2, NOTCH)   % N1 vs N2 overlaid
%     show_fvtool_notch(1, NOTCH)     % N1 only

if nargin < 2
    error(['Pass the NOTCH struct as the second argument.\n' ...
           'Usage: show_fvtool_notch(1:2, NOTCH)\n' ...
           'Run phase2_coefficients.m first to create NOTCH.']);
end

valid = indices(indices <= 2);
if isempty(valid)
    warning('Only N1 and N2 have SOS for fvtool. N3-N8 are adaptive.');
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