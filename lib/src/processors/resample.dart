import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// High-quality image downscaling used by the PNG/JPEG fallback path.
///
/// Uses a separable Lanczos3 filter whose support widens with the scale
/// factor (as Pillow does), so large downscales are antialiased in a single
/// pass instead of aliasing. Work happens in linear light with premultiplied
/// alpha, which avoids darkened edges and colour fringes around transparent
/// regions.
img.Image resizeHighQuality(img.Image src, int width, int height) {
  if (width == src.width && height == src.height) return src;
  final hasAlpha = src.hasAlpha;
  var data = _toLinearPremultiplied(src);
  data = _resampleHorizontal(data, src.width, src.height, width);
  data = _resampleVertical(data, width, src.height, height);
  return _fromLinearPremultiplied(data, width, height, hasAlpha: hasAlpha);
}

/// Drops the alpha channel if every pixel is fully opaque, which makes PNGs
/// noticeably smaller.
img.Image dropOpaqueAlpha(img.Image image) {
  if (!image.hasAlpha) return image;
  for (final p in image) {
    if (p.aNormalized < 1) return image;
  }
  return image.convert(numChannels: 3);
}

const _lobes = 3;

double _sinc(double x) {
  if (x == 0) return 1;
  x *= math.pi;
  return math.sin(x) / x;
}

double _lanczos(double x) => x.abs() < _lobes ? _sinc(x) * _sinc(x / _lobes) : 0;

/// Per output pixel: first source index and normalised weights.
({Int32List starts, List<Float64List> weights}) _coefficients(int inSize, int outSize) {
  final scale = inSize / outSize;
  final filterScale = math.max(scale, 1.0);
  final support = _lobes * filterScale;
  final starts = Int32List(outSize);
  final weights = <Float64List>[];
  for (var i = 0; i < outSize; i++) {
    final center = (i + 0.5) * scale;
    final start = math.max(0, (center - support).floor());
    final end = math.min(inSize, (center + support).ceil());
    final w = Float64List(end - start);
    var sum = 0.0;
    for (var j = start; j < end; j++) {
      final v = _lanczos((j + 0.5 - center) / filterScale);
      w[j - start] = v;
      sum += v;
    }
    if (sum != 0) {
      for (var k = 0; k < w.length; k++) {
        w[k] /= sum;
      }
    }
    starts[i] = start;
    weights.add(w);
  }
  return (starts: starts, weights: weights);
}

Float32List _resampleHorizontal(Float32List src, int w, int h, int outW) {
  if (outW == w) return src;
  final c = _coefficients(w, outW);
  final out = Float32List(outW * h * 4);
  for (var y = 0; y < h; y++) {
    final row = y * w * 4;
    for (var x = 0; x < outW; x++) {
      final weights = c.weights[x];
      var i = row + c.starts[x] * 4;
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var k = 0; k < weights.length; k++, i += 4) {
        final wt = weights[k];
        r += src[i] * wt;
        g += src[i + 1] * wt;
        b += src[i + 2] * wt;
        a += src[i + 3] * wt;
      }
      final o = (y * outW + x) * 4;
      out[o] = r;
      out[o + 1] = g;
      out[o + 2] = b;
      out[o + 3] = a;
    }
  }
  return out;
}

Float32List _resampleVertical(Float32List src, int w, int h, int outH) {
  if (outH == h) return src;
  final c = _coefficients(h, outH);
  final out = Float32List(w * outH * 4);
  final stride = w * 4;
  for (var y = 0; y < outH; y++) {
    final weights = c.weights[y];
    final start = c.starts[y];
    for (var x = 0; x < w; x++) {
      var i = start * stride + x * 4;
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var k = 0; k < weights.length; k++, i += stride) {
        final wt = weights[k];
        r += src[i] * wt;
        g += src[i + 1] * wt;
        b += src[i + 2] * wt;
        a += src[i + 3] * wt;
      }
      final o = (y * w + x) * 4;
      out[o] = r;
      out[o + 1] = g;
      out[o + 2] = b;
      out[o + 3] = a;
    }
  }
  return out;
}

double _srgbToLinear(double v) =>
    v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _linearToSrgb(double v) => v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;

final _linearLut = Float32List.fromList([for (var i = 0; i < 256; i++) _srgbToLinear(i / 255)]);

Float32List _toLinearPremultiplied(img.Image src) {
  final out = Float32List(src.width * src.height * 4);
  final eightBit = src.maxChannelValue == 255 && !src.hasPalette;
  var o = 0;
  for (final p in src) {
    final a = src.hasAlpha ? p.aNormalized.toDouble() : 1.0;
    final r = eightBit ? _linearLut[p.r.toInt()] : _srgbToLinear(p.rNormalized.toDouble());
    final g = eightBit ? _linearLut[p.g.toInt()] : _srgbToLinear(p.gNormalized.toDouble());
    final b = eightBit ? _linearLut[p.b.toInt()] : _srgbToLinear(p.bNormalized.toDouble());
    out[o++] = r * a;
    out[o++] = g * a;
    out[o++] = b * a;
    out[o++] = a;
  }
  return out;
}

int _to8bit(double v) => (v.clamp(0.0, 1.0) * 255 + 0.5).floor();

img.Image _fromLinearPremultiplied(Float32List data, int w, int h, {required bool hasAlpha}) {
  final out = img.Image(width: w, height: h, numChannels: hasAlpha ? 4 : 3);
  var i = 0;
  for (final p in out) {
    final a = data[i + 3].clamp(0.0, 1.0);
    // Decide transparency on the 8-bit value: filter ringing leaves tiny
    // alphas that round to 0, and their leftover colours would be invisible
    // noise that hurts PNG compression.
    final a8 = hasAlpha ? _to8bit(a) : 255;
    if (a8 == 0) {
      p.setRgba(0, 0, 0, 0);
    } else {
      p
        ..r = _to8bit(_linearToSrgb(data[i] / a))
        ..g = _to8bit(_linearToSrgb(data[i + 1] / a))
        ..b = _to8bit(_linearToSrgb(data[i + 2] / a));
      if (hasAlpha) p.a = a8;
    }
    i += 4;
  }
  return out;
}
