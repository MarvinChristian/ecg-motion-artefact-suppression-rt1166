/*
 * main_phase1.c
 *
 * Phase 1 acquisition firmware. Streams raw ECG (AD8233 or ADS1293) and
 * three MPU-6500 IMUs to UART for offline MATLAB analysis. Compile-time
 * mode selects ECG_ONLY, ECG_IMU, ADS1293_ONLY, or ADS1293_IMU. The
 * ADS1293_IMU mode also runs the Phase 4 real-time pipeline when enabled.
 *
 * Board UART must be set to 500000 baud (board.h:
 *   #define BOARD_DEBUG_UART_BAUDRATE 500000U). ecg_monitor.py must match.
 *
 * IMU data is read raw (IMU_ReadAllRaw) to keep the full DLPF bandwidth
 * (92 Hz at DLPF_CFG=2). The Kalman path in imu_manager.c is not used here.
 *
 * CSV formats:
 *   ECG_ONLY     : t_us, ecg_corr, out_raw, refout_raw
 *   ECG_IMU      : t_us, ecg_corr, 3x(ax,ay,az,gx,gy,gz), out_raw, refout_raw
 *   ADS1293_ONLY : t_us, ads_ch1, ads_ch2
 *   ADS1293_IMU  : t_us, ads_ch1, ads_ch2, + Phase 4 columns when enabled
 *
 * Units:
 *   t_us     uint32 microseconds, low 32 bits of Timebase 64-bit counter
 *   ecg_corr int16 ADC counts, = out_raw - refout_raw, mV = counts*1800/4096
 *   accel    int16 LSB, 1 g = 16384 LSB (FS_SEL=0, MPU-6500 RM 4.2)
 *   gyro     int16 LSB, 1 dps = 131 LSB (FS_SEL=0, MPU-6500 RM 4.4)
 *
 * IMU site mapping:
 *   IMU0 PCS0 J10[6] = LL (left lower thorax)
 *   IMU1 PCS1 J9[5]  = LA (left subclavicular)
 *   IMU2 PCS2 J9[1]  = RA (right subclavicular)
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>

#include "fsl_common.h"
#include "fsl_clock.h"
#include "fsl_debug_console.h"
#include "fsl_device_registers.h"
#include "fsl_soc_src.h"

#include "board.h"
#include "pin_mux.h"
#include "clock_config.h"

#include "app_config_phase1.h"
#include "timebase/timebase.h"
#include "drivers/ads1293.h"
#include "drivers/ecg_adc.h"
#include "drivers/imu_manager.h"

/* Phase 4 build flags. Must precede phase4_realtime.h.
 * Two-stage decision: a pooled usability gate (clean vs corrupted) on the
 * combo-1 baseline, then a pooled selection model (keep baseline vs use
 * suppressed) on clean epochs. Both are exported tree ensembles; lead_id is
 * feature [0], so one model serves both channels. Runtime scores combo 1
 * (fixed BPF+N3) and combo 5 (lead-matched RA-pair NLMS) only. */
#ifndef PHASE4_ENABLE_REALTIME_PIPELINE
#define PHASE4_ENABLE_REALTIME_PIPELINE (1U)
#endif
#ifndef PHASE4_PROCESS_ALL_CANDIDATES
#define PHASE4_PROCESS_ALL_CANDIDATES (0U)
#endif
#ifndef PHASE4_ENABLE_M4_SELECTOR
#define PHASE4_ENABLE_M4_SELECTOR (1U)
#endif
#ifndef PHASE4_M4_ALLOW_SWITCHING
#define PHASE4_M4_ALLOW_SWITCHING (1U)
#endif
#ifndef PHASE4_BOOT_CM4_CLASSIFIER
#define PHASE4_BOOT_CM4_CLASSIFIER (1U)
#endif
#ifndef PHASE4_UART_DIAGNOSTICS
#define PHASE4_UART_DIAGNOSTICS (0U)
#endif

#include "phase4_realtime.h"

/* Compile-time acquisition mode. */

#define PHASE1_ECG_ONLY   (1)
#define PHASE1_ECG_IMU    (2)
#define PHASE1_ADS1293_ONLY (3)
#define PHASE1_ADS1293_IMU  (4)

#define PHASE1_MODE       PHASE1_ADS1293_IMU    /* change here and rebuild */
#define PHASE1_ADS1293_FRONTEND ADS1293_FRONTEND_5_LEAD
#define PHASE1_ADS1293_READY_MASK (0x06U)
#define PHASE1_ADS1293_READY_DEBUG (1U)
#define PHASE1_ADS1293_READY_DEBUG_PERIOD_US (1000000U)

#define PHASE4_CM4_BOOT_ADDRESS (0x30080000UL)
#define PHASE4_CM4_FLASH_END_ADDRESS (0x30180000UL)
#define PHASE4_CM4_BOOT_ADDRESS_STR "0x30080000"
#define PHASE4_CM4_DTCM_START (0x20000000UL)
#define PHASE4_CM4_DTCM_END   (0x20020000UL)
#define PHASE4_CM4_ITCM_START (0x1FFE0000UL)
#define PHASE4_CM4_ITCM_END   (0x20000000UL)
#define PHASE4_CM4_OCRAM_START (0x202C0000UL)
#define PHASE4_CM4_OCRAM_END   (0x202C8000UL)
#define PHASE4_CM4_GO_FLAG      (0xA5A5A5A5UL)
#define PHASE4_CM4_GO_GPR_INDEX (20U)

