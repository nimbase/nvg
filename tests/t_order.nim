import std/unittest
import std/json
import nvg

proc px(c: Canvas, x, y: int): tuple[r, g, b, a: uint8] =
  let i = (y * c.width() + x) * 4
  (c.surface.pixels[i], c.surface.pixels[i + 1],
    c.surface.pixels[i + 2], c.surface.pixels[i + 3])

proc animWithRotation(keys: JsonNode): Animation =
  parseAnimation(%*{
    "v": "5", "fr": 30, "ip": 0, "op": 10, "w": 100, "h": 100,
    "layers": [{
      "ind": 1, "ty": 4,
      "ks": {"o": {"a": 0, "k": 100}, "r": {"a": 1, "k": keys}}}]})

test "shapes draw back-to-front, paints style preceding geometry":
  # File order is front-to-back (rlottie keeps model children that way and
  # renders reversed). First rect (purple, small) must cover the second
  # (orange, big); both share one trailing fill each.
  let a = parseAnimation(%*{
    "v": "5", "fr": 30, "ip": 0, "op": 10, "w": 100, "h": 100,
    "layers": [{
      "ind": 1, "ty": 4, "ks": {"o": {"a": 0, "k": 100}},
      "shapes": [
        {"ty": "gr", "it": [
          {"ty": "rc", "p": {"a": 0, "k": [50, 50]},
           "s": {"a": 0, "k": [40, 40]}},
          {"ty": "fl", "c": {"a": 0, "k": [1, 0, 1, 1]},
           "o": {"a": 0, "k": 100}}]},
        {"ty": "gr", "it": [
          {"ty": "rc", "p": {"a": 0, "k": [50, 50]},
           "s": {"a": 0, "k": [90, 90]}},
          {"ty": "fl", "c": {"a": 0, "k": [1, 0.65, 0]},
           "o": {"a": 0, "k": 100}}]}]}]})
  let c = newCanvas(a.w, a.h)
  renderFrame(c, a, 0.0)
  let mid = px(c, 50, 50)
  check mid.r > 200 and mid.g < 100 and mid.b > 200
  let corner = px(c, 8, 8)
  check corner.r > 200 and corner.g > 100 and corner.b < 100

test "s-less keyframes interpolate to the next key, not stepped":
  # rlottie: with no "e" the segment ends at the next key's start value.
  let a = animWithRotation(%*[
    {"t": 0, "s": [0]},
    {"t": 10, "s": [100]}])
  let r = a.layers[0].transform.rotation
  check abs(valueAt(r, 0.0) - 0.0) < 1e-9
  check abs(valueAt(r, 5.0) - 50.0) < 1e-6
  check abs(valueAt(r, 10.0) - 100.0) < 1e-9

test "array-wrapped rotation scalars evaluate":
  let a = animWithRotation(%*[
    {"t": 0, "s": [0]},
    {"t": 10, "s": [90]}])
  check abs(valueAt(a.layers[0].transform.rotation, 10.0) - 90.0) < 1e-9

test "local matrix rotates about the anchor":
  let a = parseAnimation(%*{
    "v": "5", "fr": 30, "ip": 0, "op": 10, "w": 100, "h": 100,
    "layers": [{
      "ind": 1, "ty": 4,
      "ks": {
        "o": {"a": 0, "k": 100},
        "a": {"a": 0, "k": [10, 20]},
        "p": {"a": 0, "k": [10, 20]},
        "r": {"a": 0, "k": 90},
        "s": {"a": 0, "k": [100, 100]}}}]})
  let m = localMatrix(a.layers[0].transform, 0.0)
  let an = vec2(10.0, 20.0)
  let x = m[0] * an.x + m[2] * an.y + m[4]
  let y = m[1] * an.x + m[3] * an.y + m[5]
  check abs(x - 10.0) < 1e-9 and abs(y - 20.0) < 1e-9
