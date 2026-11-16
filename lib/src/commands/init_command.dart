import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../errors.dart';
import 'base_command.dart';

class InitCommand extends AssetKitCommand {
  InitCommand({super.workingDir}) {
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Overwrite an existing config file.',
    );
  }

  @override
  String get name => 'init';

  @override
  String get description => 'Create $defaultConfigFileName and the source folder.';

  @override
  Future<int> run() async {
    announceDryRun();
    final configFile = File(
      p.normalize(p.absolute(workingDir, configPath ?? defaultConfigFileName)),
    );
    final root = configFile.parent.path;

    if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
      logger.warn('No pubspec.yaml in $root. Is this the root of a Flutter project?');
    }

    if (configFile.existsSync() && !argResults!.flag('force')) {
      throw AssetKitException(
        '${p.relative(configFile.path, from: workingDir)} already exists.',
        hint: 'Use --force to overwrite it.',
      );
    }
    _write(configFile, defaultConfigYaml, root);

    // Parse what we just wrote so a custom --config location still resolves
    // the source folder correctly.
    final cfg = AssetKitConfig.parse(defaultConfigYaml, projectRoot: root);
    for (final sub in ['images', 'icons', 'fonts']) {
      final dir = Directory(p.join(cfg.sourceDir, sub));
      if (dir.existsSync()) continue;
      if (!dryRun) dir.createSync(recursive: true);
      logger.success('Created ${p.relative(dir.path, from: root)}/');
    }

    final gitignore = File(p.join(root, '.gitignore'));
    if (gitignore.existsSync()) {
      final lines = gitignore.readAsLinesSync();
      if (!lines.any((l) => l.trim() == '.asset_kit/' || l.trim() == '.asset_kit')) {
        if (!dryRun) {
          final prefix = gitignore.readAsStringSync().endsWith('\n') ? '' : '\n';
          gitignore.writeAsStringSync(
            '$prefix\n# asset_kit build cache\n.asset_kit/\n',
            mode: FileMode.append,
          );
        }
        logger.success('Added .asset_kit/ to .gitignore');
      }
    }

    logger
      ..info('')
      ..info(
        'Next: drop originals into ${logger.bold('${cfg.source}/')} and run ${logger.bold('asset_kit build')}.',
      );
    return ExitCode.success;
  }

  void _write(File file, String content, String root) {
    if (!dryRun) file.writeAsStringSync(content);
    logger.success('Created ${p.relative(file.path, from: root)}');
  }
}
