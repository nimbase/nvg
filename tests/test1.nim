# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest

import nvg

test "canvas clears to the requested color":
  let c = newCanvas(8, 8)
  c.clear(rgb(255, 255, 255))
  let p = c.surface.getPixel(4, 4)
  check abs(p.r - 1.0) < 0.01
  check abs(p.g - 1.0) < 0.01