#define PHASE1_USES_AD8233 \
    ((PHASE1_MODE == PHASE1_ECG_ONLY) || (PHASE1_MODE == PHASE1_ECG_IMU))
#define PHASE1_USES_ADS1293 \
    ((PHASE1_MODE == PHASE1_ADS1293_ONLY) || (PHASE1_MODE == PHASE1_ADS1293_IMU))
#define PHASE1_USES_IMU \
    ((PHASE1_MODE == PHASE1_ECG_IMU) || (PHASE1_MODE == PHASE1_ADS1293_IMU))

#if (PHASE1_MODE != PHASE1_ECG_ONLY) && \
    (PHASE1_MODE != PHASE1_ECG_IMU) && \
    (PHASE1_MODE != PHASE1_ADS1293_ONLY) && \
    (PHASE1_MODE != PHASE1_ADS1293_IMU)
    #error "PHASE1_MODE must be PHASE1_ECG_ONLY, PHASE1_ECG_IMU, PHASE1_ADS1293_ONLY, or PHASE1_ADS1293_IMU"
#endif

/* Print every tick. Effective Fs may drop below APP_ECG_FS_HZ when UART
 * payload exceeds the tick; recover real Fs from t_us in MATLAB. */
#define PHASE1_DECIM   (1U)

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
#define PHASE1_IMU_MATCH_RING_LEN (16U)
#define PHASE1_IMU_MATCH_MAX_DELTA_US (3000U)

typedef struct
{
    uint32_t  t_us;
    imu_raw_t raw[IMU_COUNT];
    bool      valid;
} phase1_imu_match_sample_t;

static uint32_t phase1_abs_time_delta_us(uint32_t a_us, uint32_t b_us)
{
    int32_t delta = (int32_t)(a_us - b_us);
    return (delta < 0) ? (0U - (uint32_t)delta) : (uint32_t)delta;
}

static void phase1_push_imu_match_sample(phase1_imu_match_sample_t ring[PHASE1_IMU_MATCH_RING_LEN],
                                         uint32_t *write_idx,
                                         bool *has_sample)
{
    if ((ring == NULL) || (write_idx == NULL) || (has_sample == NULL))
    {
        return;
    }

    phase1_imu_match_sample_t *slot = &ring[*write_idx];
    const uint32_t t0_us = (uint32_t)Timebase_NowUs();
    IMU_ReadAllRaw(slot->raw);
    const uint32_t t1_us = (uint32_t)Timebase_NowUs();

    /* Block read of all three sites; timestamp = midpoint of read. */
    slot->t_us = t0_us + ((uint32_t)(t1_us - t0_us) / 2U);
    slot->valid = true;

    *write_idx = (*write_idx + 1U) % PHASE1_IMU_MATCH_RING_LEN;
    *has_sample = true;
}

static const phase1_imu_match_sample_t *phase1_find_nearest_imu_sample(
    const phase1_imu_match_sample_t ring[PHASE1_IMU_MATCH_RING_LEN],
    bool has_sample,
    uint32_t t_ecg_us,
    uint32_t *best_delta_us)
{
    if (best_delta_us != NULL)
    {
        *best_delta_us = UINT32_MAX;
    }
    if ((ring == NULL) || !has_sample)
    {
        return NULL;
    }

    const phase1_imu_match_sample_t *best = NULL;
    uint32_t best_delta = UINT32_MAX;

    for (uint32_t ii = 0U; ii < PHASE1_IMU_MATCH_RING_LEN; ii++)
    {
        if (!ring[ii].valid)
        {
            continue;
        }

        uint32_t delta = phase1_abs_time_delta_us(ring[ii].t_us, t_ecg_us);
        if ((best == NULL) || (delta < best_delta))
        {
            best = &ring[ii];
            best_delta = delta;
        }
    }

    if (best_delta_us != NULL)
    {
        *best_delta_us = best_delta;
    }
    return best;
}
#endif

/* Round half away from zero; matches MATLAB round(). */
static inline int16_t f_to_i16(float v)
{
    return (v >= 0.0f) ? (int16_t)(v + 0.5f) : (int16_t)(v - 0.5f);
}

/* Wait until DWT->CYCCNT reaches target. Signed cast tolerates the 32-bit
 * rollover at ~7.16 s @ 600 MHz (ARM DDI 0403E C1.8). */
static inline void wait_until_cycle(uint32_t target)
{
    while ((int32_t)(DWT->CYCCNT - target) < 0) { __NOP(); }
}

static inline void catch_up_next_tick(uint32_t *next_tick, uint32_t step)
{
    if ((int32_t)(DWT->CYCCNT - *next_tick) > 0)
    {
        do { *next_tick += step; }
        while ((int32_t)(DWT->CYCCNT - *next_tick) > 0);
    }
}

#if PHASE1_USES_ADS1293
static ads1293_t g_ads1293;
#endif

#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU)
static phase4_state_t g_phase4;
#if PHASE4_ENABLE_M4_SELECTOR && PHASE4_BOOT_CM4_CLASSIFIER
static bool g_phase4_cm4_booted;
#endif
#endif

