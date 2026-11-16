import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../codegen/assets_generator.dart';
import '../config.dart';
import '../processors/build_cache.dart';
import '../processors/fonts.dart';
import '../scale.dart';
import 'asset_index.dart';
import 'dart_lexer.dart';

/// One deletable unit: an asset with all its scale variants, plus — for an
/// SVG — its precompiled `.vec` (and vice versa).
class AssetUnit {
  AssetUnit(this.entries);

  final List<AssetEntry> entries;

  /// The representative path: the `.svg` of an SVG/`.vec` pair, otherwise
  /// the asset's 1x path.
  String get path =>
      (entries.firstWhere((e) => e.path.endsWith('.svg'), orElse: () => entries.first)).path;

  AssetKind get kind => entries.first.kind;

  /// Every file on disk that belongs to this unit.
  List<String> get files => [for (final e in entries) ...e.allFiles];
}

enum Usage { used, possiblyUsed, unused, ignored }

/// Why a unit was classified the way it was.
class Evidence {
  Evidence(this.usage, this.reason, [this.location]);

  final Usage usage;
  final String reason;

  /// `lib/main.dart:12`, or a file name for non-Dart sources.
  final String? location;

  @override
  String toString() => location == null ? reason : '$reason ($location)';
}

class UnitResult {
  UnitResult(this.unit, this.usage, this.evidence, {required this.size, required this.orphan});

  final AssetUnit unit;
  final Usage usage;
  final List<Evidence> evidence;

  /// Bytes on disk across all files of the unit.
  final int size;

  /// True if the files are in the output folder but were not produced from
  /// the source folder (no matching source and not in the build cache).
  final bool orphan;

  Map<String, Object?> toJson() => {
    'path': unit.path,
    'files': unit.files,
    'size': size,
    'orphan': orphan,
    if (evidence.isNotEmpty) 'evidence': [for (final e in evidence) e.toString()],
  };
}

/// A path string that points into the output folder at a file that
/// doesn't exist: the app will fail to load it at runtime.
class BrokenReference {
  BrokenReference(this.path, this.location, {this.suggestedPath, this.suggestedConstant});

  /// The path as written, e.g. `assets/images/logo.png`.
  final String path;

  /// `lib/main.dart:12` or `pubspec.yaml:20`.
  final String location;

  /// The existing asset it most likely means (same folder and name), e.g.
  /// `assets/images/logo.webp` after a PNG → WebP conversion.
  final String? suggestedPath;

  /// The generated constant for [suggestedPath], e.g. `Assets.images.logo`.
  final String? suggestedConstant;

  Map<String, Object?> toJson() => {
    'path': path,
    'location': location,
    if (suggestedPath != null) 'suggestedPath': suggestedPath,
    if (suggestedConstant != null) 'suggestedConstant': suggestedConstant,
  };
}

class UnusedReport {
  UnusedReport({
    required this.results,
    required this.scannedFiles,
    required this.orphanCheck,
    this.broken = const [],
  });

  /// Paths in code or package configs that point at missing files. They
  /// don't affect the used/unused classification.
  final List<BrokenReference> broken;

  final List<UnitResult> results;

  /// Project-relative paths of every file that was scanned for references.
  final List<String> scannedFiles;

  /// False when there is no source folder, so orphans can't be determined.
  final bool orphanCheck;

  Iterable<UnitResult> _where(Usage usage, {bool? orphan}) =>
      results.where((r) => r.usage == usage && (orphan == null || r.orphan == orphan));

  /// Unused assets produced by asset_kit (or with a matching source).
  List<UnitResult> get unused => _where(Usage.unused, orphan: false).toList();
  List<UnitResult> get possiblyUsed => _where(Usage.possiblyUsed, orphan: false).toList();
  List<UnitResult> get ignored => _where(Usage.ignored).toList();

  /// Every orphan, whatever its usage.
  List<UnitResult> get orphans =>
      results.where((r) => r.orphan && r.usage != Usage.ignored).toList();
  List<UnitResult> get unusedOrphans => _where(Usage.unused, orphan: true).toList();

  int get reclaimableBytes => [...unused, ...unusedOrphans].fold(0, (s, r) => s + r.size);

  Map<String, Object?> toJson() => {
    'unused': [for (final r in unused) r.toJson()],
    'possiblyUsed': [for (final r in possiblyUsed) r.toJson()],
    'orphans': [
      for (final r in orphans) {...r.toJson(), 'usage': r.usage.name},
    ],
    'ignored': [for (final r in ignored) r.unit.path],
    'reclaimableBytes': reclaimableBytes,
    'broken': [for (final b in broken) b.toJson()],
    'scannedFiles': scannedFiles.length,
  };
}

