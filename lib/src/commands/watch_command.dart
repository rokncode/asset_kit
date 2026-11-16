import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../errors.dart';
import '../processors/build_watcher.dart';
import 'base_command.dart';
import 'build_command.dart';

class WatchCommand extends AssetKitCommand {
  WatchCommand({super.workingDir, this.stopSignal}) {
    argParser.addOption(
      'debounce',
      valueHelp: 'ms',
      defaultsTo: '300',
      help: 'Wait this long after the last change before building.',
    );
  }

  /// Completes to stop watching; defaults to Ctrl+C. Injectable for tests.
  final Future<void>? stopSignal;

  @override
  String get name => 'watch';

  @override
  String get description => 'Re-run build whenever the source folder or asset_kit.yaml changes.';

  @override
  Future<int> run() async {
    final debounce = int.tryParse(argResults!.option('debounce')!);
    if (debounce == null || debounce < 0) {
      usageException('--debounce must be a number of milliseconds.');
    }

    announceDryRun();
    await runBuild(config, logger, dryRun: dryRun);

    final watcher = BuildWatcher(
      config: config,
      logger: logger,
      debounce: Duration(milliseconds: debounce),
      build: (cfg) => runBuild(cfg, logger, dryRun: dryRun),
      reloadConfig: config.loadedFromFile
          ? () => AssetKitConfig.load(configPath: config.configFile, workingDir: workingDir)
          : null,
    );
    await watcher.start();
    final configName = config.configFile == null
        ? null
        : p.relative(config.configFile!, from: workingDir);
    logger
      ..info('')
      ..info(
        'Watching ${logger.bold('${config.source}/')}'
        '${configName == null ? '' : ' and ${logger.bold(configName)}'}. Press Ctrl+C to stop.',
      );

    await (stopSignal ?? ProcessSignal.sigint.watch().first);
    await watcher.stop();
    logger.info('Stopped watching after ${watcher.buildCount} rebuild(s).');
    return ExitCode.success;
  }
}
