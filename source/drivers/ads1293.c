/*
 * ads1293.c
 *
 * Native MCUXpresso driver for the ADS1293 ECG front-end.
 *
 * SPI protocol and configuration values mirror the Protocentral ADS1293
 * Arduino library:
 *   - SPI mode 0, MSB first, 1 MHz
 *   - 24-bit ECG samples read from DATA_CH1_ECG..DATA_CH3_ECG
 *   - SPS_128 uses R2=5 and R3=16 decimation codes
 */

#include "drivers/ads1293.h"

#include <string.h>

#include "fsl_clock.h"

#define XFER_RETRY_COUNT    (50U)
#define XFER_RETRY_DELAY_US (20U)

/* ADS1293 register map subset. */
#define ADS1293_REG_CONFIG       (0x00U)
#define ADS1293_REG_FLEX_CH1_CN  (0x01U)
#define ADS1293_REG_FLEX_CH2_CN  (0x02U)
#define ADS1293_REG_FLEX_CH3_CN  (0x03U)
#define ADS1293_REG_CMDET_EN     (0x0AU)
#define ADS1293_REG_RLD_CN       (0x0CU)
#define ADS1293_REG_WILSON_EN1   (0x0DU)
#define ADS1293_REG_WILSON_EN2   (0x0EU)
#define ADS1293_REG_WILSON_EN3   (0x0FU)
#define ADS1293_REG_WILSON_CN    (0x10U)
#define ADS1293_REG_OSC_CN       (0x12U)
#define ADS1293_REG_AFE_SHDN_CN  (0x14U)
#define ADS1293_REG_R2_RATE      (0x21U)
#define ADS1293_REG_R3_RATE_CH1  (0x22U)
#define ADS1293_REG_R3_RATE_CH2  (0x23U)
#define ADS1293_REG_R3_RATE_CH3  (0x24U)
#define ADS1293_REG_DRDYB_SRC    (0x27U)
#define ADS1293_REG_CH_CNFG      (0x2FU)
#define ADS1293_REG_DATA_STATUS  (0x30U)
#define ADS1293_REG_DATA_CH1_ECG (0x37U)
#define ADS1293_REG_REVID        (0x40U)

/* Protocentral/default ECG configuration values. */
#define ADS1293_FLEX_CH1_LEAD_I      (0x11U) /* LA - RA */
#define ADS1293_FLEX_CH2_LEAD_II     (0x19U) /* LL - RA */
#define ADS1293_FLEX_CH3_V1_WCT      (0x2EU)
#define ADS1293_CMDET_RA_LA_LL       (0x07U)
#define ADS1293_RLD_DEFAULT          (0x04U)
#define ADS1293_OSC_DEFAULT          (0x04U)
#define ADS1293_AFE_ALL_ENABLED      (0x00U)
#define ADS1293_R2_RATE_5            (0x02U)
#define ADS1293_R3_RATE_16           (0x10U)
#define ADS1293_DRDY_DEFAULT         (0x08U)
#define ADS1293_CH_CFG_3_LEAD        (0x30U)
#define ADS1293_CH_CFG_5_LEAD        (0x70U)
#define ADS1293_CONFIG_START         (0x01U)

static void ads1293_apply_mode0(ads1293_t *dev)
{
    uint32_t tcr = LPSPI_GetTcr(dev->base);
    tcr &= ~(LPSPI_TCR_CPOL_MASK | LPSPI_TCR_CPHA_MASK | LPSPI_TCR_LSBF_MASK);
    tcr |= LPSPI_TCR_CPOL(kLPSPI_ClockPolarityActiveHigh) |
           LPSPI_TCR_CPHA(kLPSPI_ClockPhaseFirstEdge) |
           LPSPI_TCR_LSBF(kLPSPI_MsbFirst);
    dev->base->TCR = tcr;
}

static status_t ads1293_xfer_once(ads1293_t *dev,
                                  const uint8_t *tx,
                                  uint8_t *rx,
                                  size_t n)
{
    ads1293_apply_mode0(dev);

    lpspi_transfer_t t;
    memset(&t, 0, sizeof(t));
    t.txData      = (uint8_t *)tx;
    t.rxData      = rx;
    t.dataSize    = n;
    t.configFlags = dev->pcsFlags | kLPSPI_MasterPcsContinuous;
    return LPSPI_MasterTransferBlocking(dev->base, &t);
}

