import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

import 'resample.dart';

enum DartEncoding {
  /// Lossless PNG, maximum compression.
  png,

  /// Lossless PNG with fast compression, used as a temporary input for
  /// cwebp when pixels must be rotated first.
  pngIntermediate,

  /// Baseline JPEG at the configured quality.
  jpg,
}

typedef DartVariant = ({String path, int width, int height});

/// Decodes [sourcePath] once and writes each of [variants] in a background
/// isolate, so large images don't block other work.
///
/// Applies EXIF orientation, strips EXIF and text metadata, resizes with
/// [resizeHighQuality] and, for PNG, drops an all-opaque alpha channel.
Future<void> encodeWithDart({
  required String sourcePath,
  required List<DartVariant> variants,
  required DartEncoding encoding,
  int quality = 80,
}) => Isolate.run(() => _encode(sourcePath, variants, encoding, quality));

void _encode(String sourcePath, List<DartVariant> variants, DartEncoding encoding, int quality) {
  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync());
  if (decoded == null) throw FormatException('Unsupported or corrupt image', sourcePath);
  final image = img.bakeOrientation(decoded)
    ..exif = img.ExifData()
    ..textData = null;
  final source = image.numFrames > 1 ? image.getFrame(0) : image;

  for (final v in variants) {
    var out = resizeHighQuality(source, v.width, v.height);
    final bytes = switch (encoding) {
      DartEncoding.png => img.encodePng(dropOpaqueAlpha(out), level: 9, singleFrame: true),
      DartEncoding.pngIntermediate => img.encodePng(out, level: 1, singleFrame: true),
      DartEncoding.jpg => img.encodeJpg(
        out = out.hasAlpha ? out.convert(numChannels: 3) : out,
        quality: quality,
        chroma: img.JpegChroma.yuv420,
      ),
    };
    writeAtomically(v.path, bytes);
  }
}

/// Writes via a temporary file and a rename, so an interrupted run never
/// leaves a truncated asset behind.
void writeAtomically(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final tmp = File('$path.asset_kit.tmp');
  tmp.writeAsBytesSync(bytes, flush: true);
  tmp.renameSync(path);
}
