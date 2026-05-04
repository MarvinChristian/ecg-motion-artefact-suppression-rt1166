function train_visualise_gui(feature_mat_path)
% TRAIN_VISUALISE_GUI  Hyperparameter grid search + training visualisation.
%
% Loads revised_labels.mat (or epoch_features.mat), runs a grid search over
% model-specific hyperparameters using leave-one-recording-out (LORO) CV,
% trains the final model with the best parameters, and visualises all results.
%
% Evaluation strategy: LORO-CV
%   Each fold withholds all epochs from one recording entirely. This tests
%   generalisation to unseen recordings, which is the real deployment scenario.
%   Epoch-level k-fold CV is avoided because adjacent epochs from the same
%   recording share electrode placement, motion profile and noise floor, causing
%   information leakage across folds that inflates reported metrics.
%
% Optimisation criterion: balanced accuracy = (sensitivity + specificity) / 2.
%   Appropriate for the ~75/25 clean/corrupted class imbalance — raw accuracy
%   is biased toward the majority class.
%
% Supported models
%   1. Decision Tree  (CART, fitctree)
%   2. Random Forest  (bagged trees, fitcensemble)
%   3. RBF SVM        (fitcsvm, Gaussian kernel)
%   4. Linear SVM     (fitclinear, L2-regularised)
%   5. k-NN           (fitcknn, choice of distance metric)
%
% Usage
%   train_visualise_gui()
%   train_visualise_gui('MATLAB Files/outputs/.../revised_labels.mat')

if nargin < 1; feature_mat_path = ''; end

% ── Colour palette ────────────────────────────────────────────────────────────
C_BG    = [0.10 0.11 0.13];
C_PANEL = [0.12 0.12 0.15]; %#ok<NASGU>
C_INPUT = [0.13 0.13 0.16];
C_FG    = [0.85 0.85 0.85];
C_DIM   = [0.55 0.60 0.65];
C_GO    = [0.20 0.55 0.30];
C_BLUE  = [0.25 0.45 0.65];
C_AX    = [0.08 0.09 0.11];

% ── Model configurations ──────────────────────────────────────────────────────
% Each entry defines the model name, two hyperparameter axes for the grid
% search, and optional string labels for categorical axes.
MODELS(1).name     = 'Decision Tree';
MODELS(1).p1Name   = 'MaxNumSplits';
MODELS(1).p1Grid   = [7, 15, 31, 63, 127];
MODELS(1).p1Labels = {};
MODELS(1).p2Name   = 'MinLeafSize';
MODELS(1).p2Grid   = [2, 5, 10, 20];
MODELS(1).p2Labels = {};

MODELS(2).name     = 'Random Forest';
MODELS(2).p1Name   = 'NumLearningCycles';
MODELS(2).p1Grid   = [10, 25, 50, 100, 200];
MODELS(2).p1Labels = {};
MODELS(2).p2Name   = 'MinLeafSize';
MODELS(2).p2Grid   = [1, 2, 5, 10];
MODELS(2).p2Labels = {};

MODELS(3).name     = 'RBF SVM';
MODELS(3).p1Name   = 'BoxConstraint';
MODELS(3).p1Grid   = [0.1, 1, 10, 100];
MODELS(3).p1Labels = {'0.1','1','10','100'};
MODELS(3).p2Name   = 'KernelScale';
MODELS(3).p2Grid   = [0.1, 1, 10, 100];
MODELS(3).p2Labels = {'0.1','1','10','100'};

MODELS(4).name     = 'Linear SVM';
MODELS(4).p1Name   = 'Lambda';
MODELS(4).p1Grid   = [1e-4, 1e-3, 1e-2, 1e-1, 1];
MODELS(4).p1Labels = {'1e-4','1e-3','1e-2','0.1','1'};
MODELS(4).p2Name   = '(none)';
MODELS(4).p2Grid   = [1];
MODELS(4).p2Labels = {' '};

MODELS(5).name     = 'k-NN';
MODELS(5).p1Name   = 'NumNeighbors';
MODELS(5).p1Grid   = [1, 3, 5, 11, 21];
MODELS(5).p1Labels = {};
MODELS(5).p2Name   = 'Distance';
MODELS(5).p2Grid   = [1, 2, 3];
MODELS(5).p2Labels = {'euclidean', 'cosine', 'correlation'};

% A true CNN requires raw time-series epochs as input, not extracted features.
% fitcnet (MLP) is the correct neural network choice for a 21-element feature
% vector — it applies nonlinear learned transformations without assuming local
% spatial structure that doesn't exist in this feature space.
MODELS(6).name     = 'Neural Net (MLP)';
MODELS(6).p1Name   = 'HiddenSize';
MODELS(6).p1Grid   = [16, 32, 64, 128];
MODELS(6).p1Labels = {};
MODELS(6).p2Name   = 'Lambda (L2)';
MODELS(6).p2Grid   = [1e-4, 1e-3, 1e-2, 1e-1];
MODELS(6).p2Labels = {'1e-4','1e-3','1e-2','0.1'};

