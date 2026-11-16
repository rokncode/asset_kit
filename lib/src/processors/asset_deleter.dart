import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../scale.dart';
import '../scanner/unused_scanner.dart';
import 'build_cache.dart';

class DeleteResult {
  DeleteResult(this.deletedFiles, this.deletedSources);

  /// Project-relative paths of deleted output files.
  final List<String> deletedFiles;

  /// Project-relative paths of deleted source files.
  final List<String> deletedSources;
}

/// Source files (relative to the source folder) that produced any file of
/// [unit]: found through the build cache, or by folder + name for files
/// built before the cache existed.
List<String> sourcesOf(AssetKitConfig config, AssetUnit unit, BuildCache cache) {
  final files = unit.files.toSet();
  final fromCache = [
    for (final MapEntry(:key, :value) in cache.entries.entries)
      if (value.outputs.any(files.contains)) key,
  ];
  if (fromCache.isNotEmpty) return fromCache..sort();

  final sourceDir = Directory(config.sourceDir);
  if (!sourceDir.existsSync()) return const [];
  final outputRoot = p.posix.joinAll(
    p.split(p.relative(config.outputDir, from: config.projectRoot)),
  );
  final stems = {
    for (final e in unit.entries)
      p.posix.withoutExtension(p.posix.relative(e.path, from: outputRoot)),
  };
  return [
    for (final f in sourceDir.listSync(recursive: true, followLinks: false).whereType<File>())
      if (() {
        final rel = p.posix.joinAll(p.split(p.relative(f.path, from: config.sourceDir)));
        final name = parseScaleSuffix(p.posix.basename(rel)).name;
        return stems.contains(p.posix.join(p.posix.dirname(rel), p.posix.withoutExtension(name)));
      }())
        p.posix.joinAll(p.split(p.relative(f.path, from: config.sourceDir))),
  ]..sort();
}

/// Deletes every file of [units] (all scale variants, and the SVG/`.vec`
/// pair together). With [includeSource], also deletes the originals in the
/// source folder and forgets them in the build cache.
DeleteResult deleteUnits(
  AssetKitConfig config,
  List<AssetUnit> units, {
  required bool includeSource,
}) {
  final cache = BuildCache.load(p.join(config.cacheDir, 'cache.json'));
  final deleted = <String>[];
  final deletedSources = <String>[];

  for (final unit in units) {
    if (includeSource) {
      for (final source in sourcesOf(config, unit, cache)) {
        final file = File(p.join(config.sourceDir, source));
        if (file.existsSync()) {
          file.deleteSync();
          deletedSources.add(p.posix.join(config.source, source));
        }
        cache.entries.remove(source);
      }
    }
    for (final rel in unit.files) {
      final file = File(p.join(config.projectRoot, rel));
      if (!file.existsSync()) continue;
      file.deleteSync();
      deleted.add(rel);
      _removeEmptyParents(file.parent, config.outputDir);
    }
  }
  if (includeSource && File(cache.path).existsSync()) cache.save();
  return DeleteResult(deleted, deletedSources);
}

void _removeEmptyParents(Directory dir, String root) {
  var current = dir;
  while (p.isWithin(root, current.path) && current.existsSync() && current.listSync().isEmpty) {
    current.deleteSync();
    current = current.parent;
  }
}
