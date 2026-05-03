/*
 * timebase.c
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       DWT cycle-counter timebase for ECG thesis project
 * DATE:        02/04/2026
 *
 * SUMMARY:
 *      Microsecond timebase built on the Cortex-M7 Data Watchpoint and
 *      Trace (DWT) cycle counter (DWT->CYCCNT) on the i.MX RT1160 EVK.
 *
 *      WRAPAROUND FIX — 64-bit monotonic timestamp:
 *        DWT->CYCCNT is a 32-bit hardware register. At 600 MHz it exhausts
 *        all 2^32 counts in exactly 4 294 967 295 / 600 000 000 ≈ 7.158 s,
 *        then silently resets to zero. The original uint32_t Timebase_NowUs()
 *        propagated this wrap into the t_us CSV field, causing the GUI plots
 *        to scroll back to time 0 every 7 seconds.
 *
 *        The fix accumulates elapsed cycles in a uint64_t software counter
 *        (g_cyccnt_accum) that survives every 32-bit rollover. The delta
 *        per call is computed as:
 *            delta = (uint32_t)(now - g_last_cyccnt)
 *        Unsigned 32-bit subtraction produces the correct positive elapsed
 *        count regardless of wraparound (e.g. now=100, last=4 294 967 200
 *        → delta = 196), making the accumulator strictly monotonic.
 *
 *        uint64_t overflows at 2^64 / 1 000 000 / 600 000 000 ≈ 584 942
 *        years — effectively never for any diagnostic session.
 *
 *        Precondition: Timebase_NowUs() must be called at least once per
 *        7.158 s. The 500 Hz main loop calls it every 2 ms — satisfied
 *        with a ×3 578 000 safety margin.
 *
 *      Timebase_NowCycles() and Timebase_CyclesToUs() remain uint32_t.
 *      All callers that use signed-cast comparisons ((int32_t)(a - b))
 *      for timing — wait_until(), the catch-up loop — are already
 *      wrap-safe and require no changes.
 *
 * REFERENCES:
 *      [1] ARM DDI 0403E — ARMv7-M Architecture Reference Manual, §C1.8
 *          (Data Watchpoint and Trace unit)
 *      [2] NXP i.MX RT1160 Reference Manual, §DWT
 */

#include "timebase/timebase.h"

#include "fsl_device_registers.h"

extern uint32_t SystemCoreClock;

/* 64-bit accumulator state — updated on every Timebase_NowUs() call */
static uint32_t g_last_cyccnt  = 0U;
static uint64_t g_cyccnt_accum = 0ULL;

void Timebase_Init(void)
{
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0U;
    DWT->CTRL  |= DWT_CTRL_CYCCNTENA_Msk;

    /* Seed accumulator so the first NowUs() call starts from zero */
    g_last_cyccnt  = DWT->CYCCNT;
    g_cyccnt_accum = 0ULL;
}

uint32_t Timebase_NowCycles(void)
{
    return DWT->CYCCNT;
}

uint32_t Timebase_CyclesToUs(uint32_t cycles)
{
    return (uint32_t)(((uint64_t)cycles * 1000000ULL) / (uint64_t)SystemCoreClock);
}

/*
 * Timebase_NowUs — monotonically increasing microsecond timestamp.
 *
 * Returns uint64_t; wraps after ~584 942 years at 600 MHz.
 * Thread safety: bare-metal single-core only. Do not call from an ISR
 * that can preempt the main loop without a critical section.
 */
uint64_t Timebase_NowUs(void)
{
    uint32_t now = DWT->CYCCNT;

    /* Unsigned subtraction is correct across the 32-bit rollover boundary */
    g_cyccnt_accum += (uint64_t)(uint32_t)(now - g_last_cyccnt);
    g_last_cyccnt   = now;

    return (g_cyccnt_accum * 1000000ULL) / (uint64_t)SystemCoreClock;
}
