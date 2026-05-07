/*
 * main_phase1.c
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       Phase 1 — Raw ECG + 6-axis IMU acquisition system
 * DATE:        10/04/2026
 *
 * ════════════════════════════════════════════════════════════════════════════
 * SYSTEM OVERVIEW
 * ════════════════════════════════════════════════════════════════════════════
 *
 * This file implements the Phase 1 data acquisition firmware for a real-time
 * ambulatory ECG system targeting the pre-hospital (ambulance) environment.
 * The primary purpose is to collect raw, minimally processed ECG and inertial
 * data for offline analysis in Phases 2 (filter evaluation) and 3 (motion
 * artefact suppression evaluation) using MATLAB.
 *
 * Hardware configuration: single AD8233 ECG channel, three MPU-6500 IMUs at
 * Mason-Likar torso positions. All processing targets the single AD8233
 * channel. Preliminary cycle-count estimates for
 * the full BPF + notch + MAS pipeline on this single channel place compute
 * usage below 0.01% of the Cortex-M7 budget at 600 MHz — compute is not the
 * design constraint; algorithm selection is driven by signal quality alone.
 *
 * Two recording modes are provided, selected at compile time:
 *
 *   PHASE1_ECG_ONLY — 4 fields, DECIM=1, target 500 Hz
 *     Streams t_us + ecg_corr plus OUT and REFOUT raw taps. Verify the
 *     actual output rate from timestamps after flashing. This mode is used for
 *     Phase 2
 *     offline bandpass and notch filter evaluation in MATLAB, where the full
 *     Nyquist margin (500/2=250 Hz >> 40 Hz passband) is required for correct
 *     frequency-domain characterisation of all B1–B6 and N1–N9 configurations.
 *
 *   PHASE1_ECG_IMU — 22 fields, DECIM=1, effective rate from timestamps
 *     Streams t_us + ecg_corr + 3×(ax,ay,az,gx,gy,gz) plus trailing
 *     AD8233 debug taps [out_raw,refout_raw].
 *     The PRINTF for the expanded row can exceed the 2 ms tick period. The
 *     catch-up guard prevents unbounded lag; the effective Fs must be
 *     recovered from the t_us timestamps.
 *     This mode is used for Phase 3 offline MAS algorithm evaluation (M1–M8).
 *     Each comparison isolates one variable:
 *       M1 NLMS |a| single-site    — baseline
 *       M2 NLMS |a| 3-site         — spatial diversity
 *       M3 RLS  |a| single-site    — algorithm class
 *       M4 NLMS 3-axis accel       — reference dimensionality
 *       M5 VS-NLMS |a| single-site — step-size adaptation
 *       M6 NLMS |g| single-site    — sensor modality (gyro vs accel)
 *       M7 NLMS 6-axis single-site — full IMU reference
 *       M8 Blanked Leaky NLMS      — stabilisation (QRS gate + weight decay)
 *     All three IMU sites and both accel and gyro axes are required.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * BAUD RATE — CRITICAL NOTE
 * ════════════════════════════════════════════════════════════════════════════
 *
 * This firmware requires 500000 baud. The default NXP SDK board.h sets
 * BOARD_DEBUG_UART_BAUDRATE to 115200. You must change this to 500000 in
 * board.h before building:
 *
 *   #define BOARD_DEBUG_UART_BAUDRATE   500000U
 *
 * 500000 baud was verified to work correctly on this board (no symbol errors).
 * The LPUART fractional divider achieves < 0.1% baud error at 500000 with
 * the 80 MHz LPUART source clock (80e6/500000 = 160, exact integer — no
 * fractional error at all), which explains why 500000 is more reliable than
 * 921600 (80e6/921600 = 86.8, fractional error > 2%, violating TIA-232-F §3.2).
 *
 * Match ecg_monitor.py to 500000 baud (set in the GUI port configuration).
 * Serial settings: 8N1, no flow control.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * IMU RAW DATA BYPASS — KALMAN FILTER LIMITATION
 * ════════════════════════════════════════════════════════════════════════════
 *
 * The imu_manager.c IMU_ReadAll() function applies a per-axis scalar Kalman
 * filter (Q=0.10, R=4.00) before returning IMU values. At steady state the
 * Kalman gain converges to K ≈ 0.14, giving an effective bandwidth of:
 *
 *   f_3dB ≈ K × Fs / (2π) ≈ 0.14 × 500 / 6.283 ≈ 11 Hz
 *
 * Ambulance vibration occupies two main bands: ~1.5–2 Hz (suspension
 * resonance) and ~6.5–13 Hz (engine/tyre harmonics), with the overall
 * vibration-of-concern range ~1–30 Hz (Partridge 2016/2021; Gao 2026;
 * Kosek 2021). ISO 2631-1:1997 §5 supplies whole-body vibration weighting
 * curves applicable to vehicle-borne exposure but does not define an
 * ambulance spectrum. The ~11 Hz Kalman bandwidth attenuates the upper end
 * of the engine/tyre band, which is why raw IMU data is used for Phase 1
 * recording rather than the Kalman-filtered output.
 *
 * For Phase 1 raw data collection, this file uses IMU_ReadAllRaw() (defined
 * in imu_manager.c, added for Phase 1) which returns the raw int16_t register
 * values directly without Kalman filtering, preserving the full IMU bandwidth
 * up to the hardware DLPF cutoff (92 Hz at DLPF_CFG=2).
 *
 * The Kalman filter in imu_manager.c is retained and used in Phase 4 (real-
 * time MAS firmware) where smooth weight convergence is preferred over raw
 * measurement noise.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * CSV OUTPUT FORMAT
 * ════════════════════════════════════════════════════════════════════════════
 *
 * ECG_ONLY mode header:
 *   t_us,ecg_corr,out_raw,refout_raw
 *
 * ECG_IMU mode header:
 *   t_us,ecg_corr,ax0,ay0,az0,gx0,gy0,gz0,
 *                 ax1,ay1,az1,gx1,gy1,gz1,
 *                 ax2,ay2,az2,gx2,gy2,gz2,
 *                 out_raw,refout_raw
 *
 * This active Phase 1 source emits 22-column ECG_IMU_DEBUG rows. The first
 * 20 columns intentionally preserve the legacy MAS layout; columns 21:22
 * are raw AD8233 debug taps, not IMU references.
 *
 * Field definitions:
 *   t_us     : microsecond timestamp, lower 32 bits of 64-bit counter.
 *              Wraps at 2^32 µs ≈ 71 min. A session of any practical length
 *              will not wrap. Convert in MATLAB: t_s = t_us / 1e6.
 *
 *   ecg_corr : DC-corrected ECG in raw 12-bit ADC counts (signed int16).
 *              = out_raw (AD8233 OUT) - refout_raw (AD8233 REFOUT).
 *              Convert to mV: ecg_mV = ecg_corr × (1800/4096).
 *
 *   ax,ay,az : Raw accelerometer register values, int16 LSB.
 *              Scale: 1 g = 16384 LSB (±2 g range, FS_SEL=0).
 *              Convert: accel_g = ax / 16384 (MPU-6500 RM §4.2).
 *              DC gravity component removed offline: subtract mean at rest.
 *
 *   gx,gy,gz : Raw gyroscope register values, int16 LSB.
 *              Scale: 1 °/s = 131 LSB (±250 °/s range, FS_SEL=0).
 *              Convert: gyro_dps = gx / 131 (MPU-6500 RM §4.4).
 *
 *   IMU site assignment (updated 01/05/2026 — Mason-Likar torso placement):
 *              IMU0 (PCS0, J10[6]) = LL  (left lower thorax)
 *              IMU1 (PCS1, J9[5])  = LA  (left subclavicular)
 *              IMU2 (PCS2, J9[1])  = RA  (right subclavicular)
 *
 *   Gyroscope inclusion rationale:
 *              The gyroscope measures rotational velocity at each electrode
 *              site. Beach et al. (Healthcare Technology Letters, 2021,
 *              PMC8450177) report a case-dependent comparison — gyroscope
 *              filtering performs better for slow motion artefacts while
 *              accelerometer filtering performs better in other scenarios;
 *              neither is categorically superior. Ma et al. (Rev. Sci.
 *              Instrum., 2024, DOI 10.1063/5.0153241) use all six IMU axes
 *              (MPU6050, same family as MPU-6500) as a multi-axis reference
 *              for ECG MA suppression; the specific "particle filter vs
 *              NLMS" comparative claim is not re-asserted here pending
 *              direct verification from the paper's results.
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>

#include "fsl_common.h"
#include "fsl_debug_console.h"
#include "fsl_device_registers.h"

#include "board.h"
#include "pin_mux.h"
#include "clock_config.h"

#include "app_config_phase1.h"
#include "timebase/timebase.h"
#include "drivers/ads1293.h"
#include "drivers/ecg_adc.h"
#include "drivers/imu_manager.h"

/*
 * No DSP filter modules included — Phase 1 records raw sensor data only.
 * All filtering (B1–B7 bandpass, N1–N9 notch, M1–M6 MAS) is applied
 * offline in MATLAB during Phase 2 and Phase 3 evaluation.
 */

