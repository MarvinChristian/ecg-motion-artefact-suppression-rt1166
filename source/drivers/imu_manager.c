/*
 * imu_manager.c
 *
 * Three MPU-6500 on shared LPSPI1. LPSPI_MasterInit is called once on PCS0;
 * the handle is cloned for PCS1/PCS2 (calling MasterInit again resets the
 * peripheral and breaks all CS lines).
 *
 * Per-device init: soft-reset (PWR_MGMT_1=0x80, 100 ms settle, RM 4.23),
 * WHO_AM_I probe with 5 retries (20 ms), DLPF_CFG=2 (92 Hz), +/-2 g,
 * +/-250 dps, ODR=500 Hz, magnitude check on first read.
 *
 * IMU_ReadAll returns Kalman-filtered float values for Phase 4.
 * IMU_ReadAllRaw returns int16 register values for Phase 1 recording.
 */

#include "drivers/imu_manager.h"
#include "drivers/mpu6500_spi.h"
#include "dsp/kalman1d.h"
#include "app_config_phase1.h"

#include <math.h>
#include "fsl_clock.h"
#include "fsl_common.h"
#include "fsl_debug_console.h"

/* Kalman params (Phase 4 path). K_ss = sqrt(Q/R)/(1+sqrt(Q/R)) ~= 0.14;
 * effective BW ~= K*Fs/(2*pi) ~= 11 Hz at Fs=500. */
#define KF_Q    (0.10f)
#define KF_R    (4.00f)
#define KF_P0   (10.0f)

/* DLPF_CFG=2: 92 Hz BW for accel and gyro (RM Table 3).
 * SMPLRT_DIV=1: ODR = 1000/(1+SMPLRT_DIV) = 500 Hz (RM 4.19). */
#define IMU_DLPF_CFG    (2U)
#define IMU_SMPLRT_DIV  (1U)

/* Reset settle: 100 ms (PS-MPU-6500A-01 4.23).
 * PLL settle: 10 ms after PWR_MGMT_1=0x01 (RM 4.28, >>1 gyro sample).
 * WHO_AM_I retry: 5 attempts, 20 ms apart. */
#define IMU_RESET_DELAY_US          (100000U)
#define IMU_PLL_SETTLE_US           (10000U)
#define IMU_WHOAMI_RETRIES          (5U)
#define IMU_WHOAMI_RETRY_DELAY_US   (20000U)

typedef struct
{
    mpu6500_t   dev;
    bool        present;
    kalman1d_t  kf_ax, kf_ay, kf_az;
    kalman1d_t  kf_gx, kf_gy, kf_gz;
} imu_slot_t;

static imu_slot_t g_imu[IMU_COUNT];

