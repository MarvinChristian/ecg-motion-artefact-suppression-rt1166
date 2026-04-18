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
 * Two recording modes are provided, selected at compile time:
 *
 *   PHASE1_ECG_ONLY — 3 fields, DECIM=1, true 500 Hz
 *     Streams t_us + ecg_corr only. The PRINTF for 18 bytes at 500 kbaud
 *     takes 0.36 ms, well within the 2 ms tick period — no catch-up fires
 *     and the ADC samples at the full 500 Hz. This mode is used for Phase 2
 *     offline bandpass and notch filter evaluation in MATLAB, where the full
 *     Nyquist margin (500/2=250 Hz >> 40 Hz passband) is required for correct
 *     frequency-domain characterisation of all B1–B6 and N1–N8 configurations.
 *
 *   PHASE1_ECG_IMU — 20 fields, DECIM=1, effective 250 Hz
 *     Streams t_us + ecg_corr + 3×(ax,ay,az,gx,gy,gz). The PRINTF for
 *     ~144 bytes at 500 kbaud takes 2.88 ms, which exceeds the 2 ms tick
 *     period. The catch-up guard advances next_tick by one extra step, making
 *     each effective loop iteration take ~4 ms. The actual output rate is
 *     therefore 500/(1+1) = 250 Hz, revealed precisely by the t_us timestamps.
 *     At Fs = 250 Hz the Nyquist limit is 125 Hz, giving 125/40 ≈ 3.1× margin
 *     over the 40 Hz ECG passband — well above the Nyquist criterion
 *     (Proakis & Manolakis, DSP 4th ed., §4.1).
 *     This mode is used for Phase 3 offline MAS algorithm evaluation (M1–M13),
 *     where all three accelerometer and gyroscope axes from all three IMU sites
 *     are required as candidate reference signals.
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
 * up to the hardware DLPF cutoff (92 Hz at DLPF_CFG=2). This is the correct
 * approach for Phase 3 MAS evaluation, which must characterise the full
 * motion artefact spectrum before designing the suppression filter.
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
 *   t_us,ecg_corr
 *
 * ECG_IMU mode header:
 *   t_us,ecg_corr,ax0,ay0,az0,gx0,gy0,gz0,
 *                 ax1,ay1,az1,gx1,gy1,gz1,
 *                 ax2,ay2,az2,gx2,gy2,gz2
 *
 * Field definitions:
 *   t_us     : microsecond timestamp, lower 32 bits of 64-bit counter.
 *              Wraps at 2^32 µs ≈ 71 min. A session of any practical length
 *              will not wrap. Convert in MATLAB: t_s = t_us / 1e6.
 *
 *   ecg_corr : DC-corrected ECG in raw 12-bit ADC counts (signed int16).
 *              = ecg_raw (ch0, AD8233 OUTPUT) − ref_raw (ch1, AD8233 REFOUT).
 *              REFOUT (ch1) buffers REFIN; REFIN is driven by an external
 *              3.3 V → 5 kΩ pot + 2.2 kΩ divider for a tuneable baseline, so
 *              its DC value is setup-dependent (not fixed at VS/2). The
 *              differential subtraction removes this common-mode DC bias
 *              regardless of the exact REFOUT voltage, equivalent to AC
 *              coupling without the high-pass transient of a capacitive
 *              network (AD8233 datasheet §THEORY OF OPERATION).
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
 *   IMU site assignment (supervisor directive 02/04/2026):
 *              IMU0 (PCS0, D10) = Left Arm  (LA electrode site)
 *              IMU1 (PCS1, D4)  = Right Arm (RA electrode site)
 *              IMU2 (PCS2, D0)  = Right Leg (RL / drive electrode site)
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
 *              direct verification from the paper's results. Phase 3
 *              algorithms M9–M13 explicitly evaluate gyroscope-based and 6-axis
 *              MAS references, requiring both accel and gyro to be recorded.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * MATLAB IMPORT (both modes)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *   data      = readmatrix('phase1_session.txt');  % skips non-numeric lines
 *   t_s       = data(:,1) / 1e6;
 *   ecg_mV    = data(:,2) * (1800 / 4096);
 *   fs_actual = 1 / mean(diff(t_s));   % verify ~500 Hz (ECG_ONLY) or ~250 Hz
 *
 *   % ECG_IMU mode — IMU columns
 *   ax0 = data(:,3);   ay0 = data(:,4);   az0 = data(:,5);
 *   gx0 = data(:,6);   gy0 = data(:,7);   gz0 = data(:,8);
 *   % IMU1: cols 9-14,  IMU2: cols 15-20
 *
 *   % Compute accelerometer magnitude (used by M1-M4, M7, M8, M9):
 *   mag0_lsb = sqrt(ax0.^2 + ay0.^2 + az0.^2);
 *
 *   % Remove DC gravity before MAS (matches firmware DC blocker):
 *   dc_alpha = 0.995;
 *   ax0_ac   = filter([1-dc_alpha], [1 -dc_alpha], double(ax0));
 *   ax0_ref  = ax0_ac / 16384;   % g-units, AC only
 *
 * ════════════════════════════════════════════════════════════════════════════
 * ECG MONITOR GUI SETUP (ecg_monitor.py)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *   1. Open ecg_monitor.py. Select the correct COM port and set baud to
 *      500000 (8N1, no flow control).
 *   2. Choose an output file path before starting, e.g.:
 *      C:\ECG_Phase1\resting_01.txt
 *   3. Connect. Confirm all 3 IMUs show WHO_AM_I=0x70 and |a|≈16384 in
 *      the terminal panel. If any IMU fails, the board retries every 2 s.
 *   4. Start recording. CSV lines stream after the header. Record for the
 *      required duration (3 min for resting/walking; varies per condition).
 *   5. Stop recording in the GUI — the file saves automatically.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * RECORDING CONDITIONS (supervisor directive — Phase 1 protocol)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *   1. Resting (seated, 3 min) — baseline morphology, no motion artefact
 *   2. Walking  (3 min)        — low-frequency motion artefact (0.5–2 Hz)
 *   3. Arm/electrode movement  — medium-frequency, electrode-specific artefact
 *   4. Ambulance vibration sim — broadband vibration ~1–30 Hz (dominant
 *             bands ~1.5–2 Hz suspension resonance and ~6.5–13 Hz engine/tyre
 *             harmonics; Partridge 2016/2021; Gao 2026; Kosek 2021).
 *             ISO 2631-1:1997 §5 whole-body vibration weighting curves apply
 *             to vehicle-borne exposure but do not define an ambulance spectrum.
 *
 * REFERENCES:
 *   [1]  Proakis & Manolakis, DSP 4th ed. §4.1 — Nyquist sampling theorem
 *   [2]  AD8233 datasheet — ECG front-end, mid-supply biasing, REFOUT
 *   [3]  MPU-6500 RM-MPU-6500A-00 Rev 2.1 §4.2, §4.4 — scale factors
 *   [4]  Beach et al., Healthcare Technology Letters, 2021 (PMC8450177)
 *           — IMU-referenced adaptive filtering for ECG/EEG motion artefact;
 *             per-electrode IMU placement. Gyroscope vs accelerometer is
 *             case-dependent in that paper, not blanket-superiority.
 *   [5]  Ma et al., Rev. Sci. Instrum. 95(1), 2024 — 6-axis IMU particle filter
 *   [6]  Ambulance vibration bands — ~1.5–2 Hz (suspension) + ~6.5–13 Hz
 *           (engine/tyre), overall vibration-of-concern ~1–30 Hz
 *           (Partridge 2016/2021; Gao 2026; Kosek 2021). ISO 2631-1:1997 §5
 *           provides whole-body vibration weighting curves for vehicle-borne
 *           exposure but is not an ambulance-specific spectrum.
 *   [7]  TIA-232-F §3.2 — UART baud-rate tolerance ±2%
 *   [8]  ARM DDI 0403E §C1.8 — DWT CYCCNT cycle counter
 *   [9]  IEC 60601-2-47:2012 — ambulatory ECG passband 0.67–40 Hz
 *           (IEC 60601-2-27:2011 covers ECG monitoring equipment generally
 *            and does not specify the 0.67–40 Hz ambulatory band.)
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "fsl_common.h"
#include "fsl_debug_console.h"
#include "fsl_device_registers.h"

