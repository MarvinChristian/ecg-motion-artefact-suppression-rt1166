/*
 * imu_manager.h
 *
 * Manager for three MPU-6500 IMUs on shared LPSPI1.
 *   IMU0 PCS0 J10[6] = LL
 *   IMU1 PCS1 J9[5]  = LA
 *   IMU2 PCS2 J9[1]  = RA
 *
 * Init: LPSPI_MasterInit once on PCS0, handle cloned for PCS1/PCS2.
 * Each device: soft-reset (PWR_MGMT_1=0x80, 100 ms settle), WHO_AM_I probe
 * with 5 retries (20 ms), DLPF_CFG=2 (92 Hz), +/-2 g, +/-250 dps, ODR=500 Hz.
 *
 * Refs: MPU-6500 RM Rev 2.1 (3.1, 4.1, 4.2, 4.4); PS-MPU-6500A-01 (3.1, 4.23).
 */

#ifndef IMU_MANAGER_H
#define IMU_MANAGER_H

#include <stdint.h>
#include <stdbool.h>

#define IMU_COUNT (3U)

/* Kalman-filtered output (Phase 4 path). Float for filter state.
 * Steady-state bandwidth ~11 Hz at Fs=500 Hz with Q=0.10, R=4.00. */
typedef struct
{
    float ax, ay, az;   /* accel LSB, 16384 LSB/g  */
    float gx, gy, gz;   /* gyro  LSB, 131 LSB/dps  */
    bool  valid;
} imu_data_t;

/* Raw int16 register values (Phase 1 recording). DLPF cutoff 92 Hz.
 * MATLAB: g = int16/16384, dps = int16/131. */
typedef struct
{
    int16_t ax, ay, az;
    int16_t gx, gy, gz;
    bool    valid;
} imu_raw_t;

/* Init LPSPI1 and configure all three IMUs. Returns true if any IMU
 * responded; non-responding devices are flagged invalid. */
bool IMU_InitAll(void);

/* Read all three IMUs through the per-axis Kalman filter. */
void IMU_ReadAll(imu_data_t out[IMU_COUNT]);

/* Read all three IMUs raw, no filtering. */
void IMU_ReadAllRaw(imu_raw_t out[IMU_COUNT]);

#endif /* IMU_MANAGER_H */
