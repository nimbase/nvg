## Generic-op blend tail emitters for the x64 row kernels.
##
## One emitter per comp op, shared by all paint-shape builders: each
## generic builder sequences its own paint-eval head, calls the runtime
## dispatcher below, then emits its loop epilogue. Previously this file
## was an `include` fragment expanded once per (shape, op) pair (104
## expansions); now each op tail expands once (13 total). Emitted kernel
## bytes are unchanged (same emit calls in the same order; the extra
## call runs once per kernel build, never per pixel).
##
## Entry contract (produced by the builder's generic head):
## - xmm0/1/2 = straight CLAMPED paint r/g/b
## - xmm10 = sa (coverage-scaled source alpha)
## - r10 = dst cursor, r9 = div-table
## - xmm4/5/6/7 = c255/zero/one/half, xmm8 = x (preserved)
## Frame is 192 bytes; rgb spills to `[rsp+128/136/144]`, the 1e-6
## threshold (bit pattern via `movabs`, matching `blendPixel`'s
## `ao <= 1e-6`) to `[rsp+176]` by the builder prologue (it cannot live
## at 152: the non-sep Bout triple overwrites that slot per pixel).
## Non-separable tails (Hue..Luminosity) also use W3C Lum weights at
## `[rsp+96/104/112]` (spilled per row, per pixel for bilinear whose
## taps own that range during the head), scratch `[rsp+120]`, and the
## Bout triple at `[rsp+152/160/168]` (bilinear thresholds there are
## dead past geneval).
## Clobbers xmm0/1/2/3/9/11, eax/ecx/edx, flags. Preserves xmm4-8,
## xmm10, r8-r12. Op order replicates `surface.blendPixel` exactly
## (finite colors only, as elsewhere).

import dynasm
import ./types

