switch("path", "$projectDir/../src")
if projectName() in ["jit", "text"]:
  switch("define", "nvgJit")
