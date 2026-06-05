/*
 * app_config_phase1.h
 *
 * Phase 1 hardware constants for the acquisition firmware. Filter/algorithm
 * macros live elsewhere; this file is shared by main_phase1.c, the AD8233
 * driver, the IMU driver, and the ADS1293 driver.
 */

#ifndef APP_CONFIG_PHASE1_H
#define APP_CONFIG_PHASE1_H

#include <stdint.h>

/* AD8233 LPADC channels.
 * LPADC returns left-aligned 16-bit; shift right by 3 for 12-bit.
 * ecg_mV = (out_raw - refout_raw) * 1800 / 4096. */
#define APP_ADC_VREF_MV        (1800U)
#define APP_ADC_RESULT_SHIFT   (3U)
#define APP_ECG_ADC_CH_OUT     (0U)      /* AD8233 OUT    -> LPADC1 A1_0 */
#define APP_ECG_ADC_CH_REFOUT  (1U)      /* AD8233 REFOUT -> LPADC1 A1_1 */

/* Scheduler tick and ECG poll rate.
 * Nominal 500 Hz. ADS1293 rows are gated by DATA_STATUS at ~200 sps;
 * measure effective Fs from t_us after any format change. */
#define APP_ECG_FS_HZ          (500U)

/* Shared LPSPI1 bus for three MPU-6500 devices and the ADS1293.
 * PCS0=D10, PCS1=D4, PCS2=D0 (IMUs); PCS3=J9[7] (ADS1293).
 * LPSPI_MasterInit is called once on PCS0; cloning the handle for the other
 * devices avoids re-initialising the peripheral (which would reset all CS). */
#define APP_IMU_SPI_SRC_CLOCK_HZ   (24000000U)
#define APP_IMU_SPI_BAUD_HZ        (1000000U)

#define APP_ADS1293_SPI_SRC_CLOCK_HZ  (APP_IMU_SPI_SRC_CLOCK_HZ)
#define APP_ADS1293_SPI_BAUD_HZ       (1000000U)

#endif /* APP_CONFIG_PHASE1_H */