proc emitBlendTailX64Static*(op: static CompOp, a: var Assembler) =
  ## Emit the blend tail for one static `op` into `a`. One instantiation
  ## per op (13 total across all builders).
  # --- A: da -> xmm3, ao -> xmm11 (exact scalar order per op) ---
  when op == coSourceIn:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8] # da
      movsd xmm11, xmm10
      mulsd xmm11, xmm3 # sa*da
  elif op == coSourceOut:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm9, xmm6 # one
      subsd xmm9, xmm3 # 1-da
      movsd xmm11, xmm10
      mulsd xmm11, xmm9 # sa*(1-da)
  elif op == coAtop:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm3 # da
  elif op == coDestinationOver:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10 # sa
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm9, xmm3 # da*(1-sa)
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coDestinationIn:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm3
      mulsd xmm11, xmm10 # da*sa
  elif op == coDestinationOut:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      movsd xmm11, xmm3
      mulsd xmm11, xmm9 # da*(1-sa)
  elif op == coDestinationAtop:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10 # sa
  elif op == coLighter:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      addsd xmm11, xmm3 # sa+da
      minpd xmm11, xmm6 # min(1, sa+da), finite-only like the scalar min
  elif op == coCopy:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10 # sa
  elif op == coXor:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      addsd xmm11, xmm3 # sa+da
      movsd xmm9, xmm10
      addsd xmm9, xmm9 # 2*sa, exact like 2.0*sa
      mulsd xmm9, xmm3 # 2*sa*da
      subsd xmm11, xmm9
  elif op == coMultiply:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coScreen:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9
  elif op == coOverlay:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9
  elif op == coDarken:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coLighten:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coColorDodge:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coColorBurn:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coHardLight:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coSoftLight:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coDifference:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coExclusion:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coHue:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coSaturation:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coColor:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  elif op == coLuminosity:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 3]
      movsd xmm3, [r9 + rdx*8]
      movsd xmm11, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      addsd xmm11, xmm9 # sa + da*(1-sa)
  else:
    {.error: "blend tail: sourceOver uses the dedicated fast path".}

  # --- B: ao threshold branch + rgb spill (shared) ---
  dynasm a:
    arch x64
    movsd xmm9, [rsp + 176] # 1e-6
    ucomisd xmm11, xmm9
    jbe fwd("pxzero") # ao <= 1e-6 -> transparent black
    movsd [rsp + 128], xmm0 # spill clamped paint rgb
    movsd [rsp + 136], xmm1
    movsd [rsp + 144], xmm2

  # --- NS: non-separable Bout triple to [rsp+152/160/168] ---
  # Hue/Saturation/Color/Luminosity blend the full Cs/Cb vectors
  # (W3C SetSat/SetLum/ClipColor, Lum = 0.3R+0.59G+0.11B with weights
  # spilled per row at [rsp+96/104/112]), then the C sections composite
  # per channel like the separable ops. [rsp+120] is scratch (free in
  # all Gen frames; bilinear taps are dead past geneval). xmm3 (da)
  # and xmm11 (ao) are live into C and preserved. Finite colors only.
  when op == coHue:
    dynasm a:
      arch x64
      # satCb -> xmm9 (Cb loads; max3/min3 need no stores)
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8] # dr
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8] # dg
      movzx edx, byte [r10 + 2]
      movsd xmm2, [r9 + rdx*8] # db
      movsd xmm9, xmm0
      maxpd xmm9, xmm1
      maxpd xmm9, xmm2 # cmaxCb
      minpd xmm0, xmm1
      minpd xmm0, xmm2 # cminCb
      subsd xmm9, xmm0 # satCb
      # scmin -> xmm1 (persistent through setSat)
      movsd xmm1, [rsp + 128]
      minsd xmm1, [rsp + 136]
      minsd xmm1, [rsp + 144]
      # scmax == scmin? (gray source -> st = black)
      movsd xmm0, [rsp + 128]
      maxsd xmm0, [rsp + 136]
      maxsd xmm0, [rsp + 144]
      ucomisd xmm0, xmm1
      je fwd("nshueZero")
      # R: st_r -> [rsp + 152]
      movsd xmm0, [rsp + 128]
      maxsd xmm0, [rsp + 136]
      maxsd xmm0, [rsp + 144] # scmax
      movsd xmm2, [rsp + 128] # csr
      ucomisd xmm2, xmm0 # ch == cmax?
      je fwd("nshueRmax")
      ucomisd xmm2, xmm1 # ch == cmin?
      je fwd("nshueRmin")
      subsd xmm2, xmm1 # ch-cmin
      mulsd xmm2, xmm9 # *s
      subsd xmm0, xmm1 # denom
      divsd xmm2, xmm0 # ((ch-cmin)*s)/(cmax-cmin)
      jmp fwd("nshueRdone")
      label nshueRmax
      movsd xmm2, xmm9 # s
      jmp fwd("nshueRdone")
      label nshueRmin
      movsd xmm2, xmm5 # 0
      label nshueRdone
      movsd [rsp + 152], xmm2
      # G: st_g -> [rsp + 160]
      movsd xmm0, [rsp + 128]
      maxsd xmm0, [rsp + 136]
      maxsd xmm0, [rsp + 144]
      movsd xmm2, [rsp + 136] # csg
      ucomisd xmm2, xmm0
      je fwd("nshueGmax")
      ucomisd xmm2, xmm1
      je fwd("nshueGmin")
      subsd xmm2, xmm1
      mulsd xmm2, xmm9
      subsd xmm0, xmm1
      divsd xmm2, xmm0
      jmp fwd("nshueGdone")
      label nshueGmax
      movsd xmm2, xmm9
      jmp fwd("nshueGdone")
      label nshueGmin
      movsd xmm2, xmm5
      label nshueGdone
      movsd [rsp + 160], xmm2
      # B: st_b -> [rsp + 168]
      movsd xmm0, [rsp + 128]
      maxsd xmm0, [rsp + 136]
      maxsd xmm0, [rsp + 144]
      movsd xmm2, [rsp + 144] # csb
      ucomisd xmm2, xmm0
      je fwd("nshueBmax")
      ucomisd xmm2, xmm1
      je fwd("nshueBmin")
      subsd xmm2, xmm1
      mulsd xmm2, xmm9
      subsd xmm0, xmm1
      divsd xmm2, xmm0
      jmp fwd("nshueBdone")
      label nshueBmax
      movsd xmm2, xmm9
      jmp fwd("nshueBdone")
      label nshueBmin
      movsd xmm2, xmm5
      label nshueBdone
      movsd [rsp + 168], xmm2
      jmp fwd("nshueLum")
      label nshueZero
      movsd [rsp + 152], xmm5
      movsd [rsp + 160], xmm5
      movsd [rsp + 168], xmm5
      label nshueLum
      # lumCb -> park [rsp + 120]
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, [rsp + 96]
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1 # lumCb
      movsd [rsp + 120], xmm0 # park l
      # lumSt -> xmm0; d = l - lumSt -> xmm9
      movsd xmm0, [rsp + 152]
      mulsd xmm0, [rsp + 96]
      movsd xmm1, [rsp + 160]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 168]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1 # lumSt
      movsd xmm9, [rsp + 120]
      subsd xmm9, xmm0 # d
      # shift st slots by d
      movsd xmm0, [rsp + 152]
      addsd xmm0, xmm9
      movsd [rsp + 152], xmm0
      movsd xmm0, [rsp + 160]
      addsd xmm0, xmm9
      movsd [rsp + 160], xmm0
      movsd xmm0, [rsp + 168]
      addsd xmm0, xmm9
      movsd [rsp + 168], xmm0
      # n = min3, x = max3 (shifted values)
      movsd xmm0, [rsp + 152]
      minsd xmm0, [rsp + 160]
      minsd xmm0, [rsp + 168] # n
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168] # x
      ucomisd xmm0, xmm5 # n < 0? (NaN takes branch, finite-only)
      jb fwd("nshueAdj1")
      jmp fwd("nshueChk2")
      label nshueAdj1
      movsd xmm2, [rsp + 120]
      subsd xmm2, xmm0 # l-n -> denom xmm2
      movsd xmm1, [rsp + 152]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 152], xmm1
      movsd xmm1, [rsp + 160]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 160], xmm1
      movsd xmm1, [rsp + 168]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 168], xmm1
      label nshueChk2
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168] # x (current values)
      ucomisd xmm1, xmm6 # x > 1?
      ja fwd("nshueAdj2")
      jmp fwd("nshueDone")
      label nshueAdj2
      movsd xmm0, [rsp + 120] # l
      subsd xmm1, xmm0 # x-l -> denom xmm1
      movsd xmm0, xmm6
      subsd xmm0, [rsp + 120] # 1-l -> xmm0
      movsd xmm2, [rsp + 152]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 152], xmm2
      movsd xmm2, [rsp + 160]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 160], xmm2
      movsd xmm2, [rsp + 168]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 168], xmm2
      label nshueDone
  elif op == coSaturation:
    dynasm a:
      arch x64
      # satCs -> xmm9 (Cs spills only)
      movsd xmm0, [rsp + 128]
      maxsd xmm0, [rsp + 136]
      maxsd xmm0, [rsp + 144] # cmaxCs
      movsd xmm1, [rsp + 128]
      minsd xmm1, [rsp + 136]
      minsd xmm1, [rsp + 144] # cminCs
      movsd xmm9, xmm0
      subsd xmm9, xmm1 # satCs
      # Cb triple -> slots (future st home)
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8]
      movsd [rsp + 152], xmm0
      movzx edx, byte [r10 + 1]
      movsd xmm0, [r9 + rdx*8]
      movsd [rsp + 160], xmm0
      movzx edx, byte [r10 + 2]
      movsd xmm0, [r9 + rdx*8]
      movsd [rsp + 168], xmm0
      # cbmin -> xmm1 (persistent through setSat)
      movsd xmm1, [rsp + 152]
      minsd xmm1, [rsp + 160]
      minsd xmm1, [rsp + 168]
      # cbmax == cbmin? (gray backdrop -> st = black)
      movsd xmm0, [rsp + 152]
      maxsd xmm0, [rsp + 160]
      maxsd xmm0, [rsp + 168]
      ucomisd xmm0, xmm1
      je fwd("nssatZero")
      movsd [rsp + 120], xmm0 # park cbmax
      # R: st_r -> [rsp + 152]
      movsd xmm0, [rsp + 120] # cbmax
      movsd xmm2, [rsp + 152] # cbr
      ucomisd xmm2, xmm0
      je fwd("nssatRmax")
      ucomisd xmm2, xmm1
      je fwd("nssatRmin")
      subsd xmm2, xmm1
      mulsd xmm2, xmm9
      subsd xmm0, xmm1
      divsd xmm2, xmm0
      jmp fwd("nssatRdone")
      label nssatRmax
      movsd xmm2, xmm9
      jmp fwd("nssatRdone")
      label nssatRmin
      movsd xmm2, xmm5
      label nssatRdone
      movsd [rsp + 152], xmm2
      # G: st_g -> [rsp + 160]
      movsd xmm0, [rsp + 120]
      movsd xmm2, [rsp + 160] # cbg
      ucomisd xmm2, xmm0
      je fwd("nssatGmax")
      ucomisd xmm2, xmm1
      je fwd("nssatGmin")
      subsd xmm2, xmm1
      mulsd xmm2, xmm9
      subsd xmm0, xmm1
      divsd xmm2, xmm0
      jmp fwd("nssatGdone")
      label nssatGmax
      movsd xmm2, xmm9
      jmp fwd("nssatGdone")
      label nssatGmin
      movsd xmm2, xmm5
      label nssatGdone
      movsd [rsp + 160], xmm2
      # B: st_b -> [rsp + 168]
      movsd xmm0, [rsp + 120]
      movsd xmm2, [rsp + 168] # cbb
      ucomisd xmm2, xmm0
      je fwd("nssatBmax")
      ucomisd xmm2, xmm1
      je fwd("nssatBmin")
      subsd xmm2, xmm1
      mulsd xmm2, xmm9
      subsd xmm0, xmm1
      divsd xmm2, xmm0
      jmp fwd("nssatBdone")
      label nssatBmax
      movsd xmm2, xmm9
      jmp fwd("nssatBdone")
      label nssatBmin
      movsd xmm2, xmm5
      label nssatBdone
      movsd [rsp + 168], xmm2
      jmp fwd("nssatLum")
      label nssatZero
      movsd [rsp + 152], xmm5
      movsd [rsp + 160], xmm5
      movsd [rsp + 168], xmm5
      label nssatLum
      # lumCb (reload Cb; st owns the slots) -> park [rsp + 120]
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, [rsp + 96]
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1
      movsd [rsp + 120], xmm0 # park l
      # lumSt -> xmm0; d = l - lumSt -> xmm9
      movsd xmm0, [rsp + 152]
      mulsd xmm0, [rsp + 96]
      movsd xmm1, [rsp + 160]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 168]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1
      movsd xmm9, [rsp + 120]
      subsd xmm9, xmm0 # d
      # shift st slots by d
      movsd xmm0, [rsp + 152]
      addsd xmm0, xmm9
      movsd [rsp + 152], xmm0
      movsd xmm0, [rsp + 160]
      addsd xmm0, xmm9
      movsd [rsp + 160], xmm0
      movsd xmm0, [rsp + 168]
      addsd xmm0, xmm9
      movsd [rsp + 168], xmm0
      # n = min3, x = max3 (shifted values)
      movsd xmm0, [rsp + 152]
      minsd xmm0, [rsp + 160]
      minsd xmm0, [rsp + 168]
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168]
      ucomisd xmm0, xmm5 # n < 0?
      jb fwd("nssatAdj1")
      jmp fwd("nssatChk2")
      label nssatAdj1
      movsd xmm2, [rsp + 120]
      subsd xmm2, xmm0
      movsd xmm1, [rsp + 152]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 152], xmm1
      movsd xmm1, [rsp + 160]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 160], xmm1
      movsd xmm1, [rsp + 168]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 168], xmm1
      label nssatChk2
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168]
      ucomisd xmm1, xmm6 # x > 1?
      ja fwd("nssatAdj2")
      jmp fwd("nssatDone")
      label nssatAdj2
      movsd xmm0, [rsp + 120]
      subsd xmm1, xmm0
      movsd xmm0, xmm6
      subsd xmm0, [rsp + 120]
      movsd xmm2, [rsp + 152]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 152], xmm2
      movsd xmm2, [rsp + 160]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 160], xmm2
      movsd xmm2, [rsp + 168]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 168], xmm2
      label nssatDone
  elif op == coColor:
    dynasm a:
      arch x64
      # lumCb -> park [rsp + 120]
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, [rsp + 96]
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1
      movsd [rsp + 120], xmm0 # park l
      # st = Cs -> slots
      movsd xmm0, [rsp + 128]
      movsd [rsp + 152], xmm0
      movsd xmm0, [rsp + 136]
      movsd [rsp + 160], xmm0
      movsd xmm0, [rsp + 144]
      movsd [rsp + 168], xmm0
      # lumSt -> xmm0; d = l - lumSt -> xmm9
      movsd xmm0, [rsp + 152]
      mulsd xmm0, [rsp + 96]
      movsd xmm1, [rsp + 160]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 168]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1
      movsd xmm9, [rsp + 120]
      subsd xmm9, xmm0 # d
      # shift st slots by d
      movsd xmm0, [rsp + 152]
      addsd xmm0, xmm9
      movsd [rsp + 152], xmm0
      movsd xmm0, [rsp + 160]
      addsd xmm0, xmm9
      movsd [rsp + 160], xmm0
      movsd xmm0, [rsp + 168]
      addsd xmm0, xmm9
      movsd [rsp + 168], xmm0
      # n = min3, x = max3 (shifted values)
      movsd xmm0, [rsp + 152]
      minsd xmm0, [rsp + 160]
      minsd xmm0, [rsp + 168]
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168]
      ucomisd xmm0, xmm5 # n < 0?
      jb fwd("nscolAdj1")
      jmp fwd("nscolChk2")
      label nscolAdj1
      movsd xmm2, [rsp + 120]
      subsd xmm2, xmm0
      movsd xmm1, [rsp + 152]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 152], xmm1
      movsd xmm1, [rsp + 160]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 160], xmm1
      movsd xmm1, [rsp + 168]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 168], xmm1
      label nscolChk2
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168]
      ucomisd xmm1, xmm6 # x > 1?
      ja fwd("nscolAdj2")
      jmp fwd("nscolDone")
      label nscolAdj2
      movsd xmm0, [rsp + 120]
      subsd xmm1, xmm0
      movsd xmm0, xmm6
      subsd xmm0, [rsp + 120]
      movsd xmm2, [rsp + 152]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 152], xmm2
      movsd xmm2, [rsp + 160]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 160], xmm2
      movsd xmm2, [rsp + 168]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 168], xmm2
      label nscolDone
  elif op == coLuminosity:
    dynasm a:
      arch x64
      # lumCs -> park [rsp + 120]
      movsd xmm0, [rsp + 128]
      mulsd xmm0, [rsp + 96]
      movsd xmm1, [rsp + 136]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 144]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1
      movsd [rsp + 120], xmm0 # park l
      # st = Cb -> slots
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8]
      movsd [rsp + 152], xmm0
      movzx edx, byte [r10 + 1]
      movsd xmm0, [r9 + rdx*8]
      movsd [rsp + 160], xmm0
      movzx edx, byte [r10 + 2]
      movsd xmm0, [r9 + rdx*8]
      movsd [rsp + 168], xmm0
      # lumSt -> xmm0; d = l - lumSt -> xmm9
      movsd xmm0, [rsp + 152]
      mulsd xmm0, [rsp + 96]
      movsd xmm1, [rsp + 160]
      mulsd xmm1, [rsp + 104]
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 168]
      mulsd xmm1, [rsp + 112]
      addsd xmm0, xmm1
      movsd xmm9, [rsp + 120]
      subsd xmm9, xmm0 # d
      # shift st slots by d
      movsd xmm0, [rsp + 152]
      addsd xmm0, xmm9
      movsd [rsp + 152], xmm0
      movsd xmm0, [rsp + 160]
      addsd xmm0, xmm9
      movsd [rsp + 160], xmm0
      movsd xmm0, [rsp + 168]
      addsd xmm0, xmm9
      movsd [rsp + 168], xmm0
      # n = min3, x = max3 (shifted values)
      movsd xmm0, [rsp + 152]
      minsd xmm0, [rsp + 160]
      minsd xmm0, [rsp + 168]
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168]
      ucomisd xmm0, xmm5 # n < 0?
      jb fwd("nslumAdj1")
      jmp fwd("nslumChk2")
      label nslumAdj1
      movsd xmm2, [rsp + 120]
      subsd xmm2, xmm0
      movsd xmm1, [rsp + 152]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 152], xmm1
      movsd xmm1, [rsp + 160]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 160], xmm1
      movsd xmm1, [rsp + 168]
      subsd xmm1, [rsp + 120]
      mulsd xmm1, [rsp + 120]
      divsd xmm1, xmm2
      addsd xmm1, [rsp + 120]
      movsd [rsp + 168], xmm1
      label nslumChk2
      movsd xmm1, [rsp + 152]
      maxsd xmm1, [rsp + 160]
      maxsd xmm1, [rsp + 168]
      ucomisd xmm1, xmm6 # x > 1?
      ja fwd("nslumAdj2")
      jmp fwd("nslumDone")
      label nslumAdj2
      movsd xmm0, [rsp + 120]
      subsd xmm1, xmm0
      movsd xmm0, xmm6
      subsd xmm0, [rsp + 120]
      movsd xmm2, [rsp + 152]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 152], xmm2
      movsd xmm2, [rsp + 160]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 160], xmm2
      movsd xmm2, [rsp + 168]
      subsd xmm2, [rsp + 120]
      mulsd xmm2, xmm0
      divsd xmm2, xmm1
      addsd xmm2, [rsp + 120]
      movsd [rsp + 168], xmm2
      label nslumDone

  # --- C1: R channel (combine per op, then shared div/quant/store) ---
  when op == coSourceIn:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128] # sr
      mulsd xmm0, xmm10 # csr
      mulsd xmm0, xmm3 # csr*da
  elif op == coSourceOut:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm0, xmm9 # csr*(1-da)
  elif op == coAtop:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10 # csr
      mulsd xmm0, xmm3 # csr*da
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8] # dr
      mulsd xmm1, xmm3 # cdr
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm1, xmm9 # cdr*(1-sa)
      addsd xmm0, xmm1
  elif op == coDestinationOver:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10 # csr
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm0, xmm9 # csr*(1-da)
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8] # dr
      mulsd xmm1, xmm3 # cdr
      addsd xmm0, xmm1 # csr*(1-da) + cdr
  elif op == coDestinationIn:
    dynasm a:
      arch x64
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8] # dr
      mulsd xmm0, xmm3 # cdr
      mulsd xmm0, xmm10 # cdr*sa
  elif op == coDestinationOut:
    dynasm a:
      arch x64
      movzx edx, byte [r10]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, xmm3 # cdr
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm0, xmm9 # cdr*(1-sa)
  elif op == coDestinationAtop:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10 # csr
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm0, xmm9 # csr*(1-da)
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3 # cdr
      mulsd xmm1, xmm10 # cdr*sa
      addsd xmm0, xmm1
  elif op == coLighter:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10 # csr
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3 # cdr
      addsd xmm0, xmm1 # csr+cdr
  elif op == coCopy:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10 # csr
  elif op == coXor:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm10 # csr
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm0, xmm9 # csr*(1-da)
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3 # cdr
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm1, xmm9 # cdr*(1-sa)
      addsd xmm0, xmm1
  elif op == coMultiply:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm9, xmm10 # (1-da)*sa
      movsd xmm0, [rsp + 128] # sr
      mulsd xmm0, xmm9 # t1 = ((1-da)*sa)*sr
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm9, xmm3 # (1-sa)*da
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8] # dr
      mulsd xmm1, xmm9 # t2 = ((1-sa)*da)*dr
      addsd xmm0, xmm1 # t1+t2
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 128] # sr
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8] # dr
      mulsd xmm2, xmm9 # Bout = sr*dr
      mulsd xmm1, xmm2 # t3 = (sa*da)*Bout
      addsd xmm0, xmm1 # (t1+t2)+t3
  elif op == coScreen:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9 # t1
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9 # t2
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm2, [r9 + rdx*8] # cb
      movsd xmm9, xmm1
      mulsd xmm9, xmm2 # cs*cb
      addsd xmm1, xmm2 # cs+cb
      subsd xmm1, xmm9 # Bout = (cs+cb)-(cs*cb)
      movsd xmm2, xmm10
      mulsd xmm2, xmm3 # sa*da
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coOverlay:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9 # t1
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9 # t2
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm7 # cb <= 0.5? (half; NaN takes lo, finite-only)
      jbe fwd("ovlRlo")
      movsd xmm9, xmm6
      subsd xmm9, xmm1 # 1-cs
      addsd xmm9, xmm9 # 2*(1-cs), exact
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1 # 2*(1-cs)*(1-cb)
      movsd xmm1, xmm6
      subsd xmm1, xmm9 # Bout = 1-2*(1-cs)*(1-cb)
      jmp fwd("ovlRdone")
      label ovlRlo
      mulsd xmm1, xmm2 # cs*cb
      addsd xmm1, xmm1 # Bout = 2*cs*cb
      label ovlRdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3 # sa*da
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coDarken:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm9, xmm10 # (1-da)*sa
      movsd xmm0, [rsp + 128] # sr
      mulsd xmm0, xmm9 # t1
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm9, xmm3 # (1-sa)*da
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8] # dr
      mulsd xmm1, xmm9 # t2
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 128] # sr
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8] # dr
      minpd xmm2, xmm9 # Bout = min(cs,cb)
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coLighten:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 128]
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8]
      maxpd xmm2, xmm9 # Bout = max(cs,cb)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coColorDodge:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm5 # cs <= 0? (zero; NaN takes div, finite-only)
      jbe fwd("ddgRz")
      ucomisd xmm9, xmm6 # cb >= 1?
      jae fwd("ddgRo")
      movsd xmm2, xmm6
      subsd xmm2, xmm9 # 1-cb
      movsd xmm9, [rsp + 128] # cs
      divsd xmm9, xmm2 # cs/(1-cb)
      minpd xmm9, xmm6 # Bout
      jmp fwd("ddgRdone")
      label ddgRz
      movsd xmm9, xmm5 # Bout = 0
      jmp fwd("ddgRdone")
      label ddgRo
      movsd xmm9, xmm6 # Bout = 1
      label ddgRdone
      mulsd xmm1, xmm9 # t3
      addsd xmm0, xmm1
  elif op == coColorBurn:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm6 # cs >= 1?
      jae fwd("dbrRo")
      ucomisd xmm9, xmm5 # cb <= 0?
      jbe fwd("dbrRz")
      movsd xmm9, xmm6
      subsd xmm9, xmm2 # 1-cs
      movzx edx, byte [r10]
      movsd xmm2, [r9 + rdx*8] # cb
      divsd xmm9, xmm2 # (1-cs)/cb
      minpd xmm9, xmm6
      movsd xmm2, xmm6
      subsd xmm2, xmm9 # Bout
      jmp fwd("dbrRdone")
      label dbrRz
      movsd xmm2, xmm5 # Bout = 0
      jmp fwd("dbrRdone")
      label dbrRo
      movsd xmm2, xmm6 # Bout = 1
      label dbrRdone
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coHardLight:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm1, xmm7 # cs <= 0.5? (half; NaN takes lo, finite-only)
      jbe fwd("hltRlo")
      movsd xmm9, xmm6
      subsd xmm9, xmm1 # 1-cs
      addsd xmm9, xmm9 # 2*(1-cs), exact
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1 # 2*(1-cs)*(1-cb)
      movsd xmm1, xmm6
      subsd xmm1, xmm9 # Bout = 1-2*(1-cs)*(1-cb)
      jmp fwd("hltRdone")
      label hltRlo
      mulsd xmm1, xmm2 # cs*cb
      addsd xmm1, xmm1 # Bout = 2*cs*cb
      label hltRdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3 # sa*da
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coSoftLight:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm1, xmm7 # cs <= 0.5? (half; NaN takes lo, finite-only)
      jbe fwd("sftRlo")
      movsd xmm9, xmm7
      mulsd xmm9, xmm7 # 0.25
      ucomisd xmm2, xmm9 # cb <= 0.25?
      jbe fwd("sftRpoly")
      sqrtsd xmm9, xmm2 # d = sqrt(cb)
      jmp fwd("sftRd")
      label sftRpoly
      movsd xmm9, xmm2
      addsd xmm9, xmm9 # 2cb
      addsd xmm9, xmm9 # 4cb
      movsd xmm1, xmm6
      addsd xmm1, xmm6 # 2
      addsd xmm1, xmm6 # 3
      subsd xmm9, xmm1 # 4cb-3
      addsd xmm9, xmm9 # 8cb-6
      addsd xmm9, xmm9 # 16cb-12
      mulsd xmm9, xmm2 # (16cb-12)*cb
      movsd xmm1, xmm6
      addsd xmm1, xmm1 # 2
      addsd xmm1, xmm1 # 4
      addsd xmm9, xmm1 # +4
      mulsd xmm9, xmm2 # d
      label sftRd
      movsd xmm1, [rsp + 128] # cs
      addsd xmm1, xmm1 # 2cs
      subsd xmm1, xmm6 # 2cs-1
      subsd xmm9, xmm2 # d-cb
      mulsd xmm1, xmm9
      addsd xmm1, xmm2 # Bout = cb+(2cs-1)*(d-cb)
      jmp fwd("sftRdone")
      label sftRlo
      movsd xmm9, xmm6
      subsd xmm9, xmm1
      subsd xmm9, xmm1 # 1-2cs
      mulsd xmm9, xmm2 # *cb
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1
      movsd xmm1, xmm2 # cb
      subsd xmm1, xmm9 # Bout = cb-(1-2cs)*cb*(1-cb)
      label sftRdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3 # sa*da
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coDifference:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8] # cb
      subsd xmm2, xmm9 # cs-cb
      movsd xmm9, xmm5
      subsd xmm9, xmm2 # -(cs-cb)
      maxpd xmm2, xmm9 # Bout = |cs-cb|
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coExclusion:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 128] # cs
      movzx edx, byte [r10]
      movsd xmm9, [r9 + rdx*8] # cb
      addsd xmm2, xmm9 # cs+cb
      mulsd xmm9, [rsp + 128] # cb*cs
      addsd xmm9, xmm9 # 2*cs*cb
      subsd xmm2, xmm9 # Bout
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coHue:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3 # 1-da
      mulsd xmm9, xmm10 # (1-da)*sa
      movsd xmm0, [rsp + 128] # sr
      mulsd xmm0, xmm9 # t1
      movsd xmm9, xmm6
      subsd xmm9, xmm10 # 1-sa
      mulsd xmm9, xmm3 # (1-sa)*da
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8] # dr
      mulsd xmm1, xmm9 # t2
      addsd xmm0, xmm1 # t1+t2
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 152] # br (non-sep triple)
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coSaturation:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 152]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coColor:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 152]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coLuminosity:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 128]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 152]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  dynasm a:
    arch x64
    divsd xmm0, xmm11 # cor/ao
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10], dl

  # --- C2: G channel ---
  when op == coSourceIn:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136] # sg
      mulsd xmm0, xmm10
      mulsd xmm0, xmm3
  elif op == coSourceOut:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
  elif op == coAtop:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
      mulsd xmm0, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
  elif op == coDestinationOver:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      addsd xmm0, xmm1
  elif op == coDestinationIn:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 1]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, xmm3
      mulsd xmm0, xmm10
  elif op == coDestinationOut:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 1]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, xmm3
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm0, xmm9
  elif op == coDestinationAtop:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      mulsd xmm1, xmm10
      addsd xmm0, xmm1
  elif op == coLighter:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      addsd xmm0, xmm1
  elif op == coCopy:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
  elif op == coXor:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
  elif op == coMultiply:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 136]
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8]
      mulsd xmm2, xmm9
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coScreen:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 136]
      movzx edx, byte [r10 + 1]
      movsd xmm2, [r9 + rdx*8]
      movsd xmm9, xmm1
      mulsd xmm9, xmm2
      addsd xmm1, xmm2
      subsd xmm1, xmm9
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coOverlay:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 136]
      movzx edx, byte [r10 + 1]
      movsd xmm2, [r9 + rdx*8]
      ucomisd xmm2, xmm7
      jbe fwd("ovlGlo")
      movsd xmm9, xmm6
      subsd xmm9, xmm1
      addsd xmm9, xmm9
      movsd xmm1, xmm6
      subsd xmm1, xmm2
      mulsd xmm9, xmm1
      movsd xmm1, xmm6
      subsd xmm1, xmm9
      jmp fwd("ovlGdone")
      label ovlGlo
      mulsd xmm1, xmm2
      addsd xmm1, xmm1
      label ovlGdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coDarken:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 136]
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8]
      minpd xmm2, xmm9 # Bout = min(cs,cb)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coLighten:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 136]
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8]
      maxpd xmm2, xmm9 # Bout = max(cs,cb)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coColorDodge:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 136] # cs
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm5 # cs <= 0?
      jbe fwd("ddgGz")
      ucomisd xmm9, xmm6 # cb >= 1?
      jae fwd("ddgGo")
      movsd xmm2, xmm6
      subsd xmm2, xmm9 # 1-cb
      movsd xmm9, [rsp + 136] # cs
      divsd xmm9, xmm2 # cs/(1-cb)
      minpd xmm9, xmm6 # Bout
      jmp fwd("ddgGdone")
      label ddgGz
      movsd xmm9, xmm5 # Bout = 0
      jmp fwd("ddgGdone")
      label ddgGo
      movsd xmm9, xmm6 # Bout = 1
      label ddgGdone
      mulsd xmm1, xmm9 # t3
      addsd xmm0, xmm1
  elif op == coColorBurn:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 136] # cs
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm6 # cs >= 1?
      jae fwd("dbrGo")
      ucomisd xmm9, xmm5 # cb <= 0?
      jbe fwd("dbrGz")
      movsd xmm9, xmm6
      subsd xmm9, xmm2 # 1-cs
      movzx edx, byte [r10 + 1]
      movsd xmm2, [r9 + rdx*8] # cb
      divsd xmm9, xmm2 # (1-cs)/cb
      minpd xmm9, xmm6
      movsd xmm2, xmm6
      subsd xmm2, xmm9 # Bout
      jmp fwd("dbrGdone")
      label dbrGz
      movsd xmm2, xmm5 # Bout = 0
      jmp fwd("dbrGdone")
      label dbrGo
      movsd xmm2, xmm6 # Bout = 1
      label dbrGdone
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coHardLight:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 136] # cs
      movzx edx, byte [r10 + 1]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm1, xmm7 # cs <= 0.5?
      jbe fwd("hltGlo")
      movsd xmm9, xmm6
      subsd xmm9, xmm1 # 1-cs
      addsd xmm9, xmm9 # 2*(1-cs), exact
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1
      movsd xmm1, xmm6
      subsd xmm1, xmm9 # Bout = 1-2*(1-cs)*(1-cb)
      jmp fwd("hltGdone")
      label hltGlo
      mulsd xmm1, xmm2
      addsd xmm1, xmm1 # Bout = 2*cs*cb
      label hltGdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coSoftLight:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 136] # cs
      movzx edx, byte [r10 + 1]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm1, xmm7 # cs <= 0.5?
      jbe fwd("sftGlo")
      movsd xmm9, xmm7
      mulsd xmm9, xmm7 # 0.25
      ucomisd xmm2, xmm9 # cb <= 0.25?
      jbe fwd("sftGpoly")
      sqrtsd xmm9, xmm2 # d = sqrt(cb)
      jmp fwd("sftGd")
      label sftGpoly
      movsd xmm9, xmm2
      addsd xmm9, xmm9 # 2cb
      addsd xmm9, xmm9 # 4cb
      movsd xmm1, xmm6
      addsd xmm1, xmm6 # 2
      addsd xmm1, xmm6 # 3
      subsd xmm9, xmm1 # 4cb-3
      addsd xmm9, xmm9 # 8cb-6
      addsd xmm9, xmm9 # 16cb-12
      mulsd xmm9, xmm2 # (16cb-12)*cb
      movsd xmm1, xmm6
      addsd xmm1, xmm1 # 2
      addsd xmm1, xmm1 # 4
      addsd xmm9, xmm1 # +4
      mulsd xmm9, xmm2 # d
      label sftGd
      movsd xmm1, [rsp + 136] # cs
      addsd xmm1, xmm1 # 2cs
      subsd xmm1, xmm6 # 2cs-1
      subsd xmm9, xmm2 # d-cb
      mulsd xmm1, xmm9
      addsd xmm1, xmm2 # Bout = cb+(2cs-1)*(d-cb)
      jmp fwd("sftGdone")
      label sftGlo
      movsd xmm9, xmm6
      subsd xmm9, xmm1
      subsd xmm9, xmm1 # 1-2cs
      mulsd xmm9, xmm2 # *cb
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1
      movsd xmm1, xmm2 # cb
      subsd xmm1, xmm9 # Bout = cb-(1-2cs)*cb*(1-cb)
      label sftGdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coDifference:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 136] # cs
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8] # cb
      subsd xmm2, xmm9 # cs-cb
      movsd xmm9, xmm5
      subsd xmm9, xmm2 # -(cs-cb)
      maxpd xmm2, xmm9 # Bout = |cs-cb|
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coExclusion:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 136] # cs
      movzx edx, byte [r10 + 1]
      movsd xmm9, [r9 + rdx*8] # cb
      addsd xmm2, xmm9 # cs+cb
      mulsd xmm9, [rsp + 136] # cb*cs
      addsd xmm9, xmm9 # 2*cs*cb
      subsd xmm2, xmm9 # Bout
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coHue:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 160] # bg (non-sep triple)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coSaturation:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 160]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coColor:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 160]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coLuminosity:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 136]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 1]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 160]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  dynasm a:
    arch x64
    divsd xmm0, xmm11
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 1], dl

  # --- C3: B channel ---
  when op == coSourceIn:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144] # sb
      mulsd xmm0, xmm10
      mulsd xmm0, xmm3
  elif op == coSourceOut:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
  elif op == coAtop:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
      mulsd xmm0, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
  elif op == coDestinationOver:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      addsd xmm0, xmm1
  elif op == coDestinationIn:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 2]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, xmm3
      mulsd xmm0, xmm10
  elif op == coDestinationOut:
    dynasm a:
      arch x64
      movzx edx, byte [r10 + 2]
      movsd xmm0, [r9 + rdx*8]
      mulsd xmm0, xmm3
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm0, xmm9
  elif op == coDestinationAtop:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      mulsd xmm1, xmm10
      addsd xmm0, xmm1
  elif op == coLighter:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      addsd xmm0, xmm1
  elif op == coCopy:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
  elif op == coXor:
    dynasm a:
      arch x64
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm10
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm0, xmm9
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm3
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
  elif op == coMultiply:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 144]
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8]
      mulsd xmm2, xmm9
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coScreen:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 144]
      movzx edx, byte [r10 + 2]
      movsd xmm2, [r9 + rdx*8]
      movsd xmm9, xmm1
      mulsd xmm9, xmm2
      addsd xmm1, xmm2
      subsd xmm1, xmm9
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coOverlay:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 144]
      movzx edx, byte [r10 + 2]
      movsd xmm2, [r9 + rdx*8]
      ucomisd xmm2, xmm7
      jbe fwd("ovlBlo")
      movsd xmm9, xmm6
      subsd xmm9, xmm1
      addsd xmm9, xmm9
      movsd xmm1, xmm6
      subsd xmm1, xmm2
      mulsd xmm9, xmm1
      movsd xmm1, xmm6
      subsd xmm1, xmm9
      jmp fwd("ovlBdone")
      label ovlBlo
      mulsd xmm1, xmm2
      addsd xmm1, xmm1
      label ovlBdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coDarken:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 144]
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8]
      minpd xmm2, xmm9 # Bout = min(cs,cb)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coLighten:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 144]
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8]
      maxpd xmm2, xmm9 # Bout = max(cs,cb)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coColorDodge:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 144] # cs
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm5 # cs <= 0?
      jbe fwd("ddgBz")
      ucomisd xmm9, xmm6 # cb >= 1?
      jae fwd("ddgBo")
      movsd xmm2, xmm6
      subsd xmm2, xmm9 # 1-cb
      movsd xmm9, [rsp + 144] # cs
      divsd xmm9, xmm2 # cs/(1-cb)
      minpd xmm9, xmm6 # Bout
      jmp fwd("ddgBdone")
      label ddgBz
      movsd xmm9, xmm5 # Bout = 0
      jmp fwd("ddgBdone")
      label ddgBo
      movsd xmm9, xmm6 # Bout = 1
      label ddgBdone
      mulsd xmm1, xmm9 # t3
      addsd xmm0, xmm1
  elif op == coColorBurn:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 144] # cs
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8] # cb
      ucomisd xmm2, xmm6 # cs >= 1?
      jae fwd("dbrBo")
      ucomisd xmm9, xmm5 # cb <= 0?
      jbe fwd("dbrBz")
      movsd xmm9, xmm6
      subsd xmm9, xmm2 # 1-cs
      movzx edx, byte [r10 + 2]
      movsd xmm2, [r9 + rdx*8] # cb
      divsd xmm9, xmm2 # (1-cs)/cb
      minpd xmm9, xmm6
      movsd xmm2, xmm6
      subsd xmm2, xmm9 # Bout
      jmp fwd("dbrBdone")
      label dbrBz
      movsd xmm2, xmm5 # Bout = 0
      jmp fwd("dbrBdone")
      label dbrBo
      movsd xmm2, xmm6 # Bout = 1
      label dbrBdone
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coHardLight:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 144] # cs
      movzx edx, byte [r10 + 2]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm1, xmm7 # cs <= 0.5?
      jbe fwd("hltBlo")
      movsd xmm9, xmm6
      subsd xmm9, xmm1 # 1-cs
      addsd xmm9, xmm9 # 2*(1-cs), exact
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1
      movsd xmm1, xmm6
      subsd xmm1, xmm9 # Bout = 1-2*(1-cs)*(1-cb)
      jmp fwd("hltBdone")
      label hltBlo
      mulsd xmm1, xmm2
      addsd xmm1, xmm1 # Bout = 2*cs*cb
      label hltBdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coSoftLight:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, [rsp + 144] # cs
      movzx edx, byte [r10 + 2]
      movsd xmm2, [r9 + rdx*8] # cb
      ucomisd xmm1, xmm7 # cs <= 0.5?
      jbe fwd("sftBlo")
      movsd xmm9, xmm7
      mulsd xmm9, xmm7 # 0.25
      ucomisd xmm2, xmm9 # cb <= 0.25?
      jbe fwd("sftBpoly")
      sqrtsd xmm9, xmm2 # d = sqrt(cb)
      jmp fwd("sftBd")
      label sftBpoly
      movsd xmm9, xmm2
      addsd xmm9, xmm9 # 2cb
      addsd xmm9, xmm9 # 4cb
      movsd xmm1, xmm6
      addsd xmm1, xmm6 # 2
      addsd xmm1, xmm6 # 3
      subsd xmm9, xmm1 # 4cb-3
      addsd xmm9, xmm9 # 8cb-6
      addsd xmm9, xmm9 # 16cb-12
      mulsd xmm9, xmm2 # (16cb-12)*cb
      movsd xmm1, xmm6
      addsd xmm1, xmm1 # 2
      addsd xmm1, xmm1 # 4
      addsd xmm9, xmm1 # +4
      mulsd xmm9, xmm2 # d
      label sftBd
      movsd xmm1, [rsp + 144] # cs
      addsd xmm1, xmm1 # 2cs
      subsd xmm1, xmm6 # 2cs-1
      subsd xmm9, xmm2 # d-cb
      mulsd xmm1, xmm9
      addsd xmm1, xmm2 # Bout = cb+(2cs-1)*(d-cb)
      jmp fwd("sftBdone")
      label sftBlo
      movsd xmm9, xmm6
      subsd xmm9, xmm1
      subsd xmm9, xmm1 # 1-2cs
      mulsd xmm9, xmm2 # *cb
      movsd xmm1, xmm6
      subsd xmm1, xmm2 # 1-cb
      mulsd xmm9, xmm1
      movsd xmm1, xmm2 # cb
      subsd xmm1, xmm9 # Bout = cb-(1-2cs)*cb*(1-cb)
      label sftBdone
      movsd xmm2, xmm10
      mulsd xmm2, xmm3
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coDifference:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 144] # cs
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8] # cb
      subsd xmm2, xmm9 # cs-cb
      movsd xmm9, xmm5
      subsd xmm9, xmm2 # -(cs-cb)
      maxpd xmm2, xmm9 # Bout = |cs-cb|
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coExclusion:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3 # sa*da
      movsd xmm2, [rsp + 144] # cs
      movzx edx, byte [r10 + 2]
      movsd xmm9, [r9 + rdx*8] # cb
      addsd xmm2, xmm9 # cs+cb
      mulsd xmm9, [rsp + 144] # cb*cs
      addsd xmm9, xmm9 # 2*cs*cb
      subsd xmm2, xmm9 # Bout
      mulsd xmm1, xmm2 # t3
      addsd xmm0, xmm1
  elif op == coHue:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 168] # bb (non-sep triple)
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coSaturation:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 168]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coColor:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 168]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  elif op == coLuminosity:
    dynasm a:
      arch x64
      movsd xmm9, xmm6
      subsd xmm9, xmm3
      mulsd xmm9, xmm10
      movsd xmm0, [rsp + 144]
      mulsd xmm0, xmm9
      movsd xmm9, xmm6
      subsd xmm9, xmm10
      mulsd xmm9, xmm3
      movzx edx, byte [r10 + 2]
      movsd xmm1, [r9 + rdx*8]
      mulsd xmm1, xmm9
      addsd xmm0, xmm1
      movsd xmm1, xmm10
      mulsd xmm1, xmm3
      movsd xmm2, [rsp + 168]
      mulsd xmm1, xmm2
      addsd xmm0, xmm1
  dynasm a:
    arch x64
    divsd xmm0, xmm11
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 2], dl

  # --- C4: A channel (shared: output alpha is ao itself) ---
  dynasm a:
    arch x64
    movsd xmm0, xmm11 # ao
    maxpd xmm0, xmm5
    minpd xmm0, xmm6
    mulsd xmm0, xmm4
    addsd xmm0, xmm7
    cvttsd2si edx, xmm0
    mov byte [r10 + 3], dl

  # --- D: pixel done / zero (shared) ---
  dynasm a:
    arch x64
    jmp fwd("pxdone")
    label pxzero
    `xor` edx, edx
    mov dword [r10], edx # transparent black, like the scalar ao branch
    label pxdone

