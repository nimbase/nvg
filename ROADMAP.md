# nvg Roadmap

Source of truth for what's next. The `README.md` checklist mirrors the
headlines here; this file carries scope and acceptance criteria.

Principle: scalar-first. CPU/JIT byte-identical for finite colors; GPU
tiers are 1 LSB for paints, separable blends and Porter-Duff, 2 LSB for
non-separable blends. Metal is the accelerator, scalar is the reference.
Local testing only (CI skipped).

## Near-term (small, well-scoped)

### 1. Harfnim follow-ups
Follow-ups carried over from shaping work: joiner retention in `removeX9`,
a logical-runs API, bracket-63 abort semantics, the implicit-level cap,
and the vertical-origin TODO (`src/harfnim/shape.nim:124`).
- Scope: harfnim repo (bidi/shaping), plus `visualRuns` integration in nvg
  where behavior changes.
- Acceptance: unit tests per fix; nvg serial suite stays 20/20.

### 2. Dominant-color extraction (`dominantColors`) — shipped
New backend-agnostic `Surface` proc returning the N predominant colors of
a picture, e.g. `proc dominantColors*(s: Surface, n: int): seq[Color]`.
- Algorithm (deterministic, no floats needed): quantized RGB
  histogram (5 bits/channel, 32768 bins), skip fully transparent pixels,
  weight by alpha, sort by count then packed bin key for tie-breaks,
  return bin centroids as opaque colors.
- Edge cases: `n <= 0` returns empty; `n` larger than the unique count
  returns the unique set; flat images return one color.
- Acceptance: hand-computed tests (two-color split, tie-break order,
  transparency ignored, `n` clamping); `--palette N` flag on
  `examples/effects.nim` printing hex swatches.
- No GPU mirror needed (analysis op, not a pixel op); CPU-only.

### 3. Flex column (vertical distribution + line gap)
Mirror of the flex-row slice in `layoutBoxOpts`: block-axis `FlexJustify`
distribution plus an inter-line gap.
- Acceptance: hand-computed layout tests; serial suite stays green.
- Explicitly deferred to item 7: `order`, `flex-shrink`, wrapping.

### 4. Metal `close` lifetime (`src/nvg/metal.nim:26`)
Today `close` must be called manually (`defer` in tests); there is no
`=destroy` hook yet.
- Acceptance: deterministic cleanup, double-close safe, no leak in tests.

### 5. Scalar timing probe for fBm filters (`tests/bench/`, gitignored)
One `cpuTime()` loop over the lemons photo per filter, same pattern as
`examples/jit.nim:35`, printing ms per filter.
- Purpose: confirm everything except `turbulence`/`domainWarp` is
  noise-floor; if fBm is hot *and* a real-time non-Metal use case needs
  it, prefer algorithmic fixes (fewer octaves, half-res field +
  bilinear upsample, frame caching for video) over JIT asm.
- No parity risk: scalar stays the single implementation.

## Mid-term

### 6. AArch64 kernel execution sign-off
Run the serial suite on Apple Silicon; confirm JIT + Metal parity.
Acceptance: recorded device + OS + pass log.

### 7. SVG image loading
No decoder in the workspace today, so the first decision is a
dependency one (vendored micro-parser vs external lib).
- Acceptance: `images.nim`-style example plus decode tests; document
  the supported subset (paths/shapes first, no script/animation).

### 8. Flex completeness (`order`, `flex-shrink`, wrapping)
The v1-excluded flex features, one slice each, parent-driven like rows.
Acceptance: hand-computed tests per slice.

## Blocked / out of scope (listed so nobody re-proposes)

- Liang hyphenation: no pattern data or verified license offline.
- Full `BidiTest.txt` conformance: curated subset only, by decision.
- JIT-kernelized filters: won't help. Filter passes are memory-bound
  (~10 ops/px); the one compute-heavy case (4-octave fBm) needs
  libm-exact transcendentals where fast approximations break the 1-2
  LSB parity tiers. Metal compute is the fast path.
