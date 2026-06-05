/*
 * Standalone CM4 linker script for the Phase 4 Bag/RF classifier worker.
 * CM7 boots CM4 from external FlexSPI flash at 0x30080000.
 */

GROUP (
  "libcr_nohost_nf.a"
  "libcr_c.a"
  "libcr_eabihelpers.a"
  "libgcc.a"
)

ENTRY(ResetISR)

MEMORY
{
  BOARD_FLASH (rx)  : ORIGIN = 0x30080000, LENGTH = 0x00100000
  SRAM_DTC_cm4 (rwx): ORIGIN = 0x202C0000, LENGTH = 0x00008000
  SRAM_ITC_cm4 (rwx): ORIGIN = 0x1FFE0000, LENGTH = 0x00020000
}

SECTIONS
{
  .text : ALIGN(4)
  {
    FILL(0xff)
    __vectors_start__ = ABSOLUTE(.);
    KEEP(*(.isr_vector))

    . = ALIGN(4);
    __section_table_start = .;
    __data_section_table = .;
    LONG(LOADADDR(.data));
    LONG(ADDR(.data));
    LONG(SIZEOF(.data));
    __data_section_table_end = .;
    __bss_section_table = .;
    LONG(ADDR(.bss));
    LONG(SIZEOF(.bss));
    __bss_section_table_end = .;
    __section_table_end = .;

    *(.after_vectors*)
    *(.text*)
    *(.rodata .rodata.* .constdata .constdata.*)
    *(.crp)
    . = ALIGN(4);
  } > BOARD_FLASH

  .ARM.extab : ALIGN(4)
  {
    *(.ARM.extab* .gnu.linkonce.armextab.*)
  } > BOARD_FLASH

  .ARM.exidx : ALIGN(4)
  {
    __exidx_start = .;
    *(.ARM.exidx* .gnu.linkonce.armexidx.*)
    __exidx_end = .;
  } > BOARD_FLASH

  _etext = .;

  .data : ALIGN(4)
  {
    FILL(0xff)
    _data = .;
    PROVIDE(__start_data_RAM = .);
    PROVIDE(__start_data_SRAM_DTC_cm4 = .);
    *(vtable)
    *(.ramfunc*)
    *(RamFunction)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
    PROVIDE(__end_data_RAM = .);
    PROVIDE(__end_data_SRAM_DTC_cm4 = .);
  } > SRAM_DTC_cm4 AT > BOARD_FLASH

  .bss (NOLOAD) : ALIGN(4)
  {
    _bss = .;
    PROVIDE(__start_bss_RAM = .);
    PROVIDE(__start_bss_SRAM_DTC_cm4 = .);
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
    PROVIDE(__end_bss_RAM = .);
    PROVIDE(__end_bss_SRAM_DTC_cm4 = .);
  } > SRAM_DTC_cm4

  .noinit (NOLOAD) : ALIGN(4)
  {
    _noinit = .;
    *(.noinit*)
    . = ALIGN(4);
    _end_noinit = .;
  } > SRAM_DTC_cm4

  _HeapSize = 0x0800;
  .heap (NOLOAD) : ALIGN(4)
  {
    _pvHeapStart = .;
    . += _HeapSize;
    . = ALIGN(4);
    _pvHeapLimit = .;
  } > SRAM_DTC_cm4

  _StackSize = 0x2000;
  .heap2stackfill (NOLOAD) :
  {
    . += _StackSize;
  } > SRAM_DTC_cm4

  .stack ORIGIN(SRAM_DTC_cm4) + LENGTH(SRAM_DTC_cm4) - _StackSize (NOLOAD) : ALIGN(4)
  {
    _vStackBase = .;
    . = ALIGN(4);
    _vStackTop = . + _StackSize;
  } > SRAM_DTC_cm4

  _image_start = LOADADDR(.text);
  _image_end = LOADADDR(.data) + SIZEOF(.data);
  _image_size = _image_end - _image_start;
  _boot_loadaddr = ORIGIN(BOARD_FLASH);
  _boot_size = LENGTH(BOARD_FLASH);
}