#include "board.h"
#include "pin_mux.h"
#include "clock_config.h"

#include "app_config_phase1.h"
#include "timebase/timebase.h"
#include "drivers/ecg_adc.h"
#include "drivers/imu_manager.h"

/*
 * No DSP filter modules included — Phase 1 records raw sensor data only.
 * All filtering (B1–B6 bandpass, N1–N8 notch, M1–M13 MAS) is applied
 * offline in MATLAB during Phase 2 and Phase 3 evaluation.
 */

/* ═══════════════════════════════════════════════════════════════════════════
   MODE SELECTION
   ═══════════════════════════════════════════════════════════════════════════
   Change PHASE1_MODE and rebuild. See file header for full timing analysis.

   PHASE1_ECG_ONLY  —  true 500 Hz, 3 fields, 18% baud load
                        Use for: Phase 2 offline filter analysis (B1–B6, N1–N8)
                        Baud budget: 500 Hz × 18 B = 9 000 B/s (18% of 50 000)

   PHASE1_ECG_IMU   —  effective 250 Hz, 20 fields, 72% baud load
                        Use for: Phase 3 offline MAS evaluation (M1–M13)
                        Effective rate: PRINTF (2.88 ms) > tick (2 ms) → catch-up
                        fires each iteration → effective period = 4 ms = 250 Hz.
                        Baud budget: 250 Hz × 144 B = 36 000 B/s (72% of 50 000)
   ═══════════════════════════════════════════════════════════════════════════ */

