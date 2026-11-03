## JIT row kernels behind Dynasm: exact solid source-over blending.
##
## ABI (all arches): `proc(dst, cov: pointer, n: int64, ctx: pointer)`.
## - `dst`: first RGBA8 pixel of the row run (4 bytes per pixel).
## - `cov`: pointer to `n` float64 coverages from the Nim span pass
##   (1.0 interior, 0.0 outside; edge pixels carry supersampled values).
## - `ctx`: pointer to `SolidCtx` (paint constants + div-table pointer).
##
## Exactness vs `surface.blendPixel` (source-over): dst bytes convert via
## a 256-entry f64 table filled with `float64(i) / 255.0` (bit-identical
## to the scalar division, and it round-trips: worst error 3e-14 against
## a 0.5 truncation margin); op order replicates the scalar blend
## exactly, including `mul-then-div` for `t`-style terms and the
## `sa + da*inv` alpha form. Coverage values come from the same span
## pass, so `sa * cov` rounding matches too. Finite colors only: NaN
## inputs clamp differently than the scalar branches (documented
## divergence; API colors are finite).
##
## x64 keeps `c255/zero/one/half` in xmm4-7 (xmm6/7 are callee-saved on
## Win64 and saved/restored per row); paint channels and `sa` stream
## from ctx. AArch64 hoists everything (upper d-regs are scratch).
## Constants travel via ctx, never baked into code, so one kernel serves
## all solid fills. The macro 16-byte-aligns constant pools (packed FP
## memory operands fault on misaligned pools cross-platform).

import dynasm
import ./jitctx

export jitctx

proc buildSolidRowX64*(): ExecutableBuffer =
  ## Scalar-double row kernel. Op order per channel replicates
  ## `blendPixel`: `sr*sa + table[D]*inv`, clamp, `*255 + 0.5`, truncate.
  ## Register map (loop): xmm0 = sa_c, xmm1 = inv, xmm2/xmm3 = work,
  ## xmm4-7 = c255/zero/one/half (xmm6/7 saved/restored per row).
  ## Single-pixel loop (an x2-unrolled variant measured no win: the
  ## bottleneck is dst/table memory traffic, not loop overhead, and the
  ## out-of-order window already overlaps iterations).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 32
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    mov r9, [r8 + 64] # divtab
    movsd xmm0, [r8 + 24] # sa
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe fwd("done")
    movsd xmm4, [r8 + 32] # c255
    movsd xmm5, [r8 + 48] # zero
    movsd xmm6, [r8 + 56] # one
    movsd xmm7, [r8 + 40] # half
    cmp rax, 0
    jle fwd("done")
    label row
    movsd xmm0, [r8 + 24] # sa
    mulsd xmm0, [r11] # cov -> sa_c
    movsd xmm1, xmm6 # one
    subsd xmm1, xmm0 # inv
    # R
    movsd xmm2, [r8 + 0] # sr
    mulsd xmm2, xmm0
    movzx edx, byte [r10]
    movsd xmm3, [r9 + rdx*8] # table[D]
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    maxpd xmm2, xmm5 # low lane only; high lane unused
    minpd xmm2, xmm6
    mulsd xmm2, xmm4
    addsd xmm2, xmm7
    cvttsd2si edx, xmm2
    mov byte [r10], dl
    # G
    movsd xmm2, [r8 + 8] # sg
    mulsd xmm2, xmm0
    movzx edx, byte [r10 + 1]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    mulsd xmm2, xmm4
    addsd xmm2, xmm7
    cvttsd2si edx, xmm2
    mov byte [r10 + 1], dl
    # B
    movsd xmm2, [r8 + 16] # sb
    mulsd xmm2, xmm0
    movzx edx, byte [r10 + 2]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    mulsd xmm2, xmm4
    addsd xmm2, xmm7
    cvttsd2si edx, xmm2
    mov byte [r10 + 2], dl
    # A: sa_c + da*inv
    movzx edx, byte [r10 + 3]
    movsd xmm2, [r9 + rdx*8]
    mulsd xmm2, xmm1
    addsd xmm2, xmm0
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    mulsd xmm2, xmm4
    addsd xmm2, xmm7
    cvttsd2si edx, xmm2
    mov byte [r10 + 3], dl
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    add rsp, 32
    ret()
  a.finalize()

proc buildSolidRowGenX64*(op: static CompOp): ExecutableBuffer =
  ## Solid source-over head with the generic-op blend tail for any
  ## non-sourceOver `op` (see `blend_x64` for the entry contract).
  ## Paint channels clamp like the scalar generic path; no transparent
  ## early-out (clearing ops must run). Compile-time `op`: getters
  ## dispatch per value (see `getSolid`).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 160
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movabs rcx, 0x3EB0C6F7A0B5ED8D # 1e-6 bits (ao threshold)
    mov qword [rsp + 152], rcx
    mov r9, [r8 + 64] # divtab
    movsd xmm4, [r8 + 32] # c255
    movsd xmm5, [r8 + 48] # zero
    movsd xmm6, [r8 + 56] # one
    movsd xmm7, [r8 + 40] # half
    cmp rax, 0
    jle fwd("done")
    label row
    movsd xmm0, [r8 + 24] # sa
    mulsd xmm0, [r11] # cov -> sa (no early-out: clearing ops run)
    movsd xmm10, xmm0
    movsd xmm0, [r8 + 0] # sr, clamped like the scalar generic path
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm1, [r8 + 8]
    maxpd xmm1, xmm5
    minpd xmm1, xmm6
    movsd xmm2, [r8 + 16]
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
  # NB: `include` must nest in `when` here (compiler quirk: includes at
  # the direct body level of a generic proc fail to resolve). Getters
  # only instantiate these builders with non-sourceOver ops.
  when op != coSourceOver:
    include blend_x64
  dynasm a:
    arch x64
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    add rsp, 160
    ret()
  a.finalize()

proc buildSolidRowAarch64*(): ExecutableBuffer =
  ## Same algorithm for AArch64. Upper d-regs hoist all constants;
  ## no int<->float conversions anywhere (table + f64 coverage).
  ## NOTE: execution not yet verified on hardware; the backend runs
  ## this kernel only on amd64 until an ARM run signs it off.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0 # dst cursor
    mov x10, x1 # cov cursor
    mov x11, x2 # count
    mov x12, x3 # ctx
    ldr d19, [x12, 24] # sa
    fcmp d19, 0.0
    b.le fwd("done")
    cbz x11, fwd("done")
    ldr d16, [x12] # sr
    ldr d17, [x12, 8] # sg
    ldr d18, [x12, 16] # sb
    ldr d20, [x12, 32] # c255
    ldr d21, [x12, 48] # zero
    ldr d22, [x12, 56] # one
    ldr d23, [x12, 40] # half
    ldr x13, [x12, 64] # divtab
    label row
    ldr d0, [x10] # cov
    fmul d24, d19, d0 # sa_c
    fsub d25, d22, d24 # inv
    # R
    fmul d0, d16, d24
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d25
    fadd d0, d0, d1
    fmax d0, d0, d21
    fmin d0, d0, d22
    fmul d0, d0, d20
    fadd d0, d0, d23
    fcvtzs w4, d0
    strb w4, [x9]
    # G
    fmul d0, d17, d24
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d25
    fadd d0, d0, d1
    fmax d0, d0, d21
    fmin d0, d0, d22
    fmul d0, d0, d20
    fadd d0, d0, d23
    fcvtzs w4, d0
    strb w4, [x9, 1]
    # B
    fmul d0, d18, d24
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d25
    fadd d0, d0, d1
    fmax d0, d0, d21
    fmin d0, d0, d22
    fmul d0, d0, d20
    fadd d0, d0, d23
    fcvtzs w4, d0
    strb w4, [x9, 2]
    # A
    ldrb w4, [x9, 3]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d25
    fadd d1, d1, d24
    fmax d1, d1, d21
    fmin d1, d1, d22
    fmul d1, d1, d20
    fadd d1, d1, d23
    fcvtzs w4, d1
    strb w4, [x9, 3]
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    ret()
  a.finalize()

proc buildSolidRowGenAarch64*(op: static CompOp): ExecutableBuffer =
  ## Solid head with the generic-op tail (`blend_a64`, same contract as
  ## x64). Assemble-verified only, like the kernel above.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0
    mov x10, x1
    mov x11, x2
    mov x12, x3
    cbz x11, fwd("done")
    sub sp, sp, 64
    movz x4, 0xED8D
    movk x4, 0x0B5E, lsl, 16
    movk x4, 0xC6F7, lsl, 32
    movk x4, 0x3EB0, lsl, 48
    fmov d25, x4 # 1e-6 threshold
    ldr d16, [x12, 32] # c255
    ldr d17, [x12, 48] # zero
    ldr d18, [x12, 56] # one
    ldr d19, [x12, 40] # half
    ldr x13, [x12, 64] # divtab
    label row
    ldr d3, [x10] # cov
    ldr d22, [x12, 24] # sa
    fmul d22, d22, d3
    ldr d0, [x12] # sr, clamped like the scalar generic path
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x12, 8]
    fmax d1, d1, d17
    fmin d1, d1, d18
    ldr d2, [x12, 16]
    fmax d2, d2, d17
    fmin d2, d2, d18
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_a64
  dynasm a:
    arch aarch64
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    add sp, sp, 64
    ret()
  a.finalize()

