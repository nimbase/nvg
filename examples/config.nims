switch("path", "$projectDir/../src")
if projectName() in ["jit", "text"]:
  switch("define", "nvgJit")
if projectName() in ["gpu"]:
  switch("define", "nvgMetal")