% ELM: random input weights fixed at init; only output weights are learned via
% regularised least squares (one solve per fold — much faster than MLP/SVM).
% p1 = hidden layer size, p2 = ridge regularisation C (higher = less penalty).
MODELS(7).name     = 'ELM';
MODELS(7).p1Name   = 'HiddenSize';
MODELS(7).p1Grid   = [16, 32, 64, 128, 256];
MODELS(7).p1Labels = {};
MODELS(7).p2Name   = 'Reg. C';
MODELS(7).p2Grid   = [0.1, 1, 10, 100];
MODELS(7).p2Labels = {'0.1','1','10','100'};

% ── State ─────────────────────────────────────────────────────────────────────
app              = struct();
app.X            = [];
app.y            = [];
app.featureNames = {};
app.epochInfo    = table();
app.fpath        = '';
app.loaded       = false;
app.trained      = false;
app.models       = MODELS;
app.modelIdx     = 1;
app.model        = struct();
app.paths        = local_paths();

% ── Figure ────────────────────────────────────────────────────────────────────
fig = uifigure( ...
    'Name',     'Epoch Classifier — Hyperparameter Search + Training', ...
    'Position', [40 40 1340 820], ...
    'Color',    C_BG);

outer = uigridlayout(fig, [4 1]);
outer.RowHeight       = {46, '1x', '1x', 54};
outer.Padding         = [10 8 10 8];
outer.RowSpacing      = 8;
outer.BackgroundColor = C_BG;

% ── Row 1: control bar ────────────────────────────────────────────────────────
ctrl = uigridlayout(outer, [1 6]);
ctrl.Layout.Row      = 1;
ctrl.ColumnWidth     = {120, '1x', 90, 130, 120, 220};
ctrl.Padding         = [0 4 0 4];
ctrl.ColumnSpacing   = 8;
ctrl.BackgroundColor = C_BG;

app.loadBtn = uibutton(ctrl, 'Text', 'Load Labels', ...
    'BackgroundColor', C_BLUE, 'FontColor', 'w', ...
    'ButtonPushedFcn', @on_load);
app.loadBtn.Layout.Column = 1;

app.fileLabel = uilabel(ctrl, ...
    'Text', 'No file loaded.', ...
    'FontColor', C_DIM, 'FontSize', 11, 'HorizontalAlignment', 'left');
app.fileLabel.Layout.Column = 2;

app.cvLabel = uilabel(ctrl, ...
    'Text', 'CV: LORO', 'FontColor', C_DIM, 'FontSize', 11, ...
    'HorizontalAlignment', 'center');
app.cvLabel.Layout.Column = 3;

app.modelDrop = uidropdown(ctrl, ...
    'Items', {MODELS.name}, 'Value', MODELS(1).name, ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG, ...
    'ValueChangedFcn', @on_model_change);
app.modelDrop.Layout.Column = 4;

