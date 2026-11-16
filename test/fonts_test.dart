import 'dart:io';
import 'dart:typed_data';

import 'package:asset_kit/src/codegen/assets_generator.dart';
import 'package:asset_kit/src/config.dart';
import 'package:asset_kit/src/errors.dart';
import 'package:asset_kit/src/processors/fonts.dart';
import 'package:asset_kit/src/processors/pubspec_sync.dart';
import 'package:asset_kit/src/scanner/asset_index.dart';
import 'package:asset_kit/src/scanner/unused_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Minimal sfnt header with the given table tags.
Uint8List fontBytes(List<String> tables) {
  final data = ByteData(12 + tables.length * 16);
  data.setUint32(0, 0x00010000);
  data.setUint16(4, tables.length);
  final bytes = data.buffer.asUint8List();
  for (var i = 0; i < tables.length; i++) {
    bytes.setRange(12 + i * 16, 12 + i * 16 + 4, tables[i].codeUnits);
  }
  return bytes;
}

final staticFont = fontBytes(['cmap', 'glyf', 'head']);
final variableFont = fontBytes(['cmap', 'fvar', 'glyf', 'gvar']);

void main() {
  group('parseFontFileName', () {
    final weights = {
      'Thin': 100,
      'ExtraLight': 200,
      'UltraLight': 200,
      'Light': 300,
      'Regular': 400,
      'Book': 400,
      'Normal': 400,
      'Medium': 500,
      'SemiBold': 600,
      'DemiBold': 600,
      'Bold': 700,
      'ExtraBold': 800,
      'UltraBold': 800,
      'Black': 900,
      'Heavy': 900,
    };
    weights.forEach((suffix, weight) {
      test('Cairo-$suffix → $weight', () {
        expect(parseFontFileName('Cairo-$suffix'), (
          family: 'Cairo',
          weight: weight,
          italic: false,
          variable: false,
        ));
        expect(parseFontFileName('Cairo-${suffix}Italic'), (
          family: 'Cairo',
          weight: weight,
          italic: true,
          variable: false,
        ));
      });
    });

    test('is case-insensitive and tolerates separators inside the suffix', () {
      expect(parseFontFileName('Cairo-semibold')?.weight, 600);
      expect(parseFontFileName('Cairo-SEMIBOLD')?.weight, 600);
      expect(parseFontFileName('Cairo-Semi_Bold')?.weight, 600);
      expect(parseFontFileName('Cairo-Extra-Light'), (
        family: 'Cairo',
        weight: 200,
        italic: false,
        variable: false,
      ));
    });

    test('italic alone is regular italic, and may come first', () {
      expect(parseFontFileName('Cairo-Italic'), (
        family: 'Cairo',
        weight: 400,
        italic: true,
        variable: false,
      ));
      expect(parseFontFileName('Cairo-ItalicBold'), (
        family: 'Cairo',
        weight: 700,
        italic: true,
        variable: false,
      ));
    });

    test('multi-word and Arabic font families', () {
      expect(parseFontFileName('NotoKufiArabic-SemiBold')?.family, 'NotoKufiArabic');
      expect(parseFontFileName('IBMPlexSansArabic-Bold')?.family, 'IBMPlexSansArabic');
      expect(parseFontFileName('Noto-Sans-Arabic-Black'), (
        family: 'Noto-Sans-Arabic',
        weight: 900,
        italic: false,
        variable: false,
      ));
      expect(parseFontFileName('Tajawal-ExtraBold')?.weight, 800);
      expect(parseFontFileName('Almarai-Light')?.family, 'Almarai');
    });

    test('a plain family name is regular', () {
      expect(parseFontFileName('Cairo'), (
        family: 'Cairo',
        weight: 400,
        italic: false,
        variable: false,
      ));
    });

    test('variable fonts have no weight', () {
      expect(parseFontFileName('Cairo[wght]'), (
        family: 'Cairo',
        weight: null,
        italic: false,
        variable: true,
      ));
      expect(parseFontFileName('Cairo[slnt,wght]')?.variable, isTrue);
      expect(parseFontFileName('Cairo-Italic[wght]'), (
        family: 'Cairo',
        weight: null,
        italic: true,
        variable: true,
      ));
      expect(parseFontFileName('Cairo-VariableFont_wght'), (
        family: 'Cairo',
        weight: null,
        italic: false,
        variable: true,
      ));
      expect(parseFontFileName('NotoSans-Italic-VariableFont_wdth,wght'), (
        family: 'NotoSans',
        weight: null,
        italic: true,
        variable: true,
      ));
    });

    test('unknown suffixes and run-together names are not guessed', () {
      expect(parseFontFileName('Tajawal-Hairline'), isNull);
      expect(parseFontFileName('Cairo-Condensed'), isNull);
      expect(parseFontFileName('CairoBold'), isNull);
      expect(parseFontFileName('CairoItalic'), isNull);
    });
  });

  test('hasFvarTable', () {
    expect(hasFvarTable(variableFont), isTrue);
    expect(hasFvarTable(staticFont), isFalse);
    expect(hasFvarTable(Uint8List(4)), isFalse);
    expect(
      hasFvarTable(Uint8List.fromList([0, 1, 0, 0, 0, 50, 0, 0, 0, 0, 0, 0])),
      isFalse,
      reason: 'truncated',
    );
  });

  group('in a project', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('asset_kit_fonts');
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void font(String name, [Uint8List? bytes]) => File(p.join(tmp.path, 'assets', 'fonts', name))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes ?? staticFont);
    AssetKitConfig config([String yaml = '']) => AssetKitConfig.parse(yaml, projectRoot: tmp.path);
    File pubspec() => File(p.join(tmp.path, 'pubspec.yaml'));

    group('planFonts', () {
      test('groups by family and orders faces by weight, then style', () {
        font('Cairo-Bold.ttf');
        font('Cairo-Regular.ttf');
        font('Cairo-BoldItalic.ttf');
        font('Tajawal-Light.otf');
        final plan = planFonts(config());
        expect(plan.byFamily.keys, ['Cairo', 'Tajawal']);
        expect(plan.byFamily['Cairo']!.map((f) => f.toPubspec()), [
          {'asset': 'assets/fonts/Cairo-Regular.ttf', 'weight': 400},
          {'asset': 'assets/fonts/Cairo-Bold.ttf', 'weight': 700},
          {'asset': 'assets/fonts/Cairo-BoldItalic.ttf', 'weight': 700, 'style': 'italic'},
        ]);
      });

      test('an fvar table makes a font variable even with a weight in its name', () {
        font('Cairo-Regular.ttf', variableFont);
        final face = planFonts(config()).faces.single;
        expect(face.variable, isTrue);
        expect(face.toPubspec(), {'asset': 'assets/fonts/Cairo-Regular.ttf'});
      });

      test('unknown names are reported, not registered', () {
        font('Tajawal-Hairline.ttf');
        font('Tajawal-Bold.ttf');
        final plan = planFonts(config());
        expect(plan.unknown.single.key, 'fonts/Tajawal-Hairline.ttf');
        expect(plan.unknown.single.guessedFamily, 'Tajawal');
        expect(plan.faces.single.asset, 'assets/fonts/Tajawal-Bold.ttf');
      });

      test('fonts.overrides supplies family, weight and style', () {
        font('Tajawal-Hairline.ttf');
        font('خط-عريض.ttf');
        final plan = planFonts(
          config('''
fonts:
  overrides:
    fonts/Tajawal-Hairline.ttf: { family: Tajawal, weight: 100 }
    fonts/خط-عريض.ttf: { family: خط, weight: 700, style: italic }
'''),
        );
        expect(plan.unknown, isEmpty);
        expect(plan.byFamily['Tajawal']!.single.toPubspec(), {
          'asset': 'assets/fonts/Tajawal-Hairline.ttf',
          'weight': 100,
        });
        expect(plan.byFamily['خط']!.single.toPubspec(), {
          'asset': 'assets/fonts/خط-عريض.ttf',
          'weight': 700,
          'style': 'italic',
        });
      });

      test('two files with the same family, weight and style fail clearly', () {
        font('Cairo-Bold.ttf');
        font('Cairo-bold.otf');
        expect(
          () => planFonts(config()),
          throwsA(
            isA<AssetKitException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Cairo 700'), contains('Cairo-Bold.ttf'), contains('Cairo-bold.otf')),
            ),
          ),
        );
      });

      test('two variable fonts for the same family and style fail too', () {
        font('Cairo[wght].ttf', variableFont);
        font('Cairo-VariableFont_wght.ttf', variableFont);
        expect(() => planFonts(config()), throwsA(isA<AssetKitException>()));
      });
    });

    test('config: fonts.overrides is validated', () {
      for (final (yaml, message) in [
        ('fonts: {overrides: {a.ttf: {weight: 450}}}', 'one of 100, 200'),
        ('fonts: {overrides: {a.ttf: {style: oblique}}}', 'normal or italic'),
        ('fonts: {overrides: {a.ttf: bold}}', 'to be a map'),
        // The suggested snippet's placeholder must be replaced before it works.
        ('fonts: {overrides: {a.ttf: {family: Tajawal, weight: <weight>}}}', 'one of 100, 200'),
      ]) {
        expect(
          () => config(yaml),
          throwsA(isA<ConfigException>().having((e) => e.message, 'm', contains(message))),
        );
      }
      expect(config('fonts: {overrides: {a.ttf: {famly: X}}}').warnings.single, contains('famly'));
    });

    group('pubspec registration', () {
      test('registers families with weights and styles', () {
        font('Cairo-Regular.ttf');
        font('Cairo-BoldItalic.ttf');
        final result = syncPubspec(config(), dryRun: false);
        expect(result.fontsAdded, ['Cairo']);
        expect(pubspec().readAsStringSync(), '''
name: app

flutter:
  fonts:
    - family: Cairo
      fonts:
        - asset: assets/fonts/Cairo-Regular.ttf
          weight: 400
        - asset: assets/fonts/Cairo-BoldItalic.ttf
          weight: 700
          style: italic
''');
        expect(syncPubspec(config(), dryRun: false).changed, isFalse, reason: 'idempotent');
      });

      test('variable fonts are registered once without a weight', () {
        font('Cairo[wght].ttf', variableFont);
        syncPubspec(config(), dryRun: false);
        expect(pubspec().readAsStringSync(), contains("- asset: 'assets/fonts/Cairo[wght].ttf'\n"));
        expect(registeredFontFamilies(pubspec().path), ['Cairo']);
        expect(pubspec().readAsStringSync(), isNot(contains('weight')));
      });

      test('adds, updates and removes managed families; keeps comments and hand-made ones', () {
        font('Cairo-Regular.ttf');
        font('Cairo-Bold.ttf');
        font('Tajawal-Bold.ttf');
        File(p.join(tmp.path, 'assets', 'images', 'a.png'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');
        pubspec().writeAsStringSync('''
name: app
flutter:
  fonts: # our fonts
    - family: Cairo # main font
      fonts:
        - asset: assets/fonts/Cairo-Regular.ttf
    - family: Old
      fonts:
        - asset: assets/fonts/Old-Regular.ttf
    - family: Brand # registered by hand, outside assets/
      fonts:
        - asset: fonts/Brand.ttf
  assets:
    - assets/images/
''');
        final result = syncPubspec(config(), dryRun: false);
        expect(result.fontsUpdated, ['Cairo']);
        expect(result.fontsRemoved, ['Old']);
        expect(result.fontsAdded, ['Tajawal']);
        final text = pubspec().readAsStringSync();
        expect(text, contains('  fonts: # our fonts\n'));
        expect(text, contains('- family: Cairo # main font\n'));
        expect(text, contains('- asset: assets/fonts/Cairo-Bold.ttf\n          weight: 700'));
        expect(text, isNot(contains('Old')));
        expect(text, contains('- family: Brand # registered by hand, outside assets/\n'));
        expect(text, contains('- family: Tajawal'));
        expect(text, contains('  assets:\n    - assets/images/\n'));
        expect(syncPubspec(config(), dryRun: false).changed, isFalse);
      });

      test('a family registered by hand outside assets/ is never rewritten', () {
        font('Cairo-Regular.ttf');
        pubspec().writeAsStringSync(
          'name: app\nflutter:\n  fonts:\n    - family: Cairo\n      fonts:\n        - asset: fonts/Cairo.ttf\n',
        );
        final result = syncPubspec(config(), dryRun: false);
        expect(result.fontsSkipped, ['Cairo']);
        expect(result.changed, isFalse);
      });

      test('removing every managed family removes the fonts key', () {
        pubspec().writeAsStringSync(
          'name: app\nflutter:\n  fonts:\n    - family: Old\n      fonts:\n        - asset: assets/fonts/Old.ttf\n',
        );
        syncPubspec(config(), dryRun: false);
        expect(pubspec().readAsStringSync(), isNot(contains('fonts')));
      });

      test('register_in_pubspec: false leaves fonts alone', () {
        font('Cairo-Regular.ttf');
        final result = syncPubspec(config('fonts: {register_in_pubspec: false}'), dryRun: false);
        expect(result.fontsAdded, isEmpty);
        expect(pubspec().readAsStringSync(), isNot(contains('Cairo')));
      });

      test('Arabic family names from overrides', () {
        font('خط-عريض.ttf');
        syncPubspec(
          config('fonts: {overrides: {fonts/خط-عريض.ttf: {family: خط, weight: 700}}}'),
          dryRun: false,
        );
        expect(registeredFontFamilies(pubspec().path), ['خط']);
      });
    });

    test('FontFamily.x in code marks the family used', () {
      font('Cairo-Regular.ttf');
      font('Tajawal-Regular.ttf');
      syncPubspec(config(), dryRun: false);
      File(p.join(tmp.path, 'lib', 'main.dart'))
        ..parent.createSync()
        ..writeAsStringSync('final s = TextStyle(fontFamily: FontFamily.cairo);');
      final report = UnusedScanner(config()).scan();
      Usage usage(String path) => report.results.firstWhere((r) => r.unit.path == path).usage;
      expect(usage('assets/fonts/Cairo-Regular.ttf'), Usage.used);
      expect(usage('assets/fonts/Tajawal-Regular.ttf'), Usage.possiblyUsed);
    });
  });

  group('FontFamily codegen', () {
    String gen(List<String> families, {Map<String, String> names = const {}}) => AssetsGenerator(
      assetsRoot: 'assets',
      fontFamilies: families,
      names: names,
    ).generate(<AssetEntry>[]);

    test('emits constants for every registered family', () {
      final code = gen(['Cairo', 'IBM Plex Sans Arabic', 'Noto-Sans-Arabic']);
      expect(code, contains('abstract final class FontFamily {'));
      expect(code, contains("static const String cairo = 'Cairo';"));
      expect(code, contains("static const String ibmPlexSansArabic = 'IBM Plex Sans Arabic';"));
      expect(code, contains("static const String notoSansArabic = 'Noto-Sans-Arabic';"));
    });

    test('no families, no class', () {
      expect(gen([]), isNot(contains('FontFamily')));
    });

    test('Arabic family names need a font: entry in codegen.names', () {
      final generator = AssetsGenerator(assetsRoot: 'assets', fontFamilies: ['خط']);
      expect(generator.generate([]), isNot(contains('FontFamily')));
      expect(generator.skipped.single.key, 'font:خط');
      expect(
        gen(['خط'], names: {'font:خط': 'arabicDisplay'}),
        contains("static const String arabicDisplay = 'خط';"),
      );
    });

    test('clashing family identifiers are skipped, not numbered', () {
      final generator = AssetsGenerator(
        assetsRoot: 'assets',
        fontFamilies: ['Noto Sans', 'NotoSans', 'Cairo'],
      );
      final code = generator.generate([]);
      expect(code, contains('cairo'));
      expect(code, isNot(contains('notoSans')));
      expect(
        generator.skipped.map((s) => s.key),
        unorderedEquals(['font:Noto Sans', 'font:NotoSans']),
      );
    });
  });
}
