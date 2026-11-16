import 'dart:io';

import '../errors.dart';

/// A located `cwebp` binary (from libwebp).
class Cwebp {
  Cwebp(this.executable, this.version);

  final String executable;
  final String version;

  /// Finds `cwebp` on the PATH, or at `$ASSET_KIT_CWEBP` if set. Setting
  /// that variable to an empty string disables cwebp (useful for testing
  /// the PNG fallback).
  static Future<Cwebp?> detect({Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    final executable = env['ASSET_KIT_CWEBP'] ?? 'cwebp';
    if (executable.isEmpty) return null;
    try {
      final result = await Process.run(executable, ['-version']);
      if (result.exitCode != 0) return null;
      final version = '${result.stdout}'.split('\n').first.trim();
      return Cwebp(executable, version);
    } on ProcessException {
      return null;
    }
  }

  /// Encodes [input] (PNG, JPEG, TIFF or WebP) to WebP at [output].
  ///
  /// Resizing is done by cwebp itself (premultiplied-alpha rescaler) when
  /// [width]/[height] differ from the source. Metadata is always stripped.
  Future<void> encode({
    required String input,
    required String output,
    required int quality,
    required bool lossless,
    int? width,
    int? height,
  }) async {
    final args = [
      '-quiet',
      '-metadata',
      'none',
      if (lossless) ...['-z', '6'] else ...['-q', '$quality', '-m', '6', '-sharp_yuv'],
      if (width != null && height != null) ...['-resize', '$width', '$height'],
      input,
      '-o',
      output,
    ];
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      throw AssetKitException(
        'cwebp failed for $input (exit ${result.exitCode}): ${'${result.stderr}'.trim()}',
        exitCode: ExitCode.software,
      );
    }
  }
}

/// Install instructions for libwebp, current platform first.
List<String> cwebpInstallInstructions() {
  final macos = 'macOS:    brew install webp';
  final linux = 'Linux:    sudo apt install webp   (Fedora: sudo dnf install libwebp-tools)';
  final windows =
      'Windows:  choco install webp   or   scoop install libwebp\n'
      '          (or download from https://developers.google.com/speed/webp/download and add bin/ to PATH)';
  if (Platform.isMacOS) return [macos, linux, windows];
  if (Platform.isWindows) return [windows, macos, linux];
  return [linux, macos, windows];
}