#define PHASE1_ECG_ONLY   (1)
#define PHASE1_ECG_IMU    (2)

#define PHASE1_MODE       PHASE1_ECG_IMU    /* ← change here and rebuild */

#if (PHASE1_MODE != PHASE1_ECG_ONLY) && (PHASE1_MODE != PHASE1_ECG_IMU)
    #error "PHASE1_MODE must be PHASE1_ECG_ONLY or PHASE1_ECG_IMU"
#endif

/* ═══════════════════════════════════════════════════════════════════════════
   TIMING CONSTANTS
   ═══════════════════════════════════════════════════════════════════════════
   DECIM=1 in both modes: print on every ADC tick.

   In ECG_ONLY mode: PRINTF (18 B at 500 kbaud) = 0.36 ms << 2 ms tick.
   No catch-up fires. True 500 Hz output.

   In ECG_IMU mode: PRINTF (~144 B at 500 kbaud) = 2.88 ms > 2 ms tick.
   Catch-up fires every iteration, advancing next_tick by 1 extra step.
   Effective period = 2 × 2 ms = 4 ms. Effective output rate = 250 Hz.
   The DWT timestamps record the exact moment of each ADC conversion, so
   MATLAB recovers the true (non-uniform) sample times via t_s = t_us/1e6.
   Using actual timestamps rather than assuming a fixed rate is the correct
   approach when the inter-sample interval is not guaranteed to be uniform.
   ═══════════════════════════════════════════════════════════════════════════ */
#define PHASE1_DECIM   (1U)

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
    ECGADC_Init();

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
     * The blocking retry loop below requires all three IMU sites (LA, RA, RL)
     * to be confirmed before recording begins. Recording with a missing IMU
     * site would invalidate the multi-site vs single-site paired comparisons
     * (M1vsM2, M3vsM4, M5vsM6) that are the core experimental contribution
     * of this thesis. A partial dataset is scientifically worthless here.
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

#if (PHASE1_MODE == PHASE1_ECG_IMU)
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

            PRINTF("[PHASE1] IMU0(LA)=%s  IMU1(RA)=%s  IMU2(RL)=%s\r\n",
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
        PRINTF("[PHASE1]   IMU0 CS -> D10 (LPSPI1_PCS0) -> Left Arm\r\n");
        PRINTF("[PHASE1]   IMU1 CS -> D4  (LPSPI1_PCS1) -> Right Arm\r\n");
        PRINTF("[PHASE1]   IMU2 CS -> D0  (LPSPI1_PCS2) -> Right Leg\r\n");
        PRINTF("[PHASE1] Retrying in 2 seconds...\r\n\r\n");
        SDK_DelayAtLeastUs(2000000U, SystemCoreClock);
    }

