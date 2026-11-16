import 'dart:io';

import 'package:path/path.dart' as p;

import '../scale.dart';

enum AssetKind { image, svg, font, other }

const _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};
const _fontExtensions = {'.ttf', '.otf'};

AssetKind assetKindOf(String path) {
  final ext = p.extension(path).toLowerCase();
  if (_imageExtensions.contains(ext)) return AssetKind.image;
  if (ext == '.svg' || ext == '.vec') return AssetKind.svg;
  if (_fontExtensions.contains(ext)) return AssetKind.font;
  return AssetKind.other;
}

/// One logical asset in the Flutter assets folder: its 1x "main" file plus
/// any resolution variants (`2.0x/`, `3.0x/`) next to it.
class AssetEntry {
  AssetEntry({required this.path, required this.kind, required this.variants});

  /// Project-relative POSIX path of the main asset, e.g.
  /// `assets/images/logo.webp`. This is the path code references.
  final String path;
  final AssetKind kind;

  /// Project-relative POSIX paths of variant files, keyed by scale.
  final Map<double, String> variants;

  /// Project-relative POSIX folder that contains the main asset.
  String get directory => p.posix.dirname(path);

  /// The main file and every variant.
  Iterable<String> get allFiles => [path, ...variants.values];

  @override
  String toString() => 'AssetEntry($path, variants: ${variants.keys.toList()})';
}

/// Result of scanning an assets folder.
class AssetIndex {
  AssetIndex(this.entries, this.orphanVariants);

  /// Logical assets, sorted by path.
  final List<AssetEntry> entries;

  /// Variant files that have no matching 1x main asset. Flutter will not
  /// bundle these when the directory is declared, so they are reported.
  final List<String> orphanVariants;

  /// Scans [assetsDir] (an absolute path inside [projectRoot]).
  ///
  /// Hidden files and folders (starting with `.`) are skipped. Files inside
  /// variant folders such as `2.0x/` are attached to the main asset in the
  /// parent folder instead of being listed on their own.
  static AssetIndex scan({required String projectRoot, required String assetsDir}) {
    final dir = Directory(assetsDir);
    if (!dir.existsSync()) return AssetIndex(const [], const []);

    final mains = <String>{};
    final variants = <String, Map<double, String>>{};

    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: projectRoot);
      final segments = p.split(rel);
      if (segments.any((s) => s.startsWith('.'))) continue;
      final posix = segments.join('/');

      final parent = segments.length >= 2 ? segments[segments.length - 2] : '';
      if (variantDirPattern.hasMatch(parent)) {
        final scale = double.parse(parent.substring(0, parent.length - 1));
        final main = p.posix.joinAll([...segments.sublist(0, segments.length - 2), segments.last]);
        (variants[main] ??= {})[scale] = posix;
      } else {
        mains.add(posix);
      }
    }

    final entries = [
      for (final main in mains)
        AssetEntry(path: main, kind: assetKindOf(main), variants: variants[main] ?? const {}),
    ]..sort((a, b) => a.path.compareTo(b.path));
    final orphans = [
      for (final MapEntry(:key, :value) in variants.entries)
        if (!mains.contains(key)) ...value.values,
    ]..sort();
    return AssetIndex(entries, orphans);
  }
}