/* ═══════════════════════════════════════════════════════════════════════════
   MODE SELECTION
   ═══════════════════════════════════════════════════════════════════════════
   Change PHASE1_MODE and rebuild. See file header for full timing analysis.

   PHASE1_ECG_ONLY    —  target 500 Hz, 4 fields
                          Use for: Phase 2 offline filter analysis (B1–B6, N1–N8)
                          Baud budget depends on value widths; verify real Fs

   PHASE1_ECG_IMU     —  effective rate from timestamps, 22 fields
                          Use for: Phase 3 offline MAS evaluation
                          (M1–M8)
                          Effective rate: PRINTF payload may exceed tick (2 ms) -> catch-up
                          measure the effective period from t_us after flashing.
                          Baud budget depends on value widths; verify real Fs
                          from t_us after every firmware change.

   PHASE1_ADS1293_IMU  -  ADS1293 Lead I/II signed 24-bit codes + 3x raw IMU
                          Default for the current ADS1293-based build.
                          ADS1293 DATA_STATUS readiness anchors each ECG row;
                          timestamped IMU samples are matched by nearest time.
   ═══════════════════════════════════════════════════════════════════════════ */

#define PHASE1_ECG_ONLY   (1)
#define PHASE1_ECG_IMU    (2)
#define PHASE1_ADS1293_ONLY (3)
#define PHASE1_ADS1293_IMU  (4)

