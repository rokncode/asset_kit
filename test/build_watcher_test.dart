import 'dart:async';
import 'dart:io';

import 'package:asset_kit/src/config.dart';
import 'package:asset_kit/src/logger.dart';
import 'package:asset_kit/src/processors/build_watcher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('isIgnoredChange', () {
    for (final ignored in [
      'a/.DS_Store',
      'a/.logo.png.swp',
      'logo.png.swp',
      'logo.png.swo',
      'logo.png~',
      '#logo.png#',
      '4913',
      'export.tmp',
      'logo.png.crdownload',
      'x.part',
      'logo.png.asset_kit.tmp',
      '.hidden.png',
    ]) {
      expect(isIgnoredChange(ignored), isTrue, reason: ignored);
    }
    for (final kept in [
      'logo.png',
      'images/a.svg',
      'fonts/Cairo-Bold.ttf',
      'temp.png',
      'swp.png',
    ]) {
      expect(isIgnoredChange(kept), isFalse, reason: kept);
    }
  });

  group('BuildWatcher', () {
    late Directory tmp;
    late BuildWatcher watcher;
    late List<AssetKitConfig> builds;
    late StringBuffer out, err;
    var buildDelay = Duration.zero;

    String path(String rel) => p.join(tmp.path, rel);
    void write(String rel, [String content = 'x']) => File(path(rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);

    AssetKitConfig load() => AssetKitConfig.load(workingDir: tmp.path);

    /// Waits for the file system to deliver events and the debounced build
    /// to finish. FSEvents on macOS can take a moment.
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watcher.idle;
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('asset_kit_watch');
      // Resolve symlinks (/var → /private/var on macOS) so event paths match.
      tmp = Directory(tmp.resolveSymbolicLinksSync());
      write('asset_kit.yaml', 'source: assets_src\noutput: assets\n');
      Directory(path('assets_src/images')).createSync(recursive: true);
      Directory(path('assets')).createSync();
      builds = [];
      buildDelay = Duration.zero;
      out = StringBuffer();
      err = StringBuffer();
      watcher = BuildWatcher(
        config: load(),
        logger: Logger(ansi: false, out: out, err: err),
        debounce: const Duration(milliseconds: 150),
        reloadConfig: load,
        build: (cfg) async {
          builds.add(cfg);
          await Future<void>.delayed(buildDelay);
        },
      );
      await watcher.start();
    });

    tearDown(() async {
      await watcher.stop();
      tmp.deleteSync(recursive: true);
    });

    test('a burst of changes runs one build', () async {
      for (var i = 0; i < 10; i++) {
        write('assets_src/images/img_$i.png');
      }
      await settle();
      expect(builds, hasLength(1));
      expect(out.toString(), contains('Change detected: images/img_0.png'));
      expect(out.toString(), contains('and 5 more'));
    });

    test('editor temp files and OS metadata do not trigger builds', () async {
      write('assets_src/images/.logo.png.swp');
      write('assets_src/images/logo.png~');
      write('assets_src/images/.DS_Store');
      write('assets_src/images/export.tmp');
      await settle();
      expect(builds, isEmpty);
    });

    test('changes in the output folder and generated code are ignored', () async {
      write('assets/images/logo.webp');
      write('lib/gen/assets.gen.dart');
      await settle();
      expect(builds, isEmpty);
    });

    test('deleting a source file triggers a build', () async {
      write('assets_src/images/a.png');
      await settle();
      File(path('assets_src/images/a.png')).deleteSync();
      await settle();
      expect(builds, hasLength(2));
    });

    test('an invalid config is reported, watching continues, and a fix builds again', () async {
      write('asset_kit.yaml', 'source: assets_src\noutput: assets\nimages: {quality: 500}\n');
      await settle();
      expect(builds, isEmpty);
      expect(err.toString(), contains('`images.quality` must be an integer from 0 to 100'));
      expect(out.toString(), contains('Still watching'));

      // Source changes while the config is broken don't build either.
      write('assets_src/images/a.png');
      await settle();
      expect(builds, isEmpty);

      write('asset_kit.yaml', 'source: assets_src\noutput: assets\nimages: {quality: 50}\n');
      await settle();
      expect(builds, hasLength(1));
      expect(builds.single.images.quality, 50);
      expect(out.toString(), contains('Config is valid again.'));
    });

    test('config saved via rename (atomic save) is still picked up', () async {
      write('asset_kit.tmp.yaml', 'source: assets_src\noutput: assets\nimages: {quality: 42}\n');
      File(path('asset_kit.tmp.yaml')).renameSync(path('asset_kit.yaml'));
      await settle();
      expect(builds.single.images.quality, 42);
      // And a second save after the rename still works.
      write('asset_kit.yaml', 'source: assets_src\noutput: assets\nimages: {quality: 43}\n');
      await settle();
      expect(builds.last.images.quality, 43);
    });

    test('changes during a build cause exactly one more build', () async {
      buildDelay = const Duration(milliseconds: 800);
      write('assets_src/images/a.png');
      await Future<void>.delayed(const Duration(milliseconds: 500)); // build running
      write('assets_src/images/b.png');
      write('assets_src/images/c.png');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await watcher.idle;
      expect(builds, hasLength(2));
    });

    test('build errors are printed and watching continues', () async {
      await watcher.stop();
      var calls = 0;
      watcher = BuildWatcher(
        config: load(),
        logger: Logger(ansi: false, out: out, err: err),
        debounce: const Duration(milliseconds: 150),
        build: (cfg) async {
          calls++;
          if (calls == 1) throw Exception('boom');
        },
      );
      await watcher.start();
      write('assets_src/images/a.png');
      await settle();
      expect(err.toString(), contains('Build failed: Exception: boom'));
      write('assets_src/images/b.png');
      await settle();
      expect(calls, 2);
    });
  });
}
