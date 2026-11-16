import 'package:path/path.dart' as p;

/// Matches a scale suffix in a file name such as `logo@3x` or `logo@1.5x`.
final _scaleSuffix = RegExp(r'@(\d+(?:\.\d+)?)x$');

/// Matches Flutter's resolution-aware variant directory names (`2.0x`, `3x`).
final variantDirPattern = RegExp(r'^\d+(?:\.\d+)?x$');

/// The scale parsed out of a source file name, plus the name without it.
typedef ParsedSourceName = ({String name, double? scale});

/// Splits a `logo@3x.png` style file name into `logo.png` and scale `3`.
///
/// Returns a null scale if the base name has no `@Nx` suffix.
ParsedSourceName parseScaleSuffix(String fileName) {
  final ext = p.extension(fileName);
  final base = p.basenameWithoutExtension(fileName);
  final match = _scaleSuffix.firstMatch(base);
  if (match == null) return (name: fileName, scale: null);
  return (name: '${base.substring(0, match.start)}$ext', scale: double.parse(match.group(1)!));
}

/// Formats a scale as Flutter's variant directory name: `2.0x`, `1.5x`.
String variantDirName(double scale) {
  final text = scale == scale.truncateToDouble() ? scale.toStringAsFixed(1) : scale.toString();
  return '${text}x';
}

/// The pixel size of one output variant.
typedef VariantSize = ({double scale, int width, int height});

/// Result of planning which variants to generate for one image.
typedef VariantPlan = ({List<VariantSize> variants, List<double> skipped});

/// Works out the pixel size of each target [scales] variant for an image of
/// [width]×[height] pixels that was exported at [sourceScale].
///
/// Never upscales: a target scale above [sourceScale] is listed in `skipped`.
/// Dimensions are rounded and never drop below 1 pixel.
VariantPlan planVariants({
  required int width,
  required int height,
  required double sourceScale,
  required List<double> scales,
}) {
  if (sourceScale <= 0) {
    throw ArgumentError.value(sourceScale, 'sourceScale', 'must be > 0');
  }
  final variants = <VariantSize>[];
  final skipped = <double>[];
  for (final scale in scales) {
    if (scale > sourceScale) {
      skipped.add(scale);
      continue;
    }
    final factor = scale / sourceScale;
    variants.add((
      scale: scale,
      width: _atLeastOne((width * factor).round()),
      height: _atLeastOne((height * factor).round()),
    ));
  }
  return (variants: variants, skipped: skipped);
}

int _atLeastOne(int value) => value < 1 ? 1 : value;

/// Returns the output path for a variant, relative to the same root as
/// [logicalPath]. Scale 1 maps to the logical path itself.
///
/// `images/logo.webp` at scale 2 → `images/2.0x/logo.webp`.
String variantPath(String logicalPath, double scale) {
  if (scale == 1) return logicalPath;
  return p.posix.normalize(
    p.posix.join(
      p.posix.dirname(logicalPath),
      variantDirName(scale),
      p.posix.basename(logicalPath),
    ),
  );
}