/* MPU-6500 is big-endian (RM 4.1). */
static inline int16_t be16(const uint8_t *p)
{
    return (int16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static bool imu_configure(imu_slot_t *s, uint32_t idx)
{
    /* Soft reset: PWR_MGMT_1 |= 0x80, 100 ms settle (RM 4.23). */
    PRINTF("[IMU%u] Resetting device (100 ms)...\r\n", (unsigned)idx);
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_PWR_MGMT_1, 0x80U)
        != kStatus_Success)
    {
        PRINTF("[IMU%u] Reset write FAILED - device likely absent\r\n",
               (unsigned)idx);
        return false;
    }
    SDK_DelayAtLeastUs(IMU_RESET_DELAY_US, SystemCoreClock);

    /* WHO_AM_I with retry. 0xFF = MISO floating -> fail fast, no retry. */
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
                PRINTF("[IMU%u] 0xFF = MISO floating - check pin_mux LPSPI1_PCS%u\r\n",
                       (unsigned)idx, (unsigned)idx);
                return false;
            }

            PRINTF("[IMU%u] ID mismatch (0x%02X) - retrying in 20 ms\r\n",
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

    /* Exit sleep, select gyro X PLL (lower jitter than internal osc, RM 4.28). */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_PWR_MGMT_1, 0x01U)
        != kStatus_Success) { return false; }
    SDK_DelayAtLeastUs(IMU_PLL_SETTLE_US, SystemCoreClock);

    /* Enable all axes */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_PWR_MGMT_2, 0x00U)
        != kStatus_Success) { return false; }

    /* SPI-only mode - disable I2C interface to prevent I2C bus contention */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_USER_CTRL,
                          MPU6500_USER_CTRL_I2C_IF_DIS_MASK)
        != kStatus_Success) { return false; }

    /* Gyro +/-250 deg/s, DLPF enabled (FS_SEL=0 with FCHOICE_B=00) */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_GYRO_CONFIG, 0x00U)
        != kStatus_Success) { return false; }

    /* DLPF_CFG=2: 92 Hz BW (RM Table 3). */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_CONFIG,
                          (uint8_t)IMU_DLPF_CFG)
        != kStatus_Success) { return false; }

    /* Accel +/-2 g (FS_SEL=0): 16384 LSB/g (RM 4.2). */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_ACCEL_CONFIG, 0x00U)
        != kStatus_Success) { return false; }

    /* Accel DLPF: 92 Hz to match gyro. */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_ACCEL_CONFIG2,
                          (uint8_t)IMU_DLPF_CFG)
        != kStatus_Success) { return false; }

    /* ODR = 1000/(1+SMPLRT_DIV) = 500 Hz; matches APP_ECG_FS_HZ. */
    if (MPU6500_WriteReg(&s->dev, MPU6500_REG_SMPLRT_DIV,
                          (uint8_t)IMU_SMPLRT_DIV)
        != kStatus_Success) { return false; }

    /* |a| ~= 16384 LSB at rest. */
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
        PRINTF("[IMU%u] WARNING: magnitude outside 0.5-1.5 g - check mounting\r\n",
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

/* Initialise the shared LPSPI1 bus once, then probe and configure each IMU. */
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

    /* Keep LPSPI_MasterInit on IMU0/PCS0 only. Calling it again for IMU1 or
       IMU2 resets the peripheral and breaks all three devices at once. */
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

    /* Clone handle; only PCS differs across devices. */
    g_imu[1].dev          = g_imu[0].dev;
    g_imu[1].dev.whichPcs = kLPSPI_Pcs1;
    g_imu[1].dev.pcsFlags = kLPSPI_MasterPcs1;

    g_imu[2].dev          = g_imu[0].dev;
    g_imu[2].dev.whichPcs = kLPSPI_Pcs2;
    g_imu[2].dev.pcsFlags = kLPSPI_MasterPcs2;

    /* 100 ms bus settle before first SPI transaction. */
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

/* IMU_ReadAll: Kalman-filtered output, used by Phase 4. */
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
        /* buf[6:7] = TEMP_OUT, skipped. */
        out[i].gx = Kalman1D_Update(&g_imu[i].kf_gx, (float)be16(&buf[8]));
        out[i].gy = Kalman1D_Update(&g_imu[i].kf_gy, (float)be16(&buf[10]));
        out[i].gz = Kalman1D_Update(&g_imu[i].kf_gz, (float)be16(&buf[12]));
        out[i].valid = true;
    }
}

/* IMU_ReadAllRaw: int16 register values, no filtering. Used by Phase 1
 * recording to keep the full 92 Hz DLPF bandwidth. */
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
            /* SPI failure after driver-level retries; zero out and flag. */
            out[i].ax = 0; out[i].ay = 0; out[i].az = 0;
            out[i].gx = 0; out[i].gy = 0; out[i].gz = 0;
            out[i].valid = false;
            continue;
        }

        /* Big-endian pairs (RM 4.1); buf[6:7] = TEMP_OUT, skipped. */
        out[i].ax = be16(&buf[0]);
        out[i].ay = be16(&buf[2]);
        out[i].az = be16(&buf[4]);
        out[i].gx = be16(&buf[8]);
        out[i].gy = be16(&buf[10]);
        out[i].gz = be16(&buf[12]);
        out[i].valid = true;
    }
}