/* CM4 classifier boot support. */
#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU) && \
    PHASE4_ENABLE_M4_SELECTOR && PHASE4_BOOT_CM4_CLASSIFIER
static bool phase4_cm4_vector_is_valid(void)
{
    volatile const uint32_t *vt = (volatile const uint32_t *)PHASE4_CM4_BOOT_ADDRESS;
    uint32_t sp = vt[0];
    uint32_t pc_raw = vt[1];
    uint32_t pc = pc_raw & ~1UL;

    bool sp_dtc = (sp >= PHASE4_CM4_DTCM_START) && (sp <= PHASE4_CM4_DTCM_END);
    bool sp_itc = (sp >= PHASE4_CM4_ITCM_START) && (sp <= PHASE4_CM4_ITCM_END);
    bool sp_ocram = (sp >= PHASE4_CM4_OCRAM_START) && (sp <= PHASE4_CM4_OCRAM_END);
    bool pc_flash = (pc >= PHASE4_CM4_BOOT_ADDRESS) && (pc < PHASE4_CM4_FLASH_END_ADDRESS);
    bool thumb = ((pc_raw & 1UL) != 0U);

    return (sp_dtc || sp_itc || sp_ocram) && pc_flash && thumb;
}

static bool phase4_boot_cm4_classifier(void)
{
    if (!phase4_cm4_vector_is_valid())
    {
        return false;
    }

    IOMUXC_LPSR_GPR->GPR0 =
        IOMUXC_LPSR_GPR_GPR0_CM4_INIT_VTOR_LOW(PHASE4_CM4_BOOT_ADDRESS >> 3);
    IOMUXC_LPSR_GPR->GPR1 =
        IOMUXC_LPSR_GPR_GPR1_CM4_INIT_VTOR_HIGH(PHASE4_CM4_BOOT_ADDRESS >> 16);
    (void)IOMUXC_LPSR_GPR->GPR0;
    (void)IOMUXC_LPSR_GPR->GPR1;

    if ((SRC->SCR & SRC_SCR_BT_RELEASE_M4_MASK) == 0U)
    {
        SRC_ReleaseCoreReset(SRC, kSRC_CM4Core);
    }
    else
    {
        SRC_AssertSliceSoftwareReset(SRC, kSRC_M4CoreSlice);
    }

    SRC->GPR[PHASE4_CM4_GO_GPR_INDEX] = PHASE4_CM4_GO_FLAG;
    return true;
}
#endif

