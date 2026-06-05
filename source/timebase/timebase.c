/*
 * timebase.c
 *
 * Microsecond timebase from DWT->CYCCNT (ARM DDI 0403E C1.8).
 *
 * CYCCNT is 32-bit and wraps every ~7.158 s at 600 MHz. NowUs accumulates
 * elapsed cycles into a uint64_t (g_cyccnt_accum) using
 *   delta = (uint32_t)(now - last)
 * which is correct across the rollover. Caller must invoke NowUs at least
 * once per 7.158 s; the 500 Hz main loop satisfies this.
 *
 * Timebase_NowCycles/CyclesToUs stay uint32_t; their callers use signed-cast
 * comparisons that are already wrap-safe.
 */

#include "timebase/timebase.h"

#include "fsl_device_registers.h"
#include "fsl_clock.h"

extern uint32_t SystemCoreClock;

#define TIMEBASE_FALLBACK_CLOCK_HZ (600000000UL)

static uint32_t g_timebase_clock_hz = TIMEBASE_FALLBACK_CLOCK_HZ;

static uint32_t Timebase_DetectClockHz(void)
{
    uint32_t hz = 0U;

#if defined(CPU_MIMXRT1166DVM6A_cm7) || defined(MIMXRT1166_cm7_SERIES)
    hz = CLOCK_GetRootClockFreq(kCLOCK_Root_M7);
#elif defined(CPU_MIMXRT1166DVM6A_cm4) || defined(MIMXRT1166_cm4_SERIES)
    hz = CLOCK_GetRootClockFreq(kCLOCK_Root_M4);
#endif

    if (hz < 1000000U)
    {
        hz = SystemCoreClock;
    }
    if (hz < 1000000U)
    {
        hz = TIMEBASE_FALLBACK_CLOCK_HZ;
    }
    return hz;
}

static uint32_t g_last_cyccnt  = 0U;
static uint64_t g_cyccnt_accum = 0ULL;

void Timebase_Init(void)
{
    g_timebase_clock_hz = Timebase_DetectClockHz();
    SystemCoreClock = g_timebase_clock_hz;

    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0U;
    DWT->CTRL  |= DWT_CTRL_CYCCNTENA_Msk;

    /* Seed accumulator: first NowUs reads as zero. */
    g_last_cyccnt  = DWT->CYCCNT;
    g_cyccnt_accum = 0ULL;
}

uint32_t Timebase_NowCycles(void)
{
    return DWT->CYCCNT;
}

uint32_t Timebase_CyclesToUs(uint32_t cycles)
{
    return (uint32_t)(((uint64_t)cycles * 1000000ULL) / (uint64_t)g_timebase_clock_hz);
}

uint32_t Timebase_ClockHz(void)
{
    return g_timebase_clock_hz;
}

/* Not ISR-safe; main-loop only. */
uint64_t Timebase_NowUs(void)
{
    uint32_t now = DWT->CYCCNT;
    g_cyccnt_accum += (uint64_t)(uint32_t)(now - g_last_cyccnt);
    g_last_cyccnt   = now;
    return (g_cyccnt_accum * 1000000ULL) / (uint64_t)g_timebase_clock_hz;
}
