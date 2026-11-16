import 'package:asset_kit/src/scale.dart';
import 'package:test/test.dart';

void main() {
  group('parseScaleSuffix', () {
    test('extracts integer and fractional scales', () {
      expect(parseScaleSuffix('logo@3x.png'), (name: 'logo.png', scale: 3.0));
      expect(parseScaleSuffix('logo@1.5x.png'), (name: 'logo.png', scale: 1.5));
      expect(parseScaleSuffix('hero.banner@4x.jpg'), (name: 'hero.banner.jpg', scale: 4.0));
    });

    test('leaves names without a suffix alone', () {
      expect(parseScaleSuffix('logo.png'), (name: 'logo.png', scale: null));
      expect(parseScaleSuffix('logo@x.png'), (name: 'logo@x.png', scale: null));
      expect(parseScaleSuffix('me@home.png'), (name: 'me@home.png', scale: null));
    });
  });

  test('variantDirName', () {
    expect(variantDirName(2), '2.0x');
    expect(variantDirName(3), '3.0x');
    expect(variantDirName(1.5), '1.5x');
  });

  test('variantPath', () {
    expect(variantPath('assets/images/logo.webp', 1), 'assets/images/logo.webp');
    expect(variantPath('assets/images/logo.webp', 2), 'assets/images/2.0x/logo.webp');
    expect(variantPath('logo.webp', 3), '3.0x/logo.webp');
  });

  group('variantDirPattern', () {
    test('matches Flutter variant folders only', () {
      for (final name in ['2.0x', '3.0x', '1.5x', '2x']) {
        expect(variantDirPattern.hasMatch(name), isTrue, reason: name);
      }
      for (final name in ['x', 'images', '2.0', 'x2', '2.0xl']) {
        expect(variantDirPattern.hasMatch(name), isFalse, reason: name);
      }
    });
  });

  group('planVariants', () {
    test('downscales a 3x source to 1x/2x/3x', () {
      final plan = planVariants(width: 300, height: 150, sourceScale: 3, scales: [1, 2, 3]);
      expect(plan.variants, [
        (scale: 1.0, width: 100, height: 50),
        (scale: 2.0, width: 200, height: 100),
        (scale: 3.0, width: 300, height: 150),
      ]);
      expect(plan.skipped, isEmpty);
    });

    test('never upscales', () {
      final plan = planVariants(width: 200, height: 200, sourceScale: 2, scales: [1, 2, 3]);
      expect(plan.variants.map((v) => v.scale), [1, 2]);
      expect(plan.skipped, [3]);
    });

    test('rounds to the nearest pixel', () {
      final plan = planVariants(width: 100, height: 101, sourceScale: 3, scales: [1, 2]);
      expect(plan.variants[0], (scale: 1.0, width: 33, height: 34));
      expect(plan.variants[1], (scale: 2.0, width: 67, height: 67));
    });

    test('supports fractional scales and 4x sources', () {
      final plan = planVariants(width: 400, height: 400, sourceScale: 4, scales: [1, 1.5, 3]);
      expect(plan.variants.map((v) => v.width), [100, 150, 300]);
    });

    test('never produces zero-size images', () {
      final plan = planVariants(width: 1, height: 2, sourceScale: 3, scales: [1]);
      expect(plan.variants.single, (scale: 1.0, width: 1, height: 1));
    });

    test('rejects a non-positive source scale', () {
      expect(
        () => planVariants(width: 1, height: 1, sourceScale: 0, scales: [1]),
        throwsArgumentError,
      );
    });
  });
}
