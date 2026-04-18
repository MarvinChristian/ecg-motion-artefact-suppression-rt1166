# Motion Artefact Suppression — ECG System (Phase 1)

**Author:** Marvin Christian  
**Target:** NXP MIMXRT1166 · AD8233 ECG front-end · 3× MPU-6500 IMU  
**Context:** Pre-hospital (ambulance) ambulatory ECG — thesis project

---

## Overview

This repository contains the Phase 1 firmware, real-time monitor, and offline MATLAB analysis tools for a multi-phase ECG motion artefact suppression (MAS) system. The goal of Phase 1 is to acquire raw, timestamped ECG and 6-axis IMU data from an ambulance environment for use in subsequent phases:

| Phase | Purpose |
|-------|---------|
| **1** | Raw ECG + IMU data acquisition (this repo) |
| **2** | Offline bandpass and notch filter evaluation (MATLAB) |
| **3** | Offline MAS algorithm evaluation using IMU reference signals (MATLAB) |
| **4** | Real-time pipeline on-device (future) |

---

## Hardware

| Component | Detail |
|-----------|--------|
| MCU | NXP MIMXRT1166 (80 MHz LPUART source clock) |
| ECG front-end | Analog Devices AD8233 — differential output via LPADC ch0/ch1 |
| ADC | On-chip LPADC, 12-bit, 1.8 V reference, left-aligned 16-bit results |
| IMU | 3× InvenSense MPU-6500 on shared LPSPI1 (1 MHz, PCS0/1/2) |
| UART | 500000 baud, 8N1 — **must match `board.h` and `ecg_monitor.py`** |

The AD8233 REFOUT (buffered copy of a tuneable REFIN divider) is sampled on ch1 and subtracted from ch0 at each tick, removing the common-mode DC bias without the high-pass transient of AC coupling.

Raw IMU register values are used directly — the Kalman filter in `imu_manager.c` (K ≈ 0.14, f₃dB ≈ 11 Hz) is bypassed via `IMU_ReadAllRaw()` to preserve the full ambulance vibration spectrum (≈ 1–30 Hz).

---

## Recording Modes

Selected at compile time in `source/main_phase1.c`:

### `PHASE1_ECG_ONLY` — 500 Hz
Streams `t_us` + `ecg_corr` only. PRINTF payload ≈ 18 bytes (0.36 ms at 500 kbaud), which fits within the 2 ms tick period. True 500 Hz output. Used for Phase 2 filter evaluation.

### `PHASE1_ECG_IMU` — 250 Hz (effective)
Streams `t_us` + `ecg_corr` + 3× (`ax, ay, az, gx, gy, gz`). PRINTF payload ≈ 144 bytes (2.88 ms), exceeding the 2 ms tick period. The catch-up guard advances `next_tick` by one extra step per iteration, giving an effective rate of 500/(1+1) = 250 Hz. Confirmed via `t_us` timestamps. Used for Phase 3 MAS evaluation.

Both modes satisfy the Nyquist criterion for a 40 Hz ECG passband (250 Hz → 6.25× margin; 125 Hz → 3.1× margin).

---

## Repository Structure

```
source/
  main_phase1.c          — firmware entry point, acquisition loop
  app_config_phase1.h    — hardware constants (ADC, SPI, baud)
  drivers/
    ecg_adc.c/h          — LPADC init, triggered sampling
    imu_manager.c/h      — MPU-6500 init, IMU_ReadAllRaw()
    mpu6500_spi.c/h      — SPI register read/write
  dsp/
    kalman1d.c/h         — scalar Kalman filter (bypassed in Phase 1)
  timebase/              — SysTick-based tick timer

Python Files/
  ecg_monitor.py         — real-time serial monitor and recorder (PyQt + pyqtgraph)

MATLAB Files/
  phase2_analyzer.m      — unified Phase 2 GUI: BPF + notch evaluation
  phase2_bpf_eval.m      — bandpass filter batch evaluation
  phase2_notch_eval.m    — notch filter batch evaluation
  phase2_coefficients.m  — filter coefficient definitions (B1–B6, N1–N9)
  apply_biquad.m         — biquad cascade implementation
  apply_notch.m          — notch filter application
  ecg_metrics.m          — SNR, RMSE, and distortion metrics
  phase1_import.m        — CSV loader for Phase 1 recordings
  phase1_viewer.m        — raw data viewer

CMSIS/                   — CMSIS-DSP library (NXP SDK)
Recordings/              — recorded CSV data (gitignored)
```

---

## Setup

### Firmware

1. Open the project in MCUXpresso IDE.
2. In `board/board.h`, set:
   ```c
   #define BOARD_DEBUG_UART_BAUDRATE   500000U
   ```
3. Select recording mode in `source/main_phase1.c` (`#define PHASE1_ECG_ONLY` or `PHASE1_ECG_IMU`).
4. Build and flash via LinkServer.

### Python Monitor (`ecg_monitor.py`)

Requirements: `numpy`, `pyqtgraph`, `pyserial`, `PyQt5`

```bash
pip install numpy pyqtgraph pyserial PyQt5
python "Python Files/ecg_monitor.py"
```

Set `PORT` and `BAUD` at the top of the script to match your system (default: `COM13`, `500000`). Recordings are saved as CSV files in `Python Files/Recordings/`.

### MATLAB Analysis

Open `MATLAB Files/phase2_analyzer.m` and run. All filter definitions are embedded — no external coefficient file is needed. Load a Phase 1 CSV recording via the GUI, select a BPF (B1–B6) and/or notch filter (N1–N9), and press **Evaluate**.

---

## Key Configuration Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `APP_ADC_VREF_MV` | 1800 | ADC reference voltage (mV) |
| `APP_ADC_RESULT_SHIFT` | 3 | Left-aligned 16-bit → 12-bit right-shift |
| `APP_ECG_FS_HZ` | 500 | ADC tick rate (Hz) |
| `APP_IMU_SPI_SRC_CLOCK_HZ` | 60 000 000 | LPSPI1 source clock (Hz) |
| `APP_IMU_SPI_BAUD_HZ` | 1 000 000 | SPI baud rate (Hz) |

---

## Notes

- The three IMUs share MOSI/MISO/SCLK on LPSPI1; chip-select is handled via hardware PCS lines (PCS0=D10, PCS1=D4, PCS2=D0). `LPSPI_MasterInit()` is called once only — calling it again resets the peripheral and breaks all three devices.
- 500000 baud is exact at 80 MHz (divisor = 160, zero fractional error). Higher rates such as 921600 introduce >2% baud error and are unreliable on this hardware.
- `Recordings/` and `*.csv` are gitignored. Raw experiment data is not versioned here.
