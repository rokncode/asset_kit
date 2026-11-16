import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../config.dart';
import '../errors.dart';
import '../scale.dart';
import '../scanner/asset_index.dart';
import 'fonts.dart';

class PubspecSyncResult {
  PubspecSyncResult({
    this.added = const [],
    this.removed = const [],
    this.fontsAdded = const [],
    this.fontsUpdated = const [],
    this.fontsRemoved = const [],
    this.fontsSkipped = const [],
    this.fontPlan,
    this.backup,
  });

  /// Directory entries added to `flutter: assets:`.
  final List<String> added;

  /// Stale directory entries removed (folders that no longer hold assets,
  /// and scale folders, which Flutter resolves on its own).
  final List<String> removed;

  /// Font families added to, changed in, or removed from `flutter: fonts:`.
  final List<String> fontsAdded;
  final List<String> fontsUpdated;
  final List<String> fontsRemoved;

  /// Families left alone because the user registered them with fonts
  /// outside the output folder.
  final List<String> fontsSkipped;

  /// The font analysis, when font registration is enabled.
  final FontPlan? fontPlan;

  /// Path of the backup written before changing pubspec.yaml.
  final String? backup;

  bool get changed =>
      added.isNotEmpty ||
      removed.isNotEmpty ||
      fontsAdded.isNotEmpty ||
      fontsUpdated.isNotEmpty ||
      fontsRemoved.isNotEmpty;
}

/// How many timestamped pubspec backups to keep in `.asset_kit/backups/`.
const _maxBackups = 10;

/// Directory entries (`assets/images/`) that `flutter: assets:` needs:
/// one per folder holding a main asset. Scale folders are never listed
/// (Flutter finds variants next to the main asset) and neither are folders
/// holding only fonts (those are registered under `flutter: fonts:`).
List<String> requiredAssetDirs(AssetKitConfig config) {
  final index = AssetIndex.scan(projectRoot: config.projectRoot, assetsDir: config.outputDir);
  return {
    for (final e in index.entries)
      if (e.kind != AssetKind.font) '${e.directory}/',
  }.toList()..sort();
}

/// Brings pubspec.yaml in line with the output folder, editing in place so
/// comments and formatting survive:
///
/// - `flutter: assets:` lists exactly the folders that hold assets. Only
///   directory entries inside the output folder are managed; file entries,
///   other folders and map entries (`flavors:`) are never touched.
/// - `flutter: fonts:` registers every font file in the output folder
///   (when `fonts.register_in_pubspec` is on). Only families whose files all
///   live in the output folder are managed.
///
/// A backup is written to `.asset_kit/backups/` before any change.
PubspecSyncResult syncPubspec(AssetKitConfig config, {required bool dryRun}) {
  final file = File(config.pubspecFile);
  if (!file.existsSync()) {
    throw AssetKitException(
      'pubspec.yaml not found in ${config.projectRoot}.',
      hint: 'Run asset_kit from the root of your Flutter project, or pass --config.',
    );
  }
  final original = file.readAsStringSync();
  final Object? doc;
  try {
    doc = loadYaml(original);
  } on YamlException catch (e) {
    throw AssetKitException(
      'pubspec.yaml is not valid YAML: ${e.message}',
      exitCode: ExitCode.data,
    );
  }
  if (doc is! Map) {
    throw AssetKitException('pubspec.yaml must be a YAML map.', exitCode: ExitCode.data);
  }

  final outputRoot = p.posix.joinAll(
    p.split(p.relative(config.outputDir, from: config.projectRoot)),
  );
  final edits = _Edits(original);

  final assets = _planAssets(config, doc, outputRoot);
  final fonts = config.fonts.registerInPubspec ? _planFonts(config, doc, outputRoot) : null;
  final result = PubspecSyncResult(
    added: assets.added,
    removed: assets.removed,
    fontsAdded: fonts?.added ?? const [],
    fontsUpdated: fonts?.updated ?? const [],
    fontsRemoved: fonts?.removed ?? const [],
    fontsSkipped: fonts?.skipped ?? const [],
    fontPlan: fonts?.plan,
  );
  if (!result.changed || dryRun) return result;

  // A new top-level key would be inserted alphabetically (above `name:`);
  // append an empty `flutter:` at the end instead and fill it in place.
  var editDoc = doc;
  if (!doc.containsKey('flutter')) {
    edits.text = '${edits.text.endsWith('\n') ? edits.text : '${edits.text}\n'}\nflutter:\n';
    editDoc = loadYaml(edits.text) as Map<Object?, Object?>;
  }
  assets.apply(edits, editDoc);
  fonts?.apply(edits, loadYaml(edits.text) as Map<Object?, Object?>);

  try {
    loadYaml(edits.text);
  } on YamlException catch (e) {
    throw AssetKitException(
      'Internal error: editing pubspec.yaml produced invalid YAML (${e.message}). '
      'Nothing was written.',
    );
  }
  final backup = _backup(config, original);
  file.writeAsStringSync(edits.text);
  return PubspecSyncResult(
    added: result.added,
    removed: result.removed,
    fontsAdded: result.fontsAdded,
    fontsUpdated: result.fontsUpdated,
    fontsRemoved: result.fontsRemoved,
    fontsSkipped: result.fontsSkipped,
    fontPlan: result.fontPlan,
    backup: backup,
  );
}

