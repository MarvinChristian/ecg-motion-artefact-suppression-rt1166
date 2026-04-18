/*
 * ecg_adc.c
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       Dual-channel LPADC driver — AD8233 ECG output and REFOUT
 * DATE:        19/04/2026
 *
 * Conversion sequence (single software trigger):
 *   TRIG0 → CMD1 (ch0, ECG OUT) → chains to → CMD2 (ch1, REFOUT)
 *
 * Both results land in the FIFO in order: [ecg, refout].
 */

#include "drivers/ecg_adc.h"
#include "app_config_phase1.h"

#include "fsl_lpadc.h"
#include "fsl_common.h"
#include "fsl_device_registers.h"   /* DWT, CoreDebug — for cycle-count timeout */

/* ------------------------------------------------------------------
   Resolve LPADC peripheral base at compile time.
   The iMX RT1160-EVK SDK exposes ADC1 / ADC2 (or LPADC1/LPADC2).
   ------------------------------------------------------------------ */
#if   defined(ADC1)
    #define ECG_LPADC_BASE   ADC1
#elif defined(ADC2)
    #define ECG_LPADC_BASE   ADC2
#elif defined(LPADC1)
    #define ECG_LPADC_BASE   LPADC1
#elif defined(LPADC2)
    #define ECG_LPADC_BASE   LPADC2
#elif defined(ADC_BASE_PTRS)
    #define ECG_LPADC_BASE   (ADC_BASE_PTRS[0])
#else
    #error "No LPADC base symbol found – check your SDK device header."
#endif

/* ------------------------------------------------------------------
   Command / trigger IDs
   LPADC command IDs are 1-based (0 means "no command").
   ------------------------------------------------------------------ */
#define ECG_CMD_ECG    (1U)   /* CMD1 – samples ch0 (ECG OUT)  */
#define ECG_CMD_REF    (2U)   /* CMD2 – samples ch1 (REFOUT)   */
#define ECG_TRIG_ID    (0U)   /* software trigger 0            */

/* ------------------------------------------------------------------
   Spin-wait timeout — 500 µs expressed in CPU cycles.
   Using DWT->CYCCNT instead of a raw iteration count makes the
   timeout independent of clock frequency: if SystemCoreClock changes
   (e.g. during power-mode testing at 300 MHz) the guard still fires
   after exactly 500 µs, which is well within the 2 ms 500 Hz period.

   Two chained 12-bit LPADC conversions complete in roughly 2–5 µs at
   default settings (NXP RM §42), so 500 µs provides a ×100 safety
   margin while still bounding the worst-case delay to 25 % of one
   ECG sample period.
   ------------------------------------------------------------------ */
#define ECG_CONV_TIMEOUT_US   (500U)

/* ------------------------------------------------------------------
   ECGADC_Init
   ------------------------------------------------------------------ */
void ECGADC_Init(void)
{
    /* --- ADC core ------------------------------------------------- */
    lpadc_config_t adcCfg;
    LPADC_GetDefaultConfig(&adcCfg);
    LPADC_Init(ECG_LPADC_BASE, &adcCfg);

    /* --- CMD1: ch0 (ECG OUT), chains to CMD2 --------------------- */
    lpadc_conv_command_config_t cmdCfg;
    LPADC_GetDefaultConvCommandConfig(&cmdCfg);

    cmdCfg.sampleChannelMode        = kLPADC_SampleChannelSingleEndSideA;
    cmdCfg.channelNumber            = APP_ECG_ADC_CH_OUT;  /* ch0 */
    cmdCfg.chainedNextCommandNumber = ECG_CMD_REF;          /* auto-chain */
    cmdCfg.enableAutoChannelIncrement = false;

    LPADC_SetConvCommandConfig(ECG_LPADC_BASE, ECG_CMD_ECG, &cmdCfg);

    /* --- CMD2: ch1 (REFOUT), no further chain -------------------- */
    LPADC_GetDefaultConvCommandConfig(&cmdCfg);

    cmdCfg.sampleChannelMode        = kLPADC_SampleChannelSingleEndSideA;
    cmdCfg.channelNumber            = APP_ECG_ADC_CH_REF;  /* ch1 */
    cmdCfg.chainedNextCommandNumber = 0U;                   /* stop */
    cmdCfg.enableAutoChannelIncrement = false;

    LPADC_SetConvCommandConfig(ECG_LPADC_BASE, ECG_CMD_REF, &cmdCfg);

    /* --- TRIG0: targets CMD1 (software trigger) ------------------ */
    lpadc_conv_trigger_config_t trigCfg;
    LPADC_GetDefaultConvTriggerConfig(&trigCfg);
    trigCfg.targetCommandId       = ECG_CMD_ECG;
    trigCfg.enableHardwareTrigger = false;
    LPADC_SetConvTriggerConfig(ECG_LPADC_BASE, ECG_TRIG_ID, &trigCfg);

    /* Flush any stale data */
    LPADC_DoResetFIFO(ECG_LPADC_BASE);
}

/* ------------------------------------------------------------------
   ECGADC_ReadBoth
   Fire one trigger → CMD1 converts ch0 → CMD2 converts ch1.
   The FIFO holds exactly 2 results in order: [ecg, refout].

   Timeout strategy:
     The spin-wait deadline is computed once from DWT->CYCCNT before
     the trigger fires.  The signed comparison (int32_t)(now - end) < 0
     handles the 32-bit counter wraparound correctly (wraps every
     ~7.16 s at 600 MHz, far longer than the 500 µs timeout window).
   ------------------------------------------------------------------ */
bool ECGADC_ReadBoth(uint16_t *ecg12, uint16_t *ref12)
{
    if ((ecg12 == NULL) || (ref12 == NULL))
    {
        return false;
    }

    /* Compute absolute cycle-count deadline before firing the trigger
       so that conversion time is included inside the timeout window.   */
    uint32_t timeout_cycles =
        (uint32_t)(((uint64_t)ECG_CONV_TIMEOUT_US * (uint64_t)SystemCoreClock)
                   / 1000000ULL);
    uint32_t deadline = DWT->CYCCNT + timeout_cycles;

    /* Fire the paired conversion */
    LPADC_DoSoftwareTrigger(ECG_LPADC_BASE, (1UL << ECG_TRIG_ID));

    /* Spin until both FIFO results are ready or the deadline passes.
       The signed cast makes the comparison wrap-safe.                  */
    while ((LPADC_GetConvResultCount(ECG_LPADC_BASE) < 2U) &&
           ((int32_t)(DWT->CYCCNT - deadline) < 0))
    {
        /* spin */
    }

    if (LPADC_GetConvResultCount(ECG_LPADC_BASE) < 2U)
    {
        /* Timeout – flush so the next call starts clean */
        LPADC_DoResetFIFO(ECG_LPADC_BASE);
        return false;
    }

    /* First result = ECG OUT (CMD1, ch0) */
    lpadc_conv_result_t r;
    if (!LPADC_GetConvResult(ECG_LPADC_BASE, &r))
    {
        LPADC_DoResetFIFO(ECG_LPADC_BASE);
        return false;
    }
    *ecg12 = (uint16_t)(r.convValue >> APP_ADC_RESULT_SHIFT);

    /* Second result = REFOUT (CMD2, ch1) */
    if (!LPADC_GetConvResult(ECG_LPADC_BASE, &r))
    {
        LPADC_DoResetFIFO(ECG_LPADC_BASE);
        return false;
    }
    *ref12 = (uint16_t)(r.convValue >> APP_ADC_RESULT_SHIFT);

    return true;
}
