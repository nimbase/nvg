# spike_linear_row.nim — Phase 0b: scalar vs packed-double linear gradient.
#
# Decides whether 2-wide packed paint eval pays once fused with a scalar
# blend. Horizontal gradient (dy=0, identity map) keeps the op order
# exactly replicable; a general 2D gradient only adds muls/adds.
#
# Run (correctness): nim c -r --path:src --path:../dynasm/src spike_linear_row.nim
# Run (timing):      nim c -r -d:release --path:src --path:../dynasm/src spike_linear_row.nim
#
# Both kernels: (dst: pointer, n: int64) {.cdecl.}, all constants in the
# RIP-relative pool baked by the host. Gradient: sx=0, ex=800,
# icol=(1,0,0,1), ocol=(0,0,1,0.25). Op order replicates paint.sample +
# blendPixel exactly (mul-then-div for t, lerp as c0+dr*t); no algebraic
# reassociation, so byte-identity is structural, not lucky.
# Finite-colors-only (same NaN note as the solid spike).

import dynasm
import nvg/types
import nvg/paint
import nvg/surface
import std/[times, random]

type RowFn* = proc(dst: pointer, n: int64) {.cdecl.}

const
  SX = 0.0
  EX = 800.0
  DX = EX - SX
  LEN2 = DX * DX
  R0 = 1.0
  G0 = 0.0
  B0 = 0.0
  A0 = 1.0
  R1 = 0.0
  G1 = 0.0
  B1 = 1.0
  A1 = 0.25
  DR = R1 - R0
  DG = G1 - G0
  DB = B1 - B0
  DA = A1 - A0

proc oraclePaint*(): Paint =
  linearGradient(SX, 0.0, EX, 0.0, rgbaf(R0, G0, B0, A0),
    rgbaf(R1, G1, B1, A1))

