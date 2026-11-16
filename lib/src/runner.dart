import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/build_command.dart';
import 'commands/gen_command.dart';
import 'commands/init_command.dart';
import 'commands/optimize_command.dart';
import 'commands/unused_command.dart';
import 'commands/watch_command.dart';
import 'errors.dart';
import 'logger.dart';

const version = '0.1.0';

class AssetKitRunner extends CommandRunner<int> {
  AssetKitRunner({String? workingDir, Confirm? confirm})
    : super(
        'asset_kit',
        'Manage Flutter assets: optimize images, generate constants, find unused files.',
      ) {
    argParser
      ..addFlag('dry-run', negatable: false, help: 'Show what would change without writing files.')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Print detailed output.')
      ..addOption(
        'config',
        abbr: 'c',
        valueHelp: 'path',
        help: 'Path to the config file (default: asset_kit.yaml).',
      )
      ..addFlag('version', negatable: false, help: 'Print the version.');
    addCommand(InitCommand(workingDir: workingDir));
    addCommand(GenCommand(workingDir: workingDir));
    addCommand(OptimizeCommand(workingDir: workingDir));
    addCommand(UnusedCommand(workingDir: workingDir, confirm: confirm));
    addCommand(BuildCommand(workingDir: workingDir));
    addCommand(WatchCommand(workingDir: workingDir));
  }

  @override
  Future<int> run(Iterable<String> args) async {
    final logger = Logger();
    try {
      final results = parse(args);
      if (results.flag('version')) {
        logger.info('asset_kit $version');
        return ExitCode.success;
      }
      return await runCommand(results) ?? ExitCode.success;
    } on UsageException catch (e) {
      logger
        ..error(e.message)
        ..info('')
        ..info(e.usage);
      return ExitCode.usage;
    } on AssetKitException catch (e) {
      logger.error(e.message);
      if (e.hint != null) logger.hint(e.hint!);
      return e.exitCode;
    } on FileSystemException catch (e) {
      logger.error(
        '${e.message}${e.path == null ? '' : ': ${e.path}'}'
        '${e.osError == null ? '' : ' (${e.osError!.message})'}',
      );
      return ExitCode.io;
    } on Object catch (e, stack) {
      logger.error('Unexpected error: $e');
      if (args.contains('--verbose') || args.contains('-v')) {
        logger.info('$stack');
      } else {
        logger.hint('Run with --verbose for a stack trace, and please report this as a bug.');
      }
      return ExitCode.software;
    }
  }
}
