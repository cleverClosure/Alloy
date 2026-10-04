/* Darwin arm64 register-preservation probe. Author: Timur Isaev */
.text
.p2align 2
.globl _alloy_jit_register_probe
_alloy_jit_register_probe:
    sub sp, sp, #0x500
    add x17, sp, #0x400
    stp x19, x20, [x17, #0x00]
    stp x21, x22, [x17, #0x10]
    stp x23, x24, [x17, #0x20]
    stp x25, x26, [x17, #0x30]
    stp x27, x28, [x17, #0x40]
    stp x29, x30, [x17, #0x50]
    stp d8, d9, [x17, #0x60]
    stp d10, d11, [x17, #0x70]
    stp d12, d13, [x17, #0x80]
    stp d14, d15, [x17, #0x90]
    mrs x9, fpcr
    mrs x10, fpsr
    stp x9, x10, [x17, #0xa0]
    str x1, [x17, #0xb0]
    mov x2, sp
    str x2, [x1, #0x3a0]
    adr x30, Lprobe_return
    str x30, [x1, #0x3a8]
    mov x16, x0
    mov x9, #0x5a5a
    movk x9, #0x5a5a, lsl #16
    movk x9, #0x5a5a, lsl #32
    movk x9, #0x5a5a, lsl #48
    stp x9, x9, [sp, #-128]
    stp x9, x9, [sp, #-112]
    stp x9, x9, [sp, #-96]
    stp x9, x9, [sp, #-80]
    stp x9, x9, [sp, #-64]
    stp x9, x9, [sp, #-48]
    stp x9, x9, [sp, #-32]
    stp x9, x9, [sp, #-16]
    mov x9, #0xa0000000
    msr nzcv, x9
    mov x9, #0x400000
    msr fpcr, x9
    mov x9, #0x11
    movk x9, #0x800, lsl #16
    msr fpsr, x9
    mov x0, #0x100
    mov x1, #0x101
    mov x2, #0x102
    mov x3, #0x103
    mov x4, #0x104
    mov x5, #0x105
    mov x6, #0x106
    mov x7, #0x107
    mov x8, #0x108
    mov x9, #0x109
    mov x10, #0x10a
    mov x11, #0x10b
    mov x12, #0x10c
    mov x13, #0x10d
    mov x14, #0x10e
    mov x15, #0x10f
    mov x17, #0x111
    mov x19, #0x113
    mov x20, #0x114
    mov x21, #0x115
    mov x22, #0x116
    mov x23, #0x117
    mov x24, #0x118
    mov x25, #0x119
    mov x26, #0x11a
    mov x27, #0x11b
    mov x28, #0x11c
    mov x29, #0x11d
    movi v0.16b, #1
    movi v1.16b, #2
    movi v2.16b, #3
    movi v3.16b, #4
    movi v4.16b, #5
    movi v5.16b, #6
    movi v6.16b, #7
    movi v7.16b, #8
    movi v8.16b, #9
    movi v9.16b, #10
    movi v10.16b, #11
    movi v11.16b, #12
    movi v12.16b, #13
    movi v13.16b, #14
    movi v14.16b, #15
    movi v15.16b, #16
    movi v16.16b, #17
    movi v17.16b, #18
    movi v18.16b, #19
    movi v19.16b, #20
    movi v20.16b, #21
    movi v21.16b, #22
    movi v22.16b, #23
    movi v23.16b, #24
    movi v24.16b, #25
    movi v25.16b, #26
    movi v26.16b, #27
    movi v27.16b, #28
    movi v28.16b, #29
    movi v29.16b, #30
    movi v30.16b, #31
    movi v31.16b, #32
    br x16
Lprobe_return:
    add x17, sp, #0x400
    ldr x0, [x17, #0xb0]
    mov x1, sp
    mov x2, #0x3a0
    bl _memcpy
    add x17, sp, #0x400
    ldp x9, x10, [x17, #0xa0]
    msr fpcr, x9
    msr fpsr, x10
    ldp d8, d9, [x17, #0x60]
    ldp d10, d11, [x17, #0x70]
    ldp d12, d13, [x17, #0x80]
    ldp d14, d15, [x17, #0x90]
    ldp x19, x20, [x17, #0x00]
    ldp x21, x22, [x17, #0x10]
    ldp x23, x24, [x17, #0x20]
    ldp x25, x26, [x17, #0x30]
    ldp x27, x28, [x17, #0x40]
    ldp x29, x30, [x17, #0x50]
    add sp, sp, #0x500
    ret
.p2align 2
.globl _alloy_jit_sample_start
_alloy_jit_sample_start:
    stp x0, x1, [sp, #0x0]
    stp x2, x3, [sp, #0x10]
    stp x4, x5, [sp, #0x20]
    stp x6, x7, [sp, #0x30]
    stp x8, x9, [sp, #0x40]
    stp x10, x11, [sp, #0x50]
    stp x12, x13, [sp, #0x60]
    stp x14, x15, [sp, #0x70]
    stp x16, x17, [sp, #0x80]
    stp x18, x19, [sp, #0x90]
    stp x20, x21, [sp, #0xa0]
    stp x22, x23, [sp, #0xb0]
    stp x24, x25, [sp, #0xc0]
    stp x26, x27, [sp, #0xd0]
    stp x28, x29, [sp, #0xe0]
    str x30, [sp, #0xf0]
    mov x0, sp
    str x0, [sp, #0xf8]
    stp q0, q1, [sp, #0x100]
    stp q2, q3, [sp, #0x120]
    stp q4, q5, [sp, #0x140]
    stp q6, q7, [sp, #0x160]
    stp q8, q9, [sp, #0x180]
    stp q10, q11, [sp, #0x1a0]
    stp q12, q13, [sp, #0x1c0]
    stp q14, q15, [sp, #0x1e0]
    stp q16, q17, [sp, #0x200]
    stp q18, q19, [sp, #0x220]
    stp q20, q21, [sp, #0x240]
    stp q22, q23, [sp, #0x260]
    stp q24, q25, [sp, #0x280]
    stp q26, q27, [sp, #0x2a0]
    stp q28, q29, [sp, #0x2c0]
    stp q30, q31, [sp, #0x2e0]
    mrs x0, nzcv
    str x0, [sp, #0x300]
    mrs x0, fpcr
    str x0, [sp, #0x308]
    mrs x0, fpsr
    str x0, [sp, #0x310]
    str xzr, [sp, #0x318]
    add x2, sp, #0x320
    ldp x0, x1, [sp, #-128]
    stp x0, x1, [x2, #0]
    ldp x0, x1, [sp, #-112]
    stp x0, x1, [x2, #16]
    ldp x0, x1, [sp, #-96]
    stp x0, x1, [x2, #32]
    ldp x0, x1, [sp, #-80]
    stp x0, x1, [x2, #48]
    ldp x0, x1, [sp, #-64]
    stp x0, x1, [x2, #64]
    ldp x0, x1, [sp, #-48]
    stp x0, x1, [x2, #80]
    ldp x0, x1, [sp, #-32]
    stp x0, x1, [x2, #96]
    ldp x0, x1, [sp, #-16]
    stp x0, x1, [x2, #112]
    ret
.globl _alloy_jit_sample_end
_alloy_jit_sample_end:
