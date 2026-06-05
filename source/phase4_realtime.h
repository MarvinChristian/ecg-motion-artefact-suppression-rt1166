#ifndef PHASE4_REALTIME_H_
#define PHASE4_REALTIME_H_

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#include "drivers/imu_manager.h"
#include "mas_bag_classifier_ch1.h"
#include "mas_bag_classifier_ch2.h"

/* Two-stage decision (default on). The pooled usability model scores the
 * baseline candidate as clean/corrupted. If the epoch is clean, the pooled
 * selection model decides whether to keep baseline or use the lead-matched
 * NLMS candidate. This keeps candidate preference separate from usability:
 * a low selector score no longer turns a clean epoch into a corrupt epoch.
 * lead_id is feature [0], so one pooled model serves both ECG channels.
 * Define PHASE4_TWO_STAGE_DECISION as 0 only when reproducing the previous
 * per-channel candidate-selector path and its CH1/CH2 headers. */
#ifndef PHASE4_TWO_STAGE_DECISION
#define PHASE4_TWO_STAGE_DECISION (1U)
#endif
#if PHASE4_TWO_STAGE_DECISION
#include "mas_usability_classifier.h"
#include "mas_selection_classifier.h"
#endif

#include "phase4_m4_ipc.h"

/*
 * phase4_realtime.h
 *
 * Phase 4 real-time pipeline for ADS1293 CH1/CH2.
 *   BPF   B8: Butterworth 12th, 0.5-40 Hz
 *   Notch N3: fixed 50 Hz IIR + fixed-50 NLMS residual
 *   MAS   NLMS, 6 axes (accel+gyro), 32 taps, 0.5-1.0 Hz ref band,
 *         mu=0.5, eps=1e-8, step cap=0.001
 *
 * Default CM7 build computes one fixed candidate (BPF+N3) and one lead-
 * matched RA-pair NLMS candidate per sample, then picks fixed / RA-pair /
 * corrupt per epoch. CH1 uses RA, LA, RA-LA references; CH2 uses RA, LL,
 * RA-LL. All six MAS candidates can be enabled via
 * PHASE4_PROCESS_ALL_CANDIDATES, but verify p4_cycles and t_us first.
 */

#define PHASE4_ECG_FS_HZ              (200U)
#define PHASE4_CHANNEL_COUNT          (2U)
#define PHASE4_CANDIDATE_COUNT        (6U)
#define PHASE4_BIQUAD_STAGES          (6U)
#define PHASE4_NOTCH_STAGES           (6U)
#define PHASE4_MAS_TAPS               (32U)
#define PHASE4_MAS_MAX_REFS           (18U)
#define PHASE4_MAS_LMS_MU_BASE        (0.05f)
#define PHASE4_MAS_LMS_MU_CAP         (0.01f)
#define PHASE4_MAS_NLMS_MU_BASE       (0.50f)
#define PHASE4_MAS_NLMS_STEP_CAP      (0.001f)
#define PHASE4_MAS_NLMS_EPS           (1.0e-8f)
#define PHASE4_MAS_NLMS_WEIGHT_LEAK   (1.0f)
#define PHASE4_REF_NORM_ALPHA         (0.997503122f) /* exp(-1/(2*200)), matches MATLAB condition_refs at Fs=200 */
#define PHASE4_TRANSPORT_REF_BAND_LO_HZ (0.5f)
#define PHASE4_TRANSPORT_REF_BAND_HI_HZ (1.0f)
#define PHASE4_BASELINE_ALPHA         (0.024f)
#define PHASE4_EPOCH_SAMPLES          (PHASE4_ECG_FS_HZ)
#define PHASE4_FIXED_OUTPUT_COMBO     (1U)  /* BPF + N3 notch, no MAS */
#define PHASE4_FIXED_OUTPUT_IDX       (PHASE4_FIXED_OUTPUT_COMBO - 1U)
#define PHASE4_RA_PAIR_LMS_COMBO      (5U)  /* BPF+N3+NLMS(CH1 RA/LA/RA-LA, CH2 RA/LL/RA-LL) */
#define PHASE4_RA_PAIR_LMS_IDX        (PHASE4_RA_PAIR_LMS_COMBO - 1U)
#define PHASE4_RA_LL_LMS_COMBO        PHASE4_RA_PAIR_LMS_COMBO
#define PHASE4_RA_LL_LMS_IDX          PHASE4_RA_PAIR_LMS_IDX
#define PHASE4_RR_HISTORY             (16U)
#define PHASE4_QRS_ENV_SAMPLES        (((150U * PHASE4_ECG_FS_HZ) + 500U) / 1000U)
#define PHASE4_QRS_WARMUP_SAMPLES     (2U * PHASE4_ECG_FS_HZ)
#define PHASE4_QRS_SEARCH_BACK        (((240U * PHASE4_ECG_FS_HZ) + 500U) / 1000U)
#define PHASE4_QRS_PREDICT_HALF       (((180U * PHASE4_ECG_FS_HZ) + 500U) / 1000U)
#define PHASE4_QRS_REFRACTORY_SAMPLES (((280U * PHASE4_ECG_FS_HZ) + 500U) / 1000U)
#define PHASE4_QRS_HARD_MIN_SAMPLES   (((240U * PHASE4_ECG_FS_HZ) + 500U) / 1000U)
#define PHASE4_QRS_HARD_MIN_US        (240000U)
#define PHASE4_QRS_MAX_RR_US          (2200000U)
#define PHASE4_QRS_STALE_US           (3000000U)
#define PHASE4_QRS_FAST_REVIEW_MS     (300.0f)
#define PHASE4_QRS_MAX_RR_MS          (2200.0f)
#define PHASE4_QRS_SAMPLE_RING        (96U)
#define PHASE4_REF_ABS_LIMIT          (20.0f)
#define PHASE4_MAS_ERROR_ABS_LIMIT    (20000000.0f)
#define PHASE4_MAS_WEIGHT_ABS_LIMIT   (1000000.0f)
#define PHASE4_N3_WEIGHT_ABS_LIMIT    (1000000.0f)
#ifndef PHASE4_ENABLE_RF_SELECTOR
#define PHASE4_ENABLE_RF_SELECTOR     (0U)
#endif

#ifndef PHASE4_PROCESS_ALL_CANDIDATES
#define PHASE4_PROCESS_ALL_CANDIDATES (0U)
#endif

#ifndef PHASE4_ENABLE_RA_PAIR_LMS
#ifdef PHASE4_ENABLE_RA_LL_LMS
#define PHASE4_ENABLE_RA_PAIR_LMS     PHASE4_ENABLE_RA_LL_LMS
#else
#define PHASE4_ENABLE_RA_PAIR_LMS     (1U)
#endif
#endif
#ifndef PHASE4_ENABLE_RA_LL_LMS
#define PHASE4_ENABLE_RA_LL_LMS       PHASE4_ENABLE_RA_PAIR_LMS
#endif

#if PHASE4_ENABLE_RA_PAIR_LMS
#define PHASE4_ACTIVE_CANDIDATE_MASK  ((1UL << PHASE4_FIXED_OUTPUT_IDX) | (1UL << PHASE4_RA_PAIR_LMS_IDX))
#else
#define PHASE4_ACTIVE_CANDIDATE_MASK  (1UL << PHASE4_FIXED_OUTPUT_IDX)
#endif

#ifndef PHASE4_LMS_SWITCH_MARGIN
#define PHASE4_LMS_SWITCH_MARGIN      (8U)
#endif

#ifndef PHASE4_LMS_HOLD_MARGIN
#define PHASE4_LMS_HOLD_MARGIN        (3U)
#endif

#ifndef PHASE4_ENABLE_M4_SELECTOR
#define PHASE4_ENABLE_M4_SELECTOR     (PHASE4_PROCESS_ALL_CANDIDATES)
#endif

#ifndef PHASE4_M4_ALLOW_SWITCHING
#define PHASE4_M4_ALLOW_SWITCHING     (0U)
#endif

#ifndef PHASE4_QRS_TRACK_ALL_CANDIDATES
#define PHASE4_QRS_TRACK_ALL_CANDIDATES (0U)
#endif

#ifndef PHASE4_QRS_USE_RA_PAIR_FOR_HRV
#define PHASE4_QRS_USE_RA_PAIR_FOR_HRV PHASE4_ENABLE_RA_PAIR_LMS
#endif

#define PHASE4_REF_ENV_AVG_ALPHA      (0.96875f)
#define PHASE4_ADS1293_CODE_TO_MV     (0.000107142857f)
#define PHASE4_PI_F                   (3.141592654f)
#define PHASE4_RF_FEATURE_COUNT       (MAS_BAG_CH1_N_FEATURES)

#if PHASE4_PROCESS_ALL_CANDIDATES
#define PHASE4_M4_CANDIDATE_MASK      ((1UL << PHASE4_CANDIDATE_COUNT) - 1UL)
#else
#define PHASE4_M4_CANDIDATE_MASK      PHASE4_ACTIVE_CANDIDATE_MASK
#endif

#if PHASE4_ENABLE_M4_SELECTOR
#include "fsl_mu.h"
#ifndef PHASE4_M4_MU_BASE
#define PHASE4_M4_MU_BASE             MUA
#endif
#endif

#if MAS_BAG_CH1_N_FEATURES != MAS_BAG_CH2_N_FEATURES
    #error "Legacy CH1/CH2 model feature counts must match"
#endif

#if PHASE4_IPC_CHANNEL_COUNT != PHASE4_CHANNEL_COUNT
    #error "Phase4 IPC channel count mismatch"
#endif
#if PHASE4_IPC_CANDIDATE_COUNT != PHASE4_CANDIDATE_COUNT
    #error "Phase4 IPC candidate count mismatch"
#endif
#if PHASE4_IPC_EPOCH_SAMPLES != PHASE4_EPOCH_SAMPLES
    #error "Phase4 IPC epoch length mismatch"
#endif
#if PHASE4_IPC_FEATURE_COUNT != PHASE4_RF_FEATURE_COUNT
    #error "Phase4 IPC feature count mismatch"
#endif

#if PHASE4_TWO_STAGE_DECISION
#if (MAS_BAG_USABILITY_N_FEATURES != PHASE4_RF_FEATURE_COUNT) || \
    (MAS_BAG_SELECTION_N_FEATURES != PHASE4_RF_FEATURE_COUNT)
    #error "Two-stage usability/selection headers must match PHASE4_RF_FEATURE_COUNT"
#endif
/* P(clean) below this => corrupted epoch; P(use suppressed) at/above the
 * selection threshold on a clean epoch => emit the NLMS-suppressed candidate. */
#define PHASE4_USABILITY_THRESH (0.50f)
#define PHASE4_SELECTION_THRESH (0.50f)
#endif

#define PHASE4_FLAG_CH1_CORRUPT       (1U << 0)
#define PHASE4_FLAG_CH2_CORRUPT       (1U << 1)
#define PHASE4_FLAG_PRIMARY_CORRUPT   (1U << 2)
#define PHASE4_FLAG_MOTION_RISK       (1U << 3)
#define PHASE4_FLAG_MOTION_CORRUPT    (1U << 4)
#define PHASE4_FLAG_LMS_ACTIVE        (1U << 5)
#define PHASE4_FLAG_IMU_TIMING_BAD    (1U << 6)
#define PHASE4_FLAG_ADS_SATURATED     (1U << 7)
#define PHASE4_FLAG_ECG_SPIKE         (1U << 8)
#define PHASE4_FLAG_ECG_FLATLINE      (1U << 9)
#define PHASE4_FLAG_PEAK_UNRELIABLE   (1U << 10)
#define PHASE4_FLAG_SQI_LOW           (1U << 11)

#define PHASE4_ADS1293_ADCMAX_CODE    (0x00C35000L)
#define PHASE4_ADS1293_RAIL_LIMIT     ((int32_t)((PHASE4_ADS1293_ADCMAX_CODE * 98L) / 100L))
#define PHASE4_FAST_SPIKE_DELTA_CODES (5.0f / PHASE4_ADS1293_CODE_TO_MV)
#define PHASE4_FAST_FLAT_DELTA_CODES  (0.003f / PHASE4_ADS1293_CODE_TO_MV)
#define PHASE4_FAST_HOLD_SAMPLES      (PHASE4_ECG_FS_HZ / 4U)
#define PHASE4_FAST_FLAT_MIN_SAMPLES  (2U * PHASE4_ECG_FS_HZ)
#define PHASE4_QRS_READY_SAMPLES      (3U * PHASE4_ECG_FS_HZ)
#define PHASE4_QRS_LOW_QUALITY        (18U)
#define PHASE4_SQI_LOW_THRESH         (35U)

typedef struct
{
    float z1;
    float z2;
} phase4_biquad_state_t;

typedef struct
{
    uint8_t ref_count;
    float w[PHASE4_MAS_MAX_REFS * PHASE4_MAS_TAPS];
    float xbuf[PHASE4_MAS_MAX_REFS * PHASE4_MAS_TAPS];
} phase4_mas_state_t;

typedef struct
{
    uint32_t n;
    float sum;
    float sumsq;
    float sum3;
    float sum4;
    float deriv_abs;
    float delta_sum;
    float delta_sumsq;
    float max_abs;
    float prev;
    float cross_pre;
    float ref_sumsq;
    uint8_t ref_count;
    float sample[PHASE4_EPOCH_SAMPLES];
    float ref_env[PHASE4_EPOCH_SAMPLES];
} phase4_candidate_stats_t;

