function [sig_mV, Fs, info] = wfdb_read212(dat_file, hea_file, channel)
% WFDB_READ212  Read a WFDB format-212 binary signal without the WFDB toolbox.
%
%   [sig_mV, Fs, info] = wfdb_read212(dat_file, hea_file)
%   [sig_mV, Fs, info] = wfdb_read212(dat_file, hea_file, channel)
%
%   INPUTS:
%     dat_file : path to WFDB .dat file (binary, format 212)
%     hea_file : path to matching .hea header file
%     channel  : 1-based channel index (default 1 = first signal, e.g. MLII)
%
%   OUTPUTS:
%     sig_mV : ECG signal in millivolts, column vector
%     Fs     : sample rate in Hz (from header)
%     info   : struct — Fs, n_channels, n_samples, gain(:), baseline(:), label(:)
%
%   FORMAT 212 ENCODING (PhysioNet WFDB specification):
%     Three consecutive bytes [b0 b1 b2] encode two consecutive 12-bit samples:
%       sample_even = b0 | ((b2 & 0x0F) << 8)    -- lower nibble of b2
%       sample_odd  = b1 | ((b2 & 0xF0) << 4)    -- upper nibble of b2
%     Both are sign-extended: if value >= 2048, value -= 4096.
%
%   PHYSICAL CONVERSION:
%     sig_mV = (raw_adc - baseline) / gain
%
%   For MIT-BIH Arrhythmia Database and MIT-BIH NST records:
%     Fs = 360 Hz, gain = 200 LSB/mV, baseline = 1024 (ADC zero)
%     Channel 1 = MLII (modified lead II), Channel 2 = V1 or V5.
%
%   MULTI-CHANNEL INTERLEAVING:
%     Samples cycle through all channels before advancing in time:
%       global sequence: ch1_t0, ch2_t0, ch1_t1, ch2_t1, ...
%     This function extracts one channel by taking every n_channels-th sample.
%
%   Reference: PhysioNet WFDB format specification
%     https://physionet.org/physiotools/wag/signal-5.htm

if nargin < 3, channel = 1; end

info = parse_hea(hea_file);
Fs   = info.Fs;

if channel < 1 || channel > info.n_channels
    error('wfdb_read212: channel %d requested but header declares %d channel(s).', ...
          channel, info.n_channels);
end

% Read raw binary
fid = fopen(dat_file, 'rb');
if fid < 0
    error('wfdb_read212: cannot open %s', dat_file);
end
raw_bytes = fread(fid, Inf, 'uint8');
fclose(fid);

% Total global samples across all channels
n_global = info.n_samples * info.n_channels;
n_pairs  = ceil(n_global / 2);
n_needed = n_pairs * 3;

if numel(raw_bytes) < n_needed
    % Truncate n_global to match what is actually on disk
    n_pairs  = floor(numel(raw_bytes) / 3);
    n_global = n_pairs * 2;
end

% Decode format-212: 3 bytes -> 2 signed 12-bit integers
raw_adc = zeros(n_global, 1, 'int32');
b0 = int32(raw_bytes(1:3:3*n_pairs));
b1 = int32(raw_bytes(2:3:3*n_pairs));
b2 = int32(raw_bytes(3:3:3*n_pairs));

s_even = bitor(b0, bitshift(bitand(b2, int32(15)),  8));  % lower nibble
s_odd  = bitor(b1, bitshift(bitand(b2, int32(240)), 4));  % upper nibble

% Sign extension: values >= 2048 are negative
s_even(s_even >= 2048) = s_even(s_even >= 2048) - 4096;
s_odd( s_odd  >= 2048) = s_odd( s_odd  >= 2048) - 4096;

% Interleave back into global sample array
raw_adc(1:2:end) = s_even;
raw_adc(2:2:end) = s_odd;

% Extract requested channel (every n_channels-th global sample starting at channel)
ch_raw = raw_adc(channel : info.n_channels : end);
n_ch   = min(numel(ch_raw), info.n_samples);
ch_raw = ch_raw(1:n_ch);

% Physical unit conversion
gain     = info.gain(channel);
baseline = info.baseline(channel);
sig_mV   = double(ch_raw - baseline) / gain;
end

% =========================================================================
function info = parse_hea(hea_file)
% Parse a WFDB .hea header file.
% Returns struct with Fs, n_channels, n_samples, gain, baseline, label arrays.
%
% WFDB header format:
%   Line 1:  record_name  n_channels  Fs  [n_samples  ...]
%   Lines 2+: filename  fmt  gain[/unit]  adcres  adczero  adcoffset ...
%             (adczero is the physical zero of the ADC in LSB = our baseline)

fid = fopen(hea_file, 'rt');
if fid < 0, error('wfdb_read212: cannot open header %s', hea_file); end

lines = {};
while ~feof(fid)
    L = strtrim(fgetl(fid));
    if ischar(L) && ~isempty(L) && L(1) ~= '#'
        lines{end+1} = L; %#ok<AGROW>
    end
end
fclose(fid);

if isempty(lines)
    error('wfdb_read212: header %s is empty or has only comments.', hea_file);
end

% ── Record line ──
tok = strsplit(lines{1});
info.n_channels = str2double(tok{2});
info.Fs         = str2double(tok{3});
if numel(tok) >= 4
    info.n_samples = str2double(tok{4});
else
    info.n_samples = Inf;
end

% ── Signal specification lines (one per channel) ──
% Fields: filename fmt gain adcres adczero adcoffset firstvalue checksum blocksize label
info.gain     = 200 * ones(1, info.n_channels);  % MIT-BIH default
info.baseline = zeros(1, info.n_channels);
info.label    = cell(1, info.n_channels);
for k = 1:info.n_channels
    info.label{k} = sprintf('ch%d', k);
end

for ch = 1:info.n_channels
    line_idx = ch + 1;
    if line_idx > numel(lines), break; end
    p = strsplit(lines{line_idx});

    % Column 3: gain (may have /unit suffix, e.g. "200/mV" or "200")
    if numel(p) >= 3
        gn = regexp(p{3}, '^([0-9.]+)', 'tokens', 'once');
        if ~isempty(gn)
            info.gain(ch) = str2double(gn{1});
        end
    end

    % Column 5: adczero (ADC output for 0 mV = baseline)
    if numel(p) >= 5
        bl = str2double(p{5});
        if ~isnan(bl)
            info.baseline(ch) = bl;
        end
    end

    % Label: last non-numeric token (column 9 in full MIT-BIH headers)
    if numel(p) >= 9
        info.label{ch} = p{9};
    elseif numel(p) >= 4
        info.label{ch} = p{end};
    end
end
end
