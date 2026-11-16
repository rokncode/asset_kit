import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../config.dart';
import '../errors.dart';
import '../logger.dart';

/// Whether a changed file should be ignored: editor swap/backup files,
/// partial downloads, OS metadata and asset_kit's own temp files.
bool isIgnoredChange(String path) {
  final name = p.basename(path);
  if (name.startsWith('.')) return true; // .DS_Store, .#lock, .swp files
  if (name.endsWith('~')) return true; // Emacs/gedit backups
  if (name.startsWith('#') && name.endsWith('#')) return true; // Emacs autosave
  if (name == '4913') return true; // Vim's write test file
  const suffixes = ['.swp', '.swo', '.swx', '.tmp', '.temp', '.crdownload', '.part', '.download'];
  final lower = name.toLowerCase();
  return suffixes.any(lower.endsWith);
}

/// Runs a build whenever the source folder or the config file changes.
///
/// - Only the source folder (recursively) and the config file are watched;
///   never the output folder or generated code, so builds can't trigger
///   themselves.
/// - Events are debounced: a burst (e.g. a bulk export) runs one build.
/// - Changes that arrive during a build trigger exactly one more build.
/// - If the config becomes invalid, the error is printed and watching
///   continues; the next valid save builds again.
class BuildWatcher {
  BuildWatcher({
    required AssetKitConfig config,
    required this.build,
    required this.logger,
    this.reloadConfig,
    this.debounce = const Duration(milliseconds: 300),
  }) : _config = config;

  /// Runs one build with the current config.
  final Future<void> Function(AssetKitConfig config) build;

  /// Re-reads the config file; null disables config reloading.
  final AssetKitConfig Function()? reloadConfig;
  final Logger logger;
  final Duration debounce;

  AssetKitConfig _config;
  AssetKitConfig get config => _config;

  StreamSubscription<WatchEvent>? _sourceSub;
  StreamSubscription<FileSystemEvent>? _configSub;
  Timer? _timer;
  bool _building = false;
  bool _pending = false;
  bool _reload = false;
  bool _configValid = true;
  final _changed = <String>{};
  Completer<void>? _idle;

  /// Number of builds started; for tests and status output.
  int buildCount = 0;

  /// Starts watching. Completes once the watchers are ready.
  Future<void> start() async {
    if (!Directory(_config.sourceDir).existsSync()) {
      throw AssetKitException(
        'Source folder "${_config.source}" does not exist, so there is nothing to watch.',
        hint: 'Run `asset_kit init` first.',
      );
    }
    await _watchSource();
    _watchConfig();
  }

  Future<void> _watchSource() async {
    await _sourceSub?.cancel();
    final watcher = DirectoryWatcher(_config.sourceDir);
    _sourceSub = watcher.events.listen((event) {
      if (isIgnoredChange(event.path)) return;
      _changed.add(p.relative(event.path, from: _config.sourceDir));
      _schedule();
    });
    await watcher.ready;
  }

  void _watchConfig() {
    final path = _config.configFile;
    if (path == null || reloadConfig == null) return;
    final name = p.basename(path);
    // Watch the folder rather than the file: editors that save by renaming
    // a temp file over the original would otherwise end the watch.
    _configSub = Directory(p.dirname(path)).watch().listen((event) {
      final names = {
        p.basename(event.path),
        if (event is FileSystemMoveEvent) p.basename(event.destination ?? ''),
      };
      if (!names.contains(name)) return;
      _reload = true;
      _changed.add(name);
      _schedule();
    });
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, _run);
  }

  Future<void> _run() async {
    if (_building) {
      _pending = true;
      return;
    }
    _building = true;
    _idle ??= Completer<void>();
    try {
      final changed = _changed.toList()..sort();
      _changed.clear();
      logger
        ..info('')
        ..info(
          logger.cyan(
            'Change detected: ${changed.take(5).join(', ')}'
            '${changed.length > 5 ? ' and ${changed.length - 5} more' : ''}',
          ),
        );

      if (_reload) {
        _reload = false;
        try {
          final next = reloadConfig!();
          next.warnings.forEach(logger.warn);
          final sourceMoved = !p.equals(next.sourceDir, _config.sourceDir);
          _config = next;
          if (!_configValid) logger.success('Config is valid again.');
          _configValid = true;
          if (sourceMoved) {
            if (!Directory(next.sourceDir).existsSync()) {
              throw AssetKitException('Source folder "${next.source}" does not exist.');
            }
            logger.info('Now watching ${next.source}/.');
            await _watchSource();
          }
        } on AssetKitException catch (e) {
          _configValid = false;
          logger.error(e.message);
          if (e.hint != null) logger.hint(e.hint!);
          logger.info(
            logger.dim(
              'Still watching; fix ${p.basename(_config.configFile ?? defaultConfigFileName)} to build again.',
            ),
          );
          return;
        }
      }
      if (!_configValid) {
        logger.info(logger.dim('Skipping build until the config is valid.'));
        return;
      }

      buildCount++;
      try {
        await build(_config);
      } on AssetKitException catch (e) {
        logger.error(e.message);
        if (e.hint != null) logger.hint(e.hint!);
      } on Object catch (e) {
        // Anything else (e.g. a file deleted mid-export) must not end the
        // watch: report it and wait for the next change.
        logger.error('Build failed: $e');
      }
      logger.info(logger.dim('Watching for changes…'));
    } finally {
      _building = false;
      if (_pending) {
        _pending = false;
        _schedule();
      } else {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// Completes when no build is running or scheduled. For tests.
  Future<void> get idle async {
    while (_timer?.isActive ?? false) {
      await Future<void>.delayed(debounce);
    }
    await _idle?.future;
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _sourceSub?.cancel();
    await _configSub?.cancel();
  }
}
