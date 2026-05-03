/*
 * mpu6500_spi.h
 *
 * AUTHOR:      Marvin Christian
 * TITLE:       MPU6500 SPI driver for ECG thesis project
 * DATE:        28/03/2026
 *
 * SUMMARY:
 *      SPI driver for the MPU-6500 using LPSPI1 with native hardware PCS
 *      chip-select lines. Three devices share MOSI/MISO/SCLK and are each
 *      selected by a separate LPSPI PCS channel (PCS0, PCS1, PCS2).
 *
 *      Physical wiring (Arduino header):
 *        J10 pin 4 (D11) — MOSI
 *        J10 pin 5 (D12) — MISO
 *        J10 pin 6 (D13) — SCLK
 *        J10[6] — CS0 → IMU 0 (LPSPI1 PCS0)
 *        J9[5]  — CS1 → IMU 1 (LPSPI1 PCS1)
 *        J9[1]  — CS2 → IMU 2 (LPSPI1 PCS2)
 *
 *      The three CS pins must be configured as LPSPI1 PCS0/PCS1/PCS2
 *      in pin_mux.c for this to work.
 *
 *      SPI protocol:
 *        Read:  send (0x80 | addr), receive data byte
 *        Write: send (0x7F & addr), send data byte
 *        All transfers use kLPSPI_MasterPcsContinuous to hold CS low
 *        for the full multi-byte transaction.
 *
 * REFERENCES:
 *      MPU-6500 Register Map RM-MPU-6500A-00 Rev 2.1, InvenSense 2013
 */

#ifndef MPU6500_SPI_H_
#define MPU6500_SPI_H_

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "fsl_common.h"
#include "fsl_lpspi.h"

/* ── SPI protocol ────────────────────────────────────────────────────────── */
#define MPU6500_SPI_READ_BIT        (0x80U)

/* ── Register addresses ─────────────────────────────────────────────────── */
#define MPU6500_REG_SMPLRT_DIV      (0x19U)
#define MPU6500_REG_CONFIG          (0x1AU)
#define MPU6500_REG_GYRO_CONFIG     (0x1BU)
#define MPU6500_REG_ACCEL_CONFIG    (0x1CU)
#define MPU6500_REG_ACCEL_CONFIG2   (0x1DU)
#define MPU6500_REG_ACCEL_XOUT_H    (0x3BU)
#define MPU6500_REG_USER_CTRL       (0x6AU)
#define MPU6500_REG_PWR_MGMT_1      (0x6BU)
#define MPU6500_REG_PWR_MGMT_2      (0x6CU)
#define MPU6500_REG_WHO_AM_I        (0x75U)

/* ── WHO_AM_I value ─────────────────────────────────────────────────────── */
#define MPU_WHO_AM_I_MPU6500        (0x70U)

/* ── USER_CTRL bit masks ────────────────────────────────────────────────── */
#define MPU6500_USER_CTRL_I2C_IF_DIS_MASK  (0x10U)

/* ── Chunk size for burst reads ─────────────────────────────────────────── */
#define MPU6500_MAX_CHUNK           (64U)

/* ── SPI mode ───────────────────────────────────────────────────────────── */
typedef enum
{
    MPU6500_SPI_MODE0 = 0,
    MPU6500_SPI_MODE3 = 3
} mpu6500_spi_mode_t;

/* ── Device handle ──────────────────────────────────────────────────────── */
typedef struct
{
    LPSPI_Type          *base;          /* LPSPI peripheral (LPSPI1)        */
    uint32_t             srcClockHz;    /* LPSPI source clock frequency     */
    uint32_t             baudHz;        /* SPI baud rate                    */
    lpspi_which_pcs_t    whichPcs;      /* kLPSPI_Pcs0 / Pcs1 / Pcs2       */
    uint32_t             pcsFlags;      /* kLPSPI_MasterPcs0/1/2            */
    mpu6500_spi_mode_t   mode;          /* MPU6500_SPI_MODE3                */
} mpu6500_t;

/* ── Public API ─────────────────────────────────────────────────────────── */

/*
 * Initialise LPSPI in master mode and configure the device handle.
 * Call once for IMU0 (PCS0); IMU1/2 handles are cloned from IMU0
 * in imu_manager.c with only whichPcs/pcsFlags changed.
 */
status_t MPU6500_SPI_InitMode(mpu6500_t          *dev,
                               LPSPI_Type         *base,
                               uint32_t            srcClockHz,
                               uint32_t            baudHz,
                               lpspi_which_pcs_t   whichPcs,
                               uint32_t            pcsFlags,
                               mpu6500_spi_mode_t  mode);

status_t MPU6500_ReadReg    (mpu6500_t *dev, uint8_t reg, uint8_t *val);
status_t MPU6500_WriteReg   (mpu6500_t *dev, uint8_t reg, uint8_t  val);
status_t MPU6500_ReadBytes  (mpu6500_t *dev, uint8_t startReg,
                              uint8_t *dst, size_t n);
status_t MPU6500_ReadWhoAmI (mpu6500_t *dev, uint8_t *who);

#endif /* MPU6500_SPI_H_ */