typedef struct
{
    bool initialized;
    float first_ecg;
    phase4_biquad_state_t bpf[PHASE4_BIQUAD_STAGES];
    phase4_biquad_state_t notch[PHASE4_NOTCH_STAGES];
    float n3_w_cos;
    float n3_w_sin;
    float osc_cos;
    float osc_sin;
    phase4_mas_state_t mas[PHASE4_CANDIDATE_COUNT];
    phase4_candidate_stats_t stats[PHASE4_CANDIDATE_COUNT];
    float last_candidates[PHASE4_CANDIDATE_COUNT];
    float last_ref_env[PHASE4_CANDIDATE_COUNT];
    uint8_t last_ref_count[PHASE4_CANDIDATE_COUNT];
    float ref_env_lp[PHASE4_CANDIDATE_COUNT];
    float baseline_lp[PHASE4_CANDIDATE_COUNT];
    bool baseline_ready[PHASE4_CANDIDATE_COUNT];
    uint8_t current_combo;
    uint8_t last_sqi;
    bool last_corrupt;
    bool fast_validity_ready;
    int32_t fast_prev_raw;
    float fast_prev_y;
    uint16_t fast_sat_hold;
    uint16_t fast_spike_hold;
    uint16_t fast_flat_count;
} phase4_channel_state_t;

typedef struct
{
    bool initialized;
    bool axis_ready[IMU_COUNT][6];
    float hp_prev_x[IMU_COUNT][6];
    float hp_prev_y[IMU_COUNT][6];
    float band_lp[IMU_COUNT][6];
    float mean[IMU_COUNT][6];
    float power[IMU_COUNT][6];
} phase4_ref_state_t;

typedef struct
{
    bool initialized;
    uint32_t sample_index;
    uint32_t last_r_sample;
    uint32_t last_decision_sample;
    uint16_t refractory;
    float prev;
    float env_buf[PHASE4_QRS_ENV_SAMPLES];
    float env_sum;
    uint8_t env_count;
    uint8_t env_write;
    float warm_env[PHASE4_QRS_WARMUP_SAMPLES];
    uint16_t warm_count;
    float sample_ring[PHASE4_QRS_SAMPLE_RING];
    uint32_t time_ring_us[PHASE4_QRS_SAMPLE_RING];
    float env;
    float noise;
    float signal;
    float threshold;
    float rr_ms[PHASE4_RR_HISTORY];
    uint32_t r_sample[PHASE4_RR_HISTORY];
    uint32_t r_time_us[PHASE4_RR_HISTORY];
    float r_value[PHASE4_RR_HISTORY];
    float r_strength[PHASE4_RR_HISTORY];
    uint8_t r_count;
    uint8_t r_write;
    uint8_t rr_count;
    uint8_t rr_write;
    uint32_t last_r_time_us;
    uint32_t last_hr_sample;
    uint32_t last_hr_time_us;
    float hr_bpm;
    float sdnn_ms;
    float rmssd_ms;
    float median_rr_ms;
    uint8_t quality;
} phase4_qrs_state_t;

typedef struct
{
    float kurtosis;
    float rms_codes;
    float nsr;
    float qrs_ratio;
    float skewness;
    float entropy;
    float has_rpeak;
    float band_artifact;
    float band_qrs;
} phase4_quality_features_t;

typedef struct
{
    phase4_channel_state_t ch[PHASE4_CHANNEL_COUNT];
    phase4_ref_state_t refs;
    phase4_qrs_state_t qrs[PHASE4_CHANNEL_COUNT][PHASE4_CANDIDATE_COUNT];
    uint32_t sample_count;
    uint32_t epoch_seq;
    uint8_t primary_lead;
    float motion_baseline;
    float motion_dev;
    float motion_score;
    uint16_t baseline_samples;
    uint32_t loop_cycles_max;
    uint32_t label_epoch_seq;
    bool label_epoch_valid;
#if PHASE4_ENABLE_M4_SELECTOR
    bool m4_ipc_initialized;
    uint32_t m4_last_result_seq;
    uint32_t m4_jobs_posted;
    uint32_t m4_jobs_dropped;
    uint8_t m4_last_selected_combo[PHASE4_CHANNEL_COUNT];
    uint16_t m4_last_selected_prob_x1000[PHASE4_CHANNEL_COUNT];
    uint32_t m4_last_cycles;
#endif
} phase4_state_t;

typedef struct
{
    int32_t ra_pair_ch1;
    int32_t ra_pair_ch2;
    /* Kept as p4_ch* on UART for parser compatibility; now selected output. */
    int32_t stitched_ch1;
    int32_t stitched_ch2;
    int32_t primary_ecg;
    uint8_t sel_ch1;
    uint8_t sel_ch2;
    uint8_t primary_lead;
    uint16_t flags;
    uint16_t hr1_x10;
    uint16_t hr2_x10;
    uint16_t rmssd1_x10;
    uint16_t rmssd2_x10;
    uint16_t motion_x10;
    uint8_t sqi1;
    uint8_t sqi2;
    uint32_t epoch_seq;
    uint32_t label_epoch_seq;
    uint32_t m4_heartbeat;
    uint32_t m4_jobs_posted;
    uint32_t m4_results_posted;
    uint32_t m4_results_consumed;
    uint32_t m4_jobs_dropped;
    uint32_t m4_last_result_seq;
    uint8_t m4_sel_ch1;
    uint8_t m4_sel_ch2;
    uint16_t m4_prob1_x1000;
    uint16_t m4_prob2_x1000;
    uint32_t m4_cycles;
} phase4_output_t;

static const float phase4_b8_sos[PHASE4_BIQUAD_STAGES][5] =
{
    { 0.009714657927f,  0.019429315855f,  0.009714657927f, -0.342669315863f, 0.046428900909f },
    { 1.000000000000f,  2.000000000000f,  1.000000000000f, -0.383268867650f, 0.202787300304f },
    { 1.000000000000f,  2.000000000000f,  1.000000000000f, -0.499997703129f, 0.611459326767f },
    { 1.000000000000f, -2.000000000000f,  1.000000000000f, -1.969291977622f, 0.969545138362f },
    { 1.000000000000f, -2.000000000000f,  1.000000000000f, -1.977791668166f, 0.978040965394f },
    { 1.000000000000f, -2.000000000000f,  1.000000000000f, -1.991806511073f, 0.992052951237f }
};

static const float phase4_n1_sos[5] =
{
    1.000000000000f,
    0.000000000000f,
    1.000000000000f,
    0.000000000000f,
    0.980100000000f
};


static inline bool phase4_is_finite(float x)
{
    return (x == x) && (x < 3.4e38f) && (x > -3.4e38f);
}

static inline float phase4_absf(float x)
{
    return (x >= 0.0f) ? x : -x;
}

static inline float phase4_clampf(float x, float lo, float hi)
{
    if (x < lo) { return lo; }
    if (x > hi) { return hi; }
    return x;
}

static inline uint16_t phase4_u16_scaled(float x, float scale, float max_value)
{
    float v = phase4_clampf(x * scale, 0.0f, max_value);
    return (uint16_t)(v + 0.5f);
}

static inline int32_t phase4_i32_round(float x)
{
    if (!phase4_is_finite(x)) { return 0; }
    if (x > 2147483000.0f) { return 2147483000; }
    if (x < -2147483000.0f) { return -2147483000; }
    return (x >= 0.0f) ? (int32_t)(x + 0.5f) : (int32_t)(x - 0.5f);
}

static inline float phase4_biquad_step(float x,
                                       const float c[5],
                                       phase4_biquad_state_t *s)
{
    float y = c[0] * x + s->z1;
    s->z1 = c[1] * x - c[3] * y + s->z2;
    s->z2 = c[2] * x - c[4] * y;
    if (!phase4_is_finite(y))
    {
        s->z1 = 0.0f;
        s->z2 = 0.0f;
        y = x;
    }
    return y;
}

static inline float phase4_biquad_cascade(float x,
                                          const float sos[][5],
                                          phase4_biquad_state_t *state,
                                          uint32_t stages)
{
    float y = x;
    for (uint32_t ii = 0U; ii < stages; ii++)
    {
        y = phase4_biquad_step(y, sos[ii], &state[ii]);
    }
    return y;
}

static inline float phase4_notch_cascade(float x, phase4_biquad_state_t *state)
{
    float y = x;
    for (uint32_t ii = 0U; ii < PHASE4_NOTCH_STAGES; ii++)
    {
        y = phase4_biquad_step(y, phase4_n1_sos, &state[ii]);
    }
    return y;
}

static inline float phase4_baseline_remove(phase4_channel_state_t *ch,
                                           uint32_t candidate_idx,
                                           float x)
{
    if ((ch == NULL) || (candidate_idx >= PHASE4_CANDIDATE_COUNT))
    {
        return x;
    }

    if (!ch->baseline_ready[candidate_idx])
    {
        ch->baseline_lp[candidate_idx] = x;
        ch->baseline_ready[candidate_idx] = true;
        return 0.0f;
    }

    float err = x - ch->baseline_lp[candidate_idx];
    ch->baseline_lp[candidate_idx] += PHASE4_BASELINE_ALPHA * err;
    if (!phase4_is_finite(ch->baseline_lp[candidate_idx]))
    {
        ch->baseline_lp[candidate_idx] = x;
        return 0.0f;
    }

    float y = x - ch->baseline_lp[candidate_idx];
    return phase4_is_finite(y) ? y : 0.0f;
}

static inline float phase4_n3_step(float x, phase4_channel_state_t *ch)
{
    const float mu = 0.005f;
    const float osc_c = 0.000000000000f;
    const float osc_s = 1.000000000000f;

    float y = phase4_notch_cascade(x, ch->notch);
    if (!phase4_is_finite(ch->n3_w_cos) || !phase4_is_finite(ch->n3_w_sin) ||
        (phase4_absf(ch->n3_w_cos) > PHASE4_N3_WEIGHT_ABS_LIMIT) ||
        (phase4_absf(ch->n3_w_sin) > PHASE4_N3_WEIGHT_ABS_LIMIT))
    {
        ch->n3_w_cos = 0.0f;
        ch->n3_w_sin = 0.0f;
    }

    float ref_c = ch->osc_cos;
    float ref_s = ch->osc_sin;
    float estimate = ch->n3_w_cos * ref_c + ch->n3_w_sin * ref_s;
    float e = y - estimate;
    if (!phase4_is_finite(e))
    {
        ch->n3_w_cos = 0.0f;
        ch->n3_w_sin = 0.0f;
        e = phase4_is_finite(y) ? y : 0.0f;
    }
    float step = mu / (ref_c * ref_c + ref_s * ref_s + 1.0e-8f);
    float next_w_cos = ch->n3_w_cos + step * e * ref_c;
    float next_w_sin = ch->n3_w_sin + step * e * ref_s;
    ch->n3_w_cos = (phase4_is_finite(next_w_cos) &&
                    (phase4_absf(next_w_cos) <= PHASE4_N3_WEIGHT_ABS_LIMIT)) ?
                   next_w_cos : 0.0f;
    ch->n3_w_sin = (phase4_is_finite(next_w_sin) &&
                    (phase4_absf(next_w_sin) <= PHASE4_N3_WEIGHT_ABS_LIMIT)) ?
                   next_w_sin : 0.0f;

    float next_c = ch->osc_cos * osc_c - ch->osc_sin * osc_s;
    float next_s = ch->osc_sin * osc_c + ch->osc_cos * osc_s;
    float osc_mag2 = next_c * next_c + next_s * next_s;
    if (phase4_is_finite(osc_mag2) && (osc_mag2 > 0.25f) && (osc_mag2 < 4.0f))
    {
        float inv_mag = 1.0f / sqrtf(osc_mag2);
        ch->osc_cos = next_c * inv_mag;
        ch->osc_sin = next_s * inv_mag;
    }
    else
    {
        ch->osc_cos = 1.0f;
        ch->osc_sin = 0.0f;
    }
    return e;
}

static inline void phase4_condition_refs(phase4_ref_state_t *st,
                                         const imu_raw_t raw[IMU_COUNT],
                                         float refs[IMU_COUNT][6])
{
    const float dt = 1.0f / (float)PHASE4_ECG_FS_HZ;
    const float hp_rc = 1.0f / (6.283185307f * PHASE4_TRANSPORT_REF_BAND_LO_HZ);
    const float lp_rc = 1.0f / (6.283185307f * PHASE4_TRANSPORT_REF_BAND_HI_HZ);
    const float alpha_hp = hp_rc / (hp_rc + dt);
    const float alpha_lp = dt / (lp_rc + dt);
    const float alpha_norm = PHASE4_REF_NORM_ALPHA;
    bool any_valid = false;

    for (uint32_t site = 0U; site < IMU_COUNT; site++)
    {
        if (!raw[site].valid)
        {
            for (uint32_t axis = 0U; axis < 6U; axis++)
            {
                refs[site][axis] = 0.0f;
            }
            continue;
        }
        any_valid = true;

        float x[6];
        x[0] = (float)raw[site].ax / 16384.0f;
        x[1] = (float)raw[site].ay / 16384.0f;
        x[2] = (float)raw[site].az / 16384.0f;
        x[3] = (float)raw[site].gx / 131.0f;
        x[4] = (float)raw[site].gy / 131.0f;
        x[5] = (float)raw[site].gz / 131.0f;

        for (uint32_t axis = 0U; axis < 6U; axis++)
        {
            if (!st->axis_ready[site][axis])
            {
                st->axis_ready[site][axis] = true;
                st->hp_prev_x[site][axis] = x[axis];
                st->hp_prev_y[site][axis] = 0.0f;
                st->band_lp[site][axis] = 0.0f;
                st->mean[site][axis] = 0.0f;
                st->power[site][axis] = 1.0f;
                refs[site][axis] = 0.0f;
                continue;
            }

            float hp = alpha_hp * (st->hp_prev_y[site][axis] +
                                   x[axis] - st->hp_prev_x[site][axis]);
            st->hp_prev_x[site][axis] = x[axis];
            st->hp_prev_y[site][axis] = hp;
            st->band_lp[site][axis] += alpha_lp * (hp - st->band_lp[site][axis]);

            float band = st->band_lp[site][axis];
            float centered = band - st->mean[site][axis];
            st->power[site][axis] = alpha_norm * st->power[site][axis] +
                                    (1.0f - alpha_norm) * centered * centered;
            st->mean[site][axis] = alpha_norm * st->mean[site][axis] +
                                   (1.0f - alpha_norm) * band;
            refs[site][axis] = centered / sqrtf(st->power[site][axis] + 1.0e-6f);
            if (!phase4_is_finite(refs[site][axis]))
            {
                refs[site][axis] = 0.0f;
            }
            refs[site][axis] = phase4_clampf(refs[site][axis],
                                             -PHASE4_REF_ABS_LIMIT,
                                             PHASE4_REF_ABS_LIMIT);
        }
    }

    if (any_valid)
    {
        st->initialized = true;
    }
}