#else   /* PHASE1_ECG_ONLY — IMU not needed in stream but verify at boot */
    PRINTF("[PHASE1] ECG_ONLY mode — verifying IMU hardware at boot...\r\n");
    (void)IMU_InitAll();   /* result not checked — IMU unused in stream */
    PRINTF("[PHASE1] IMU check done (IMU data not recorded in this mode).\r\n\r\n");
#endif

    /* ── Configuration summary ──────────────────────────────────────────── */
    PRINTF("[PHASE1] =============================================\r\n");

#if (PHASE1_MODE == PHASE1_ECG_ONLY)
    PRINTF("[PHASE1]  Mode      : ECG_ONLY (Phase 2 filter analysis)\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ecg_corr  (3 fields)\r\n");
    PRINTF("[PHASE1]  Rate      : 500 Hz true  (PRINTF 0.36 ms << 2 ms tick)\r\n");
    PRINTF("[PHASE1]  Baud load : ~9000 B/s  (18%% of 50000 B/s ceiling)\r\n");
    PRINTF("[PHASE1]  Nyquist   : 250 Hz >> 40 Hz passband  (6.25x margin)\r\n");
    PRINTF("[PHASE1]  Use for   : B1-B6 bandpass + N1-N8 notch evaluation\r\n");
#else
    PRINTF("[PHASE1]  Mode      : ECG_IMU (Phase 3 MAS analysis)\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ecg_corr, 3x(ax,ay,az,gx,gy,gz) = 20\r\n");
    PRINTF("[PHASE1]  Rate      : ~250 Hz effective (PRINTF 2.88 ms > 2 ms tick)\r\n");
    PRINTF("[PHASE1]             Catch-up fires each iteration -> 4 ms period.\r\n");
    PRINTF("[PHASE1]             Actual Fs confirmed via t_us timestamps.\r\n");
    PRINTF("[PHASE1]  Baud load : ~36000 B/s  (72%% of 50000 B/s ceiling)\r\n");
    PRINTF("[PHASE1]  Nyquist   : 125 Hz >> 40 Hz passband  (3.1x margin)\r\n");
    PRINTF("[PHASE1]  IMU data  : RAW int16 register values (Kalman bypassed)\r\n");
    PRINTF("[PHASE1]             Accel: /16384 -> g-units\r\n");
    PRINTF("[PHASE1]             Gyro : /131   -> deg/s\r\n");
    PRINTF("[PHASE1]  IMU sites : IMU0=Left Arm  IMU1=Right Arm  IMU2=Right Leg\r\n");
    PRINTF("[PHASE1]  Use for   : M1-M13 MAS algorithm evaluation\r\n");
    PRINTF("[PHASE1]             (includes M9-M13 gyro-augmented algorithms)\r\n");
#endif

    PRINTF("[PHASE1] =============================================\r\n");
    PRINTF("[PHASE1]  Baud rate : 500000  (confirm ecg_monitor.py matches)\r\n");
    PRINTF("[PHASE1]  MATLAB    : data = readmatrix('file.txt')\r\n");
    PRINTF("[PHASE1]             t_s  = data(:,1)/1e6\r\n");
    PRINTF("[PHASE1]             ecg  = data(:,2)*(1800/4096)\r\n");
    PRINTF("[PHASE1] =============================================\r\n\r\n");

    /* ── CSV header ─────────────────────────────────────────────────────── */
    /*
     * The header is emitted once. MATLAB's readmatrix() automatically skips
     * non-numeric lines (boot messages and this header), so no manual parsing
     * is required on the MATLAB side.
     */
#if (PHASE1_MODE == PHASE1_ECG_ONLY)
    PRINTF("t_us,ecg_corr\r\n");
