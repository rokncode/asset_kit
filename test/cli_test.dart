import 'dart:convert';
import 'dart:io';

import 'package:asset_kit/src/errors.dart';
import 'package:asset_kit/src/runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/source_images.dart';

/// Copies [from] into [to] recursively.
void copyDir(String from, String to) {
  for (final entity in Directory(from).listSync(recursive: true)) {
    final target = p.join(to, p.relative(entity.path, from: from));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('asset_kit_cli'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final questions = <String>[];
  var answers = <bool>[];
  Future<int> run(List<String> args) => AssetKitRunner(
    workingDir: tmp.path,
    confirm: (q) async {
      questions.add(q);
      return answers.isEmpty ? false : answers.removeAt(0);
    },
  ).run(args);
  setUp(() {
    questions.clear();
    answers = [];
  });
  File file(String path) => File(p.join(tmp.path, path));

  group('init', () {
    test('creates the config, source folders and a .gitignore entry', () async {
      file('pubspec.yaml').writeAsStringSync('name: app\n');
      file('.gitignore').writeAsStringSync('build/');
      expect(await run(['init']), ExitCode.success);
      expect(file('asset_kit.yaml').existsSync(), isTrue);
      for (final dir in ['images', 'icons', 'fonts']) {
        expect(Directory(p.join(tmp.path, 'assets_src', dir)).existsSync(), isTrue);
      }
      expect(
        file('.gitignore').readAsStringSync(),
        'build/\n\n# asset_kit build cache\n.asset_kit/\n',
      );
    });

    test('refuses to overwrite without --force', () async {
      file('asset_kit.yaml').writeAsStringSync('source: mine\n');
      expect(await run(['init']), ExitCode.failure);
      expect(file('asset_kit.yaml').readAsStringSync(), 'source: mine\n');
      expect(await run(['init', '--force']), ExitCode.success);
      expect(file('asset_kit.yaml').readAsStringSync(), contains('source: assets_src'));
    });

    test('--dry-run writes nothing', () async {
      expect(await run(['--dry-run', 'init']), ExitCode.success);
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('gen', () {
    setUp(() => copyDir('test/fixtures/sample_app', tmp.path));

    test('writes the constants file', () async {
      file('lib/gen/assets.gen.dart').deleteSync();
      expect(await run(['gen']), ExitCode.success);
      final code = file('lib/gen/assets.gen.dart').readAsStringSync();
      expect(code, File('test/fixtures/sample_app/lib/gen/assets.gen.dart').readAsStringSync());
    });

    test('--dry-run does not write', () async {
      file('lib/gen/assets.gen.dart').deleteSync();
      expect(await run(['gen', '--dry-run']), ExitCode.success);
      expect(file('lib/gen/assets.gen.dart').existsSync(), isFalse);
    });

    test('respects codegen.output and class_name', () async {
      file('asset_kit.yaml').writeAsStringSync('codegen: {output: lib/r.dart, class_name: R}\n');
      expect(await run(['gen']), ExitCode.success);
      expect(file('lib/r.dart').readAsStringSync(), contains('abstract final class R {'));
    });

    test('--config points at another file and resolves paths from it', () async {
      Directory(p.join(tmp.path, 'config')).createSync();
      file(
        'config/kit.yaml',
      ).writeAsStringSync('output: ../assets\ncodegen: {output: ../lib/x.dart}\n');
      expect(await run(['--config', 'config/kit.yaml', 'gen']), ExitCode.success);
      expect(file('lib/x.dart').existsSync(), isTrue);
    });

    test('invalid config exits with the config error code', () async {
      file('asset_kit.yaml').writeAsStringSync('images: {quality: 500}\n');
      expect(await run(['gen']), ExitCode.config);
    });

    test('missing assets folder is an error', () async {
      Directory(p.join(tmp.path, 'assets')).deleteSync(recursive: true);
      expect(await run(['gen']), ExitCode.failure);
    });
  });

  group('optimize', () {
    setUp(() => writeDemoSources(p.join(tmp.path, 'assets_src')));

    test('succeeds and then gen picks up the outputs', () async {
      expect(await run(['optimize', '-j', '2']), ExitCode.success);
      expect(
        file('assets/images/logo.webp').existsSync() || file('assets/images/logo.png').existsSync(),
        isTrue,
      );
      expect(await run(['gen']), ExitCode.success);
      expect(file('lib/gen/assets.gen.dart').readAsStringSync(), contains('final String logo ='));
    });

    test('exits 1 when a file fails', () async {
      file('assets_src/images/corrupt.png').writeAsStringSync('nope');
      expect(await run(['optimize']), ExitCode.failure);
    });

    test('missing source folder is an error', () async {
      Directory(p.join(tmp.path, 'assets_src')).deleteSync(recursive: true);
      expect(await run(['optimize']), ExitCode.failure);
    });

    test('--jobs must be positive', () async {
      expect(await run(['optimize', '--jobs', '0']), ExitCode.usage);
    });

    test('--dry-run writes nothing', () async {
      expect(await run(['--dry-run', 'optimize']), ExitCode.success);
      expect(Directory(p.join(tmp.path, 'assets')).existsSync(), isFalse);
    });
  });

  group('unused', () {
    setUp(() => copyDir('test/fixtures/sample_app', tmp.path));
    bool exists(String rel) => file(rel).existsSync();

    test('reports and exits 0', () async {
      expect(await run(['unused']), ExitCode.success);
    });

    test('--fail-on-unused exits 1 when something is unused', () async {
      expect(await run(['unused', '--fail-on-unused']), ExitCode.failure);
    });

    test('--fail-on-unused exits 0 when everything is used or ignored', () async {
      file('asset_kit.yaml').writeAsStringSync('unused: {ignore: ["assets/**"]}\n');
      expect(await run(['unused', '--fail-on-unused']), ExitCode.success);
    });

    test('--json prints a machine-readable report on stdout', () async {
      final result = await Process.run('dart', [
        'run',
        p.absolute('bin/asset_kit.dart'),
        'unused',
        '--json',
      ], workingDirectory: tmp.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final json = jsonDecode('${result.stdout}') as Map<String, dynamic>;
      expect((json['unused'] as List).map((e) => (e as Map)['path']), [
        'assets/images/background_old.webp',
        'assets/images/unused_banner.webp',
      ]);
      expect((json['unused'] as List).last, containsPair('files', hasLength(3)));
      expect(json['possiblyUsed'], hasLength(4));
      expect(json['orphans'], hasLength(5));
      expect(json['reclaimableBytes'], isPositive);
      expect(json['broken'], [
        {'path': 'assets/images/branding.png', 'location': 'flutter_native_splash.yaml:4'},
        {
          'path': 'assets/images/logo.png',
          'location': 'lib/screens/onboarding.dart:15',
          'suggestedPath': 'assets/images/logo.webp',
          'suggestedConstant': 'Assets.images.logo',
        },
      ]);
    });

    test('--delete asks first and does nothing on "no"', () async {
      answers = [false, false];
      expect(await run(['unused', '--delete']), ExitCode.success);
      expect(questions, hasLength(2));
      expect(questions.first, startsWith('Delete 2 unused assets (4 files'));
      expect(questions.last, startsWith('Delete 4 unused orphan files'));
      expect(exists('assets/images/unused_banner.webp'), isTrue);
    });

    test('--delete removes every scale variant and regenerates constants', () async {
      answers = [true, false];
      expect(await run(['unused', '--delete']), ExitCode.success);
      for (final f in [
        'unused_banner.webp',
        '2.0x/unused_banner.webp',
        '3.0x/unused_banner.webp',
        'background_old.webp',
      ]) {
        expect(exists('assets/images/$f'), isFalse, reason: f);
      }
      expect(exists('assets/images/logo.webp'), isTrue);
      expect(
        exists('assets/images/flags/sa.webp'),
        isTrue,
        reason: 'possibly used is never deleted',
      );
      // Orphans were declined.
      expect(exists('assets/data/config.json'), isTrue);
      // Sources are kept without --include-source.
      expect(exists('assets_src/images/unused_banner.png'), isTrue);
      expect(file('lib/gen/assets.gen.dart').readAsStringSync(), isNot(contains('unusedBanner')));
    });

    test('--include-source also deletes the originals', () async {
      answers = [true, false];
      expect(await run(['unused', '--delete', '--include-source']), ExitCode.success);
      expect(questions.first, contains('and 2 source files'));
      expect(exists('assets_src/images/unused_banner.png'), isFalse);
      expect(exists('assets_src/images/background_old.png'), isFalse);
      expect(exists('assets_src/images/logo@3x.png'), isTrue);
    });

    test('unused orphans are deleted only on their own confirmation; used orphans never', () async {
      answers = [false, true];
      expect(await run(['unused', '--delete']), ExitCode.success);
      expect(exists('assets/data/config.json'), isFalse);
      expect(exists('assets/images/2.0x/orphan.webp'), isFalse);
      expect(exists('assets/images/default.webp'), isTrue, reason: 'used orphan');
      expect(exists('assets/images/unused_banner.webp'), isTrue, reason: 'first prompt declined');
    });

    test('an SVG and its .vec are deleted together', () async {
      file('lib/screens/onboarding.dart').writeAsStringSync('// nothing\n');
      answers = [true, false];
      expect(await run(['unused', '--delete', '--yes']), ExitCode.success);
      expect(exists('assets/icons/arrow_back.svg'), isFalse);
      expect(exists('assets/icons/arrow_back.vec'), isFalse);
    });

    test('--yes skips confirmation (both groups)', () async {
      expect(await run(['unused', '--delete', '--yes', '--fail-on-unused']), ExitCode.success);
      expect(questions, isEmpty);
      expect(exists('assets/images/background_old.webp'), isFalse);
      expect(exists('assets/data/config.json'), isFalse);
    });

    test('--dry-run --delete deletes nothing', () async {
      expect(await run(['--dry-run', 'unused', '--delete', '--yes']), ExitCode.success);
      expect(exists('assets/images/background_old.webp'), isTrue);
    });

    test('--fail-on-broken exits 1 when a path points at a missing file', () async {
      expect(await run(['unused', '--fail-on-broken']), ExitCode.failure);
      file('lib/screens/onboarding.dart').writeAsStringSync('// fixed\n');
      file(
        'flutter_native_splash.yaml',
      ).writeAsStringSync('flutter_native_splash:\n  image: assets/images/splash.png\n');
      expect(await run(['unused', '--fail-on-broken']), ExitCode.success);
    });

    test('flag combinations are validated', () async {
      expect(await run(['unused', '--include-source']), ExitCode.usage);
      expect(await run(['unused', '--json', '--delete']), ExitCode.usage);
    });
  });

  group('build', () {
    test('warns about broken references', () async {
      copyDir('test/fixtures/sample_app', tmp.path);
      Directory(p.join(tmp.path, 'assets_src')).deleteSync(recursive: true);
      final result = await Process.run('dart', [
        'run',
        p.absolute('bin/asset_kit.dart'),
        'build',
      ], workingDirectory: tmp.path);
      expect(result.exitCode, 0);
      expect('${result.stderr}', contains('2 broken asset reference(s)'));
      expect(
        '${result.stdout}',
        contains("did you mean 'assets/images/logo.webp' or Assets.images.logo?"),
      );
    });

    test('runs optimize, gen and pubspec sync', () async {
      writeDemoSources(p.join(tmp.path, 'assets_src'));
      file('pubspec.yaml').writeAsStringSync(
        'name: app\nenvironment:\n  sdk: ^3.5.0\n\nflutter:\n  uses-material-design: true\n',
      );
      expect(await run(['build']), ExitCode.success);
      expect(file('lib/gen/assets.gen.dart').readAsStringSync(), contains('final String logo ='));
      final pubspec = file('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/images/'));
      expect(pubspec, isNot(contains('2.0x')));
      expect(
        pubspec,
        isNot(contains('- assets/fonts/\n')),
        reason: 'fonts are not an assets folder',
      );
      expect(
        pubspec,
        contains(
          '- family: Cairo\n      fonts:\n        - asset: assets/fonts/Cairo-Bold.ttf\n          weight: 700',
        ),
      );
      expect(
        file('lib/gen/assets.gen.dart').readAsStringSync(),
        contains("static const String cairo = 'Cairo';"),
      );
      expect(Directory(p.join(tmp.path, '.asset_kit', 'backups')).listSync(), hasLength(1));
      // Second build: nothing to do, no new backup.
      expect(await run(['build']), ExitCode.success);
      expect(Directory(p.join(tmp.path, '.asset_kit', 'backups')).listSync(), hasLength(1));
    });

    test('works without a source folder (gen + sync only)', () async {
      copyDir('test/fixtures/sample_app', tmp.path);
      Directory(p.join(tmp.path, 'assets_src')).deleteSync(recursive: true);
      expect(await run(['build']), ExitCode.success);
      expect(file('pubspec.yaml').readAsStringSync(), contains('- assets/images/onboarding/'));
    });

    test('--dry-run writes nothing', () async {
      copyDir('test/fixtures/sample_app', tmp.path);
      final before = file('pubspec.yaml').readAsStringSync();
      expect(await run(['--dry-run', 'build']), ExitCode.success);
      expect(file('pubspec.yaml').readAsStringSync(), before);
      expect(Directory(p.join(tmp.path, '.asset_kit')).existsSync(), isFalse);
    });

    test('exits 1 if optimize fails, but still generates and syncs', () async {
      writeDemoSources(p.join(tmp.path, 'assets_src'));
      file('assets_src/images/corrupt.png').writeAsStringSync('nope');
      file('pubspec.yaml').writeAsStringSync('name: app\n');
      expect(await run(['build']), ExitCode.failure);
      expect(file('lib/gen/assets.gen.dart').existsSync(), isTrue);
      expect(file('pubspec.yaml').readAsStringSync(), contains('assets/images/'));
    });

    test('missing pubspec.yaml is an error', () async {
      writeDemoSources(p.join(tmp.path, 'assets_src'));
      expect(await run(['build']), ExitCode.failure);
    });
  });

  test('unknown commands and flags are usage errors', () async {
    expect(await run(['nope']), ExitCode.usage);
    expect(await run(['gen', '--nope']), ExitCode.usage);
  });

  test('--version', () async {
    expect(await run(['--version']), ExitCode.success);
  });
}
