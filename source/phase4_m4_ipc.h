#ifndef PHASE4_M4_IPC_H_
#define PHASE4_M4_IPC_H_

#include <stdint.h>

/*
 * CM7 <-> CM4 mailbox for the Phase 4 epoch classifier.
 * Placed at 0x202c8000 (NCACHE region per CM7 linker script, non-cacheable
 * in board.c). Fixed address avoids editing the linker script.
 */

#define PHASE4_IPC_MAGIC               (0x50344943UL) /* "P4IC" */
#define PHASE4_IPC_VERSION             (2UL) /* v2: result.m4_cycles added */
#define PHASE4_IPC_MAILBOX_ADDR        (0x202c8000UL)
#define PHASE4_IPC_MAILBOX_SIZE_BYTES  (0x8000UL)

#define PHASE4_IPC_CHANNEL_COUNT       (2U)
#define PHASE4_IPC_CANDIDATE_COUNT     (6U)
#define PHASE4_IPC_EPOCH_SAMPLES       (200U)
#define PHASE4_IPC_FEATURE_COUNT       (25U)
#define PHASE4_IPC_FIXED_CANDIDATE_IDX (0U)  /* combo 1, BPF+N3 */

#define PHASE4_IPC_JOB_IDLE            (0UL)
#define PHASE4_IPC_JOB_READY           (1UL)
#define PHASE4_IPC_JOB_PROCESSING      (2UL)

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
    uint8_t reserved[3];
    float sample[PHASE4_IPC_EPOCH_SAMPLES];
    float ref_env[PHASE4_IPC_EPOCH_SAMPLES];
} phase4_ipc_candidate_stats_t;

typedef struct
{
    uint32_t epoch_seq;
    uint32_t sample_count;
    uint32_t valid_mask[PHASE4_IPC_CHANNEL_COUNT];
    float motion_score;
    float motion_baseline;
    float motion_dev;
    phase4_ipc_candidate_stats_t stats[PHASE4_IPC_CHANNEL_COUNT][PHASE4_IPC_CANDIDATE_COUNT];
} phase4_ipc_epoch_job_t;

typedef struct
{
    uint32_t epoch_seq;
    uint32_t valid_mask[PHASE4_IPC_CHANNEL_COUNT];
    uint8_t selected_combo[PHASE4_IPC_CHANNEL_COUNT];
    uint8_t sqi[PHASE4_IPC_CHANNEL_COUNT];
    uint8_t corrupt[PHASE4_IPC_CHANNEL_COUNT];
    uint8_t reserved[2];
    uint16_t prob_x1000[PHASE4_IPC_CHANNEL_COUNT][PHASE4_IPC_CANDIDATE_COUNT];
    uint32_t m4_cycles; /* CM4 DWT cycles for one epoch classification */
} phase4_ipc_epoch_result_t;

typedef struct
{
    uint32_t magic;
    uint32_t version;
    volatile uint32_t job_state;
    volatile uint32_t result_ready;
    volatile uint32_t jobs_posted;
    volatile uint32_t jobs_dropped;
    volatile uint32_t results_posted;
    volatile uint32_t results_consumed;
    volatile uint32_t m4_heartbeat;
    uint32_t reserved[7];
    phase4_ipc_epoch_job_t job;
    phase4_ipc_epoch_result_t result;
} phase4_ipc_mailbox_t;

#define PHASE4_IPC_MAILBOX ((volatile phase4_ipc_mailbox_t *)PHASE4_IPC_MAILBOX_ADDR)

#endif /* PHASE4_M4_IPC_H_ */
