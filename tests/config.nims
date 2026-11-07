switch("path", "$projectDir/../src")
# Only the JIT-comparison suites pay for the Dynasm kernel builders
# (~65 generic instantiations); the rest skip them at compile time.
const jitSuites = ["t_jit", "t_dash", "t_fillrule", "t_multistop"]
if projectName() in jitSuites:
  switch("define", "nvgJit")
# The Metal backend seam (t_metal) is opt-in like the JIT kernels.
const metalSuites = ["t_metal"]
if projectName() in metalSuites:
  switch("define", "nvgMetal")
# The JIT kernels are fixed mul/add/div instruction sequences (never fused).
# Apple Clang fuses scalar a*b+c into FMA by default, which rounds once and
# breaks byte-identity with the kernels on ±1 boundaries. Disable contraction
# on every leg so the scalar oracle stays unfused like the x86/ARM-GCC legs.
switch("passC", "-ffp-contract=off")
