/*
 * timebase.h
 *
 * DWT-based microsecond timebase. NowUs returns uint64_t to survive the
 * 32-bit CYCCNT rollover (~7.158 s @ 600 MHz). See timebase.c.
 * Ref: ARM DDI 0403E C1.8.
 */

#ifndef TIMEBASE_H
#define TIMEBASE_H

#include <stdint.h>

/* Enable DWT, zero CYCCNT, seed the 64-bit accumulator. Call once. */
void     Timebase_Init(void);

/* Raw 32-bit cycle count - wraps every ~7.158 s at 600 MHz.
   Used by wait_until() and the catch-up loop via signed-cast arithmetic;
   those callers are already wrap-safe and do not need uint64_t.          */
uint32_t Timebase_NowCycles(void);

/* Convert a 32-bit cycle delta to microseconds. */
uint32_t Timebase_CyclesToUs(uint32_t cycles);

/* Clock used to convert DWT cycles to microseconds. */
uint32_t Timebase_ClockHz(void);

/* Monotonically increasing microsecond timestamp.
   Returns uint64_t - wraps after ~584 942 years at 600 MHz.
   Must be called at least once per 7.158 s (satisfied at 500 Hz).       */
uint64_t Timebase_NowUs(void);

#endif /* TIMEBASE_H */