/// Applies yaml_edit operations one at a time on a fresh editor, so a
/// failed attempt never leaves a half-edited document behind.
class _Edits {
  _Edits(this.text);

  String text;

  /// Runs [op]; returns false (leaving [text] unchanged) if yaml_edit
  /// rejects it.
  bool tryApply(void Function(YamlEditor) op) {
    final editor = YamlEditor(text);
    try {
      op(editor);
    } on Object {
      return false;
    }
    text = editor.toString();
    return true;
  }

  void apply(void Function(YamlEditor) op) {
    if (!tryApply(op)) {
      throw AssetKitException('Internal error: could not edit pubspec.yaml. Nothing was written.');
    }
  }
}

// ------------------------------------------------------------------ assets

class _AssetsPlan {
  _AssetsPlan(this.added, this.removed, this.removeIndexes, this.entries);

  final List<String> added;
  final List<String> removed;
  final List<int> removeIndexes;
  final List<Object?> entries;

  void apply(_Edits edits, Map<Object?, Object?> doc) {
    if (added.isEmpty && removed.isEmpty) return;
    final flutter = doc['flutter'];
    if (flutter is! Map) {
      edits.apply((e) => e.update(['flutter'], {'assets': added}));
      return;
    }
    if (flutter['assets'] is! List) {
      edits.apply((e) => e.update(['flutter', 'assets'], added));
      return;
    }
    if (added.isEmpty && removeIndexes.length == entries.length) {
      edits.apply((e) => e.remove(['flutter', 'assets']));
      return;
    }
    for (final i in removeIndexes.reversed) {
      edits.apply((e) => e.remove(['flutter', 'assets', i]));
    }
    // Insert after the last plain entry: keeps directory entries together,
    // and yaml_edit cannot append after a trailing map entry
    // (`- path: … flavors: …`) that is followed by another key.
    final remaining = [
      for (var i = 0; i < entries.length; i++)
        if (!removeIndexes.contains(i)) entries[i],
    ];
    var at = remaining.lastIndexWhere((e) => e is String) + 1;
    for (final dir in added) {
      final index = at++;
      edits.apply((e) => e.insertIntoList(['flutter', 'assets'], index, dir));
    }
  }
}

_AssetsPlan _planAssets(AssetKitConfig config, Map<Object?, Object?> doc, String outputRoot) {
  final required = requiredAssetDirs(config);
  final flutter = doc['flutter'];
  final existing = flutter is Map ? flutter['assets'] : null;
  final entries = existing is List ? existing : const <Object?>[];

  bool isManaged(String entry) =>
      entry.endsWith('/') && (entry == '$outputRoot/' || p.posix.isWithin(outputRoot, entry));
  bool isScaleDir(String entry) =>
      variantDirPattern.hasMatch(p.posix.basename(entry.substring(0, entry.length - 1)));

  final declared = <String>{};
  final removeIndexes = <int>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final path = entry is String ? entry : (entry is Map ? entry['path'] : null);
    if (path is! String) continue;
    final normalized = path.endsWith('/') ? path : (entry is String ? path : '$path/');
    if (entry is String &&
        isManaged(normalized) &&
        (isScaleDir(normalized) || !required.contains(normalized))) {
      removeIndexes.add(i);
    } else {
      declared.add(normalized);
    }
  }
  return _AssetsPlan(
    required.where((d) => !declared.contains(d)).toList(),
    [for (final i in removeIndexes) entries[i] as String],
    removeIndexes,
    entries,
  );
}

// ------------------------------------------------------------------- fonts

class _FontsPlan {
  _FontsPlan(
    this.plan,
    this.desired,
    this.added,
    this.updated,
    this.removed,
    this.skipped,
    this.updateIndexes,
    this.removeIndexes,
    this.existingNames,
  );

  final FontPlan plan;
  final Map<String, List<Map<String, Object>>> desired;
  final List<String> added, updated, removed, skipped;
  final Map<String, int> updateIndexes;
  final List<int> removeIndexes;

  /// Family names currently in `flutter: fonts:`, in file order.
  final List<String?> existingNames;