/// Config files of packages that reference assets outside Dart code. Any
/// string value in them that names an asset counts as a use.
const _packageConfigKeys = ['flutter_launcher_icons', 'flutter_icons', 'flutter_native_splash'];
final _packageConfigFile = RegExp(
  r'^(flutter_launcher_icons|flutter_native_splash)(-[\w-]+)?\.ya?ml$',
);

/// Native sources that may load Flutter assets via the lookup-key APIs.
const _nativeDirs = ['android/app/src', 'ios/Runner', 'macos/Runner'];
const _nativeExtensions = {'.kt', '.java', '.swift', '.m', '.mm', '.h'};

/// Finds assets in the output folder that nothing references.
class UnusedScanner {
  UnusedScanner(this.config);

  final AssetKitConfig config;

  late final String _outputRoot = p.posix.joinAll(
    p.split(p.relative(config.outputDir, from: config.projectRoot)),
  );

  final _evidence = <String, List<Evidence>>{}; // file path → evidence
  final _scanned = <String>[];
  final _broken = <BrokenReference>[];
  late AssetsGenerator _generator;
  late Set<String> _mainFiles;

  String _rel(String abs) => p.posix.joinAll(p.split(p.relative(abs, from: config.projectRoot)));

  UnusedReport scan() {
    final index = AssetIndex.scan(projectRoot: config.projectRoot, assetsDir: config.outputDir);
    // Variants without a 1x main asset are never bundled by a directory
    // entry, but still sit in the folder: list them as their own units.
    final strays = [
      for (final v in index.orphanVariants)
        AssetEntry(path: v, kind: assetKindOf(v), variants: const {}),
    ];
    final units = _groupUnits([...index.entries, ...strays]);
    final allFiles = {for (final u in units) ...u.files};
    final mainByFile = {
      for (final u in units)
        for (final e in u.entries)
          for (final f in e.allFiles) f: e.path,
    };

    void add(String file, Evidence e) => (_evidence[mainByFile[file] ?? file] ??= []).add(e);

    final generator = AssetsGenerator(
      assetsRoot: _outputRoot,
      className: config.codegen.className,
      names: config.codegen.names,
      fontFamilies: registeredFontFamilies(config.pubspecFile),
    )..generate(index.entries);
    _generator = generator;
    _mainFiles = {
      for (final u in units)
        for (final e in u.entries) e.path,
    };
    final fontFamilies = _scanPubspec(allFiles, add);
    _scanPackageConfigFiles(allFiles, add);
    _scanDart(units, allFiles, generator, fontFamilies, add);
    _scanTextFiles(allFiles, add);

    final orphanCheck = Directory(config.sourceDir).existsSync();
    final orphanFiles = orphanCheck ? _orphanFiles(units) : const <String>{};

    final results = <UnitResult>[];
    for (final unit in units) {
      final evidence = [for (final e in unit.entries) ...?_evidence[e.path]];
      final ignored = unit.files.any(config.unused.isIgnored);
      final usage = ignored
          ? Usage.ignored
          : evidence.any((e) => e.usage == Usage.used)
          ? Usage.used
          : evidence.isNotEmpty
          ? Usage.possiblyUsed
          : Usage.unused;
      final size = unit.files.fold<int>(
        0,
        (s, f) => s + File(p.join(config.projectRoot, f)).lengthSync(),
      );
      results.add(
        UnitResult(
          unit,
          usage,
          _dedupe(evidence.where((e) => e.usage == usage || usage == Usage.ignored).toList()),
          size: size,
          orphan: unit.files.every(orphanFiles.contains),
        ),
      );
    }
    results.sort((a, b) => a.unit.path.compareTo(b.unit.path));
    _broken.sort((a, b) => a.location.compareTo(b.location));
    return UnusedReport(
      results: results,
      scannedFiles: _scanned..sort(),
      orphanCheck: orphanCheck,
      broken: _broken,
    );
  }

  List<Evidence> _dedupe(List<Evidence> list) {
    final seen = <String>{};
    return [
      for (final e in list)
        if (seen.add(e.toString())) e,
    ];
  }

