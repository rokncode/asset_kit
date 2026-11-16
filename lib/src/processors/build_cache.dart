import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What was produced from one source file in a previous run.
class CacheEntry {
  CacheEntry({
    required this.sourceHash,
    required this.settings,
    required this.outputs,
    required this.sourceSize,
    required this.outputSize,
  });

  factory CacheEntry.fromJson(Map<String, dynamic> json) => CacheEntry(
    sourceHash: json['hash'] as String,
    settings: json['settings'] as String,
    outputs: (json['outputs'] as List<dynamic>).cast<String>(),
    sourceSize: json['sourceSize'] as int,
    outputSize: json['outputSize'] as int,
  );

  /// SHA-256 of the source file contents.
  final String sourceHash;

  /// Fingerprint of every setting that affects the output.
  final String settings;

  /// Project-relative POSIX paths of every file written for this source.
  final List<String> outputs;
  final int sourceSize;
  final int outputSize;

  Map<String, dynamic> toJson() => {
    'hash': sourceHash,
    'settings': settings,
    'outputs': outputs,
    'sourceSize': sourceSize,
    'outputSize': outputSize,
  };
}

/// `.asset_kit/cache.json`: source path (relative to the source folder) →
/// [CacheEntry]. Used to skip unchanged files and to clean up outputs whose
/// source was removed or renamed.
class BuildCache {
  BuildCache(this.path, [Map<String, CacheEntry>? entries]) : entries = entries ?? {};

  static const _version = 1;

  final String path;
  final Map<String, CacheEntry> entries;

  /// Loads the cache, starting fresh if it is missing, corrupt or from an
  /// incompatible version.
  static BuildCache load(String path) {
    final file = File(path);
    if (!file.existsSync()) return BuildCache(path);
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (json['version'] != _version) return BuildCache(path);
      final raw = json['entries'] as Map<String, dynamic>;
      return BuildCache(path, {
        for (final MapEntry(:key, :value) in raw.entries)
          key: CacheEntry.fromJson(value as Map<String, dynamic>),
      });
    } on Object {
      return BuildCache(path);
    }
  }

  /// Whether [source] can be skipped: same contents, same settings, and
  /// every recorded output still exists under [projectRoot].
  bool isFresh(
    String source, {
    required String hash,
    required String settings,
    required String projectRoot,
  }) {
    final entry = entries[source];
    return entry != null &&
        entry.sourceHash == hash &&
        entry.settings == settings &&
        entry.outputs.every((o) => File(p.join(projectRoot, o)).existsSync());
  }

  void save() {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final sorted = Map.fromEntries(
      entries.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': _version,
        'entries': {for (final MapEntry(:key, :value) in sorted.entries) key: value.toJson()},
      }),
    );
  }
}