proc buildLinearRowX64*(): ExecutableBuffer =
  ## Linear-gradient source-over row kernel, same ABI as solid.
  ## Per-pixel op order replicates `paint.sample` (linear branch) +
  ## `blendPixel` exactly:
  ## - `x` starts at `ctx.rowX` (`float64(x0)+0.5`, exact) and adds
  ##   exactly `1.0` per pixel, so every `x` equals the scalar
  ##   `float64(x)+0.5` bit-for-bit (small ints + 0.5 are exact).
  ## - `m2y = m2*y`, `m3y = m3*y` are baked per row in Nim with the same
  ##   multiply as the scalar `map.apply`, so `qx = (m0*x + m2y) + m4`
  ##   matches `(m0*x + m2*y) + m4` bit-for-bit; same for `qy`.
  ## - `t_num = (qx-sx)*dx + (qy-sy)*dy`, `t = t_num/len2` via `divsd`
  ##   (never reciprocal-multiply), clamped via max/min (finite-only).
  ## - Channels lerp as `c0 + dc*t` (no result clamp, like `lerpColor`);
  ##   alpha scales `a_lerp * aAlpha` in that order, then `clamp01`.
  ## - Blend replicates source-over: `c*sa_c + table[D]*inv`, clamp,
  ##   `*255 + 0.5`, truncate; dst bytes convert through the div-table
  ##   (bit-identical to `float64(byte)/255.0`).
  ## Registers: xmm4-7 = c255/zero/one/half (xmm6/7 saved for Win64);
  ## xmm8-11 = x/t/sa_c/inv (saved); xmm0-3 = work. Constants stream
  ## from ctx (L1); the blend, not paint eval, is the bottleneck.
  ## Single-pixel loop (an x2-unrolled variant measured no win; see
  ## the solid kernel note).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 96
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    mov r9, [r8 + 176] # divtab
    movsd xmm4, [r8 + 144] # c255
    movsd xmm5, [r8 + 160] # zero
    movsd xmm6, [r8 + 168] # one
    movsd xmm7, [r8 + 152] # half
    cmp rax, 0
    jle fwd("done")
    movsd xmm8, [r8 + 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0] # m0
    addsd xmm0, [r8 + 192] # m2y
    addsd xmm0, [r8 + 16] # m4
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8] # m1
    addsd xmm1, [r8 + 200] # m3y
    addsd xmm1, [r8 + 24] # m5
    # t = ((qx-sx)*dx + (qy-sy)*dy) / len2, clamped
    subsd xmm0, [r8 + 32] # sx
    mulsd xmm0, [r8 + 48] # dx
    subsd xmm1, [r8 + 40] # sy
    mulsd xmm1, [r8 + 56] # dy
    addsd xmm0, xmm1
    divsd xmm0, [r8 + 64] # len2
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm9, xmm0 # t
    # sa_c = clamp01(a_lerp * aAlpha) * cov; inv = 1 - sa_c
    movsd xmm0, [r8 + 120] # a0
    movsd xmm1, [r8 + 128] # da
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, [r8 + 136] # aAlpha
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, [r11] # cov
    movsd xmm10, xmm0 # sa_c
    movsd xmm11, xmm6 # one
    subsd xmm11, xmm10 # inv
    # R
    movsd xmm0, [r8 + 72] # r0
    movsd xmm1, [r8 + 80] # dr
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10], dl
    # G
    movsd xmm0, [r8 + 88] # g0
    movsd xmm1, [r8 + 96] # dg
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10 + 1]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 1], dl
    # B
    movsd xmm0, [r8 + 104] # b0
    movsd xmm1, [r8 + 112] # db
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10 + 2]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 2], dl
    # A: sa_c + da*inv
    movzx edx, byte [r10 + 3]
    movsd xmm0, [r9 + rdx*8]
    mulsd xmm0, xmm11
    addsd xmm0, xmm10
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 3], dl
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 96
    ret()
  a.finalize()

proc buildLinearRowGenX64*(op: static CompOp): ExecutableBuffer =
  ## Linear-gradient head with the generic-op blend tail for any
  ## non-sourceOver `op` (entry contract in `blend_x64`). Paint eval
  ## mirrors `paint.sample` exactly like the sourceOver kernel; channels
  ## clamp and clearing ops run (no transparent early-out).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 160
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    movabs rcx, 0x3EB0C6F7A0B5ED8D # 1e-6 bits (ao threshold)
    mov qword [rsp + 152], rcx
    mov r9, [r8 + 176] # divtab
    movsd xmm4, [r8 + 144] # c255
    movsd xmm5, [r8 + 160] # zero
    movsd xmm6, [r8 + 168] # one
    movsd xmm7, [r8 + 152] # half
    cmp rax, 0
    jle fwd("done")
    movsd xmm8, [r8 + 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0] # m0
    addsd xmm0, [r8 + 192] # m2y
    addsd xmm0, [r8 + 16] # m4
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8] # m1
    addsd xmm1, [r8 + 200] # m3y
    addsd xmm1, [r8 + 24] # m5
    # t = ((qx-sx)*dx + (qy-sy)*dy) / len2, clamped
    subsd xmm0, [r8 + 32] # sx
    mulsd xmm0, [r8 + 48] # dx
    subsd xmm1, [r8 + 40] # sy
    mulsd xmm1, [r8 + 56] # dy
    addsd xmm0, xmm1
    divsd xmm0, [r8 + 64] # len2
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm9, xmm0 # t
    # sa = clamp01(a_lerp * aAlpha) * cov
    movsd xmm0, [r8 + 120] # a0
    movsd xmm1, [r8 + 128] # da
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, [r8 + 136] # aAlpha
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, [r11] # cov
    movsd xmm10, xmm0 # sa
    # R/G/B lerps, clamped like the scalar generic path
    movsd xmm0, [r8 + 72] # r0
    movsd xmm1, [r8 + 80] # dr
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm1, [r8 + 88] # g0
    movsd xmm2, [r8 + 96] # dg
    mulsd xmm2, xmm9
    addsd xmm1, xmm2
    maxpd xmm1, xmm5
    minpd xmm1, xmm6
    movsd xmm2, [r8 + 104] # b0
    movsd xmm3, [r8 + 112] # db
    mulsd xmm3, xmm9
    addsd xmm2, xmm3
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_x64
  dynasm a:
    arch x64
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 160
    ret()
  a.finalize()

proc buildLinearRowAarch64*(): ExecutableBuffer =
  ## Same algorithm for AArch64 (d16-23 hoist consts + loop-carried;
  ## paint streams from ctx). Assemble-verified only until an ARM
  ## hardware run signs off execution; the backend stays amd64-gated.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0 # dst cursor
    mov x10, x1 # cov cursor
    mov x11, x2 # count
    mov x12, x3 # ctx
    cbz x11, fwd("done")
    ldr d16, [x12, 144] # c255
    ldr d17, [x12, 160] # zero
    ldr d18, [x12, 168] # one
    ldr d19, [x12, 152] # half
    ldr x13, [x12, 176] # divtab
    ldr d20, [x12, 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0] # m0
    fmul d0, d20, d1
    ldr d1, [x12, 192] # m2y
    fadd d0, d0, d1
    ldr d1, [x12, 16] # m4
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8] # m1
    fmul d2, d20, d1
    ldr d1, [x12, 200] # m3y
    fadd d2, d2, d1
    ldr d1, [x12, 24] # m5
    fadd d2, d2, d1
    # t
    ldr d1, [x12, 32] # sx
    fsub d0, d0, d1
    ldr d1, [x12, 48] # dx
    fmul d0, d0, d1
    ldr d1, [x12, 40] # sy
    fsub d2, d2, d1
    ldr d1, [x12, 56] # dy
    fmul d2, d2, d1
    fadd d0, d0, d2
    ldr d1, [x12, 64] # len2
    fdiv d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmov d21, d0 # t
    # sa_c
    ldr d0, [x12, 120] # a0
    ldr d1, [x12, 128] # da
    fmul d1, d1, d21
    fadd d0, d0, d1
    ldr d1, [x12, 136] # aAlpha
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x10] # cov
    fmul d0, d0, d1
    fmov d22, d0 # sa_c
    fsub d23, d18, d22 # inv
    # R
    ldr d0, [x12, 72] # r0
    ldr d1, [x12, 80] # dr
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9]
    # G
    ldr d0, [x12, 88]
    ldr d1, [x12, 96]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9, 1]
    # B
    ldr d0, [x12, 104]
    ldr d1, [x12, 112]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9, 2]
    # A
    ldrb w4, [x9, 3]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d1, d1, d22
    fmax d1, d1, d17
    fmin d1, d1, d18
    fmul d1, d1, d16
    fadd d1, d1, d19
    fcvtzs w4, d1
    strb w4, [x9, 3]
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    ret()
  a.finalize()

proc buildLinearRowGenAarch64*(op: static CompOp): ExecutableBuffer =
  ## Linear head with the generic-op tail (`blend_a64`, same contract
  ## as x64). Assemble-verified only, like the kernel above.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0
    mov x10, x1
    mov x11, x2
    mov x12, x3
    cbz x11, fwd("done")
    sub sp, sp, 64
    movz x4, 0xED8D
    movk x4, 0x0B5E, lsl, 16
    movk x4, 0xC6F7, lsl, 32
    movk x4, 0x3EB0, lsl, 48
    fmov d25, x4 # 1e-6 threshold
    ldr d16, [x12, 144] # c255
    ldr d17, [x12, 160] # zero
    ldr d18, [x12, 168] # one
    ldr d19, [x12, 152] # half
    ldr x13, [x12, 176] # divtab
    ldr d20, [x12, 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0]
    fmul d0, d20, d1
    ldr d1, [x12, 192]
    fadd d0, d0, d1
    ldr d1, [x12, 16]
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8]
    fmul d2, d20, d1
    ldr d1, [x12, 200]
    fadd d2, d2, d1
    ldr d1, [x12, 24]
    fadd d2, d2, d1
    # t
    ldr d1, [x12, 32]
    fsub d0, d0, d1
    ldr d1, [x12, 48]
    fmul d0, d0, d1
    ldr d1, [x12, 40]
    fsub d2, d2, d1
    ldr d1, [x12, 56]
    fmul d2, d2, d1
    fadd d0, d0, d2
    ldr d1, [x12, 64]
    fdiv d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmov d21, d0 # t
    # sa -> d22
    ldr d0, [x12, 120]
    ldr d1, [x12, 128]
    fmul d1, d1, d21
    fadd d0, d0, d1
    ldr d1, [x12, 136]
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x10]
    fmul d22, d0, d1
    # R/G/B lerps, clamped
    ldr d0, [x12, 72]
    ldr d1, [x12, 80]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x12, 88]
    ldr d2, [x12, 96]
    fmul d2, d2, d21
    fadd d1, d1, d2
    fmax d1, d1, d17
    fmin d1, d1, d18
    ldr d2, [x12, 104]
    ldr d3, [x12, 112]
    fmul d3, d3, d21
    fadd d2, d2, d3
    fmax d2, d2, d17
    fmin d2, d2, d18
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_a64
  dynasm a:
    arch aarch64
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    add sp, sp, 64
    ret()
  a.finalize()