  /// Groups an SVG with the `.vec` of the same name in the same folder.
  List<AssetUnit> _groupUnits(List<AssetEntry> entries) {
    final groups = <String, List<AssetEntry>>{};
    for (final e in entries) {
      final ext = p.posix.extension(e.path).toLowerCase();
      final key = ext == '.svg' || ext == '.vec'
          ? '${p.posix.withoutExtension(e.path)}#vector'
          : e.path;
      (groups[key] ??= []).add(e);
    }
    return [for (final g in groups.values) AssetUnit(g)];
  }

  // ---------------------------------------------------------------- Dart

  void _scanDart(
    List<AssetUnit> units,
    Set<String> allFiles,
    AssetsGenerator generator,
    Map<String, String> fontFamilies,
    void Function(String, Evidence) add,
  ) {
    final generated = p.normalize(config.codegenOutputFile);
    final chainToAsset = {
      for (final MapEntry(:key, :value) in generator.assetChains.entries) value.join('.'): key,
    };
    final chainToFolder = {
      for (final MapEntry(:key, :value) in generator.folderChains.entries) value.join('.'): key,
    };
    final byBasename = <String, List<String>>{};
    for (final f in allFiles) {
      (byBasename[p.posix.basename(f)] ??= []).add(f);
    }
    final folders = <String>{};
    for (final f in allFiles) {
      for (var d = _logicalDir(f); d != _outputRoot && d != '.'; d = p.posix.dirname(d)) {
        folders.add(d);
      }
    }
    folders.add(_outputRoot);
    final chainRef = RegExp(
      '(?<![\\w\$])${RegExp.escape(config.codegen.className)}((?:\\s*\\??\\.\\s*[A-Za-z_\$][\\w\$]*)+)',
    );
    final familyStrings = <String, String>{}; // family → location
    final fontFamilyRef = RegExp(
      '(?<![\\w\$])${AssetsGenerator.fontFamilyClass}\\s*\\.\\s*([A-Za-z_\$][\\w\$]*)',
    );

    for (final dir in config.unused.scanDirs) {
      final root = Directory(p.join(config.projectRoot, dir));
      if (!root.existsSync()) continue;
      for (final file in root.listSync(recursive: true, followLinks: false)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (p.equals(p.normalize(file.path), generated)) continue;
        final rel = _rel(file.path);
        if (p.split(rel).any((s) => s.startsWith('.'))) continue;
        _scanned.add(rel);
        final lexed = lexDart(file.readAsStringSync());
        String at(int offset) => '$rel:${lexed.lineOf(offset)}';

        // Generated constants: Assets.images.onboarding.step1
        for (final m in chainRef.allMatches(lexed.code)) {
          final idents = m
              .group(1)!
              .split(RegExp(r'\s*\??\.\s*'))
              .where((s) => s.isNotEmpty)
              .toList();
          String? folder;
          var resolved = false;
          for (var k = 1; k <= idents.length; k++) {
            final key = idents.take(k).join('.');
            final asset = chainToAsset[key];
            if (asset != null) {
              add(
                asset,
                Evidence(Usage.used, 'referenced as ${config.codegen.className}.$key', at(m.start)),
              );
              resolved = true;
              break;
            }
            final f = chainToFolder[key];
            if (f == null) break;
            folder = f;
          }
          if (!resolved && folder != null) {
            final chain =
                '${config.codegen.className}.${generator.folderChains[folder]!.join('.')}';
            final dir = p.posix.join(_outputRoot, folder);
            for (final file in allFiles.where(
              (f) => _logicalDir(f) == dir || p.posix.isWithin(dir, f),
            )) {
              add(
                file,
                Evidence(
                  Usage.possiblyUsed,
                  'its folder object $chain is used without a member',
                  at(m.start),
                ),
              );
            }
          }
        }

        // FontFamily.cairo → the Cairo family is used.
        for (final m in fontFamilyRef.allMatches(lexed.code)) {
          final family = generator.fontFamilyIds[m.group(1)];
          if (family != null) familyStrings.putIfAbsent(family, () => at(m.start));
        }

        // String literals.
        for (final s in lexed.strings) {
          final location = at(s.offset);
          if (s.hasInterpolation) {
            _matchPattern(s, allFiles, location, add);
            continue;
          }
          final v = s.value;
          _checkBroken(v, location);
          if (fontFamilies.containsValue(v)) familyStrings.putIfAbsent(v, () => location);
          if (v.contains('$_outputRoot/')) {
            for (final f in allFiles) {
              if (v.contains(f)) add(f, Evidence(Usage.used, "path '$f'", location));
            }
            final dir = v.endsWith('/') ? v.substring(0, v.length - 1) : v;
            if (folders.contains(dir) && !allFiles.contains(v)) {
              for (final f in allFiles.where(
                (f) => _logicalDir(f) == dir || p.posix.isWithin(dir, f),
              )) {
                add(
                  f,
                  Evidence(
                    Usage.possiblyUsed,
                    "its folder '$v' is used as a path prefix",
                    location,
                  ),
                );
              }
            }
          }
          final base = v.contains('/') ? v.substring(v.lastIndexOf('/') + 1) : v;
          for (final f in byBasename[base] ?? const <String>[]) {
            if (!v.contains(f)) add(f, Evidence(Usage.used, "file name '$base'", location));
          }
        }
      }
    }

    // Fonts are used through their family name.
    fontFamilies.forEach((fontPath, family) {
      final location = familyStrings[family];
      if (location != null) {
        add(fontPath, Evidence(Usage.used, "font family '$family'", location));
      } else {
        add(
          fontPath,
          Evidence(
            Usage.possiblyUsed,
            "registered in pubspec.yaml as family '$family', but '$family' never appears in Dart code",
          ),
        );
      }
    });
  }

