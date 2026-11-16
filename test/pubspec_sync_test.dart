import 'dart:io';

import 'package:asset_kit/src/config.dart';
import 'package:asset_kit/src/errors.dart';
import 'package:asset_kit/src/processors/pubspec_sync.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('asset_kit_sync');
    for (final f in [
      'assets/images/logo.webp',
      'assets/images/2.0x/logo.webp',
      'assets/images/onboarding/step_1.webp',
      'assets/icons/home.svg',
      'assets/fonts/Cairo-Bold.ttf',
    ]) {
      File(p.join(tmp.path, f))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  AssetKitConfig config() => AssetKitConfig.parse('', projectRoot: tmp.path);
  File pubspec() => File(p.join(tmp.path, 'pubspec.yaml'));
  PubspecSyncResult sync({bool dryRun = false}) => syncPubspec(config(), dryRun: dryRun);

  test('requiredAssetDirs: one entry per folder, no scale or font-only folders', () {
    expect(requiredAssetDirs(config()), [
      'assets/icons/',
      'assets/images/',
      'assets/images/onboarding/',
    ]);
  });

  test('adds the assets list when there is none, keeping the rest intact', () {
    pubspec().writeAsStringSync('''
name: app # the name

flutter:
  uses-material-design: true # keep me
''');
    final result = sync();
    expect(result.added, ['assets/icons/', 'assets/images/', 'assets/images/onboarding/']);
    final text = pubspec().readAsStringSync();
    expect(text, startsWith('name: app # the name\n\nflutter:\n'));
    expect(text, contains('  uses-material-design: true # keep me\n'));
    expect(
      text,
      contains(
        '  assets:\n    - assets/icons/\n    - assets/images/\n    - assets/images/onboarding/\n',
      ),
    );
  });

  test('creates the flutter section when missing or empty', () {
    for (final yaml in ['name: app\n', 'name: app\nflutter:\n']) {
      pubspec().writeAsStringSync(yaml);
      sync();
      expect(pubspec().readAsStringSync(), contains('- assets/images/onboarding/'));
    }
  });

  test(
    'appends missing folders, removes stale and scale folders, keeps comments and foreign entries',
    () {
      pubspec().writeAsStringSync('''
name: app
flutter:
  assets:
    - assets/images/          # images
    - assets/images/2.0x/     # scale folder
    - assets/gone/            # deleted folder
    - assets/icons/home.svg   # a single file: left alone
    - shaders/                # outside the assets folder
    - path: assets/flavor/
      flavors: [dev]
  fonts: # fonts below
    - family: Cairo
''');
      final result = sync();
      expect(result.removed, ['assets/images/2.0x/', 'assets/gone/']);
      expect(result.added, ['assets/icons/', 'assets/images/onboarding/']);
      expect(pubspec().readAsStringSync(), '''
name: app
flutter:
  assets:
    - assets/images/          # images
    - assets/icons/home.svg   # a single file: left alone
    - shaders/                # outside the assets folder
    - assets/icons/
    - assets/images/onboarding/
    - path: assets/flavor/
      flavors: [dev]
  fonts: # fonts below
    - family: Cairo
''');
    },
  );

  test('a new flutter section goes after the existing keys', () {
    pubspec().writeAsStringSync('name: app\nversion: 1.0.0\n');
    sync();
    expect(
      pubspec().readAsStringSync(),
      startsWith('name: app\nversion: 1.0.0\n\nflutter:\n  assets:\n'),
    );
  });

  test('removing every managed entry removes the assets key', () {
    for (final f in Directory(p.join(tmp.path, 'assets')).listSync()) {
      f.deleteSync(recursive: true);
    }
    pubspec().writeAsStringSync(
      'name: app\nflutter:\n  uses-material-design: true\n  assets:\n    - assets/images/\n',
    );
    sync();
    expect(pubspec().readAsStringSync(), 'name: app\nflutter:\n  uses-material-design: true\n');
  });

  test('is idempotent and writes nothing when up to date', () {
    pubspec().writeAsStringSync('name: app\n');
    sync();
    final before = pubspec().readAsStringSync();
    final second = sync();
    expect(second.changed, isFalse);
    expect(second.backup, isNull);
    expect(pubspec().readAsStringSync(), before);
  });

  test('backs up pubspec.yaml before writing', () {
    pubspec().writeAsStringSync('name: app\n');
    final result = sync();
    expect(File(result.backup!).readAsStringSync(), 'name: app\n');
    expect(p.isWithin(p.join(tmp.path, '.asset_kit', 'backups'), result.backup!), isTrue);
  });

  test('keeps at most 10 backups', () {
    final dir = Directory(p.join(tmp.path, '.asset_kit', 'backups'))..createSync(recursive: true);
    for (var i = 0; i < 12; i++) {
      File(
        p.join(dir.path, 'pubspec.yaml.2020-01-${'$i'.padLeft(2, '0')}'),
      ).writeAsStringSync('old');
    }
    pubspec().writeAsStringSync('name: app\n');
    sync();
    expect(dir.listSync(), hasLength(10));
  });

  test('dry run reports changes without writing', () {
    pubspec().writeAsStringSync('name: app\n');
    final result = sync(dryRun: true);
    expect(result.added, hasLength(3));
    expect(pubspec().readAsStringSync(), 'name: app\n');
    expect(Directory(p.join(tmp.path, '.asset_kit')).existsSync(), isFalse);
  });

  test('fails clearly on a missing or invalid pubspec.yaml', () {
    expect(sync, throwsA(isA<AssetKitException>()));
    pubspec().writeAsStringSync('name: [broken');
    expect(
      sync,
      throwsA(isA<AssetKitException>().having((e) => e.exitCode, 'exitCode', ExitCode.data)),
    );
  });
}
