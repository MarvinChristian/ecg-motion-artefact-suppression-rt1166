/*
 * ecg_adc.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       LPADC driver - AD8233 OUT and REFOUT taps
 * DATE:        19/04/2026
 *
 * SUMMARY:
 *      Public interface for the LPADC acquisition driver.
 *      One software trigger samples OUT and REFOUT back-to-back. Both values
 *      are raw 12-bit ADC counts.
 *      DC correction is performed in the caller:
 *
 *          ecg_corr = out_raw - refout_raw
 */

#ifndef ECG_ADC_H
#define ECG_ADC_H

#include <stdint.h>
#include <stdbool.h>

typedef struct
{
    uint16_t out12;
    uint16_t refout12;
} ecg_adc_debug_sample_t;

/*
 * Initialise the LPADC.
 * CMD1 -> OUT, CMD2 -> REFOUT.
 * One software trigger fires all conversions back-to-back.
 */
void ECGADC_Init(void);

/*
 * Fire one debug conversion sequence and return all 12-bit results.
 *
 * Returns true on success, false on timeout or null pointer.
 */
bool ECGADC_ReadDebug(ecg_adc_debug_sample_t *sample);

/*
 * Compatibility wrapper for older code.
 *
 * ecg12 - raw 12-bit ADC value for OUT
 * ref12 - raw 12-bit ADC value for REFOUT
 */
bool ECGADC_ReadBoth(uint16_t *ecg12, uint16_t *ref12);

#endif /* ECG_ADC_H */