static status_t ads1293_xfer(ads1293_t *dev,
                             const uint8_t *tx,
                             uint8_t *rx,
                             size_t n)
{
    if ((dev == NULL) || (dev->base == NULL) || (tx == NULL) || (n == 0U))
    {
        return kStatus_InvalidArgument;
    }

    status_t st = kStatus_Fail;
    for (uint32_t i = 0U; i < XFER_RETRY_COUNT; i++)
    {
        st = ads1293_xfer_once(dev, tx, rx, n);
        if (st == kStatus_LPSPI_Busy)
        {
            SDK_DelayAtLeastUs(XFER_RETRY_DELAY_US, SystemCoreClock);
            continue;
        }
        return st;
    }
    return st;
}

static status_t ads1293_write_checked(ads1293_t *dev, uint8_t reg, uint8_t val)
{
    status_t st = ADS1293_WriteReg(dev, reg, val);
    if (st != kStatus_Success)
    {
        return st;
    }
    SDK_DelayAtLeastUs(1000U, SystemCoreClock);
    return kStatus_Success;
}

status_t ADS1293_Attach(ads1293_t        *dev,
                         LPSPI_Type       *base,
                         uint32_t          srcClockHz,
                         uint32_t          baudHz,
                         lpspi_which_pcs_t whichPcs,
                         uint32_t          pcsFlags)
{
    if ((dev == NULL) || (base == NULL) || (srcClockHz == 0U) || (baudHz == 0U))
    {
        return kStatus_InvalidArgument;
    }

    dev->base       = base;
    dev->srcClockHz = srcClockHz;
    dev->baudHz     = baudHz;
    dev->whichPcs   = whichPcs;
    dev->pcsFlags   = pcsFlags;
    return kStatus_Success;
}

status_t ADS1293_InitBus(ads1293_t *dev)
{
    if ((dev == NULL) || (dev->base == NULL))
    {
        return kStatus_InvalidArgument;
    }

#if defined(kCLOCK_Lpspi1)
    if (dev->base == LPSPI1)
    {
        CLOCK_EnableClock(kCLOCK_Lpspi1);
    }
#endif

    lpspi_master_config_t cfg;
    LPSPI_MasterGetDefaultConfig(&cfg);
    cfg.baudRate           = dev->baudHz;
    cfg.bitsPerFrame       = 8U;
    cfg.direction          = kLPSPI_MsbFirst;
    cfg.whichPcs           = dev->whichPcs;
    cfg.pcsActiveHighOrLow = kLPSPI_PcsActiveLow;
    cfg.pinCfg             = kLPSPI_SdiInSdoOut;
    cfg.cpol               = kLPSPI_ClockPolarityActiveHigh;
    cfg.cpha               = kLPSPI_ClockPhaseFirstEdge;

    LPSPI_MasterInit(dev->base, &cfg, dev->srcClockHz);
    return kStatus_Success;
}

status_t ADS1293_Configure(ads1293_t *dev, ads1293_frontend_t frontend)
{
    status_t st;

    st = ads1293_write_checked(dev, ADS1293_REG_FLEX_CH1_CN,
                               ADS1293_FLEX_CH1_LEAD_I);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_FLEX_CH2_CN,
                               ADS1293_FLEX_CH2_LEAD_II);
    if (st != kStatus_Success) { return st; }

    if (frontend == ADS1293_FRONTEND_5_LEAD)
    {
        st = ads1293_write_checked(dev, ADS1293_REG_FLEX_CH3_CN,
                                   ADS1293_FLEX_CH3_V1_WCT);
        if (st != kStatus_Success) { return st; }

        st = ads1293_write_checked(dev, ADS1293_REG_WILSON_EN1, 0x01U);
        if (st != kStatus_Success) { return st; }
        st = ads1293_write_checked(dev, ADS1293_REG_WILSON_EN2, 0x02U);
        if (st != kStatus_Success) { return st; }
        st = ads1293_write_checked(dev, ADS1293_REG_WILSON_EN3, 0x03U);
        if (st != kStatus_Success) { return st; }
        st = ads1293_write_checked(dev, ADS1293_REG_WILSON_CN, 0x01U);
        if (st != kStatus_Success) { return st; }
    }

    st = ads1293_write_checked(dev, ADS1293_REG_CMDET_EN, ADS1293_CMDET_RA_LA_LL);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_RLD_CN, ADS1293_RLD_DEFAULT);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_OSC_CN, ADS1293_OSC_DEFAULT);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_AFE_SHDN_CN,
                               ADS1293_AFE_ALL_ENABLED);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_R2_RATE, ADS1293_R2_RATE_5);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_R3_RATE_CH1, ADS1293_R3_RATE_16);
    if (st != kStatus_Success) { return st; }
    st = ads1293_write_checked(dev, ADS1293_REG_R3_RATE_CH2, ADS1293_R3_RATE_16);
    if (st != kStatus_Success) { return st; }
    st = ads1293_write_checked(dev, ADS1293_REG_R3_RATE_CH3, ADS1293_R3_RATE_16);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_DRDYB_SRC, ADS1293_DRDY_DEFAULT);
    if (st != kStatus_Success) { return st; }

    st = ads1293_write_checked(dev, ADS1293_REG_CH_CNFG,
                               (frontend == ADS1293_FRONTEND_5_LEAD) ?
                               ADS1293_CH_CFG_5_LEAD : ADS1293_CH_CFG_3_LEAD);
    if (st != kStatus_Success) { return st; }

    return ads1293_write_checked(dev, ADS1293_REG_CONFIG, ADS1293_CONFIG_START);
}

