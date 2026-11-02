import std/times
import std/unittest
import nvg

test "large scene renders within budget":
  # Regression guard for the span-fill rasterizer (generous budget:
  # debug builds typically finish in well under a second).
  let t0 = cpuTime()
  let c = newCanvas(800, 600)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.circle(400, 300, 280)
  c.setFillPaint(c.radialGradient(400, 300, 20, 280, rgbf(0.8, 0.1, 0.1),
    rgbf(0.1, 0.1, 0.8)))
  c.fill()
  c.beginPath()
  c.roundedRect(100, 100, 600, 400, 40)
  c.setFillColor(rgbf(0.1, 0.4, 0.1))
  c.fill()
  c.beginPath()
  c.roundedRect(100, 100, 600, 400, 40)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(10.0)
  c.setLineJoin(ljRound)
  c.stroke()
  check cpuTime() - t0 < 8.0
  let t1 = cpuTime()
  let bytes = c.encodePng()
  check cpuTime() - t1 < 8.0
  check bytes.len > 100
  # Flat areas must compress dramatically vs stored deflate (~2MB raw).
  check bytes.len < 200_000

test "encoder output is deterministic":
  let c = newCanvas(64, 64)
  c.clear(rgb(255, 0, 0))
  c.beginPath()
  c.circle(32, 32, 20)
  c.setFillColor(rgbf(0, 0, 1))
  c.fill()
  check c.encodePng() == c.encodePng()

test "deflate shrinks repetitive input, bounds incompressible":
  var rep: seq[uint8] = @[]
  for i in 0 ..< 1000:
    rep.add(uint8(i mod 16))
  check deflateFixed(rep).len < 100
  var seqData: seq[uint8] = @[]
  for i in 0 ..< 2000:
    seqData.add(uint8((i * 7919 + 13) mod 256))
  check deflateFixed(seqData).len < seqData.len + 64
  check deflateFixed([]).len > 0
