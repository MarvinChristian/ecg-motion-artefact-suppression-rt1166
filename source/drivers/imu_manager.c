/*
 * imu_manager.c
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       MPU6500 IMU manager — 3-device implementation
 * DATE:        28/03/2026
 * REVISED:     10/04/2026  — device reset + WHO_AM_I retry (intermittent fix)
 *              10/04/2026  — added IMU_ReadAllRaw() for Phase 1 raw recording
 *
 * SUMMARY:
 *      Three MPU6500 on shared LPSPI1.
 *
 *      Init strategy:
 *        1. Call MPU6500_SPI_InitMode() for IMU0 on PCS0 — this calls
 *           LPSPI_MasterInit() once to configure the peripheral.
 *        2. Clone the handle into IMU1 and IMU2, changing only whichPcs
 *           and pcsFlags. LPSPI_MasterInit() is NOT called again — calling
 *           it a second time resets the peripheral and breaks all devices.
 *        3. Configure each device independently over SPI.
 *
 *      Two read interfaces are provided:
 *
 *        IMU_ReadAll()    — Kalman-filtered float output. Used by Phase 4
 *                           real-time MAS firmware where smooth adaptive
 *                           filter weight convergence is preferred.
 *                           Effective bandwidth: ~11 Hz (K≈0.14 at 500 Hz).
 *
 *        IMU_ReadAllRaw() — Raw int16_t register values, no filtering.
 *                           Used by Phase 1 recording firmware to preserve
 *                           the full IMU hardware bandwidth (92 Hz at
 *                           DLPF_CFG=2) for Phase 3 offline MAS evaluation.
 *                           The Kalman ~11 Hz cutoff would attenuate the
 *                           upper end of the ~6.5–13 Hz engine/tyre vibration
 *                           band (Partridge 2016/2021; Gao 2026), which is
 *                           required for gyroscope-augmented MAS algorithms
 *                           M9–M13 (Beach et al., Healthcare Technology
 *                           Letters, 2021, PMC8450177; Ma et al., Rev. Sci.
 *                           Instrum., 2024).
 *
 * REVISION NOTES (10/04/2026):
 *      Intermittent IMU failures traced to two causes:
 *
 *      (1) No device reset before configuration.
 *          PWR_MGMT_1 bit 7 (DEVICE_RESET) must be asserted and 100 ms
 *          allowed for oscillator stabilisation after a firmware reset
 *          without power cycling (PS-MPU-6500A-01 §4.23). Without this,
 *          register state from the previous session causes non-deterministic
 *          WHO_AM_I mismatches and configuration write failures.
 *
 *      (2) Single-attempt WHO_AM_I with no retry.
 *          The first SPI transaction after LPSPI_MasterInit() can fail
 *          transiently (TCR PCS latch not settled, or PCS glitch at startup).
 *          Up to 5 retries with 20 ms inter-attempt delay resolve transient
 *          failures while still correctly detecting absent devices (0xFF =
 *          MISO floating; no retry needed — wiring issue).
 *
 * REFERENCES:
 *      PS-MPU-6500A-01 — MPU-6500 Product Spec §3.1, §4.23
 *      RM-MPU-6500A-00 Rev 2.1 — MPU-6500 Register Map §3.1, §4.1, §4.2, §4.4
 *      Beach et al., Healthcare Technology Letters 2021 (PMC8450177)
 *      Ma et al., Rev. Sci. Instrum. 95(1), 2024
 *      Ambulance vibration bands — ~1.5–2 Hz (suspension) + ~6.5–13 Hz
 *                           (engine/tyre), overall ~1–30 Hz (Partridge
 *                           2016/2021; Gao 2026; Kosek 2021). ISO 2631-1:1997
 *                           §5 supplies whole-body vibration weighting curves
 *                           for vehicle-borne exposure but does not define
 *                           an ambulance-specific spectrum.
 */

#include "drivers/imu_manager.h"
#include "drivers/mpu6500_spi.h"
#include "dsp/kalman1d.h"
#include "app_config_phase1.h"