static inline uint8_t phase4_build_candidate_refs(uint8_t combo_id,
                                                  uint32_t ch_idx,
                                                  const float site_refs[IMU_COUNT][6],
                                                  float out_refs[PHASE4_MAS_MAX_REFS])
{
    uint8_t n = 0U;
    uint8_t a = 0U;
    uint8_t b = 0U;

    if (combo_id == PHASE4_RA_PAIR_LMS_COMBO)
    {
        a = 2U;                         /* RA is common to Lead I and Lead II. */
        b = (ch_idx == 0U) ? 1U : 0U;   /* CH1 Lead I: LA, CH2 Lead II: LL. */
    }
    else if (combo_id == 2U) { a = 0U; b = 255U; }
    else if (combo_id == 3U) { a = 1U; b = 255U; }
    else if (combo_id == 4U) { a = 2U; b = 255U; }
    else if (combo_id == 6U) { a = 2U; b = 1U; }
    else { return 0U; }

    for (uint32_t ii = 0U; ii < 6U; ii++)
    {
        out_refs[n++] = site_refs[a][ii];
    }

    if (b != 255U)
    {
        for (uint32_t ii = 0U; ii < 6U; ii++)
        {
            out_refs[n++] = site_refs[b][ii];
        }
        for (uint32_t ii = 0U; ii < 6U; ii++)
        {
            out_refs[n++] = site_refs[a][ii] - site_refs[b][ii];
        }
    }

    return n;
}

static inline float phase4_reference_envelope_sample(const float refs[PHASE4_MAS_MAX_REFS],
                                                     uint8_t ref_count)
{
    if (ref_count == 0U)
    {
        return 0.0f;
    }

    float sumsq = 0.0f;
    for (uint32_t ii = 0U; ii < ref_count; ii++)
    {
        sumsq += refs[ii] * refs[ii];
    }
    return sqrtf(sumsq / (float)ref_count);
}

static inline float phase4_mas_nlms_step(float d,
                                         const float refs[PHASE4_MAS_MAX_REFS],
                                         uint8_t ref_count,
                                         phase4_mas_state_t *st)
{
    if (!phase4_is_finite(d))
    {
        d = 0.0f;
    }

    if (ref_count == 0U)
    {
        return d;
    }

    st->ref_count = ref_count;
    for (uint32_t rr = 0U; rr < ref_count; rr++)
    {
        uint32_t base = rr * PHASE4_MAS_TAPS;
        for (uint32_t tt = PHASE4_MAS_TAPS - 1U; tt > 0U; tt--)
        {
            st->xbuf[base + tt] = st->xbuf[base + tt - 1U];
        }
        st->xbuf[base] = refs[rr];
    }

    uint32_t len = (uint32_t)ref_count * PHASE4_MAS_TAPS;
    float estimate = 0.0f;
    float x_power = PHASE4_MAS_NLMS_EPS;
    for (uint32_t ii = 0U; ii < len; ii++)
    {
        estimate += st->w[ii] * st->xbuf[ii];
        x_power += st->xbuf[ii] * st->xbuf[ii];
    }
    if (!phase4_is_finite(estimate))
    {
        memset(st->w, 0, sizeof(st->w));
        return d;
    }

    float e = d - estimate;
    if (!phase4_is_finite(e))
    {
        memset(st->w, 0, sizeof(st->w));
        return d;
    }
    e = phase4_clampf(e, -PHASE4_MAS_ERROR_ABS_LIMIT, PHASE4_MAS_ERROR_ABS_LIMIT);
    if (!phase4_is_finite(x_power) || (x_power <= PHASE4_MAS_NLMS_EPS))
    {
        return e;
    }

    float step = PHASE4_MAS_NLMS_MU_BASE / x_power;
    if (step > PHASE4_MAS_NLMS_STEP_CAP)
    {
        step = PHASE4_MAS_NLMS_STEP_CAP;
    }

    for (uint32_t ii = 0U; ii < len; ii++)
    {
        float next_w = (st->w[ii] + step * e * st->xbuf[ii]) *
                       PHASE4_MAS_NLMS_WEIGHT_LEAK;
        st->w[ii] = (phase4_is_finite(next_w) &&
                     (phase4_absf(next_w) <= PHASE4_MAS_WEIGHT_ABS_LIMIT)) ?
                    next_w : 0.0f;
    }

    return e;
}

static inline float phase4_mas_lms_step(float d,
                                        const float refs[PHASE4_MAS_MAX_REFS],
                                        uint8_t ref_count,
                                        phase4_mas_state_t *st)
{
    return phase4_mas_nlms_step(d, refs, ref_count, st);
}

static inline void phase4_stats_update(phase4_candidate_stats_t *st,
                                       float y,
                                       float pre,
                                       float ref_env,
                                       uint8_t ref_count)
{
    if (!phase4_is_finite(y)) { y = 0.0f; }
    if (!phase4_is_finite(pre)) { pre = 0.0f; }
    if (!phase4_is_finite(ref_env)) { ref_env = 0.0f; }
    uint32_t idx = st->n;
    float dy = y - st->prev;
    float delta = y - pre;
    float y2 = y * y;
    st->n++;
    st->sum += y;
    st->sumsq += y2;
    st->sum3 += y2 * y;
    st->sum4 += y2 * y2;
    st->deriv_abs += phase4_absf(dy);
    st->delta_sum += delta;
    st->delta_sumsq += delta * delta;
    st->cross_pre += y * pre;
    st->ref_count = ref_count;
    st->ref_sumsq += ref_env * ref_env;
    if (idx < PHASE4_EPOCH_SAMPLES)
    {
        st->sample[idx] = y;
        st->ref_env[idx] = ref_env;
    }
    if (phase4_absf(y) > st->max_abs)
    {
        st->max_abs = phase4_absf(y);
    }
    st->prev = y;
}

static inline void phase4_stats_reset(phase4_candidate_stats_t *st)
{
    float prev = st->prev;
    memset(st, 0, sizeof(*st));
    st->prev = prev;
}

static inline float phase4_stats_mean(const phase4_candidate_stats_t *st)
{
    return (st->n > 0U) ? (st->sum / (float)st->n) : 0.0f;
}

static inline float phase4_stats_variance(const phase4_candidate_stats_t *st)
{
    if (st->n == 0U)
    {
        return 0.0f;
    }
    float n = (float)st->n;
    float mean = st->sum / n;
    float var = (st->sumsq / n) - (mean * mean);
    return (var > 1.0e-12f) ? var : 0.0f;
}

static inline float phase4_stats_rms_ac(const phase4_candidate_stats_t *st)
{
    return sqrtf(phase4_stats_variance(st));
}

static inline float phase4_stats_delta_rms(const phase4_candidate_stats_t *st)
{
    if (st->n == 0U)
    {
        return 0.0f;
    }
    float n = (float)st->n;
    float mean = st->delta_sum / n;
    float var = (st->delta_sumsq / n) - (mean * mean);
    return sqrtf((var > 0.0f) ? var : 0.0f);
}

static inline float phase4_stats_skewness(const phase4_candidate_stats_t *st)
{
    if (st->n == 0U)
    {
        return 0.0f;
    }
    float n = (float)st->n;
    float mean = st->sum / n;
    float m2 = (st->sumsq / n) - (mean * mean);
    if (m2 <= 1.0e-12f)
    {
        return 0.0f;
    }
    float m3 = (st->sum3 / n) -
               (3.0f * mean * st->sumsq / n) +
               (2.0f * mean * mean * mean);
    return m3 / (m2 * sqrtf(m2));
}

static inline float phase4_stats_kurtosis(const phase4_candidate_stats_t *st)
{
    if (st->n == 0U)
    {
        return 0.0f;
    }
    float n = (float)st->n;
    float mean = st->sum / n;
    float mean2 = mean * mean;
    float m2 = (st->sumsq / n) - mean2;
    if (m2 <= 1.0e-12f)
    {
        return 0.0f;
    }
    float m4 = (st->sum4 / n) -
               (4.0f * mean * st->sum3 / n) +
               (6.0f * mean2 * st->sumsq / n) -
               (3.0f * mean2 * mean2);
    return m4 / (m2 * m2);
}

static inline float phase4_stats_corr_with_pre(const phase4_candidate_stats_t *st,
                                               const phase4_candidate_stats_t *pre)
{
    if ((st->n == 0U) || (pre->n == 0U))
    {
        return 0.0f;
    }
    float n = (float)((st->n < pre->n) ? st->n : pre->n);
    float num = (n * st->cross_pre) - (st->sum * pre->sum);
    float va = (n * st->sumsq) - (st->sum * st->sum);
    float vb = (n * pre->sumsq) - (pre->sum * pre->sum);
    float den = sqrtf(phase4_absf(va * vb));
    if (den <= 1.0e-12f)
    {
        return 0.0f;
    }
    return phase4_clampf(num / den, -1.0f, 1.0f);
}

static inline float phase4_stats_ref_rms(const phase4_candidate_stats_t *st)
{
    if ((st->n == 0U) || (st->ref_count == 0U))
    {
        return 0.0f;
    }
    return sqrtf(st->ref_sumsq / (float)st->n);
}

static inline float phase4_stats_ref_p95(const phase4_candidate_stats_t *st)
{
    uint32_t count = (st->n < PHASE4_EPOCH_SAMPLES) ? st->n : PHASE4_EPOCH_SAMPLES;
    if ((count == 0U) || (st->ref_count == 0U))
    {
        return 0.0f;
    }

    float tmp[PHASE4_EPOCH_SAMPLES];
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        tmp[ii] = st->ref_env[ii];
    }

    for (uint32_t ii = 1U; ii < count; ii++)
    {
        float v = tmp[ii];
        uint32_t jj = ii;
        while ((jj > 0U) && (tmp[jj - 1U] > v))
        {
            tmp[jj] = tmp[jj - 1U];
            jj--;
        }
        tmp[jj] = v;
    }

    uint32_t rank = (uint32_t)((95U * (count - 1U) + 50U) / 100U);
    if (rank >= count)
    {
        rank = count - 1U;
    }
    return tmp[rank];
}

static inline float phase4_percentile_sorted(float values[PHASE4_EPOCH_SAMPLES],
                                             uint32_t count,
                                             uint32_t pct)
{
    if (count == 0U)
    {
        return 0.0f;
    }

    for (uint32_t ii = 1U; ii < count; ii++)
    {
        float v = values[ii];
        uint32_t jj = ii;
        while ((jj > 0U) && (values[jj - 1U] > v))
        {
            values[jj] = values[jj - 1U];
            jj--;
        }
        values[jj] = v;
    }

    uint32_t rank = (uint32_t)((pct * (count - 1U) + 50U) / 100U);
    if (rank >= count)
    {
        rank = count - 1U;
    }
    return values[rank];
}

static inline float phase4_sample_percentile(const float samples[PHASE4_EPOCH_SAMPLES],
                                             uint32_t count,
                                             uint32_t pct)
{
    float tmp[PHASE4_EPOCH_SAMPLES];
    if (count > PHASE4_EPOCH_SAMPLES)
    {
        count = PHASE4_EPOCH_SAMPLES;
    }
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        tmp[ii] = samples[ii];
    }
    return phase4_percentile_sorted(tmp, count, pct);
}

static inline void phase4_compute_psd_bands(const float samples[PHASE4_EPOCH_SAMPLES],
                                            uint32_t count,
                                            float mean,
                                            float *band_artifact,
                                            float *band_qrs,
                                            float *entropy)
{
    float band40[40U];
    float total40 = 0.0f;
    *band_artifact = 0.0f;
    *band_qrs = 0.0f;
    *entropy = 0.0f;
    if (count < 8U)
    {
        return;
    }

    float window[PHASE4_EPOCH_SAMPLES];
    for (uint32_t nn = 0U; nn < count; nn++)
    {
        float win = 0.5f;
        if (count > 1U)
        {
            win -= 0.5f * cosf(2.0f * PHASE4_PI_F * (float)nn / (float)(count - 1U));
        }
        window[nn] = win;
    }

    for (uint32_t kk = 1U; kk <= 40U; kk++)
    {
        float re = 0.0f;
        float im = 0.0f;
        float theta = -2.0f * PHASE4_PI_F * (float)kk / (float)count;
        float step_c = cosf(theta);
        float step_s = sinf(theta);
        float osc_c = 1.0f;
        float osc_s = 0.0f;
        for (uint32_t nn = 0U; nn < count; nn++)
        {
            float x = (samples[nn] - mean) * window[nn];
            re += x * osc_c;
            im += x * osc_s;
            float next_c = osc_c * step_c - osc_s * step_s;
            float next_s = osc_s * step_c + osc_c * step_s;
            osc_c = next_c;
            osc_s = next_s;
        }
        float p = re * re + im * im;
        band40[kk - 1U] = p;
        total40 += p;
        if (kk <= 8U)
        {
            *band_artifact += p;
        }
        if ((kk >= 8U) && (kk <= 35U))
        {
            *band_qrs += p;
        }
    }

    if (total40 > 1.0e-30f)
    {
        const float inv_log2 = 1.442695041f;
        for (uint32_t kk = 0U; kk < 40U; kk++)
        {
            float p = band40[kk] / total40;
            if (p > 1.0e-30f)
            {
                *entropy -= p * logf(p) * inv_log2;
            }
        }
    }
}

