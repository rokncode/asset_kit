import 'dart:io';

import 'package:asset_kit/src/config.dart';
import 'package:asset_kit/src/processors/build_cache.dart';
import 'package:asset_kit/src/scanner/unused_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('fixture project', () {
    late UnusedReport report;
    setUpAll(() {
      report = UnusedScanner(AssetKitConfig.load(workingDir: 'test/fixtures/sample_app')).scan();
    });
    Usage usageOf(String path) => report.results.firstWhere((r) => r.unit.path == path).usage;

    test('classifies every asset', () {
      expect(report.unused.map((r) => r.unit.path), [
        'assets/images/background_old.webp',
        'assets/images/unused_banner.webp',
      ]);
      expect(report.possiblyUsed.map((r) => r.unit.path), [
        'assets/images/flags/eg.webp',
        'assets/images/flags/sa.webp',
        'assets/images/onboarding/step-2.webp',
        'assets/images/onboarding/step_1.webp',
      ]);
      for (final used in [
        'assets/images/logo.webp',
        'assets/icons/home-icon.svg',
        'assets/icons/arrow_back.svg',
        'assets/icons/app_icon.png',
        'assets/images/splash.png',
        'assets/images/default.webp',
        'assets/fonts/Cairo-Bold.ttf',
      ]) {
        expect(usageOf(used), Usage.used, reason: used);
      }
    });

    test('the generated constants file is not scanned', () {
      expect(report.scannedFiles, isNot(contains('lib/gen/assets.gen.dart')));
      expect(report.scannedFiles, contains('lib/main.dart'));
    });

    test('sizes include every scale variant', () {
      final banner = report.unused.firstWhere((r) => r.unit.path.endsWith('unused_banner.webp'));
      expect(banner.unit.files, hasLength(3));
      final expected = banner.unit.files.fold<int>(
        0,
        (s, f) => s + File(p.join('test/fixtures/sample_app', f)).lengthSync(),
      );
      expect(banner.size, expected);
    });

    test('broken references in Dart and package configs', () {
      expect(report.broken.map((b) => (b.location, b.path, b.suggestedConstant)), [
        ('flutter_native_splash.yaml:4', 'assets/images/branding.png', null),
        ('lib/screens/onboarding.dart:15', 'assets/images/logo.png', 'Assets.images.logo'),
      ]);
    });

    test('orphans are files with no source and no cache entry', () {
      expect(report.orphans.map((r) => (r.unit.path, r.usage.name)), [
        ('assets/data/config.json', 'unused'),
        ('assets/images/1st place.webp', 'unused'),
        ('assets/images/2.0x/orphan.webp', 'unused'),
        ('assets/images/default.webp', 'used'),
        ('assets/images/شعار.webp', 'unused'),
      ]);
      // Orphans are reported separately from managed unused assets.
      expect(report.unused.where((r) => r.orphan), isEmpty);
    });

    test('reclaimable size covers unused assets and unused orphans', () {
      final expected = [
        ...report.unused,
        ...report.unusedOrphans,
      ].fold<int>(0, (s, r) => s + r.size);
      expect(report.reclaimableBytes, expected);
    });
  });

  group('in a scratch project', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('asset_kit_unused');
      _write(tmp, 'pubspec.yaml', 'name: app\n');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    UnusedReport scan([String yaml = '']) =>
        UnusedScanner(AssetKitConfig.parse(yaml, projectRoot: tmp.path)).scan();
    Usage usage(UnusedReport r, String path) =>
        r.results.firstWhere((x) => x.unit.path == path).usage;
    void asset(String rel) => _write(tmp, rel, 'x');
    void dart(String code, [String file = 'lib/main.dart']) => _write(tmp, file, code);

    group('1. generated file', () {
      test('is excluded, otherwise every asset would look used', () {
        asset('assets/images/a.png');
        dart("final a = 'assets/images/a.png';", 'lib/gen/assets.gen.dart');
        expect(usage(scan(), 'assets/images/a.png'), Usage.unused);
      });

      test('a custom codegen.output is excluded too', () {
        asset('assets/images/a.png');
        dart("final a = 'assets/images/a.png';", 'lib/r.dart');
        expect(usage(scan('codegen: {output: lib/r.dart}'), 'assets/images/a.png'), Usage.unused);
      });
    });

    group('generated constants', () {
      test('a full chain marks the asset used', () {
        asset('assets/images/onboarding/step_1.png');
        asset('assets/images/onboarding/step_2.png');
        dart('final x = Assets.images.onboarding.step1;');
        final r = scan();
        expect(usage(r, 'assets/images/onboarding/step_1.png'), Usage.used);
        expect(usage(r, 'assets/images/onboarding/step_2.png'), Usage.unused);
      });

      test('chains may span lines and use an import prefix', () {
        asset('assets/images/logo.png');
        dart('final x = gen.Assets\n    .images\n    .logo;');
        expect(usage(scan(), 'assets/images/logo.png'), Usage.used);
      });

      test('respects codegen.class_name and codegen.names', () {
        asset('assets/images/شعار.png');
        dart('final x = R.images.logoAr;');
        final r = scan('codegen: {class_name: R, names: {images/شعار.png: logoAr}}');
        expect(usage(r, 'assets/images/شعار.png'), Usage.used);
      });

      test('a similarly named class does not count', () {
        asset('assets/images/logo.png');
        dart('final x = MyAssets.images.logo;');
        expect(usage(scan(), 'assets/images/logo.png'), Usage.unused);
      });
    });

    group('2. folder objects', () {
      test('a folder stored in a variable makes its assets possibly used', () {
        asset('assets/images/onboarding/step_1.png');
        asset('assets/images/onboarding/deep/x.png');
        asset('assets/images/other.png');
        dart('final o = Assets.images.onboarding;\nfinal s = o.step1;');
        final r = scan();
        expect(usage(r, 'assets/images/onboarding/step_1.png'), Usage.possiblyUsed);
        expect(usage(r, 'assets/images/onboarding/deep/x.png'), Usage.possiblyUsed);
        expect(usage(r, 'assets/images/other.png'), Usage.unused);
        final evidence = r.results
            .firstWhere((x) => x.unit.path.endsWith('step_1.png'))
            .evidence
            .single;
        expect(evidence.toString(), contains('Assets.images.onboarding'));
        expect(evidence.location, 'lib/main.dart:1');
      });

      test('a member that does not exist is treated like a folder object', () {
        asset('assets/images/a.png');
        dart('final all = Assets.images.values;');
        expect(usage(scan(), 'assets/images/a.png'), Usage.possiblyUsed);
      });
    });

    group('string literals', () {
      test('exact paths, including variant paths, mark the asset used', () {
        asset('assets/images/a.png');
        asset('assets/images/2.0x/a.png');
        asset('assets/images/b.png');
        asset('assets/images/2.0x/b.png');
        dart("final a = 'assets/images/a.png'; final b = 'packages/app/assets/images/2.0x/b.png';");
        final r = scan();
        expect(usage(r, 'assets/images/a.png'), Usage.used);
        expect(usage(r, 'assets/images/b.png'), Usage.used);
      });

      test('the file name alone marks the asset used', () {
        asset('assets/images/hero.png');
        dart("final a = 'images/' 'hero.png'; final b = 'hero.png';");
        expect(usage(scan(), 'assets/images/hero.png'), Usage.used);
      });

      test('interpolated paths make matching assets possibly used', () {
        asset('assets/flags/sa.webp');
        asset('assets/flags/eg.webp');
        asset('assets/flags/README.txt');
        asset('assets/other/sa.webp');
        dart(r"String f(String c) => 'assets/flags/$c.webp';");
        final r = scan();
        expect(usage(r, 'assets/flags/sa.webp'), Usage.possiblyUsed);
        expect(usage(r, 'assets/flags/eg.webp'), Usage.possiblyUsed);
        expect(usage(r, 'assets/flags/README.txt'), Usage.unused);
        expect(usage(r, 'assets/other/sa.webp'), Usage.unused);
      });

      test(r'interpolations with only placeholders are ignored ($a/$b)', () {
        asset('assets/x.png');
        dart(r"String f(a, b) => '$a/$b';");
        expect(usage(scan(), 'assets/x.png'), Usage.unused);
      });

      test('a folder path used as a prefix makes its assets possibly used', () {
        asset('assets/images/icons/a.png');
        asset('assets/images/b.png');
        dart("String f(n) => 'assets/images/icons/' + n;");
        final r = scan();
        expect(usage(r, 'assets/images/icons/a.png'), Usage.possiblyUsed);
        expect(usage(r, 'assets/images/b.png'), Usage.unused);
      });

      test('comments do not count', () {
        asset('assets/images/a.png');
        dart("// final a = 'assets/images/a.png';\n/* Assets.images.a */");
        expect(usage(scan(), 'assets/images/a.png'), Usage.unused);
      });

      test('only scan_dirs are scanned', () {
        asset('assets/images/a.png');
        dart("final a = 'assets/images/a.png';", 'test/a_test.dart');
        expect(usage(scan(), 'assets/images/a.png'), Usage.unused);
        expect(usage(scan('unused: {scan_dirs: [lib, test]}'), 'assets/images/a.png'), Usage.used);
      });
    });

    group('3. package configs and extra files', () {
      test('flutter_launcher_icons and flutter_native_splash sections in pubspec.yaml', () {
        asset('assets/icon.png');
        asset('assets/splash.png');
        asset('assets/splash_dark.png');
        _write(tmp, 'pubspec.yaml', '''
name: app
flutter_launcher_icons:
  image_path: "assets/icon.png"
flutter_native_splash:
  image: assets/splash.png
  android_12:
    image_dark: assets/splash_dark.png
''');
        final r = scan();
        expect(usage(r, 'assets/icon.png'), Usage.used);
        expect(usage(r, 'assets/splash.png'), Usage.used);
        expect(usage(r, 'assets/splash_dark.png'), Usage.used);
      });

      test('standalone and per-flavor config files', () {
        asset('assets/icon.png');
        asset('assets/icon_dev.png');
        asset('assets/splash.png');
        _write(
          tmp,
          'flutter_launcher_icons.yaml',
          'flutter_launcher_icons:\n  image_path: assets/icon.png\n',
        );
        _write(
          tmp,
          'flutter_launcher_icons-dev.yaml',
          'flutter_launcher_icons:\n  image_path: assets/icon_dev.png\n',
        );
        _write(
          tmp,
          'flutter_native_splash.yaml',
          'flutter_native_splash:\n  image: assets/splash.png\n',
        );
        final r = scan();
        expect(usage(r, 'assets/icon.png'), Usage.used);
        expect(usage(r, 'assets/icon_dev.png'), Usage.used);
        expect(usage(r, 'assets/splash.png'), Usage.used);
      });

      test('the flutter: assets: list does not count as a use', () {
        asset('assets/images/a.png');
        _write(tmp, 'pubspec.yaml', 'name: app\nflutter:\n  assets:\n    - assets/images/a.png\n');
        expect(usage(scan(), 'assets/images/a.png'), Usage.unused);
      });

      test('unused.extra_scan_files are searched as text', () {
        asset('assets/images/a.png');
        asset('assets/images/b.png');
        asset('assets/images/c.png');
        _write(tmp, 'assets/config/remote.json', '{"banner": "assets/images/a.png"}');
        _write(tmp, 'lib/l10n/app_ar.arb', '{"img": "b.png"}');
        final r = scan('unused: {extra_scan_files: ["assets/config/*.json", "lib/l10n/*.arb"]}');
        expect(usage(r, 'assets/images/a.png'), Usage.used);
        expect(usage(r, 'assets/images/b.png'), Usage.used);
        expect(usage(r, 'assets/images/c.png'), Usage.unused);
        expect(r.scannedFiles, containsAll(['assets/config/remote.json', 'lib/l10n/app_ar.arb']));
      });

      test('native sources that load Flutter assets', () {
        asset('assets/images/native.png');
        _write(
          tmp,
          'android/app/src/main/kotlin/MainActivity.kt',
          'val key = loader.getLookupKeyForAsset("assets/images/native.png")',
        );
        expect(usage(scan(), 'assets/images/native.png'), Usage.used);
      });
    });

    group('4. SVG and .vec', () {
      test('are one unit; referencing either marks both used', () {
        asset('assets/icons/a.svg');
        asset('assets/icons/a.vec');
        asset('assets/icons/b.svg');
        asset('assets/icons/b.vec');
        dart("final a = 'assets/icons/a.vec'; final b = Assets.icons.b;");
        final r = scan();
        final a = r.results.firstWhere((x) => x.unit.path == 'assets/icons/a.svg');
        expect(a.unit.files, ['assets/icons/a.svg', 'assets/icons/a.vec']);
        expect(a.usage, Usage.used);
        expect(usage(r, 'assets/icons/b.svg'), Usage.used);
        expect(r.results.where((x) => x.unit.path.endsWith('.vec')), isEmpty);
      });

      test('an unused pair is reported once with both files', () {
        asset('assets/icons/c.svg');
        asset('assets/icons/c.vec');
        final unit = scan().unused.single;
        expect(unit.unit.files, ['assets/icons/c.svg', 'assets/icons/c.vec']);
      });
    });

    group('fonts', () {
      test('a registered font is used when its family name appears in Dart', () {
        asset('assets/fonts/Cairo-Bold.ttf');
        _write(tmp, 'pubspec.yaml', '''
name: app
flutter:
  fonts:
    - family: Cairo
      fonts:
        - asset: assets/fonts/Cairo-Bold.ttf
''');
        expect(usage(scan(), 'assets/fonts/Cairo-Bold.ttf'), Usage.possiblyUsed);
        dart("final f = TextStyle(fontFamily: 'Cairo');");
        expect(usage(scan(), 'assets/fonts/Cairo-Bold.ttf'), Usage.used);
      });

      test('an unregistered, unreferenced font is unused', () {
        asset('assets/fonts/Old.ttf');
        expect(usage(scan(), 'assets/fonts/Old.ttf'), Usage.unused);
      });
    });

    group('5. orphans', () {
      test('files without a source or cache entry are orphans', () {
        _write(tmp, 'assets_src/images/logo@3x.png', 'x');
        asset('assets/images/logo.webp');
        asset('assets/images/2.0x/logo.webp');
        asset('assets/images/built.webp');
        asset('assets/images/stray.png');
        BuildCache(p.join(tmp.path, '.asset_kit', 'cache.json'), {
          'images/old_name.png': CacheEntry(
            sourceHash: 'h',
            settings: 's',
            outputs: ['assets/images/built.webp'],
            sourceSize: 1,
            outputSize: 1,
          ),
        }).save();
        final r = scan();
        expect(r.orphanCheck, isTrue);
        expect(r.orphans.map((x) => x.unit.path), ['assets/images/stray.png']);
        expect(r.unusedOrphans.single.unit.path, 'assets/images/stray.png');
        expect(r.unused.map((x) => x.unit.path), [
          'assets/images/built.webp',
          'assets/images/logo.webp',
        ]);
      });

      test('no source folder means no orphan check', () {
        asset('assets/images/a.png');
        final r = scan();
        expect(r.orphanCheck, isFalse);
        expect(r.orphans, isEmpty);
        expect(r.unused.single.unit.path, 'assets/images/a.png');
      });
    });

    group('broken references', () {
      test('a path to a missing file is broken, with a suggestion for the converted asset', () {
        asset('assets/images/logo.webp');
        dart("final a = 'assets/images/logo.png';\nfinal b = 'assets/images/3.0x/logo@3x.png';");
        final r = scan();
        expect(r.broken.map((b) => (b.path, b.location, b.suggestedPath, b.suggestedConstant)), [
          (
            'assets/images/logo.png',
            'lib/main.dart:1',
            'assets/images/logo.webp',
            'Assets.images.logo',
          ),
          (
            'assets/images/3.0x/logo@3x.png',
            'lib/main.dart:2',
            'assets/images/logo.webp',
            'Assets.images.logo',
          ),
        ]);
      });

      test('do not change the used/unused classification', () {
        asset('assets/images/logo.webp');
        dart("final a = 'assets/images/logo.png';");
        final r = scan();
        expect(usage(r, 'assets/images/logo.webp'), Usage.unused);
        expect(r.broken, hasLength(1));
      });

      test('no suggestion when nothing matches', () {
        asset('assets/images/a.png');
        dart("final a = 'assets/images/gone.png';");
        final b = scan().broken.single;
        expect(b.suggestedPath, isNull);
        expect(b.suggestedConstant, isNull);
      });

      test('existing files, variants and folders are not broken', () {
        asset('assets/images/a.png');
        asset('assets/images/2.0x/a.png');
        dart(
          "final a = 'assets/images/a.png'; final b = 'assets/images/2.0x/a.png';\n"
          "final c = 'assets/images/'; final d = 'assets/images';",
        );
        expect(scan().broken, isEmpty);
      });

      test('dynamic paths and paths outside the output folder are not checked', () {
        asset('assets/images/a.png');
        dart(
          r"final a = 'assets/images/$x.png'; final b = 'images/gone.png'; final c = 'https://x/assets/a.png';",
        );
        expect(scan().broken, isEmpty);
      });

      test('package configs are checked with line numbers', () {
        asset('assets/icon.png');
        _write(
          tmp,
          'flutter_native_splash.yaml',
          'flutter_native_splash:\n  color: "#fff"\n  image: assets/splash.png\n',
        );
        _write(
          tmp,
          'pubspec.yaml',
          'name: app\nflutter_launcher_icons:\n  image_path: assets/icon.jpg\n',
        );
        final r = scan();
        expect(r.broken.map((b) => (b.location, b.path, b.suggestedPath)), [
          ('flutter_native_splash.yaml:3', 'assets/splash.png', null),
          ('pubspec.yaml:3', 'assets/icon.jpg', 'assets/icon.png'),
        ]);
      });

      test('commented-out paths are not broken', () {
        asset('assets/a.png');
        dart("// final a = 'assets/gone.png';");
        expect(scan().broken, isEmpty);
      });
    });

    test('unused.ignore excludes assets from the report', () {
      asset('assets/images/onboarding/a.png');
      asset('assets/images/b.png');
      final r = scan('unused: {ignore: ["assets/images/onboarding/*"]}');
      expect(r.ignored.single.unit.path, 'assets/images/onboarding/a.png');
      expect(r.unused.single.unit.path, 'assets/images/b.png');
    });
  });
}

void _write(Directory root, String rel, String content) {
  final f = File(p.join(root.path, rel));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}
