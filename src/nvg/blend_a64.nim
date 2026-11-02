## Generic-op blend tail for the AArch64 row kernels (INCLUDED, never
## imported). Same structure and contract notes as `blend_x64.nim`;
## assemble-verified only until an ARM run signs off execution.
##
## Entry contract: d0/1/2 = straight CLAMPED paint r/g/b, d22 = sa,
## x9 = dst cursor, x13 = div-table, d16/17/18/19 = c255/zero/one/half,
## d20 = x (preserved). Frame is 64 bytes; rgb spills to
## `[sp+32/40/48]`, d25 holds 1e-6 (builder prologue materializes it via
## movz/movk + fmov). Clobbers d0-d4/d23/d24/d26/d27, x4-x7, flags.

when not declared(a):
  {.error: "blend_a64 is an include fragment for jit.nim builders, never compiled directly".}

# --- A: da -> d24, ao -> d23 ---
when op == coSourceIn:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3] # da
    fmul d23, d22, d24 # sa*da
elif op == coSourceOut:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fsub d26, d18, d24 # 1-da
    fmul d23, d22, d26 # sa*(1-da)
elif op == coAtop:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fmov d23, d24 # da
elif op == coDestinationOver:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fsub d26, d18, d22 # 1-sa
    fmul d26, d26, d24 # da*(1-sa)
    fadd d23, d22, d26
elif op == coDestinationIn:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fmul d23, d24, d22 # da*sa
elif op == coDestinationOut:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fsub d26, d18, d22 # 1-sa
    fmul d23, d24, d26 # da*(1-sa)
elif op == coDestinationAtop:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fmov d23, d22 # sa
elif op == coLighter:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fadd d23, d22, d24
    fmin d23, d23, d18
elif op == coCopy:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fmov d23, d22
elif op == coXor:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fadd d23, d22, d24
    fadd d26, d22, d22 # 2*sa
    fmul d26, d26, d24
    fsub d23, d23, d26
elif op == coMultiply:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fsub d26, d18, d22
    fmul d26, d26, d24
    fadd d23, d22, d26
elif op == coScreen:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fsub d26, d18, d22
    fmul d26, d26, d24
    fadd d23, d22, d26
elif op == coOverlay:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 3]
    ldr d24, [x13, x4, lsl, 3]
    fsub d26, d18, d22
    fmul d26, d26, d24
    fadd d23, d22, d26
else:
  {.error: "blend tail: sourceOver uses the dedicated fast path".}

# --- B: ao threshold branch + rgb spill (shared) ---
dynasm a:
  arch aarch64
  fcmp d23, d25
  b.ls fwd("pxzero") # ao <= 1e-6 -> transparent black
  str d0, [sp, 32]
  str d1, [sp, 40]
  str d2, [sp, 48]

# --- C1: R channel ---
when op == coSourceIn:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    fmul d0, d0, d24
elif op == coSourceOut:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
elif op == coAtop:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    fmul d0, d0, d24
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fsub d26, d18, d22
    fmul d1, d1, d26
    fadd d0, d0, d1
elif op == coDestinationOver:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fadd d0, d0, d1
elif op == coDestinationIn:
  dynasm a:
    arch aarch64
    ldrb w4, [x9]
    ldr d0, [x13, x4, lsl, 3]
    fmul d0, d0, d24
    fmul d0, d0, d22
elif op == coDestinationOut:
  dynasm a:
    arch aarch64
    ldrb w4, [x9]
    ldr d0, [x13, x4, lsl, 3]
    fmul d0, d0, d24
    fsub d26, d18, d22
    fmul d0, d0, d26
elif op == coDestinationAtop:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fmul d1, d1, d22
    fadd d0, d0, d1
elif op == coLighter:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fadd d0, d0, d1
elif op == coCopy:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
elif op == coXor:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 32]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fsub d26, d18, d22
    fmul d1, d1, d26
    fadd d0, d0, d1