static inline float phase4_compute_nsr(const float samples[PHASE4_EPOCH_SAMPLES],
                                       uint32_t count,
                                       float mean,
                                       float rms)
{
    const uint32_t trend_len = 12U;
    float ring[12U];
    float run = 0.0f;
    float diff_sumsq = 0.0f;
    for (uint32_t ii = 0U; ii < trend_len; ii++)
    {
        ring[ii] = 0.0f;
    }
    if ((count == 0U) || (rms <= 1.0e-12f))
    {
        return 0.0f;
    }
    for (uint32_t nn = 0U; nn < count; nn++)
    {
        float x = samples[nn] - mean;
        uint32_t slot = nn % trend_len;
        run -= ring[slot];
        ring[slot] = x;
        run += x;
        float trend = run / (float)trend_len;
        float d = x - trend;
        diff_sumsq += d * d;
    }
    return sqrtf(diff_sumsq / (float)count) / rms;
}

static inline float phase4_compute_has_rpeak(const float samples[PHASE4_EPOCH_SAMPLES],
                                             uint32_t count,
                                             float mean)
{
    const uint32_t win = 10U;
    float env[PHASE4_EPOCH_SAMPLES];
    float sq[PHASE4_EPOCH_SAMPLES];
    float env_sum = 0.0f;
    float env_max = 0.0f;
    if (count < 16U)
    {
        return 0.0f;
    }
    sq[0] = 0.0f;
    for (uint32_t ii = 1U; ii < count; ii++)
    {
        float d = (samples[ii] - mean) - (samples[ii - 1U] - mean);
        sq[ii] = d * d;
    }
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        uint32_t lo = (ii > (win / 2U)) ? (ii - (win / 2U)) : 0U;
        uint32_t hi = ii + (win / 2U);
        if (hi >= count) { hi = count - 1U; }
        float s = 0.0f;
        for (uint32_t jj = lo; jj <= hi; jj++)
        {
            s += sq[jj];
        }
        env[ii] = s / (float)(hi - lo + 1U);
        env_sum += env[ii];
        if (env[ii] > env_max)
        {
            env_max = env[ii];
        }
    }
    return (env_max > 0.0f && (env_max / ((env_sum / (float)count) + 1.0e-12f)) > 5.0f) ? 1.0f : 0.0f;
}

static inline void phase4_compute_quality_features(const phase4_candidate_stats_t *st,
                                                   phase4_quality_features_t *q)
{
    memset(q, 0, sizeof(*q));
    if (st->n == 0U)
    {
        return;
    }
    uint32_t count = (st->n < PHASE4_EPOCH_SAMPLES) ? st->n : PHASE4_EPOCH_SAMPLES;
    float mean = phase4_stats_mean(st);
    q->kurtosis = phase4_stats_kurtosis(st);
    q->rms_codes = phase4_stats_rms_ac(st);
    q->skewness = phase4_stats_skewness(st);
    q->nsr = phase4_compute_nsr(st->sample, count, mean, q->rms_codes);
    q->has_rpeak = phase4_compute_has_rpeak(st->sample, count, mean);
    phase4_compute_psd_bands(st->sample, count, mean,
                             &q->band_artifact,
                             &q->band_qrs,
                             &q->entropy);
    q->qrs_ratio = q->band_qrs / (q->band_artifact + 1.0e-30f);
}

static inline float phase4_delta_p95_pct(const phase4_candidate_stats_t *st,
                                         const phase4_candidate_stats_t *pre,
                                         float pre_rms)
{
    uint32_t count = (st->n < pre->n) ? st->n : pre->n;
    if (count > PHASE4_EPOCH_SAMPLES)
    {
        count = PHASE4_EPOCH_SAMPLES;
    }
    if (count == 0U)
    {
        return 0.0f;
    }

    float delta[PHASE4_EPOCH_SAMPLES];
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        delta[ii] = st->sample[ii] - pre->sample[ii];
    }
    float med = phase4_percentile_sorted(delta, count, 50U);
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        delta[ii] = phase4_absf((st->sample[ii] - pre->sample[ii]) - med);
    }

    float scale = phase4_sample_percentile(pre->sample, count, 95U) -
                  phase4_sample_percentile(pre->sample, count, 5U);
    if ((!phase4_is_finite(scale)) || (scale < 1.0e-9f))
    {
        scale = 6.0f * pre_rms;
    }
    if ((!phase4_is_finite(scale)) || (scale < 1.0e-9f))
    {
        scale = 1.0f;
    }

    return 100.0f * phase4_percentile_sorted(delta, count, 95U) / scale;
}

static inline float phase4_corr_arrays(const float a[PHASE4_EPOCH_SAMPLES],
                                       const float b[PHASE4_EPOCH_SAMPLES],
                                       uint32_t count)
{
    float sa = 0.0f;
    float sb = 0.0f;
    float saa = 0.0f;
    float sbb = 0.0f;
    float sab = 0.0f;
    if (count == 0U)
    {
        return 0.0f;
    }
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        sa += a[ii];
        sb += b[ii];
        saa += a[ii] * a[ii];
        sbb += b[ii] * b[ii];
        sab += a[ii] * b[ii];
    }
    float n = (float)count;
    float num = n * sab - sa * sb;
    float va = n * saa - sa * sa;
    float vb = n * sbb - sb * sb;
    float den = sqrtf(phase4_absf(va * vb));
    if (den <= 1.0e-12f)
    {
        return 0.0f;
    }
    return phase4_clampf(num / den, -1.0f, 1.0f);
}

static inline float phase4_corr_ref_delta(const phase4_candidate_stats_t *st,
                                          const phase4_candidate_stats_t *pre)
{
    float delta[PHASE4_EPOCH_SAMPLES];
    uint32_t count = (st->n < pre->n) ? st->n : pre->n;
    if (count > PHASE4_EPOCH_SAMPLES)
    {
        count = PHASE4_EPOCH_SAMPLES;
    }
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        delta[ii] = st->sample[ii] - pre->sample[ii];
    }
    return phase4_corr_arrays(st->ref_env, delta, count);
}

static inline float phase4_motion_score_from_baseline(float baseline,
                                                      float dev_in,
                                                      float energy)
{
    float dev_floor = baseline * 0.25f;
    if (dev_floor < 1.0e-3f) { dev_floor = 1.0e-3f; }
    float dev = (dev_in > dev_floor) ? dev_in : dev_floor;
    return phase4_clampf((energy - baseline) / dev, 0.0f, 99.0f);
}

static inline float phase4_motion_score_from_energy(const phase4_state_t *s, float energy)
{
    return phase4_motion_score_from_baseline(s->motion_baseline,
                                             s->motion_dev,
                                             energy);
}

#if PHASE4_ENABLE_RF_SELECTOR || defined(PHASE4_M4_CLASSIFIER_APP)
static inline float phase4_bag_impute_value(uint32_t ch_idx, uint32_t feature_idx)
{
    if (feature_idx >= PHASE4_RF_FEATURE_COUNT)
    {
        return 0.0f;
    }
    return (ch_idx == 0U) ? mas_bag_ch1_impute_vals[feature_idx] :
                            mas_bag_ch2_impute_vals[feature_idx];
}

static inline void phase4_fill_rf_features_from_stats(uint32_t ch_idx,
                                                      uint32_t candidate_idx,
                                                      float motion_score,
                                                      float motion_baseline,
                                                      float motion_dev,
                                                      const phase4_candidate_stats_t *st,
                                                      const phase4_candidate_stats_t *pre,
                                                      float x[PHASE4_RF_FEATURE_COUNT])
{
    phase4_quality_features_t ecg_q;
    phase4_quality_features_t pre_q;
    float source_rms = phase4_stats_ref_rms(st);
    float source_p95 = phase4_stats_ref_p95(st);
    float source_score = phase4_motion_score_from_baseline(motion_baseline,
                                                           motion_dev,
                                                           source_rms);
    float pre_rms = phase4_stats_rms_ac(pre);
    float delta_scale = 6.0f * pre_rms;
    if (delta_scale < 1.0f)
    {
        delta_scale = pre_rms + 1.0f;
    }

    phase4_compute_quality_features(st, &ecg_q);
    phase4_compute_quality_features(pre, &pre_q);

    x[0] = (float)(ch_idx + 1U);
    x[1] = (float)(candidate_idx + 1U);
    x[2] = (candidate_idx == 0U) ? 0.0f : 1.0f;
    x[3] = (float)st->ref_count;
    x[4] = motion_score;
    x[5] = (st->ref_count == 0U) ? phase4_bag_impute_value(ch_idx, 5U) : source_score;
    x[6] = (st->ref_count == 0U) ? phase4_bag_impute_value(ch_idx, 6U) : source_rms;
    x[7] = (st->ref_count == 0U) ? phase4_bag_impute_value(ch_idx, 7U) : source_p95;
    x[8] = ecg_q.kurtosis;
    x[9] = ecg_q.rms_codes * PHASE4_ADS1293_CODE_TO_MV;
    x[10] = ecg_q.nsr;
    x[11] = ecg_q.qrs_ratio;
    x[12] = ecg_q.skewness;
    x[13] = ecg_q.entropy;
    x[14] = ecg_q.has_rpeak;
    x[15] = pre_q.kurtosis;
    x[16] = pre_q.rms_codes * PHASE4_ADS1293_CODE_TO_MV;
    x[17] = pre_q.qrs_ratio;
    x[18] = 100.0f * phase4_stats_delta_rms(st) / delta_scale;
    x[19] = phase4_delta_p95_pct(st, pre, pre_rms);
    x[20] = 10.0f * log10f((pre_q.band_artifact + 1.0e-30f) /
                           (ecg_q.band_artifact + 1.0e-30f));
    x[21] = 10.0f * log10f((ecg_q.band_qrs + 1.0e-30f) /
                           (pre_q.band_qrs + 1.0e-30f));
    x[22] = phase4_stats_corr_with_pre(st, pre);
    x[23] = (st->ref_count == 0U) ? phase4_bag_impute_value(ch_idx, 23U) :
            phase4_corr_arrays(st->ref_env, st->sample,
                               (st->n < PHASE4_EPOCH_SAMPLES) ? st->n : PHASE4_EPOCH_SAMPLES);
    x[24] = (st->ref_count == 0U) ? phase4_bag_impute_value(ch_idx, 24U) :
            phase4_corr_ref_delta(st, pre);

    for (uint32_t ii = 0U; ii < PHASE4_RF_FEATURE_COUNT; ii++)
    {
        if (!phase4_is_finite(x[ii]))
        {
            x[ii] = phase4_bag_impute_value(ch_idx, ii);
        }
    }
}

static inline uint8_t phase4_rf_score_from_stats(uint32_t ch_idx,
                                                 uint32_t candidate_idx,
                                                 float motion_score,
                                                 float motion_baseline,
                                                 float motion_dev,
                                                 const phase4_candidate_stats_t *st,
                                                 const phase4_candidate_stats_t *pre,
                                                 float *prob_out)
{
    if ((ch_idx >= PHASE4_CHANNEL_COUNT) ||
        (candidate_idx >= PHASE4_CANDIDATE_COUNT) ||
        (st == NULL) ||
        (pre == NULL))
    {
        if (prob_out != NULL) { *prob_out = 0.0f; }
        return 0U;
    }

    float x[PHASE4_RF_FEATURE_COUNT];
    phase4_fill_rf_features_from_stats(ch_idx,
                                       candidate_idx,
                                       motion_score,
                                       motion_baseline,
                                       motion_dev,
                                       st,
                                       pre,
                                       x);
    float p = 0.0f;
    if (ch_idx == 0U)
    {
        p = mas_bag_ch1_classify_prob(x);
    }
    else
    {
        p = mas_bag_ch2_classify_prob(x);
    }

    if (prob_out != NULL)
    {
        *prob_out = p;
    }
    return (uint8_t)phase4_clampf(100.0f * p, 0.0f, 100.0f);
}
#endif

#if PHASE4_ENABLE_RF_SELECTOR
static inline uint8_t phase4_rf_candidate_score(const phase4_state_t *s,
                                                uint32_t ch_idx,
                                                uint32_t candidate_idx)
{
    if ((ch_idx >= PHASE4_CHANNEL_COUNT) ||
        (candidate_idx >= PHASE4_CANDIDATE_COUNT))
    {
        return 0U;
    }

    const phase4_channel_state_t *ch = &s->ch[ch_idx];
    return phase4_rf_score_from_stats(ch_idx,
                                      candidate_idx,
                                      s->motion_score,
                                      s->motion_baseline,
                                      s->motion_dev,
                                      &ch->stats[candidate_idx],
                                      &ch->stats[0],
                                      NULL);
}
#endif