int main(void)
{
    /* Board and debug UART setup. BOARD_DEBUG_UART_BAUDRATE must be 500000. */
    BOARD_InitBootPins();
    BOARD_InitBootClocks();
    uint32_t m7_clock_hz = CLOCK_GetRootClockFreq(kCLOCK_Root_M7);
    if (m7_clock_hz >= 1000000U)
    {
        SystemCoreClock = m7_clock_hz;
    }
    BOARD_InitDebugConsole();
    PRINTF("\r\n[BOOT] CM7 UART alive at 500000 baud\r\n");
    PRINTF("[BOOT] Phase4 ADS1293/IMU acquisition firmware starting\r\n");

    Timebase_Init();
    PRINTF("[BOOT] Clocks SystemCore=%u Timebase=%u M7=%u M4=%u LPUART1=%u LPSPI1=%u\r\n",
           (unsigned)SystemCoreClock,
           (unsigned)Timebase_ClockHz(),
           (unsigned)CLOCK_GetRootClockFreq(kCLOCK_Root_M7),
           (unsigned)CLOCK_GetRootClockFreq(kCLOCK_Root_M4),
           (unsigned)CLOCK_GetRootClockFreq(kCLOCK_Root_Lpuart1),
           (unsigned)CLOCK_GetRootClockFreq(kCLOCK_Root_Lpspi1));

#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU)
    Phase4_Init(&g_phase4);
#endif

#if PHASE1_USES_AD8233
    ECGADC_Init();
#endif

    /* IMU init (imu_manager.c): reset, WHO_AM_I probe with retries, DLPF=2,
     * +/-2 g, +/-250 dps, ODR=500 Hz, magnitude check. WHO_AM_I = 0xFF
     * usually means floating MISO; check pin_mux.c PCS assignments. */

#if PHASE1_USES_IMU
    /* All three sites required before recording starts. */
    PRINTF("[PHASE1] Waiting for all 3 IMUs (required for MAS data)...\r\n");

    uint32_t attempt = 0U;
    while (1)
    {
        attempt++;
        PRINTF("[PHASE1] Init attempt %u...\r\n", (unsigned)attempt);

        bool any = IMU_InitAll();
        if (any)
        {
            /* IMU_InitAll returns true if any IMU responds; verify all three
             * via the valid flag from IMU_ReadAll. */
            imu_data_t probe[IMU_COUNT];
            IMU_ReadAll(probe);

            bool ok0 = probe[0].valid;
            bool ok1 = probe[1].valid;
            bool ok2 = probe[2].valid;

            PRINTF("[PHASE1] IMU0(LL)=%s  IMU1(LA)=%s  IMU2(RA)=%s\r\n",
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
        PRINTF("[PHASE1]   IMU0 CS -> J10[6] (LPSPI1_PCS0) -> LL (L.LowerThorax)\r\n");
        PRINTF("[PHASE1]   IMU1 CS -> J9[5]  (LPSPI1_PCS1) -> LA (L.Subclavicular)\r\n");
        PRINTF("[PHASE1]   IMU2 CS -> J9[1]  (LPSPI1_PCS2) -> RA (R.Subclavicular)\r\n");
        PRINTF("[PHASE1] Retrying in 2 seconds...\r\n\r\n");
        SDK_DelayAtLeastUs(2000000U, SystemCoreClock);
    }

#else   /* PHASE1_ECG_ONLY: IMU not streamed, but probed at boot. */
    PRINTF("[PHASE1] ECG_ONLY mode - verifying IMU hardware at boot...\r\n");
    (void)IMU_InitAll();
    PRINTF("[PHASE1] IMU check done (IMU data not recorded in this mode).\r\n\r\n");
#endif

    /* ADS1293 setup and boot-time hardware summary. */
#if PHASE1_USES_ADS1293
    status_t ads_st = ADS1293_Attach(&g_ads1293, LPSPI1,
                                     APP_ADS1293_SPI_SRC_CLOCK_HZ,
                                     APP_ADS1293_SPI_BAUD_HZ,
                                     kLPSPI_Pcs3, kLPSPI_MasterPcs3);
    if (ads_st != kStatus_Success)
    {
        PRINTF("[ADS1293] Attach failed (%d)\r\n", (int)ads_st);
        while (1) { __NOP(); }
    }

#if !PHASE1_USES_IMU
    ads_st = ADS1293_InitBus(&g_ads1293);
    if (ads_st != kStatus_Success)
    {
        PRINTF("[ADS1293] LPSPI1 init failed (%d)\r\n", (int)ads_st);
        while (1) { __NOP(); }
    }
#endif

    PRINTF("[ADS1293] CS -> J9[7] (LPSPI1_PCS3), SPI mode 0, 1 MHz\r\n");
    PRINTF("[ADS1293] DRDY is polled through DATA_STATUS for this build.\r\n");

    ads_st = ADS1293_Configure(&g_ads1293, PHASE1_ADS1293_FRONTEND);
    if (ads_st != kStatus_Success)
    {
        PRINTF("[ADS1293] Configuration failed (%d). Check CS/MISO/MOSI/SCLK.\r\n",
               (int)ads_st);
        while (1) { __NOP(); }
    }

    uint8_t ads_revid = 0U;
    if (ADS1293_ReadRevision(&g_ads1293, &ads_revid) == kStatus_Success)
    {
        PRINTF("[ADS1293] REVID = 0x%02X\r\n", ads_revid);
    }
    PRINTF("[ADS1293] Configured for %s, output stream uses Lead I and Lead II only.\r\n\r\n",
           (PHASE1_ADS1293_FRONTEND == ADS1293_FRONTEND_5_LEAD) ?
           "5-lead ECG" : "3-lead ECG");
#endif

#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU) && \
    PHASE4_ENABLE_M4_SELECTOR && PHASE4_BOOT_CM4_CLASSIFIER
    PRINTF("[PHASE1] Booting CM4 classifier from %s...\r\n", PHASE4_CM4_BOOT_ADDRESS_STR);
    g_phase4_cm4_booted = phase4_boot_cm4_classifier();
    PRINTF("[PHASE1] CM4 classifier boot %s\r\n",
           g_phase4_cm4_booted ? "OK" : "not started");
#endif

    PRINTF("[PHASE1] =============================================\r\n");

#if (PHASE1_MODE == PHASE1_ECG_ONLY)
    PRINTF("[PHASE1]  Mode      : ECG_ONLY (Phase 2 filter analysis)\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ecg_corr, out_raw, refout_raw = 4\r\n");
    PRINTF("[PHASE1]  Rate      : target 500 Hz; verify with t_us after debug logging\r\n");
    PRINTF("[PHASE1]  Baud load : includes OUT and REFOUT raw ADC columns\r\n");
    PRINTF("[PHASE1]  Nyquist   : 250 Hz >> 40 Hz passband  (6.25x margin)\r\n");
    PRINTF("[PHASE1]  Use for   : B1-B6 bandpass + N1-N9 notch evaluation\r\n");
#elif (PHASE1_MODE == PHASE1_ECG_IMU)
    PRINTF("[PHASE1]  Mode      : ECG_IMU (Phase 3 MAS analysis)\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ecg_corr, 3xIMU, out_raw, refout_raw = 22\r\n");
    PRINTF("[PHASE1]  Rate      : effective Fs must be measured from t_us timestamps\r\n");
    PRINTF("[PHASE1]             UART payload includes OUT and REFOUT raw ADC columns.\r\n");
    PRINTF("[PHASE1]  Baud load : depends on value width; check ecg_monitor Fs est.\r\n");
    PRINTF("[PHASE1]  Nyquist   : compute from measured Fs before filter/MAS analysis\r\n");
    PRINTF("[PHASE1]  IMU data  : RAW int16 register values (Kalman bypassed)\r\n");
    PRINTF("[PHASE1]             Accel: /16384 -> g-units\r\n");
    PRINTF("[PHASE1]             Gyro : /131   -> deg/s\r\n");
    PRINTF("[PHASE1]  IMU sites : IMU0=LL(L.LowerThorax) IMU1=LA(L.Subclav) IMU2=RA(R.Subclav)\r\n");
    PRINTF("[PHASE1]  Use for   : MAS evaluation (M1-M8)\r\n");
    PRINTF("[PHASE1]             Accel ref: M1-M5,M8  Gyro: M6  6-axis: M7\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_ONLY)
    PRINTF("[PHASE1]  Mode      : ADS1293_ONLY\r\n");
    PRINTF("[PHASE1]  Fields    : t_us, ads_ch1, ads_ch2 = 3\r\n");
    PRINTF("[PHASE1]  ECG data  : ADS1293 signed 24-bit Lead I and Lead II codes\r\n");
    PRINTF("[PHASE1]  Rate      : ADS1293 target 200 sps; verify from t_us timestamps\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_IMU)
    PRINTF("[PHASE1]  Mode      : ADS1293_IMU\r\n");
#if PHASE4_ENABLE_REALTIME_PIPELINE
#if PHASE4_PROCESS_ALL_CANDIDATES
    PRINTF("[PHASE1]  Pipeline  : Phase4 baseline removal + B8+N3+all NLMS MAS candidates\r\n");
#elif PHASE4_ENABLE_RA_PAIR_LMS
    PRINTF("[PHASE1]  Pipeline  : Phase4 fixed B8+N3 vs lead-matched RA-pair NLMS epoch selector\r\n");
#else
    PRINTF("[PHASE1]  Pipeline  : Phase4 realtime-safe fixed B8+N3 output\r\n");
#endif
#if PHASE4_ENABLE_M4_SELECTOR
    PRINTF("[PHASE1]  ML offload: CM4 scores two-stage MAS models; no blocking wait\r\n");
    PRINTF("[PHASE1]  ML models : pooled usability gate + baseline-vs-suppressed selector (lead_id feature)\r\n");
    PRINTF("[PHASE1]             Active firmware candidates: combo 1 fixed, combo 5 RA-pair NLMS\r\n");
#if PHASE4_BOOT_CM4_CLASSIFIER
    if (g_phase4_cm4_booted)
    {
        PRINTF("[PHASE1]             CM4 worker started at %s\r\n", PHASE4_CM4_BOOT_ADDRESS_STR);
    }
    else
    {
        PRINTF("[PHASE1]             CM4 worker image not detected at %s\r\n", PHASE4_CM4_BOOT_ADDRESS_STR);
    }
#endif
    PRINTF("[PHASE1]             Display output follows CM4 selected candidate when results are available\r\n");
#else
    PRINTF("[PHASE1]  ML offload: disabled; CM7 selects fixed, lead-matched RA-pair NLMS, or corrupt heuristically\r\n");
#endif
#if PHASE4_ENABLE_M4_SELECTOR
    PRINTF("[PHASE1]  Fields    : compact UART raw ADS1293 + lead-matched RA-pair NLMS + selected output\r\n");
#if PHASE4_UART_DIAGNOSTICS
    PRINTF("[PHASE1]             Diagnostic M4/cycle telemetry is enabled; UART rate may fall below ADS1293 rate\r\n");
#endif
#elif PHASE4_PROCESS_ALL_CANDIDATES
    PRINTF("[PHASE1]  Fields    : compact UART raw ADS1293 + lead-matched RA-pair NLMS + selected output\r\n");
#elif PHASE4_ENABLE_RA_PAIR_LMS
    PRINTF("[PHASE1]  Fields    : compact UART raw ADS1293 + lead-matched RA-pair NLMS + selected output\r\n");
#else
    PRINTF("[PHASE1]  Fields    : compact UART raw ADS1293 + fixed BPF+N3 output; reference columns mirror fixed output\r\n");
#endif
#else
    PRINTF("[PHASE1]  Fields    : compact UART raw ADS1293 only; IMU remains internal\r\n");
#endif
    PRINTF("[PHASE1]  ECG data  : ADS1293 signed 24-bit Lead I and Lead II codes\r\n");
    PRINTF("[PHASE1]  Rate      : ADS1293 target 200 sps; verify from t_us timestamps\r\n");
    PRINTF("[PHASE1]  IMU data  : sampled internally for MAS/classifier; not streamed over UART\r\n");
    PRINTF("[PHASE1]  IMU match : nearest timestamped IMU block feeds MAS/classifier\r\n");
    PRINTF("[PHASE1]  IMU sites : IMU0=LL  IMU1=LA  IMU2=RA\r\n");
#endif

    PRINTF("[PHASE1] =============================================\r\n");
    PRINTF("[PHASE1]  Baud rate : 500000  (confirm ecg_monitor.py matches)\r\n");
    PRINTF("[PHASE1]  MATLAB    : data = readmatrix('file.txt')\r\n");
    PRINTF("[PHASE1]             t_s  = data(:,1)/1e6\r\n");
#if PHASE1_USES_ADS1293
    PRINTF("[PHASE1]             leadI  = data(:,2)\r\n");
    PRINTF("[PHASE1]             leadII = data(:,3)\r\n");
#else
    PRINTF("[PHASE1]             ecg  = data(:,2)*(1800/4096)\r\n");
    PRINTF("[PHASE1]             raw  = data(:,end-1:end) = [OUT REFOUT]\r\n");
#endif
    PRINTF("[PHASE1] =============================================\r\n\r\n");

    /* CSV header emitted before numeric rows. readmatrix skips the boot log. */
#if (PHASE1_MODE == PHASE1_ECG_ONLY)
    PRINTF("t_us,ecg_corr,out_raw,refout_raw\r\n");
#elif (PHASE1_MODE == PHASE1_ECG_IMU)
    PRINTF("t_us,ecg_corr,"
           "ax0,ay0,az0,gx0,gy0,gz0,"
           "ax1,ay1,az1,gx1,gy1,gz1,"
           "ax2,ay2,az2,gx2,gy2,gz2,"
           "out_raw,refout_raw\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_ONLY)
    PRINTF("t_us,ads_ch1,ads_ch2\r\n");
#elif (PHASE1_MODE == PHASE1_ADS1293_IMU)
    PRINTF("t_us,ads_ch1,ads_ch2"
#if PHASE4_ENABLE_REALTIME_PIPELINE
           ",p4_ra_pair_ch1,p4_ra_pair_ch2,"
           "p4_ch1,p4_ch2,p4_primary,"
           "sel_ch1,sel_ch2,primary_lead,p4_flags,"
           "motion_x10,sqi1,sqi2,"
           "hr1_x10,hr2_x10,rmssd1_x10,rmssd2_x10,"
           "epoch_seq,label_epoch_seq,p4_cycles"
#if PHASE4_ENABLE_M4_SELECTOR
           ",m4_cycles"
#endif
#if PHASE4_UART_DIAGNOSTICS
           ",loop_cycles_max"
#if PHASE4_ENABLE_M4_SELECTOR
           ",m4_hb,m4_jobs,m4_results,m4_consumed,m4_drops,m4_seq,"
           "m4_sel_ch1,m4_sel_ch2,m4_prob1_x1000,m4_prob2_x1000"
#endif
#endif
#endif
           "\r\n");
#endif

    /* Acquisition loop.
     * Scheduler: DWT->CYCCNT busy-wait at APP_ECG_FS_HZ. ADS1293 rows emit
     * only on DATA_STATUS ready. Catch-up advances next_tick if the loop
     * overruns; resulting gaps are visible as diff(t_us) outliers. */
    const uint32_t step = (uint32_t)(
        ((uint64_t)SystemCoreClock + (APP_ECG_FS_HZ / 2U)) / APP_ECG_FS_HZ);

    uint32_t next_tick = DWT->CYCCNT + step;
    uint32_t seq       = 0U;

#if PHASE1_USES_ADS1293 && PHASE1_ADS1293_READY_DEBUG
    uint32_t ads_debug_last_us = 0U;
    uint32_t ads_status_fail_count = 0U;
    uint32_t ads_not_ready_count = 0U;
    uint32_t ads_read_fail_count = 0U;
#endif

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
    phase1_imu_match_sample_t imu_ring[PHASE1_IMU_MATCH_RING_LEN];
    memset(imu_ring, 0, sizeof(imu_ring));
    uint32_t imu_ring_write = 0U;
    bool imu_ring_has_sample = false;
#elif PHASE1_USES_IMU
    imu_raw_t imu_raw[IMU_COUNT];
    memset(imu_raw, 0, sizeof(imu_raw));
#endif

    while (1)
    {
        wait_until_cycle(next_tick);
        next_tick += step;
        const uint32_t loop_start = DWT->CYCCNT;

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
        phase1_push_imu_match_sample(imu_ring, &imu_ring_write, &imu_ring_has_sample);
#endif

#if PHASE1_USES_ADS1293
        uint8_t ads_status = 0U;
        status_t ads_status_st = ADS1293_ReadDataStatus(&g_ads1293, &ads_status);
        bool ads_ready = (ads_status_st == kStatus_Success) &&
                         ((ads_status & PHASE1_ADS1293_READY_MASK) ==
                          PHASE1_ADS1293_READY_MASK);
        if (!ads_ready)
        {
#if PHASE1_ADS1293_READY_DEBUG
            const uint32_t now_us = (uint32_t)Timebase_NowUs();
            if (ads_status_st != kStatus_Success)
            {
                ads_status_fail_count++;
            }
            else
            {
                ads_not_ready_count++;
            }
            if ((ads_debug_last_us == 0U) ||
                ((uint32_t)(now_us - ads_debug_last_us) >= PHASE1_ADS1293_READY_DEBUG_PERIOD_US))
            {
                ads_debug_last_us = now_us;
                PRINTF("[ADS1293_DEBUG] t_us=%u DATA_STATUS=0x%02X "
                       "st=%d ready=%u mask=0x%02X "
                       "b0=%u b1=%u b2=%u b3=%u b4=%u b5=%u b6=%u b7=%u "
                       "status_fail=%u not_ready=%u read_fail=%u\r\n",
                       (unsigned)now_us,
                       (unsigned)ads_status,
                       (int)ads_status_st,
                       ads_ready ? 1U : 0U,
                       (unsigned)PHASE1_ADS1293_READY_MASK,
                       (unsigned)((ads_status >> 0U) & 0x01U),
                       (unsigned)((ads_status >> 1U) & 0x01U),
                       (unsigned)((ads_status >> 2U) & 0x01U),
                       (unsigned)((ads_status >> 3U) & 0x01U),
                       (unsigned)((ads_status >> 4U) & 0x01U),
                       (unsigned)((ads_status >> 5U) & 0x01U),
                       (unsigned)((ads_status >> 6U) & 0x01U),
                       (unsigned)((ads_status >> 7U) & 0x01U),
                       (unsigned)ads_status_fail_count,
                       (unsigned)ads_not_ready_count,
                       (unsigned)ads_read_fail_count);
            }
#endif
#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU)
            Phase4_RecordLoopCycles(&g_phase4, DWT->CYCCNT - loop_start);
#endif
            catch_up_next_tick(&next_tick, step);
            continue;
        }

        const uint32_t t_us = (uint32_t)Timebase_NowUs();

        ads1293_samples_t ads_sample;
        if (ADS1293_ReadECGData(&g_ads1293, &ads_sample) != kStatus_Success)
        {
#if PHASE1_ADS1293_READY_DEBUG
            ads_read_fail_count++;
#endif
#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU)
            Phase4_RecordLoopCycles(&g_phase4, DWT->CYCCNT - loop_start);
#endif
            catch_up_next_tick(&next_tick, step);
            continue;
        }

#if (PHASE1_MODE == PHASE1_ADS1293_IMU)
        uint32_t imu_match_delta_us = UINT32_MAX;
        const phase1_imu_match_sample_t *imu_match =
            phase1_find_nearest_imu_sample(imu_ring,
                                           imu_ring_has_sample,
                                           t_us,
                                           &imu_match_delta_us);
        const bool imu_match_ok = (imu_match != NULL) &&
                                  (imu_match_delta_us <= PHASE1_IMU_MATCH_MAX_DELTA_US);
        imu_raw_t imu_zero[IMU_COUNT];
        memset(imu_zero, 0, sizeof(imu_zero));
        const imu_raw_t *imu_out = imu_match_ok ? imu_match->raw : imu_zero;
#if PHASE4_ENABLE_REALTIME_PIPELINE
        phase4_output_t p4_out;
        const uint32_t p4_start = DWT->CYCCNT;
        Phase4_ProcessAds1293Imu(&g_phase4,
                                  ads_sample.ch1,
                                  ads_sample.ch2,
                                  t_us,
                                  imu_out,
                                  &p4_out);
        if (!imu_match_ok)
        {
            p4_out.flags |= PHASE4_FLAG_IMU_TIMING_BAD;
        }
        const uint32_t p4_cycles = DWT->CYCCNT - p4_start;
#endif
#endif

        if ((seq % PHASE1_DECIM) == 0U)
        {
#if (PHASE1_MODE == PHASE1_ADS1293_ONLY)
            PRINTF("%u,%d,%d\r\n",
                   (unsigned)t_us,
                   (int)ads_sample.ch1,
                   (int)ads_sample.ch2);
#else
#if PHASE4_UART_DIAGNOSTICS
            PRINTF("%u,%d,%d"
#if PHASE4_ENABLE_REALTIME_PIPELINE
                   ",%d,%d,%d,%d,%d,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u"
#if PHASE4_ENABLE_M4_SELECTOR
                   ",%u"
#endif
                   ",%u"
#if PHASE4_ENABLE_M4_SELECTOR
                   ",%u,%u,%u,%u,%u,%u,%u,%u,%u,%u"
#endif
#endif
                   "\r\n",
                   (unsigned)t_us,
                   (int)ads_sample.ch1,
                   (int)ads_sample.ch2
#if PHASE4_ENABLE_REALTIME_PIPELINE
                   ,
                   (int)p4_out.ra_pair_ch1,
                   (int)p4_out.ra_pair_ch2,
                   (int)p4_out.stitched_ch1,
                   (int)p4_out.stitched_ch2,
                   (int)p4_out.primary_ecg,
                   (unsigned)p4_out.sel_ch1,
                   (unsigned)p4_out.sel_ch2,
                   (unsigned)p4_out.primary_lead,
                   (unsigned)p4_out.flags,
                   (unsigned)p4_out.motion_x10,
                   (unsigned)p4_out.sqi1,
                   (unsigned)p4_out.sqi2,
                   (unsigned)p4_out.hr1_x10,
                   (unsigned)p4_out.hr2_x10,
                   (unsigned)p4_out.rmssd1_x10,
                   (unsigned)p4_out.rmssd2_x10,
                   (unsigned)p4_out.epoch_seq,
                   (unsigned)p4_out.label_epoch_seq,
                   (unsigned)p4_cycles,
#if PHASE4_ENABLE_M4_SELECTOR
                   (unsigned)p4_out.m4_cycles,
#endif
                   (unsigned)g_phase4.loop_cycles_max
#if PHASE4_ENABLE_M4_SELECTOR
                   ,
                   (unsigned)p4_out.m4_heartbeat,
                   (unsigned)p4_out.m4_jobs_posted,
                   (unsigned)p4_out.m4_results_posted,
                   (unsigned)p4_out.m4_results_consumed,
                   (unsigned)p4_out.m4_jobs_dropped,
                   (unsigned)p4_out.m4_last_result_seq,
                   (unsigned)p4_out.m4_sel_ch1,
                   (unsigned)p4_out.m4_sel_ch2,
                   (unsigned)p4_out.m4_prob1_x1000,
                   (unsigned)p4_out.m4_prob2_x1000
#endif
#endif
                   );
#else
            PRINTF("%u,%d,%d"
#if PHASE4_ENABLE_REALTIME_PIPELINE
                   ",%d,%d,%d,%d,%d,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u"
#if PHASE4_ENABLE_M4_SELECTOR
                   ",%u"
#endif
#endif
                   "\r\n",
                   (unsigned)t_us,
                   (int)ads_sample.ch1,
                   (int)ads_sample.ch2
#if PHASE4_ENABLE_REALTIME_PIPELINE
                   ,
                   (int)p4_out.ra_pair_ch1,
                   (int)p4_out.ra_pair_ch2,
                   (int)p4_out.stitched_ch1,
                   (int)p4_out.stitched_ch2,
                   (int)p4_out.primary_ecg,
                   (unsigned)p4_out.sel_ch1,
                   (unsigned)p4_out.sel_ch2,
                   (unsigned)p4_out.primary_lead,
                   (unsigned)p4_out.flags,
                   (unsigned)p4_out.motion_x10,
                   (unsigned)p4_out.sqi1,
                   (unsigned)p4_out.sqi2,
                   (unsigned)p4_out.hr1_x10,
                   (unsigned)p4_out.hr2_x10,
                   (unsigned)p4_out.rmssd1_x10,
                   (unsigned)p4_out.rmssd2_x10,
                   (unsigned)p4_out.epoch_seq,
                   (unsigned)p4_out.label_epoch_seq,
                   (unsigned)p4_cycles
#if PHASE4_ENABLE_M4_SELECTOR
                   ,
                   (unsigned)p4_out.m4_cycles
#endif
#endif
                   );
#endif
#endif
        }

#else
        /* Sample timestamp taken before ADC/UART work. Wraps at 2^32 us
         * (~71 min); no wrap in a Phase 1 session. */
        const uint32_t t_us = (uint32_t)Timebase_NowUs();

        /* Chained LPADC: trigger -> OUT -> REFOUT -> FIFO. 500 us timeout
         * (ecg_adc.c). On timeout out12/refout12 = 0 and the row is still
         * emitted to keep indices aligned. */
        ecg_adc_debug_sample_t ecg_dbg;
        (void)ECGADC_ReadDebug(&ecg_dbg);
        const int16_t ecg_corr =
            (int16_t)((int32_t)ecg_dbg.out12 - (int32_t)ecg_dbg.refout12);

#if (PHASE1_MODE == PHASE1_ECG_IMU)
        /* Raw int16 read from MPU-6500 (ACCEL_XOUT_H..GYRO_ZOUT_L, RM 3.1).
         * Missing sites stay zero from the memset above. */
        IMU_ReadAllRaw(imu_raw);
#endif

        /* Signed IMU values use %d; %u on a negative int16 prints 0xFFFF... */
        if ((seq % PHASE1_DECIM) == 0U)
        {
#if (PHASE1_MODE == PHASE1_ECG_ONLY)
            PRINTF("%u,%d,%u,%u\r\n",
                   (unsigned)t_us,
                   (int)ecg_corr,
                   (unsigned)ecg_dbg.out12,
                   (unsigned)ecg_dbg.refout12);

#else   /* PHASE1_ECG_IMU - 20 ECG/IMU fields + 2 AD8233 debug fields */
            PRINTF("%u,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%d,%d,%d,%d,%d,%d,"
                   "%u,%u\r\n",
                   (unsigned)t_us,
                   (int)ecg_corr,
                   /* IMU0 - LL, left lower thorax */
                   (int)imu_raw[0].ax, (int)imu_raw[0].ay, (int)imu_raw[0].az,
                   (int)imu_raw[0].gx, (int)imu_raw[0].gy, (int)imu_raw[0].gz,
                   /* IMU1 - LA, left subclavicular */
                   (int)imu_raw[1].ax, (int)imu_raw[1].ay, (int)imu_raw[1].az,
                   (int)imu_raw[1].gx, (int)imu_raw[1].gy, (int)imu_raw[1].gz,
                   /* IMU2 - RA, right subclavicular */
                   (int)imu_raw[2].ax, (int)imu_raw[2].ay, (int)imu_raw[2].az,
                   (int)imu_raw[2].gx, (int)imu_raw[2].gy, (int)imu_raw[2].gz,
                   (unsigned)ecg_dbg.out12,
                   (unsigned)ecg_dbg.refout12);
#endif
        }

#endif /* PHASE1_USES_ADS1293 */

        seq++;

        /* Re-anchor next_tick if the loop body overran one step. */
#if (PHASE4_ENABLE_REALTIME_PIPELINE) && (PHASE1_MODE == PHASE1_ADS1293_IMU)
        Phase4_RecordLoopCycles(&g_phase4, DWT->CYCCNT - loop_start);
#endif
        catch_up_next_tick(&next_tick, step);
    }
}
