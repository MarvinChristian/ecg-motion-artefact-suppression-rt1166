# Motion Artefact Suppression ECG System

Embedded ECG and motion-sensing prototype for suppressing motion artefacts in
real-time ECG monitoring.

This repository contains the publishable project snapshot:

- NXP MIMXRT1166 firmware and MCUXpresso project files;
- host-side support tools used to inspect recordings, label epochs, train the
  compact classifiers, and monitor the deployed Phase 4 stream;
- a curated R01-R10 ADS1293/IMU recording subset used by the included tools.

The thesis report, figure-generation workspace, raw results workspace, and
private MATLAB/Python scratch files are intentionally not part of this
repository.

## System Overview

The prototype combines ADS1293 ECG acquisition with three MPU-6500 inertial
measurement units. The firmware streams timestamped ECG, IMU, signal-quality,
heart-rate, and classifier fields over UART. The current Phase 4 path uses a
two-stage embedded classifier:

1. a usability gate marks clean versus corrupted epochs;
2. a candidate selector chooses between the baseline ECG candidate and the
   motion-suppressed candidate when the epoch is usable.

The model headers committed under `source/` are the firmware-ready exported
versions used by the embedded classifier build.

## Repository Layout

```text
source/
  main_phase1.c                  Acquisition and Phase 4 stream entry point
  app_config_phase1.h            Board, UART, and stream configuration
  phase4_realtime.h              Real-time ECG/MAS feature and decision path
  phase4_m4_classifier.c         Cortex-M4 classifier worker
  mas_usability_classifier.h     Exported usability classifier
  mas_selection_classifier.h     Exported candidate-selection classifier
  drivers/                       ADS1293, ECG ADC, IMU, and board drivers
  timebase/                      Shared timestamp support

board/, CMSIS/, component/, device/, drivers/, startup/, utilities/, xip/
  NXP SDK and MCUXpresso support files required by the project.

Debug_CM4/
  Cortex-M4 worker makefile and linker script. Generated build outputs are
  ignored.

scripts/
  build_cm4_classifier.ps1       Helper for the CM4 classifier build
  flash_phase4_dual.ps1          Helper for flashing the dual-core Phase 4 build

Support_Tools/
  Final_Pipeline_Files/          Minimal final MATLAB/Python pipeline snapshot
  Evaluation_Files_By_Phase/     Evaluation and diagnostic tools by project phase
  Recordings/R01_R10_ADS1293_IMU_TS/
                                  Curated ADS1293/IMU recording subset
```

## Firmware Quick Start

Open the repository root as an MCUXpresso project for the MIMXRT1166 target.
The main CM7 firmware lives under `source/`; the CM4 classifier worker build is
kept under `Debug_CM4/`.

If the MCUXpresso command-line tools are available on the machine, the helper
scripts can be run from the repository root:

```powershell
scripts/build_cm4_classifier.ps1
scripts/flash_phase4_dual.ps1
```

Hardware/configuration assumptions:

- target MCU: NXP MIMXRT1166;
- ECG front-end: ADS1293, two ECG channels;
- motion reference: three MPU-6500 IMUs;
- host UART rate: 500000 baud.

## Support Tools

`Support_Tools/` contains the curated MATLAB and Python files that support the
published firmware snapshot. Start with
`Support_Tools/README.md` for the full layout.

Typical MATLAB setup from the repository root:

```matlab
addpath('Support_Tools/Final_Pipeline_Files/MATLAB');
addpath('Support_Tools/Evaluation_Files_By_Phase/MATLAB');
```

The final pipeline can extract and label MAS epochs, train/export the two-stage
classifier headers, and compare the candidate model set. The Python monitor in
`Support_Tools/Final_Pipeline_Files/Python/ecg_phase4_monitor_gui.py` reads the
deployed Phase 4 UART stream.

NOTE: If the ECG trace of CH1 or CH2 in the Python monitor looks clipped or 
unclear, simply reset the board. 

## Validation Boundary

This is a single-subject proof-of-concept and embedded feasibility repository.
It is not a medical device, not a clinical diagnostic tool, and does not claim
population-level generalisation.
