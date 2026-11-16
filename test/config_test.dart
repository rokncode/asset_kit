import 'dart:io';

import 'package:asset_kit/src/config.dart';
import 'package:asset_kit/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

AssetKitConfig parse(String yaml) => AssetKitConfig.parse(yaml, projectRoot: '/proj');

Matcher throwsConfig(Pattern message) => throwsA(
  isA<ConfigException>()
      .having((e) => e.message, 'message', contains(message))
      .having((e) => e.exitCode, 'exitCode', ExitCode.config),
);

void main() {
  test('the full example config parses', () {
    final cfg = parse('''
source: assets_src
output: assets
source_scale: 3
scales: [1, 2, 3]
images:
  format: webp
  quality: 80
  lossless_for: ["*.icon.png"]
svg:
  optimize: true
fonts:
  register_in_pubspec: true
codegen:
  output: lib/gen/assets.gen.dart
  class_name: Assets
unused:
  scan_dirs: [lib]
  ignore: ["assets/images/onboarding/*"]
''');
    expect(cfg.source, 'assets_src');
    expect(cfg.output, 'assets');
    expect(cfg.sourceScale, 3);
    expect(cfg.scales, [1, 2, 3]);
    expect(cfg.images.format, ImageFormat.webp);
    expect(cfg.images.quality, 80);
    expect(cfg.images.losslessFor, ['*.icon.png']);
    expect(cfg.svg.optimize, isTrue);
    expect(cfg.fonts.registerInPubspec, isTrue);
    expect(cfg.codegen.output, 'lib/gen/assets.gen.dart');
    expect(cfg.codegen.className, 'Assets');
    expect(cfg.unused.scanDirs, ['lib']);
    expect(cfg.unused.ignore, ['assets/images/onboarding/*']);
    expect(cfg.warnings, isEmpty);
    expect(cfg.sourceDir, '/proj/assets_src');
    expect(cfg.codegenOutputFile, '/proj/lib/gen/assets.gen.dart');
  });

  test('the init template parses without warnings', () {
    final cfg = parse(defaultConfigYaml);
    expect(cfg.warnings, isEmpty);
    expect(cfg.unused.ignore, isEmpty);
  });

  test('empty file and missing sections use defaults', () {
    for (final yaml in ['', 'images:', 'source: src']) {
      final cfg = parse(yaml);
      expect(cfg.output, 'assets');
      expect(cfg.scales, [1, 2, 3]);
      expect(cfg.images.quality, 80);
      expect(cfg.codegen.className, 'Assets');
    }
  });

  test('scales are de-duplicated, sorted and accept fractions', () {
    expect(parse('scales: [3, 1, 2, 1.5, 2]').scales, [1, 1.5, 2, 3]);
  });

  test('folder_scales override source_scale by most specific folder', () {
    final cfg = parse('''
source_scale: 3
folder_scales:
  images: 2
  images/hero: 4
''');
    expect(cfg.sourceScaleFor('logo.png'), 3);
    expect(cfg.sourceScaleFor('icons/a.png'), 3);
    expect(cfg.sourceScaleFor('images/a.png'), 2);
    expect(cfg.sourceScaleFor('images/hero/big.png'), 4);
    expect(cfg.sourceScaleFor('images/hero/x/deep.png'), 4);
    expect(cfg.sourceScaleFor('images_old/a.png'), 3);
  });

  test('lossless_for matches file names and relative paths', () {
    final cfg = parse('images: {lossless_for: ["*.icon.png", "icons/**"]}');
    expect(cfg.images.isLossless('images/home.icon.png'), isTrue);
    expect(cfg.images.isLossless('icons/sub/a.png'), isTrue);
    expect(cfg.images.isLossless('images/photo.png'), isFalse);
  });

  test('unused.ignore globs match project-relative paths', () {
    final cfg = parse('unused: {ignore: ["assets/images/onboarding/*"]}');
    expect(cfg.unused.isIgnored('assets/images/onboarding/step_1.webp'), isTrue);
    expect(cfg.unused.isIgnored('assets/images/logo.webp'), isFalse);
  });

  test('codegen.names maps paths to identifiers', () {
    final cfg = parse('codegen:\n  names:\n    images/شعار.webp: logoAr\n    "my dir/x.png": x\n');
    expect(cfg.codegen.names, {'images/شعار.webp': 'logoAr', 'my dir/x.png': 'x'});
  });

  test('unknown keys produce warnings with locations', () {
    final cfg = parse('sorce: x\nimages:\n  qualty: 50\n');
    expect(
      cfg.warnings,
      unorderedEquals([contains('`sorce` (line 1'), contains('`images.qualty` (line 3')]),
    );
  });

  group('rejects invalid values', () {
    final cases = {
      'images: {quality: 101}': '`images.quality` must be an integer from 0 to 100',
      'images: {quality: high}': '`images.quality` must be an integer from 0 to 100',
      'images: {format: avif}': '`images.format` must be one of webp | png | keep',
      'source_scale: 0': '`source_scale` must be a positive number',
      'source_scale: three': '`source_scale` must be a positive number',
      'scales: []': '`scales` must be a non-empty list',
      'scales: [2, 3]': '`scales` must include 1',
      'scales: [1, -2]': '`scales` must be a positive number',
      'svg: {optimize: yes please}': '`svg.optimize` must be true or false',
      'codegen: {class_name: assets}': '`codegen.class_name` must be an UpperCamelCase',
      'codegen: {output: lib/assets.txt}': '`codegen.output` must be a .dart file',
      'codegen: {names: {a.png: Logo}}':
          '`codegen.names.a.png` must be a lowerCamelCase Dart identifier',
      'codegen: {names: {a.png: class}}': 'that is not a reserved word',
      'codegen: {names: [a]}': 'Expected `codegen.names` to be a map',
      'unused: {scan_dirs: lib}': '`unused.scan_dirs` must be a list of strings',
      'unused: {ignore: ["[oops"]}': 'Invalid glob pattern',
      'source: assets': '`source` and `output` must be different',
      'source: assets/src': 'must not be nested',
      'images: [1, 2]': 'Expected `images` to be a map',
      '- just a list': 'Expected config root to be a map',
      'source: [unclosed': 'Invalid YAML',
    };
    cases.forEach((yaml, message) {
      test(yaml, () => expect(() => parse(yaml), throwsConfig(message)));
    });
  });

  test('error messages include the line number', () {
    expect(
      () => parse('output: assets\nimages:\n  quality: 500\n'),
      throwsConfig('(line 3, column 12)'),
    );
  });

  group('load', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('asset_kit_cfg'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('falls back to defaults when asset_kit.yaml is missing', () {
      final cfg = AssetKitConfig.load(workingDir: tmp.path);
      expect(cfg.loadedFromFile, isFalse);
      expect(cfg.projectRoot, p.normalize(tmp.path));
    });

    test('an explicit --config that does not exist is an error', () {
      expect(
        () => AssetKitConfig.load(configPath: 'nope.yaml', workingDir: tmp.path),
        throwsConfig('Config file not found'),
      );
    });

    test('paths resolve relative to the config file', () {
      Directory(p.join(tmp.path, 'app')).createSync();
      File(p.join(tmp.path, 'app', 'kit.yaml')).writeAsStringSync('output: out');
      final cfg = AssetKitConfig.load(configPath: 'app/kit.yaml', workingDir: tmp.path);
      expect(cfg.outputDir, p.join(tmp.path, 'app', 'out'));
      expect(cfg.loadedFromFile, isTrue);
    });
  });
}