status_t ADS1293_WriteReg(ads1293_t *dev, uint8_t reg, uint8_t val)
{
    uint8_t tx[2] = { (uint8_t)(reg & ADS1293_SPI_WRITE_MASK), val };
    uint8_t rx[2] = { 0U, 0U };
    status_t st = ads1293_xfer(dev, tx, rx, 2U);
    if (st == kStatus_Success)
    {
        SDK_DelayAtLeastUs(10U, SystemCoreClock);
    }
    return st;
}

status_t ADS1293_ReadReg(ads1293_t *dev, uint8_t reg, uint8_t *val)
{
    if (val == NULL)
    {
        return kStatus_InvalidArgument;
    }

    uint8_t tx[2] = { (uint8_t)(reg | ADS1293_SPI_READ_BIT), 0x00U };
    uint8_t rx[2] = { 0U, 0U };
    status_t st = ads1293_xfer(dev, tx, rx, 2U);
    if (st != kStatus_Success)
    {
        return st;
    }

    *val = rx[1];
    return kStatus_Success;
}

status_t ADS1293_ReadRevision(ads1293_t *dev, uint8_t *revid)
{
    return ADS1293_ReadReg(dev, ADS1293_REG_REVID, revid);
}

status_t ADS1293_IsDataReady(ads1293_t *dev, bool *ready)
{
    if (ready == NULL)
    {
        return kStatus_InvalidArgument;
    }

    uint8_t status = 0U;
    status_t st = ADS1293_ReadReg(dev, ADS1293_REG_DATA_STATUS, &status);
    if (st != kStatus_Success)
    {
        *ready = false;
        return st;
    }

    *ready = ((status & 0x07U) != 0U);
    return kStatus_Success;
}

status_t ADS1293_ReadECGData(ads1293_t *dev, ads1293_samples_t *samples)
{
    if (samples == NULL)
    {
        return kStatus_InvalidArgument;
    }

    uint8_t tx[10];
    uint8_t rx[10];
    memset(tx, 0x00U, sizeof(tx));
    memset(rx, 0x00U, sizeof(rx));

    tx[0] = (uint8_t)(ADS1293_REG_DATA_CH1_ECG | ADS1293_SPI_READ_BIT);

    status_t st = ads1293_xfer(dev, tx, rx, sizeof(tx));
    if (st != kStatus_Success)
    {
        return st;
    }

    const uint8_t *b = &rx[1];
    uint32_t raw1 = ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | b[2];
    uint32_t raw2 = ((uint32_t)b[3] << 16) | ((uint32_t)b[4] << 8) | b[5];
    uint32_t raw3 = ((uint32_t)b[6] << 16) | ((uint32_t)b[7] << 8) | b[8];

    samples->ch1 = ADS1293_SignExtend24(raw1);
    samples->ch2 = ADS1293_SignExtend24(raw2);
    samples->ch3 = ADS1293_SignExtend24(raw3);
    return kStatus_Success;
}

int32_t ADS1293_SignExtend24(uint32_t raw24)
{
    raw24 &= 0xFFFFFFU;
    if ((raw24 & 0x800000U) != 0U)
    {
        raw24 |= 0xFF000000U;
    }
    return (int32_t)raw24;
}