#include <math.h>
#include "fsl_clock.h"
#include "fsl_common.h"
#include "fsl_debug_console.h"

/* ── Kalman filter parameters (Phase 4 use via IMU_ReadAll) ─────────────────
 *
 * Q = process noise variance: how much the true IMU reading changes per sample.
 * R = measurement noise variance: how noisy the raw register value is.
 * P0 = initial error covariance (large value = fast initial convergence).
 *
 * Steady-state Kalman gain: K ≈ sqrt(Q/R) / (1 + sqrt(Q/R)) ≈ 0.14
 * Effective bandwidth: K × Fs / (2π) ≈ 0.14 × 500 / 6.283 ≈ 11 Hz.
 * This is suitable for smooth adaptive filter weight updates in Phase 4
 * but attenuates the upper end of the ~6.5–13 Hz ambulance engine/tyre
 * vibration band — hence IMU_ReadAllRaw() bypasses the Kalman for Phase 1
 * recording.
 * ─────────────────────────────────────────────────────────────────────────── */
#define KF_Q    (0.10f)
#define KF_R    (4.00f)
#define KF_P0   (10.0f)

/* ── MPU-6500 configuration constants ────────────────────────────────────────
 *
 * DLPF_CFG = 2: Digital Low-Pass Filter configuration register value.
 *   At FS_SEL=0 (gyro ±250°/s, internal clock 1 kHz) and DLPF_CFG=2:
 *   accel bandwidth = 92 Hz, gyro bandwidth = 92 Hz (RM Table 3).
 *   This preserves the ambulance vibration range (~1–30 Hz; Partridge
 *   2016/2021, Gao 2026, Kosek 2021) with >3× margin, while rejecting
 *   high-frequency quantisation noise.
 *
 * SMPLRT_DIV = 1: Sample rate divider.
 *   ODR = 1000 / (1 + SMPLRT_DIV) = 1000/2 = 500 Hz (RM §4.19).
 *   Matches the ECG ADC tick rate APP_ECG_FS_HZ = 500 Hz.
 * ─────────────────────────────────────────────────────────────────────────── */
#define IMU_DLPF_CFG    (2U)
#define IMU_SMPLRT_DIV  (1U)

/* ── Init retry/timing parameters (revised 10/04/2026) ─────────────────────
 *
 * IMU_RESET_DELAY_US = 100 ms: minimum oscillator stabilisation time after
 *   device reset (PS-MPU-6500A-01 §4.23, Table 1: "Start-Up Time for
 *   Register Read/Write from Power-Up" = 100 ms).
 *
 * IMU_PLL_SETTLE_US = 10 ms: settling time after writing PWR_MGMT_1 = 0x01
 *   (PLL clock source). RM §4.28 notes one gyro sample period is required
 *   for PLL lock; 10 ms provides 80× margin across temperature variation.
 *
 * IMU_WHOAMI_RETRIES = 5: maximum WHO_AM_I attempts before declaring absent.
 *   Empirically, transient LPSPI first-transaction failures resolve within
 *   1–2 retries. Five attempts add at most 100 ms per failing device.
 *
 * IMU_WHOAMI_RETRY_DELAY_US = 20 ms: inter-attempt pause giving the LPSPI
 *   peripheral and MPU-6500 SPI state machine time to settle.
 * ─────────────────────────────────────────────────────────────────────────── */
#define IMU_RESET_DELAY_US          (100000U)
#define IMU_PLL_SETTLE_US           (10000U)
#define IMU_WHOAMI_RETRIES          (5U)
#define IMU_WHOAMI_RETRY_DELAY_US   (20000U)

/* ── Per-device state (file-scope, not exposed to callers) ──────────────────
 *
 * Keeping this static ensures callers interact only through IMU_ReadAll() and
 * IMU_ReadAllRaw() — no direct register access from outside this module.
 * ─────────────────────────────────────────────────────────────────────────── */
typedef struct
{
    mpu6500_t   dev;
    bool        present;
    kalman1d_t  kf_ax, kf_ay, kf_az;
    kalman1d_t  kf_gx, kf_gy, kf_gz;
} imu_slot_t;