  void apply(_Edits edits, Map<Object?, Object?> doc) {
    if (added.isEmpty && updated.isEmpty && removed.isEmpty) return;
    final flutter = doc['flutter'];
    final hasList = flutter is Map && flutter['fonts'] is List;

    if (!hasList) {
      final families = [for (final f in added) _familyEntry(f, desired[f]!)];
      edits.apply(
        (e) => e.update(
          flutter is Map ? ['flutter', 'fonts'] : ['flutter'],
          flutter is Map ? families : {'fonts': families},
        ),
      );
      return;
    }

    for (final family in updated) {
      final i = updateIndexes[family]!;
      edits.apply((e) => e.update(['flutter', 'fonts', i, 'fonts'], _forYaml(desired[family]!)));
    }

    final names = [...existingNames];
    if (removeIndexes.length == names.length && added.isEmpty) {
      edits.apply((e) => e.remove(['flutter', 'fonts']));
      return;
    }
    for (final i in removeIndexes.reversed) {
      edits.apply((e) => e.remove(['flutter', 'fonts', i]));
      names.removeAt(i);
    }

    for (final family in added) {
      final entry = _familyEntry(family, desired[family]!);
      // Keep families sorted where possible. yaml_edit can't append a map
      // after a trailing map item followed by another key, so the end of
      // the list falls back to the front.
      var at = names.indexWhere((n) => n != null && n.compareTo(family) > 0);
      if (at == -1) at = names.length;
      final index = at;
      if (edits.tryApply((e) => e.insertIntoList(['flutter', 'fonts'], index, entry))) {
        names.insert(index, family);
      } else if (edits.tryApply((e) => e.insertIntoList(['flutter', 'fonts'], 0, entry))) {
        names.insert(0, family);
      } else {
        throw AssetKitException(
          'Internal error: could not add font family $family to pubspec.yaml.',
        );
      }
    }
  }

  static Map<String, Object> _familyEntry(String family, List<Map<String, Object>> fonts) => {
    'family': family,
    'fonts': _forYaml(fonts),
  };

  /// yaml_edit double-quotes values such as `Cairo[wght].ttf` and escapes
  /// `/` as `\/`; single quotes read better.
  static List<Object> _forYaml(List<Map<String, Object>> fonts) => [
    for (final f in fonts)
      {
        for (final MapEntry(:key, :value) in f.entries)
          key: value is String && !RegExp(r'^[\w./-]+$').hasMatch(value)
              ? wrapAsYamlNode(value, scalarStyle: ScalarStyle.SINGLE_QUOTED)
              : value,
      },
  ];
}

_FontsPlan _planFonts(AssetKitConfig config, Map<Object?, Object?> doc, String outputRoot) {
  final plan = planFonts(config);
  final desired = {
    for (final MapEntry(:key, :value) in plan.byFamily.entries)
      key: [for (final f in value) f.toPubspec()],
  };

  final flutter = doc['flutter'];
  final existing = flutter is Map && flutter['fonts'] is List
      ? flutter['fonts'] as List
      : const <Object?>[];
  final names = <String?>[];
  final updateIndexes = <String, int>{};
  final removeIndexes = <int>[];
  final updated = <String>[], removed = <String>[], skipped = <String>[];
  final present = <String>{};

  for (var i = 0; i < existing.length; i++) {
    final entry = existing[i];
    final name = entry is Map ? entry['family'] : null;
    names.add(name is String ? name : null);
    if (entry is! Map || name is! String) continue;
    final list = entry['fonts'];
    final assets = [
      if (list is List)
        for (final f in list)
          if (f is Map && f['asset'] is String) f['asset'] as String,
    ];
    final managed = assets.isNotEmpty && assets.every((a) => p.posix.isWithin(outputRoot, a));
    final want = desired[name];
    if (want != null) {
      present.add(name);
      if (!managed) {
        skipped.add(name);
      } else if (!_sameFonts(list, want)) {
        updated.add(name);
        updateIndexes[name] = i;
      }
    } else if (managed) {
      removed.add(name);
      removeIndexes.add(i);
    }
  }

  return _FontsPlan(
    plan,
    desired,
    desired.keys.where((f) => !present.contains(f)).toList(),
    updated,
    removed,
    skipped,
    updateIndexes,
    removeIndexes,
    names,
  );
}

bool _sameFonts(Object? list, List<Map<String, Object>> want) {
  if (list is! List || list.length != want.length) return false;
  for (var i = 0; i < want.length; i++) {
    final have = list[i];
    if (have is! Map) return false;
    final style = have['style'] ?? 'normal';
    if (have['asset'] != want[i]['asset'] ||
        have['weight'] != want[i]['weight'] ||
        style != (want[i]['style'] ?? 'normal')) {
      return false;
    }
    if (have.keys.any((k) => k != 'asset' && k != 'weight' && k != 'style')) return false;
  }
  return true;
}

String _backup(AssetKitConfig config, String content) {
  final dir = Directory(p.join(config.cacheDir, 'backups'))..createSync(recursive: true);
  final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final file = File(p.join(dir.path, 'pubspec.yaml.$stamp'))..writeAsStringSync(content);
  final backups =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('pubspec.yaml.'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final old in backups.take(math.max(0, backups.length - _maxBackups))) {
    old.deleteSync();
  }
  return file.path;
}