#else
    PRINTF("t_us,ecg_corr,"
           "ax0,ay0,az0,gx0,gy0,gz0,"
           "ax1,ay1,az1,gx1,gy1,gz1,"
           "ax2,ay2,az2,gx2,gy2,gz2\r\n");
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
     * ECG_ONLY mode (PRINTF 0.36 ms, tick 2 ms):
     *   Work per tick << tick period. No catch-up fires. True 500 Hz.
     *
     * ECG_IMU mode (PRINTF 2.88 ms, tick 2 ms):
     *   Work per tick > tick period. After PRINTF completes (~3.24 ms after
     *   tick start), DWT->CYCCNT has passed next_tick by ~1.24 ms. The
     *   catch-up guard advances next_tick by one step (2 ms), bringing the
     *   new deadline to ~4 ms after tick start. The next wait_until_cycle()
     *   call therefore completes almost immediately (~0.76 ms later), making
     *   the effective iteration period 4 ms = 250 Hz.
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

#if (PHASE1_MODE == PHASE1_ECG_IMU)
    imu_raw_t imu_raw[IMU_COUNT];
    memset(imu_raw, 0, sizeof(imu_raw));
#endif

    while (1)
    {
        wait_until_cycle(next_tick);
        next_tick += step;

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
         * ECG ADC: ECGADC_ReadBoth() fires a chained LPADC conversion:
         *   Software trigger → CMD1 (ch0, AD8233 OUTPUT) →
         *                      CMD2 (ch1, AD8233 REFOUT) → FIFO
         * Both results land in the FIFO in order [ecg_raw, ref_raw].
         * Spin-wait timeout: 500 µs (see ecg_adc.c). On timeout, returns
         * false and both values remain 0. The zero entry is still recorded
         * so array indices stay aligned with timestamps; MATLAB identifies
         * dropped samples as zero-amplitude entries at the expected time.
         *
         * DC correction: ecg_corr = ecg_raw − ref_raw removes the REFOUT
         * common-mode DC bias. REFOUT buffers REFIN, which is set by an
         * external 3.3 V → 5 kΩ pot + 2.2 kΩ divider for a tuneable
         * baseline, so its DC value is setup-dependent. The differential
         * subtraction removes it whatever its value (AD8233 datasheet
         * §THEORY OF OPERATION). Signed subtraction into int16_t: the 12-bit
         * unsigned values are in [0, 4095], so the difference is in
         * [−4095, +4095], fitting int16_t without overflow.
         */
        uint16_t ecg_raw = 0U, ref_raw = 0U;
        (void)ECGADC_ReadBoth(&ecg_raw, &ref_raw);
        const int16_t ecg_corr = (int16_t)((int32_t)ecg_raw - (int32_t)ref_raw);

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
            PRINTF("%u,%d\r\n",
                   (unsigned)t_us,
                   (int)ecg_corr);

#else   /* PHASE1_ECG_IMU — all 20 fields */
            PRINTF("%u,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d\r\n",
                   (unsigned)t_us,
                   (int)ecg_corr,
                   /* IMU0 — Left Arm electrode site */
                   (int)imu_raw[0].ax, (int)imu_raw[0].ay, (int)imu_raw[0].az,
                   (int)imu_raw[0].gx, (int)imu_raw[0].gy, (int)imu_raw[0].gz,
                   /* IMU1 — Right Arm electrode site */
                   (int)imu_raw[1].ax, (int)imu_raw[1].ay, (int)imu_raw[1].az,
                   (int)imu_raw[1].gx, (int)imu_raw[1].gy, (int)imu_raw[1].gz,
                   /* IMU2 — Right Leg / drive electrode site */
                   (int)imu_raw[2].ax, (int)imu_raw[2].ay, (int)imu_raw[2].az,
                   (int)imu_raw[2].gx, (int)imu_raw[2].gy, (int)imu_raw[2].gz);
#endif
        }

        seq++;

        /*
         * Catch-up guard: if the loop body (ADC + IMU + PRINTF) took longer
         * than one step, advance next_tick until it is back in the future.
         * In ECG_IMU mode this fires every iteration (PRINTF 2.88 ms > 2 ms
         * tick), advancing next_tick by exactly one step and producing an
         * effective 4 ms iteration period. In ECG_ONLY mode this should never
         * fire under normal operation; if it does, the corresponding timestamp
         * gap will appear in MATLAB's diff(t_s) for quality inspection.
         */
        if ((int32_t)(DWT->CYCCNT - next_tick) > 0)
        {
            do { next_tick += step; }
            while ((int32_t)(DWT->CYCCNT - next_tick) > 0);
        }
    }
}
