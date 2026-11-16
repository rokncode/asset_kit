import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../logger.dart';
import '../processors/asset_deleter.dart';
import '../processors/build_cache.dart';
import '../scanner/unused_scanner.dart';
import '../table.dart';
import 'base_command.dart';
import 'gen_command.dart';

/// Asks the user a yes/no question.
typedef Confirm = Future<bool> Function(String question);

Future<bool> terminalConfirm(String question) async {
  if (!stdin.hasTerminal) {
    throw AssetKitException(
      'Deleting needs confirmation, but no terminal is attached.',
      hint: 'Pass --yes to delete without asking (e.g. in CI).',
      exitCode: ExitCode.usage,
    );
  }
  stdout.write('$question [y/N] ');
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

class UnusedCommand extends AssetKitCommand {
  UnusedCommand({super.workingDir, Confirm? confirm}) : _confirm = confirm ?? terminalConfirm {
    argParser
      ..addFlag(
        'delete',
        negatable: false,
        help: 'Delete unused assets (all scale variants) after confirmation.',
      )
      ..addFlag(
        'include-source',
        negatable: false,
        help: 'With --delete, also delete the matching originals in the source folder.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'With --delete, do not ask for confirmation.',
      )
      ..addFlag('json', negatable: false, help: 'Print the report as JSON on stdout.')
      ..addFlag(
        'fail-on-unused',
        negatable: false,
        help: 'Exit with code 1 if any unused asset is found (for CI).',
      )
      ..addFlag(
        'fail-on-broken',
        negatable: false,
        help: 'Exit with code 1 if code references an asset path that does not exist (for CI).',
      );
  }

  final Confirm _confirm;

  @override
  String get name => 'unused';

  @override
  String get description => 'Report (and optionally delete) assets that nothing references.';

  bool get _json => argResults!.flag('json');

  /// In JSON mode all human-readable output goes to stderr.
  @override
  Logger createLogger() => _json ? Logger(verbose: verbose, out: stderr) : super.createLogger();

  @override
  Future<int> run() async {
    final args = argResults!;
    final delete = args.flag('delete');
    if (args.flag('include-source') && !delete) {
      usageException('--include-source only works with --delete.');
    }
    if (_json && delete && !args.flag('yes')) {
      usageException('--json with --delete requires --yes.');
    }
    announceDryRun();

    var report = UnusedScanner(config).scan();
    if (_json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      printUnusedReport(report, logger);
    }

    if (delete) {
      final deletedAny = await _delete(
        report,
        includeSource: args.flag('include-source'),
        skipConfirm: args.flag('yes'),
      );
      if (deletedAny && !dryRun) report = UnusedScanner(config).scan();
    }

    var exitCode = ExitCode.success;
    final remaining = report.unused.length + report.unusedOrphans.length;
    if (args.flag('fail-on-unused') && remaining > 0) {
      logger.error('$remaining unused asset(s) found.');
      exitCode = ExitCode.failure;
    }
    if (args.flag('fail-on-broken') && report.broken.isNotEmpty) {
      logger.error('${report.broken.length} broken asset reference(s) found.');
      exitCode = ExitCode.failure;
    }
    return exitCode;
  }

  Future<bool> _delete(
    UnusedReport report, {
    required bool includeSource,
    required bool skipConfirm,
  }) async {
    var deletedAny = false;
    final groups = [('unused asset', report.unused), ('unused orphan file', report.unusedOrphans)];
    final cache = BuildCache.load(p.join(config.cacheDir, 'cache.json'));
    for (final (label, results) in groups) {
      if (results.isEmpty) continue;
      final units = [for (final r in results) r.unit];
      final files = units.fold<int>(0, (s, u) => s + u.files.length);
      final size = results.fold<int>(0, (s, r) => s + r.size);
      final sources = includeSource
          ? {for (final u in units) ...sourcesOf(config, u, cache)}
          : const <String>{};
      final what =
          '${units.length} $label${units.length == 1 ? '' : 's'} '
          '($files file${files == 1 ? '' : 's'}, ${formatBytes(size)})'
          '${sources.isEmpty ? '' : ' and ${sources.length} source file${sources.length == 1 ? '' : 's'}'}';
      if (dryRun) {
        logger.info('Would delete $what.');
        continue;
      }
      if (!skipConfirm && !await _confirm('Delete $what?')) {
        logger.info('Skipped.');
        continue;
      }
      final result = deleteUnits(config, units, includeSource: includeSource);
      deletedAny = true;
      for (final f in [...result.deletedFiles, ...result.deletedSources]) {
        logger.detail('deleted $f');
      }
      logger.success(
        'Deleted ${result.deletedFiles.length} file(s)'
        '${result.deletedSources.isEmpty ? '' : ' and ${result.deletedSources.length} source file(s)'}.',
      );
      if (!includeSource && label == 'unused asset') {
        final kept = {for (final u in units) ...sourcesOf(config, u, cache)};
        if (kept.isNotEmpty) {
          logger.warn(
            '${kept.length} source file(s) in ${config.source}/ were kept, so `asset_kit optimize` '
            'will recreate these assets. Use --include-source to delete them too.',
          );
        }
      }
    }
    if (deletedAny && File(config.codegenOutputFile).existsSync()) {
      runGen(config, logger, dryRun: false);
    }
    return deletedAny;
  }
}

void printUnusedReport(UnusedReport report, Logger logger) {
  String files(UnitResult r) =>
      r.unit.files.length == 1 ? '' : logger.dim(' (${r.unit.files.length} files)');

  void table(
    String title,
    List<UnitResult> results, {
    bool withReason = false,
    bool withUsage = false,
  }) {
    if (results.isEmpty) return;
    logger
      ..info('')
      ..info(logger.bold('$title (${results.length})'));
    for (final r in results) {
      final usage = withUsage ? '  ${_usageLabel(r.usage, logger)}' : '';
      logger.info('  ${r.unit.path}  ${formatBytes(r.size)}${files(r)}$usage');
      if (withReason) {
        for (final e in r.evidence.take(3)) {
          logger.info(logger.dim('      ↳ $e'));
        }
        if (r.evidence.length > 3) {
          logger.info(logger.dim('      ↳ …and ${r.evidence.length - 3} more'));
        }
      }
    }
  }

  printBrokenReferences(report.broken, logger);
  table('Unused assets', report.unused);
  table('Possibly used — check these by hand', report.possiblyUsed, withReason: true);
  if (report.orphanCheck) {
    table(
      'Orphan files — in the assets folder but not built from the source folder',
      report.orphans,
      withUsage: true,
    );
  }

  final used = report.results.where((r) => r.usage == Usage.used).length;
  logger
    ..info('')
    ..info(
      logger.dim(
        'Scanned ${report.scannedFiles.length} file(s); ${report.results.length} asset(s): '
        '$used used, ${report.possiblyUsed.length} possibly used, '
        '${report.unused.length + report.unusedOrphans.length} unused'
        '${report.ignored.isEmpty ? '' : ', ${report.ignored.length} ignored'}.',
      ),
    );
  if (report.reclaimableBytes > 0) {
    logger.info(
      'Reclaimable: ${logger.bold(formatBytes(report.reclaimableBytes))} '
      '(unused assets${report.unusedOrphans.isEmpty ? '' : ' and unused orphans'}; run with --delete to remove).',
    );
  } else {
    logger.success('No unused assets.');
  }
}

String _usageLabel(Usage usage, Logger logger) => switch (usage) {
  Usage.used => logger.green('used'),
  Usage.possiblyUsed => logger.yellow('possibly used'),
  Usage.unused => logger.red('unused'),
  Usage.ignored => logger.dim('ignored'),
};

void printBrokenReferences(List<BrokenReference> broken, Logger logger) {
  if (broken.isEmpty) return;
  logger
    ..info('')
    ..info(
      logger.bold(
        logger.red(
          'Broken references (${broken.length}) — these files do not exist; loading them fails at runtime',
        ),
      ),
    );
  for (final b in broken) {
    logger.info('  ${b.location}  ${logger.red(b.path)}');
    if (b.suggestedPath != null) {
      final constant = b.suggestedConstant == null
          ? ''
          : ' or ${logger.cyan(b.suggestedConstant!)}';
      logger.info("      ↳ did you mean ${logger.cyan("'${b.suggestedPath}'")}$constant?");
    }
  }
}
