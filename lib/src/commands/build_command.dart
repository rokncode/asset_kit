import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../logger.dart';
import '../processors/optimizer.dart';
import '../processors/pubspec_sync.dart';
import 'base_command.dart';
import '../codegen/assets_generator.dart' show yamlKey;
import '../config.dart';
import '../scanner/unused_scanner.dart';
import 'gen_command.dart';
import 'unused_command.dart';
import 'optimize_command.dart';

class BuildCommand extends AssetKitCommand {
  BuildCommand({super.workingDir}) {
    argParser
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Ignore the cache and reprocess every file.',
      )
      ..addOption(
        'jobs',
        abbr: 'j',
        valueHelp: 'n',
        help: 'Files to process in parallel (default: CPU count).',
      );
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Run optimize, gen and pubspec sync in one go.';

  @override
  Future<int> run() async {
    announceDryRun();
    final jobsArg = argResults!.option('jobs');
    final jobs = jobsArg == null ? null : int.tryParse(jobsArg);
    if (jobsArg != null && (jobs == null || jobs < 1)) {
      usageException('--jobs must be a positive integer.');
    }
    return runBuild(config, logger, dryRun: dryRun, force: argResults!.flag('force'), jobs: jobs);
  }
}

/// optimize → pubspec sync → gen, then a broken-reference check.
/// Shared with `watch`.
Future<int> runBuild(
  AssetKitConfig config,
  Logger logger, {
  bool dryRun = false,
  bool force = false,
  int? jobs,
}) async {
  var exitCode = ExitCode.success;

  logger.info(logger.bold('Optimize'));
  if (Directory(config.sourceDir).existsSync()) {
    final report = await runOptimize(
      config,
      logger,
      OptimizeOptions(dryRun: dryRun, force: force, jobs: jobs),
    );
    if (report.hasErrors) exitCode = ExitCode.failure;
  } else {
    logger.info(
      logger.dim('  No ${config.source}/ folder; skipping (only sync and gen will run).'),
    );
  }

  // Sync before gen: the FontFamily constants come from pubspec.yaml.
  logger
    ..info('')
    ..info(logger.bold('Sync pubspec.yaml'));
  final sync = syncPubspec(config, dryRun: dryRun);
  printSyncResult(sync, logger, dryRun: dryRun);

  if (Directory(config.outputDir).existsSync()) {
    logger
      ..info('')
      ..info(logger.bold('Generate'));
    runGen(config, logger, dryRun: dryRun);

    final broken = UnusedScanner(config).scan().broken;
    if (broken.isNotEmpty) {
      logger.warn(
        '${broken.length} broken asset reference(s): code points at files that do not exist.',
      );
      printBrokenReferences(broken, logger);
    }
  }
  return exitCode;
}

void printSyncResult(PubspecSyncResult sync, Logger logger, {required bool dryRun}) {
  final plan = sync.fontPlan;
  if (plan != null) {
    if (plan.unknown.isNotEmpty) {
      logger.warn(
        '${plan.unknown.length} font file(s) have a name asset_kit cannot read, so they were '
        'not registered (weights are never guessed):',
      );
      for (final u in plan.unknown) {
        logger.info('    ${u.key}');
      }
      logger.info(
        '  Add them to asset_kit.yaml (replace <weight> with 100–900, and check the family):',
      );
      logger.info('    ${logger.cyan('fonts:')}');
      logger.info('      ${logger.cyan('overrides:')}');
      for (final u in plan.unknown) {
        logger.info(
          '        ${logger.cyan('${yamlKey(u.key)}: { family: ${u.guessedFamily}, weight: <weight> }')}',
        );
      }
    }
    for (final face in plan.variableFaces) {
      logger.info(
        logger.dim(
          '  ${face.asset} is a variable font: registered once without a weight. '
          'In Flutter, pick weights with fontWeight, or FontVariation(\'wght\', 650) for in-between values.',
        ),
      );
    }
  }
  for (final family in sync.fontsSkipped) {
    logger.warn(
      'Font family "$family" is already registered with files outside the assets folder; '
      'left unchanged.',
    );
  }

  if (!sync.changed) {
    logger.success('pubspec.yaml is up to date.');
    return;
  }
  for (final dir in sync.added) {
    logger.info('  ${logger.green('+')} $dir');
  }
  for (final dir in sync.removed) {
    logger.info('  ${logger.red('-')} $dir');
  }
  for (final family in sync.fontsAdded) {
    final faces = plan!.byFamily[family]!;
    logger.info('  ${logger.green('+')} font $family (${faces.map((f) => f.describe).join(', ')})');
  }
  for (final family in sync.fontsUpdated) {
    final faces = plan!.byFamily[family]!;
    logger.info(
      '  ${logger.yellow('~')} font $family (${faces.map((f) => f.describe).join(', ')})',
    );
  }
  for (final family in sync.fontsRemoved) {
    logger.info('  ${logger.red('-')} font $family');
  }
  if (dryRun) {
    logger.info('Would update pubspec.yaml.');
  } else {
    logger.success('Updated pubspec.yaml (backup: ${p.relative(sync.backup!)}).');
  }
}
