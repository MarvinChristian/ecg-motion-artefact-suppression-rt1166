################################################################################
# Standalone CM4 build for the Phase 4 Bag/RF classifier worker.
################################################################################

RM := rm -rf
ROOT := ..

BUILD_ARTIFACT_NAME := Phase4_CM4_Classifier
BUILD_ARTIFACT := $(BUILD_ARTIFACT_NAME).axf

CC := arm-none-eabi-gcc
OBJCOPY := arm-none-eabi-objcopy
SIZE := arm-none-eabi-size

DEFINES := \
  -D__REDLIB__ \
  -DCPU_MIMXRT1166DVM6A_cm4 \
  -DMCUXPRESSO_SDK \
  -DMIMXRT1166_cm4_SERIES \
  -D__MCUXPRESSO \
  -D__USE_CMSIS \
  -DDEBUG \
  -DSDK_OS_BAREMETAL \
  -DDISABLEFLOAT16 \
  -DDISABLE_WDOG=1

INCLUDES := \
  -I"$(ROOT)/source" \
  -I"$(ROOT)/drivers" \
  -I"$(ROOT)/device" \
  -I"$(ROOT)/device/periph" \
  -I"$(ROOT)/CMSIS" \
  -I"$(ROOT)/CMSIS/m-profile" \
  -I"$(ROOT)/board" \
  -I"$(ROOT)/utilities"

CPU_FLAGS := -mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard -mthumb
CFLAGS := -std=gnu99 $(DEFINES) $(INCLUDES) -O3 -fno-common -g3 -gdwarf-4 \
  -ffunction-sections -fdata-sections -fno-builtin -fmerge-constants \
  -fstack-usage -specs=redlib.specs $(CPU_FLAGS) -MMD -MP
LDFLAGS := -nostdlib -Xlinker -no-warn-rwx-segments \
  -Xlinker -Map="$(BUILD_ARTIFACT_NAME).map" -Xlinker --gc-sections \
  -Xlinker -print-memory-usage -Xlinker --sort-section=alignment \
  -Xlinker --cref $(CPU_FLAGS) -T phase4_m4_classifier_cm4.ld

OBJS := \
  startup_mimxrt1166_cm4.o \
  system_MIMXRT1166_cm4.o \
  phase4_m4_classifier.o

DEPS := $(OBJS:.o=.d)

all: $(BUILD_ARTIFACT) $(BUILD_ARTIFACT_NAME).bin

$(BUILD_ARTIFACT): $(OBJS) phase4_m4_classifier_cm4.ld makefile
	$(CC) $(LDFLAGS) -o "$@" $(OBJS)
	$(SIZE) "$@"

$(BUILD_ARTIFACT_NAME).bin: $(BUILD_ARTIFACT)
	$(OBJCOPY) -O binary "$<" "$@"

startup_mimxrt1166_cm4.o: $(ROOT)/startup/startup_mimxrt1166_cm4.c makefile
	$(CC) $(CFLAGS) -MF"$(@:.o=.d)" -MT"$@" -o "$@" -c "$<"

system_MIMXRT1166_cm4.o: $(ROOT)/device/system_MIMXRT1166_cm4.c makefile
	$(CC) $(CFLAGS) -MF"$(@:.o=.d)" -MT"$@" -o "$@" -c "$<"

phase4_m4_classifier.o: $(ROOT)/source/phase4_m4_classifier.c makefile
	$(CC) $(CFLAGS) -MF"$(@:.o=.d)" -MT"$@" -o "$@" -c "$<"

clean:
	-$(RM) $(OBJS) $(DEPS) $(OBJS:.o=.su) $(BUILD_ARTIFACT) $(BUILD_ARTIFACT_NAME).bin $(BUILD_ARTIFACT_NAME).map

.PHONY: all clean

-include $(DEPS)
