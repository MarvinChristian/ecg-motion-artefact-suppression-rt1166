/*
 * kalman1d.c
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       1D scalar Kalman filter implementation
 * DATE:        28/03/2026
 */

#include "kalman1d.h"
#include <stddef.h>     /* NULL */

void Kalman1D_Init(kalman1d_t *k, float q, float r, float p0, float x0)
{
    if (k == NULL) { return; }
    k->q = q;
    k->r = r;
    k->p = p0;
    k->x = x0;
}

float Kalman1D_Update(kalman1d_t *k, float z)
{
    if (k == NULL) { return z; }

    /* Predict covariance one sample ahead. */
    k->p = k->p + k->q;

    /* Update estimate from the new measurement. */
    float s = k->p + k->r;
    float K = (s > 0.0f) ? (k->p / s) : 0.0f;

    k->x = k->x + K * (z - k->x);
    k->p = (1.0f - K) * k->p;

    return k->x;
}