elif op == coMultiply:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24 # 1-da
    fmul d26, d26, d22 # (1-da)*sa
    ldr d0, [sp, 32]
    fmul d0, d0, d26 # t1
    fsub d26, d18, d22 # 1-sa
    fmul d26, d26, d24 # (1-sa)*da
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26 # t2
    fadd d0, d0, d1
    fmul d1, d22, d24 # sa*da
    ldr d2, [sp, 32]
    ldrb w4, [x9]
    ldr d26, [x13, x4, lsl, 3]
    fmul d2, d2, d26 # Bout
    fmul d1, d1, d2 # t3
    fadd d0, d0, d1
elif op == coScreen:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 32]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    ldr d1, [sp, 32]
    ldrb w4, [x9]
    ldr d2, [x13, x4, lsl, 3]
    fmul d26, d1, d2
    fadd d1, d1, d2
    fsub d1, d1, d26 # Bout
    fmul d2, d22, d24
    fmul d1, d1, d2
    fadd d0, d0, d1
elif op == coOverlay:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 32]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    ldr d1, [sp, 32]
    ldrb w4, [x9]
    ldr d2, [x13, x4, lsl, 3]
    fcmp d2, d19 # cb <= 0.5?
    b.ls fwd("ovlRlo")
    fsub d26, d18, d1 # 1-cs
    fadd d26, d26, d26
    fsub d1, d18, d2 # 1-cb
    fmul d26, d26, d1
    fsub d1, d18, d26 # Bout
    b fwd("ovlRdone")
    label ovlRlo
    fmul d1, d1, d2
    fadd d1, d1, d1
    label ovlRdone
    fmul d2, d22, d24
    fmul d1, d1, d2
    fadd d0, d0, d1
dynasm a:
  arch aarch64
  fdiv d0, d0, d23
  fmax d0, d0, d17
  fmin d0, d0, d18
  fmul d0, d0, d16
  fadd d0, d0, d19
  fcvtzs w4, d0
  strb w4, [x9]

# --- C2: G channel ---
when op == coSourceIn:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    fmul d0, d0, d24
elif op == coSourceOut:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
elif op == coAtop:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    fmul d0, d0, d24
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fsub d26, d18, d22
    fmul d1, d1, d26
    fadd d0, d0, d1
elif op == coDestinationOver:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fadd d0, d0, d1
elif op == coDestinationIn:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 1]
    ldr d0, [x13, x4, lsl, 3]
    fmul d0, d0, d24
    fmul d0, d0, d22
elif op == coDestinationOut:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 1]
    ldr d0, [x13, x4, lsl, 3]
    fmul d0, d0, d24
    fsub d26, d18, d22
    fmul d0, d0, d26
elif op == coDestinationAtop:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fmul d1, d1, d22
    fadd d0, d0, d1
elif op == coLighter:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fadd d0, d0, d1
elif op == coCopy:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
elif op == coXor:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 40]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fsub d26, d18, d22
    fmul d1, d1, d26
    fadd d0, d0, d1
elif op == coMultiply:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 40]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    fmul d1, d22, d24
    ldr d2, [sp, 40]
    ldrb w4, [x9, 1]
    ldr d26, [x13, x4, lsl, 3]
    fmul d2, d2, d26
    fmul d1, d1, d2
    fadd d0, d0, d1
elif op == coScreen:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 40]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    ldr d1, [sp, 40]
    ldrb w4, [x9, 1]
    ldr d2, [x13, x4, lsl, 3]
    fmul d26, d1, d2
    fadd d1, d1, d2
    fsub d1, d1, d26
    fmul d2, d22, d24
    fmul d1, d1, d2
    fadd d0, d0, d1
elif op == coOverlay:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 40]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9, 1]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    ldr d1, [sp, 40]
    ldrb w4, [x9, 1]
    ldr d2, [x13, x4, lsl, 3]
    fcmp d2, d19
    b.ls fwd("ovlGlo")
    fsub d26, d18, d1
    fadd d26, d26, d26
    fsub d1, d18, d2
    fmul d26, d26, d1
    fsub d1, d18, d26
    b fwd("ovlGdone")
    label ovlGlo
    fmul d1, d1, d2
    fadd d1, d1, d1
    label ovlGdone
    fmul d2, d22, d24
    fmul d1, d1, d2
    fadd d0, d0, d1