  /// The folder a file logically belongs to, ignoring scale folders:
  /// `assets/images/2.0x/a.webp` → `assets/images`.
  String _logicalDir(String file) {
    final dir = p.posix.dirname(file);
    return variantDirPattern.hasMatch(p.posix.basename(dir)) ? p.posix.dirname(dir) : dir;
  }

  /// `'assets/images/flags/$code.webp'` → possibly uses every matching file.
  void _matchPattern(
    StringLiteral s,
    Set<String> allFiles,
    String location,
    void Function(String, Evidence) add,
  ) {
    final parts = s.parts;
    // A pattern needs some literal path text to be meaningful; `'$a$b'`
    // or `'$a/$b'` would match everything.
    if (!parts.any((part) => RegExp(r'[A-Za-z0-9]').hasMatch(part))) return;
    final pattern = RegExp('(^|/)${parts.map(RegExp.escape).join('.*')}\$');
    for (final f in allFiles) {
      if (pattern.hasMatch(f)) {
        add(f, Evidence(Usage.possiblyUsed, 'matches dynamic path $s', location));
      }
    }
  }

  // ------------------------------------------------------------- YAML/text

  /// Scans pubspec.yaml: font registrations and package config sections.
  /// Returns registered font asset path → family.
  Map<String, String> _scanPubspec(Set<String> allFiles, void Function(String, Evidence) add) {
    final file = File(config.pubspecFile);
    if (!file.existsSync()) return const {};
    _scanned.add('pubspec.yaml');
    final YamlNode root;
    try {
      root = loadYamlNode(file.readAsStringSync());
    } on YamlException {
      return const {};
    }
    if (root is! YamlMap) return const {};
    final doc = root;

    final families = <String, String>{};
    final fonts = doc['flutter'] is Map ? (doc['flutter'] as Map)['fonts'] : null;
    if (fonts is List) {
      for (final family in fonts.whereType<Map<Object?, Object?>>()) {
        final name = family['family'];
        final list = family['fonts'];
        if (name is! String || list is! List) continue;
        for (final font in list.whereType<Map<Object?, Object?>>()) {
          final asset = font['asset'];
          if (asset is String && allFiles.contains(asset)) families[asset] = name;
        }
      }
    }
    for (final key in _packageConfigKeys) {
      if (doc.nodes[key] case final node?) {
        _matchScalars(node, allFiles, 'pubspec.yaml ($key)', add);
      }
    }
    return families;
  }

  void _scanPackageConfigFiles(Set<String> allFiles, void Function(String, Evidence) add) {
    for (final entity in Directory(config.projectRoot).listSync()) {
      final name = p.basename(entity.path);
      if (entity is! File || !_packageConfigFile.hasMatch(name)) continue;
      _scanned.add(name);
      try {
        _matchScalars(loadYamlNode(entity.readAsStringSync()), allFiles, name, add);
      } on YamlException {
        _matchText(entity.readAsStringSync(), allFiles, name, add);
      }
    }
  }

  void _matchScalars(
    YamlNode? node,
    Set<String> allFiles,
    String location,
    void Function(String, Evidence) add,
  ) {
    if (node is YamlMap) {
      for (final v in node.nodes.values) {
        _matchScalars(v, allFiles, location, add);
      }
    } else if (node is YamlList) {
      for (final v in node.nodes) {
        _matchScalars(v, allFiles, location, add);
      }
    } else if (node is YamlScalar && node.value is String) {
      final value = (node.value as String).trim();
      final file = location.split(' ').first;
      _checkBroken(value, '$file:${node.span.start.line + 1}');
      for (final f in allFiles) {
        if (value == f || value.endsWith('/$f')) {
          add(f, Evidence(Usage.used, 'referenced in $location'));
        }
      }
    }
  }