proc buildRadialRowX64*(): ExecutableBuffer =
  ## Radial-gradient source-over row kernel, same ABI as solid/linear.
  ## Per-pixel op order replicates `paint.sample` (radial branch) +
  ## `blendPixel`: `qx/qy` exactly as in the linear kernel, then
  ## `dx = qx-cx`, `dy = qy-cy`, `dist = sqrt(dx*dx+dy*dy)` via
  ## `sqrtsd`, `t = (dist-inr)/f` via `divsd`, clamped; lerp + blend
  ## identical to linear from there on.
  ## Registers: same map as linear (xmm4-7 consts, xmm8-11
  ## x/t/sa_c/inv, xmm0-3 work). Single-pixel loop (see solid note).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 96
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    mov r9, [r8 + 176] # divtab
    movsd xmm4, [r8 + 144] # c255
    movsd xmm5, [r8 + 160] # zero
    movsd xmm6, [r8 + 168] # one
    movsd xmm7, [r8 + 152] # half
    cmp rax, 0
    jle fwd("done")
    movsd xmm8, [r8 + 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0] # m0
    addsd xmm0, [r8 + 192] # m2y
    addsd xmm0, [r8 + 16] # m4
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8] # m1
    addsd xmm1, [r8 + 200] # m3y
    addsd xmm1, [r8 + 24] # m5
    # dist = sqrt((qx-cx)^2 + (qy-cy)^2)
    subsd xmm0, [r8 + 32] # cx
    subsd xmm1, [r8 + 40] # cy
    movsd xmm2, xmm0
    mulsd xmm2, xmm2
    movsd xmm3, xmm1
    mulsd xmm3, xmm3
    addsd xmm2, xmm3
    sqrtsd xmm2, xmm2
    # t = (dist-inr)/f, clamped
    subsd xmm2, [r8 + 48] # inr
    divsd xmm2, [r8 + 56] # f
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    movsd xmm9, xmm2 # t
    # sa_c = clamp01(a_lerp * aAlpha) * cov; inv = 1 - sa_c
    movsd xmm0, [r8 + 120] # a0
    movsd xmm1, [r8 + 128] # da
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, [r8 + 136] # aAlpha
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, [r11] # cov
    movsd xmm10, xmm0 # sa_c
    movsd xmm11, xmm6 # one
    subsd xmm11, xmm10 # inv
    # R
    movsd xmm0, [r8 + 72] # r0
    movsd xmm1, [r8 + 80] # dr
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10], dl
    # G
    movsd xmm0, [r8 + 88] # g0
    movsd xmm1, [r8 + 96] # dg
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10 + 1]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 1], dl
    # B
    movsd xmm0, [r8 + 104] # b0
    movsd xmm1, [r8 + 112] # db
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10 + 2]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 2], dl
    # A: sa_c + da*inv
    movzx edx, byte [r10 + 3]
    movsd xmm0, [r9 + rdx*8]
    mulsd xmm0, xmm11
    addsd xmm0, xmm10
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 3], dl
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 96
    ret()
  a.finalize()

proc buildRadialRowGenX64*(op: static CompOp): ExecutableBuffer =
  ## Radial-gradient head with the generic-op blend tail (entry
  ## contract in `blend_x64`). `sqrtsd`/`divsd` mirror the scalar;
  ## channels clamp and clearing ops run.
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 160
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    movabs rcx, 0x3EB0C6F7A0B5ED8D # 1e-6 bits (ao threshold)
    mov qword [rsp + 152], rcx
    mov r9, [r8 + 176] # divtab
    movsd xmm4, [r8 + 144] # c255
    movsd xmm5, [r8 + 160] # zero
    movsd xmm6, [r8 + 168] # one
    movsd xmm7, [r8 + 152] # half
    cmp rax, 0
    jle fwd("done")
    movsd xmm8, [r8 + 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0]
    addsd xmm0, [r8 + 192]
    addsd xmm0, [r8 + 16]
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8]
    addsd xmm1, [r8 + 200]
    addsd xmm1, [r8 + 24]
    # dist = sqrt((qx-cx)^2 + (qy-cy)^2)
    subsd xmm0, [r8 + 32] # cx
    subsd xmm1, [r8 + 40] # cy
    movsd xmm2, xmm0
    mulsd xmm2, xmm2
    movsd xmm3, xmm1
    mulsd xmm3, xmm3
    addsd xmm2, xmm3
    sqrtsd xmm2, xmm2
    # t = (dist-inr)/f, clamped
    subsd xmm2, [r8 + 48] # inr
    divsd xmm2, [r8 + 56] # f
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    movsd xmm9, xmm2 # t
    # sa = clamp01(a_lerp * aAlpha) * cov
    movsd xmm0, [r8 + 120] # a0
    movsd xmm1, [r8 + 128] # da
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, [r8 + 136] # aAlpha
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, [r11]
    movsd xmm10, xmm0 # sa
    movsd xmm0, [r8 + 72] # r0
    movsd xmm1, [r8 + 80] # dr
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm1, [r8 + 88]
    movsd xmm2, [r8 + 96]
    mulsd xmm2, xmm9
    addsd xmm1, xmm2
    maxpd xmm1, xmm5
    minpd xmm1, xmm6
    movsd xmm2, [r8 + 104]
    movsd xmm3, [r8 + 112]
    mulsd xmm3, xmm9
    addsd xmm2, xmm3
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_x64
  dynasm a:
    arch x64
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 160
    ret()
  a.finalize()

proc buildRadialRowAarch64*(): ExecutableBuffer =
  ## Same algorithm for AArch64 (`fsqrt` for the distance).
  ## Assemble-verified only; the backend stays amd64-gated.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0 # dst cursor
    mov x10, x1 # cov cursor
    mov x11, x2 # count
    mov x12, x3 # ctx
    cbz x11, fwd("done")
    ldr d16, [x12, 144] # c255
    ldr d17, [x12, 160] # zero
    ldr d18, [x12, 168] # one
    ldr d19, [x12, 152] # half
    ldr x13, [x12, 176] # divtab
    ldr d20, [x12, 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0] # m0
    fmul d0, d20, d1
    ldr d1, [x12, 192] # m2y
    fadd d0, d0, d1
    ldr d1, [x12, 16] # m4
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8] # m1
    fmul d2, d20, d1
    ldr d1, [x12, 200] # m3y
    fadd d2, d2, d1
    ldr d1, [x12, 24] # m5
    fadd d2, d2, d1
    # dist = sqrt((qx-cx)^2 + (qy-cy)^2)
    ldr d1, [x12, 32] # cx
    fsub d0, d0, d1
    ldr d1, [x12, 40] # cy
    fsub d2, d2, d1
    fmul d0, d0, d0
    fmul d3, d2, d2
    fadd d0, d0, d3
    fsqrt d0, d0
    # t = (dist-inr)/f
    ldr d1, [x12, 48] # inr
    fsub d0, d0, d1
    ldr d1, [x12, 56] # f
    fdiv d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmov d21, d0 # t
    # sa_c
    ldr d0, [x12, 120] # a0
    ldr d1, [x12, 128] # da
    fmul d1, d1, d21
    fadd d0, d0, d1
    ldr d1, [x12, 136] # aAlpha
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x10] # cov
    fmul d0, d0, d1
    fmov d22, d0 # sa_c
    fsub d23, d18, d22 # inv
    # R
    ldr d0, [x12, 72] # r0
    ldr d1, [x12, 80] # dr
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9]
    # G
    ldr d0, [x12, 88]
    ldr d1, [x12, 96]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9, 1]
    # B
    ldr d0, [x12, 104]
    ldr d1, [x12, 112]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9, 2]
    # A
    ldrb w4, [x9, 3]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d1, d1, d22
    fmax d1, d1, d17
    fmin d1, d1, d18
    fmul d1, d1, d16
    fadd d1, d1, d19
    fcvtzs w4, d1
    strb w4, [x9, 3]
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    ret()
  a.finalize()

proc buildRadialRowGenAarch64*(op: static CompOp): ExecutableBuffer =
  ## Radial head with the generic-op tail (`blend_a64`, same contract
  ## as x64). Assemble-verified only, like the kernel above.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0
    mov x10, x1
    mov x11, x2
    mov x12, x3
    cbz x11, fwd("done")
    sub sp, sp, 64
    movz x4, 0xED8D
    movk x4, 0x0B5E, lsl, 16
    movk x4, 0xC6F7, lsl, 32
    movk x4, 0x3EB0, lsl, 48
    fmov d25, x4 # 1e-6 threshold
    ldr d16, [x12, 144] # c255
    ldr d17, [x12, 160] # zero
    ldr d18, [x12, 168] # one
    ldr d19, [x12, 152] # half
    ldr x13, [x12, 176] # divtab
    ldr d20, [x12, 184] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0]
    fmul d0, d20, d1
    ldr d1, [x12, 192]
    fadd d0, d0, d1
    ldr d1, [x12, 16]
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8]
    fmul d2, d20, d1
    ldr d1, [x12, 200]
    fadd d2, d2, d1
    ldr d1, [x12, 24]
    fadd d2, d2, d1
    # dist = sqrt((qx-cx)^2 + (qy-cy)^2)
    ldr d1, [x12, 32]
    fsub d0, d0, d1
    ldr d1, [x12, 40]
    fsub d2, d2, d1
    fmul d0, d0, d0
    fmul d3, d2, d2
    fadd d0, d0, d3
    fsqrt d0, d0
    # t = (dist-inr)/f
    ldr d1, [x12, 48]
    fsub d0, d0, d1
    ldr d1, [x12, 56]
    fdiv d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmov d21, d0 # t
    # sa -> d22
    ldr d0, [x12, 120]
    ldr d1, [x12, 128]
    fmul d1, d1, d21
    fadd d0, d0, d1
    ldr d1, [x12, 136]
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x10]
    fmul d22, d0, d1
    # R/G/B lerps, clamped
    ldr d0, [x12, 72]
    ldr d1, [x12, 80]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x12, 88]
    ldr d2, [x12, 96]
    fmul d2, d2, d21
    fadd d1, d1, d2
    fmax d1, d1, d17
    fmin d1, d1, d18
    ldr d2, [x12, 104]
    ldr d3, [x12, 112]
    fmul d3, d3, d21
    fadd d2, d2, d3
    fmax d2, d2, d17
    fmin d2, d2, d18
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_a64
  dynasm a:
    arch aarch64
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    add sp, sp, 64
    ret()
  a.finalize()

