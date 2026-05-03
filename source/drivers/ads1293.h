/*
 * ads1293.h
 *
 * Native MCUXpresso driver for the ADS1293 ECG front-end.
 *
 * The register sequence mirrors the working Protocentral Arduino library
 * configuration, while using the NXP LPSPI blocking API directly.
 */

#ifndef ADS1293_H_
#define ADS1293_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "fsl_common.h"
#include "fsl_lpspi.h"

#define ADS1293_SPI_READ_BIT   (0x80U)
#define ADS1293_SPI_WRITE_MASK (0x7FU)

typedef enum
{
    ADS1293_FRONTEND_3_LEAD = 0,
    ADS1293_FRONTEND_5_LEAD = 1
} ads1293_frontend_t;

typedef struct
{
    LPSPI_Type        *base;
    uint32_t           srcClockHz;
    uint32_t           baudHz;
    lpspi_which_pcs_t  whichPcs;
    uint32_t           pcsFlags;
} ads1293_t;

typedef struct
{
    int32_t ch1;
    int32_t ch2;
    int32_t ch3;
} ads1293_samples_t;

status_t ADS1293_Attach(ads1293_t        *dev,
                         LPSPI_Type       *base,
                         uint32_t          srcClockHz,
                         uint32_t          baudHz,
                         lpspi_which_pcs_t whichPcs,
                         uint32_t          pcsFlags);

status_t ADS1293_InitBus(ads1293_t *dev);
status_t ADS1293_Configure(ads1293_t *dev, ads1293_frontend_t frontend);

status_t ADS1293_WriteReg(ads1293_t *dev, uint8_t reg, uint8_t val);
status_t ADS1293_ReadReg(ads1293_t *dev, uint8_t reg, uint8_t *val);
status_t ADS1293_ReadRevision(ads1293_t *dev, uint8_t *revid);
status_t ADS1293_IsDataReady(ads1293_t *dev, bool *ready);
status_t ADS1293_ReadECGData(ads1293_t *dev, ads1293_samples_t *samples);

int32_t ADS1293_SignExtend24(uint32_t raw24);

#endif /* ADS1293_H_ */
