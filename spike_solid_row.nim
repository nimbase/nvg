# spike_solid_row.nim — Phase 0a: scalar solid+sourceOver row kernel.
#
# No library wiring: validates Dynasm codegen shape, ABI, const handling,
# and byte-identity vs surface.blendPixel before any backend work.
#
# Run (correctness): nim c -r --path:src --path:../dynasm/src spike_solid_row.nim
# Run (timing):      nim c -r -d:release --path:src --path:../dynasm/src spike_solid_row.nim
#
# Kernel ABI (both arches): (dst: pointer, n: int64, params: pointer) {.cdecl.}
# params = ptr to 9 float64: srSa, sgSa, sbSa, sa, inv, 255.0, 0.5, 0.0, 1.0
# baked by the host in Nim doubles, so src*sa rounding matches blendPixel.
# Finite-colors-only guarantee: NaN inputs may clamp differently than the
# scalar path (branchless max/min vs `clamp01` branches). Caller colors are
# always finite; documented, not handled.

import dynasm
import nvg/types
import nvg/surface
import std/[times, random]

type SolidRowFn = proc(dst: pointer, n: int64, params: pointer) {.cdecl.}

const NParams = 9

proc bakeParams(src: Color): array[NParams, float64] =
  let s = clamp01(src.a)
  [src.r * s, src.g * s, src.b * s, s, 1.0 - s, 255.0, 0.5, 0.0, 1.0]