proc buildBoxRowX64*(): ExecutableBuffer =
  ## Box-gradient source-over row kernel, same ABI as the other row
  ## kernels (note `BoxCtx` offsets differ: paint starts at 80, consts
  ## at 152, `divtab` at 184, `rowX` at 192). Per-pixel op order
  ## replicates `paint.sample` (box branch) + `blendPixel`: `qx/qy` as
  ## in the linear kernel, `px = qx-cx`, `py = qy-cy`, `|.|` via
  ## `0-x` + `maxpd` (sweep-proven over `sdRoundBox`), `qx = |px|-exr`
  ## with the baked `ex-r`, then `min(max(qx,qy),0) +
  ## sqrt(max(qx,0)^2+max(qy,0)^2) - r`, `t = (sd+f*0.5)/f` via
  ## `divsd`, clamped; lerp + blend identical from there on.
  ## Registers: same map as linear (xmm4-7 consts, xmm8-11
  ## x/t/sa_c/inv, xmm0-2 work). Single-pixel loop (see solid note).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 96
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    mov r9, [r8 + 184] # divtab
    movsd xmm4, [r8 + 152] # c255
    movsd xmm5, [r8 + 168] # zero
    movsd xmm6, [r8 + 176] # one
    movsd xmm7, [r8 + 160] # half
    cmp rax, 0
    jle fwd("done")
    movsd xmm8, [r8 + 192] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0] # m0
    addsd xmm0, [r8 + 200] # m2y
    addsd xmm0, [r8 + 16] # m4
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8] # m1
    addsd xmm1, [r8 + 208] # m3y
    addsd xmm1, [r8 + 24] # m5
    # px = qx-cx, py = qy-cy, then |.| via max(x, 0-x)
    subsd xmm0, [r8 + 32] # cx
    subsd xmm1, [r8 + 40] # cy
    movsd xmm2, xmm5
    subsd xmm2, xmm0 # -px
    maxpd xmm0, xmm2 # |px|
    movsd xmm2, xmm5
    subsd xmm2, xmm1 # -py
    maxpd xmm1, xmm2 # |py|
    # qx = |px|-exr, qy = |py|-eyr
    subsd xmm0, [r8 + 48] # exr
    subsd xmm1, [r8 + 56] # eyr
    # d1 = min(max(qx,qy),0)
    movsd xmm2, xmm0
    maxpd xmm2, xmm1
    minpd xmm2, xmm5
    # sd = d1 + sqrt(max(qx,0)^2+max(qy,0)^2) - r
    maxpd xmm0, xmm5
    mulsd xmm0, xmm0
    maxpd xmm1, xmm5
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    addsd xmm2, xmm0
    subsd xmm2, [r8 + 64] # radius
    # t = (sd+f*0.5)/f, clamped
    movsd xmm0, [r8 + 72] # f
    mulsd xmm0, xmm7 # f*0.5
    addsd xmm0, xmm2 # fh+sd == sd+fh, exact
    divsd xmm0, [r8 + 72] # f
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm9, xmm0 # t
    # sa_c = clamp01(a_lerp * aAlpha) * cov; inv = 1 - sa_c
    movsd xmm0, [r8 + 128] # a0
    movsd xmm1, [r8 + 136] # da
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, [r8 + 144] # aAlpha
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, [r11] # cov
    movsd xmm10, xmm0 # sa_c
    movsd xmm11, xmm6 # one
    subsd xmm11, xmm10 # inv
    # R
    movsd xmm0, [r8 + 80] # r0
    movsd xmm1, [r8 + 88] # dr
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10], dl
    # G
    movsd xmm0, [r8 + 96] # g0
    movsd xmm1, [r8 + 104] # dg
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10 + 1]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 1], dl
    # B
    movsd xmm0, [r8 + 112] # b0
    movsd xmm1, [r8 + 120] # db
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, xmm10
    movzx edx, byte [r10 + 2]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, xmm11
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 2], dl
    # A: sa_c + da*inv
    movzx edx, byte [r10 + 3]
    movsd xmm0, [r9 + rdx*8]
    mulsd xmm0, xmm11
    addsd xmm0, xmm10
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 3], dl
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 96
    ret()
  a.finalize()

proc buildBoxRowGenX64*(op: static CompOp): ExecutableBuffer =
  ## Box-gradient head with the generic-op blend tail (entry contract
  ## in `blend_x64`). `abs`/`min`/`max` replicate via sub+maxpd like the
  ## sourceOver kernel; channels clamp and clearing ops run.
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    mov r10, dst
    mov r11, cov
    mov rax, nn
    mov r8, ctx
    sub rsp, 160
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    movabs rcx, 0x3EB0C6F7A0B5ED8D # 1e-6 bits (ao threshold)
    mov qword [rsp + 152], rcx
    mov r9, [r8 + 184] # divtab
    movsd xmm4, [r8 + 152] # c255
    movsd xmm5, [r8 + 168] # zero
    movsd xmm6, [r8 + 176] # one
    movsd xmm7, [r8 + 160] # half
    cmp rax, 0
    jle fwd("done")
    movsd xmm8, [r8 + 192] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0]
    addsd xmm0, [r8 + 200]
    addsd xmm0, [r8 + 16]
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8]
    addsd xmm1, [r8 + 208]
    addsd xmm1, [r8 + 24]
    # |px|, |py| via max(x, 0-x)
    subsd xmm0, [r8 + 32] # cx
    subsd xmm1, [r8 + 40] # cy
    movsd xmm2, xmm5
    subsd xmm2, xmm0
    maxpd xmm0, xmm2
    movsd xmm2, xmm5
    subsd xmm2, xmm1
    maxpd xmm1, xmm2
    subsd xmm0, [r8 + 48] # exr
    subsd xmm1, [r8 + 56] # eyr
    movsd xmm2, xmm0
    maxpd xmm2, xmm1
    minpd xmm2, xmm5 # d1w
    maxpd xmm0, xmm5
    mulsd xmm0, xmm0
    maxpd xmm1, xmm5
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    addsd xmm2, xmm0
    subsd xmm2, [r8 + 64] # radius -> sd
    movsd xmm0, [r8 + 72] # f
    mulsd xmm0, xmm7 # f*0.5
    addsd xmm0, xmm2
    divsd xmm0, [r8 + 72]
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm9, xmm0 # t
    # sa = clamp01(a_lerp * aAlpha) * cov
    movsd xmm0, [r8 + 128] # a0
    movsd xmm1, [r8 + 136] # da
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    mulsd xmm0, [r8 + 144] # aAlpha
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, [r11]
    movsd xmm10, xmm0 # sa
    movsd xmm0, [r8 + 80] # r0
    movsd xmm1, [r8 + 88] # dr
    mulsd xmm1, xmm9
    addsd xmm0, xmm1
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movsd xmm1, [r8 + 96]
    movsd xmm2, [r8 + 104]
    mulsd xmm2, xmm9
    addsd xmm1, xmm2
    maxpd xmm1, xmm5
    minpd xmm1, xmm6
    movsd xmm2, [r8 + 112]
    movsd xmm3, [r8 + 120]
    mulsd xmm3, xmm9
    addsd xmm2, xmm3
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_x64
  dynasm a:
    arch x64
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    sub rax, 1
    cmp rax, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 160
    ret()
  a.finalize()

proc buildBoxRowAarch64*(): ExecutableBuffer =
  ## Same algorithm for AArch64 (`|.|` via `0-x` + `fmax`, mirroring
  ## x64). Assemble-verified only; the backend stays amd64-gated.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0 # dst cursor
    mov x10, x1 # cov cursor
    mov x11, x2 # count
    mov x12, x3 # ctx
    cbz x11, fwd("done")
    ldr d16, [x12, 152] # c255
    ldr d17, [x12, 168] # zero
    ldr d18, [x12, 176] # one
    ldr d19, [x12, 160] # half
    ldr x13, [x12, 184] # divtab
    ldr d20, [x12, 192] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0] # m0
    fmul d0, d20, d1
    ldr d1, [x12, 200] # m2y
    fadd d0, d0, d1
    ldr d1, [x12, 16] # m4
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8] # m1
    fmul d2, d20, d1
    ldr d1, [x12, 208] # m3y
    fadd d2, d2, d1
    ldr d1, [x12, 24] # m5
    fadd d2, d2, d1
    # px/py then |.| via max(x, 0-x)
    ldr d1, [x12, 32] # cx
    fsub d0, d0, d1
    ldr d1, [x12, 40] # cy
    fsub d2, d2, d1
    fsub d1, d17, d0
    fmax d0, d0, d1
    fsub d1, d17, d2
    fmax d2, d2, d1
    # qx/qy minus exr/eyr
    ldr d1, [x12, 48] # exr
    fsub d0, d0, d1
    ldr d1, [x12, 56] # eyr
    fsub d2, d2, d1
    # d1w = min(max(qx,qy),0)
    fmax d1, d0, d2
    fmin d1, d1, d17
    # sd = d1w + sqrt(max(qx,0)^2+max(qy,0)^2) - r
    fmax d0, d0, d17
    fmul d0, d0, d0
    fmax d2, d2, d17
    fmul d2, d2, d2
    fadd d0, d0, d2
    fsqrt d0, d0
    fadd d1, d1, d0
    ldr d0, [x12, 64] # radius
    fsub d1, d1, d0
    # t = (sd+f*0.5)/f
    ldr d0, [x12, 72] # f
    fmul d0, d0, d19
    fadd d0, d0, d1
    ldr d1, [x12, 72] # f
    fdiv d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmov d21, d0 # t
    # sa_c
    ldr d0, [x12, 128] # a0
    ldr d1, [x12, 136] # da
    fmul d1, d1, d21
    fadd d0, d0, d1
    ldr d1, [x12, 144] # aAlpha
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x10] # cov
    fmul d0, d0, d1
    fmov d22, d0 # sa_c
    fsub d23, d18, d22 # inv
    # R
    ldr d0, [x12, 80] # r0
    ldr d1, [x12, 88] # dr
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9]
    # G
    ldr d0, [x12, 96]
    ldr d1, [x12, 104]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9, 1]
    # B
    ldr d0, [x12, 112]
    ldr d1, [x12, 120]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmul d0, d0, d22
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9, 2]
    # A
    ldrb w4, [x9, 3]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d23
    fadd d1, d1, d22
    fmax d1, d1, d17
    fmin d1, d1, d18
    fmul d1, d1, d16
    fadd d1, d1, d19
    fcvtzs w4, d1
    strb w4, [x9, 3]
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    ret()
  a.finalize()