proc buildLinearScalar*(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias n, rsi, rdx
    mov r10, dst
    mov r11, n
    `xor` eax, eax # j = 0
    cmp r11, 0
    jle fwd("dkOne")
    label pixel
    cvtsi2sd xmm0, eax
    addsd xmm0, [glob("kHalf")]  # qx = j + 0.5
    mulsd xmm0, [glob("kDx")]    # qx*dx
    divsd xmm0, [glob("kLen2")]  # t (same order as sample)
    movsd xmm1, [glob("kZero")]
    maxpd xmm0, xmm1
    movsd xmm1, [glob("kOne")]
    minpd xmm0, xmm1            # clamped t in xmm0
    # A channel first: sa + inv live across the other channels.
    movsd xmm1, [glob("kA0")]
    movsd xmm2, [glob("kDa")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2            # a
    movsd xmm2, [glob("kZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("kOne")]
    minpd xmm1, xmm2
    movsd xmm4, xmm1            # sa
    movsd xmm3, [glob("kOne")]
    subsd xmm3, xmm4            # inv
    # R
    movsd xmm1, [glob("kR0")]
    movsd xmm2, [glob("kDr")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    mulsd xmm1, xmm4
    movzx edx, byte [r10]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("k255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("kZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("kOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("k255")]
    addsd xmm1, [glob("kHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10], dl
    # G
    movsd xmm1, [glob("kG0")]
    movsd xmm2, [glob("kDg")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 1]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("k255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("kZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("kOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("k255")]
    addsd xmm1, [glob("kHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 1], dl
    # B
    movsd xmm1, [glob("kB0")]
    movsd xmm2, [glob("kDb")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 2]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("k255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("kZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("kOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("k255")]
    addsd xmm1, [glob("kHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 2], dl
    # A: sa + da*inv
    movzx edx, byte [r10 + 3]
    cvtsi2sd xmm1, edx
    divsd xmm1, [glob("k255")]
    mulsd xmm1, xmm3
    addsd xmm1, xmm4
    movsd xmm2, [glob("kZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("kOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("k255")]
    addsd xmm1, [glob("kHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 3], dl
    add r10, 4
    add eax, 1
    sub r11, 1
    cmp r11, 0
    jg bwd("pixel")
    label dkOne
    ret()
    global kHalf
    f64 0.5
    global kDx
    f64 DX
    global kLen2
    f64 LEN2
    global kZero
    f64 0.0
    global kOne
    f64 1.0
    global k255
    f64 255.0
    global kR0
    f64 R0
    global kG0
    f64 G0
    global kB0
    f64 B0
    global kA0
    f64 A0
    global kDr
    f64 DR
    global kDg
    f64 DG
    global kDb
    f64 DB
    global kDa
    f64 DA
  a.finalize()

proc buildLinearPacked*(): ExecutableBuffer =
  # Paint eval 2-wide (t + 4 lerps in packed-double), blend scalar from
  # spilled pairs. Straight-line k=0/k=1 blend avoids unverified SIB
  # forms and keeps all state in volatile regs + 72-byte scratch.
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias n, rsi, rdx
    mov r10, dst
    mov r11, n
    `xor` eax, eax # j = 0
    cmp r11, 2
    jl fwd("tail")
    sub rsp, 88 # [rsp]=jvec temp, [rsp+16..79]=4 spilled pairs
    label pair
    cmp r11, 2
    jl fwd("unwind")
    mov ecx, eax
    add ecx, 1
    cvtsi2sd xmm0, eax
    movsd [rsp], xmm0
    cvtsi2sd xmm0, ecx
    movsd [rsp + 8], xmm0
    movupd xmm0, [rsp]
    # NB: packed ALU with RIP-relative mem faults (dynasm bug, filed
    # separately); route every pool constant through a register.
    movupd xmm1, [glob("pHalf")]
    addpd xmm0, xmm1
    movupd xmm1, [glob("pDx")]
    mulpd xmm0, xmm1
    movupd xmm1, [glob("pLen2")]
    divpd xmm0, xmm1
    movupd xmm1, [glob("pZero")]
    maxpd xmm0, xmm1
    movupd xmm1, [glob("pOne")]
    minpd xmm0, xmm1 # t pair in xmm0
    movupd xmm1, [glob("pR0")]
    movupd xmm2, [glob("pDr")]
    mulpd xmm2, xmm0
    addpd xmm1, xmm2
    movupd [rsp + 16], xmm1
    movupd xmm1, [glob("pG0")]
    movupd xmm2, [glob("pDg")]
    mulpd xmm2, xmm0
    addpd xmm1, xmm2
    movupd [rsp + 32], xmm1
    movupd xmm1, [glob("pB0")]
    movupd xmm2, [glob("pDb")]
    mulpd xmm2, xmm0
    addpd xmm1, xmm2
    movupd [rsp + 48], xmm1
    movupd xmm1, [glob("pA0")]
    movupd xmm2, [glob("pDa")]
    mulpd xmm2, xmm0
    addpd xmm1, xmm2
    movupd [rsp + 64], xmm1
    # --- blend k=0: doubles at +0 lane, dst at [r10] ---
    movsd xmm4, [rsp + 64]
    movsd xmm5, [glob("sZero")]
    maxpd xmm4, xmm5
    movsd xmm5, [glob("sOne")]
    minpd xmm4, xmm5
    movsd xmm3, [glob("sOne")]
    subsd xmm3, xmm4
    movsd xmm1, [rsp + 16] # R0
    mulsd xmm1, xmm4
    movzx edx, byte [r10]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10], dl
    movsd xmm1, [rsp + 32] # G0
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 1]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 1], dl
    movsd xmm1, [rsp + 48] # B0
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 2]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 2], dl
    movzx edx, byte [r10 + 3] # A0
    cvtsi2sd xmm1, edx
    divsd xmm1, [glob("sC255")]
    mulsd xmm1, xmm3
    addsd xmm1, xmm4
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 3], dl
    # --- blend k=1: doubles at +8 lane, dst at [r10+4] ---
    movsd xmm4, [rsp + 72]
    movsd xmm5, [glob("sZero")]
    maxpd xmm4, xmm5
    movsd xmm5, [glob("sOne")]
    minpd xmm4, xmm5
    movsd xmm3, [glob("sOne")]
    subsd xmm3, xmm4
    movsd xmm1, [rsp + 24] # R1
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 4]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 4], dl
    movsd xmm1, [rsp + 40] # G1
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 5]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 5], dl
    movsd xmm1, [rsp + 56] # B1
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 6]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 6], dl
    movzx edx, byte [r10 + 7] # A1
    cvtsi2sd xmm1, edx
    divsd xmm1, [glob("sC255")]
    mulsd xmm1, xmm3
    addsd xmm1, xmm4
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 7], dl
    add r10, 8
    add eax, 2
    sub r11, 2
    jmp bwd("pair")
    label unwind
    add rsp, 88
    label tail
    # Scalar tail for the last pixel when n is odd (pair-pool low lanes
    # double as scalar constants via movsd).
    cmp r11, 0
    jle fwd("dkOne")
    cvtsi2sd xmm0, eax
    addsd xmm0, [glob("pHalf")]
    movupd xmm1, [glob("pDx")]
    mulsd xmm0, xmm1        # low lane only; high lane garbage, unused
    movupd xmm1, [glob("pLen2")]
    divsd xmm0, xmm1
    movsd xmm1, [glob("sZero")]
    maxpd xmm0, xmm1
    movsd xmm1, [glob("sOne")]
    minpd xmm0, xmm1
    movsd xmm1, [glob("pA0")]
    movupd xmm2, [glob("pDa")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    movsd xmm4, xmm1
    movsd xmm3, [glob("sOne")]
    subsd xmm3, xmm4
    movsd xmm1, [glob("pR0")]
    movupd xmm2, [glob("pDr")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    mulsd xmm1, xmm4
    movzx edx, byte [r10]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10], dl
    movsd xmm1, [glob("pG0")]
    movupd xmm2, [glob("pDg")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 1]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 1], dl
    movsd xmm1, [glob("pB0")]
    movupd xmm2, [glob("pDb")]
    mulsd xmm2, xmm0
    addsd xmm1, xmm2
    mulsd xmm1, xmm4
    movzx edx, byte [r10 + 2]
    cvtsi2sd xmm2, edx
    divsd xmm2, [glob("sC255")]
    mulsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 2], dl
    movzx edx, byte [r10 + 3]
    cvtsi2sd xmm1, edx
    divsd xmm1, [glob("sC255")]
    mulsd xmm1, xmm3
    addsd xmm1, xmm4
    movsd xmm2, [glob("sZero")]
    maxpd xmm1, xmm2
    movsd xmm2, [glob("sOne")]
    minpd xmm1, xmm2
    mulsd xmm1, [glob("sC255")]
    addsd xmm1, [glob("sHalf")]
    cvttsd2si edx, xmm1
    mov byte [r10 + 3], dl
    label dkOne
    ret()
    global pHalf
    f64 0.5
    f64 0.5
    global pDx
    f64 DX
    f64 DX
    global pLen2
    f64 LEN2
    f64 LEN2
    global pZero
    f64 0.0
    f64 0.0
    global pOne
    f64 1.0
    f64 1.0
    global pR0
    f64 R0
    f64 R0
    global pDr
    f64 DR
    f64 DR
    global pG0
    f64 G0
    f64 G0
    global pDg
    f64 DG
    f64 DG
    global pB0
    f64 B0
    f64 B0
    global pDb
    f64 DB
    f64 DB
    global pA0
    f64 A0
    f64 A0
    global pDa
    f64 DA
    f64 DA
    global sZero
    f64 0.0
    global sOne
    f64 1.0
    global sC255
    f64 255.0
    global sHalf
    f64 0.5
  a.finalize()

proc checkRow(fn: RowFn, paint: Paint, dst: openArray[uint8]) =
  let n = dst.len div 4
  var got = newSeq[uint8](dst.len)
  for i, b in dst: got[i] = b
  if n > 0:
    fn(addr got[0], int64(n))
  else:
    fn(nil, 0)
  var surf = newSurface(max(n, 1), 1)
  surf.pixels.setLen(dst.len)
  for i, b in dst: surf.pixels[i] = b
  for x in 0 ..< n:
    # Kernel hardcodes the row at y=0.5; the oracle gradient is
    # y-independent (dy=0, identity map), so any y agrees.
    surf.blendPixel(x, 0, paint.sample(float64(x) + 0.5, 0.5), 1.0,
      coSourceOver)
  assert got == surf.pixels, "mismatch n=" & $n

when isMainModule:
  randomize(99)
  var sbuf = buildLinearScalar()
  var pbuf = buildLinearPacked()
  echo "scalar kernel: ", sbuf.len, " bytes; packed kernel: ", pbuf.len,
    " bytes"
  let sfn = cast[RowFn](sbuf.ptrAt(AssemblyOffset(0)))
  let pfn = cast[RowFn](pbuf.ptrAt(AssemblyOffset(0)))
  let gpaint = oraclePaint()
  for n in [0, 1, 2, 3, 7, 800, 801]:
    var dst = newSeq[uint8](n * 4)
    for i in 0 ..< dst.len: dst[i] = uint8(rand(256))
    checkRow(sfn, gpaint, dst)
    checkRow(pfn, gpaint, dst)
  var kZeros = newSeq[uint8](800 * 4)
  checkRow(sfn, gpaint, kZeros)
  checkRow(pfn, gpaint, kZeros)
  # Per-channel sweep on a mid row keeps the blend hkOnest.
  for ch in 0 ..< 4:
    for v in [0, 64, 128, 192, 255]:
      var px = [10'u8, 20, 30, 40]
      px[ch] = uint8(v)
      checkRow(sfn, gpaint, px)
      checkRow(pfn, gpaint, px)
  echo "correctness: scalar + packed byte-identical to sample+blend"

  const W = 800
  const H = 600
  const Iters = 20
  var pristine = newSeq[uint8](W * H * 4)
  for i in 0 ..< pristine.len: pristine[i] = uint8(rand(256))
  var work = newSeq[uint8](pristine.len)
  let t0 = cpuTime()
  for _ in 0 ..< Iters:
    var s = newSurface(W, H)
    copyMem(addr s.pixels[0], addr pristine[0], pristine.len)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.blendPixel(x, y, gpaint.sample(float64(x) + 0.5,
          float64(y) + 0.5), 1.0, coSourceOver)
  let nimT = cpuTime() - t0
  let t1 = cpuTime()
  for _ in 0 ..< Iters:
    copyMem(addr work[0], addr pristine[0], pristine.len)
    for y in 0 ..< H:
      sfn(cast[pointer](cast[int](addr work[0]) + y * W * 4), int64(W))
  let scalarT = cpuTime() - t1
  let t2 = cpuTime()
  for _ in 0 ..< Iters:
    copyMem(addr work[0], addr pristine[0], pristine.len)
    for y in 0 ..< H:
      pfn(cast[pointer](cast[int](addr work[0]) + y * W * 4), int64(W))
  let packedT = cpuTime() - t2
  echo "nim sample+blend 800x600 x", Iters, ": ", nimT, "s"
  echo "jit scalar 800x600 x", Iters, ": ", scalarT, "s (",
    nimT / max(scalarT, 1e-9), "x)"
  echo "jit packed 800x600 x", Iters, ": ", packedT, "s (",
    nimT / max(packedT, 1e-9), "x; ",
    scalarT / max(packedT, 1e-9), "x vs scalar)"
  sbuf.destroy()
  pbuf.destroy()