proc buildSolidRowX64(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias dst, rdi, rcx
    alias n, rsi, rdx
    alias params, rdx, r8
    mov r10, dst
    mov r11, n
    mov r9, params
    # Early-out when sa <= 0 (matches blendPixel's `if sa <= 0: return`).
    movsd xmm0, [r9 + 24]
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe fwd("done")
    cmp r11, 0
    jle fwd("done")
    label pixel
    # R
    movzx eax, byte [r10]
    cvtsi2sd xmm0, eax
    divsd xmm0, [r9 + 40] # /255: division matches Nim's `byte / 255.0`
    mulsd xmm0, [r9 + 32] # *inv
    addsd xmm0, [r9 + 0]  # +srSa (baked by host)
    movsd xmm5, [r9 + 56] # 0.0
    maxpd xmm0, xmm5      # low lane only; high lane garbage is harmless
    movsd xmm5, [r9 + 64] # 1.0
    minpd xmm0, xmm5
    mulsd xmm0, [r9 + 40] # *255
    addsd xmm0, [r9 + 48] # +0.5
    cvttsd2si eax, xmm0   # truncates like Nim's uint8(float) for >= 0
    mov byte [r10], al
    # G
    movzx eax, byte [r10 + 1]
    cvtsi2sd xmm0, eax
    divsd xmm0, [r9 + 40]
    mulsd xmm0, [r9 + 32]
    addsd xmm0, [r9 + 8]
    movsd xmm5, [r9 + 56]
    maxpd xmm0, xmm5
    movsd xmm5, [r9 + 64]
    minpd xmm0, xmm5
    mulsd xmm0, [r9 + 40]
    addsd xmm0, [r9 + 48]
    cvttsd2si eax, xmm0
    mov byte [r10 + 1], al
    # B
    movzx eax, byte [r10 + 2]
    cvtsi2sd xmm0, eax
    divsd xmm0, [r9 + 40]
    mulsd xmm0, [r9 + 32]
    addsd xmm0, [r9 + 16]
    movsd xmm5, [r9 + 56]
    maxpd xmm0, xmm5
    movsd xmm5, [r9 + 64]
    minpd xmm0, xmm5
    mulsd xmm0, [r9 + 40]
    addsd xmm0, [r9 + 48]
    cvttsd2si eax, xmm0
    mov byte [r10 + 2], al
    # A: sa + da*inv
    movzx eax, byte [r10 + 3]
    cvtsi2sd xmm0, eax
    divsd xmm0, [r9 + 40]
    mulsd xmm0, [r9 + 32]
    addsd xmm0, [r9 + 24]
    movsd xmm5, [r9 + 56]
    maxpd xmm0, xmm5
    movsd xmm5, [r9 + 64]
    minpd xmm0, xmm5
    mulsd xmm0, [r9 + 40]
    addsd xmm0, [r9 + 48]
    cvttsd2si eax, xmm0
    mov byte [r10 + 3], al
    add r10, 4
    sub r11, 1
    cmp r11, 0
    jg bwd("pixel")
    label done
    ret()
  a.finalize()

proc buildSolidRowAarch64(): ExecutableBuffer =
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    mov x9, x0  # cursor
    mov x10, x1 # count
    mov x11, x2 # params
    ldr d6, [x11, 24] # sa
    fcmp d6, 0.0
    b.le fwd("done")
    cbz x10, fwd("done")
    label pixel
    # R
    ldrb w4, [x9]
    scvtf d0, w4
    ldr d1, [x11, 40]
    fdiv d0, d0, d1
    ldr d1, [x11, 32]
    fmul d0, d0, d1
    ldr d1, [x11]
    fadd d0, d0, d1
    ldr d1, [x11, 56]
    fmax d0, d0, d1
    ldr d1, [x11, 64]
    fmin d0, d0, d1
    ldr d1, [x11, 40]
    fmul d0, d0, d1
    ldr d1, [x11, 48]
    fadd d0, d0, d1
    fcvtzs w4, d0
    strb w4, [x9]
    # G
    ldrb w4, [x9, 1]
    scvtf d0, w4
    ldr d1, [x11, 40]
    fdiv d0, d0, d1
    ldr d1, [x11, 32]
    fmul d0, d0, d1
    ldr d1, [x11, 8]
    fadd d0, d0, d1
    ldr d1, [x11, 56]
    fmax d0, d0, d1
    ldr d1, [x11, 64]
    fmin d0, d0, d1
    ldr d1, [x11, 40]
    fmul d0, d0, d1
    ldr d1, [x11, 48]
    fadd d0, d0, d1
    fcvtzs w4, d0
    strb w4, [x9, 1]
    # B
    ldrb w4, [x9, 2]
    scvtf d0, w4
    ldr d1, [x11, 40]
    fdiv d0, d0, d1
    ldr d1, [x11, 32]
    fmul d0, d0, d1
    ldr d1, [x11, 16]
    fadd d0, d0, d1
    ldr d1, [x11, 56]
    fmax d0, d0, d1
    ldr d1, [x11, 64]
    fmin d0, d0, d1
    ldr d1, [x11, 40]
    fmul d0, d0, d1
    ldr d1, [x11, 48]
    fadd d0, d0, d1
    fcvtzs w4, d0
    strb w4, [x9, 2]
    # A
    ldrb w4, [x9, 3]
    scvtf d0, w4
    ldr d1, [x11, 40]
    fdiv d0, d0, d1
    ldr d1, [x11, 32]
    fmul d0, d0, d1
    ldr d1, [x11, 24]
    fadd d0, d0, d1
    ldr d1, [x11, 56]
    fmax d0, d0, d1
    ldr d1, [x11, 64]
    fmin d0, d0, d1
    ldr d1, [x11, 40]
    fmul d0, d0, d1
    ldr d1, [x11, 48]
    fadd d0, d0, d1
    fcvtzs w4, d0
    strb w4, [x9, 3]
    add x9, x9, 4
    sub x10, x10, 1
    cbnz x10, bwd("pixel")
    label done
    ret()
  a.finalize()

proc checkRow(fn: SolidRowFn, src: Color, dst: openArray[uint8]) =
  let n = dst.len div 4
  var params = bakeParams(src)
  var got = newSeq[uint8](dst.len)
  for i, b in dst: got[i] = b
  if n > 0:
    fn(addr got[0], int64(n), addr params[0])
  else:
    fn(nil, 0, addr params[0])
  var surf = newSurface(max(n, 1), 1)
  surf.pixels.setLen(dst.len)
  for i, b in dst: surf.pixels[i] = b
  for x in 0 ..< n:
    surf.blendPixel(x, 0, src, 1.0, coSourceOver)
  assert got == surf.pixels,
    "mismatch src=" & $src & " n=" & $n

when isMainModule:
  randomize(1234)
  var x64buf = buildSolidRowX64()
  echo "x64 kernel: ", x64buf.len, " bytes"
  var a64buf = buildSolidRowAarch64()
  echo "aarch64 kernel assembles: ", a64buf.len, " bytes (bytes only on x64 host)"
  let fn = cast[SolidRowFn](x64buf.ptrAt(AssemblyOffset(0)))

  let srcs = [
    rgbf(1.0, 0.0, 0.0),                    # opaque red
    rgbaf(0.0, 1.0, 0.0, 0.5),              # half green
    rgbaf(0.2, 0.4, 0.8, 0.0),              # transparent: must not touch dst
    rgbaf(0.0, 0.0, 1.0, 1.0),              # opaque blue
    rgbaf(2.0, -0.5, 0.5, 0.75),            # overbright: exercises clamp
    rgbaf(0.33, 0.66, 0.99, 0.01),          # near-zero alpha
  ]
  for src in srcs:
    checkRow(fn, src, [])                   # n = 0
    checkRow(fn, src, [10'u8, 20, 30, 40])  # n = 1
    var r2 = newSeq[uint8](8)
    for i in 0 ..< 8: r2[i] = uint8(rand(256))
    checkRow(fn, src, r2)                   # n = 2, random
    checkRow(fn, src, newSeq[uint8](28))    # n = 7, zeros
    var ff = newSeq[uint8](256)
    for i in 0 ..< 256: ff[i] = 0xFF'u8
    checkRow(fn, src, ff)                   # n = 64, white
    var rr = newSeq[uint8](1024)
    for i in 0 ..< 1024: rr[i] = uint8(rand(256))
    checkRow(fn, src, rr)                   # n = 256, random
  # Exhaustive single-pixel sweep for one src: all 2^32 dst values is too
  # many; sweep each channel over 0..255 with the others fixed instead.
  let sweepSrc = rgbaf(0.5, 0.25, 0.75, 0.6)
  for ch in 0 ..< 4:
    for v in 0 .. 255:
      var px = [128'u8, 64, 32, 200]
      px[ch] = uint8(v)
      checkRow(fn, sweepSrc, px)
  echo "correctness: all rows byte-identical to blendPixel"

  # Timing: fullscreen-ish contiguous run, Nim per-pixel vs JIT per row.
  const W = 800
  const H = 600
  let tsrc = rgbaf(0.8, 0.1, 0.1, 0.9)
  var tparams = bakeParams(tsrc)
  var pristine = newSeq[uint8](W * H * 4)
  for i in 0 ..< pristine.len: pristine[i] = uint8(rand(256))
  const Iters = 20
  var work = newSeq[uint8](pristine.len)
  let t0 = cpuTime()
  for _ in 0 ..< Iters:
    copyMem(addr work[0], addr pristine[0], pristine.len)
    var s = newSurface(W, H)
    copyMem(addr s.pixels[0], addr pristine[0], pristine.len)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.blendPixel(x, y, tsrc, 1.0, coSourceOver)
    copyMem(addr work[0], addr s.pixels[0], pristine.len)
  let nimT = cpuTime() - t0
  let t1 = cpuTime()
  for _ in 0 ..< Iters:
    copyMem(addr work[0], addr pristine[0], pristine.len)
    for y in 0 ..< H:
      let row = cast[pointer](cast[int](addr work[0]) + y * W * 4)
      fn(row, int64(W), addr tparams[0])
  let jitT = cpuTime() - t1
  echo "nim blendPixel 800x600 x", Iters, ": ", nimT, "s"
  echo "jit row kernel 800x600 x", Iters, ": ", jitT, "s"
  echo "speedup: ", nimT / max(jitT, 1e-9), "x"
  x64buf.destroy()
  a64buf.destroy()