static imu_slot_t g_imu[IMU_COUNT];

/* ── Big-endian 16-bit reconstruction ───────────────────────────────────────
 *
 * MPU-6500 stores all sensor data high-byte first (big-endian, RM §4.1).
 * This helper reconstructs a signed int16_t from two consecutive bytes.
 * ─────────────────────────────────────────────────────────────────────────── */
static inline int16_t be16(const uint8_t *p)
{
    return (int16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

/* ═══════════════════════════════════════════════════════════════════════════
   INTERNAL: imu_configure — configure one device
   ═══════════════════════════════════════════════════════════════════════════ */
static bool imu_configure(imu_slot_t *s, uint32_t idx)
{
    /* Step A: device reset ───────────────────────────────────────────────────
     *
     * Writing 0x80 to PWR_MGMT_1 asserts DEVICE_RESET, returning all internal
     * registers to power-on defaults and restarting the internal oscillator.
     * This guarantees a known state regardless of whether the IMU supply was
     * power-cycled or only the MCU was soft-reset (PS-MPU-6500A-01 §4.23).
     * The self-clearing reset bit requires 100 ms to complete.
     * ─────────────────────────────────────────────────────────────────────── */
    PRINTF("[IMU%u] Resetting device (100 ms)...\r\n", (unsigned)idx);
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_PWR_MGMT_1, 0x80U)
        != kStatus_Success)
    {
        PRINTF("[IMU%u] Reset write FAILED — device likely absent\r\n",
               (unsigned)idx);
        return false;
    }
    SDK_DelayAtLeastUs(IMU_RESET_DELAY_US, SystemCoreClock);

    /* Step B: WHO_AM_I with retry ────────────────────────────────────────────
     *
     * Retrying up to IMU_WHOAMI_RETRIES times resolves transient LPSPI
     * first-transaction failures. 0xFF = MISO floating (wiring problem);
     * return immediately without retrying since SPI resets won't help.
     * ─────────────────────────────────────────────────────────────────────── */
    uint8_t who    = 0x00U;
    bool    who_ok = false;

    for (uint32_t attempt = 0U; attempt < IMU_WHOAMI_RETRIES; attempt++)
    {
        status_t st = MPU6500_ReadWhoAmI(&s->dev, &who);

        if (st == kStatus_Success)
        {
            PRINTF("[IMU%u] WHO_AM_I = 0x%02X  (attempt %u, expected 0x70)\r\n",
                   (unsigned)idx, who, (unsigned)(attempt + 1U));

            if (who == MPU_WHO_AM_I_MPU6500)
            {
                who_ok = true;
                break;
            }

            if (who == 0xFFU)
            {
                PRINTF("[IMU%u] 0xFF = MISO floating — check pin_mux LPSPI1_PCS%u\r\n",
                       (unsigned)idx, (unsigned)idx);
                return false;
            }

            PRINTF("[IMU%u] ID mismatch (0x%02X) — retrying in 20 ms\r\n",
                   (unsigned)idx, who);
        }
        else
        {
            PRINTF("[IMU%u] WHO_AM_I SPI error on attempt %u\r\n",
                   (unsigned)idx, (unsigned)(attempt + 1U));
        }

        SDK_DelayAtLeastUs(IMU_WHOAMI_RETRY_DELAY_US, SystemCoreClock);
    }

    if (!who_ok)
    {
        PRINTF("[IMU%u] WHO_AM_I failed after %u attempts\r\n",
               (unsigned)idx, (unsigned)IMU_WHOAMI_RETRIES);
        return false;
    }

    /* Step C: wake up and select PLL clock source ────────────────────────────
     *
     * After reset, PWR_MGMT_1 = 0x40 (sleep mode, internal 8 MHz oscillator).
     * Writing 0x01 exits sleep and selects the gyroscope X-axis PLL, which
     * provides lower jitter and better temperature stability than the internal
     * oscillator (PS-MPU-6500A-01 §4.4, RM §4.28).
     * ─────────────────────────────────────────────────────────────────────── */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_PWR_MGMT_1, 0x01U)
        != kStatus_Success) { return false; }
    SDK_DelayAtLeastUs(IMU_PLL_SETTLE_US, SystemCoreClock);

    /* Enable all axes */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_PWR_MGMT_2, 0x00U)
        != kStatus_Success) { return false; }

    /* SPI-only mode — disable I2C interface to prevent I2C bus contention */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_USER_CTRL,
                          MPU6500_USER_CTRL_I2C_IF_DIS_MASK)
        != kStatus_Success) { return false; }

    /* Gyro ±250°/s, DLPF enabled (FS_SEL=0 with FCHOICE_B=00) */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_GYRO_CONFIG, 0x00U)
        != kStatus_Success) { return false; }

    /* DLPF_CFG=2: 92 Hz bandwidth for both accel and gyro (RM Table 3).
       Preserves the ambulance vibration range (~1–30 Hz; Partridge 2016/2021,
       Gao 2026, Kosek 2021) with >3× margin while rejecting high-frequency
       quantisation noise. */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_CONFIG,
                          (uint8_t)IMU_DLPF_CFG)
        != kStatus_Success) { return false; }

    /* Accel ±2 g (FS_SEL=0): 16384 LSB/g resolution (RM §4.2) */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_ACCEL_CONFIG, 0x00U)
        != kStatus_Success) { return false; }

    /* Accel DLPF: same 92 Hz cutoff as gyro */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_ACCEL_CONFIG2,
                          (uint8_t)IMU_DLPF_CFG)
        != kStatus_Success) { return false; }

    /* ODR = 1000 / (1 + SMPLRT_DIV) = 1000/2 = 500 Hz.
       Matches APP_ECG_FS_HZ so every ECG sample has a co-temporal IMU sample
       available without interpolation (RM §4.19 — SMPLRT_DIV register). */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_SMPLRT_DIV,
                          (uint8_t)IMU_SMPLRT_DIV)
        != kStatus_Success) { return false; }

    /* First-sample sanity check: verify |a| ≈ 1 g = 16384 LSB at rest */
    uint8_t buf[14];
    if (MPU6500_ReadBytes(&s->dev, MPU6500_REG_ACCEL_XOUT_H, buf, 14U)
        != kStatus_Success) { return false; }

    int16_t rax = be16(&buf[0]);
    int16_t ray = be16(&buf[2]);
    int16_t raz = be16(&buf[4]);
    float mag = sqrtf((float)rax*(float)rax +
                      (float)ray*(float)ray +
                      (float)raz*(float)raz);

    PRINTF("[IMU%u] ax=%6d ay=%6d az=%6d |a|=%.0f (expect ~16384)\r\n",
           (unsigned)idx, (int)rax, (int)ray, (int)raz, (double)mag);

    if (mag < 8000.0f || mag > 25000.0f)
    {
        PRINTF("[IMU%u] WARNING: magnitude outside 0.5–1.5 g — check mounting\r\n",
               (unsigned)idx);
    }

    /* Seed Kalman filter state with the first real measurement so Phase 4
       MAS filter weights start from a physically meaningful initial estimate
       rather than from zero (which would cause a large initial weight transient). */
    Kalman1D_Init(&s->kf_ax, KF_Q, KF_R, KF_P0, (float)rax);
    Kalman1D_Init(&s->kf_ay, KF_Q, KF_R, KF_P0, (float)ray);
    Kalman1D_Init(&s->kf_az, KF_Q, KF_R, KF_P0, (float)raz);
    Kalman1D_Init(&s->kf_gx, KF_Q, KF_R, KF_P0, (float)be16(&buf[8]));
    Kalman1D_Init(&s->kf_gy, KF_Q, KF_R, KF_P0, (float)be16(&buf[10]));
    Kalman1D_Init(&s->kf_gz, KF_Q, KF_R, KF_P0, (float)be16(&buf[12]));

    PRINTF("[IMU%u] config OK\r\n", (unsigned)idx);
    return true;
}