dynasm a:
  arch aarch64
  fdiv d0, d0, d23
  fmax d0, d0, d17
  fmin d0, d0, d18
  fmul d0, d0, d16
  fadd d0, d0, d19
  fcvtzs w4, d0
  strb w4, [x9, 1]

# --- C3: B channel ---
when op == coSourceIn:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    fmul d0, d0, d24
elif op == coSourceOut:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
elif op == coAtop:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    fmul d0, d0, d24
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fsub d26, d18, d22
    fmul d1, d1, d26
    fadd d0, d0, d1
elif op == coDestinationOver:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fadd d0, d0, d1
elif op == coDestinationIn:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 2]
    ldr d0, [x13, x4, lsl, 3]
    fmul d0, d0, d24
    fmul d0, d0, d22
elif op == coDestinationOut:
  dynasm a:
    arch aarch64
    ldrb w4, [x9, 2]
    ldr d0, [x13, x4, lsl, 3]
    fmul d0, d0, d24
    fsub d26, d18, d22
    fmul d0, d0, d26
elif op == coDestinationAtop:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fmul d1, d1, d22
    fadd d0, d0, d1
elif op == coLighter:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fadd d0, d0, d1
elif op == coCopy:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
elif op == coXor:
  dynasm a:
    arch aarch64
    ldr d0, [sp, 48]
    fmul d0, d0, d22
    fsub d26, d18, d24
    fmul d0, d0, d26
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d24
    fsub d26, d18, d22
    fmul d1, d1, d26
    fadd d0, d0, d1
elif op == coMultiply:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 48]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    fmul d1, d22, d24
    ldr d2, [sp, 48]
    ldrb w4, [x9, 2]
    ldr d26, [x13, x4, lsl, 3]
    fmul d2, d2, d26
    fmul d1, d1, d2
    fadd d0, d0, d1
elif op == coScreen:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 48]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    ldr d1, [sp, 48]
    ldrb w4, [x9, 2]
    ldr d2, [x13, x4, lsl, 3]
    fmul d26, d1, d2
    fadd d1, d1, d2
    fsub d1, d1, d26
    fmul d2, d22, d24
    fmul d1, d1, d2
    fadd d0, d0, d1
elif op == coOverlay:
  dynasm a:
    arch aarch64
    fsub d26, d18, d24
    fmul d26, d26, d22
    ldr d0, [sp, 48]
    fmul d0, d0, d26
    fsub d26, d18, d22
    fmul d26, d26, d24
    ldrb w4, [x9, 2]
    ldr d1, [x13, x4, lsl, 3]
    fmul d1, d1, d26
    fadd d0, d0, d1
    ldr d1, [sp, 48]
    ldrb w4, [x9, 2]
    ldr d2, [x13, x4, lsl, 3]
    fcmp d2, d19
    b.ls fwd("ovlBlo")
    fsub d26, d18, d1
    fadd d26, d26, d26
    fsub d1, d18, d2
    fmul d26, d26, d1
    fsub d1, d18, d26
    b fwd("ovlBdone")
    label ovlBlo
    fmul d1, d1, d2
    fadd d1, d1, d1
    label ovlBdone
    fmul d2, d22, d24
    fmul d1, d1, d2
    fadd d0, d0, d1
dynasm a:
  arch aarch64
  fdiv d0, d0, d23
  fmax d0, d0, d17
  fmin d0, d0, d18
  fmul d0, d0, d16
  fadd d0, d0, d19
  fcvtzs w4, d0
  strb w4, [x9, 2]

# --- C4: A channel (shared) + pixel done / zero (shared) ---
dynasm a:
  arch aarch64
  fmax d3, d23, d17
  fmin d3, d23, d18
  fmul d3, d3, d16
  fadd d3, d3, d19
  fcvtzs w4, d3
  strb w4, [x9, 3]
  b fwd("pxdone")
  label pxzero
  str wzr, [x9] # transparent black, like the scalar ao branch
  label pxdone