#define PHASE1_MODE       PHASE1_ADS1293_IMU    /* change here and rebuild */
#define PHASE1_ADS1293_FRONTEND ADS1293_FRONTEND_5_LEAD
#define PHASE1_ADS1293_READY_MASK (0x06U)
#define PHASE1_ADS1293_READY_DEBUG (1U)
#define PHASE1_ADS1293_READY_DEBUG_PERIOD_US (1000000U)

#define PHASE1_USES_AD8233 \
    ((PHASE1_MODE == PHASE1_ECG_ONLY) || (PHASE1_MODE == PHASE1_ECG_IMU))
#define PHASE1_USES_ADS1293 \
    ((PHASE1_MODE == PHASE1_ADS1293_ONLY) || (PHASE1_MODE == PHASE1_ADS1293_IMU))
#define PHASE1_USES_IMU \
    ((PHASE1_MODE == PHASE1_ECG_IMU) || (PHASE1_MODE == PHASE1_ADS1293_IMU))

#if (PHASE1_MODE != PHASE1_ECG_ONLY) && \
    (PHASE1_MODE != PHASE1_ECG_IMU) && \
    (PHASE1_MODE != PHASE1_ADS1293_ONLY) && \
    (PHASE1_MODE != PHASE1_ADS1293_IMU)
    #error "PHASE1_MODE must be PHASE1_ECG_ONLY, PHASE1_ECG_IMU, PHASE1_ADS1293_ONLY, or PHASE1_ADS1293_IMU"
#endif

/* ═══════════════════════════════════════════════════════════════════════════
   TIMING CONSTANTS
   ═══════════════════════════════════════════════════════════════════════════
   DECIM=1 in both modes: print on every ADC tick.

   In ECG_ONLY mode: the expanded debug payload must be validated from
   timestamps after flashing.

   In ECG_IMU mode: the expanded debug payload can exceed the 2 ms tick.
   Catch-up may advance next_tick by extra steps.
   Effective output rate must be measured from t_us after serial-format changes.
   The DWT timestamps record the exact moment of each ADC conversion, so
   MATLAB recovers the true (non-uniform) sample times via t_s = t_us/1e6.
   Using actual timestamps rather than assuming a fixed rate is the correct
   approach when the inter-sample interval is not guaranteed to be uniform.
   ═══════════════════════════════════════════════════════════════════════════ */
#define PHASE1_DECIM   (1U)

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
#define PHASE1_IMU_MATCH_RING_LEN (16U)

typedef struct
{
    uint32_t  t_us;
    imu_raw_t raw[IMU_COUNT];
    bool      valid;
} phase1_imu_match_sample_t;

static uint32_t phase1_abs_time_delta_us(uint32_t a_us, uint32_t b_us)
{
    int32_t delta = (int32_t)(a_us - b_us);
    return (delta < 0) ? (0U - (uint32_t)delta) : (uint32_t)delta;
}

static void phase1_push_imu_match_sample(phase1_imu_match_sample_t ring[PHASE1_IMU_MATCH_RING_LEN],
                                         uint32_t *write_idx,
                                         bool *has_sample)
{
    if ((ring == NULL) || (write_idx == NULL) || (has_sample == NULL))
    {
        return;
    }

    phase1_imu_match_sample_t *slot = &ring[*write_idx];
    const uint32_t t0_us = (uint32_t)Timebase_NowUs();
    IMU_ReadAllRaw(slot->raw);
    const uint32_t t1_us = (uint32_t)Timebase_NowUs();

    /* Current IMU API reads all three sites as one block; use the midpoint
       as the block timestamp. Three dt columns keep the CSV contract ready
       for future per-site timestamping without another format change. */
    slot->t_us = t0_us + ((uint32_t)(t1_us - t0_us) / 2U);
    slot->valid = true;

    *write_idx = (*write_idx + 1U) % PHASE1_IMU_MATCH_RING_LEN;
    *has_sample = true;
}

static const phase1_imu_match_sample_t *phase1_find_nearest_imu_sample(
    const phase1_imu_match_sample_t ring[PHASE1_IMU_MATCH_RING_LEN],
    bool has_sample,
    uint32_t t_ecg_us)
{
    if ((ring == NULL) || !has_sample)
    {
        return NULL;
    }

    const phase1_imu_match_sample_t *best = NULL;
    uint32_t best_delta = UINT32_MAX;

    for (uint32_t ii = 0U; ii < PHASE1_IMU_MATCH_RING_LEN; ii++)
    {
        if (!ring[ii].valid)
        {
            continue;
        }

        uint32_t delta = phase1_abs_time_delta_us(ring[ii].t_us, t_ecg_us);
        if ((best == NULL) || (delta < best_delta))
        {
            best = &ring[ii];
            best_delta = delta;
        }
    }

    return best;
}
#endif

/* ═══════════════════════════════════════════════════════════════════════════
   HELPER: FLOAT → INT16 WITH ROUND-HALF-AWAY-FROM-ZERO
   ═══════════════════════════════════════════════════════════════════════════
   Used to convert Kalman-filtered float IMU values to int16_t for printing.
   Plain C cast truncates toward zero: (int16_t)(-16384.7f) = -16384, not
   -16385. Round-half-away-from-zero matches MATLAB's round() semantics,
   limiting the rounding error to ±0.5 LSB — below the MPU-6500 noise floor
   of approximately 4 mg RMS (PS-MPU-6500A-01 §3.1). This is used when
   Kalman output is printed; raw int16 from IMU_ReadAllRaw() needs no rounding.
   ═══════════════════════════════════════════════════════════════════════════ */