static inline uint8_t phase4_score_candidate(const phase4_candidate_stats_t *st,
                                             const phase4_candidate_stats_t *pre,
                                             float motion_score,
                                             bool *corrupt)
{
    *corrupt = false;
    if ((st->n == 0U) || (pre->n == 0U))
    {
        *corrupt = true;
        return 0U;
    }

    float inv_n = 1.0f / (float)st->n;
    float rms = sqrtf(st->sumsq * inv_n + 1.0e-6f);
    float pre_rms = sqrtf(pre->sumsq * (1.0f / (float)pre->n) + 1.0e-6f);
    float slope = st->deriv_abs * inv_n;
    float delta_pct = 100.0f * sqrtf(st->delta_sumsq * inv_n) / (pre_rms + 1.0f);
    float qrs_proxy = 140.0f * slope / (0.05f * rms + 1.0f);
    float score = qrs_proxy - 0.22f * delta_pct;

    if (rms < 5.0f) { score -= 40.0f; }
    if (st->max_abs > 5000000.0f) { score -= 30.0f; }
    if (motion_score >= 8.0f) { score -= 8.0f; }
    if (motion_score >= 16.0f) { score -= 12.0f; }

    if (score < 8.0f)
    {
        *corrupt = true;
    }

    return (uint8_t)phase4_clampf(score, 0.0f, 100.0f);
}

static inline void phase4_select_epoch(phase4_state_t *s, uint32_t ch_idx)
{
    phase4_channel_state_t *ch = &s->ch[ch_idx];
    bool fixed_corrupt = false;
    uint8_t fixed_sqi = phase4_score_candidate(&ch->stats[PHASE4_FIXED_OUTPUT_IDX],
                                               &ch->stats[0],
                                               s->motion_score,
                                               &fixed_corrupt);

#if PHASE4_ENABLE_RA_PAIR_LMS
    bool lms_corrupt = false;
    uint8_t lms_sqi = phase4_score_candidate(&ch->stats[PHASE4_RA_PAIR_LMS_IDX],
                                             &ch->stats[0],
                                             s->motion_score,
                                             &lms_corrupt);
#endif
#if PHASE4_ENABLE_RF_SELECTOR
    fixed_sqi = phase4_rf_candidate_score(s, ch_idx, PHASE4_FIXED_OUTPUT_IDX);
    if (fixed_sqi < 50U)
    {
        fixed_corrupt = true;
    }
#if PHASE4_ENABLE_RA_PAIR_LMS
    lms_sqi = phase4_rf_candidate_score(s, ch_idx, PHASE4_RA_PAIR_LMS_IDX);
    if (lms_sqi < 50U)
    {
        lms_corrupt = true;
    }
#endif
#endif

    uint8_t next_combo = PHASE4_FIXED_OUTPUT_COMBO;
    uint8_t next_sqi = fixed_sqi;
    bool next_corrupt = fixed_corrupt;

#if PHASE4_ENABLE_RA_PAIR_LMS
    bool was_lms = (ch->current_combo == PHASE4_RA_PAIR_LMS_COMBO);
    if (!fixed_corrupt && !lms_corrupt)
    {
        bool switch_to_lms = false;
        if (was_lms)
        {
            switch_to_lms = ((uint16_t)lms_sqi + PHASE4_LMS_HOLD_MARGIN) >= (uint16_t)fixed_sqi;
        }
        else
        {
            switch_to_lms = (uint16_t)lms_sqi >= ((uint16_t)fixed_sqi + PHASE4_LMS_SWITCH_MARGIN);
        }

        if (switch_to_lms)
        {
            next_combo = PHASE4_RA_PAIR_LMS_COMBO;
            next_sqi = lms_sqi;
        }
        next_corrupt = false;
    }
    else if (fixed_corrupt && !lms_corrupt)
    {
        next_combo = PHASE4_RA_PAIR_LMS_COMBO;
        next_sqi = lms_sqi;
        next_corrupt = false;
    }
    else if (!fixed_corrupt && lms_corrupt)
    {
        next_combo = PHASE4_FIXED_OUTPUT_COMBO;
        next_sqi = fixed_sqi;
        next_corrupt = false;
    }
    else
    {
        /* Both candidates corrupt: emit the RA-pair NLMS (suppressed) output so
         * the selected/displayed trace stays the MAS-suppressed signal. Epoch
         * remains flagged corrupt via next_corrupt. */
        next_combo = PHASE4_RA_PAIR_LMS_COMBO;
        next_sqi = (lms_sqi > fixed_sqi) ? lms_sqi : fixed_sqi;
        next_corrupt = true;
    }
#endif

    ch->current_combo = next_combo;
    ch->last_sqi = next_sqi;
    ch->last_corrupt = next_corrupt;
}

static inline void phase4_update_motion_score(phase4_state_t *s,
                                              const float refs[IMU_COUNT][6])
{
    float sumsq = 0.0f;
    for (uint32_t site = 0U; site < IMU_COUNT; site++)
    {
        for (uint32_t axis = 0U; axis < 6U; axis++)
        {
            float w = (axis < 3U) ? 1.0f : 0.01f;
            sumsq += w * refs[site][axis] * refs[site][axis];
        }
    }
    float energy = sqrtf(sumsq / 18.0f);

    if (s->baseline_samples < (5U * PHASE4_ECG_FS_HZ))
    {
        s->baseline_samples++;
        float k = 1.0f / (float)s->baseline_samples;
        s->motion_baseline += k * (energy - s->motion_baseline);
        s->motion_dev += k * (phase4_absf(energy - s->motion_baseline) - s->motion_dev);
        s->motion_score = 0.0f;
        return;
    }

    float dev_floor = s->motion_baseline * 0.25f;
    if (dev_floor < 1.0e-3f) { dev_floor = 1.0e-3f; }
    float dev = (s->motion_dev > dev_floor) ? s->motion_dev : dev_floor;
    s->motion_score = phase4_clampf((energy - s->motion_baseline) / dev, 0.0f, 99.0f);
    s->motion_dev = 0.999f * s->motion_dev +
                    0.001f * phase4_absf(energy - s->motion_baseline);
}

static inline void phase4_sort_float(float *values, uint32_t count)
{
    for (uint32_t ii = 1U; ii < count; ii++)
    {
        float v = values[ii];
        int32_t jj = (int32_t)ii - 1;
        while ((jj >= 0) && (values[jj] > v))
        {
            values[jj + 1] = values[jj];
            jj--;
        }
        values[jj + 1] = v;
    }
}

static inline float phase4_median_float(float *values, uint32_t count)
{
    if ((values == NULL) || (count == 0U))
    {
        return 0.0f;
    }
    phase4_sort_float(values, count);
    if ((count & 1U) != 0U)
    {
        return values[count / 2U];
    }
    return 0.5f * (values[(count / 2U) - 1U] + values[count / 2U]);
}

static inline uint32_t phase4_elapsed_us(uint32_t newer_us, uint32_t older_us)
{
    return (uint32_t)(newer_us - older_us);
}

static inline bool phase4_qrs_get_sample(const phase4_qrs_state_t *qrs,
                                         uint32_t sample_idx,
                                         float *value)
{
    if ((qrs == NULL) || (value == NULL) || (sample_idx > qrs->sample_index))
    {
        return false;
    }
    if ((qrs->sample_index - sample_idx) >= PHASE4_QRS_SAMPLE_RING)
    {
        return false;
    }
    *value = qrs->sample_ring[sample_idx % PHASE4_QRS_SAMPLE_RING];
    return phase4_is_finite(*value);
}

static inline bool phase4_qrs_get_sample_time(const phase4_qrs_state_t *qrs,
                                              uint32_t sample_idx,
                                              uint32_t *time_us)
{
    if ((qrs == NULL) || (time_us == NULL) || (sample_idx > qrs->sample_index))
    {
        return false;
    }
    if ((qrs->sample_index - sample_idx) >= PHASE4_QRS_SAMPLE_RING)
    {
        return false;
    }
    *time_us = qrs->time_ring_us[sample_idx % PHASE4_QRS_SAMPLE_RING];
    return true;
}

static inline void phase4_qrs_store_sample(phase4_qrs_state_t *qrs,
                                           float y,
                                           uint32_t sample_time_us)
{
    if (!phase4_is_finite(y))
    {
        y = 0.0f;
    }
    qrs->sample_ring[qrs->sample_index % PHASE4_QRS_SAMPLE_RING] = y;
    qrs->time_ring_us[qrs->sample_index % PHASE4_QRS_SAMPLE_RING] = sample_time_us;
}

static inline float phase4_qrs_peak_strength(const phase4_qrs_state_t *qrs,
                                             uint32_t r_sample)
{
    float peak = 0.0f;
    if (!phase4_qrs_get_sample(qrs, r_sample, &peak))
    {
        return 0.0f;
    }

    uint32_t b0 = (r_sample > ((250U * PHASE4_ECG_FS_HZ + 500U) / 1000U)) ?
                  (r_sample - ((250U * PHASE4_ECG_FS_HZ + 500U) / 1000U)) : 0U;
    uint32_t b1 = (r_sample > ((120U * PHASE4_ECG_FS_HZ + 500U) / 1000U)) ?
                  (r_sample - ((120U * PHASE4_ECG_FS_HZ + 500U) / 1000U)) : b0;
    if (b1 < b0) { b1 = b0; }

    float vals[PHASE4_QRS_SAMPLE_RING];
    uint32_t n = 0U;
    for (uint32_t ii = b0; ii <= b1; ii++)
    {
        float v = 0.0f;
        if (phase4_qrs_get_sample(qrs, ii, &v) && (n < PHASE4_QRS_SAMPLE_RING))
        {
            vals[n++] = v;
        }
        if (ii == UINT32_MAX) { break; }
    }

    float baseline = 0.0f;
    if (n > 0U)
    {
        baseline = phase4_median_float(vals, n);
    }
    return phase4_absf(peak - baseline);
}

static inline float phase4_qrs_recent_value_polarity(const phase4_qrs_state_t *qrs)
{
    if ((qrs == NULL) || (qrs->r_count < 3U))
    {
        return 0.0f;
    }

    float vals[5];
    uint32_t n = 0U;
    uint32_t count = (qrs->r_count < 5U) ? qrs->r_count : 5U;
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        uint32_t idx = (qrs->r_write + PHASE4_RR_HISTORY - 1U - ii) % PHASE4_RR_HISTORY;
        float v = qrs->r_value[idx];
        if (phase4_is_finite(v))
        {
            vals[n++] = v;
        }
    }
    if (n == 0U)
    {
        return 0.0f;
    }
    float med = phase4_median_float(vals, n);
    if (med > 0.0f) { return 1.0f; }
    if (med < 0.0f) { return -1.0f; }
    return 0.0f;
}

static inline bool phase4_qrs_localize_peak(const phase4_qrs_state_t *qrs,
                                            uint32_t search0,
                                            uint32_t search1,
                                            uint32_t *r_out)
{
    if ((qrs == NULL) || (r_out == NULL) || (search0 > search1))
    {
        return false;
    }
    if (search1 > qrs->sample_index)
    {
        search1 = qrs->sample_index;
    }

    float polarity = phase4_qrs_recent_value_polarity(qrs);
    float best_score = -1.0f;
    uint32_t best_idx = search0;
    for (uint32_t ii = search0; ii <= search1; ii++)
    {
        float v = 0.0f;
        if (!phase4_qrs_get_sample(qrs, ii, &v))
        {
            continue;
        }

        float score = phase4_absf(v);
        if (polarity > 0.0f) { score = v; }
        else if (polarity < 0.0f) { score = -v; }

        if (score > best_score)
        {
            best_score = score;
            best_idx = ii;
        }
        if (ii == UINT32_MAX) { break; }
    }

    if (best_score < 0.0f)
    {
        return false;
    }
    *r_out = best_idx;
    return true;
}

static inline float phase4_qrs_median_rr(const phase4_qrs_state_t *qrs)
{
    if ((qrs == NULL) || (qrs->rr_count == 0U))
    {
        return 0.0f;
    }

    float sorted[PHASE4_RR_HISTORY];
    uint32_t count = qrs->rr_count;
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        sorted[ii] = qrs->rr_ms[ii];
    }

    return phase4_median_float(sorted, count);
}

static inline float phase4_qrs_recent_rr_median(const phase4_qrs_state_t *qrs,
                                                uint32_t max_count,
                                                float min_ms,
                                                float max_ms)
{
    if ((qrs == NULL) || (qrs->rr_count == 0U))
    {
        return 0.0f;
    }

    float vals[PHASE4_RR_HISTORY];
    uint32_t n = 0U;
    uint32_t count = qrs->rr_count;
    if (count > max_count) { count = max_count; }
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        uint32_t idx = (qrs->rr_write + PHASE4_RR_HISTORY - 1U - ii) % PHASE4_RR_HISTORY;
        float rr = qrs->rr_ms[idx];
        if (phase4_is_finite(rr) && (rr >= min_ms) && (rr <= max_ms))
        {
            vals[n++] = rr;
        }
    }
    if (n == 0U)
    {
        return 0.0f;
    }
    return phase4_median_float(vals, n);
}

