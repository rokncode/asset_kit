import 'dart:io';

/// Colored, verbosity-aware terminal output.
///
/// Colors are disabled automatically when stdout is not a terminal that
/// supports ANSI escapes, or when the `NO_COLOR` environment variable is set.
class Logger {
  Logger({this.verbose = false, bool? ansi, StringSink? out, StringSink? err})
    : ansi = ansi ?? (stdout.supportsAnsiEscapes && !Platform.environment.containsKey('NO_COLOR')),
      _out = out ?? stdout,
      _err = err ?? stderr;

  final bool verbose;
  final bool ansi;
  final StringSink _out;
  final StringSink _err;

  int warningCount = 0;

  String _wrap(String code, String text) => ansi ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String text) => _wrap('1', text);
  String dim(String text) => _wrap('2', text);
  String red(String text) => _wrap('31', text);
  String green(String text) => _wrap('32', text);
  String yellow(String text) => _wrap('33', text);
  String cyan(String text) => _wrap('36', text);

  void info(String message) => _out.writeln(message);

  void detail(String message) {
    if (verbose) _out.writeln(dim(message));
  }

  void success(String message) => _out.writeln('${green('✓')} $message');

  void warn(String message) {
    warningCount++;
    _err.writeln('${yellow('warning')} $message');
  }

  void error(String message) => _err.writeln('${red('error')} $message');

  void hint(String message) => _err.writeln('  ${cyan('hint')} $message');

  /// Prints a single "[3/10] doing x" style progress line.
  void progress(int current, int total, String message) {
    final width = '$total'.length;
    info('${dim('[${'$current'.padLeft(width)}/$total]')} $message');
  }
}
