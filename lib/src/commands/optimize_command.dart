import '../config.dart';
import '../errors.dart';
import '../logger.dart';
import '../processors/cwebp.dart';
import '../processors/optimizer.dart';
import '../table.dart';
import 'base_command.dart';

class OptimizeCommand extends AssetKitCommand {
  OptimizeCommand({super.workingDir}) {
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
      )
      ..addFlag(
        'precompile-svg',
        defaultsTo: null,
        help: 'Also compile SVGs to .vec with vector_graphics_compiler (overrides svg.precompile).',
      );
  }

  @override
  String get name => 'optimize';

  @override
  String get description => 'Compress and convert images and generate resolution variants.';

  @override
  Future<int> run() async {
    announceDryRun();
    final jobsArg = argResults!.option('jobs');
    final jobs = jobsArg == null ? null : int.tryParse(jobsArg);
    if (jobsArg != null && (jobs == null || jobs < 1)) {
      usageException('--jobs must be a positive integer.');
    }

    final report = await runOptimize(
      config,
      logger,
      OptimizeOptions(
        dryRun: dryRun,
        force: argResults!.flag('force'),
        jobs: jobs,
        precompileSvg: argResults!['precompile-svg'] as bool?,
      ),
    );
    return report.hasErrors ? ExitCode.failure : ExitCode.success;
  }
}

/// Detects cwebp, runs the optimizer and prints the summary. Shared with `build`.
Future<OptimizeReport> runOptimize(
  AssetKitConfig config,
  Logger logger,
  OptimizeOptions options,
) async {
  final wantsWebp = config.images.format != ImageFormat.png;
  final cwebp = wantsWebp ? await Cwebp.detect() : null;
  if (wantsWebp && cwebp == null) {
    logger.warn(
      'cwebp was not found, so images will be written as optimized PNG '
      '(JPEG photos stay JPEG) instead of WebP.',
    );
    logger.info('  Install libwebp to get WebP output:');
    for (final line in cwebpInstallInstructions()) {
      logger.info('    $line');
    }
  }
  logger.detail(
    cwebp == null
        ? 'Encoder: built-in PNG encoder'
        : 'Encoder: ${cwebp.executable} ${cwebp.version}',
  );

  final report = await Optimizer(config, logger, options: options, cwebp: cwebp).run();
  printOptimizeSummary(report, logger, dryRun: options.dryRun);
  return report;
}

void printOptimizeSummary(OptimizeReport report, Logger logger, {required bool dryRun}) {
  final failed = report.files.where((f) => f.status == FileStatus.failed).toList();
  final cachedCount = report.cached.length;

  if (dryRun) {
    final planned = report.files.where((f) => f.status == FileStatus.planned).toList();
    for (final f in planned) {
      logger.info('  would write ${f.outputs.join(', ')}');
      if (f.skippedScales.isNotEmpty) {
        logger.info(
          logger.yellow(
            '    (source too small for ${f.skippedScales.map((s) => '${s}x').join(', ')})',
          ),
        );
      }
    }
    for (final stale in report.removedStale) {
      logger.info('  would remove stale $stale');
    }
    logger.info('${planned.length} file(s) to process, $cachedCount unchanged.');
  } else {
    final processed = report.processed.toList();
    if (processed.isNotEmpty) {
      final rows = [
        for (final f in processed)
          [
            f.source,
            '${f.outputs.length}',
            formatBytes(f.sourceSize),
            formatBytes(f.outputSize),
            '${percentSaved(f.sourceSize, f.outputSize).toStringAsFixed(1)}%',
          ],
      ];
      final totalIn = processed.fold<int>(0, (s, f) => s + f.sourceSize);
      final totalOut = processed.fold<int>(0, (s, f) => s + f.outputSize);
      logger
        ..info('')
        ..info(
          renderTable(
            ['File', 'Files out', 'Original', 'Optimized', 'Saved'],
            rows,
            rightAligned: {1, 2, 3, 4},
            footer: [
              'Total (${processed.length})',
              '${processed.fold<int>(0, (s, f) => s + f.outputs.length)}',
              formatBytes(totalIn),
              formatBytes(totalOut),
              '${percentSaved(totalIn, totalOut).toStringAsFixed(1)}%',
            ],
            colorize: (row, column, padded) {
              if (column != 4 || row < 0) return padded;
              return padded.trimLeft().startsWith('-') ? logger.red(padded) : logger.green(padded);
            },
          ),
        )
        ..info(logger.dim('Optimized = all scale variants combined. Encoder: ${report.encoder}.'));
    }
    for (final stale in report.removedStale) {
      logger.detail('removed stale $stale');
    }
    final parts = [
      '${processed.length} processed',
      '$cachedCount unchanged',
      if (report.removedStale.isNotEmpty) '${report.removedStale.length} stale output(s) removed',
      if (failed.isNotEmpty) logger.red('${failed.length} failed'),
    ];
    logger.info('');
    if (failed.isEmpty) {
      logger.success(parts.join(', '));
    } else {
      logger.info(parts.join(', '));
    }
  }

  for (final f in failed) {
    logger.error('${f.source}: ${f.error}');
  }
}