proc buildBoxRowGenAarch64*(op: static CompOp): ExecutableBuffer =
  ## Box head with the generic-op tail (`blend_a64`, same contract as
  ## x64). Assemble-verified only, like the kernel above.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0
    mov x10, x1
    mov x11, x2
    mov x12, x3
    cbz x11, fwd("done")
    sub sp, sp, 64
    movz x4, 0xED8D
    movk x4, 0x0B5E, lsl, 16
    movk x4, 0xC6F7, lsl, 32
    movk x4, 0x3EB0, lsl, 48
    fmov d25, x4 # 1e-6 threshold
    ldr d16, [x12, 152] # c255
    ldr d17, [x12, 168] # zero
    ldr d18, [x12, 176] # one
    ldr d19, [x12, 160] # half
    ldr x13, [x12, 184] # divtab
    ldr d20, [x12, 192] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0]
    fmul d0, d20, d1
    ldr d1, [x12, 200]
    fadd d0, d0, d1
    ldr d1, [x12, 16]
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8]
    fmul d2, d20, d1
    ldr d1, [x12, 208]
    fadd d2, d2, d1
    ldr d1, [x12, 24]
    fadd d2, d2, d1
    # |px|, |py| via max(x, 0-x)
    ldr d1, [x12, 32]
    fsub d0, d0, d1
    ldr d1, [x12, 40]
    fsub d2, d2, d1
    fsub d1, d17, d0
    fmax d0, d0, d1
    fsub d1, d17, d2
    fmax d2, d2, d1
    ldr d1, [x12, 48] # exr
    fsub d0, d0, d1
    ldr d1, [x12, 56] # eyr
    fsub d2, d2, d1
    fmax d1, d0, d2
    fmin d1, d1, d17 # d1w
    fmax d0, d0, d17
    fmul d0, d0, d0
    fmax d2, d2, d17
    fmul d2, d2, d2
    fadd d0, d0, d2
    fsqrt d0, d0
    fadd d1, d1, d0
    ldr d0, [x12, 64] # radius
    fsub d1, d1, d0 # sd
    ldr d0, [x12, 72] # f
    fmul d0, d0, d19
    fadd d0, d0, d1
    ldr d1, [x12, 72]
    fdiv d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmov d21, d0 # t
    # sa -> d22
    ldr d0, [x12, 128]
    ldr d1, [x12, 136]
    fmul d1, d1, d21
    fadd d0, d0, d1
    ldr d1, [x12, 144]
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x10]
    fmul d22, d0, d1
    # R/G/B lerps, clamped
    ldr d0, [x12, 80]
    ldr d1, [x12, 88]
    fmul d1, d1, d21
    fadd d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldr d1, [x12, 96]
    ldr d2, [x12, 104]
    fmul d2, d2, d21
    fadd d1, d1, d2
    fmax d1, d1, d17
    fmin d1, d1, d18
    ldr d2, [x12, 112]
    ldr d3, [x12, 120]
    fmul d3, d3, d21
    fadd d2, d2, d3
    fmax d2, d2, d17
    fmin d2, d2, d18
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_a64
  dynasm a:
    arch aarch64
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    add sp, sp, 64
    ret()
  a.finalize()

proc buildPatternRowX64*(): ExecutableBuffer =
  ## Nearest-pattern source-over row kernel, same ABI as the other row
  ## kernels (`PatternCtx` offsets: paint params at 32..120, consts at
  ## 128..160, pointers at 168..176, int fields at 184..216, per-row at
  ## 224..240). Per-pixel op order replicates `paint.sample` (pattern
  ## branch, nearest) + `sampleImage` + `blendPixel`: `qx/qy` as in the
  ## gradient kernels, `u = (ca*dx+sn*dy)/ex`, `v = (ca*dy-sn*dx)/ey`
  ## via `divsd` (the addends commute exactly, so the subtraction form
  ## matches), flip-tested `v`, trunc+adjust floor (saturation-safe, see
  ## `spike_pattern_idx.nim`), `idiv` repeat-wrap with bounded cmp-sub
  ## for the outer mod, cmp clamp, texel bytes through the div-table,
  ## tint muls, then the standard blend. Bilinear paints never reach
  ## this kernel (backend gates on `ifNearest`).
  ## Registers: xmm4-7 = c255/zero/one/half, xmm8 = x, xmm9 = u,
  ## xmm10/11 = sa_c/inv (all saved); xmm0-3 = work. GP: r10/r11 =
  ## dst/cov cursors, rbx = count (idiv-safe), r12 = xi, r8 = ctx,
  ## r9 = divtab; rax/rcx/rdx = index temps.
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    push rbx
    push r12
    mov r10, dst
    mov r11, cov
    mov rbx, nn
    mov r8, ctx
    sub rsp, 96
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    mov r9, [r8 + 168] # divtab
    movsd xmm4, [r8 + 136] # c255
    movsd xmm5, [r8 + 152] # zero
    movsd xmm6, [r8 + 160] # one
    movsd xmm7, [r8 + 144] # half
    cmp rbx, 0
    jle fwd("done")
    movsd xmm8, [r8 + 224] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0] # m0
    addsd xmm0, [r8 + 232] # m2y
    addsd xmm0, [r8 + 16] # m4
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8] # m1
    addsd xmm1, [r8 + 240] # m3y
    addsd xmm1, [r8 + 24] # m5
    # dx, dy
    subsd xmm0, [r8 + 32] # ox
    subsd xmm1, [r8 + 40] # oy
    # u = (ca*dx + sn*dy)/ex
    movsd xmm2, [r8 + 64] # ca
    mulsd xmm2, xmm0
    movsd xmm3, [r8 + 72] # sn
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    divsd xmm2, [r8 + 48] # ex
    movsd xmm9, xmm2 # u
    # v = (ca*dy - sn*dx)/ey
    movsd xmm2, [r8 + 72] # sn
    mulsd xmm2, xmm0 # sn*dx
    movsd xmm3, [r8 + 64] # ca
    mulsd xmm3, xmm1 # ca*dy
    subsd xmm3, xmm2
    divsd xmm3, [r8 + 56] # ey
    movsd xmm2, xmm3 # v
    # flipY?
    mov rcx, [r8 + 200] # flip
    cmp rcx, 0
    jz fwd("noflip")
    movsd xmm3, xmm6 # one
    subsd xmm3, xmm2
    movsd xmm2, xmm3 # 1.0 - v
    label noflip
    # xi = wrap(floor(u*wF))
    mulsd xmm9, [r8 + 80] # wF
    cvttsd2si rdx, xmm9
    mov rcx, rdx
    add rcx, rcx
    jnz fwd("xadj")
    test rdx, rdx
    jnz fwd("xkeep") # INT64_MIN: saturated, keep
    label xadj
    cvtsi2sd xmm3, rdx
    ucomisd xmm3, xmm9
    jbe fwd("xkeep")
    dec rdx
    label xkeep
    mov rcx, [r8 + 208] # repX
    cmp rcx, 0
    jz fwd("xclamp")
    mov rax, rdx
    mov rcx, [r8 + 184] # imgW
    cqo
    idiv rcx
    add rdx, rcx
    cmp rdx, rcx
    jl fwd("xstore")
    sub rdx, rcx
    jmp fwd("xstore")
    label xclamp
    cmp rdx, 0
    jge fwd("xhi")
    `xor` edx, edx
    jmp fwd("xstore")
    label xhi
    mov rcx, [r8 + 184]
    dec rcx
    cmp rdx, rcx
    jle fwd("xstore")
    mov rdx, rcx
    label xstore
    mov r12, rdx # xi
    # yi = wrap(floor(v*hF))
    mulsd xmm2, [r8 + 88] # hF
    cvttsd2si rdx, xmm2
    mov rcx, rdx
    add rcx, rcx
    jnz fwd("yadj")
    test rdx, rdx
    jnz fwd("ykeep")
    label yadj
    cvtsi2sd xmm3, rdx
    ucomisd xmm3, xmm2
    jbe fwd("ykeep")
    dec rdx
    label ykeep
    mov rcx, [r8 + 216] # repY
    cmp rcx, 0
    jz fwd("yclamp")
    mov rax, rdx
    mov rcx, [r8 + 192] # imgH
    cqo
    idiv rcx
    add rdx, rcx
    cmp rdx, rcx
    jl fwd("ystore")
    sub rdx, rcx
    jmp fwd("ystore")
    label yclamp
    cmp rdx, 0
    jge fwd("yhi")
    `xor` edx, edx
    jmp fwd("ystore")
    label yhi
    mov rcx, [r8 + 192]
    dec rcx
    cmp rdx, rcx
    jle fwd("ystore")
    mov rdx, rcx
    label ystore
    # texel addr = imgPx + (yi*imgW + xi)*4
    mov rcx, [r8 + 184] # imgW
    imul rdx, rcx # yi*w
    add rdx, r12 # +xi
    mov rcx, [r8 + 176] # imgPx
    lea rcx, [rcx + rdx*4]
    # texel bytes -> f64, tinted
    movzx edx, byte [rcx]
    movsd xmm0, [r9 + rdx*8]
    mulsd xmm0, [r8 + 96] # tintR -> cr
    movzx edx, byte [rcx + 1]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, [r8 + 104] # tintG -> cg
    movzx edx, byte [rcx + 2]
    movsd xmm2, [r9 + rdx*8]
    mulsd xmm2, [r8 + 112] # tintB -> cb
    movzx edx, byte [rcx + 3]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, [r8 + 120] # tintA
    mulsd xmm3, [r8 + 128] # aAlpha -> aS
    maxpd xmm3, xmm5
    minpd xmm3, xmm6
    mulsd xmm3, [r11] # cov -> sa_c
    movsd xmm10, xmm3 # sa_c
    movsd xmm11, xmm6 # one
    subsd xmm11, xmm10 # inv
    # R
    mulsd xmm0, xmm10
    movzx edx, byte [r10]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, xmm11
    addsd xmm0, xmm3
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10], dl
    # G
    mulsd xmm1, xmm10
    movzx edx, byte [r10 + 1]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, xmm11
    addsd xmm1, xmm3
    maxpd xmm1, xmm5
    minpd xmm1, xmm6
    mulsd xmm1, xmm4
    addsd xmm1, xmm7
    cvttsd2si edx, xmm1
    mov byte [r10 + 1], dl
    # B
    mulsd xmm2, xmm10
    movzx edx, byte [r10 + 2]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, xmm11
    addsd xmm2, xmm3
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    mulsd xmm2, xmm4
    addsd xmm2, xmm7
    cvttsd2si edx, xmm2
    mov byte [r10 + 2], dl
    # A: sa_c + da*inv
    movzx edx, byte [r10 + 3]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, xmm11
    addsd xmm3, xmm10
    maxpd xmm3, xmm5
    minpd xmm3, xmm6
    mulsd xmm3, xmm4
    addsd xmm3, xmm7
    cvttsd2si edx, xmm3
    mov byte [r10 + 3], dl
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    dec rbx
    cmp rbx, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 96
    pop r12
    pop rbx
    ret()
  a.finalize()

