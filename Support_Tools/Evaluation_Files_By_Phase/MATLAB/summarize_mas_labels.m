function summary = summarize_mas_labels(label_mat_path)
% SUMMARIZE_MAS_LABELS Print label counts before training.
%
% Usage:
%   summarize_mas_labels('...\revised_mas_labels.mat')

if nargin < 1 || isempty(label_mat_path)
    [fn, fd] = uigetfile('*.mat', 'Select revised_mas_labels.mat');
    if isequal(fn, 0)
        summary = table();
        return;
    end
    label_mat_path = fullfile(fd, fn);
end

d = load(label_mat_path);
required = {'epochInfo','y_final'};
for ii = 1:numel(required)
    if ~isfield(d, required{ii})
        error('Missing "%s" in %s.', required{ii}, label_mat_path);
    end
end

if isfield(d, 'groupLabels') && ismember('decision_label', d.groupLabels.Properties.VariableNames)
    decisions = string(d.groupLabels.decision_label);
else
    decisions = strings(0, 1);
end

leads = unique(string(d.epochInfo.lead), 'stable');
comboIds = unique(double(d.epochInfo.combo_id), 'stable');
leadCol = strings(0, 1);
comboCol = zeros(0, 1);
usableCol = zeros(0, 1);
rejectCol = zeros(0, 1);
skipCol = zeros(0, 1);
for li = 1:numel(leads)
    for ci = 1:numel(comboIds)
        mask = string(d.epochInfo.lead) == leads(li) & double(d.epochInfo.combo_id) == comboIds(ci);
        leadCol(end+1, 1) = leads(li); %#ok<AGROW>
        comboCol(end+1, 1) = comboIds(ci); %#ok<AGROW>
        usableCol(end+1, 1) = nnz(mask & d.y_final == 1); %#ok<AGROW>
        rejectCol(end+1, 1) = nnz(mask & d.y_final == 0); %#ok<AGROW>
        skipCol(end+1, 1) = nnz(mask & d.y_final == 2); %#ok<AGROW>
    end
end
summary = table(leadCol, comboCol, usableCol, rejectCol, skipCol, ...
    'VariableNames', {'lead','combo_id','usable','rejected','skipped_or_open'});

fprintf('\nMAS label summary:\n  %s\n', char(string(label_mat_path)));
disp(summary);
if ~isempty(decisions)
    fprintf('Group decisions:\n');
    cats = unique(decisions, 'stable');
    for ii = 1:numel(cats)
        fprintf('  %-12s %d\n', char(cats(ii)), nnz(decisions == cats(ii)));
    end
end

if any(summary.usable < 10)
    warning('Some lead/combo classes have fewer than 10 usable examples. Train results may be unstable.');
end
if any(summary.rejected < 10)
    warning('Some lead/combo classes have fewer than 10 rejected examples. Add corrupted/rejected examples before trusting ML.');
end
end