/* ═══════════════════════════════════════════════════════════════════════════
   IMU_InitAll
   ═══════════════════════════════════════════════════════════════════════════ */
bool IMU_InitAll(void)
{
    PRINTF("\r\n[IMU] === 3-device init start ===\r\n");

#if defined(kCLOCK_Lpspi1)
    CLOCK_EnableClock(kCLOCK_Lpspi1);
#endif

    for (uint32_t i = 0U; i < IMU_COUNT; i++)
    {
        g_imu[i].present = false;
    }

    /* Initialise LPSPI1 once on IMU0/PCS0. Do NOT call LPSPI_MasterInit()
       again for IMU1 or IMU2 — it resets the peripheral and breaks all three
       devices simultaneously. Handles for IMU1/IMU2 are cloned below. */
    status_t st = MPU6500_SPI_InitMode(
        &g_imu[0].dev, LPSPI1,
        APP_IMU_SPI_SRC_CLOCK_HZ, APP_IMU_SPI_BAUD_HZ,
        kLPSPI_Pcs0, kLPSPI_MasterPcs0, MPU6500_SPI_MODE3);

    if (st != kStatus_Success)
    {
        PRINTF("[IMU] LPSPI_MasterInit FAILED\r\n");
        return false;
    }
    PRINTF("[IMU] LPSPI1 init OK\r\n");

    /* Clone handle — only PCS identifiers change; base, clocks, SPI mode
       are identical for all three devices on the same bus. */
    g_imu[1].dev          = g_imu[0].dev;
    g_imu[1].dev.whichPcs = kLPSPI_Pcs1;
    g_imu[1].dev.pcsFlags = kLPSPI_MasterPcs1;

    g_imu[2].dev          = g_imu[0].dev;
    g_imu[2].dev.whichPcs = kLPSPI_Pcs2;
    g_imu[2].dev.pcsFlags = kLPSPI_MasterPcs2;

    /* 100 ms bus-settle delay before first SPI transaction */
    SDK_DelayAtLeastUs(100000U, SystemCoreClock);

    bool any_ok = false;
    for (uint32_t i = 0U; i < IMU_COUNT; i++)
    {
        if (imu_configure(&g_imu[i], i))
        {
            g_imu[i].present = true;
            any_ok = true;
        }
    }

    PRINTF("[IMU] === Init done: IMU0=%s  IMU1=%s  IMU2=%s ===\r\n\r\n",
           g_imu[0].present ? "OK" : "FAIL",
           g_imu[1].present ? "OK" : "FAIL",
           g_imu[2].present ? "OK" : "FAIL");

    return any_ok;
}

