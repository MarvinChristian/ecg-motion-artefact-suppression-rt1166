function launch_label_gui()
% Launcher for the MAS labelling/training GUI. Adds both support-tool MATLAB
% folders to the path and opens the workflow front end.
d = fileparts(mfilename('fullpath'));                                  % .../Evaluation_Files_By_Phase/MATLAB
finalDir = fullfile(fileparts(fileparts(d)), 'Final_Pipeline_Files', 'MATLAB');
addpath(d, finalDir);
fprintf('Support tool paths added:\n  %s\n  %s\nOpening ads1293_mas_ml_gui...\n', d, finalDir);
ads1293_mas_ml_gui;
end
