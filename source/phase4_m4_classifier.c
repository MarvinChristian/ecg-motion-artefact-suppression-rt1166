/*
 * phase4_m4_classifier.c
 *
 * CM4 worker. Lives in source/ so it ships with the Phase 4 pipeline; the
 * CM7 project auto-discovers source/*.c, so the entire file is guarded by
 * the CM4 CPU define below.
 */

#if defined(CPU_MIMXRT1166DVM6A_cm4) || defined(MIMXRT1166_cm4_SERIES)

#define PHASE4_M4_CLASSIFIER_APP 1
#define PHASE4_ENABLE_RF_SELECTOR 1
#define PHASE4_ENABLE_M4_SELECTOR 0

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "fsl_device_registers.h"
#include "fsl_mu.h"
#include "phase4_realtime.h"
#include "phase4_m4_ipc.h"

#ifndef PHASE4_M4_WORKER_MU_BASE
#define PHASE4_M4_WORKER_MU_BASE MUB
#endif

static void phase4_m4_enable_cycle_counter(void)
{
    /* DWT->CYCCNT on the CM4 core clock; converts to time with kCLOCK_Root_M4
     * (printed by the CM7 boot log). Used to report per-epoch classifier cost. */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0U;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

static void phase4_m4_disable_system_cache(void)
{
    /* The mailbox lives in shared OCRAM. Disable CM4 caching so CM7 and CM4
     * observe job/result state changes without explicit cache maintenance. */
    if ((LMEM->PSCCR & LMEM_PSCCR_ENCACHE_MASK) != 0U)
    {
        LMEM->PSCCR |= LMEM_PSCCR_PUSHW0_MASK | LMEM_PSCCR_PUSHW1_MASK | LMEM_PSCCR_GO_MASK;
        while ((LMEM->PSCCR & LMEM_PSCCR_GO_MASK) != 0U)
        {
        }
        LMEM->PSCCR &= ~(LMEM_PSCCR_PUSHW0_MASK | LMEM_PSCCR_PUSHW1_MASK);
        LMEM->PSCCR &= ~LMEM_PSCCR_ENCACHE_MASK;
    }
    __DSB();
    __ISB();
}

static inline void phase4_m4_trigger_m7(void)
{
    uint32_t mask = (uint32_t)kMU_GenInt0InterruptTrigger;
    uint32_t reg = PHASE4_M4_WORKER_MU_BASE->CR;
    if ((reg & mask) == 0U)
    {
        PHASE4_M4_WORKER_MU_BASE->CR =
            (reg & ~(MU_CR_GIRn_MASK | MU_CR_NMI_MASK)) | mask;
    }
}

static phase4_candidate_stats_t s_pre_stats;
static phase4_candidate_stats_t s_candidate_stats;

static void phase4_m4_copy_stats_from_ipc(phase4_candidate_stats_t *dst,
                                          const volatile phase4_ipc_candidate_stats_t *src)
{
    memset(dst, 0, sizeof(*dst));
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
    for (uint32_t ii = 0U; ii < PHASE4_EPOCH_SAMPLES; ii++)
    {
        dst->sample[ii] = src->sample[ii];
        dst->ref_env[ii] = src->ref_env[ii];
    }
}

static uint16_t phase4_m4_prob_to_x1000(float p)
{
    if (!phase4_is_finite(p))
    {
        p = 0.0f;
    }
    p = phase4_clampf(p, 0.0f, 1.0f);
    return (uint16_t)(p * 1000.0f + 0.5f);
}

static void phase4_m4_score_job(volatile phase4_ipc_mailbox_t *mb)
{
    const volatile phase4_ipc_epoch_job_t *job = &mb->job;
    volatile phase4_ipc_epoch_result_t *result = &mb->result;

    /* Job ownership is controlled by job_state in shared memory; keep this
     * function side-effect limited to result fields and heartbeat counters. */
    result->epoch_seq = job->epoch_seq;
    for (uint32_t ch = 0U; ch < PHASE4_CHANNEL_COUNT; ch++)
    {
        mb->m4_heartbeat++;
        result->valid_mask[ch] = job->valid_mask[ch];

#if PHASE4_TWO_STAGE_DECISION
        /* Stage 1: usability gate on the baseline candidate (combo 1).
         * Stage 2 (only if clean): selection on the suppressed candidate
         * (combo 5). Corruption is its own decision, not "neither candidate
         * cleared the preference threshold". lead_id is feature [0], so the
         * pooled usability/selection models serve both channels. */
        for (uint32_t cc = 0U; cc < PHASE4_CANDIDATE_COUNT; cc++)
        {
            result->prob_x1000[ch][cc] = 0U;
        }

        phase4_m4_copy_stats_from_ipc(&s_pre_stats, &job->stats[ch][PHASE4_FIXED_OUTPUT_IDX]);
        phase4_m4_copy_stats_from_ipc(&s_candidate_stats, &job->stats[ch][PHASE4_RA_PAIR_LMS_IDX]);

        bool baseline_valid   = (job->valid_mask[ch] & (1UL << PHASE4_FIXED_OUTPUT_IDX)) != 0U;
        bool suppressed_valid = (job->valid_mask[ch] & (1UL << PHASE4_RA_PAIR_LMS_IDX)) != 0U;

        float p_clean = 0.0f;
        float p_supp  = 0.0f;
        if (baseline_valid)
        {
            float xb[PHASE4_RF_FEATURE_COUNT];
            phase4_fill_rf_features_from_stats(ch, PHASE4_FIXED_OUTPUT_IDX,
                                               job->motion_score,
                                               job->motion_baseline,
                                               job->motion_dev,
                                               &s_pre_stats, &s_pre_stats, xb);
            p_clean = mas_bag_usability_classify_prob(xb);
        }
        if (suppressed_valid)
        {
            float xs[PHASE4_RF_FEATURE_COUNT];
            phase4_fill_rf_features_from_stats(ch, PHASE4_RA_PAIR_LMS_IDX,
                                               job->motion_score,
                                               job->motion_baseline,
                                               job->motion_dev,
                                               &s_candidate_stats, &s_pre_stats, xs);
            p_supp = mas_bag_selection_classify_prob(xs);
        }
        mb->m4_heartbeat++;

        uint8_t is_corrupt = (!baseline_valid || (p_clean < PHASE4_USABILITY_THRESH)) ? 1U : 0U;
        uint8_t selected   = PHASE4_FIXED_OUTPUT_COMBO;
        if ((is_corrupt == 0U) && suppressed_valid && (p_supp >= PHASE4_SELECTION_THRESH))
        {
            selected = PHASE4_RA_PAIR_LMS_COMBO;
        }

        result->selected_combo[ch] = selected;
        result->corrupt[ch] = is_corrupt;
        result->sqi[ch] = (uint8_t)phase4_clampf(100.0f * p_clean, 0.0f, 100.0f);
        result->prob_x1000[ch][PHASE4_FIXED_OUTPUT_IDX]  = phase4_m4_prob_to_x1000(p_clean);
        result->prob_x1000[ch][PHASE4_RA_PAIR_LMS_IDX]   = phase4_m4_prob_to_x1000(p_supp);
#else
        float best_prob = -1.0f;
        uint8_t best_combo = PHASE4_FIXED_OUTPUT_COMBO;

        phase4_m4_copy_stats_from_ipc(&s_pre_stats, &job->stats[ch][0]);
        for (uint32_t cc = 0U; cc < PHASE4_CANDIDATE_COUNT; cc++)
        {
            mb->m4_heartbeat++;
            result->prob_x1000[ch][cc] = 0U;
            if ((job->valid_mask[ch] & (1UL << cc)) == 0U)
            {
                continue;
            }

            phase4_m4_copy_stats_from_ipc(&s_candidate_stats, &job->stats[ch][cc]);
            float prob = 0.0f;
            (void)phase4_rf_score_from_stats(ch,
                                             cc,
                                             job->motion_score,
                                             job->motion_baseline,
                                             job->motion_dev,
                                             &s_candidate_stats,
                                             &s_pre_stats,
                                             &prob);
            result->prob_x1000[ch][cc] = phase4_m4_prob_to_x1000(prob);
            if (prob > best_prob)
            {
                best_prob = prob;
                best_combo = (uint8_t)(cc + 1U);
            }
        }

        if (best_prob < 0.0f)
        {
            uint32_t fixed = PHASE4_FIXED_OUTPUT_IDX;
            best_prob = (float)result->prob_x1000[ch][fixed] / 1000.0f;
            best_combo = PHASE4_FIXED_OUTPUT_COMBO;
        }

        result->selected_combo[ch] = best_combo;
        result->sqi[ch] = (uint8_t)phase4_clampf(100.0f * best_prob, 0.0f, 100.0f);
        result->corrupt[ch] = (best_prob < 0.50f) ? 1U : 0U;
#endif
    }
    result->reserved[0] = 0U;
    result->reserved[1] = 0U;
}

void MUB_IRQHandler(void)
{
    while ((MU_GetStatusFlags(PHASE4_M4_WORKER_MU_BASE) & (uint32_t)kMU_Rx0FullFlag) != 0U)
    {
        (void)MU_ReceiveMsgNonBlocking(PHASE4_M4_WORKER_MU_BASE, kMU_MsgReg0);
    }
    MU_ClearStatusFlags(PHASE4_M4_WORKER_MU_BASE, kMU_GenInt0Flag);
}

int main(void)
{
    volatile phase4_ipc_mailbox_t *mb = PHASE4_IPC_MAILBOX;

    phase4_m4_enable_cycle_counter();
    phase4_m4_disable_system_cache();
    NVIC_ClearPendingIRQ(MUB_IRQn);
    EnableIRQ(MUB_IRQn);
    MU_EnableInterrupts(PHASE4_M4_WORKER_MU_BASE,
                        kMU_Rx0FullInterruptEnable | kMU_GenInt0InterruptEnable);
    __enable_irq();

    for (;;)
    {
        if ((mb->magic == PHASE4_IPC_MAGIC) &&
            (mb->version == PHASE4_IPC_VERSION))
        {
            if (mb->m4_heartbeat == 0U)
            {
                mb->m4_heartbeat = 1U;
            }

            if (mb->job_state == PHASE4_IPC_JOB_READY)
            {
                mb->job_state = PHASE4_IPC_JOB_PROCESSING;
                __DSB();

                mb->m4_heartbeat++;
                uint32_t m4_t0 = DWT->CYCCNT;
                phase4_m4_score_job(mb);
                mb->result.m4_cycles = DWT->CYCCNT - m4_t0;

                __DSB();
                mb->results_posted++;
                mb->m4_heartbeat++;
                mb->result_ready = 1U;
                mb->job_state = PHASE4_IPC_JOB_IDLE;
                phase4_m4_trigger_m7();
            }
        }

        for (volatile uint32_t spin = 0U; spin < 256U; spin++)
        {
            __NOP();
        }
    }
}

#endif /* CM4 worker build */
