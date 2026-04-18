/*
 * mpu6500_spi.c
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       MPU6500 SPI driver implementation
 * DATE:        28/03/2026
 *
 * SUMMARY:
 *      Blocking SPI transfers using LPSPI_MasterTransferBlocking.
 *      kLPSPI_MasterPcsContinuous holds CS low for the full multi-byte
 *      transfer (address byte + data bytes in one transaction).
 *      Retry loop handles kStatus_LPSPI_Busy when the bus is briefly busy.
 */

#include "drivers/mpu6500_spi.h"
#include <string.h>

#define XFER_RETRY_COUNT    (50U)
#define XFER_RETRY_DELAY_US (20U)

/* ── Internal transfer ───────────────────────────────────────────────────── */

static status_t spi_xfer_once(mpu6500_t *dev,
                               const uint8_t *tx, uint8_t *rx, size_t n)
{
    lpspi_transfer_t t;
    memset(&t, 0, sizeof(t));
    t.txData      = (uint8_t *)tx;
    t.rxData      = rx;
    t.dataSize    = n;
    t.configFlags = dev->pcsFlags | kLPSPI_MasterPcsContinuous;
    return LPSPI_MasterTransferBlocking(dev->base, &t);
}

static status_t spi_xfer(mpu6500_t *dev,
                          const uint8_t *tx, uint8_t *rx, size_t n)
{
    if ((dev == NULL) || (dev->base == NULL) || (tx == NULL) || (n == 0U))
    {
        return kStatus_InvalidArgument;
    }

    status_t st = kStatus_Fail;
    for (uint32_t i = 0U; i < XFER_RETRY_COUNT; i++)
    {
        st = spi_xfer_once(dev, tx, rx, n);
        if (st == kStatus_LPSPI_Busy)
        {
            SDK_DelayAtLeastUs(XFER_RETRY_DELAY_US, SystemCoreClock);
            continue;
        }
        return st;
    }
    return st;
}

/* ── Public API ─────────────────────────────────────────────────────────── */

status_t MPU6500_SPI_InitMode(mpu6500_t          *dev,
                               LPSPI_Type         *base,
                               uint32_t            srcClockHz,
                               uint32_t            baudHz,
                               lpspi_which_pcs_t   whichPcs,
                               uint32_t            pcsFlags,
                               mpu6500_spi_mode_t  mode)
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
    dev->mode       = mode;

    lpspi_master_config_t cfg;
    LPSPI_MasterGetDefaultConfig(&cfg);

    cfg.baudRate          = dev->baudHz;
    cfg.bitsPerFrame      = 8U;
    cfg.direction         = kLPSPI_MsbFirst;
    cfg.whichPcs          = dev->whichPcs;
    cfg.pcsActiveHighOrLow = kLPSPI_PcsActiveLow;
    cfg.pinCfg            = kLPSPI_SdiInSdoOut;

    if (mode == MPU6500_SPI_MODE3)
    {
        cfg.cpol = kLPSPI_ClockPolarityActiveLow;   /* CPOL=1 */
        cfg.cpha = kLPSPI_ClockPhaseSecondEdge;     /* CPHA=1 */
    }
    else
    {
        cfg.cpol = kLPSPI_ClockPolarityActiveHigh;
        cfg.cpha = kLPSPI_ClockPhaseFirstEdge;
    }

    LPSPI_MasterInit(dev->base, &cfg, dev->srcClockHz);
    return kStatus_Success;
}

status_t MPU6500_ReadBytes(mpu6500_t *dev, uint8_t startReg,
                            uint8_t *dst, size_t n)
{
    if ((dev == NULL) || (dst == NULL) || (n == 0U))
    {
        return kStatus_InvalidArgument;
    }

    size_t done = 0U;
    while (done < n)
    {
        size_t  chunk = n - done;
        if (chunk > MPU6500_MAX_CHUNK) chunk = MPU6500_MAX_CHUNK;

        uint8_t tx[1U + MPU6500_MAX_CHUNK];
        uint8_t rx[1U + MPU6500_MAX_CHUNK];

        tx[0] = (uint8_t)(MPU6500_SPI_READ_BIT | (startReg & 0x7FU));
        memset(&tx[1], 0x00U, chunk);
        memset(rx,     0x00U, 1U + chunk);

        status_t st = spi_xfer(dev, tx, rx, 1U + chunk);
        if (st != kStatus_Success) { return st; }

        memcpy(&dst[done], &rx[1], chunk);
        done     += chunk;
        startReg  = (uint8_t)(startReg + (uint8_t)chunk);
    }
    return kStatus_Success;
}

status_t MPU6500_ReadReg(mpu6500_t *dev, uint8_t reg, uint8_t *val)
{
    return MPU6500_ReadBytes(dev, reg, val, 1U);
}

status_t MPU6500_WriteReg(mpu6500_t *dev, uint8_t reg, uint8_t val)
{
    if (dev == NULL) { return kStatus_InvalidArgument; }

    uint8_t tx[2] = { (uint8_t)(reg & 0x7FU), val };
    uint8_t rx[2] = { 0U, 0U };
    return spi_xfer(dev, tx, rx, 2U);
}

status_t MPU6500_ReadWhoAmI(mpu6500_t *dev, uint8_t *who)
{
    if ((dev == NULL) || (who == NULL)) { return kStatus_InvalidArgument; }
    *who = 0U;
    return MPU6500_ReadReg(dev, MPU6500_REG_WHO_AM_I, who);
}
