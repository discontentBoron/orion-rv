    .option norvc
    .section .text.start
    .globl _start
    .type _start, @function

_start:
    li      sp, 960

    call    main

    # Store benchmark result
    li      t0, 0x3f0
    sw      a0, 0(t0)

    # Store completion flag
    li      t0, 0x3f4
    li      t1, 1
    sw      t1, 0(t0)

    # Retirement marker.
    # This instruction comes after the DONE store.
    # When x31 retires, everything above has retired too.
    li      t6, 1

stop:
    j       stop

    .size _start, .-_start