static inline float phase4_qrs_recent_strength_median(const phase4_qrs_state_t *qrs)
{
    if ((qrs == NULL) || (qrs->r_count == 0U))
    {
        return 0.0f;
    }

    float vals[5];
    uint32_t n = 0U;
    uint32_t count = (qrs->r_count < 5U) ? qrs->r_count : 5U;
    for (uint32_t ii = 0U; ii < count; ii++)
    {
        uint32_t idx = (qrs->r_write + PHASE4_RR_HISTORY - 1U - ii) % PHASE4_RR_HISTORY;
        float v = qrs->r_strength[idx];
        if (phase4_is_finite(v) && (v > 0.0f))
        {
            vals[n++] = v;
        }
    }
    if (n == 0U)
    {
        return 0.0f;
    }
    return phase4_median_float(vals, n);
}

static inline void phase4_qrs_clear_rr_history(phase4_qrs_state_t *qrs)
{
    qrs->rr_count = 0U;
    qrs->rr_write = 0U;
    qrs->hr_bpm = 0.0f;
    qrs->sdnn_ms = 0.0f;
    qrs->rmssd_ms = 0.0f;
    qrs->median_rr_ms = 0.0f;
    qrs->last_hr_sample = 0U;
    qrs->last_hr_time_us = 0U;
}

static inline void phase4_qrs_add_rr(phase4_qrs_state_t *qrs,
                                     float rr_ms,
                                     uint32_t r_time_us)
{
    if (!phase4_is_finite(rr_ms) || (rr_ms <= 0.0f))
    {
        return;
    }

    qrs->rr_ms[qrs->rr_write] = rr_ms;
    qrs->rr_write = (uint8_t)((qrs->rr_write + 1U) % PHASE4_RR_HISTORY);
    if (qrs->rr_count < PHASE4_RR_HISTORY) { qrs->rr_count++; }
    qrs->median_rr_ms = phase4_qrs_median_rr(qrs);
    qrs->hr_bpm = 60000.0f / rr_ms;
    qrs->last_hr_sample = qrs->sample_index;
    qrs->last_hr_time_us = r_time_us;
}

static inline bool phase4_qrs_accept_candidate(phase4_qrs_state_t *qrs,
                                               uint32_t r_sample,
                                               uint32_t trigger_sample)
{
    if ((qrs == NULL) || (r_sample > qrs->sample_index))
    {
        return false;
    }

    float r_value = 0.0f;
    if (!phase4_qrs_get_sample(qrs, r_sample, &r_value))
    {
        return false;
    }
    uint32_t r_time_us = 0U;
    if (!phase4_qrs_get_sample_time(qrs, r_sample, &r_time_us))
    {
        return false;
    }
    float strength = phase4_qrs_peak_strength(qrs, r_sample);

    if (qrs->r_count > 0U)
    {
        if (r_sample <= qrs->last_r_sample)
        {
            return false;
        }

        uint32_t rr_samples = r_sample - qrs->last_r_sample;
        uint32_t rr_delta_us = phase4_elapsed_us(r_time_us, qrs->last_r_time_us);
        if ((rr_samples < PHASE4_QRS_HARD_MIN_SAMPLES) ||
            (rr_delta_us < PHASE4_QRS_HARD_MIN_US))
        {
            uint32_t last_idx = (qrs->r_write + PHASE4_RR_HISTORY - 1U) % PHASE4_RR_HISTORY;
            if (strength > qrs->r_strength[last_idx])
            {
                qrs->r_sample[last_idx] = r_sample;
                qrs->r_time_us[last_idx] = r_time_us;
                qrs->r_value[last_idx] = r_value;
                qrs->r_strength[last_idx] = strength;
                qrs->last_r_sample = r_sample;
                qrs->last_r_time_us = r_time_us;
                if ((qrs->r_count >= 2U) && (qrs->rr_count > 0U))
                {
                    uint32_t prev_idx = (qrs->r_write + PHASE4_RR_HISTORY - 2U) % PHASE4_RR_HISTORY;
                    uint32_t rr_idx = (qrs->rr_write + PHASE4_RR_HISTORY - 1U) % PHASE4_RR_HISTORY;
                    if (r_sample > qrs->r_sample[prev_idx])
                    {
                        uint32_t dt_us = phase4_elapsed_us(r_time_us, qrs->r_time_us[prev_idx]);
                        if ((dt_us >= PHASE4_QRS_HARD_MIN_US) &&
                            (dt_us <= PHASE4_QRS_MAX_RR_US))
                        {
                            float rr_ms = 0.001f * (float)dt_us;
                            qrs->rr_ms[rr_idx] = rr_ms;
                            qrs->median_rr_ms = phase4_qrs_median_rr(qrs);
                            qrs->hr_bpm = 60000.0f / rr_ms;
                            qrs->last_hr_sample = qrs->sample_index;
                            qrs->last_hr_time_us = r_time_us;
                        }
                    }
                }
                qrs->last_decision_sample = trigger_sample;
            }
            return false;
        }
    }

    if (qrs->r_count > 0U)
    {
        uint32_t rr_delta_us = phase4_elapsed_us(r_time_us, qrs->last_r_time_us);
        float rr_ms = 0.001f * (float)rr_delta_us;
        if ((rr_delta_us >= PHASE4_QRS_HARD_MIN_US) &&
            (rr_delta_us <= PHASE4_QRS_MAX_RR_US))
        {
            phase4_qrs_add_rr(qrs, rr_ms, r_time_us);
        }
        else
        {
            phase4_qrs_clear_rr_history(qrs);
        }
    }

    qrs->r_sample[qrs->r_write] = r_sample;
    qrs->r_time_us[qrs->r_write] = r_time_us;
    qrs->r_value[qrs->r_write] = r_value;
    qrs->r_strength[qrs->r_write] = strength;
    qrs->r_write = (uint8_t)((qrs->r_write + 1U) % PHASE4_RR_HISTORY);
    if (qrs->r_count < PHASE4_RR_HISTORY) { qrs->r_count++; }
    qrs->last_r_sample = r_sample;
    qrs->last_r_time_us = r_time_us;
    qrs->last_decision_sample = trigger_sample;
    return true;
}

static inline void phase4_qrs_update_hrv(phase4_qrs_state_t *qrs)
{
    if (qrs->rr_count > 0U)
    {
        uint32_t recent_count = (qrs->rr_count < 5U) ? qrs->rr_count : 5U;
        float recent_sum = 0.0f;
        uint32_t recent_n = 0U;
        for (uint32_t ii = 0U; ii < recent_count; ii++)
        {
            uint32_t idx = (qrs->rr_write + PHASE4_RR_HISTORY - 1U - ii) % PHASE4_RR_HISTORY;
            float rr = qrs->rr_ms[idx];
            if (phase4_is_finite(rr) &&
                (rr >= PHASE4_QRS_FAST_REVIEW_MS) &&
                (rr <= PHASE4_QRS_MAX_RR_MS))
            {
                recent_sum += rr;
                recent_n++;
            }
        }
        if (recent_n > 0U)
        {
            float rr_mean = recent_sum / (float)recent_n;
            qrs->hr_bpm = 60000.0f / rr_mean;
        }
    }

    if (qrs->rr_count >= 2U)
    {
        uint32_t count = qrs->rr_count;
        uint32_t start = (qrs->rr_count < PHASE4_RR_HISTORY) ? 0U : qrs->rr_write;
        float mean = 0.0f;
        for (uint32_t ii = 0U; ii < count; ii++)
        {
            uint32_t idx = (start + ii) % PHASE4_RR_HISTORY;
            mean += qrs->rr_ms[idx];
        }
        mean /= (float)count;

        float var = 0.0f;
        float diff_sq = 0.0f;
        float prev_rr = 0.0f;
        for (uint32_t ii = 0U; ii < count; ii++)
        {
            uint32_t idx = (start + ii) % PHASE4_RR_HISTORY;
            float rr = qrs->rr_ms[idx];
            float d = rr - mean;
            var += d * d;
            if (ii > 0U)
            {
                float rd = rr - prev_rr;
                diff_sq += rd * rd;
            }
            prev_rr = rr;
        }
        qrs->sdnn_ms = sqrtf(var / (float)count);
        qrs->rmssd_ms = sqrtf(diff_sq / (float)(count - 1U));
    }
}

static inline void phase4_qrs_try_predictive_recovery(phase4_qrs_state_t *qrs)
{
    if ((qrs == NULL) || (qrs->r_count < 4U))
    {
        return;
    }

    float pred_rr_ms = phase4_qrs_recent_rr_median(qrs, 5U, PHASE4_QRS_FAST_REVIEW_MS, 2000.0f);
    if (pred_rr_ms <= 0.0f)
    {
        return;
    }

    uint32_t expected = qrs->last_r_sample +
        (uint32_t)((pred_rr_ms * (float)PHASE4_ECG_FS_HZ / 1000.0f) + 0.5f);
    uint32_t search0 = (expected > PHASE4_QRS_PREDICT_HALF) ?
                       (expected - PHASE4_QRS_PREDICT_HALF) : 0U;
    uint32_t search1 = expected + PHASE4_QRS_PREDICT_HALF;

    if ((qrs->sample_index < search1) ||
        (search0 <= (qrs->last_r_sample + PHASE4_QRS_REFRACTORY_SAMPLES)))
    {
        return;
    }
    if (search1 > qrs->sample_index)
    {
        search1 = qrs->sample_index;
    }

    uint32_t r = 0U;
    if (!phase4_qrs_localize_peak(qrs, search0, search1, &r))
    {
        return;
    }

    float recent_strength = phase4_qrs_recent_strength_median(qrs);
    float cand_strength = phase4_qrs_peak_strength(qrs, r);
    if ((recent_strength > 0.0f) && (cand_strength < (0.35f * recent_strength)))
    {
        return;
    }

    (void)phase4_qrs_accept_candidate(qrs, r, qrs->sample_index);
}

static inline void phase4_qrs_update(phase4_qrs_state_t *qrs,
                                     float y,
                                     uint32_t sample_time_us)
{
    if (!qrs->initialized)
    {
        memset(qrs, 0, sizeof(*qrs));
        qrs->initialized = true;
        qrs->prev = y;
        qrs->threshold = 3.4e38f;
        phase4_qrs_store_sample(qrs, y, sample_time_us);
        return;
    }

    qrs->sample_index++;
    phase4_qrs_store_sample(qrs, y, sample_time_us);

    float d = phase4_is_finite(y) && phase4_is_finite(qrs->prev) ? (y - qrs->prev) : 0.0f;
    qrs->prev = y;
    float env_sample = d * d;
    if (!phase4_is_finite(env_sample)) { env_sample = 0.0f; }
    if (qrs->env_count < PHASE4_QRS_ENV_SAMPLES)
    {
        qrs->env_buf[qrs->env_write] = env_sample;
        qrs->env_sum += env_sample;
        qrs->env_count++;
    }
    else
    {
        qrs->env_sum -= qrs->env_buf[qrs->env_write];
        qrs->env_buf[qrs->env_write] = env_sample;
        qrs->env_sum += env_sample;
    }
    qrs->env_write = (uint8_t)((qrs->env_write + 1U) % PHASE4_QRS_ENV_SAMPLES);
    qrs->env = (qrs->env_count > 0U) ? (qrs->env_sum / (float)qrs->env_count) : 0.0f;

    if (qrs->sample_index <= PHASE4_QRS_WARMUP_SAMPLES)
    {
        if (qrs->warm_count < PHASE4_QRS_WARMUP_SAMPLES)
        {
            qrs->warm_env[qrs->warm_count++] = qrs->env;
        }
        if (qrs->sample_index == PHASE4_QRS_WARMUP_SAMPLES)
        {
            float tmp[PHASE4_QRS_WARMUP_SAMPLES];
            for (uint32_t ii = 0U; ii < qrs->warm_count; ii++)
            {
                tmp[ii] = qrs->warm_env[ii];
            }
            float med = phase4_median_float(tmp, qrs->warm_count);
            for (uint32_t ii = 0U; ii < qrs->warm_count; ii++)
            {
                tmp[ii] = phase4_absf(qrs->warm_env[ii] - med);
            }
            float mad = phase4_median_float(tmp, qrs->warm_count);
            if (mad <= 0.0f) { mad = 1.0e-6f; }
            qrs->noise = med;
            qrs->signal = med + 6.0f * mad;
            qrs->threshold = med + 3.0f * mad;
        }
        return;
    }

    if ((qrs->env > qrs->threshold) &&
        ((qrs->last_decision_sample == 0U) ||
         ((qrs->sample_index - qrs->last_decision_sample) > PHASE4_QRS_REFRACTORY_SAMPLES)))
    {
        uint32_t search0 = (qrs->sample_index > PHASE4_QRS_SEARCH_BACK) ?
                           (qrs->sample_index - PHASE4_QRS_SEARCH_BACK) : 0U;
        uint32_t r = 0U;
        bool accepted = false;
        if (phase4_qrs_localize_peak(qrs, search0, qrs->sample_index, &r))
        {
            accepted = phase4_qrs_accept_candidate(qrs, r, qrs->sample_index);
        }

        if (accepted)
        {
            qrs->signal = 0.875f * qrs->signal + 0.125f * qrs->env;
        }
        else
        {
            qrs->noise = 0.995f * qrs->noise + 0.005f * qrs->env;
        }
    }
    else
    {
        qrs->noise = 0.995f * qrs->noise + 0.005f * qrs->env;
    }

    phase4_qrs_try_predictive_recovery(qrs);

    if (qrs->signal <= qrs->noise)
    {
        qrs->threshold = 1.5f * qrs->noise + 1.0e-6f;
    }
    else
    {
        qrs->threshold = qrs->noise + 0.25f * (qrs->signal - qrs->noise);
    }

    phase4_qrs_update_hrv(qrs);

    qrs->quality = (uint8_t)phase4_clampf(100.0f * qrs->signal /
                                          (qrs->signal + 5.0f * qrs->noise + 1.0f),
                                          0.0f, 100.0f);

    if ((qrs->last_hr_time_us != 0U) &&
        (phase4_elapsed_us(sample_time_us, qrs->last_hr_time_us) > PHASE4_QRS_STALE_US))
    {
        qrs->hr_bpm = 0.0f;
        qrs->sdnn_ms = 0.0f;
        qrs->rmssd_ms = 0.0f;
        qrs->rr_count = 0U;
        qrs->rr_write = 0U;
        qrs->median_rr_ms = 0.0f;
        qrs->last_hr_sample = 0U;
        qrs->last_hr_time_us = 0U;
    }
}

