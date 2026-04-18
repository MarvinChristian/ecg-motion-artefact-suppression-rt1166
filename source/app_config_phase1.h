/*
 * app_config_phase1.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       Phase 1 master configuration — minimal acquisition only
 * DATE:        10/04/2026
 *
 * SUMMARY:
 *      Stripped-down configuration header for Phase 1 firmware.
 *      Contains only the hardware constants required for raw ECG and IMU
 *      acquisition. All filter algorithm selection macros (APP_NOTCH_CONFIG,
 *      APP_BPF_CONFIG, APP_MAS_CONFIG) and their compile-time validation
 *      blocks are deliberately omitted — those belong to app_config.h which
 *      is used by the Phase 4 real-time pipeline (main.c).
 *
 *      Phase 1 firmware files that include this header:
 *        main_phase1.c
 *        drivers/ecg_adc.c      (uses APP_ECG_ADC_CH_OUT/REF, APP_ADC_RESULT_SHIFT)
 *        drivers/imu_manager.c  (uses APP_IMU_SPI_SRC_CLOCK_HZ, APP_IMU_SPI_BAUD_HZ)
 */

#ifndef APP_CONFIG_PHASE1_H
#define APP_CONFIG_PHASE1_H

#include <stdint.h>

/* ═══════════════════════════════════════════════════════════════════════════
   ADC HARDWARE (LPADC — AD8233 ECG front-end)
   ═══════════════════════════════════════════════════════════════════════════
   The LPADC on the RT1166 produces left-aligned 16-bit results by default.
   APP_ADC_RESULT_SHIFT = 3 right-shifts to recover the 12-bit value in the
   most significant 12 bits of the 16-bit result register (NXP RT1160 RM §42).

   APP_ADC_VREF_MV = 1800 mV — the on-board 1.8 V ADC reference.
   Conversion: ecg_mV = (ecg_raw - ref_raw) * (1800 / 4096).

   Channel mapping:
     ch0 (APP_ECG_ADC_CH_OUT) — AD8233 OUTPUT pin
     ch1 (APP_ECG_ADC_CH_REF) — AD8233 REFOUT pin (buffered copy of REFIN).
                                REFIN is driven by a 5 kΩ pot + 2.2 kΩ divider
                                from 3.3 V for a tuneable baseline, so REFOUT
                                is not fixed at VS/2 — its value depends on the
                                pot setting and is removed by the differential
                                subtraction below.
   The differential subtraction ecg_raw - ref_raw removes the common-mode
   DC bias regardless of the exact REFOUT voltage, equivalent to AC coupling
   without the high-pass transient of a capacitive network (AD8233 datasheet
   §THEORY OF OPERATION).
   ═══════════════════════════════════════════════════════════════════════════ */

#define APP_ADC_VREF_MV        (1800U)   /* on-board ADC reference (mV)     */
#define APP_ADC_RESULT_SHIFT   (3U)      /* left-aligned 16-bit → 12-bit    */
#define APP_ECG_ADC_CH_OUT     (0U)      /* AD8233 OUTPUT  → LPADC ch0      */
#define APP_ECG_ADC_CH_REF     (1U)      /* AD8233 REFOUT  → LPADC ch1      */

/* ═══════════════════════════════════════════════════════════════════════════
   ECG SAMPLING RATE
   ═══════════════════════════════════════════════════════════════════════════
   500 Hz is the nominal ADC tick rate. In Phase 1 ECG_IMU mode, the PRINTF
   call (~2.88 ms at 500 kbaud) exceeds the 2 ms tick period and causes the
   catch-up guard to fire every iteration. The effective output rate is then
   500/(1+1) = 250 Hz, confirmed via the t_us timestamps in the CSV.
   In Phase 1 ECG_ONLY mode, the PRINTF (0.36 ms) fits within 2 ms and the
   true output rate is 500 Hz.

   Reference: Proakis & Manolakis, DSP 4th ed. §4.1 — Nyquist criterion.
   ECG_ONLY mode: Fs = 500 Hz, Nyquist = 250 Hz, 250/40 = 6.25× margin. ✓
   ECG_IMU  mode: Fs = 250 Hz, Nyquist = 125 Hz, 125/40 ≈ 3.1× margin.  ✓
   ═══════════════════════════════════════════════════════════════════════════ */

#define APP_ECG_FS_HZ          (500U)    /* ADC tick rate (Hz)               */

/* ═══════════════════════════════════════════════════════════════════════════
   MPU-6500 SPI (LPSPI1) — 3 × IMU on shared bus
   ═══════════════════════════════════════════════════════════════════════════
   All three IMUs share MOSI/MISO/SCLK on LPSPI1. Each is selected by a
   separate hardware PCS line (PCS0=D10, PCS1=D4, PCS2=D0) configured in
   pin_mux.c. LPSPI_MasterInit() is called only once (on IMU0/PCS0); the
   device handle is cloned for IMU1 and IMU2 with only the PCS field changed.
   Calling LPSPI_MasterInit() a second time resets the peripheral and breaks
   all three devices simultaneously (imu_manager.c §IMU_InitAll).

   SPI baud rate: 1 MHz. Three 14-byte reads (ACCEL+TEMP+GYRO per device)
   take approximately 3 × 120 µs = 360 µs total — within the effective
   ~4 ms iteration period of Phase 1 ECG_IMU mode.
   ═══════════════════════════════════════════════════════════════════════════ */

#define APP_IMU_SPI_SRC_CLOCK_HZ   (60000000U)   /* LPSPI1 source clock (Hz) */
#define APP_IMU_SPI_BAUD_HZ        (1000000U)    /* SPI baud rate: 1 MHz     */

#endif /* APP_CONFIG_PHASE1_H */
