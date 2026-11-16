import 'dart:io';

import 'package:asset_kit/src/codegen/assets_generator.dart';
import 'package:asset_kit/src/codegen/format_settings.dart';
import 'package:asset_kit/src/errors.dart';
import 'package:asset_kit/src/processors/fonts.dart';
import 'package:asset_kit/src/scanner/asset_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const fixture = 'test/fixtures/sample_app';

AssetEntry entry(String path) =>
    AssetEntry(path: path, kind: assetKindOf(path), variants: const {});

String gen(List<String> paths, {String className = 'Assets'}) =>
    AssetsGenerator(assetsRoot: 'assets', className: className).generate(paths.map(entry));

void main() {
  group('FormatSettings', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('asset_kit_fmt'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reads the language version and page width of a project', () {
      File(
        p.join(tmp.path, 'pubspec.yaml'),
      ).writeAsStringSync('environment:\n  sdk: ">=3.4.1 <4.0.0"\n');
      File(
        p.join(tmp.path, 'analysis_options.yaml'),
      ).writeAsStringSync('formatter:\n  page_width: 120\n');
      final settings = FormatSettings.forProject(tmp.path);
      expect(settings.languageVersion.toString(), '3.4.0');
      expect(settings.pageWidth, 120);
    });

    test('falls back to defaults when files are missing or odd', () {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('environment: {sdk: any}');
      final settings = FormatSettings.forProject(tmp.path);
      expect(settings.languageVersion, isNull);
      expect(settings.pageWidth, isNull);
    });

    for (final (sdk, style) in [('^3.5.0', 'short'), ('^3.8.0', 'tall')]) {
      test('output matches dart format for an sdk: $sdk project ($style style)', () async {
        File(
          p.join(tmp.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: t\nenvironment:\n  sdk: $sdk\n');
        File(
          p.join(tmp.path, 'analysis_options.yaml'),
        ).writeAsStringSync('formatter:\n  page_width: 60\n');
        final code =
            AssetsGenerator(
              assetsRoot: 'assets',
              formatSettings: FormatSettings.forProject(tmp.path),
            ).generate(
              ['assets/images/a_rather_long_file_name.png', 'assets/images/sub/b.png'].map(entry),
            );
        Directory(p.join(tmp.path, 'lib')).createSync();
        File(p.join(tmp.path, 'lib', 'assets.gen.dart')).writeAsStringSync(code);
        final result = await Process.run('dart', [
          'format',
          '--output=none',
          '--set-exit-if-changed',
          'lib',
        ], workingDirectory: tmp.path);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      });
    }
  });

  group('AssetIndex.scan', () {
    late AssetIndex index;
    setUpAll(() {
      index = AssetIndex.scan(projectRoot: fixture, assetsDir: p.join(fixture, 'assets'));
    });

    test('attaches scale variants to their main asset', () {
      final logo = index.entries.firstWhere((e) => e.path == 'assets/images/logo.webp');
      expect(logo.variants, {
        2.0: 'assets/images/2.0x/logo.webp',
        3.0: 'assets/images/3.0x/logo.webp',
      });
      final step = index.entries.firstWhere((e) => e.path.endsWith('step_1.webp'));
      expect(step.variants, {3.0: 'assets/images/onboarding/3.0x/step_1.webp'});
    });

    test('does not list variant files or hidden files as assets', () {
      final paths = index.entries.map((e) => e.path);
      expect(paths.where((p) => p.contains('2.0x') || p.contains('3.0x')), isEmpty);
      expect(paths.where((p) => p.contains('.DS_Store')), isEmpty);
    });

    test('reports variants without a main asset', () {
      expect(index.orphanVariants, ['assets/images/2.0x/orphan.webp']);
    });

    test('classifies asset kinds', () {
      AssetKind kindOf(String suffix) =>
          index.entries.firstWhere((e) => e.path.endsWith(suffix)).kind;
      expect(kindOf('logo.webp'), AssetKind.image);
      expect(kindOf('home-icon.svg'), AssetKind.svg);
      expect(kindOf('Cairo-Bold.ttf'), AssetKind.font);
      expect(kindOf('config.json'), AssetKind.other);
    });

    test('missing folder gives an empty index', () {
      final empty = AssetIndex.scan(projectRoot: fixture, assetsDir: p.join(fixture, 'nope'));
      expect(empty.entries, isEmpty);
    });
  });

  group('AssetsGenerator', () {
    test('matches the golden output for the fixture project', () {
      final index = AssetIndex.scan(projectRoot: fixture, assetsDir: p.join(fixture, 'assets'));
      final code = AssetsGenerator(
        assetsRoot: 'assets',
        names: {'images/شعار.webp': 'logoAr'},
        fontFamilies: registeredFontFamilies(p.join(fixture, 'pubspec.yaml')),
        formatSettings: FormatSettings.forProject(fixture),
      ).generate(index.entries);
      final golden = File(p.join(fixture, 'lib/gen/assets.gen.dart')).readAsStringSync();
      expect(
        code,
        golden,
        reason: 'Regenerate with: cd $fixture && dart run ../../../bin/asset_kit.dart gen',
      );
    });

    test('produces the documented shape', () {
      final code = gen(['assets/images/logo.webp', 'assets/icons/home.svg']);
      expect(code, startsWith('// GENERATED CODE - DO NOT MODIFY BY HAND\n'));
      expect(code, contains('abstract final class Assets {'));
      expect(code, contains('  static const images = _Images();'));
      expect(code, contains('  static const icons = _Icons();'));
      expect(code, contains('final class _Images {\n  const _Images();\n'));
      expect(code, contains("  final String logo = 'assets/images/logo.webp';"));
    });

    test('nested folders become nested classes', () {
      final code = gen(['assets/images/onboarding/step_1.webp']);
      expect(code, contains('final _ImagesOnboarding onboarding = const _ImagesOnboarding();'));
      expect(code, contains("final String step1 = 'assets/images/onboarding/step_1.webp';"));
    });

    test('files at the assets root become static constants', () {
      final code = gen(['assets/config.json']);
      expect(code, contains("static const String config = 'assets/config.json';"));
    });

    test('same name with different extensions gets the extension appended', () {
      final code = gen([
        'assets/images/logo.png',
        'assets/images/logo.svg',
        'assets/images/logo.webp',
      ]);
      expect(code, contains("logoPng = 'assets/images/logo.png'"));
      expect(code, contains("logoSvg = 'assets/images/logo.svg'"));
      expect(code, contains("logoWebp = 'assets/images/logo.webp'"));
    });

    test('names that normalize to the same identifier are skipped, not numbered', () {
      final generator = AssetsGenerator(assetsRoot: 'assets');
      final code = generator.generate(
        ['assets/i/my-icon.svg', 'assets/i/my_icon.svg', 'assets/i/ok.svg'].map(entry),
      );
      expect(code, isNot(contains('myIcon')));
      expect(code, contains('final String ok ='));
      expect(generator.skipped.map((s) => (s.key, s.reason)), [
        ('i/my-icon.svg', SkipReason.collision),
        ('i/my_icon.svg', SkipReason.collision),
      ]);
      expect(generator.skipped.first.collidesWith, ['i/my_icon.svg']);
    });

    test('adding a file never renames an existing identifier', () {
      final before = gen(['assets/i/my-icon.svg']);
      final after = gen(['assets/i/my-icon.svg', 'assets/i/zzz.svg', 'assets/i/aaa.svg']);
      expect(before, contains("myIcon = 'assets/i/my-icon.svg'"));
      expect(after, contains("myIcon = 'assets/i/my-icon.svg'"));
    });

    test('a file that collides with a folder gets its extension', () {
      final code = gen(['assets/images/flags.webp', 'assets/images/flags/sa.webp']);
      expect(code, contains('final _ImagesFlags flags = const _ImagesFlags();'));
      expect(code, contains("final String flagsWebp = 'assets/images/flags.webp';"));
    });

    test('a precompiled .vec never renames its SVG', () {
      final code = gen(['assets/icons/home.svg', 'assets/icons/home.vec']);
      expect(code, contains("final String home = 'assets/icons/home.svg';"));
      expect(code, contains("final String homeVec = 'assets/icons/home.vec';"));
    });

    test('folders that collide with each other are both skipped', () {
      final generator = AssetsGenerator(assetsRoot: 'assets');
      final code = generator.generate(
        ['assets/on-boarding/a.png', 'assets/on_boarding/b.png'].map(entry),
      );
      expect(code, isNot(contains('onBoarding')));
      expect(generator.skipped.map((s) => s.key), ['on-boarding', 'on_boarding']);
      expect(generator.skipped.every((s) => s.isFolder), isTrue);
    });

    group('names that cannot be converted cleanly', () {
      test('are skipped and reported', () {
        final generator = AssetsGenerator(assetsRoot: 'assets');
        final code = generator.generate(
          [
            'assets/images/شعار.webp',
            'assets/images/logo_شعار.webp',
            'assets/images/café.png',
            'assets/images/ok.png',
          ].map(entry),
        );
        expect(generator.skipped.map((s) => s.key), [
          'images/café.png',
          'images/logo_شعار.webp',
          'images/شعار.webp',
        ]);
        expect(generator.skipped.every((s) => s.reason == SkipReason.unconvertible), isTrue);
        expect(code, contains("final String ok = 'assets/images/ok.png';"));
        expect(code, isNot(contains('شعار')));
      });

      test('Arabic folder names skip the whole folder', () {
        final generator = AssetsGenerator(assetsRoot: 'assets');
        final code = generator.generate(['assets/أعلام/sa.png'].map(entry));
        expect(generator.skipped.single.key, 'أعلام');
        expect(generator.skipped.single.isFolder, isTrue);
        expect(code, isNot(contains('sa.png')));
      });

      test('get the identifier given in codegen.names', () {
        final generator = AssetsGenerator(
          assetsRoot: 'assets',
          names: {'images/شعار.webp': 'logoAr', 'أعلام': 'flags'},
        );
        final code = generator.generate(
          ['assets/images/شعار.webp', 'assets/أعلام/sa.png'].map(entry),
        );
        expect(code, contains("final String logoAr = 'assets/images/شعار.webp';"));
        expect(code, contains('static const flags = _Flags();'));
        expect(code, contains("final String sa = 'assets/أعلام/sa.png';"));
        expect(generator.skipped, isEmpty);
        expect(generator.unusedNames, isEmpty);
      });
    });

    test('codegen.names can resolve a collision and override clean names', () {
      final generator = AssetsGenerator(
        assetsRoot: 'assets',
        names: {'i/my_icon.svg': 'myIconAlt', 'i/ok.svg': 'fine'},
      );
      final code = generator.generate(
        ['assets/i/my-icon.svg', 'assets/i/my_icon.svg', 'assets/i/ok.svg'].map(entry),
      );
      expect(code, contains("myIcon = 'assets/i/my-icon.svg'"));
      expect(code, contains("myIconAlt = 'assets/i/my_icon.svg'"));
      expect(code, contains("fine = 'assets/i/ok.svg'"));
      expect(generator.skipped, isEmpty);
    });

    test('a manual name blocks an automatic name that matches it', () {
      final generator = AssetsGenerator(assetsRoot: 'assets', names: {'i/شعار.png': 'logo'});
      final code = generator.generate(['assets/i/شعار.png', 'assets/i/logo.svg'].map(entry));
      // logo.svg shares the base name, so it gets its extension.
      expect(code, contains("logo = 'assets/i/شعار.png'"));
      expect(code, contains("logoSvg = 'assets/i/logo.svg'"));
    });

    test('two manual names clashing in one folder is a config error', () {
      final generator = AssetsGenerator(
        assetsRoot: 'assets',
        names: {'i/a.png': 'x', 'i/b.png': 'x'},
      );
      expect(
        () => generator.generate(['assets/i/a.png', 'assets/i/b.png'].map(entry)),
        throwsA(isA<ConfigException>()),
      );
    });

    test('reports codegen.names keys that match nothing', () {
      final generator = AssetsGenerator(assetsRoot: 'assets', names: {'images/gone.png': 'gone'});
      generator.generate(['assets/images/a.png'].map(entry));
      expect(generator.unusedNames, ['images/gone.png']);
    });

    test('namesConfigSnippet quotes keys only when needed', () {
      final snippet = namesConfigSnippet([
        SkippedAsset('images/شعار.webp', SkipReason.unconvertible),
        SkippedAsset('images/my logo.png', SkipReason.collision, collidesWith: ['x']),
      ]);
      expect(
        snippet,
        'codegen:\n  names:\n    images/شعار.webp: <name>\n    "images/my logo.png": <name>\n',
      );
    });

    test('custom class name', () {
      expect(gen(['assets/images/a.png'], className: 'R'), contains('abstract final class R {'));
    });

    test('escapes quotes and dollar signs in paths', () {
      final code = gen([r"assets/images/it's $cheap.png"]);
      expect(code, contains(r"'assets/images/it\'s \$cheap.png'"));
    });

    test('fonts are excluded; folders with only fonts disappear', () {
      final code = gen(['assets/fonts/Cairo-Bold.ttf', 'assets/images/a.png']);
      expect(code, isNot(contains('Cairo')));
      expect(code, isNot(contains('_Fonts')));
    });

    test('output is deterministic regardless of input order', () {
      final paths = ['assets/b/z.png', 'assets/a/y.png', 'assets/b/x.png', 'assets/c.json'];
      expect(gen(paths), gen(paths.reversed.toList()));
    });

    test('no assets gives an empty but valid class', () {
      expect(gen([]), contains('abstract final class Assets {}'));
    });
  });

  test('generated code passes dart format and dart analyze with zero issues', () async {
    final index = AssetIndex.scan(projectRoot: fixture, assetsDir: p.join(fixture, 'assets'));
    final tricky = [
      ...index.entries,
      ...[
        'assets/images/logo.png',
        'assets/images/logo.svg',
        "assets/odd/it's \$1.png",
        'assets/odd/name.png',
        'assets/odd/class.png',
        'assets/odd/hash_code.png',
        'assets/root.json',
        'assets/a_b/c/x.png',
        'assets/a/b_c/y.png',
      ].map(entry),
    ];
    // Drop the blanket lint suppression so the package's own lint set is
    // enforced on the generated code.
    // The check folder lives inside this package, so format with this
    // package's settings, exactly as `asset_kit gen` would for a project.
    final code = AssetsGenerator(
      assetsRoot: 'assets',
      formatSettings: FormatSettings.forProject('.'),
    ).generate(tricky).replaceFirst('// ignore_for_file: type=lint\n\n', '');
    final usage = '''
import 'assets.gen.dart';

void main() {
  print(Assets.images.logoWebp);
  print(Assets.images.onboarding.step1);
  print(Assets.odd.classAsset);
  print(Assets.root);
}
''';

    final dir = Directory('build/codegen_check')..createSync(recursive: true);
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'assets.gen.dart')).writeAsStringSync(code);
    File(p.join(dir.path, 'usage.dart')).writeAsStringSync(usage);

    final format = await Process.run('dart', [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      dir.path,
    ]);
    expect(format.exitCode, 0, reason: '${format.stdout}${format.stderr}');

    final analyze = await Process.run('dart', ['analyze', '--fatal-infos', dir.path]);
    expect(analyze.exitCode, 0, reason: '${analyze.stdout}${analyze.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