static inline void phase4_update_primary_lead(phase4_state_t *s)
{
    if (!s->ch[0].last_corrupt &&
        (s->ch[1].last_corrupt || (s->ch[0].last_sqi >= s->ch[1].last_sqi)))
    {
        s->primary_lead = 1U;
    }
    else if (!s->ch[1].last_corrupt)
    {
        s->primary_lead = 2U;
    }
}

#if PHASE4_ENABLE_M4_SELECTOR
static inline void phase4_m4_zero_mailbox(volatile phase4_ipc_mailbox_t *mb)
{
    volatile uint32_t *p = (volatile uint32_t *)mb;
    uint32_t words = (uint32_t)(sizeof(phase4_ipc_mailbox_t) / sizeof(uint32_t));
    for (uint32_t ii = 0U; ii < words; ii++)
    {
        p[ii] = 0U;
    }
}

static inline void phase4_m4_init_mailbox(phase4_state_t *s)
{
    if (s->m4_ipc_initialized)
    {
        return;
    }

    volatile phase4_ipc_mailbox_t *mb = PHASE4_IPC_MAILBOX;
    phase4_m4_zero_mailbox(mb);
    mb->magic = PHASE4_IPC_MAGIC;
    mb->version = PHASE4_IPC_VERSION;
    mb->job_state = PHASE4_IPC_JOB_IDLE;
    mb->result_ready = 0U;
    __DSB();
    MU_Init(PHASE4_M4_MU_BASE);
    s->m4_ipc_initialized = true;
}

static inline void phase4_m4_copy_candidate_stats(volatile phase4_ipc_candidate_stats_t *dst,
                                                  const phase4_candidate_stats_t *src)
{
    dst->n = src->n;
    dst->sum = src->sum;
    dst->sumsq = src->sumsq;
    dst->sum3 = src->sum3;
    dst->sum4 = src->sum4;
    dst->deriv_abs = src->deriv_abs;
    dst->delta_sum = src->delta_sum;
    dst->delta_sumsq = src->delta_sumsq;
    dst->max_abs = src->max_abs;
    dst->prev = src->prev;
    dst->cross_pre = src->cross_pre;
    dst->ref_sumsq = src->ref_sumsq;
    dst->ref_count = src->ref_count;
    dst->reserved[0] = 0U;
    dst->reserved[1] = 0U;
    dst->reserved[2] = 0U;
    for (uint32_t ii = 0U; ii < PHASE4_EPOCH_SAMPLES; ii++)
    {
        dst->sample[ii] = src->sample[ii];
        dst->ref_env[ii] = src->ref_env[ii];
    }
}

static inline void phase4_m4_post_epoch(phase4_state_t *s, uint32_t completed_epoch_seq)
{
    phase4_m4_init_mailbox(s);
    volatile phase4_ipc_mailbox_t *mb = PHASE4_IPC_MAILBOX;

    if (mb->job_state != PHASE4_IPC_JOB_IDLE)
    {
        if ((completed_epoch_seq - mb->job.epoch_seq) > 2U)
        {
            mb->job_state = PHASE4_IPC_JOB_IDLE;
        }
        else
        {
            s->m4_jobs_dropped++;
            mb->jobs_dropped++;
            return;
        }
    }

    volatile phase4_ipc_epoch_job_t *job = &mb->job;
    job->epoch_seq = completed_epoch_seq;
    job->sample_count = s->sample_count;
    job->motion_score = s->motion_score;
    job->motion_baseline = s->motion_baseline;
    job->motion_dev = s->motion_dev;

    for (uint32_t ch = 0U; ch < PHASE4_CHANNEL_COUNT; ch++)
    {
        job->valid_mask[ch] = PHASE4_M4_CANDIDATE_MASK;
        for (uint32_t cc = 0U; cc < PHASE4_CANDIDATE_COUNT; cc++)
        {
            phase4_m4_copy_candidate_stats(&job->stats[ch][cc],
                                           &s->ch[ch].stats[cc]);
        }
    }

    __DSB();
    mb->job_state = PHASE4_IPC_JOB_READY;
    mb->jobs_posted++;
    s->m4_jobs_posted++;

    uint32_t flags = MU_GetStatusFlags(PHASE4_M4_MU_BASE);
    if ((flags & (uint32_t)kMU_Tx0EmptyFlag) != 0U)
    {
        MU_SendMsgNonBlocking(PHASE4_M4_MU_BASE, kMU_MsgReg0, completed_epoch_seq);
    }
    (void)MU_TriggerInterrupts(PHASE4_M4_MU_BASE, kMU_GenInt0InterruptTrigger);
}

static inline void phase4_m4_try_consume_result(phase4_state_t *s)
{
    phase4_m4_init_mailbox(s);
    volatile phase4_ipc_mailbox_t *mb = PHASE4_IPC_MAILBOX;
    if (mb->result_ready == 0U)
    {
        return;
    }

    uint32_t seq = mb->result.epoch_seq;
    if ((seq == 0U) || (seq == s->m4_last_result_seq))
    {
        mb->result_ready = 0U;
        return;
    }

    for (uint32_t ch = 0U; ch < PHASE4_CHANNEL_COUNT; ch++)
    {
        uint8_t combo = mb->result.selected_combo[ch];
        if ((combo < 1U) || (combo > PHASE4_CANDIDATE_COUNT))
        {
            combo = PHASE4_FIXED_OUTPUT_COMBO;
        }
        uint32_t selected_idx = (uint32_t)combo - 1U;
        if ((mb->result.valid_mask[ch] & (1UL << selected_idx)) == 0U)
        {
            combo = PHASE4_FIXED_OUTPUT_COMBO;
            selected_idx = PHASE4_FIXED_OUTPUT_IDX;
        }
        s->m4_last_selected_combo[ch] = combo;
        s->m4_last_selected_prob_x1000[ch] = mb->result.prob_x1000[ch][selected_idx];
#if PHASE4_M4_ALLOW_SWITCHING
        s->ch[ch].current_combo = combo;
        s->ch[ch].last_sqi = (mb->result.sqi[ch] <= 100U) ? mb->result.sqi[ch] : 0U;
        s->ch[ch].last_corrupt = (mb->result.corrupt[ch] != 0U);
#if PHASE4_ENABLE_RA_PAIR_LMS
        /* Corrupt epoch: force the RA-pair NLMS (suppressed) candidate so the
         * selected/displayed trace remains MAS-suppressed even when the M4
         * usability gate flags the epoch. */
        if (s->ch[ch].last_corrupt)
        {
            s->ch[ch].current_combo = PHASE4_RA_PAIR_LMS_COMBO;
        }
#endif
#else
        uint32_t fixed_idx = PHASE4_FIXED_OUTPUT_IDX;
        uint32_t fixed_bit = (1UL << fixed_idx);
        if ((mb->result.valid_mask[ch] & fixed_bit) != 0U)
        {
            uint16_t p = mb->result.prob_x1000[ch][fixed_idx];
            s->ch[ch].last_sqi = (uint8_t)((p + 5U) / 10U);
            s->ch[ch].last_corrupt = (p < 500U);
        }
        else
        {
            s->ch[ch].last_sqi = (mb->result.sqi[ch] <= 100U) ? mb->result.sqi[ch] : 0U;
            s->ch[ch].last_corrupt = (mb->result.corrupt[ch] != 0U);
        }
        s->ch[ch].current_combo = PHASE4_FIXED_OUTPUT_COMBO;
#endif
    }

    s->m4_last_result_seq = seq;
    s->m4_last_cycles = mb->result.m4_cycles;
    s->label_epoch_seq = seq;
    s->label_epoch_valid = true;
    mb->results_consumed++;
    mb->result_ready = 0U;
    phase4_update_primary_lead(s);
}
#endif

static inline float phase4_process_channel(phase4_channel_state_t *ch,
                                           uint32_t ch_idx,
                                           float raw_ecg,
                                           const float site_refs[IMU_COUNT][6])
{
#if PHASE4_PROCESS_ALL_CANDIDATES || PHASE4_ENABLE_RA_PAIR_LMS
    float candidate_refs[PHASE4_MAS_MAX_REFS];
#else
    (void)site_refs;
#endif

    if (!ch->initialized)
    {
        ch->initialized = true;
        ch->first_ecg = raw_ecg;
        ch->osc_cos = 1.0f;
        ch->osc_sin = 0.0f;
        ch->current_combo = PHASE4_FIXED_OUTPUT_COMBO;
    }

    float centered = raw_ecg - ch->first_ecg;
    float bpf = phase4_biquad_cascade(centered, phase4_b8_sos,
                                      ch->bpf, PHASE4_BIQUAD_STAGES);
    float pre = phase4_n3_step(bpf, ch);
    ch->last_candidates[0] = phase4_baseline_remove(ch, 0U, pre);
    ch->last_ref_env[0] = 0.0f;
    ch->last_ref_count[0] = 0U;

#if PHASE4_PROCESS_ALL_CANDIDATES
    for (uint32_t cc = 1U; cc < PHASE4_CANDIDATE_COUNT; cc++)
    {
        uint8_t ref_count = phase4_build_candidate_refs((uint8_t)(cc + 1U),
                                                        ch_idx,
                                                        site_refs,
                                                        candidate_refs);
        float ref_env = phase4_reference_envelope_sample(candidate_refs, ref_count);
        if (ch->ref_env_lp[cc] == 0.0f)
        {
            ch->ref_env_lp[cc] = ref_env;
        }
        else
        {
            ch->ref_env_lp[cc] = PHASE4_REF_ENV_AVG_ALPHA * ch->ref_env_lp[cc] +
                                 (1.0f - PHASE4_REF_ENV_AVG_ALPHA) * ref_env;
        }
        ch->last_ref_env[cc] = ch->ref_env_lp[cc];
        ch->last_ref_count[cc] = ref_count;
        float mas_y = phase4_mas_lms_step(pre,
                                          candidate_refs,
                                          ref_count,
                                          &ch->mas[cc]);
        ch->last_candidates[cc] = phase4_baseline_remove(ch, cc, mas_y);
    }
#else
    for (uint32_t cc = 1U; cc < PHASE4_CANDIDATE_COUNT; cc++)
    {
        ch->last_candidates[cc] = ch->last_candidates[0];
        ch->last_ref_env[cc] = 0.0f;
        ch->last_ref_count[cc] = 0U;
    }
#if PHASE4_ENABLE_RA_PAIR_LMS
    uint8_t ref_count = phase4_build_candidate_refs(PHASE4_RA_PAIR_LMS_COMBO,
                                                    ch_idx,
                                                    site_refs,
                                                    candidate_refs);
    float ref_env = phase4_reference_envelope_sample(candidate_refs, ref_count);
    if (ch->ref_env_lp[PHASE4_RA_PAIR_LMS_IDX] == 0.0f)
    {
        ch->ref_env_lp[PHASE4_RA_PAIR_LMS_IDX] = ref_env;
    }
    else
    {
        ch->ref_env_lp[PHASE4_RA_PAIR_LMS_IDX] =
            PHASE4_REF_ENV_AVG_ALPHA * ch->ref_env_lp[PHASE4_RA_PAIR_LMS_IDX] +
            (1.0f - PHASE4_REF_ENV_AVG_ALPHA) * ref_env;
    }
    ch->last_ref_env[PHASE4_RA_PAIR_LMS_IDX] = ch->ref_env_lp[PHASE4_RA_PAIR_LMS_IDX];
    ch->last_ref_count[PHASE4_RA_PAIR_LMS_IDX] = ref_count;
    float mas_y = phase4_mas_lms_step(pre,
                                      candidate_refs,
                                      ref_count,
                                      &ch->mas[PHASE4_RA_PAIR_LMS_IDX]);
    ch->last_candidates[PHASE4_RA_PAIR_LMS_IDX] =
        phase4_baseline_remove(ch, PHASE4_RA_PAIR_LMS_IDX, mas_y);
#endif
#endif

#if PHASE4_PROCESS_ALL_CANDIDATES
    for (uint32_t cc = 0U; cc < PHASE4_CANDIDATE_COUNT; cc++)
    {
        phase4_stats_update(&ch->stats[cc],
                            ch->last_candidates[cc],
                            ch->last_candidates[0],
                            ch->last_ref_env[cc],
                            ch->last_ref_count[cc]);
    }
#else
    phase4_stats_update(&ch->stats[0],
                        ch->last_candidates[0],
                        ch->last_candidates[0],
                        ch->last_ref_env[0],
                        ch->last_ref_count[0]);
#if PHASE4_ENABLE_RA_PAIR_LMS
    phase4_stats_update(&ch->stats[PHASE4_RA_PAIR_LMS_IDX],
                        ch->last_candidates[PHASE4_RA_PAIR_LMS_IDX],
                        ch->last_candidates[0],
                        ch->last_ref_env[PHASE4_RA_PAIR_LMS_IDX],
                        ch->last_ref_count[PHASE4_RA_PAIR_LMS_IDX]);
#endif
#endif

    uint8_t selected = ch->current_combo;
    if ((selected == 0U) || (selected > PHASE4_CANDIDATE_COUNT))
    {
        selected = PHASE4_FIXED_OUTPUT_COMBO;
    }
    return ch->last_candidates[selected - 1U];
}