proc emitBlendTailX64*(op: CompOp, a: var Assembler) =
  ## Runtime-op dispatcher for the tail emitter. Runs once per kernel
  ## build (the emitted bytes are identical to the old per-builder
  ## inlining); `coSourceOver` keeps its dedicated fast path.
  case op
  of coSourceOver:
    raise newException(Defect,
      "emitBlendTailX64: sourceOver uses the dedicated fast path")
  of coSourceIn: emitBlendTailX64Static(coSourceIn, a)
  of coSourceOut: emitBlendTailX64Static(coSourceOut, a)
  of coAtop: emitBlendTailX64Static(coAtop, a)
  of coDestinationOver: emitBlendTailX64Static(coDestinationOver, a)
  of coDestinationIn: emitBlendTailX64Static(coDestinationIn, a)
  of coDestinationOut: emitBlendTailX64Static(coDestinationOut, a)
  of coDestinationAtop: emitBlendTailX64Static(coDestinationAtop, a)
  of coLighter: emitBlendTailX64Static(coLighter, a)
  of coCopy: emitBlendTailX64Static(coCopy, a)
  of coXor: emitBlendTailX64Static(coXor, a)
  of coMultiply: emitBlendTailX64Static(coMultiply, a)
  of coScreen: emitBlendTailX64Static(coScreen, a)
  of coOverlay: emitBlendTailX64Static(coOverlay, a)
  of coDarken: emitBlendTailX64Static(coDarken, a)
  of coLighten: emitBlendTailX64Static(coLighten, a)
  of coColorDodge: emitBlendTailX64Static(coColorDodge, a)
  of coColorBurn: emitBlendTailX64Static(coColorBurn, a)
  of coHardLight: emitBlendTailX64Static(coHardLight, a)
  of coSoftLight: emitBlendTailX64Static(coSoftLight, a)
  of coDifference: emitBlendTailX64Static(coDifference, a)
  of coExclusion: emitBlendTailX64Static(coExclusion, a)
  of coHue: emitBlendTailX64Static(coHue, a)
  of coSaturation: emitBlendTailX64Static(coSaturation, a)
  of coColor: emitBlendTailX64Static(coColor, a)
  of coLuminosity: emitBlendTailX64Static(coLuminosity, a)
