/*
 * ecg_adc.c
 *
 * LPADC driver for the AD8233 OUT/REFOUT taps. One software trigger fires
 * a chained conversion (TRIG0 -> CMD1 OUT -> CMD2 REFOUT); FIFO order
 * is [out, refout].
 */

#include "drivers/ecg_adc.h"
#include "app_config_phase1.h"

#include "fsl_lpadc.h"
#include "fsl_common.h"
#include "fsl_device_registers.h"   /* DWT, CoreDebug - cycle-count timeout */

/* Resolve the LPADC peripheral base. The RT1160-EVK SDK may expose ADC1/ADC2
 * or LPADC1/LPADC2 depending on the device header version. */
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
    #error "No LPADC base symbol found - check your SDK device header."
#endif

/* LPADC command and trigger IDs. Command IDs are 1-based; 0 means no command. */
#define ECG_CMD_OUT        (1U)   /* CMD1 - samples OUT           */
#define ECG_CMD_REFOUT     (2U)   /* CMD2 - samples REFOUT        */
#define ECG_TRIG_ID        (0U)   /* software trigger 0           */
#define ECG_RESULT_COUNT   (2U)

/* 500 us spin-wait bound; protects against a wiring/config fault. */
#define ECG_CONV_TIMEOUT_US   (500U)

static void ECGADC_SetCommand(uint32_t cmd_id, uint32_t channel, uint32_t next_cmd)
{
    lpadc_conv_command_config_t cmdCfg;
    LPADC_GetDefaultConvCommandConfig(&cmdCfg);

    cmdCfg.sampleChannelMode          = kLPADC_SampleChannelSingleEndSideA;
    cmdCfg.channelNumber              = channel;
    cmdCfg.chainedNextCommandNumber   = next_cmd;
    cmdCfg.enableAutoChannelIncrement = false;

    LPADC_SetConvCommandConfig(ECG_LPADC_BASE, cmd_id, &cmdCfg);
}

void ECGADC_Init(void)
{
    lpadc_config_t adcCfg;
    LPADC_GetDefaultConfig(&adcCfg);
    LPADC_Init(ECG_LPADC_BASE, &adcCfg);

    ECGADC_SetCommand(ECG_CMD_OUT,    APP_ECG_ADC_CH_OUT,    ECG_CMD_REFOUT);
    ECGADC_SetCommand(ECG_CMD_REFOUT, APP_ECG_ADC_CH_REFOUT, 0U);

    lpadc_conv_trigger_config_t trigCfg;
    LPADC_GetDefaultConvTriggerConfig(&trigCfg);
    trigCfg.targetCommandId       = ECG_CMD_OUT;
    trigCfg.enableHardwareTrigger = false;
    LPADC_SetConvTriggerConfig(ECG_LPADC_BASE, ECG_TRIG_ID, &trigCfg);

    LPADC_DoResetFIFO(ECG_LPADC_BASE);
}

bool ECGADC_ReadDebug(ecg_adc_debug_sample_t *sample)
{
    if (sample == NULL)
    {
        return false;
    }

    sample->out12     = 0U;
    sample->refout12  = 0U;

    uint32_t timeout_cycles =
        (uint32_t)(((uint64_t)ECG_CONV_TIMEOUT_US * (uint64_t)SystemCoreClock)
                   / 1000000ULL);
    uint32_t deadline = DWT->CYCCNT + timeout_cycles;

    LPADC_DoSoftwareTrigger(ECG_LPADC_BASE, (1UL << ECG_TRIG_ID));

    while ((LPADC_GetConvResultCount(ECG_LPADC_BASE) < ECG_RESULT_COUNT) &&
           ((int32_t)(DWT->CYCCNT - deadline) < 0))
    {
        /* spin */
    }

    if (LPADC_GetConvResultCount(ECG_LPADC_BASE) < ECG_RESULT_COUNT)
    {
        LPADC_DoResetFIFO(ECG_LPADC_BASE);
        return false;
    }

    lpadc_conv_result_t r;

    if (!LPADC_GetConvResult(ECG_LPADC_BASE, &r))
    {
        LPADC_DoResetFIFO(ECG_LPADC_BASE);
        return false;
    }
    sample->out12 = (uint16_t)(r.convValue >> APP_ADC_RESULT_SHIFT);

    if (!LPADC_GetConvResult(ECG_LPADC_BASE, &r))
    {
        LPADC_DoResetFIFO(ECG_LPADC_BASE);
        return false;
    }
    sample->refout12 = (uint16_t)(r.convValue >> APP_ADC_RESULT_SHIFT);

    return true;
}

bool ECGADC_ReadBoth(uint16_t *ecg12, uint16_t *ref12)
{
    if ((ecg12 == NULL) || (ref12 == NULL))
    {
        return false;
    }

    ecg_adc_debug_sample_t sample;
    bool ok = ECGADC_ReadDebug(&sample);
    *ecg12 = sample.out12;
    *ref12 = sample.refout12;
    return ok;
}
