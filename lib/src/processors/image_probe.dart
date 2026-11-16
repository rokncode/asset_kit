import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Size and orientation of an image, read from its header without decoding
/// pixels.
class ImageProbe {
  ImageProbe({required this.width, required this.height, required this.orientation});

  /// Display width (after EXIF orientation is applied).
  final int width;

  /// Display height (after EXIF orientation is applied).
  final int height;

  /// EXIF orientation, 1 (normal) to 8.
  final int orientation;

  /// Whether the pixels must be rotated/flipped before encoding. cwebp
  /// ignores EXIF orientation, so such images go through Dart first.
  bool get needsRotation => orientation != 1;
}

ImageProbe? probeImage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width <= 0 || info.height <= 0) return null;
  var orientation = 1;
  if (decoder is img.JpegDecoder) {
    final o = img.decodeJpgExif(bytes)?.imageIfd.orientation;
    if (o != null && o >= 1 && o <= 8) orientation = o;
  }
  final swap = orientation >= 5;
  return ImageProbe(
    width: swap ? info.height : info.width,
    height: swap ? info.width : info.height,
    orientation: orientation,
  );
}
