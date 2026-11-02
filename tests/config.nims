switch("path", "$projectDir/../src")
# Only the JIT-comparison suites pay for the Dynasm kernel builders
# (~65 generic instantiations); the rest skip them at compile time.
const jitSuites = ["t_jit", "t_dash", "t_fillrule", "t_multistop"]
if projectName() in jitSuites:
  switch("define", "nvgJit")
