ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 1K
}

SECTIONS
{
    .text :
    {
        . = ALIGN(4);
        KEEP(*(.text.start))
        *(.text*)
        *(.rodata*)
    } > IMEM

    /DISCARD/ :
    {
        *(.comment)
        *(.riscv.attributes)
        *(.note*)
    }
}