/* ═══════════════════════════════════════════════════════════════════════════
   IMU_ReadAll — Kalman-filtered float output (Phase 4 real-time MAS)
   ═══════════════════════════════════════════════════════════════════════════
   Reads 14 bytes per device and passes each axis through the per-axis scalar
   Kalman filter. Output is float32 in raw LSB units. Effective bandwidth
   ~10 Hz at 500 Hz sample rate (K≈0.127, see file header).

   Used by Phase 4 firmware (main.c) where smooth weight convergence is
   more important than preserving high-frequency IMU content.
   ═══════════════════════════════════════════════════════════════════════════ */
void IMU_ReadAll(imu_data_t out[IMU_COUNT])
{
    for (uint32_t i = 0U; i < IMU_COUNT; i++)
    {
        if (!g_imu[i].present)
        {
            out[i].ax = out[i].ay = out[i].az = 0.0f;
            out[i].gx = out[i].gy = out[i].gz = 0.0f;
            out[i].valid = false;
            continue;
        }

        uint8_t buf[14];
        if (MPU6500_ReadBytes(&g_imu[i].dev,
                               MPU6500_REG_ACCEL_XOUT_H,
                               buf, 14U) != kStatus_Success)
        {
            out[i].valid = false;
            continue;
        }

        out[i].ax = Kalman1D_Update(&g_imu[i].kf_ax, (float)be16(&buf[0]));
        out[i].ay = Kalman1D_Update(&g_imu[i].kf_ay, (float)be16(&buf[2]));
        out[i].az = Kalman1D_Update(&g_imu[i].kf_az, (float)be16(&buf[4]));
        /* buf[6:7] = TEMP_OUT — skipped, not used by any MAS algorithm */
        out[i].gx = Kalman1D_Update(&g_imu[i].kf_gx, (float)be16(&buf[8]));
        out[i].gy = Kalman1D_Update(&g_imu[i].kf_gy, (float)be16(&buf[10]));
        out[i].gz = Kalman1D_Update(&g_imu[i].kf_gz, (float)be16(&buf[12]));
        out[i].valid = true;
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
   IMU_ReadAllRaw — Raw int16 register output (Phase 1 recording)
   ═══════════════════════════════════════════════════════════════════════════
   Reads 14 bytes per device and returns the raw int16_t two's-complement
   values directly from the ACCEL_XOUT and GYRO_XOUT registers, bypassing
   the Kalman filter entirely. Hardware DLPF bandwidth: 92 Hz at DLPF_CFG=2.

   This is the correct interface for Phase 1 data collection because:
     - The Kalman filter (Q=0.10, R=4.00) has a steady-state bandwidth of
       ~11 Hz, attenuating the upper end of the ~6.5–13 Hz ambulance
       engine/tyre vibration band (Partridge 2016/2021; Gao 2026).
     - Ambulance vibration of concern extends to ~30 Hz overall (Kosek 2021).
     - Phase 3 gyroscope-augmented algorithms M9–M13 require full IMU
       bandwidth to evaluate gyroscope as a motion reference signal
       (Beach et al. 2021, PMC8450177, report a case-dependent result in
       which gyroscope filtering performs better for slow motion artefacts
       while accelerometer filtering performs better in other scenarios;
       full bandwidth is required to evaluate either reference in Phase 3).

   Scale factors for MATLAB (MPU-6500 RM-MPU-6500A-00 Rev 2.1):
     Accelerometer: int16 / 16384  → g-units    (FS_SEL=0, ±2 g)
     Gyroscope:     int16 / 131    → degrees/s  (FS_SEL=0, ±250°/s)

   Invalid devices write zeros to all fields and valid=false. This produces
   clean zero CSV columns rather than stale or uninitialised values.
   ═══════════════════════════════════════════════════════════════════════════ */
void IMU_ReadAllRaw(imu_raw_t out[IMU_COUNT])
{
    for (uint32_t i = 0U; i < IMU_COUNT; i++)
    {
        if (!g_imu[i].present)
        {
            out[i].ax = 0; out[i].ay = 0; out[i].az = 0;
            out[i].gx = 0; out[i].gy = 0; out[i].gz = 0;
            out[i].valid = false;
            continue;
        }

        uint8_t buf[14];
        if (MPU6500_ReadBytes(&g_imu[i].dev,
                               MPU6500_REG_ACCEL_XOUT_H,
                               buf, 14U) != kStatus_Success)
        {
            /* SPI read failed. The retry logic in mpu6500_spi.c
               (XFER_RETRY_COUNT=50, 20 µs apart) will have attempted
               recovery. If it still fails, the device is transiently
               unresponsive — zero output and flag invalid. */
            out[i].ax = 0; out[i].ay = 0; out[i].az = 0;
            out[i].gx = 0; out[i].gy = 0; out[i].gz = 0;
            out[i].valid = false;
            continue;
        }

        /* Parse big-endian register pairs (MPU-6500 RM §4.1).
           buf[6:7] = TEMP_OUT — temperature has no correlation with electrode
           motion and is not a useful MAS reference signal; skipped. */
        out[i].ax = be16(&buf[0]);
        out[i].ay = be16(&buf[2]);
        out[i].az = be16(&buf[4]);
        /* buf[6:7] skipped */
        out[i].gx = be16(&buf[8]);
        out[i].gy = be16(&buf[10]);
        out[i].gz = be16(&buf[12]);
        out[i].valid = true;
    }
}