proc buildPatternRowGenX64*(op: static CompOp): ExecutableBuffer =
  ## Nearest-pattern head with the generic-op blend tail (entry
  ## contract in `blend_x64`). Index math mirrors `sampleImage` exactly
  ## like the sourceOver kernel; texel channels clamp and clearing ops
  ## run (no transparent early-out).
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias cov, rsi, rdx
    alias nn, rdx, r8
    alias ctx, rcx, r9
    push rbx
    push r12
    mov r10, dst
    mov r11, cov
    mov rbx, nn
    mov r8, ctx
    sub rsp, 160
    movupd [rsp], xmm6
    movupd [rsp + 16], xmm7
    movupd [rsp + 32], xmm8
    movupd [rsp + 48], xmm9
    movupd [rsp + 64], xmm10
    movupd [rsp + 80], xmm11
    movabs rcx, 0x3EB0C6F7A0B5ED8D # 1e-6 bits (ao threshold)
    mov qword [rsp + 152], rcx
    mov r9, [r8 + 168] # divtab
    movsd xmm4, [r8 + 136] # c255
    movsd xmm5, [r8 + 152] # zero
    movsd xmm6, [r8 + 160] # one
    movsd xmm7, [r8 + 144] # half
    cmp rbx, 0
    jle fwd("done")
    movsd xmm8, [r8 + 224] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    movsd xmm0, xmm8
    mulsd xmm0, [r8 + 0]
    addsd xmm0, [r8 + 232]
    addsd xmm0, [r8 + 16]
    # qy = (m1*x + m3y) + m5
    movsd xmm1, xmm8
    mulsd xmm1, [r8 + 8]
    addsd xmm1, [r8 + 240]
    addsd xmm1, [r8 + 24]
    # dx, dy
    subsd xmm0, [r8 + 32] # ox
    subsd xmm1, [r8 + 40] # oy
    # u = (ca*dx + sn*dy)/ex
    movsd xmm2, [r8 + 64] # ca
    mulsd xmm2, xmm0
    movsd xmm3, [r8 + 72] # sn
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    divsd xmm2, [r8 + 48] # ex
    movsd xmm9, xmm2 # u
    # v = (ca*dy - sn*dx)/ey
    movsd xmm2, [r8 + 72]
    mulsd xmm2, xmm0
    movsd xmm3, [r8 + 64]
    mulsd xmm3, xmm1
    subsd xmm3, xmm2
    divsd xmm3, [r8 + 56] # ey
    movsd xmm2, xmm3 # v
    # flipY?
    mov rcx, [r8 + 200]
    cmp rcx, 0
    jz fwd("noflip")
    movsd xmm3, xmm6
    subsd xmm3, xmm2
    movsd xmm2, xmm3
    label noflip
    # xi = wrap(floor(u*wF))
    mulsd xmm9, [r8 + 80]
    cvttsd2si rdx, xmm9
    mov rcx, rdx
    add rcx, rcx
    jnz fwd("xadj")
    test rdx, rdx
    jnz fwd("xkeep")
    label xadj
    cvtsi2sd xmm3, rdx
    ucomisd xmm3, xmm9
    jbe fwd("xkeep")
    dec rdx
    label xkeep
    mov rcx, [r8 + 208] # repX
    cmp rcx, 0
    jz fwd("xclamp")
    mov rax, rdx
    mov rcx, [r8 + 184]
    cqo
    idiv rcx
    add rdx, rcx
    cmp rdx, rcx
    jl fwd("xstore")
    sub rdx, rcx
    jmp fwd("xstore")
    label xclamp
    cmp rdx, 0
    jge fwd("xhi")
    `xor` edx, edx
    jmp fwd("xstore")
    label xhi
    mov rcx, [r8 + 184]
    dec rcx
    cmp rdx, rcx
    jle fwd("xstore")
    mov rdx, rcx
    label xstore
    mov r12, rdx # xi
    # yi = wrap(floor(v*hF))
    mulsd xmm2, [r8 + 88] # hF
    cvttsd2si rdx, xmm2
    mov rcx, rdx
    add rcx, rcx
    jnz fwd("yadj")
    test rdx, rdx
    jnz fwd("ykeep")
    label yadj
    cvtsi2sd xmm3, rdx
    ucomisd xmm3, xmm2
    jbe fwd("ykeep")
    dec rdx
    label ykeep
    mov rcx, [r8 + 216] # repY
    cmp rcx, 0
    jz fwd("yclamp")
    mov rax, rdx
    mov rcx, [r8 + 192] # imgH
    cqo
    idiv rcx
    add rdx, rcx
    cmp rdx, rcx
    jl fwd("ystore")
    sub rdx, rcx
    jmp fwd("ystore")
    label yclamp
    cmp rdx, 0
    jge fwd("yhi")
    `xor` edx, edx
    jmp fwd("ystore")
    label yhi
    mov rcx, [r8 + 192]
    dec rcx
    cmp rdx, rcx
    jle fwd("ystore")
    mov rdx, rcx
    label ystore
    # texel addr = imgPx + (yi*imgW + xi)*4
    mov rcx, [r8 + 184] # imgW
    imul rdx, rcx # yi*w
    add rdx, r12 # +xi
    mov rcx, [r8 + 176] # imgPx
    lea rcx, [rcx + rdx*4]
    # texel bytes -> f64, tinted, clamped (generic path clamps rgb)
    movzx edx, byte [rcx]
    movsd xmm0, [r9 + rdx*8]
    mulsd xmm0, [r8 + 96] # tintR -> cr
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    movzx edx, byte [rcx + 1]
    movsd xmm1, [r9 + rdx*8]
    mulsd xmm1, [r8 + 104] # tintG -> cg
    maxpd xmm1, xmm5
    minpd xmm1, xmm6
    movzx edx, byte [rcx + 2]
    movsd xmm2, [r9 + rdx*8]
    mulsd xmm2, [r8 + 112] # tintB -> cb
    maxpd xmm2, xmm5
    minpd xmm2, xmm6
    movzx edx, byte [rcx + 3]
    movsd xmm3, [r9 + rdx*8]
    mulsd xmm3, [r8 + 120] # tintA
    mulsd xmm3, [r8 + 128] # aAlpha -> aS
    maxpd xmm3, xmm5
    minpd xmm3, xmm6
    mulsd xmm3, [r11] # cov -> sa (no early-out: clearing ops run)
    movsd xmm10, xmm3 # sa
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_x64
  dynasm a:
    arch x64
    addsd xmm8, xmm6 # x += 1.0
    add r10, 4
    add r11, 8
    dec rbx
    cmp rbx, 0
    jg bwd("row")
    label done
    movupd xmm6, [rsp]
    movupd xmm7, [rsp + 16]
    movupd xmm8, [rsp + 32]
    movupd xmm9, [rsp + 48]
    movupd xmm10, [rsp + 64]
    movupd xmm11, [rsp + 80]
    add rsp, 160
    pop r12
    pop rbx
    ret()
  a.finalize()

