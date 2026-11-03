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
## Frame is 160 bytes; rgb spills to `[rsp+128/136/144]`, the 1e-6
## threshold (bit pattern via `movabs`, matching `blendPixel`'s
## `ao <= 1e-6`) to `[rsp+152]` by the builder prologue.
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
  else:
    {.error: "blend tail: sourceOver uses the dedicated fast path".}

  # --- B: ao threshold branch + rgb spill (shared) ---
  dynasm a:
    arch x64
    movsd xmm9, [rsp + 152] # 1e-6
    ucomisd xmm11, xmm9
    jbe fwd("pxzero") # ao <= 1e-6 -> transparent black
    movsd [rsp + 128], xmm0 # spill clamped paint rgb
    movsd [rsp + 136], xmm1
    movsd [rsp + 144], xmm2

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
  else:
    raise newException(Defect,
      "emitBlendTailX64: scalar-only op has no JIT tail")
