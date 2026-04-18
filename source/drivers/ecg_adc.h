/*
 * ecg_adc.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       Dual-channel LPADC driver — AD8233 ECG output and REFOUT
 * DATE:        19/04/2026
 *
 * SUMMARY:
 *      Public interface for the LPADC acquisition driver.
 *      One software trigger fires CMD1 (ch0, ECG OUT) chained to CMD2
 *      (ch1, AD8233 REFOUT). Both 12-bit results are returned per call.
 *      DC correction is performed in the caller: ecg_corr = ecg_raw - ref_raw.
 */

#ifndef ECG_ADC_H
#define ECG_ADC_H

#include <stdint.h>
#include <stdbool.h>

/*
 * Initialise the LPADC.
 * CMD1 → ch0 (ECG OUT), chained to CMD2 → ch1 (REFOUT).
 * One software trigger fires both conversions back-to-back.
 */
void ECGADC_Init(void);

/*
 * Fire one paired conversion and return both 12-bit results.
 *
 * ecg12   – raw 12-bit ADC value for ECG OUT  (ch0)
 * ref12   – raw 12-bit ADC value for REFOUT   (ch1)
 *
 * Returns true on success, false on timeout or null pointer.
 */
bool ECGADC_ReadBoth(uint16_t *ecg12, uint16_t *ref12);

#endif /* ECG_ADC_H */
