/*
 * imu_manager.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       MPU6500 IMU manager — 3-device interface
 * DATE:        28/03/2026
 * REVISED:     10/04/2026  — added imu_raw_t and IMU_ReadAllRaw() for Phase 1
 *
 * SUMMARY:
 *      Three MPU6500 on LPSPI1 using hardware PCS0/PCS1/PCS2.
 *        IMU 0 - CS0: J10[6] - LPSPI1 PCS0 - LL
 *        IMU 1 - CS1: J9[5]  - LPSPI1 PCS1 - LA
 *        IMU 2 - CS2: J9[1]  - LPSPI1 PCS2 - RA
 *
 *      IMU_InitAll() initialises LPSPI1 once on PCS0, clones the handle
 *      for PCS1/PCS2, then configures each device independently. Revised
 *      10/04/2026 to include device soft-reset (PWR_MGMT_1=0x80, 100 ms
 *      settle, PS-MPU-6500A-01 §4.23) and WHO_AM_I retry loop (up to 5
 *      attempts, 20 ms apart) to fix intermittent initialisation failures.
 *
 * TWO READ INTERFACES
 * ───────────────────
 *
 * IMU_ReadAll() — Kalman-filtered float output (Phase 4 real-time use)
 *   Returns per-axis scalar Kalman filter output (Q=0.10, R=4.00).
 *   Effective bandwidth: ~11 Hz. Used by the real-time MAS algorithms in
 *   Phase 4 firmware where smooth weight convergence is preferred over
 *   high-frequency fidelity.
 *
 * IMU_ReadAllRaw() — Raw int16 register values (Phase 1 recording use)
 *   Returns the raw 16-bit two's-complement register values from
 *   ACCEL_XOUT and GYRO_XOUT registers directly, without any filtering.
 *   Hardware DLPF bandwidth: 92 Hz (DLPF_CFG=2, MPU-6500 RM Table 3).
 *   Preserves the full motion artefact spectrum up to the hardware DLPF
 *   cutoff (92 Hz at DLPF_CFG=2) for Phase 3 MAS algorithm evaluation.
 *   The Kalman filter's ~11 Hz
 *   bandwidth (steady-state K≈0.14 at Fs=500 Hz) would attenuate the
 *   upper end of the ~6.5–13 Hz ambulance engine/tyre vibration band
 *   (Partridge 2016/2021; Gao 2026; Kosek 2021), required for offline
 *   gyroscope-augmented MAS evaluation.
 *
 * REFERENCES:
 *      MPU-6500 Register Map RM-MPU-6500A-00 Rev 2.1, InvenSense 2013
 *      PS-MPU-6500A-01 §3.1 (noise floor), §4.23 (startup timing)
 *      Ambulance vibration bands — ~1.5–2 Hz (suspension) + ~6.5–13 Hz
 *                            (engine/tyre), overall ~1–30 Hz (Partridge
 *                            2016/2021; Gao 2026; Kosek 2021). ISO 2631-1:1997
 *                            §5 provides whole-body vibration weighting curves
 *                            for vehicle-borne exposure but does not define
 *                            an ambulance-specific spectrum.
 *      Beach et al., Healthcare Technology Letters, 2021 (PMC8450177)
 *      Ma et al., Rev. Sci. Instrum. 95(1), 2024
 */

#ifndef IMU_MANAGER_H
#define IMU_MANAGER_H

#include <stdint.h>
#include <stdbool.h>

#define IMU_COUNT (3U)

/* ── Kalman-filtered output (Phase 4 real-time MAS) ─────────────────────────
 *
 * Fields ax/ay/az are in raw LSB units at ±2 g scale (16384 LSB/g).
 * Fields gx/gy/gz are in raw LSB units at ±250°/s scale (131 LSB/°/s).
 * Values are float32 because the Kalman filter state is float32 internally.
 * The valid flag is false if the device did not respond during IMU_InitAll().
 */
typedef struct
{
    float ax, ay, az;   /* accelerometer LSB (±2 g,    16384 LSB/g)  */
    float gx, gy, gz;   /* gyroscope    LSB (±250°/s,  131  LSB/°/s) */
    bool  valid;
} imu_data_t;

/* ── Raw register output (Phase 1 recording) ─────────────────────────────────
 *
 * Fields are the raw two's-complement 16-bit values read directly from the
 * MPU-6500 ACCEL_XOUT_H/L and GYRO_XOUT_H/L registers with no filtering.
 * Hardware DLPF cutoff: 92 Hz at DLPF_CFG=2 (MPU-6500 RM Table 3).
 *
 * Scale factors for MATLAB conversion (MPU-6500 RM §4.2, §4.4):
 *   Accelerometer: int16 / 16384  → g-units      (FS_SEL=0, ±2 g)
 *   Gyroscope:     int16 / 131    → degrees/sec  (FS_SEL=0, ±250°/s)
 *
 * The valid flag is false if the device did not respond during IMU_InitAll().
 * Invalid devices return all-zero fields, producing clean zero CSV columns.
 */
typedef struct
{
    int16_t ax, ay, az;   /* raw accelerometer register values, LSB */
    int16_t gx, gy, gz;   /* raw gyroscope    register values, LSB  */
    bool    valid;
} imu_raw_t;

/* ─────────────────────────────────────────────────────────────────────────────
   PUBLIC API
   ───────────────────────────────────────────────────────────────────────────── */

/*
 * IMU_InitAll — Initialise LPSPI1 and configure all three MPU-6500 devices.
 *
 * Performs for each device:
 *   1. Soft reset via PWR_MGMT_1 = 0x80, 100 ms settle (PS-MPU-6500A-01 §4.23)
 *   2. WHO_AM_I check with up to 5 retries, 20 ms apart (expected: 0x70)
 *   3. DLPF_CFG=2 (92 Hz bandwidth), accel ±2 g, gyro ±250°/s, ODR=500 Hz
 *   4. First-sample read with acceleration magnitude check and Kalman seed
 *
 * Returns true if at least one device responds. Non-responding devices are
 * flagged invalid and return zero data from all read functions.
 */
bool IMU_InitAll(void);

/*
 * IMU_ReadAll — Read all three IMUs with per-axis Kalman filtering.
 *
 * Writes Kalman-filtered float values (LSB units) to out[0..IMU_COUNT-1].
 * Kalman parameters: Q=0.10, R=4.00. Effective bandwidth: ~11 Hz at 500 Hz.
 * Use in Phase 4 real-time firmware for smooth MAS adaptive filter operation.
 */
void IMU_ReadAll(imu_data_t out[IMU_COUNT]);

/*
 * IMU_ReadAllRaw — Read all three IMUs returning raw int16 register values.
 *
 * Writes raw register values directly to out[0..IMU_COUNT-1] without any
 * filtering. Hardware DLPF bandwidth: 92 Hz at DLPF_CFG=2.
 * Use in Phase 1 firmware for unfiltered data recording, preserving the full
 * ambulance vibration spectrum for Phase 3 offline MAS analysis.
 *
 * Invalid devices (valid=false after IMU_InitAll) write zeros to all fields.
 */
void IMU_ReadAllRaw(imu_raw_t out[IMU_COUNT]);

#endif /* IMU_MANAGER_H */