  /// Records [value] as broken if it is a path into the output folder that
  /// doesn't exist (as a file or folder).
  void _checkBroken(String value, String location) {
    if (!value.startsWith('$_outputRoot/')) return;
    final abs = p.join(config.projectRoot, value);
    if (File(abs).existsSync() || Directory(abs).existsSync()) return;

    // Same folder (ignoring scale folders) and name, with @Nx and the
    // extension removed: logo.png / 3.0x/logo.png / logo@3x.png → logo.webp.
    final parsed = parseScaleSuffix(p.posix.basename(value));
    final stem = p.posix.join(_logicalDir(value), p.posix.withoutExtension(parsed.name));
    final candidates = _mainFiles.where((f) => p.posix.withoutExtension(f) == stem).toList()
      ..sort();
    final suggestion = candidates.isEmpty ? null : candidates.first;
    final chain = suggestion == null ? null : _generator.assetChains[suggestion];
    _broken.add(
      BrokenReference(
        value,
        location,
        suggestedPath: suggestion,
        suggestedConstant: chain == null ? null : '${config.codegen.className}.${chain.join('.')}',
      ),
    );
  }

  /// `unused.extra_scan_files` and native sources: plain-text search.
  void _scanTextFiles(Set<String> allFiles, void Function(String, Evidence) add) {
    final files = <String>{};
    for (final pattern in config.unused.extraScanFiles) {
      final glob = Glob(pattern, context: p.posix);
      for (final e in glob.listSync(root: config.projectRoot, followLinks: false)) {
        if (e is File) files.add(p.normalize(e.path));
      }
    }
    for (final dir in _nativeDirs) {
      final root = Directory(p.join(config.projectRoot, dir));
      if (!root.existsSync()) continue;
      for (final e in root.listSync(recursive: true, followLinks: false)) {
        if (e is File && _nativeExtensions.contains(p.extension(e.path))) {
          files.add(p.normalize(e.path));
        }
      }
    }
    for (final path in files.toList()..sort()) {
      final rel = _rel(path);
      _scanned.add(rel);
      final String text;
      try {
        text = File(path).readAsStringSync();
      } on FileSystemException {
        continue; // binary or unreadable
      }
      _matchText(text, allFiles, rel, add);
    }
  }

  void _matchText(
    String text,
    Set<String> allFiles,
    String location,
    void Function(String, Evidence) add,
  ) {
    for (final f in allFiles) {
      if (text.contains(f)) {
        add(f, Evidence(Usage.used, 'referenced in $location'));
        continue;
      }
      final base = RegExp.escape(p.posix.basename(f));
      if (RegExp('(^|[^\\w.-])$base(\$|[^\\w.-])').hasMatch(text)) {
        add(f, Evidence(Usage.used, "file name '${p.posix.basename(f)}' in $location"));
      }
    }
  }

  // --------------------------------------------------------------- orphans

  /// Files in the output folder that asset_kit did not produce: not in the
  /// build cache and with no source of the same folder and name.
  Set<String> _orphanFiles(List<AssetUnit> units) {
    final cache = BuildCache.load(p.join(config.cacheDir, 'cache.json'));
    final produced = {for (final e in cache.entries.values) ...e.outputs};
    final sourceStems = <String>{};
    final sourceDir = Directory(config.sourceDir);
    for (final f in sourceDir.listSync(recursive: true, followLinks: false).whereType<File>()) {
      final rel = p.posix.joinAll(p.split(p.relative(f.path, from: config.sourceDir)));
      final name = parseScaleSuffix(p.posix.basename(rel)).name;
      sourceStems.add(p.posix.join(p.posix.dirname(rel), p.posix.basenameWithoutExtension(name)));
    }
    final orphans = <String>{};
    for (final unit in units) {
      for (final file in unit.files) {
        if (produced.contains(file)) continue;
        final rel = p.posix.relative(_logicalPath(file), from: _outputRoot);
        if (sourceStems.contains(p.posix.withoutExtension(rel))) continue;
        orphans.add(file);
      }
    }
    return orphans;
  }

  String _logicalPath(String file) => p.posix.join(_logicalDir(file), p.posix.basename(file));
}
