import 'dart:convert';
import 'dart:io';

import 'package:asset_kit/src/config.dart';
import 'package:asset_kit/src/logger.dart';
import 'package:asset_kit/src/processors/cwebp.dart';
import 'package:asset_kit/src/processors/optimizer.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/source_images.dart';

void main() {
  group('outputExtension', () {
    test('webp with cwebp', () {
      for (final ext in ['.png', '.jpg', '.webp']) {
        expect(outputExtension(ext, ImageFormat.webp, cwebpAvailable: true), '.webp');
      }
    });
    test('webp without cwebp: PNG, but JPEG photos stay JPEG', () {
      expect(outputExtension('.png', ImageFormat.webp, cwebpAvailable: false), '.png');
      expect(outputExtension('.webp', ImageFormat.webp, cwebpAvailable: false), '.png');
      expect(outputExtension('.jpg', ImageFormat.webp, cwebpAvailable: false), '.jpg');
      expect(outputExtension('.JPEG', ImageFormat.webp, cwebpAvailable: false), '.jpeg');
    });
    test('png and keep', () {
      expect(outputExtension('.jpg', ImageFormat.png, cwebpAvailable: true), '.png');
      expect(outputExtension('.jpg', ImageFormat.keep, cwebpAvailable: true), '.jpg');
      expect(outputExtension('.webp', ImageFormat.keep, cwebpAvailable: true), '.webp');
      expect(outputExtension('.webp', ImageFormat.keep, cwebpAvailable: false), '.png');
    });
  });

  late Directory tmp;
  late Cwebp? cwebp;
  setUpAll(() async => cwebp = await Cwebp.detect());
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('asset_kit_opt');
    writeDemoSources(p.join(tmp.path, 'assets_src'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  AssetKitConfig config([String yaml = '']) => AssetKitConfig.parse(yaml, projectRoot: tmp.path);
  final quiet = Logger(ansi: false, out: StringBuffer(), err: StringBuffer());

  Future<OptimizeReport> optimize({
    String yaml = '',
    bool webp = true,
    OptimizeOptions options = const OptimizeOptions(),
  }) => Optimizer(config(yaml), quiet, options: options, cwebp: webp ? cwebp : null).run();

  File out(String rel) => File(p.join(tmp.path, 'assets', rel));
  (int, int) size(String rel) {
    final image = img.decodeImage(out(rel).readAsBytesSync())!;
    return (image.width, image.height);
  }

  FileReport reportFor(OptimizeReport r, String source) =>
      r.files.firstWhere((f) => f.source == source);

  group('with cwebp', () {
    test('writes resolution-aware WebP variants', () async {
      final report = await optimize();
      expect(report.hasErrors, isFalse);
      expect(size('images/hero.webp'), (400, 300));
      expect(size('images/2.0x/hero.webp'), (800, 600));
      expect(size('images/3.0x/hero.webp'), (1200, 900));
      expect(reportFor(report, 'images/hero.jpg').outputs, [
        'assets/images/hero.webp',
        'assets/images/2.0x/hero.webp',
        'assets/images/3.0x/hero.webp',
      ]);
    }, skip: _noCwebp());

    test('@Nx suffix sets the source scale and is dropped from the name', () async {
      await optimize();
      expect(size('images/banner.webp'), (200, 50));
      expect(size('images/3.0x/banner.webp'), (600, 150));
      expect(out('images/banner@4x.webp').existsSync(), isFalse);
    }, skip: _noCwebp());

    test('never upscales and reports the skipped scale', () async {
      final report = await optimize();
      expect(size('images/small.webp'), (50, 50));
      expect(size('images/2.0x/small.webp'), (100, 100));
      expect(out('images/3.0x/small.webp').existsSync(), isFalse);
      expect(reportFor(report, 'images/small@2x.png').skippedScales, [3.0]);
    }, skip: _noCwebp());

    test('applies EXIF orientation before cwebp', () async {
      await optimize();
      expect(size('images/3.0x/camera_photo.webp'), (300, 400));
      expect(size('images/camera_photo.webp'), (100, 133));
    }, skip: _noCwebp());

    test('keeps transparency', () async {
      await optimize();
      final logo = img.decodeImage(out('images/logo.webp').readAsBytesSync())!;
      expect(logo.hasAlpha, isTrue);
      expect(logo.getPixel(0, 0).a, 0);
      expect(logo.getPixel(50, 50).a, 255);
    }, skip: _noCwebp());

    test('lossless_for patterns produce lossless WebP', () async {
      await optimize(yaml: 'images: {lossless_for: ["*.icon.png"]}');
      final bytes = out('icons/3.0x/home.icon.webp').readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(12, 16)), anyOf('VP8L', 'VP8X'));
      expect(latin1.decode(bytes, allowInvalid: true), contains('VP8L'));
      final lossy = latin1.decode(
        out('images/3.0x/logo.webp').readAsBytesSync(),
        allowInvalid: true,
      );
      expect(lossy, isNot(contains('VP8L')));
    }, skip: _noCwebp());

    test('strips metadata', () async {
      await optimize();
      final bytes = latin1.decode(
        out('images/3.0x/camera_photo.webp').readAsBytesSync(),
        allowInvalid: true,
      );
      expect(bytes, isNot(contains('EXIF')));
      expect(bytes, isNot(contains('Exif')));
    }, skip: _noCwebp());

    test('folder_scales applies per folder', () async {
      await optimize(yaml: 'folder_scales: {images: 1}');
      // hero.jpg is now a 1x original: only the 1x variant, at full size.
      expect(size('images/hero.webp'), (1200, 900));
      expect(out('images/2.0x/hero.webp').existsSync(), isFalse);
      // The @4x suffix still wins over the folder setting.
      expect(size('images/banner.webp'), (200, 50));
    }, skip: _noCwebp());

    test('makes the bundle smaller', () async {
      final report = await optimize();
      final images = report.processed.where((f) => f.source.endsWith('.jpg'));
      for (final f in images) {
        expect(f.outputSize, lessThan(f.sourceSize), reason: f.source);
      }
    }, skip: _noCwebp());
  });

  group('without cwebp (fallback)', () {
    test('writes PNG, and JPEG for JPEG sources', () async {
      final report = await optimize(webp: false);
      expect(report.hasErrors, isFalse);
      expect(size('images/logo.png'), (100, 100));
      expect(size('images/3.0x/logo.png'), (300, 300));
      expect(size('images/hero.jpg'), (400, 300));
      expect(size('images/3.0x/camera_photo.jpg'), (300, 400));
      expect(report.encoder, 'built-in PNG encoder');
    });

    test('PNG output keeps transparency', () async {
      await optimize(webp: false);
      final logo = img.decodePng(out('images/logo.png').readAsBytesSync())!;
      expect(logo.getPixel(0, 0).a, 0);
      expect(logo.getPixel(50, 50).a, 255);
    });

    test('format: png forces PNG even with cwebp', () async {
      await optimize(yaml: 'images: {format: png}');
      expect(out('images/hero.png').existsSync(), isTrue);
    });
  });

  group('SVG, fonts and other files', () {
    test('SVGs are optimized and copied without scale variants', () async {
      await optimize(webp: false);
      final svg = out('icons/home.svg').readAsStringSync();
      expect(svg, isNot(contains('inkscape')));
      expect(
        Directory(
          p.join(tmp.path, 'assets', 'icons', '2.0x'),
        ).listSync().any((e) => e.path.endsWith('.svg')),
        isFalse,
      );
    });

    test('svg.optimize: false copies SVGs verbatim', () async {
      await optimize(yaml: 'svg: {optimize: false}', webp: false);
      expect(out('icons/home.svg').readAsStringSync(), inkscapeSvg);
    });

    test('fonts and other files are copied unchanged', () async {
      await optimize(webp: false);
      expect(out('fonts/Cairo-Bold.ttf').lengthSync(), 2048);
      expect(out('data/config.json').readAsStringSync(), '{"a": 1}');
    });

    test(
      'precompile without vector_graphics_compiler is skipped, then retried once added',
      () async {
        final first = await optimize(
          webp: false,
          options: const OptimizeOptions(precompileSvg: true),
        );
        expect(first.hasErrors, isFalse);
        expect(out('icons/home.vec').existsSync(), isFalse);
        // Simulate adding the dependency: the SVG must not count as cached.
        File(p.join(tmp.path, '.dart_tool', 'package_config.json'))
          ..parent.createSync()
          ..writeAsStringSync('{"packages": [{"name": "vector_graphics_compiler"}]}');
        final planned = await optimize(
          webp: false,
          options: const OptimizeOptions(precompileSvg: true, dryRun: true),
        );
        final svg = planned.files.firstWhere((f) => f.source == 'icons/home.svg');
        expect(svg.status, FileStatus.planned);
        expect(svg.outputs, ['assets/icons/home.svg', 'assets/icons/home.vec']);
      },
    );

    test('invalid SVG is copied with a warning instead of failing', () async {
      File(
        p.join(tmp.path, 'assets_src', 'icons', 'broken.svg'),
      ).writeAsStringSync('<svg><g></svg>');
      final report = await optimize(webp: false);
      expect(report.hasErrors, isFalse);
      expect(out('icons/broken.svg').readAsStringSync(), '<svg><g></svg>');
    });
  });

  group('incremental builds', () {
    test('second run is fully cached', () async {
      await optimize(webp: false);
      final again = await optimize(webp: false);
      expect(again.processed, isEmpty);
      expect(again.cached.length, again.files.length);
    });

    test('changing a source reprocesses only that file', () async {
      await optimize(webp: false);
      File(
        p.join(tmp.path, 'assets_src', 'images', 'logo.png'),
      ).writeAsBytesSync(img.encodePng(transparentLogo(270)));
      final again = await optimize(webp: false);
      expect(again.processed.map((f) => f.source), ['images/logo.png']);
      expect(size('images/logo.png'), (90, 90));
    });

    test('changing quality reprocesses only lossy outputs', () async {
      await optimize(webp: false);
      final again = await optimize(yaml: 'images: {quality: 50}', webp: false);
      // In fallback mode JPEG sources are the only lossy outputs.
      expect(
        again.processed.map((f) => f.source),
        unorderedEquals(['images/camera_photo.jpg', 'images/hero.jpg']),
      );
    });

    test('changing scales reprocesses rasters but not SVGs or copies', () async {
      await optimize(webp: false);
      final again = await optimize(yaml: 'scales: [1, 2]', webp: false);
      final redone = again.processed.map((f) => f.source).toSet();
      expect(redone, contains('images/logo.png'));
      expect(redone, isNot(contains('icons/home.svg')));
      expect(redone, isNot(contains('data/config.json')));
      expect(out('images/3.0x/logo.png').existsSync(), isFalse);
    });

    test('a deleted output is regenerated', () async {
      await optimize(webp: false);
      out('images/2.0x/logo.png').deleteSync();
      final again = await optimize(webp: false);
      expect(again.processed.map((f) => f.source), ['images/logo.png']);
      expect(out('images/2.0x/logo.png').existsSync(), isTrue);
    });

    test('--force reprocesses everything', () async {
      await optimize(webp: false);
      final again = await optimize(webp: false, options: const OptimizeOptions(force: true));
      expect(again.cached, isEmpty);
    });

    test('removing a source removes its outputs and empty folders', () async {
      await optimize(webp: false);
      File(p.join(tmp.path, 'assets_src', 'images', 'small@2x.png')).deleteSync();
      final again = await optimize(webp: false);
      expect(again.removedStale, ['assets/images/2.0x/small.png', 'assets/images/small.png']);
      expect(out('images/small.png').existsSync(), isFalse);
    });

    test('changing the output format removes the old-format files', () async {
      await optimize(webp: false);
      await optimize(yaml: 'images: {format: png}', webp: false);
      expect(out('images/hero.jpg').existsSync(), isFalse);
      expect(out('images/hero.png').existsSync(), isTrue);
    });

    test('files it did not create are never deleted', () async {
      Directory(p.join(tmp.path, 'assets', 'images')).createSync(recursive: true);
      out('images/handmade.png').writeAsBytesSync([1, 2, 3]);
      await optimize(webp: false);
      File(p.join(tmp.path, 'assets_src', 'images', 'logo.png')).deleteSync();
      await optimize(webp: false);
      expect(out('images/handmade.png').existsSync(), isTrue);
    });
  });

  test('two sources writing the same output both fail, and old outputs survive', () async {
    await optimize(webp: false);
    File(
      p.join(tmp.path, 'assets_src', 'images', 'logo.jpg'),
    ).writeAsBytesSync(img.encodeJpg(photo(30, 30)));
    // logo.png → logo.png and logo.jpg → logo.jpg don't clash in fallback
    // mode, so force a clash with format: png.
    final report = await optimize(yaml: 'images: {format: png}', webp: false);
    final failed = report.files.where((f) => f.status == FileStatus.failed).map((f) => f.source);
    expect(failed, unorderedEquals(['images/logo.jpg', 'images/logo.png']));
    expect(report.hasErrors, isTrue);
    expect(out('images/logo.png').existsSync(), isTrue);
  });

  test('unreadable images fail without stopping the rest', () async {
    File(p.join(tmp.path, 'assets_src', 'images', 'corrupt.png')).writeAsStringSync('not a png');
    final report = await optimize(webp: false);
    expect(
      report.files.firstWhere((f) => f.source == 'images/corrupt.png').status,
      FileStatus.failed,
    );
    expect(out('images/logo.png').existsSync(), isTrue);
  });

  test('dry run writes nothing', () async {
    final report = await optimize(webp: false, options: const OptimizeOptions(dryRun: true));
    expect(Directory(p.join(tmp.path, 'assets')).existsSync(), isFalse);
    expect(Directory(p.join(tmp.path, '.asset_kit')).existsSync(), isFalse);
    expect(report.files.every((f) => f.status == FileStatus.planned), isTrue);
    expect(report.files.firstWhere((f) => f.source == 'images/logo.png').outputs, hasLength(3));
  });

  test('files inside a scale folder in the source are skipped', () async {
    File(p.join(tmp.path, 'assets_src', 'images', '2.0x', 'x.png'))
      ..parent.createSync()
      ..writeAsBytesSync(img.encodePng(photo(10, 10)));
    final report = await optimize(webp: false);
    expect(report.files.map((f) => f.source), isNot(contains('images/2.0x/x.png')));
  });
}

Object _noCwebp() =>
    Process.runSync('which', ['cwebp']).exitCode == 0 ? false : 'cwebp not installed';
