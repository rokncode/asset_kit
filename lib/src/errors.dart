/// Exit codes used by the CLI. They follow the BSD `sysexits.h` conventions
/// where one applies, so CI scripts can tell failure kinds apart.
abstract final class ExitCode {
  static const success = 0;

  /// Generic failure, and also `unused --fail-on-unused` when assets are unused.
  static const failure = 1;

  /// Invalid command line usage.
  static const usage = 64;

  /// Input data is malformed (e.g. a broken pubspec.yaml).
  static const data = 65;

  /// A required external tool is missing or failed.
  static const software = 70;

  /// I/O error while reading or writing files.
  static const io = 74;

  /// Configuration error (bad or missing asset_kit.yaml).
  static const config = 78;
}

/// An error that should be shown to the user without a stack trace.
class AssetKitException implements Exception {
  AssetKitException(this.message, {this.exitCode = ExitCode.failure, this.hint});

  final String message;
  final int exitCode;

  /// An optional suggestion on how to fix the problem.
  final String? hint;

  @override
  String toString() => message;
}

class ConfigException extends AssetKitException {
  ConfigException(super.message, {super.hint}) : super(exitCode: ExitCode.config);
}