proc buildPatternRowAarch64*(): ExecutableBuffer =
  ## Same algorithm for AArch64 (`sdiv`+`msub` repeat-wrap, `fcvtzs`
  ## trunc-convert with the same saturation guard). Assemble-verified
  ## only; the backend stays amd64-gated.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0 # dst cursor
    mov x10, x1 # cov cursor
    mov x11, x2 # count
    mov x12, x3 # ctx
    cbz x11, fwd("done")
    ldr d16, [x12, 136] # c255
    ldr d17, [x12, 152] # zero
    ldr d18, [x12, 160] # one
    ldr d19, [x12, 144] # half
    ldr x13, [x12, 168] # divtab
    ldr d20, [x12, 224] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0] # m0
    fmul d0, d20, d1
    ldr d1, [x12, 232] # m2y
    fadd d0, d0, d1
    ldr d1, [x12, 16] # m4
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8] # m1
    fmul d2, d20, d1
    ldr d1, [x12, 240] # m3y
    fadd d2, d2, d1
    ldr d1, [x12, 24] # m5
    fadd d2, d2, d1
    # dx, dy
    ldr d1, [x12, 32] # ox
    fsub d0, d0, d1
    ldr d1, [x12, 40] # oy
    fsub d2, d2, d1
    # u = (ca*dx + sn*dy)/ex
    ldr d1, [x12, 64] # ca
    fmul d3, d1, d0
    ldr d1, [x12, 72] # sn
    fmul d4, d1, d2
    fadd d3, d3, d4
    ldr d1, [x12, 48] # ex
    fdiv d3, d3, d1
    fmov d21, d3 # u
    # v = (ca*dy - sn*dx)/ey
    ldr d1, [x12, 72] # sn
    fmul d3, d1, d0 # sn*dx
    ldr d1, [x12, 64] # ca
    fmul d4, d1, d2 # ca*dy
    fsub d4, d4, d3
    ldr d1, [x12, 56] # ey
    fdiv d4, d4, d1
    fmov d22, d4 # v (reuses sa_c slot; reloaded below)
    # flipY?
    ldr x4, [x12, 200] # flip
    cbz x4, fwd("noflip")
    fsub d22, d18, d22 # 1.0 - v
    label noflip
    # xi = wrap(floor(u*wF)): trunc+adjust in x4, repX/clamp
    ldr d1, [x12, 80] # wF
    fmul d1, d21, d1
    fcvtzs x4, d1 # trunc
    add x5, x4, x4
    cbnz x5, fwd("xadj")
    cbnz x4, fwd("xkeep") # INT64_MIN: saturated, keep
    label xadj
    scvtf d2, x4
    fcmp d2, d1
    b.le fwd("xkeep")
    sub x4, x4, 1
    label xkeep
    ldr x5, [x12, 208] # repX
    cbz x5, fwd("xclamp")
    ldr x5, [x12, 184] # imgW
    sdiv x6, x4, x5
    msub x4, x6, x5, x4 # x4 % imgW (truncated)
    add x4, x4, x5
    cmp x4, x5
    b.lt fwd("xstore")
    sub x4, x4, x5
    b fwd("xstore")
    label xclamp
    cmp x4, 0
    b.ge fwd("xhi")
    mov x4, 0
    b fwd("xstore")
    label xhi
    ldr x5, [x12, 184]
    sub x5, x5, 1
    cmp x4, x5
    b.le fwd("xstore")
    mov x4, x5
    label xstore
    # yi likewise into x6
    ldr d1, [x12, 88] # hF
    fmul d1, d22, d1
    fcvtzs x6, d1
    add x5, x6, x6
    cbnz x5, fwd("yadj")
    cbnz x6, fwd("ykeep")
    label yadj
    scvtf d2, x6
    fcmp d2, d1
    b.le fwd("ykeep")
    sub x6, x6, 1
    label ykeep
    ldr x5, [x12, 216] # repY
    cbz x5, fwd("yclamp")
    ldr x5, [x12, 192] # imgH
    sdiv x7, x6, x5
    msub x6, x7, x5, x6
    add x6, x6, x5
    cmp x6, x5
    b.lt fwd("ystore")
    sub x6, x6, x5
    b fwd("ystore")
    label yclamp
    cmp x6, 0
    b.ge fwd("yhi")
    mov x6, 0
    b fwd("ystore")
    label yhi
    ldr x5, [x12, 192]
    sub x5, x5, 1
    cmp x6, x5
    b.le fwd("ystore")
    mov x6, x5
    label ystore
    # texel addr = imgPx + (yi*imgW + xi)*4
    ldr x5, [x12, 184] # imgW
    mul x6, x6, x5
    add x6, x6, x4
    ldr x5, [x12, 176] # imgPx
    add x5, x5, x6, lsl, 2
    # texel bytes -> f64, tinted: d0=cr, d1=cg, d2=cb, d3=ta*tintA
    ldrb w4, [x5]
    ldr d0, [x13, x4, lsl, 3]
    ldr d1, [x12, 96] # tintR
    fmul d0, d0, d1
    ldrb w4, [x5, 1]
    ldr d1, [x13, x4, lsl, 3]
    ldr d2, [x12, 104] # tintG
    fmul d1, d1, d2
    ldrb w4, [x5, 2]
    ldr d2, [x13, x4, lsl, 3]
    ldr d3, [x12, 112] # tintB
    fmul d2, d2, d3
    ldrb w4, [x5, 3]
    ldr d3, [x13, x4, lsl, 3]
    ldr d4, [x12, 120] # tintA
    fmul d3, d3, d4
    ldr d4, [x12, 128] # aAlpha
    fmul d3, d3, d4
    fmax d3, d3, d17
    fmin d3, d3, d18
    ldr d4, [x10] # cov
    fmul d3, d3, d4
    fmov d24, d3 # sa_c
    fsub d25, d18, d24 # inv
    # R
    fmul d0, d0, d24
    ldrb w4, [x9]
    ldr d3, [x13, x4, lsl, 3]
    fmul d3, d3, d25
    fadd d0, d0, d3
    fmax d0, d0, d17
    fmin d0, d0, d18
    fmul d0, d0, d16
    fadd d0, d0, d19
    fcvtzs w4, d0
    strb w4, [x9]
    # G
    fmul d1, d1, d24
    ldrb w4, [x9, 1]
    ldr d3, [x13, x4, lsl, 3]
    fmul d3, d3, d25
    fadd d1, d1, d3
    fmax d1, d1, d17
    fmin d1, d1, d18
    fmul d1, d1, d16
    fadd d1, d1, d19
    fcvtzs w4, d1
    strb w4, [x9, 1]
    # B
    fmul d2, d2, d24
    ldrb w4, [x9, 2]
    ldr d3, [x13, x4, lsl, 3]
    fmul d3, d3, d25
    fadd d2, d2, d3
    fmax d2, d2, d17
    fmin d2, d2, d18
    fmul d2, d2, d16
    fadd d2, d2, d19
    fcvtzs w4, d2
    strb w4, [x9, 2]
    # A
    ldrb w4, [x9, 3]
    ldr d3, [x13, x4, lsl, 3]
    fmul d3, d3, d25
    fadd d3, d3, d24
    fmax d3, d3, d17
    fmin d3, d3, d18
    fmul d3, d3, d16
    fadd d3, d3, d19
    fcvtzs w4, d3
    strb w4, [x9, 3]
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    ret()
  a.finalize()

proc buildPatternRowGenAarch64*(op: static CompOp): ExecutableBuffer =
  ## Nearest-pattern head with the generic-op tail (`blend_a64`, same
  ## contract as x64). Assemble-verified only, like the kernel above.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0
    mov x10, x1
    mov x11, x2
    mov x12, x3
    cbz x11, fwd("done")
    sub sp, sp, 64
    movz x4, 0xED8D
    movk x4, 0x0B5E, lsl, 16
    movk x4, 0xC6F7, lsl, 32
    movk x4, 0x3EB0, lsl, 48
    fmov d25, x4 # 1e-6 threshold
    ldr d16, [x12, 136] # c255
    ldr d17, [x12, 152] # zero
    ldr d18, [x12, 160] # one
    ldr d19, [x12, 144] # half
    ldr x13, [x12, 168] # divtab
    ldr d20, [x12, 224] # rowX
    label row
    # qx = (m0*x + m2y) + m4
    ldr d1, [x12, 0]
    fmul d0, d20, d1
    ldr d1, [x12, 232]
    fadd d0, d0, d1
    ldr d1, [x12, 16]
    fadd d0, d0, d1
    # qy = (m1*x + m3y) + m5
    ldr d1, [x12, 8]
    fmul d2, d20, d1
    ldr d1, [x12, 240]
    fadd d2, d2, d1
    ldr d1, [x12, 24]
    fadd d2, d2, d1
    # dx, dy
    ldr d1, [x12, 32]
    fsub d0, d0, d1
    ldr d1, [x12, 40]
    fsub d2, d2, d1
    # u = (ca*dx + sn*dy)/ex
    ldr d1, [x12, 64]
    fmul d3, d1, d0
    ldr d1, [x12, 72]
    fmul d4, d1, d2
    fadd d3, d3, d4
    ldr d1, [x12, 48]
    fdiv d3, d3, d1
    fmov d21, d3 # u
    # v = (ca*dy - sn*dx)/ey
    ldr d1, [x12, 72]
    fmul d3, d1, d0
    ldr d1, [x12, 64]
    fmul d4, d1, d2
    fsub d4, d4, d3
    ldr d1, [x12, 56]
    fdiv d4, d4, d1
    fmov d22, d4 # v (reused for sa below after yi)
    # flipY?
    ldr x4, [x12, 200]
    cbz x4, fwd("noflip")
    fsub d22, d18, d22
    label noflip
    # xi = wrap(floor(u*wF)) into x4
    ldr d1, [x12, 80]
    fmul d1, d21, d1
    fcvtzs x4, d1
    add x5, x4, x4
    cbnz x5, fwd("xadj")
    cbnz x4, fwd("xkeep")
    label xadj
    scvtf d2, x4
    fcmp d2, d1
    b.le fwd("xkeep")
    sub x4, x4, 1
    label xkeep
    ldr x5, [x12, 208] # repX
    cbz x5, fwd("xclamp")
    ldr x5, [x12, 184]
    sdiv x6, x4, x5
    msub x4, x6, x5, x4
    add x4, x4, x5
    cmp x4, x5
    b.lt fwd("xstore")
    sub x4, x4, x5
    b fwd("xstore")
    label xclamp
    cmp x4, 0
    b.ge fwd("xhi")
    mov x4, 0
    b fwd("xstore")
    label xhi
    ldr x5, [x12, 184]
    sub x5, x5, 1
    cmp x4, x5
    b.le fwd("xstore")
    mov x4, x5
    label xstore
    # yi likewise into x6
    ldr d1, [x12, 88]
    fmul d1, d22, d1
    fcvtzs x6, d1
    add x5, x6, x6
    cbnz x5, fwd("yadj")
    cbnz x6, fwd("ykeep")
    label yadj
    scvtf d2, x6
    fcmp d2, d1
    b.le fwd("ykeep")
    sub x6, x6, 1
    label ykeep
    ldr x5, [x12, 216] # repY
    cbz x5, fwd("yclamp")
    ldr x5, [x12, 192]
    sdiv x7, x6, x5
    msub x6, x7, x5, x6
    add x6, x6, x5
    cmp x6, x5
    b.lt fwd("ystore")
    sub x6, x6, x5
    b fwd("ystore")
    label yclamp
    cmp x6, 0
    b.ge fwd("yhi")
    mov x6, 0
    b fwd("ystore")
    label yhi
    ldr x5, [x12, 192]
    sub x5, x5, 1
    cmp x6, x5
    b.le fwd("ystore")
    mov x6, x5
    label ystore
    # texel addr = imgPx + (yi*imgW + xi)*4
    ldr x5, [x12, 184]
    mul x6, x6, x5
    add x6, x6, x4
    ldr x5, [x12, 176]
    add x5, x5, x6, lsl, 2
    # texel bytes -> f64, tinted, clamped
    ldrb w4, [x5]
    ldr d0, [x13, x4, lsl, 3]
    ldr d1, [x12, 96]
    fmul d0, d0, d1
    fmax d0, d0, d17
    fmin d0, d0, d18
    ldrb w4, [x5, 1]
    ldr d1, [x13, x4, lsl, 3]
    ldr d2, [x12, 104]
    fmul d1, d1, d2
    fmax d1, d1, d17
    fmin d1, d1, d18
    ldrb w4, [x5, 2]
    ldr d2, [x13, x4, lsl, 3]
    ldr d3, [x12, 112]
    fmul d2, d2, d3
    fmax d2, d2, d17
    fmin d2, d2, d18
    ldrb w4, [x5, 3]
    ldr d3, [x13, x4, lsl, 3]
    ldr d4, [x12, 120]
    fmul d3, d3, d4
    ldr d4, [x12, 128]
    fmul d3, d3, d4
    fmax d3, d3, d17
    fmin d3, d3, d18
    ldr d4, [x10]
    fmul d22, d3, d4 # sa
  # NB: `include` must nest in `when` here (same quirk as above).
  when op != coSourceOver:
    include blend_a64
  dynasm a:
    arch aarch64
    fadd d20, d20, d18 # x += 1.0
    add x9, x9, 4
    add x10, x10, 8
    sub x11, x11, 1
    cbnz x11, bwd("row")
    label done
    add sp, sp, 64
    ret()
  a.finalize()

