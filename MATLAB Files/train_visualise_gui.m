function train_visualise_gui(feature_mat_path)
% TRAIN_VISUALISE_GUI  Hyperparameter grid search + training visualisation.
%
% Loads revised_labels.mat (or epoch_features.mat), runs a grid search over
% MaxNumSplits × MinLeafSize using stratified k-fold CV, trains the final
% CART tree with the best parameters, and visualises all results.
%
% Optimisation criterion: balanced accuracy = (sensitivity + specificity) / 2.
% This is appropriate for the ~75/25 clean/corrupted class imbalance — raw
% accuracy is biased toward the majority class.
%
% Usage
%   train_visualise_gui()
%   train_visualise_gui('MATLAB Files/outputs/.../revised_labels.mat')

if nargin < 1; feature_mat_path = ''; end

% ── Colour palette ────────────────────────────────────────────────────────────
C_BG    = [0.10 0.11 0.13];
C_PANEL = [0.12 0.12 0.15];
C_INPUT = [0.13 0.13 0.16];
C_FG    = [0.85 0.85 0.85];
C_DIM   = [0.55 0.60 0.65];
C_GO    = [0.20 0.55 0.30];
C_BLUE  = [0.25 0.45 0.65];
C_AX    = [0.08 0.09 0.11];

% ── Grid search parameter space ───────────────────────────────────────────────
% MaxNumSplits = 2^depth - 1; values here correspond to depth 3–7.
% MinLeafSize controls regularisation (larger = simpler, less overfit).
SPLITS_GRID = [7, 15, 31, 63, 127];
LEAF_GRID   = [2, 5, 10, 20];
K_FOLDS     = 5;

% ── State ─────────────────────────────────────────────────────────────────────
app                 = struct();
app.X               = [];
app.y               = [];
app.featureNames    = {};
app.epochInfo       = table();
app.fpath           = '';
app.loaded          = false;
app.trained         = false;
app.splitsGrid      = SPLITS_GRID;
app.leafGrid        = LEAF_GRID;
app.kFolds          = K_FOLDS;
app.model           = struct();
app.paths           = local_paths();

% ── Figure ────────────────────────────────────────────────────────────────────
fig = uifigure( ...
    'Name',     'Epoch Classifier — Hyperparameter Search + Training', ...
    'Position', [40 40 1300 800], ...
    'Color',    C_BG);

outer = uigridlayout(fig, [4 1]);
outer.RowHeight      = {46, '1x', '1x', 54};
outer.Padding        = [10 8 10 8];
outer.RowSpacing     = 8;
outer.BackgroundColor = C_BG;

% ── Row 1: control bar ────────────────────────────────────────────────────────
ctrl = uigridlayout(outer, [1 5]);
ctrl.Layout.Row      = 1;
ctrl.ColumnWidth     = {120, '1x', 90, 100, 260};
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

app.kFoldDrop = uidropdown(ctrl, ...
    'Items', {'3-fold CV','5-fold CV','10-fold CV'}, 'Value', '5-fold CV', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.kFoldDrop.Layout.Column = 3;

app.metricDrop = uidropdown(ctrl, ...
    'Items', {'Balanced Acc','Accuracy','F1 Score'}, 'Value', 'Balanced Acc', ...
    'BackgroundColor', C_INPUT, 'FontColor', C_FG);
app.metricDrop.Layout.Column = 4;

app.trainBtn = uibutton(ctrl, ...
    'Text',            'Run Grid Search + Train', ...
    'BackgroundColor', C_GO, 'FontColor', 'w', ...
    'FontWeight',      'bold', 'Enable', 'off', ...
    'ButtonPushedFcn', @on_train);
app.trainBtn.Layout.Column = 5;

% ── Row 2: top axes (grid heatmap | feature distributions) ────────────────────
top = uigridlayout(outer, [1 2]);
top.Layout.Row       = 2;
top.ColumnWidth      = {'1x', '1x'};
top.Padding          = [0 0 0 0];
top.ColumnSpacing    = 10;
top.BackgroundColor  = C_BG;

app.gridAx = uiaxes(top);
app.gridAx.Layout.Column = 1;
style_axes(app.gridAx, 'Hyperparameter Grid  (waiting for search...)', ...
    'MaxNumSplits', 'MinLeafSize', C_AX);

app.distAx = uiaxes(top);
app.distAx.Layout.Column = 2;
style_axes(app.distAx, 'Feature Separation by Class  (top features, IQR boxes)', ...
    'Feature value', '', C_AX);

% ── Row 3: bottom axes (confusion matrix | feature importance) ────────────────
bot = uigridlayout(outer, [1 2]);
bot.Layout.Row      = 3;
bot.ColumnWidth     = {'1x', '1x'};
bot.Padding         = [0 0 0 0];
bot.ColumnSpacing   = 10;
bot.BackgroundColor = C_BG;

app.cmAx = uiaxes(bot);
app.cmAx.Layout.Column = 1;
style_axes(app.cmAx, 'CV Confusion Matrix  (waiting for training...)', ...
    '', '', C_AX);

app.impAx = uiaxes(bot);
app.impAx.Layout.Column = 2;
style_axes(app.impAx, 'Feature Importance  (waiting for training...)', ...
    'Gini impurity reduction', '', C_AX);

% ── Row 4: metrics bar ────────────────────────────────────────────────────────
mbar = uigridlayout(outer, [1 7]);
mbar.Layout.Row      = 4;
mbar.ColumnWidth     = {'1x','1x','1x','1x','1x','1x','2x'};
mbar.Padding         = [0 4 0 4];
mbar.ColumnSpacing   = 10;
mbar.BackgroundColor = C_BG;

app.mAcc  = make_metric(mbar, 1, 'CV Accuracy',    C_DIM, C_FG);
app.mSens = make_metric(mbar, 2, 'Sensitivity',    C_DIM, C_FG);
app.mSpec = make_metric(mbar, 3, 'Specificity',    C_DIM, C_FG);
app.mBal  = make_metric(mbar, 4, 'Balanced Acc',   C_DIM, C_FG);
app.mF1   = make_metric(mbar, 5, 'F1 Score',       C_DIM, C_FG);
app.mBase = make_metric(mbar, 6, 'Baseline (thr)', C_DIM, [0.88 0.70 0.30]);

app.mBestLabel = uilabel(mbar, ...
    'Text', 'Best params: —', ...
    'FontColor', C_DIM, 'FontSize', 10, 'HorizontalAlignment', 'left');
app.mBestLabel.Layout.Column = 7;

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
            uialert(fig, sprintf('Only %d binary-labelled epochs. Need at least 20.', sum(valid)), ...
                'Too few labels'); return;
        end

        app.X            = d.X(valid, :);
        app.y            = y_raw(valid);
        app.featureNames = d.featureNames;
        app.epochInfo    = d.epochInfo(valid, :);
        app.fpath        = fpath;
        app.loaded       = true;

        [~, fn, ext] = fileparts(fpath);
        nC = sum(app.y == 1); nX = sum(app.y == 0);
        app.fileLabel.Text = sprintf( ...
            '%s%s  —  %d epochs  |  clean: %d (%.0f%%)  corrupted: %d (%.0f%%)', ...
            fn, ext, numel(app.y), nC, 100*nC/numel(app.y), nX, 100*nX/numel(app.y));

        app.trainBtn.Enable = 'on';
        draw_distributions();
        drawnow;
    end

    function on_train(~, ~)
        if ~app.loaded; return; end
        app.trainBtn.Enable = 'off';
        app.loadBtn.Enable  = 'off';
        cleanup = onCleanup(@() restore_btns()); %#ok<NASGU>
        try
            app.kFolds = str2double(strtok(app.kFoldDrop.Value, '-'));
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
        nS = numel(app.splitsGrid);
        nL = numel(app.leafGrid);
        grid_score = nan(nL, nS);  % rows = minLeaf, cols = maxSplits

        % Single partition reused across all combinations for fair comparison.
        cv = cvpartition(app.y, 'KFold', app.kFolds, 'Stratify', true);
        total = nS * nL;

        for si = 1:nS
            for li = 1:nL
                ms = app.splitsGrid(si);
                ml = app.leafGrid(li);

                cv_pred = zeros(size(app.y));
                for fold = 1:app.kFolds
                    tr = training(cv, fold);
                    te = test(cv,     fold);
                    t  = fitctree(app.X(tr,:), app.y(tr), ...
                        'MaxNumSplits',   ms, ...
                        'MinLeafSize',    ml, ...
                        'PredictorNames', app.featureNames, ...
                        'ResponseName',   'EpochLabel');
                    cv_pred(te) = predict(t, app.X(te,:));
                end

                cm_g = confusionmat(app.y, cv_pred);
                TP = cm_g(2,2); FN = cm_g(2,1);
                TN = cm_g(1,1); FP = cm_g(1,2);
                sens_g = TP / max(1, TP+FN);
                spec_g = TN / max(1, TN+FP);
                acc_g  = (TP+TN) / sum(cm_g(:));
                prec_g = TP / max(1, TP+FP);
                f1_g   = 2*prec_g*sens_g / max(1e-9, prec_g+sens_g);

                switch app.metricDrop.Value
                    case 'Accuracy';     grid_score(li, si) = acc_g  * 100;
                    case 'F1 Score';     grid_score(li, si) = f1_g   * 100;
                    otherwise;           grid_score(li, si) = 50*(sens_g + spec_g);
                end

                done = (si-1)*nL + li;
                best_so_far = max(grid_score(:), [], 'omitnan');
                title(app.gridAx, ...
                    sprintf('Grid search: %d / %d  —  best so far: %.1f%%', ...
                    done, total, best_so_far), ...
                    'Color',[0.78 0.78 0.78], 'FontSize',10);
                drawnow;
            end
        end

        app.model.grid_score  = grid_score;
        app.model.splitsGrid  = app.splitsGrid;
        app.model.leafGrid    = app.leafGrid;
        app.model.metricName  = app.metricDrop.Value;

        [best_val, best_idx]     = max(grid_score(:));
        [best_li,  best_si]      = ind2sub(size(grid_score), best_idx);
        app.model.best_maxSplits = app.splitsGrid(best_si);
        app.model.best_minLeaf   = app.leafGrid(best_li);
        app.model.best_score     = best_val;

        draw_grid(grid_score, best_si, best_li);
    end

    function train_best_model()
        ms = app.model.best_maxSplits;
        ml = app.model.best_minLeaf;

        % Final tree on all labelled data.
        tree = fitctree(app.X, app.y, ...
            'MaxNumSplits',   ms, ...
            'MinLeafSize',    ml, ...
            'PredictorNames', app.featureNames, ...
            'ResponseName',   'EpochLabel');

        % Fresh CV partition for reported metrics (avoids optimism from grid search CV).
        cv      = cvpartition(app.y, 'KFold', app.kFolds, 'Stratify', true);
        cv_pred = zeros(size(app.y));
        for fold = 1:app.kFolds
            tr = training(cv, fold);
            te = test(cv,     fold);
            t  = fitctree(app.X(tr,:), app.y(tr), ...
                'MaxNumSplits',   ms, ...
                'MinLeafSize',    ml, ...
                'PredictorNames', app.featureNames, ...
                'ResponseName',   'EpochLabel');
            cv_pred(te) = predict(t, app.X(te,:));
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

        % Hard motion-threshold baseline for comparison.
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

        imp = predictorImportance(tree);

        app.model.tree  = tree;
        app.model.cm    = cm;
        app.model.acc   = acc;
        app.model.sens  = sens;
        app.model.spec  = spec;
        app.model.bal   = bal;
        app.model.f1    = f1;
        app.model.imp   = imp;
        app.trained     = true;

        draw_confusion(cm);
        draw_importance(imp);

        app.mAcc.Text  = sprintf('%.1f%%', acc);
        app.mSens.Text = sprintf('%.1f%%', sens);
        app.mSpec.Text = sprintf('%.1f%%', spec);
        app.mBal.Text  = sprintf('%.1f%%', bal);
        app.mF1.Text   = sprintf('%.1f%%', f1);
        app.mBestLabel.Text = sprintf( ...
            'Best params:  MaxSplits = %d  MinLeaf = %d  (%s = %.1f%%)', ...
            ms, ml, app.model.metricName, app.model.best_score);

        save_outputs();
    end

    function save_outputs()
        outDir = fullfile(app.paths.subrepo, 'outputs', ...
            char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
        if ~exist(outDir, 'dir'); mkdir(outDir); end
        model = app.model; %#ok<NASGU>
        save(fullfile(outDir, 'epoch_classifier.mat'), 'model');

        % Print tree rules to Command Window for thesis documentation.
        view(app.model.tree, 'Mode', 'text');

        [~, fn, ext] = fileparts(app.fpath);
        app.fileLabel.Text = sprintf('%s%s  →  Saved: %s', fn, ext, outDir);
        fprintf('\nModel saved to:\n  %s\n', outDir);
        fprintf('Run export_tree_to_c(model) to generate firmware C arrays.\n');
    end

% =============================================================================
% Drawing
% =============================================================================

    function draw_grid(grid_score, best_si, best_li)
        cla(app.gridAx);

        imagesc(app.gridAx, app.splitsGrid, 1:numel(app.leafGrid), grid_score);
        colormap(app.gridAx, parula);
        cb            = colorbar(app.gridAx);
        cb.Color      = [0.62 0.68 0.74];
        cb.Label.String = sprintf('%s (%%)', app.metricDrop.Value);
        cb.Label.Color  = [0.62 0.68 0.74];

        app.gridAx.XTick      = app.splitsGrid;
        app.gridAx.YTick      = 1:numel(app.leafGrid);
        app.gridAx.YTickLabel = arrayfun(@num2str, app.leafGrid, 'UniformOutput', false);

        for si = 1:numel(app.splitsGrid)
            for li = 1:numel(app.leafGrid)
                v = grid_score(li, si);
                if isfinite(v)
                    text(app.gridAx, app.splitsGrid(si), li, sprintf('%.1f', v), ...
                        'HorizontalAlignment','center','VerticalAlignment','middle', ...
                        'Color','w','FontSize',9,'FontWeight','bold');
                end
            end
        end

        hold(app.gridAx, 'on');
        plot(app.gridAx, app.splitsGrid(best_si), best_li, 's', ...
            'MarkerSize', 18, 'MarkerEdgeColor', [0.30 1.00 0.50], 'LineWidth', 2.5);
        hold(app.gridAx, 'off');

        best_val = grid_score(best_li, best_si);
        title(app.gridAx, sprintf('%s grid — best %.1f%% at MaxSplits=%d  MinLeaf=%d', ...
            app.metricDrop.Value, best_val, app.splitsGrid(best_si), app.leafGrid(best_li)), ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
        xlabel(app.gridAx, 'MaxNumSplits', 'Color',[0.55 0.55 0.55]);
        ylabel(app.gridAx, 'MinLeafSize',  'Color',[0.55 0.55 0.55]);
    end

    function draw_distributions()
        if isempty(app.featureNames) || isempty(app.X); return; end

        X0 = app.X(app.y == 0, :);
        X1 = app.X(app.y == 1, :);

        % Rank features by standardised mean difference (Cohen's d).
        mu0  = mean(X0, 1, 'omitnan');
        mu1  = mean(X1, 1, 'omitnan');
        pool_sd = sqrt((var(X0,0,1,'omitnan') + var(X1,0,1,'omitnan')) / 2);
        smd  = abs(mu1 - mu0) ./ max(pool_sd, 1e-9);
        [~, idx] = sort(smd, 'descend');
        top_n    = min(10, numel(idx));
        top_idx  = idx(1:top_n);

        cla(app.distAx);
        hold(app.distAx, 'on');

        for ii = 1:top_n
            fi   = top_idx(ii);
            y_pos = top_n - ii + 1;

            v0 = X0(isfinite(X0(:,fi)), fi);
            v1 = X1(isfinite(X1(:,fi)), fi);
            if numel(v0) < 4 || numel(v1) < 4; continue; end

            q0 = quantile(v0, [0.25 0.50 0.75]);
            q1 = quantile(v1, [0.25 0.50 0.75]);

            minibox(app.distAx, q0, y_pos - 0.20, [0.85 0.28 0.28]);
            minibox(app.distAx, q1, y_pos + 0.20, [0.25 0.78 0.44]);
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

        % Rows = actual (0=corrupted, 1=clean), cols = predicted.
        % cm(1,1)=TN  cm(1,2)=FP  cm(2,1)=FN  cm(2,2)=TP
        clrs = {[0.18 0.52 0.18], [0.62 0.16 0.16]; ...
                [0.62 0.16 0.16], [0.18 0.52 0.18]};
        lbls = {'Corrupted', 'Clean'};

        hold(app.cmAx, 'on');
        for r = 1:2
            for c = 1:2
                patch(app.cmAx, ...
                    [c-1 c c c-1] + 0.5, [r-1 r-1 r r] + 0.5, ...
                    clrs{r,c}, 'EdgeColor', [0.15 0.15 0.18], 'LineWidth', 1.5);
                text(app.cmAx, c, r, num2str(cm(r,c)), ...
                    'HorizontalAlignment','center','VerticalAlignment','middle', ...
                    'FontSize', 22, 'FontWeight','bold', 'Color','w');
            end
        end
        hold(app.cmAx, 'off');

        app.cmAx.XTick      = [1 2];
        app.cmAx.XTickLabel = lbls;
        app.cmAx.YTick      = [1 2];
        app.cmAx.YTickLabel = lbls;
        app.cmAx.XLim       = [0.5 2.5];
        app.cmAx.YLim       = [0.5 2.5];
        xlabel(app.cmAx, 'Predicted',  'Color',[0.55 0.55 0.55]);
        ylabel(app.cmAx, 'Actual',     'Color',[0.55 0.55 0.55]);

        TP = cm(2,2); FN = cm(2,1); TN = cm(1,1); FP = cm(1,2);
        title(app.cmAx, sprintf('%d-fold CV  —  TP=%d  TN=%d  FP=%d  FN=%d', ...
            app.kFolds, TP, TN, FP, FN), ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
    end

    function draw_importance(imp)
        cla(app.impAx);

        [sorted_imp, order] = sort(imp, 'ascend');
        n_show      = min(15, numel(order));
        sorted_imp  = sorted_imp(end - n_show + 1 : end);
        order       = order(end - n_show + 1 : end);

        barh(app.impAx, 1:n_show, sorted_imp, ...
            'FaceColor', [0.28 0.52 0.82], 'EdgeColor', 'none');

        app.impAx.YTick      = 1:n_show;
        app.impAx.YTickLabel = app.featureNames(order);
        app.impAx.YLim       = [0.5, n_show + 0.5];

        title(app.impAx, 'Feature Importance  (Gini impurity reduction, full tree)', ...
            'Color',[0.78 0.78 0.78], 'FontSize',10);
        xlabel(app.impAx, 'Importance', 'Color',[0.55 0.55 0.55]);
    end

end  % train_visualise_gui

% =============================================================================
% Static helpers (outside main — no access to app)
% =============================================================================

function minibox(ax, q, y_pos, col)
% Horizontal IQR box: q = [q25, q50, q75], drawn at vertical y_pos.
h = 0.16;
patch(ax, [q(1) q(3) q(3) q(1)], [y_pos-h y_pos-h y_pos+h y_pos+h], ...
    col, 'FaceAlpha', 0.55, 'EdgeColor', col * 0.75);
plot(ax, [q(2) q(2)], [y_pos-h y_pos+h], 'Color', 'w', 'LineWidth', 1.8);
end

function style_axes(ax, ttl, xl, yl, bg)
ax.Color     = bg;
ax.XColor    = [0.42 0.42 0.42];
ax.YColor    = [0.42 0.42 0.42];
ax.GridColor = [0.24 0.24 0.24];
ax.XGrid     = 'on';
ax.YGrid     = 'on';
title(ax,  ttl, 'Color', [0.76 0.76 0.76], 'FontSize', 10);
xlabel(ax, xl,  'Color', [0.60 0.60 0.60]);
ylabel(ax, yl,  'Color', [0.60 0.60 0.60]);
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