static inline int16_t f_to_i16(float v)
{
    return (v >= 0.0f) ? (int16_t)(v + 0.5f) : (int16_t)(v - 0.5f);
}

/* ═══════════════════════════════════════════════════════════════════════════
   HELPER: WRAP-SAFE BUSY-WAIT ON DWT CYCLE COUNTER
   ═══════════════════════════════════════════════════════════════════════════
   Waits until DWT->CYCCNT reaches `target`. The signed cast makes the
   comparison correct across the 32-bit CYCCNT rollover boundary (~7.16 s
   at 600 MHz): when CYCCNT wraps below target, (int32_t)(CYCCNT - target)
   is a large negative number and the loop correctly continues.
   Reference: ARM DDI 0403E §C1.8 (DWT cycle counter, unsigned free-running).
   ═══════════════════════════════════════════════════════════════════════════ */
static inline void wait_until_cycle(uint32_t target)
{
    while ((int32_t)(DWT->CYCCNT - target) < 0) { __NOP(); }
}

static inline void catch_up_next_tick(uint32_t *next_tick, uint32_t step)
{
    if ((int32_t)(DWT->CYCCNT - *next_tick) > 0)
    {
        do { *next_tick += step; }
        while ((int32_t)(DWT->CYCCNT - *next_tick) > 0);
    }
}

#if PHASE1_USES_ADS1293
static ads1293_t g_ads1293;
#endif

/* ═══════════════════════════════════════════════════════════════════════════
   MAIN
   ═══════════════════════════════════════════════════════════════════════════ */