type
  JitKernels* = ref JitKernelsObj
    ## Owns JIT row kernels. Paint-agnostic (constants travel via ctx),
    ## so one kernel per paint shape serves all fills of that shape;
    ## built lazily.
  JitKernelsObj* = object
    solidBufs: array[CompOp, ExecutableBuffer]
    solidFns: array[CompOp, SolidRowFn]
    solidHas: array[CompOp, bool]
    linearBufs: array[CompOp, ExecutableBuffer]
    linearFns: array[CompOp, LinearRowFn]
    linearHas: array[CompOp, bool]
    radialBufs: array[CompOp, ExecutableBuffer]
    radialFns: array[CompOp, RadialRowFn]
    radialHas: array[CompOp, bool]
    boxBufs: array[CompOp, ExecutableBuffer]
    boxFns: array[CompOp, BoxRowFn]
    boxHas: array[CompOp, bool]
    patBufs: array[CompOp, ExecutableBuffer]
    patFns: array[CompOp, PatternRowFn]
    patHas: array[CompOp, bool]

proc getSolid*(k: JitKernels, op: CompOp = coSourceOver): SolidRowFn =
  ## Return the solid row kernel for `op`, building it on first use.
  ## Non-amd64 hosts get nil (callers fall back to the scalar
  ## rasterizer; the AArch64 kernels are assemble-verified until an ARM
  ## run signs off execution).
  when defined(amd64):
    if not k.solidHas[op]:
      ensureDivTable()
      k.solidBufs[op] = case op
        of coSourceOver: buildSolidRowX64()
        of coSourceIn: buildSolidRowGenX64(coSourceIn)
        of coSourceOut: buildSolidRowGenX64(coSourceOut)
        of coAtop: buildSolidRowGenX64(coAtop)
        of coDestinationOver: buildSolidRowGenX64(coDestinationOver)
        of coDestinationIn: buildSolidRowGenX64(coDestinationIn)
        of coDestinationOut: buildSolidRowGenX64(coDestinationOut)
        of coDestinationAtop: buildSolidRowGenX64(coDestinationAtop)
        of coLighter: buildSolidRowGenX64(coLighter)
        of coCopy: buildSolidRowGenX64(coCopy)
        of coXor: buildSolidRowGenX64(coXor)
        of coMultiply: buildSolidRowGenX64(coMultiply)
        of coScreen: buildSolidRowGenX64(coScreen)
        of coOverlay: buildSolidRowGenX64(coOverlay)
      k.solidFns[op] = cast[SolidRowFn](
        k.solidBufs[op].ptrAt(AssemblyOffset(0)))
      k.solidHas[op] = true
    k.solidFns[op]
  else:
    nil

proc getLinear*(k: JitKernels, op: CompOp = coSourceOver): LinearRowFn =
  ## Return the linear-gradient row kernel for `op`, building it on
  ## first use. Same platform gate as `getSolid`.
  when defined(amd64):
    if not k.linearHas[op]:
      ensureDivTable()
      k.linearBufs[op] = case op
        of coSourceOver: buildLinearRowX64()
        of coSourceIn: buildLinearRowGenX64(coSourceIn)
        of coSourceOut: buildLinearRowGenX64(coSourceOut)
        of coAtop: buildLinearRowGenX64(coAtop)
        of coDestinationOver: buildLinearRowGenX64(coDestinationOver)
        of coDestinationIn: buildLinearRowGenX64(coDestinationIn)
        of coDestinationOut: buildLinearRowGenX64(coDestinationOut)
        of coDestinationAtop: buildLinearRowGenX64(coDestinationAtop)
        of coLighter: buildLinearRowGenX64(coLighter)
        of coCopy: buildLinearRowGenX64(coCopy)
        of coXor: buildLinearRowGenX64(coXor)
        of coMultiply: buildLinearRowGenX64(coMultiply)
        of coScreen: buildLinearRowGenX64(coScreen)
        of coOverlay: buildLinearRowGenX64(coOverlay)
      k.linearFns[op] = cast[LinearRowFn](
        k.linearBufs[op].ptrAt(AssemblyOffset(0)))
      k.linearHas[op] = true
    k.linearFns[op]
  else:
    nil

proc getRadial*(k: JitKernels, op: CompOp = coSourceOver): RadialRowFn =
  ## Return the radial-gradient row kernel for `op`, building it on
  ## first use. Same platform gate as `getSolid`.
  when defined(amd64):
    if not k.radialHas[op]:
      ensureDivTable()
      k.radialBufs[op] = case op
        of coSourceOver: buildRadialRowX64()
        of coSourceIn: buildRadialRowGenX64(coSourceIn)
        of coSourceOut: buildRadialRowGenX64(coSourceOut)
        of coAtop: buildRadialRowGenX64(coAtop)
        of coDestinationOver: buildRadialRowGenX64(coDestinationOver)
        of coDestinationIn: buildRadialRowGenX64(coDestinationIn)
        of coDestinationOut: buildRadialRowGenX64(coDestinationOut)
        of coDestinationAtop: buildRadialRowGenX64(coDestinationAtop)
        of coLighter: buildRadialRowGenX64(coLighter)
        of coCopy: buildRadialRowGenX64(coCopy)
        of coXor: buildRadialRowGenX64(coXor)
        of coMultiply: buildRadialRowGenX64(coMultiply)
        of coScreen: buildRadialRowGenX64(coScreen)
        of coOverlay: buildRadialRowGenX64(coOverlay)
      k.radialFns[op] = cast[RadialRowFn](
        k.radialBufs[op].ptrAt(AssemblyOffset(0)))
      k.radialHas[op] = true
    k.radialFns[op]
  else:
    nil

proc getBox*(k: JitKernels, op: CompOp = coSourceOver): BoxRowFn =
  ## Return the box-gradient row kernel for `op`, building it on first
  ## use. Same platform gate as `getSolid`.
  when defined(amd64):
    if not k.boxHas[op]:
      ensureDivTable()
      k.boxBufs[op] = case op
        of coSourceOver: buildBoxRowX64()
        of coSourceIn: buildBoxRowGenX64(coSourceIn)
        of coSourceOut: buildBoxRowGenX64(coSourceOut)
        of coAtop: buildBoxRowGenX64(coAtop)
        of coDestinationOver: buildBoxRowGenX64(coDestinationOver)
        of coDestinationIn: buildBoxRowGenX64(coDestinationIn)
        of coDestinationOut: buildBoxRowGenX64(coDestinationOut)
        of coDestinationAtop: buildBoxRowGenX64(coDestinationAtop)
        of coLighter: buildBoxRowGenX64(coLighter)
        of coCopy: buildBoxRowGenX64(coCopy)
        of coXor: buildBoxRowGenX64(coXor)
        of coMultiply: buildBoxRowGenX64(coMultiply)
        of coScreen: buildBoxRowGenX64(coScreen)
        of coOverlay: buildBoxRowGenX64(coOverlay)
      k.boxFns[op] = cast[BoxRowFn](
        k.boxBufs[op].ptrAt(AssemblyOffset(0)))
      k.boxHas[op] = true
    k.boxFns[op]
  else:
    nil

proc getPattern*(k: JitKernels, op: CompOp = coSourceOver): PatternRowFn =
  ## Return the nearest-pattern row kernel for `op`, building it on
  ## first use. Same platform gate as `getSolid`.
  when defined(amd64):
    if not k.patHas[op]:
      ensureDivTable()
      k.patBufs[op] = case op
        of coSourceOver: buildPatternRowX64()
        of coSourceIn: buildPatternRowGenX64(coSourceIn)
        of coSourceOut: buildPatternRowGenX64(coSourceOut)
        of coAtop: buildPatternRowGenX64(coAtop)
        of coDestinationOver: buildPatternRowGenX64(coDestinationOver)
        of coDestinationIn: buildPatternRowGenX64(coDestinationIn)
        of coDestinationOut: buildPatternRowGenX64(coDestinationOut)
        of coDestinationAtop: buildPatternRowGenX64(coDestinationAtop)
        of coLighter: buildPatternRowGenX64(coLighter)
        of coCopy: buildPatternRowGenX64(coCopy)
        of coXor: buildPatternRowGenX64(coXor)
        of coMultiply: buildPatternRowGenX64(coMultiply)
        of coScreen: buildPatternRowGenX64(coScreen)
        of coOverlay: buildPatternRowGenX64(coOverlay)
      k.patFns[op] = cast[PatternRowFn](
        k.patBufs[op].ptrAt(AssemblyOffset(0)))
      k.patHas[op] = true
    k.patFns[op]
  else:
    nil

proc destroy*(k: JitKernels) =
  ## Release executable mappings. Idempotent; also runs via GC.
  for op in CompOp:
    if k.solidHas[op]:
      k.solidBufs[op].destroy()
      k.solidHas[op] = false
      k.solidFns[op] = nil
    if k.linearHas[op]:
      k.linearBufs[op].destroy()
      k.linearHas[op] = false
      k.linearFns[op] = nil
    if k.radialHas[op]:
      k.radialBufs[op].destroy()
      k.radialHas[op] = false
      k.radialFns[op] = nil
    if k.boxHas[op]:
      k.boxBufs[op].destroy()
      k.boxHas[op] = false
      k.boxFns[op] = nil
    if k.patHas[op]:
      k.patBufs[op].destroy()
      k.patHas[op] = false
      k.patFns[op] = nil

proc `=destroy`*(x: var JitKernelsObj) =
  for op in CompOp:
    if x.solidHas[op]:
      x.solidBufs[op].destroy()
      x.solidHas[op] = false
      x.solidFns[op] = nil
    if x.linearHas[op]:
      x.linearBufs[op].destroy()
      x.linearHas[op] = false
      x.linearFns[op] = nil
    if x.radialHas[op]:
      x.radialBufs[op].destroy()
      x.radialHas[op] = false
      x.radialFns[op] = nil
    if x.boxHas[op]:
      x.boxBufs[op].destroy()
      x.boxHas[op] = false
      x.boxFns[op] = nil
    if x.patHas[op]:
      x.patBufs[op].destroy()
      x.patHas[op] = false
      x.patFns[op] = nil