app.metricDrop = uidropdown(ctrl, ...
    'Items', {'Balanced Acc','MCC','Accuracy','F1 Score'}, 'Value', 'Balanced Acc', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.metricDrop.Layout.Column = 5;

app.trainBtn = uibutton(ctrl, ...
    'Text',            'Run Grid Search + Train', ...
    'BackgroundColor', C_GO, 'FontColor', 'w', ...
    'FontWeight',      'bold', 'Enable', 'off', ...
    'ButtonPushedFcn', @on_train);
app.trainBtn.Layout.Column = 6;

% ── Row 2: grid heatmap + feature distributions ───────────────────────────────
top = uigridlayout(outer, [1 2]);
top.Layout.Row      = 2;
top.ColumnWidth     = {'1x', '1x'};
top.Padding         = [0 0 0 0];
top.ColumnSpacing   = 10;
top.BackgroundColor = C_BG;

app.gridAx = uiaxes(top);
app.gridAx.Layout.Column = 1;
style_axes(app.gridAx, 'Hyperparameter Grid  (waiting for search...)', ...
    MODELS(1).p1Name, MODELS(1).p2Name, C_AX);

app.distAx = uiaxes(top);
app.distAx.Layout.Column = 2;
style_axes(app.distAx, 'Feature Separation by Class  (top features, IQR boxes)', ...
    'Feature value', '', C_AX);

% ── Row 3: confusion matrix + feature importance ──────────────────────────────
bot = uigridlayout(outer, [1 2]);
bot.Layout.Row      = 3;
bot.ColumnWidth     = {'1x', '1x'};
bot.Padding         = [0 0 0 0];
bot.ColumnSpacing   = 10;
bot.BackgroundColor = C_BG;

app.cmAx = uiaxes(bot);
app.cmAx.Layout.Column = 1;
style_axes(app.cmAx, 'LORO-CV Confusion Matrix  (waiting for training...)', ...
    '', '', C_AX);

app.impAx = uiaxes(bot);
app.impAx.Layout.Column = 2;
style_axes(app.impAx, 'Feature Importance  (waiting for training...)', ...
    '', '', C_AX);

% ── Row 4: metrics bar ────────────────────────────────────────────────────────
mbar = uigridlayout(outer, [1 8]);
mbar.Layout.Row      = 4;
mbar.ColumnWidth     = {'1x','1x','1x','1x','1x','1x','1x','2x'};
mbar.Padding         = [0 4 0 4];
mbar.ColumnSpacing   = 10;
mbar.BackgroundColor = C_BG;

app.mAcc  = make_metric(mbar, 1, 'CV Accuracy',    C_DIM, C_FG);
app.mSens = make_metric(mbar, 2, 'Sensitivity',    C_DIM, C_FG);
app.mSpec = make_metric(mbar, 3, 'Specificity',    C_DIM, C_FG);
app.mBal  = make_metric(mbar, 4, 'Balanced Acc',   C_DIM, C_FG);
app.mF1   = make_metric(mbar, 5, 'F1 Score',       C_DIM, C_FG);
app.mMCC  = make_metric(mbar, 6, 'MCC',            C_DIM, C_FG);
app.mBase = make_metric(mbar, 7, 'Baseline (thr)', C_DIM, [0.88 0.70 0.30]);

app.mBestLabel = uilabel(mbar, ...
    'Text', 'Best params: —', ...
    'FontColor', C_DIM, 'FontSize', 10, 'HorizontalAlignment', 'left');
app.mBestLabel.Layout.Column = 8;

% ── Auto-load ─────────────────────────────────────────────────────────────────
if ~isempty(feature_mat_path)
    do_load(feature_mat_path);
end

% =============================================================================
% Callbacks
% =============================================================================

    function on_load(~, ~)
        startDir = fullfile(app.paths.subrepo, 'outputs');
        if ~isfolder(startDir); startDir = app.paths.subrepo; end
        [fn, fd] = uigetfile('*.mat', ...
            'Select revised_labels.mat or epoch_features.mat', startDir);
        if isequal(fn, 0); return; end
        do_load(fullfile(fd, fn));
    end

    function do_load(fpath)
        try
            d = load(fpath);
        catch ME
            uialert(fig, ME.message, 'Load failed'); return;
        end
        for rf = {'X','featureNames','epochInfo'}
            if ~isfield(d, rf{1})
                uialert(fig, sprintf('Missing field "%s".', rf{1}), 'Wrong file');
                return;
            end
        end
        if isfield(d, 'y_final')
            y_raw = double(d.y_final(:));
        elseif isfield(d, 'y')
            y_raw = double(d.y(:));
        else
            uialert(fig, 'No label field (y or y_final).', 'Wrong file'); return;
        end

        valid = isfinite(y_raw) & (y_raw == 0 | y_raw == 1);
        if sum(valid) < 20
            uialert(fig, sprintf('Only %d binary-labelled epochs. Need at least 20.', ...
                sum(valid)), 'Too few labels'); return;
        end

        app.X            = d.X(valid, :);
        app.y            = y_raw(valid);
        app.featureNames = d.featureNames;
        app.epochInfo    = d.epochInfo(valid, :);
        app.fpath        = fpath;
        app.loaded       = true;

        [~, fn, ext] = fileparts(fpath);
        nC = sum(app.y == 1); nX = sum(app.y == 0);
        rec_ids = unique(app.epochInfo.recording_id);
        app.fileLabel.Text = sprintf( ...
            '%s%s  —  %d epochs  |  clean: %d (%.0f%%)  corrupted: %d (%.0f%%)  |  %d recordings (LORO-CV)', ...
            fn, ext, numel(app.y), nC, 100*nC/numel(app.y), nX, 100*nX/numel(app.y), numel(rec_ids));

        app.trainBtn.Enable = 'on';
        draw_distributions();
        drawnow;
    end

    function on_model_change(~, ~)
        sel = find(strcmp({app.models.name}, app.modelDrop.Value), 1);
        if isempty(sel); return; end
        app.modelIdx = sel;
        cfg = app.models(sel);
        xlabel(app.gridAx, cfg.p1Name, 'Color', [0.55 0.55 0.55]);
        ylabel(app.gridAx, cfg.p2Name, 'Color', [0.55 0.55 0.55]);
        title(app.gridAx, sprintf('%s — Hyperparameter Grid', cfg.name), ...
            'Color', [0.78 0.78 0.78], 'FontSize', 10);
    end

    function on_train(~, ~)
        if ~app.loaded; return; end
        app.trainBtn.Enable = 'off';
        app.loadBtn.Enable  = 'off';
        cleanup = onCleanup(@() restore_btns()); %#ok<NASGU>
        try
            run_grid_search();
            train_best_model();
        catch ME
            uialert(fig, ME.message, 'Training failed');
        end
    end

    function restore_btns()
        app.trainBtn.Enable = 'on';
        app.loadBtn.Enable  = 'on';
    end

% =============================================================================
% Core computation
% =============================================================================

    function run_grid_search()
        cfg  = app.models(app.modelIdx);
        nS   = numel(cfg.p1Grid);
        nL   = numel(cfg.p2Grid);
        grid_score = nan(nL, nS);

        rec_ids = unique(app.epochInfo.recording_id, 'stable');
        n_rec   = numel(rec_ids);
        total   = nS * nL;

        for si = 1:nS
            for li = 1:nL
                p1_val = cfg.p1Grid(si);
                p2_val = cfg.p2Grid(li);

                cv_pred = zeros(size(app.y));
                for rr = 1:n_rec
                    te = app.epochInfo.recording_id == rec_ids(rr);
                    tr = ~te;
                    if sum(tr) < 4 || numel(unique(app.y(tr))) < 2
                        cv_pred(te) = mode(app.y(tr));
                        continue;
                    end
                    mdl = fit_model(cfg.name, app.X(tr,:), app.y(tr), ...
                        app.featureNames, p1_val, p2_val);
                    cv_pred(te) = predict_model(mdl, app.X(te,:));
                end

                cm_g = confusionmat(app.y, cv_pred);
                TP = cm_g(2,2); FN = cm_g(2,1);
                TN = cm_g(1,1); FP = cm_g(1,2);
                sens_g = TP / max(1, TP+FN);
                spec_g = TN / max(1, TN+FP);
                acc_g  = (TP+TN) / sum(cm_g(:));
                prec_g = TP / max(1, TP+FP);
                f1_g   = 2*prec_g*sens_g / max(1e-9, prec_g+sens_g);
                mcc_g  = ((TP*TN) - (FP*FN)) / ...
                    max(1e-9, sqrt((TP+FP)*(TP+FN)*(TN+FP)*(TN+FN)));

                switch app.metricDrop.Value
                    case 'Accuracy';  grid_score(li, si) = acc_g * 100;
                    case 'F1 Score';  grid_score(li, si) = f1_g  * 100;
                    case 'MCC';       grid_score(li, si) = mcc_g * 100;
                    otherwise;        grid_score(li, si) = 50*(sens_g + spec_g);
                end

                done = (si-1)*nL + li;
                best_so_far = max(grid_score(:), [], 'omitnan');
                title(app.gridAx, ...
                    sprintf('Grid search (%s): %d / %d  —  best so far: %.1f%%', ...
                    cfg.name, done, total, best_so_far), ...
                    'Color',[0.78 0.78 0.78], 'FontSize',10);
                drawnow;
            end
        end

        app.model.cfg        = cfg;
        app.model.grid_score = grid_score;
        app.model.metricName = app.metricDrop.Value;

        [~, best_idx]       = max(grid_score(:));
        [best_li, best_si]  = ind2sub(size(grid_score), best_idx);
        app.model.best_p1   = cfg.p1Grid(best_si);
        app.model.best_p2   = cfg.p2Grid(best_li);
        app.model.best_si   = best_si;
        app.model.best_li   = best_li;
        app.model.best_score = grid_score(best_li, best_si);

        draw_grid(grid_score, best_si, best_li);
    end

    function train_best_model()
        cfg    = app.model.cfg;
        p1_val = app.model.best_p1;
        p2_val = app.model.best_p2;

        % Final model trained on all labelled data.
        tree = fit_model(cfg.name, app.X, app.y, app.featureNames, p1_val, p2_val);

        % LORO-CV for reported metrics — each fold withholds all epochs from
        % one recording, testing generalisation to unseen recordings.
        rec_ids = unique(app.epochInfo.recording_id, 'stable');
        n_rec   = numel(rec_ids);
        cv_pred = zeros(size(app.y));

        for rr = 1:n_rec
            te = app.epochInfo.recording_id == rec_ids(rr);
            tr = ~te;
            if sum(tr) < 4 || numel(unique(app.y(tr))) < 2
                cv_pred(te) = mode(app.y(tr));
                continue;
            end
            mdl = fit_model(cfg.name, app.X(tr,:), app.y(tr), ...
                app.featureNames, p1_val, p2_val);
            cv_pred(te) = predict_model(mdl, app.X(te,:));
        end

        cm   = confusionmat(app.y, cv_pred);
        TP = cm(2,2); FN = cm(2,1);
        TN = cm(1,1); FP = cm(1,2);
        acc  = 100 * (TP+TN) / sum(cm(:));
        sens = 100 * TP / max(1, TP+FN);
        spec = 100 * TN / max(1, TN+FP);
        bal  = (sens + spec) / 2;
        prec = 100 * TP / max(1, TP+FP);
        f1   = 2 * prec * sens / max(1e-6, prec+sens);
        mcc  = (TP*TN - FP*FN) / max(1, sqrt((TP+FP)*(TP+FN)*(TN+FP)*(TN+FN)));

        % Hard motion-threshold baseline (motion_score < 3) for comparison.
        mc = find(strcmpi(app.featureNames, 'motion_score'), 1);
        if ~isempty(mc)
            th_pred = double(app.X(:, mc) < 3);
            th_cm   = confusionmat(app.y, th_pred);
            th_TP = th_cm(2,2); th_FN = th_cm(2,1);
            th_TN = th_cm(1,1); th_FP = th_cm(1,2);
            th_bal = 50 * (th_TP/max(1,th_TP+th_FN) + th_TN/max(1,th_TN+th_FP));
            app.mBase.Text = sprintf('%.1f%%', th_bal);
        else
            app.mBase.Text = 'N/A';
        end

        imp = get_importance(tree, cfg.name, app.featureNames, app.X, app.y);

        app.model.tree  = tree;
        app.model.cm    = cm;
        app.model.acc   = acc;
        app.model.sens  = sens;
        app.model.spec  = spec;
        app.model.bal   = bal;
        app.model.f1    = f1;
        app.model.mcc   = mcc;
        app.model.imp   = imp;
        app.model.featureNames = app.featureNames;
        app.model.kfold_acc    = acc;
        app.model.kfold_sens   = sens;
        app.model.kfold_spec   = spec;
        app.model.max_depth    = tree_depth(tree);
        app.trained     = true;

        draw_confusion(cm);
        draw_importance(imp);

        app.mAcc.Text  = sprintf('%.1f%%', acc);
        app.mSens.Text = sprintf('%.1f%%', sens);
        app.mSpec.Text = sprintf('%.1f%%', spec);
        app.mBal.Text  = sprintf('%.1f%%', bal);
        app.mF1.Text   = sprintf('%.1f%%', f1);
        app.mMCC.Text  = sprintf('%.3f',   mcc);

        p1_str = format_param(cfg, 'p1', app.model.best_si);
        p2_str = format_param(cfg, 'p2', app.model.best_li);
        app.mBestLabel.Text = sprintf( ...
            'Model: %s  |  %s=%s  %s=%s  |  %s=%.1f%%  (LORO-CV, %d recordings)', ...
            cfg.name, cfg.p1Name, p1_str, cfg.p2Name, p2_str, ...
            app.model.metricName, app.model.best_score, n_rec);

        save_outputs();
    end

    function s = format_param(cfg, which, idx)
        labels = cfg.([which 'Labels']);
        grid   = cfg.([which 'Grid']);
        if ~isempty(labels) && idx <= numel(labels)
            s = labels{idx};
        else
            s = num2str(grid(idx));
        end
    end

    function save_outputs()
        model_slug = lower(regexprep(app.model.cfg.name, '[^a-zA-Z0-9]+', '_'));
        outDir = fullfile(app.paths.subrepo, 'outputs', ...
            char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
        if ~exist(outDir, 'dir'); mkdir(outDir); end
        model = app.model; %#ok<NASGU>
        fname = sprintf('epoch_classifier_%s.mat', model_slug);
        save(fullfile(outDir, fname), 'model');

        if strcmp(app.model.cfg.name, 'Decision Tree')
            view(app.model.tree, 'Mode', 'text');
            fprintf('\nRun export_tree_to_c(model) to generate firmware C arrays.\n');
        end

        [~, fn, ext] = fileparts(app.fpath);
        app.fileLabel.Text = sprintf('%s%s  →  Saved: %s', fn, ext, fullfile(outDir, fname));
        fprintf('\nModel (%s) saved to:\n  %s\n', app.model.cfg.name, fullfile(outDir, fname));
    end

% =============================================================================
% Drawing
% =============================================================================

    function draw_grid(grid_score, best_si, best_li)
        cfg  = app.model.cfg;
        nS   = numel(cfg.p1Grid);
        nL   = numel(cfg.p2Grid);

        cla(app.gridAx);
        imagesc(app.gridAx, 1:nS, 1:nL, grid_score);
        colormap(app.gridAx, parula);
        cb              = colorbar(app.gridAx);
        cb.Color        = [0.62 0.68 0.74];
        cb.Label.String = sprintf('%s (%%)', app.metricDrop.Value);
        cb.Label.Color  = [0.62 0.68 0.74];

        % X-axis: p1 values
        app.gridAx.XTick = 1:nS;
        if ~isempty(cfg.p1Labels)
            app.gridAx.XTickLabel = cfg.p1Labels;
        else
            app.gridAx.XTickLabel = arrayfun(@num2str, cfg.p1Grid, 'UniformOutput', false);
        end

        % Y-axis: p2 values
        app.gridAx.YTick = 1:nL;
        if ~isempty(cfg.p2Labels)
            app.gridAx.YTickLabel = cfg.p2Labels;
        else
            app.gridAx.YTickLabel = arrayfun(@num2str, cfg.p2Grid, 'UniformOutput', false);
        end

        for si = 1:nS
            for li = 1:nL
                v = grid_score(li, si);
                if isfinite(v)
                    text(app.gridAx, si, li, sprintf('%.1f', v), ...
                        'HorizontalAlignment','center','VerticalAlignment','middle', ...
                        'Color','w','FontSize',9,'FontWeight','bold');
                end
            end
        end

        hold(app.gridAx, 'on');
        plot(app.gridAx, best_si, best_li, 's', ...
            'MarkerSize', 18, 'MarkerEdgeColor', [0.30 1.00 0.50], 'LineWidth', 2.5);
        hold(app.gridAx, 'off');

        p1_str = format_param(cfg, 'p1', best_si);
        p2_str = format_param(cfg, 'p2', best_li);
        title(app.gridAx, sprintf('%s — %s: %.1f%%  |  %s=%s  %s=%s', ...
            cfg.name, app.metricDrop.Value, grid_score(best_li, best_si), ...
            cfg.p1Name, p1_str, cfg.p2Name, p2_str), ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
        xlabel(app.gridAx, cfg.p1Name, 'Color',[0.55 0.55 0.55]);
        ylabel(app.gridAx, cfg.p2Name, 'Color',[0.55 0.55 0.55]);
    end

    function draw_distributions()
        if isempty(app.featureNames) || isempty(app.X); return; end

        X0 = app.X(app.y == 0, :);
        X1 = app.X(app.y == 1, :);

        mu0     = mean(X0, 1, 'omitnan');
        mu1     = mean(X1, 1, 'omitnan');
        pool_sd = sqrt((var(X0,0,1,'omitnan') + var(X1,0,1,'omitnan')) / 2);
        smd     = abs(mu1 - mu0) ./ max(pool_sd, 1e-9);
        [~, idx] = sort(smd, 'descend');
        top_n    = min(10, numel(idx));
        top_idx  = idx(1:top_n);

        cla(app.distAx);
        hold(app.distAx, 'on');

        for ii = 1:top_n
            fi    = top_idx(ii);
            y_pos = top_n - ii + 1;
            v0 = X0(isfinite(X0(:,fi)), fi);
            v1 = X1(isfinite(X1(:,fi)), fi);
            if numel(v0) < 4 || numel(v1) < 4; continue; end
            minibox(app.distAx, quantile(v0, [0.25 0.50 0.75]), y_pos - 0.20, [0.85 0.28 0.28]);
            minibox(app.distAx, quantile(v1, [0.25 0.50 0.75]), y_pos + 0.20, [0.25 0.78 0.44]);
        end

        app.distAx.YTick      = 1:top_n;
        app.distAx.YTickLabel = fliplr( ...
            arrayfun(@(i) app.featureNames{i}, top_idx, 'UniformOutput', false));
        app.distAx.YLim = [0.5, top_n + 0.5];
        hold(app.distAx, 'off');

        title(app.distAx, ...
            'Top features by class separation  (red = corrupted  |  green = clean  |  box = IQR  line = median)', ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
        xlabel(app.distAx, 'Feature value', 'Color',[0.55 0.55 0.55]);
    end

    function draw_confusion(cm)
        cla(app.cmAx);
        clrs = {[0.18 0.52 0.18], [0.62 0.16 0.16]; ...
                [0.62 0.16 0.16], [0.18 0.52 0.18]};
        lbls = {'Corrupted', 'Clean'};
        hold(app.cmAx, 'on');
        for r = 1:2
            for c = 1:2
                patch(app.cmAx, ...
                    [c-1 c c c-1]+0.5, [r-1 r-1 r r]+0.5, ...
                    clrs{r,c}, 'EdgeColor',[0.15 0.15 0.18], 'LineWidth',1.5);
                text(app.cmAx, c, r, num2str(cm(r,c)), ...
                    'HorizontalAlignment','center','VerticalAlignment','middle', ...
                    'FontSize',22,'FontWeight','bold','Color','w');
            end
        end
        hold(app.cmAx, 'off');
        app.cmAx.XTick      = [1 2];  app.cmAx.XTickLabel = lbls;
        app.cmAx.YTick      = [1 2];  app.cmAx.YTickLabel = lbls;
        app.cmAx.XLim       = [0.5 2.5];
        app.cmAx.YLim       = [0.5 2.5];
        xlabel(app.cmAx, 'Predicted', 'Color',[0.55 0.55 0.55]);
        ylabel(app.cmAx, 'Actual',    'Color',[0.55 0.55 0.55]);
        TP = cm(2,2); FN = cm(2,1); TN = cm(1,1); FP = cm(1,2);
        title(app.cmAx, sprintf('LORO-CV  —  TP=%d  TN=%d  FP=%d  FN=%d', TP, TN, FP, FN), ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
    end

    function draw_importance(imp)
        cla(app.impAx);
        cfg = app.model.cfg;

        [sorted_imp, order] = sort(imp, 'ascend');
        n_show     = min(15, sum(isfinite(imp)));
        if n_show == 0; return; end
        sorted_imp = sorted_imp(end-n_show+1:end);
        order      = order(end-n_show+1:end);

        barh(app.impAx, 1:n_show, sorted_imp, ...
            'FaceColor',[0.28 0.52 0.82], 'EdgeColor','none');
        app.impAx.YTick      = 1:n_show;
        app.impAx.YTickLabel = app.featureNames(order);
        app.impAx.YLim       = [0.5, n_show+0.5];

        title(app.impAx, importance_title(cfg.name), ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
        xlabel(app.impAx, 'Importance', 'Color',[0.55 0.55 0.55]);
    end

end  % train_visualise_gui

% =============================================================================
% Static helpers — no access to app
% =============================================================================

function mdl = fit_model(model_name, X_tr, y_tr, feat_names, p1, p2)
switch model_name
    case 'Decision Tree'
        mdl = fitctree(X_tr, y_tr, ...
            'MaxNumSplits',   p1, ...
            'MinLeafSize',    p2, ...
            'PredictorNames', feat_names);
    case 'Random Forest'
        templ = templateTree('MinLeafSize', p2);
        mdl   = fitcensemble(X_tr, y_tr, ...
            'Method',            'Bag', ...
            'NumLearningCycles', p1, ...
            'Learners',          templ, ...
            'PredictorNames',    feat_names);
    case 'RBF SVM'
        mdl = fitcsvm(X_tr, y_tr, ...
            'KernelFunction', 'rbf', ...
            'BoxConstraint',  p1, ...
            'KernelScale',    p2, ...
            'Standardize',    true);
    case 'Linear SVM'
        mu = mean(X_tr, 1, 'omitnan');
        sd = std(X_tr,  0, 1, 'omitnan');
        sd(sd < 1e-9) = 1;
        inner = fitclinear((X_tr - mu) ./ sd, y_tr, ...
            'Lambda',  p1, ...
            'Learner', 'svm');
        mdl = struct('linsvm_type', 'linsvm', 'inner', inner, 'mu', mu, 'sd', sd);
    case 'k-NN'
        dist_map = {'euclidean', 'cosine', 'correlation'};
        mdl = fitcknn(X_tr, y_tr, ...
            'NumNeighbors', p1, ...
            'Distance',     dist_map{p2});
    case 'Neural Net (MLP)'
        % Two hidden layers: p1 and p1/2 neurons. L2 regularisation = p2.
        mdl = fitcnet(X_tr, y_tr, ...
            'LayerSizes',  [p1, max(4, floor(p1/2))], ...
            'Lambda',      p2, ...
            'Standardize', true, ...
            'Activations', 'relu');
    case 'ELM'
        mdl = fit_elm(X_tr, y_tr, p1, p2);
    otherwise
        error('Unknown model: %s', model_name);
end
end

function y_pred = predict_model(mdl, X)
% Unified prediction dispatcher.
% ELM and Linear SVM both return plain structs; MATLAB classifier objects
% are handled by the MATLAB predict() function.
if isstruct(mdl) && isfield(mdl, 'linsvm_type')
    X_std  = (X - mdl.mu) ./ mdl.sd;
    y_pred = predict(mdl.inner, X_std);
elseif isstruct(mdl) && isfield(mdl, 'elm_type')
    X_std = (X - mdl.mu) ./ mdl.sd;
    H     = 1 ./ (1 + exp(-(X_std * mdl.W' + mdl.b')));
    y_pred = double(H * mdl.beta >= 0);
else
    y_pred = predict(mdl, X);
end
end

function mdl = fit_elm(X_tr, y_tr, hidden_size, C)
% Regularised ELM for binary classification.
% Input weights W and biases b are drawn once at random and fixed.
% Output weights beta are solved via ridge regression: beta = (I/C + H'H)^{-1} H' y.
mu = mean(X_tr, 1, 'omitnan');
sd = std(X_tr,  0, 1, 'omitnan');
sd(sd < 1e-9) = 1;
X_tr = (X_tr - mu) ./ sd;

[n, p] = size(X_tr);
W = randn(hidden_size, p) * sqrt(2 / p);   % He-style scaling
b = randn(hidden_size, 1);
H = sigmoid_act(X_tr * W' + b');           % n × hidden_size

y_enc = 2 * double(y_tr(:)) - 1;           % {0,1} → {-1,+1}
beta  = (eye(hidden_size) / C + H' * H) \ (H' * y_enc);

mdl = struct('elm_type', 'elm', 'W', W, 'b', b, 'beta', beta, 'mu', mu, 'sd', sd);
end

function out = sigmoid_act(z)
out = 1 ./ (1 + exp(-z));
end

function d = tree_depth(tree)
if ~(isobject(tree) && isprop(tree, 'Children')) && ...
        ~(isstruct(tree) && isfield(tree, 'Children'))
    d = NaN;
    return;
end
children = tree.Children;
if isempty(children)
    d = 0;
else
    d = branch_depth(1, children);
end
end

function d = branch_depth(node, children)
kids = children(node, :);
kids = kids(kids > 0);
if isempty(kids)
    d = 0;
else
    child_depths = arrayfun(@(k) branch_depth(k, children), kids);
    d = 1 + max(child_depths);
end
end

function imp = get_importance(mdl, model_name, feat_names, X, y)
% Returns a feature importance vector length == numel(feat_names).
% Tree-based models use Gini impurity reduction.
% Linear SVM uses |beta| coefficient magnitudes.
% RBF SVM and k-NN have no closed-form importance — returns Cohen's d as proxy.
n = numel(feat_names);
switch model_name
    case {'Decision Tree', 'Random Forest'}
        imp = predictorImportance(mdl);
    case 'Linear SVM'
        try
            b = mdl.inner.Beta;
            if numel(b) == n
                imp = abs(b(:))';
            else
                imp = nan(1, n);
            end
        catch
            imp = nan(1, n);
        end
    otherwise
        X0 = X(y == 0, :);
        X1 = X(y == 1, :);
        mu0     = mean(X0, 1, 'omitnan');
        mu1     = mean(X1, 1, 'omitnan');
        pool_sd = sqrt((var(X0,0,1,'omitnan') + var(X1,0,1,'omitnan')) / 2);
        imp     = abs(mu1 - mu0) ./ max(pool_sd, 1e-9);
end
end

function ttl = importance_title(model_name)
switch model_name
    case {'Decision Tree', 'Random Forest'}
        ttl = 'Feature Importance  (Gini impurity reduction, full model)';
    case 'Linear SVM'
        ttl = 'Feature Importance  (|β| coefficient magnitude)';
    case 'Neural Net (MLP)'
        ttl = 'Feature Separability  (Cohen''s d — MLP has no closed-form feature importance)';
    otherwise
        ttl = 'Feature Separability  (Cohen''s d — no native importance for this model)';
end
end

function minibox(ax, q, y_pos, col)
h = 0.16;
patch(ax, [q(1) q(3) q(3) q(1)], [y_pos-h y_pos-h y_pos+h y_pos+h], ...
    col, 'FaceAlpha', 0.55, 'EdgeColor', col*0.75);
plot(ax, [q(2) q(2)], [y_pos-h y_pos+h], 'Color','w', 'LineWidth',1.8);
end

function style_axes(ax, ttl, xl, yl, bg)
ax.Color     = bg;
ax.XColor    = [0.42 0.42 0.42];
ax.YColor    = [0.42 0.42 0.42];
ax.GridColor = [0.24 0.24 0.24];
ax.XGrid     = 'on';
ax.YGrid     = 'on';
title(ax,  ttl, 'Color',[0.76 0.76 0.76], 'FontSize',10);
xlabel(ax, xl,  'Color',[0.60 0.60 0.60]);
ylabel(ax, yl,  'Color',[0.60 0.60 0.60]);
end

function lbl = make_metric(parent, col, title_txt, dim_col, fg_col)
g = uigridlayout(parent, [2 1]);
g.Layout.Column   = col;
g.RowHeight       = {18, 28};
g.Padding         = [0 0 0 0];
g.RowSpacing      = 0;
g.BackgroundColor = parent.BackgroundColor;
tl = uilabel(g, 'Text', title_txt, 'FontColor', dim_col, 'FontSize', 9, ...
    'HorizontalAlignment', 'center');
tl.Layout.Row = 1;
lbl = uilabel(g, 'Text', '—', 'FontColor', fg_col, 'FontSize', 14, ...
    'FontWeight', 'bold', 'HorizontalAlignment', 'center');
lbl.Layout.Row = 2;
end

function paths = local_paths()
matlabDir      = fileparts(mfilename('fullpath'));
paths.repo     = fileparts(matlabDir);
paths.subrepo  = matlabDir;
end
