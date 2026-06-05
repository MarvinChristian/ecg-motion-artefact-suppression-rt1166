/*
 * kalman1d.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       1D scalar Kalman filter for IMU axis smoothing
 * DATE:        28/03/2026
 *
 * SUMMARY:
 *      Simple scalar (1-dimensional) Kalman filter used to smooth each
 *      individual axis of the MPU6500 accelerometer and gyroscope output.
 *
 *      Applied independently per axis (ax, ay, az, gx, gy, gz), treating
 *      each raw IMU reading as a noisy measurement of a slowly-changing
 *      true value. This is the minimum-complexity Kalman form: no state
 *      transition matrix, constant-velocity model assumed to be identity.
 *
 *      Predict step:  P = P + Q
 *      Update step:   K = P / (P + R)
 *                     x = x + K * (z - x)
 *                     P = (1 - K) * P
 *
 *      Q - process noise variance: how much the true value can change per
 *          sample. Smaller = smoother but slower to track motion.
 *      R - measurement noise variance: how noisy the raw sensor reading is.
 *          Larger = more smoothing, less responsive to real motion.
 */

#ifndef KALMAN1D_H
#define KALMAN1D_H

typedef struct
{
    float x;   /* current state estimate (filtered value)   */
    float p;   /* current error covariance                  */
    float q;   /* process noise variance                    */
    float r;   /* measurement noise variance                */
} kalman1d_t;

void  Kalman1D_Init  (kalman1d_t *k, float q, float r, float p0, float x0);
float Kalman1D_Update(kalman1d_t *k, float z);

#endif /* KALMAN1D_H */