static inline void Phase4_Init(phase4_state_t *s)
{
    memset(s, 0, sizeof(*s));
    s->primary_lead = 1U;
    s->epoch_seq = 1U;
    for (uint32_t cc = 0U; cc < PHASE4_CHANNEL_COUNT; cc++)
    {
        s->ch[cc].current_combo = PHASE4_FIXED_OUTPUT_COMBO;
    }
#if PHASE4_ENABLE_M4_SELECTOR
    phase4_m4_init_mailbox(s);
#endif
}

static inline void Phase4_RecordLoopCycles(phase4_state_t *s, uint32_t cycles)
{
    if (cycles > s->loop_cycles_max)
    {
        s->loop_cycles_max = cycles;
    }
}

static inline uint8_t phase4_valid_combo_or_fixed(uint8_t combo)
{
    if ((combo == 0U) || (combo > PHASE4_CANDIDATE_COUNT))
    {
        return PHASE4_FIXED_OUTPUT_COMBO;
    }
    return combo;
}

static inline uint8_t phase4_qrs_source_idx(uint8_t selected_combo)
{
#if PHASE4_QRS_USE_RA_PAIR_FOR_HRV
    (void)selected_combo;
    return PHASE4_RA_PAIR_LMS_IDX;
#else
    uint8_t combo = phase4_valid_combo_or_fixed(selected_combo);
    return (uint8_t)(combo - 1U);
#endif
}

static inline uint16_t phase4_update_fast_validity(phase4_channel_state_t *ch,
                                                   int32_t raw_ecg,
                                                   float y)
{
    uint16_t flags = 0U;
    int32_t raw_abs = (raw_ecg < 0) ? -raw_ecg : raw_ecg;

    if (raw_abs >= PHASE4_ADS1293_RAIL_LIMIT)
    {
        ch->fast_sat_hold = PHASE4_FAST_HOLD_SAMPLES;
    }

    if (ch->fast_validity_ready)
    {
        float dy = phase4_absf(y - ch->fast_prev_y);
        float draw = phase4_absf((float)raw_ecg - (float)ch->fast_prev_raw);

        if ((dy > PHASE4_FAST_SPIKE_DELTA_CODES) ||
            (draw > (4.0f * PHASE4_FAST_SPIKE_DELTA_CODES)))
        {
            ch->fast_spike_hold = PHASE4_FAST_HOLD_SAMPLES;
        }

        if ((dy < PHASE4_FAST_FLAT_DELTA_CODES) &&
            (draw < (4.0f * PHASE4_FAST_FLAT_DELTA_CODES)))
        {
            if (ch->fast_flat_count < PHASE4_FAST_FLAT_MIN_SAMPLES)
            {
                ch->fast_flat_count++;
            }
        }
        else
        {
            ch->fast_flat_count = 0U;
        }
    }
    else
    {
        ch->fast_validity_ready = true;
        ch->fast_flat_count = 0U;
    }

    ch->fast_prev_raw = raw_ecg;
    ch->fast_prev_y = phase4_is_finite(y) ? y : 0.0f;

    if (ch->fast_sat_hold > 0U)
    {
        flags |= PHASE4_FLAG_ADS_SATURATED;
        ch->fast_sat_hold--;
    }
    if (ch->fast_spike_hold > 0U)
    {
        flags |= PHASE4_FLAG_ECG_SPIKE;
        ch->fast_spike_hold--;
    }
    if (ch->fast_flat_count >= PHASE4_FAST_FLAT_MIN_SAMPLES)
    {
        flags |= PHASE4_FLAG_ECG_FLATLINE;
    }

    return flags;
}

static inline void phase4_update_qrs_trackers(phase4_state_t *s, uint32_t sample_time_us)
{
    if (s == NULL)
    {
        return;
    }

#if PHASE4_QRS_TRACK_ALL_CANDIDATES
    for (uint32_t ch = 0U; ch < PHASE4_CHANNEL_COUNT; ch++)
    {
        for (uint32_t cc = 0U; cc < PHASE4_CANDIDATE_COUNT; cc++)
        {
            phase4_qrs_update(&s->qrs[ch][cc],
                              s->ch[ch].last_candidates[cc],
                              sample_time_us);
        }
    }
#else
    for (uint32_t ch = 0U; ch < PHASE4_CHANNEL_COUNT; ch++)
    {
#if PHASE4_ENABLE_RA_PAIR_LMS
        phase4_qrs_update(&s->qrs[ch][PHASE4_FIXED_OUTPUT_IDX],
                          s->ch[ch].last_candidates[PHASE4_FIXED_OUTPUT_IDX],
                          sample_time_us);
        phase4_qrs_update(&s->qrs[ch][PHASE4_RA_PAIR_LMS_IDX],
                          s->ch[ch].last_candidates[PHASE4_RA_PAIR_LMS_IDX],
                          sample_time_us);
#else
        uint8_t combo = phase4_valid_combo_or_fixed(s->ch[ch].current_combo);
        uint32_t idx = (uint32_t)combo - 1U;
        phase4_qrs_update(&s->qrs[ch][idx],
                          s->ch[ch].last_candidates[idx],
                          sample_time_us);
#endif
    }
#endif
}

static inline void Phase4_ProcessAds1293Imu(phase4_state_t *s,
                                            int32_t ads_ch1,
                                            int32_t ads_ch2,
                                            uint32_t sample_time_us,
                                            const imu_raw_t raw[IMU_COUNT],
                                            phase4_output_t *out)
{
    float refs[IMU_COUNT][6];
    float y[PHASE4_CHANNEL_COUNT];

    if ((s == NULL) || (raw == NULL) || (out == NULL))
    {
        return;
    }

    memset(out, 0, sizeof(*out));
    uint32_t sample_epoch_seq = s->epoch_seq;
    phase4_condition_refs(&s->refs, raw, refs);
    phase4_update_motion_score(s, refs);
#if PHASE4_ENABLE_M4_SELECTOR
    phase4_m4_try_consume_result(s);
#endif

    y[0] = phase4_process_channel(&s->ch[0], 0U, (float)ads_ch1, refs);
    y[1] = phase4_process_channel(&s->ch[1], 1U, (float)ads_ch2, refs);

    phase4_update_qrs_trackers(s, sample_time_us);

    s->sample_count++;
    if ((s->sample_count % PHASE4_EPOCH_SAMPLES) == 0U)
    {
#if PHASE4_ENABLE_M4_SELECTOR
        if (s->m4_last_result_seq == 0U)
        {
            phase4_select_epoch(s, 0U);
            phase4_select_epoch(s, 1U);
            s->label_epoch_seq = sample_epoch_seq;
            s->label_epoch_valid = true;
        }
#else
        phase4_select_epoch(s, 0U);
        phase4_select_epoch(s, 1U);
        s->label_epoch_seq = sample_epoch_seq;
        s->label_epoch_valid = true;
#endif
#if PHASE4_ENABLE_M4_SELECTOR
        phase4_m4_post_epoch(s, sample_epoch_seq);
#endif
        for (uint32_t ch = 0U; ch < PHASE4_CHANNEL_COUNT; ch++)
        {
            for (uint32_t cc = 0U; cc < PHASE4_CANDIDATE_COUNT; cc++)
            {
                phase4_stats_reset(&s->ch[ch].stats[cc]);
            }
        }

        phase4_update_primary_lead(s);
        s->epoch_seq++;
    }

#if PHASE4_PROCESS_ALL_CANDIDATES || PHASE4_ENABLE_RA_PAIR_LMS
    out->ra_pair_ch1 = phase4_i32_round(s->ch[0].last_candidates[PHASE4_RA_PAIR_LMS_IDX]);
    out->ra_pair_ch2 = phase4_i32_round(s->ch[1].last_candidates[PHASE4_RA_PAIR_LMS_IDX]);
#else
    out->ra_pair_ch1 = phase4_i32_round(s->ch[0].last_candidates[PHASE4_FIXED_OUTPUT_IDX]);
    out->ra_pair_ch2 = phase4_i32_round(s->ch[1].last_candidates[PHASE4_FIXED_OUTPUT_IDX]);
#endif
    out->stitched_ch1 = phase4_i32_round(y[0]);
    out->stitched_ch2 = phase4_i32_round(y[1]);
    out->primary_lead = s->primary_lead;
    out->primary_ecg = (s->primary_lead == 2U) ? out->stitched_ch2 : out->stitched_ch1;
    out->sel_ch1 = s->ch[0].current_combo;
    out->sel_ch2 = s->ch[1].current_combo;
    out->sel_ch1 = phase4_valid_combo_or_fixed(out->sel_ch1);
    out->sel_ch2 = phase4_valid_combo_or_fixed(out->sel_ch2);
    uint8_t qrs1_idx = phase4_qrs_source_idx(out->sel_ch1);
    uint8_t qrs2_idx = phase4_qrs_source_idx(out->sel_ch2);
    if (qrs1_idx >= PHASE4_CANDIDATE_COUNT) { qrs1_idx = PHASE4_FIXED_OUTPUT_IDX; }
    if (qrs2_idx >= PHASE4_CANDIDATE_COUNT) { qrs2_idx = PHASE4_FIXED_OUTPUT_IDX; }
    const phase4_qrs_state_t *qrs1 = &s->qrs[0][qrs1_idx];
    const phase4_qrs_state_t *qrs2 = &s->qrs[1][qrs2_idx];
    uint16_t fast_flags = phase4_update_fast_validity(&s->ch[0], ads_ch1, y[0]) |
                          phase4_update_fast_validity(&s->ch[1], ads_ch2, y[1]);
    out->sqi1 = (uint8_t)((s->ch[0].last_sqi + qrs1->quality) / 2U);
    out->sqi2 = (uint8_t)((s->ch[1].last_sqi + qrs2->quality) / 2U);
    out->hr1_x10 = phase4_u16_scaled(qrs1->hr_bpm, 10.0f, 3000.0f);
    out->hr2_x10 = phase4_u16_scaled(qrs2->hr_bpm, 10.0f, 3000.0f);
    out->rmssd1_x10 = phase4_u16_scaled(qrs1->rmssd_ms, 10.0f, 60000.0f);
    out->rmssd2_x10 = phase4_u16_scaled(qrs2->rmssd_ms, 10.0f, 60000.0f);
    out->motion_x10 = phase4_u16_scaled(s->motion_score, 10.0f, 9990.0f);
    out->epoch_seq = sample_epoch_seq;
    out->label_epoch_seq = s->label_epoch_valid ? s->label_epoch_seq : 0xFFFFFFFFUL;
#if PHASE4_ENABLE_M4_SELECTOR
    volatile phase4_ipc_mailbox_t *mb = PHASE4_IPC_MAILBOX;
    out->m4_heartbeat = mb->m4_heartbeat;
    out->m4_jobs_posted = mb->jobs_posted;
    out->m4_results_posted = mb->results_posted;
    out->m4_results_consumed = mb->results_consumed;
    out->m4_jobs_dropped = mb->jobs_dropped;
    out->m4_last_result_seq = s->m4_last_result_seq;
    out->m4_sel_ch1 = s->m4_last_selected_combo[0];
    out->m4_sel_ch2 = s->m4_last_selected_combo[1];
    out->m4_prob1_x1000 = s->m4_last_selected_prob_x1000[0];
    out->m4_prob2_x1000 = s->m4_last_selected_prob_x1000[1];
    out->m4_cycles = s->m4_last_cycles;
#endif

    if (s->ch[0].last_corrupt) { out->flags |= PHASE4_FLAG_CH1_CORRUPT; }
    if (s->ch[1].last_corrupt) { out->flags |= PHASE4_FLAG_CH2_CORRUPT; }
    if (((s->primary_lead == 1U) && s->ch[0].last_corrupt) ||
        ((s->primary_lead == 2U) && s->ch[1].last_corrupt))
    {
        out->flags |= PHASE4_FLAG_PRIMARY_CORRUPT;
    }
    if (s->motion_score >= 3.0f) { out->flags |= PHASE4_FLAG_MOTION_RISK; }
    if (s->motion_score >= 8.0f) { out->flags |= PHASE4_FLAG_MOTION_CORRUPT; }
    out->flags |= fast_flags;
    if (s->sample_count > PHASE4_QRS_READY_SAMPLES)
    {
        const phase4_qrs_state_t *primary_qrs = (s->primary_lead == 2U) ? qrs2 : qrs1;
        uint16_t primary_hr_x10 = (s->primary_lead == 2U) ? out->hr2_x10 : out->hr1_x10;
        uint8_t primary_sqi = (s->primary_lead == 2U) ? out->sqi2 : out->sqi1;
        if ((primary_hr_x10 == 0U) || (primary_qrs->quality < PHASE4_QRS_LOW_QUALITY))
        {
            out->flags |= PHASE4_FLAG_PEAK_UNRELIABLE;
        }
        if (primary_sqi < PHASE4_SQI_LOW_THRESH)
        {
            out->flags |= PHASE4_FLAG_SQI_LOW;
        }
    }
    if ((out->sel_ch1 == PHASE4_RA_PAIR_LMS_COMBO) ||
        (out->sel_ch2 == PHASE4_RA_PAIR_LMS_COMBO))
    {
        out->flags |= PHASE4_FLAG_LMS_ACTIVE;
    }
}

#endif /* PHASE4_REALTIME_H_ */
