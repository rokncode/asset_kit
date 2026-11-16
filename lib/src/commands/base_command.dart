import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../config.dart';
import '../logger.dart';

/// Shared plumbing for all commands: global flags, logger and config.
abstract class AssetKitCommand extends Command<int> {
  AssetKitCommand({String? workingDir}) : _workingDir = workingDir;

  final String? _workingDir;

  String get workingDir => _workingDir ?? Directory.current.path;

  ArgResults get _global => globalResults!;

  bool get dryRun => _global.flag('dry-run');
  bool get verbose => _global.flag('verbose');
  String? get configPath => _global.option('config');

  late final Logger logger = createLogger();

  /// Creates the logger; commands can override this (e.g. to route output
  /// to stderr when printing JSON).
  Logger createLogger() => Logger(verbose: verbose);

  late final AssetKitConfig config = _loadConfig();

  AssetKitConfig _loadConfig() {
    final cfg = AssetKitConfig.load(configPath: configPath, workingDir: workingDir);
    if (!cfg.loadedFromFile) {
      logger.warn(
        'No $defaultConfigFileName found; using defaults. Run `asset_kit init` to create one.',
      );
    }
    cfg.warnings.forEach(logger.warn);
    logger.detail('Project root: ${cfg.projectRoot}');
    return cfg;
  }

  /// Prints the "dry run" banner once, if active.
  void announceDryRun() {
    if (dryRun) logger.info(logger.yellow('Dry run: no files will be written.'));
  }
}
