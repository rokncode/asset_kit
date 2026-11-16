import 'package:asset_kit/src/processors/resample.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  test('resizes to the exact requested size', () {
    final src = img.Image(width: 300, height: 101);
    final out = resizeHighQuality(src, 100, 34);
    expect((out.width, out.height), (100, 34));
  });

  test('returns the source untouched when the size is unchanged', () {
    final src = img.Image(width: 10, height: 10);
    expect(identical(resizeHighQuality(src, 10, 10), src), isTrue);
  });

  test('a flat colour stays exactly that colour (no ringing)', () {
    final src = img.Image(width: 90, height: 90)..clear(img.ColorRgb8(200, 30, 90));
    final out = resizeHighQuality(src, 30, 30);
    for (final p in out) {
      expect([p.r, p.g, p.b], [200, 30, 90]);
    }
  });

  test('averages in linear light: black/white checkerboard → ~188, not 128', () {
    final src = img.Image(width: 64, height: 64);
    for (final p in src) {
      final v = (p.x + p.y).isEven ? 255 : 0;
      p.setRgb(v, v, v);
    }
    final out = resizeHighQuality(src, 8, 8);
    final center = out.getPixel(4, 4);
    expect(center.r, inInclusiveRange(180, 195));
  });

  test('premultiplied alpha: no dark fringe around a coloured shape', () {
    // A white square on transparent *black* pixels.
    final src = img.Image(width: 60, height: 60, numChannels: 4);
    img.fillRect(src, x1: 15, y1: 15, x2: 44, y2: 44, color: img.ColorRgba8(255, 255, 255, 255));
    final out = resizeHighQuality(src, 20, 20);
    for (final p in out) {
      if (p.a > 8) {
        expect(
          p.r,
          greaterThan(240),
          reason: 'edge pixel (${p.x},${p.y}) a=${p.a} darkened to ${p.r}',
        );
      }
    }
  });

  test('fully transparent pixels are written as zero', () {
    final src = img.Image(width: 60, height: 60, numChannels: 4);
    img.fillCircle(src, x: 30, y: 30, radius: 10, color: img.ColorRgba8(10, 200, 30, 255));
    final out = resizeHighQuality(src, 20, 20);
    for (final p in out) {
      if (p.a == 0) expect([p.r, p.g, p.b], [0, 0, 0]);
    }
  });

  test('dropOpaqueAlpha removes alpha only when everything is opaque', () {
    final opaque = img.Image(width: 4, height: 4, numChannels: 4)
      ..clear(img.ColorRgba8(1, 2, 3, 255));
    expect(dropOpaqueAlpha(opaque).numChannels, 3);
    final translucent = img.Image(width: 4, height: 4, numChannels: 4)
      ..clear(img.ColorRgba8(1, 2, 3, 254));
    expect(dropOpaqueAlpha(translucent).numChannels, 4);
  });
}
