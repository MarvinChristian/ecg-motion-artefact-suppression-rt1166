/*
 * timebase.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       DWT cycle-counter timebase for ECG thesis project
 * DATE:        02/04/2026
 *
 * SUMMARY:
 *      Public interface for the DWT-based microsecond timebase.
 *      Timebase_NowUs() returns uint64_t to survive the 32-bit
 *      DWT->CYCCNT rollover that occurs every ~7.158 s at 600 MHz.
 *      See timebase.c for the full accumulator approach.
 *
 * REFERENCES:
 *      [1] ARM DDI 0403E — ARMv7-M Architecture Reference Manual, §C1.8
 */

#ifndef TIMEBASE_H
#define TIMEBASE_H

#include <stdint.h>

/* Enable DWT, zero CYCCNT, seed the 64-bit accumulator. Call once. */
void     Timebase_Init(void);

/* Raw 32-bit cycle count — wraps every ~7.158 s at 600 MHz.
   Used by wait_until() and the catch-up loop via signed-cast arithmetic;
   those callers are already wrap-safe and do not need uint64_t.          */
uint32_t Timebase_NowCycles(void);

/* Convert a 32-bit cycle delta to microseconds. */
uint32_t Timebase_CyclesToUs(uint32_t cycles);

/* Monotonically increasing microsecond timestamp.
   Returns uint64_t — wraps after ~584 942 years at 600 MHz.
   Must be called at least once per 7.158 s (satisfied at 500 Hz).       */
uint64_t Timebase_NowUs(void);

#endif /* TIMEBASE_H */