int main(void)
{
    /* Standard NXP SDK board initialisation. Ensure board.h has:
       #define BOARD_DEBUG_UART_BAUDRATE  500000U
       before building, or PRINTF output will be at 115200 baud and appear
       garbled data in ecg_monitor.py at 500000.                            */
    BOARD_InitBootPins();
    BOARD_InitBootClocks();
    BOARD_InitDebugConsole();

    Timebase_Init();

#if PHASE1_USES_AD8233
    ECGADC_Init();
#endif

    /* ── IMU initialisation ─────────────────────────────────────────────────
     *
     * imu_manager.c (revised 10/04/2026) performs for each MPU-6500:
     *   1. Device reset via PWR_MGMT_1 bit 7 and 100 ms settle time, ensuring
     *      a known register state regardless of whether the supply was power-
     *      cycled (PS-MPU-6500A-01 §4.23 — startup time after reset).
     *   2. WHO_AM_I register read with up to 5 retries and 20 ms inter-attempt
     *      pause, resolving transient LPSPI first-transaction failures.
     *   3. DLPF=2 (92 Hz bandwidth), accel ±2 g, gyro ±250°/s, ODR=500 Hz.
     *   4. First-sample read with acceleration magnitude check.
     *
     * The blocking retry loop below requires all three IMU sites (LA, RA, LL)
     * to be confirmed before recording begins. Recording with a missing IMU
     * site would invalidate the multi-site vs single-site comparison (M1 vs M2)
     * and any algorithm requiring a specific electrode-site reference.
     *
     * Expected terminal output when all IMUs are healthy:
     *   [IMU0] WHO_AM_I = 0x70   ax=... |a|~=16384   config OK
     *   [IMU1] WHO_AM_I = 0x70   ax=... |a|~=16384   config OK
     *   [IMU2] WHO_AM_I = 0x70   ax=... |a|~=16384   config OK
     *   [PHASE1] All 3 IMUs confirmed.
     *
     * If any IMU shows 0xFF: MISO is floating — check pin_mux.c for the
     * LPSPI1_PCS0/PCS1/PCS2 assignments (D10, D4, D0 respectively).
     */

#if PHASE1_USES_IMU
    /* In ECG_IMU mode, all three IMUs are mandatory for Phase 3 MAS data. */
    PRINTF("[PHASE1] Waiting for all 3 IMUs (required for MAS data)...\r\n");

    uint32_t attempt = 0U;
    while (1)
    {
        attempt++;
        PRINTF("[PHASE1] Init attempt %u...\r\n", (unsigned)attempt);

        bool any = IMU_InitAll();
        if (any)
        {
            /* IMU_InitAll() returns true if at least one responds.
               We verify all three by probing valid flags via IMU_ReadAll(). */
            imu_data_t probe[IMU_COUNT];
            IMU_ReadAll(probe);

            bool ok0 = probe[0].valid;
            bool ok1 = probe[1].valid;
            bool ok2 = probe[2].valid;

            PRINTF("[PHASE1] IMU0(LL)=%s  IMU1(LA)=%s  IMU2(RA)=%s\r\n",
                   ok0 ? "OK" : "FAIL",
                   ok1 ? "OK" : "FAIL",
                   ok2 ? "OK" : "FAIL");

            if (ok0 && ok1 && ok2)
            {
                PRINTF("[PHASE1] All 3 IMUs confirmed. Proceeding.\r\n\r\n");
                break;
            }
        }

        PRINTF("[PHASE1] Check wiring:\r\n");
        PRINTF("[PHASE1]   IMU0 CS -> J10[6] (LPSPI1_PCS0) -> LL (L.LowerThorax)\r\n");
        PRINTF("[PHASE1]   IMU1 CS -> J9[5]  (LPSPI1_PCS1) -> LA (L.Subclavicular)\r\n");
        PRINTF("[PHASE1]   IMU2 CS -> J9[1]  (LPSPI1_PCS2) -> RA (R.Subclavicular)\r\n");
        PRINTF("[PHASE1] Retrying in 2 seconds...\r\n\r\n");
        SDK_DelayAtLeastUs(2000000U, SystemCoreClock);
    }

#else   /* PHASE1_ECG_ONLY — IMU not needed in stream but verify at boot */
    PRINTF("[PHASE1] ECG_ONLY mode — verifying IMU hardware at boot...\r\n");
    (void)IMU_InitAll();   /* result not checked — IMU unused in stream */
    PRINTF("[PHASE1] IMU check done (IMU data not recorded in this mode).\r\n\r\n");
#endif

    /* ── Configuration summary ──────────────────────────────────────────── */
#if PHASE1_USES_ADS1293
    status_t ads_st = ADS1293_Attach(&g_ads1293, LPSPI1,
                                     APP_ADS1293_SPI_SRC_CLOCK_HZ,
                                     APP_ADS1293_SPI_BAUD_HZ,
                                     kLPSPI_Pcs3, kLPSPI_MasterPcs3);
    if (ads_st != kStatus_Success)
    {
        PRINTF("[ADS1293] Attach failed (%d)\r\n", (int)ads_st);
        while (1) { __NOP(); }
    }

#if !PHASE1_USES_IMU
    ads_st = ADS1293_InitBus(&g_ads1293);
    if (ads_st != kStatus_Success)
    {
        PRINTF("[ADS1293] LPSPI1 init failed (%d)\r\n", (int)ads_st);
        while (1) { __NOP(); }
    }
#endif

    PRINTF("[ADS1293] CS -> J9[7] (LPSPI1_PCS3), SPI mode 0, 1 MHz\r\n");
    PRINTF("[ADS1293] DRDY is polled through DATA_STATUS for this build.\r\n");

    ads_st = ADS1293_Configure(&g_ads1293, PHASE1_ADS1293_FRONTEND);
    if (ads_st != kStatus_Success)
    {
        PRINTF("[ADS1293] Configuration failed (%d). Check CS/MISO/MOSI/SCLK.\r\n",
               (int)ads_st);
        while (1) { __NOP(); }
    }

    uint8_t ads_revid = 0U;
    if (ADS1293_ReadRevision(&g_ads1293, &ads_revid) == kStatus_Success)
    {
        PRINTF("[ADS1293] REVID = 0x%02X\r\n", ads_revid);
    }
    PRINTF("[ADS1293] Configured for %s, output stream uses Lead I and Lead II only.\r\n\r\n",
           (PHASE1_ADS1293_FRONTEND == ADS1293_FRONTEND_5_LEAD) ?
           "5-lead ECG" : "3-lead ECG");
#endif

    PRINTF("[PHASE1] =============================================\r\n");

#if (PHASE1_MODE == PHASE1_ECG_ONLY)
    PRINTF("[PHASE1]  Mode      : ECG_ONLY (Phase 2 filter analysis)\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ecg_corr, out_raw, refout_raw = 4\r\n");
    PRINTF("[PHASE1]  Rate      : target 500 Hz; verify with t_us after debug logging\r\n");
    PRINTF("[PHASE1]  Baud load : includes OUT and REFOUT raw ADC columns\r\n");
    PRINTF("[PHASE1]  Nyquist   : 250 Hz >> 40 Hz passband  (6.25x margin)\r\n");
    PRINTF("[PHASE1]  Use for   : B1-B6 bandpass + N1-N9 notch evaluation\r\n");
#elif (PHASE1_MODE == PHASE1_ECG_IMU)
    PRINTF("[PHASE1]  Mode      : ECG_IMU (Phase 3 MAS analysis)\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ecg_corr, 3xIMU, out_raw, refout_raw = 22\r\n");
    PRINTF("[PHASE1]  Rate      : effective Fs must be measured from t_us timestamps\r\n");
    PRINTF("[PHASE1]             UART payload includes OUT and REFOUT raw ADC columns.\r\n");
    PRINTF("[PHASE1]  Baud load : depends on value width; check ecg_monitor Fs est.\r\n");
    PRINTF("[PHASE1]  Nyquist   : compute from measured Fs before filter/MAS analysis\r\n");
    PRINTF("[PHASE1]  IMU data  : RAW int16 register values (Kalman bypassed)\r\n");
    PRINTF("[PHASE1]             Accel: /16384 -> g-units\r\n");
    PRINTF("[PHASE1]             Gyro : /131   -> deg/s\r\n");
    PRINTF("[PHASE1]  IMU sites : IMU0=LL(L.LowerThorax) IMU1=LA(L.Subclav) IMU2=RA(R.Subclav)\r\n");
    PRINTF("[PHASE1]  Use for   : MAS evaluation (M1-M8)\r\n");
    PRINTF("[PHASE1]             Accel ref: M1-M5,M8  Gyro: M6  6-axis: M7\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_ONLY)
    PRINTF("[PHASE1]  Mode      : ADS1293_ONLY\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ads_ch1, ads_ch2 = 3\r\n");
    PRINTF("[PHASE1]  ECG data  : ADS1293 signed 24-bit Lead I and Lead II codes\r\n");
    PRINTF("[PHASE1]  Rate      : ADS1293 SPS_128; verify from t_us timestamps\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_IMU)
    PRINTF("[PHASE1]  Mode      : ADS1293_IMU\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ads_ch1, ads_ch2, 3xIMU, dt_us = 24\r\n");
    PRINTF("[PHASE1]  ECG data  : ADS1293 signed 24-bit Lead I and Lead II codes\r\n");
    PRINTF("[PHASE1]  Rate      : ADS1293-ready anchored; verify from t_us timestamps\r\n");
    PRINTF("[PHASE1]  IMU data  : RAW int16 register values (Kalman bypassed)\r\n");
    PRINTF("[PHASE1]  IMU match : nearest timestamped IMU block; dt*_us = IMU - ECG\r\n");
    PRINTF("[PHASE1]  IMU sites : IMU0=LL  IMU1=LA  IMU2=RA\r\n");
#endif

    PRINTF("[PHASE1] =============================================\r\n");
    PRINTF("[PHASE1]  Baud rate : 500000  (confirm ecg_monitor.py matches)\r\n");
    PRINTF("[PHASE1]  MATLAB    : data = readmatrix('file.txt')\r\n");
    PRINTF("[PHASE1]             t_s  = data(:,1)/1e6\r\n");
#if PHASE1_USES_ADS1293
    PRINTF("[PHASE1]             leadI  = data(:,2)\r\n");
    PRINTF("[PHASE1]             leadII = data(:,3)\r\n");
#else
    PRINTF("[PHASE1]             ecg  = data(:,2)*(1800/4096)\r\n");
    PRINTF("[PHASE1]             raw  = data(:,end-1:end) = [OUT REFOUT]\r\n");
#endif
    PRINTF("[PHASE1] =============================================\r\n\r\n");

    /* ── CSV header ─────────────────────────────────────────────────────── */
    /*
     * The header is emitted once. MATLAB's readmatrix() automatically skips
     * non-numeric lines (boot messages and this header), so no manual parsing
     * is required on the MATLAB side.
     */
#if (PHASE1_MODE == PHASE1_ECG_ONLY)
    PRINTF("t_us,ecg_corr,out_raw,refout_raw\r\n");
#elif (PHASE1_MODE == PHASE1_ECG_IMU)
    PRINTF("t_us,ecg_corr,"
           "ax0,ay0,az0,gx0,gy0,gz0,"
           "ax1,ay1,az1,gx1,gy1,gz1,"
           "ax2,ay2,az2,gx2,gy2,gz2,"
           "out_raw,refout_raw\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_ONLY)
    PRINTF("t_us,ads_ch1,ads_ch2\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_IMU)
    PRINTF("t_us,ads_ch1,ads_ch2,"
           "ax0,ay0,az0,gx0,gy0,gz0,"
           "ax1,ay1,az1,gx1,gy1,gz1,"
           "ax2,ay2,az2,gx2,gy2,gz2,"
           "dt0_us,dt1_us,dt2_us\r\n");
#endif

    /* ── Main acquisition loop ───────────────────────────────────────────── */
    /*
     * Timing architecture:
     *   The loop uses the DWT->CYCCNT free-running 32-bit cycle counter as
     *   its timebase. The ADC is triggered every `step` cycles (= 600 MHz /
     *   500 Hz = 1 200 000 cycles per tick). The signed-cast comparison in
     *   wait_until_cycle() correctly handles the 32-bit rollover at ~7.16 s
     *   (ARM DDI 0403E §C1.8). Timebase_NowUs() is called every iteration to
     *   keep its 64-bit accumulator current (precondition: called at least once
     *   per 7.16 s — satisfied here at 500 Hz nominal, see timebase.c).
     *
     * ECG_ONLY mode:
     *   Use t_us timestamps to verify the expanded debug row still meets the
     *   required printed sample rate.
     *
     * ECG_IMU mode:
     *   Work per tick can exceed the 2 ms tick. The catch-up guard keeps the
     *   loop bounded; with debug payloads, use t_us to measure actual period.
     *
     * Catch-up guard:
     *   If multiple ticks are missed (e.g. during IMU SPI retries), the guard
     *   advances next_tick repeatedly until it is back in the future. This
     *   prevents unbounded lag accumulation without dropping the sequence
     *   counter — any overrun appears as a larger-than-expected timestamp
     *   interval in the CSV, visible in MATLAB via diff(t_s) > expected_dt.
     *
     * IMU raw reads (ECG_IMU mode only):
     *   IMU_ReadAllRaw() is called every iteration to bypass the Kalman filter
     *   in imu_manager.c. The Kalman filter has a steady-state bandwidth of
     *   ~11 Hz (see file header), which would attenuate the upper end of the
     *   ~6.5–13 Hz engine/tyre vibration band (Partridge 2016/2021; Gao 2026).
     *   Raw register values preserve the full IMU hardware DLPF bandwidth
     *   (92 Hz at DLPF_CFG=2), retaining all motion artefact content needed
     *   for Phase 3 MAS evaluation.
     */
    const uint32_t step = (uint32_t)(
        ((uint64_t)SystemCoreClock + (APP_ECG_FS_HZ / 2U)) / APP_ECG_FS_HZ);

    uint32_t next_tick = DWT->CYCCNT + step;
    uint32_t seq       = 0U;

#if PHASE1_USES_ADS1293 && PHASE1_ADS1293_READY_DEBUG
    uint32_t ads_debug_last_us = 0U;
    uint32_t ads_status_fail_count = 0U;
    uint32_t ads_not_ready_count = 0U;
    uint32_t ads_read_fail_count = 0U;
#endif

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
    phase1_imu_match_sample_t imu_ring[PHASE1_IMU_MATCH_RING_LEN];
    memset(imu_ring, 0, sizeof(imu_ring));
    uint32_t imu_ring_write = 0U;
    bool imu_ring_has_sample = false;
#elif PHASE1_USES_IMU
    imu_raw_t imu_raw[IMU_COUNT];
    memset(imu_raw, 0, sizeof(imu_raw));
#endif

    while (1)
    {
        wait_until_cycle(next_tick);
        next_tick += step;

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
        phase1_push_imu_match_sample(imu_ring, &imu_ring_write, &imu_ring_has_sample);
#endif

#if PHASE1_USES_ADS1293
        uint8_t ads_status = 0U;
        status_t ads_status_st = ADS1293_ReadDataStatus(&g_ads1293, &ads_status);
        bool ads_ready = (ads_status_st == kStatus_Success) &&
                         ((ads_status & PHASE1_ADS1293_READY_MASK) ==
                          PHASE1_ADS1293_READY_MASK);
        if (!ads_ready)
        {
#if PHASE1_ADS1293_READY_DEBUG
            const uint32_t now_us = (uint32_t)Timebase_NowUs();
            if (ads_status_st != kStatus_Success)
            {
                ads_status_fail_count++;
            }
            else
            {
                ads_not_ready_count++;
            }
            if ((ads_debug_last_us == 0U) ||
                ((uint32_t)(now_us - ads_debug_last_us) >= PHASE1_ADS1293_READY_DEBUG_PERIOD_US))
            {
                ads_debug_last_us = now_us;
                PRINTF("[ADS1293_DEBUG] t_us=%u DATA_STATUS=0x%02X "
                       "st=%d ready=%u mask=0x%02X "
                       "b0=%u b1=%u b2=%u b3=%u b4=%u b5=%u b6=%u b7=%u "
                       "status_fail=%u not_ready=%u read_fail=%u\r\n",
                       (unsigned)now_us,
                       (unsigned)ads_status,
                       (int)ads_status_st,
                       ads_ready ? 1U : 0U,
                       (unsigned)PHASE1_ADS1293_READY_MASK,
                       (unsigned)((ads_status >> 0U) & 0x01U),
                       (unsigned)((ads_status >> 1U) & 0x01U),
                       (unsigned)((ads_status >> 2U) & 0x01U),
                       (unsigned)((ads_status >> 3U) & 0x01U),
                       (unsigned)((ads_status >> 4U) & 0x01U),
                       (unsigned)((ads_status >> 5U) & 0x01U),
                       (unsigned)((ads_status >> 6U) & 0x01U),
                       (unsigned)((ads_status >> 7U) & 0x01U),
                       (unsigned)ads_status_fail_count,
                       (unsigned)ads_not_ready_count,
                       (unsigned)ads_read_fail_count);
            }
#endif
            catch_up_next_tick(&next_tick, step);
            continue;
        }

        const uint32_t t_us = (uint32_t)Timebase_NowUs();

        ads1293_samples_t ads_sample;
        if (ADS1293_ReadECGData(&g_ads1293, &ads_sample) != kStatus_Success)
        {
#if PHASE1_ADS1293_READY_DEBUG
            ads_read_fail_count++;
#endif
            catch_up_next_tick(&next_tick, step);
            continue;
        }

        if ((seq % PHASE1_DECIM) == 0U)
        {
#if (PHASE1_MODE == PHASE1_ADS1293_ONLY)
            PRINTF("%u,%d,%d\r\n",
                   (unsigned)t_us,
                   (int)ads_sample.ch1,
                   (int)ads_sample.ch2);
#else
            const phase1_imu_match_sample_t *imu_match =
                phase1_find_nearest_imu_sample(imu_ring, imu_ring_has_sample, t_us);
            imu_raw_t imu_zero[IMU_COUNT];
            memset(imu_zero, 0, sizeof(imu_zero));
            const imu_raw_t *imu_out = (imu_match != NULL) ? imu_match->raw : imu_zero;
            const int32_t imu_dt_us = (imu_match != NULL) ?
                (int32_t)(imu_match->t_us - t_us) : 0;

            PRINTF("%u,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d\r\n",
                   (unsigned)t_us,
                   (int)ads_sample.ch1,
                   (int)ads_sample.ch2,
                   /* IMU0 - LL */
                   (int)imu_out[0].ax, (int)imu_out[0].ay, (int)imu_out[0].az,
                   (int)imu_out[0].gx, (int)imu_out[0].gy, (int)imu_out[0].gz,
                   /* IMU1 - LA */
                   (int)imu_out[1].ax, (int)imu_out[1].ay, (int)imu_out[1].az,
                   (int)imu_out[1].gx, (int)imu_out[1].gy, (int)imu_out[1].gz,
                   /* IMU2 - RA */
                   (int)imu_out[2].ax, (int)imu_out[2].ay, (int)imu_out[2].az,
                   (int)imu_out[2].gx, (int)imu_out[2].gy, (int)imu_out[2].gz,
                   (int)imu_dt_us, (int)imu_dt_us, (int)imu_dt_us);
#endif
        }

#else
        /*
         * Timestamp captured immediately after the tick wait, before the
         * ADC conversion and any UART activity. This ensures t_us reflects
         * the moment the sample was taken, not the moment it was transmitted.
         * Timebase_NowUs() maintains a 64-bit monotonic microsecond counter
         * by accumulating the 32-bit DWT rollover (see timebase.c). The lower
         * 32 bits are stored here; they wrap at 2^32 µs ≈ 71 min — no wrap
         * occurs in any practical Phase 1 session.
         */
        const uint32_t t_us = (uint32_t)Timebase_NowUs();

        /*
         * ECG ADC: ECGADC_ReadDebug() fires a chained LPADC conversion:
         *   Software trigger -> OUT -> REFOUT -> FIFO
         * Results land in FIFO order [out_raw, refout_raw].
         * Spin-wait timeout: 500 µs (see ecg_adc.c). On timeout, returns
         * false and both values remain 0. The zero entry is still recorded
         * so array indices stay aligned with timestamps; MATLAB identifies
         * dropped samples as zero-amplitude entries at the expected time.
         *
         * DC correction: ecg_corr = out_raw - refout_raw. Signed subtraction into
         * int16_t is safe because both 12-bit raw values are in [0, 4095].
         */
        ecg_adc_debug_sample_t ecg_dbg;
        (void)ECGADC_ReadDebug(&ecg_dbg);
        const int16_t ecg_corr =
            (int16_t)((int32_t)ecg_dbg.out12 - (int32_t)ecg_dbg.refout12);

#if (PHASE1_MODE == PHASE1_ECG_IMU)
        /*
         * IMU raw read: IMU_ReadAllRaw() reads 14 bytes from each MPU-6500
         * over LPSPI1 (ACCEL_XOUT_H through GYRO_ZOUT_L) and returns the
         * raw int16_t register values without Kalman filtering.
         * Three SPI reads at 1 MHz baud take approximately 3 × 120 µs = 360 µs
         * total — within the ~3.24 ms effective tick period.
         *
         * Register layout (MPU-6500 RM-MPU-6500A-00 Rev 2.1 §3.1):
         *   buf[0:1]  = ACCEL_XOUT  buf[2:3]  = ACCEL_YOUT  buf[4:5]  = ACCEL_ZOUT
         *   buf[6:7]  = TEMP_OUT    (skipped)
         *   buf[8:9]  = GYRO_XOUT   buf[10:11] = GYRO_YOUT  buf[12:13] = GYRO_ZOUT
         *
         * If a device is not present (not flagged valid after init), the raw
         * struct is left as zero from the memset above — producing clean zero
         * columns in the CSV rather than stale or garbage values.
         */
        IMU_ReadAllRaw(imu_raw);
#endif

        /* ── PRINTF output ───────────────────────────────────────────────── */
        /*
         * All signed IMU values are printed with %d (signed decimal).
         * Using %u for signed values would overflow negative readings to
         * 4294967295 (= 0xFFFFFFFF = (uint32_t)(-1)), which was observed
         * previously when axes pointed downward (e.g. az ≈ -16384 on an
         * upside-down IMU). %d with (int) cast correctly emits the minus sign.
         *
         * t_us is unsigned and printed with %u.
         * ecg_corr is signed int16_t, printed with %d.
         */
        if ((seq % PHASE1_DECIM) == 0U)
        {
#if (PHASE1_MODE == PHASE1_ECG_ONLY)
            PRINTF("%u,%d,%u,%u\r\n",
                   (unsigned)t_us,
                   (int)ecg_corr,
                   (unsigned)ecg_dbg.out12,
                   (unsigned)ecg_dbg.refout12);

#else   /* PHASE1_ECG_IMU - 20 legacy fields + 2 AD8233 debug fields */
            PRINTF("%u,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%u,%u\r\n",
                   (unsigned)t_us,
                   (int)ecg_corr,
                   /* IMU0 - LL, left lower thorax */
                   (int)imu_raw[0].ax, (int)imu_raw[0].ay, (int)imu_raw[0].az,
                   (int)imu_raw[0].gx, (int)imu_raw[0].gy, (int)imu_raw[0].gz,
                   /* IMU1 - LA, left subclavicular */
                   (int)imu_raw[1].ax, (int)imu_raw[1].ay, (int)imu_raw[1].az,
                   (int)imu_raw[1].gx, (int)imu_raw[1].gy, (int)imu_raw[1].gz,
                   /* IMU2 - RA, right subclavicular */
                   (int)imu_raw[2].ax, (int)imu_raw[2].ay, (int)imu_raw[2].az,
                   (int)imu_raw[2].gx, (int)imu_raw[2].gy, (int)imu_raw[2].gz,
                   (unsigned)ecg_dbg.out12,
                   (unsigned)ecg_dbg.refout12);
#endif
        }

#endif /* PHASE1_USES_ADS1293 */

        seq++;

        /*
         * Catch-up guard: if the loop body (ADC + IMU + PRINTF) took longer
         * than one step, advance next_tick until it is back in the future.
         * In ECG_IMU mode this may fire whenever UART/IMU work exceeds the
         * 2 ms tick. In ECG_ONLY mode this should be rare; if it fires, the corresponding timestamp
         * gap will appear in MATLAB's diff(t_s) for quality inspection.
         */
        catch_up_next_tick(&next_tick, step);
    }
}
