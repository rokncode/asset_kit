import 'dart:io';

import 'package:path/path.dart' as p;

import '../codegen/assets_generator.dart';
import '../codegen/format_settings.dart';
import '../config.dart';
import '../errors.dart';
import '../processors/fonts.dart';
import '../logger.dart';
import '../scanner/asset_index.dart';
import 'base_command.dart';

class GenCommand extends AssetKitCommand {
  GenCommand({super.workingDir});

  @override
  String get name => 'gen';

  @override
  String get description => 'Generate type-safe Dart constants for every asset.';

  @override
  Future<int> run() async {
    announceDryRun();
    runGen(config, logger, dryRun: dryRun);
    return ExitCode.success;
  }
}

/// Result of a codegen run.
typedef GenResult = ({int assetCount, int skippedCount, bool changed});

/// Generates the constants file. Shared with `build`.
GenResult runGen(AssetKitConfig config, Logger logger, {required bool dryRun}) {
  final assetsRoot = p.posix.joinAll(
    p.split(p.relative(config.outputDir, from: config.projectRoot)),
  );
  if (!Directory(config.outputDir).existsSync()) {
    throw AssetKitException(
      'Assets folder "${config.output}" does not exist.',
      hint: 'Run `asset_kit optimize` first, or set `output` in $defaultConfigFileName.',
    );
  }

  final index = AssetIndex.scan(projectRoot: config.projectRoot, assetsDir: config.outputDir);
  for (final orphan in index.orphanVariants) {
    logger.warn('$orphan has no 1x main asset, so Flutter will not bundle it. Skipped.');
  }

  final generator = AssetsGenerator(
    assetsRoot: assetsRoot,
    className: config.codegen.className,
    names: config.codegen.names,
    fontFamilies: registeredFontFamilies(config.pubspecFile),
    formatSettings: FormatSettings.forProject(config.projectRoot),
  );
  final code = generator.generate(index.entries);
  final file = File(config.codegenOutputFile);
  final relOut = p.relative(file.path, from: config.projectRoot);

  for (final key in generator.unusedNames) {
    logger.warn('`codegen.names` entry "$key" matches no file or folder in ${config.output}/.');
  }
  _reportSkipped(generator.skipped, config, logger, assetsRoot, relOut);

  final referenced = generator.assetCount;
  final changed = !file.existsSync() || file.readAsStringSync() != code;
  if (!changed) {
    logger.success('$relOut is up to date ($referenced assets).');
  } else {
    if (!dryRun) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(code);
    }
    logger.success('${dryRun ? 'Would write' : 'Wrote'} $relOut ($referenced assets).');
  }
  return (assetCount: referenced, skippedCount: generator.skipped.length, changed: changed);
}

void _reportSkipped(
  List<SkippedAsset> skipped,
  AssetKitConfig config,
  Logger logger,
  String assetsRoot,
  String relOut,
) {
  if (skipped.isEmpty) return;
  final count = skipped.length;
  logger.warn('$count ${count == 1 ? 'entry was' : 'entries were'} left out of $relOut:');
  for (final s in skipped) {
    final path = s.key.startsWith('font:')
        ? 'font family "${s.key.substring(5)}"'
        : '${p.posix.join(assetsRoot, s.key)}${s.isFolder ? '/' : ''}';
    logger.info('    $path  ${logger.dim('(${s.explanation})')}');
  }
  final configName = config.configFile == null
      ? defaultConfigFileName
      : p.relative(config.configFile!, from: config.projectRoot);
  logger.info('  Give them names in $configName (replace <name>):');
  for (final line in namesConfigSnippet(skipped).trimRight().split('\n')) {
    logger.info('    ${logger.cyan(line)}');
  }
}
