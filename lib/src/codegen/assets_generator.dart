import 'package:path/path.dart' as p;

import '../errors.dart';
import '../scanner/asset_index.dart';
import 'format_settings.dart';
import 'identifier.dart';

const generatedHeader = '// GENERATED CODE - DO NOT MODIFY BY HAND';

/// A folder in the asset tree, which becomes one generated class.
class _Folder {
  _Folder(this.relPath);

  /// POSIX path below the assets root; empty for the root itself.
  final String relPath;
  final folders = <String, _Folder>{};
  final files = <AssetEntry>[];

  /// Class name, assigned when the folder is emitted.
  late String className;

  /// Identifiers from the root class to this folder: `[images, onboarding]`.
  List<String> chain = const [];
}

/// A member of a generated class: either a sub-folder or an asset path.
class _Member {
  _Member.folder(this.name, this.relPath, _Folder this.folder) : asset = null;
  _Member.file(this.name, this.relPath, AssetEntry this.asset) : folder = null;

  /// File or folder name as on disk.
  final String name;

  /// POSIX path relative to the assets root; the key used in `codegen.names`.
  final String relPath;
  final _Folder? folder;
  final AssetEntry? asset;
  String? identifier;

  bool get isFile => asset != null;
}

/// Why an asset or folder was left out of the generated file.
enum SkipReason {
  /// The name has characters that can't be represented in a Dart identifier
  /// (e.g. Arabic letters), so any automatic name would be lossy.
  unconvertible,

  /// Its identifier clashes with a sibling and the clash can't be resolved
  /// without numbering, which would be unstable.
  collision,
}

/// An asset or folder that was left out, with the `codegen.names` key that
/// would bring it back.
class SkippedAsset {
  SkippedAsset(this.key, this.reason, {this.isFolder = false, this.collidesWith});

  /// Path relative to the assets root, e.g. `images/شعار.webp`.
  final String key;
  final SkipReason reason;
  final bool isFolder;

  /// For collisions: the sibling(s) that produce the same identifier.
  final List<String>? collidesWith;

  String get explanation => switch (reason) {
    SkipReason.unconvertible => 'name has characters that can\'t be used in a Dart identifier',
    SkipReason.collision => 'same identifier as ${collidesWith!.join(', ')}',
  };
}

/// Generates the `Assets` constants file from an [AssetIndex].
///
/// Each folder below the assets root becomes a private class; the root class
/// exposes top-level folders as static constants:
///
/// ```dart
/// Assets.images.logo                 // 'assets/images/logo.webp'
/// Assets.images.onboarding.step1     // 'assets/images/onboarding/step_1.webp'
/// ```
///
/// Identifiers are **stable**: an asset's identifier depends only on its own
/// name (plus its extension when a sibling shares the base name), never on
/// how many other files exist. Names that can't be converted cleanly, and
/// clashes that would need numbering, are left out and reported in
/// [skipped] so the user can name them in `codegen.names`.
///
/// Fonts are skipped: they are referenced by family name, not path.
class AssetsGenerator {
  AssetsGenerator({
    required this.assetsRoot,
    this.className = 'Assets',
    this.names = const {},
    this.fontFamilies = const [],
    this.formatSettings = const FormatSettings(),
  });

  /// Font family names registered in pubspec.yaml; emitted as constants on
  /// `FontFamily`. Identifiers can be set in [names] with a `font:` key
  /// (`font:تجوال: tajawal`).
  final List<String> fontFamilies;

  /// Name of the generated font family class.
  static const fontFamilyClass = 'FontFamily';

  /// Identifier → family name for the emitted `FontFamily` constants.
  final fontFamilyIds = <String, String>{};

  /// Project-relative POSIX path of the assets folder, e.g. `assets`.
  final String assetsRoot;
  final String className;

  /// Manual identifiers keyed by path relative to [assetsRoot]
  /// (`images/شعار.webp` → `logo`). Keys may name files or folders.
  final Map<String, String> names;

  /// Formatter settings of the target project; see [FormatSettings].
  final FormatSettings formatSettings;

  /// Assets and folders that were left out; filled by [generate].
  final skipped = <SkippedAsset>[];

  /// `names` keys that matched nothing; filled by [generate].
  final unusedNames = <String>[];

  /// Number of asset constants emitted by the last [generate] call.
  int assetCount = 0;

  /// Identifiers leading to each emitted asset, keyed by its project path:
  /// `assets/images/logo.webp` → `[images, logo]` (i.e. `Assets.images.logo`).
  final assetChains = <String, List<String>>{};

  /// Identifiers leading to each emitted folder class, keyed by the folder's
  /// path relative to [assetsRoot]: `images/onboarding` → `[images, onboarding]`.
  final folderChains = <String, List<String>>{};

  final _classNames = <String>{};
  final _usedNameKeys = <String>{};

  String generate(Iterable<AssetEntry> entries) {
    skipped.clear();
    fontFamilyIds.clear();
    assetChains.clear();
    folderChains.clear();
    unusedNames.clear();
    assetCount = 0;
    _usedNameKeys.clear();
    _classNames
      ..clear()
      ..add(className);

    final root = _Folder('');
    for (final entry in entries) {
      if (entry.kind == AssetKind.font) continue;
      final rel = p.posix.relative(entry.path, from: assetsRoot);
      final segments = p.posix.split(rel);
      var folder = root;
      for (final segment in segments.take(segments.length - 1)) {
        final childPath = folder.relPath.isEmpty ? segment : '${folder.relPath}/$segment';
        folder = folder.folders.putIfAbsent(segment, () => _Folder(childPath));
      }
      folder.files.add(entry);
    }

    final out = StringBuffer()
      ..writeln(generatedHeader)
      ..writeln('// Generated by asset_kit. Run `asset_kit gen` to regenerate.')
      ..writeln()
      ..writeln('// ignore_for_file: type=lint')
      ..writeln();

    final pending = <_Folder>[];
    out.writeln('abstract final class $className {');
    for (final m in _members(root)) {
      if (m.isFile) {
        assetChains[m.asset!.path] = [m.identifier!];
        out.writeln('  static const String ${m.identifier} = ${_literal(m.asset!.path)};');
      } else {
        final folder = m.folder!
          ..className = _classNameFor(m.identifier!, '')
          ..chain = [m.identifier!];
        folderChains[folder.relPath] = folder.chain;
        pending.add(folder);
        out.writeln('  static const ${m.identifier} = ${folder.className}();');
      }
    }
    out.writeln('}');

    while (pending.isNotEmpty) {
      final folder = pending.removeAt(0);
      final name = folder.className;
      out
        ..writeln()
        ..writeln('/// Assets in `${p.posix.join(assetsRoot, folder.relPath)}/`.')
        ..writeln('final class $name {')
        ..writeln('  const $name();');
      for (final m in _members(folder)) {
        if (m.isFile) {
          assetChains[m.asset!.path] = [...folder.chain, m.identifier!];
          out.writeln('  final String ${m.identifier} = ${_literal(m.asset!.path)};');
        } else {
          final child = m.folder!
            ..className = _classNameFor(m.identifier!, name)
            ..chain = [...folder.chain, m.identifier!];
          folderChains[child.relPath] = child.chain;
          pending.add(child);
          out.writeln('  final ${child.className} ${m.identifier} = const ${child.className}();');
        }
      }
      out.writeln('}');
    }

    _emitFontFamilies(out);

    unusedNames.addAll(names.keys.where((k) => !_usedNameKeys.contains(k)).toList()..sort());
    skipped.sort((a, b) => a.key.compareTo(b.key));
    return formatSettings.formatter().format(out.toString());
  }

  /// Builds the members of [folder] with stable, collision-free identifiers.
  ///
  /// Precedence: names from `codegen.names`, then folders, then files.
  /// Files whose base name clashes with a sibling get their extension
  /// appended (`logo.png` + `logo.svg` → `logoPng`, `logoSvg`). Anything that
  /// still clashes is skipped, together with every member it clashes with
  /// at the same precedence, so the outcome doesn't depend on sort order.
  List<_Member> _members(_Folder folder) {
    String childPath(String name) => folder.relPath.isEmpty ? name : '${folder.relPath}/$name';
    final members = [
      for (final MapEntry(:key, :value) in folder.folders.entries)
        _Member.folder(key, childPath(key), value),
      for (final file in folder.files)
        _Member.file(p.posix.basename(file.path), childPath(p.posix.basename(file.path)), file),
    ];

    final taken = <String, _Member>{};

    // 1. Manual names.
    final manual = <String, List<_Member>>{};
    for (final m in members) {
      final name = names[m.relPath];
      if (name == null) continue;
      _usedNameKeys.add(m.relPath);
      (manual[name] ??= []).add(m);
    }
    for (final MapEntry(key: id, value: group) in manual.entries) {
      if (group.length > 1) {
        throw ConfigException(
          '`codegen.names` gives the same name `$id` to '
          '${group.map((m) => m.relPath).join(' and ')}, which are in the same folder.',
        );
      }
      group.single.identifier = id;
      taken[id] = group.single;
    }

    // 2. Automatic names: unconvertible names are skipped outright.
    final auto = <_Member>[];
    for (final m in members.where((m) => m.identifier == null)) {
      final stem = m.isFile ? p.posix.basenameWithoutExtension(m.name) : m.name;
      if (!isCleanlyConvertible(stem)) {
        skipped.add(SkippedAsset(m.relPath, SkipReason.unconvertible, isFolder: !m.isFile));
      } else {
        auto.add(m);
      }
    }

    // Precompiled `.vec` files always get a `Vec` suffix, so turning
    // svg.precompile on never renames the matching SVG's identifier.
    String baseId(_Member m) {
      if (!m.isFile) return toLowerCamelCase(m.name);
      final id = toLowerCamelCase(p.posix.basenameWithoutExtension(m.name));
      return p.posix.extension(m.name).toLowerCase() == '.vec' ? '${id}Vec' : id;
    }

    final baseCounts = <String, int>{};
    for (final m in auto) {
      baseCounts.update(baseId(m), (c) => c + 1, ifAbsent: () => 1);
    }
    for (final id in taken.keys) {
      baseCounts.update(id, (c) => c + 1, ifAbsent: () => 1);
    }

    for (final tier in [auto.where((m) => !m.isFile), auto.where((m) => m.isFile)]) {
      final candidates = <String, List<_Member>>{};
      for (final m in tier) {
        var id = baseId(m);
        if (m.isFile && baseCounts[id]! > 1) {
          final ext = p.posix.extension(m.name).replaceFirst('.', '');
          if (ext.isNotEmpty) id = '$id${toUpperCamelCase(ext)}';
        }
        (candidates[id] ??= []).add(m);
      }
      for (final MapEntry(key: id, value: group) in candidates.entries) {
        final holder = taken[id];
        if (group.length == 1 && holder == null) {
          group.single.identifier = id;
          taken[id] = group.single;
          continue;
        }
        for (final m in group) {
          final others = [
            if (holder != null) holder.relPath,
            ...group.where((o) => o != m).map((o) => o.relPath),
          ];
          skipped.add(
            SkippedAsset(
              m.relPath,
              SkipReason.collision,
              isFolder: !m.isFile,
              collidesWith: others,
            ),
          );
        }
      }
    }

    assetCount += members.where((m) => m.isFile && m.identifier != null).length;
    return members.where((m) => m.identifier != null).toList()
      ..sort((a, b) => a.identifier!.compareTo(b.identifier!));
  }

  /// `abstract final class FontFamily { static const String cairo = 'Cairo'; }`
  ///
  /// Same stability rules as assets: names that can't be converted cleanly,
  /// and clashes, are skipped unless named via `font:<family>` in [names].
  void _emitFontFamilies(StringBuffer out) {
    if (fontFamilies.isEmpty) return;
    final candidates = <String, List<String>>{};
    for (final family in {...fontFamilies}) {
      final key = 'font:$family';
      final manual = names[key];
      if (manual != null) {
        _usedNameKeys.add(key);
        (candidates[manual] ??= []).add(family);
      } else if (!isCleanlyConvertible(family)) {
        skipped.add(SkippedAsset(key, SkipReason.unconvertible));
      } else {
        (candidates[toLowerCamelCase(family)] ??= []).add(family);
      }
    }
    for (final MapEntry(key: id, value: families) in candidates.entries) {
      if (families.length == 1) {
        fontFamilyIds[id] = families.single;
      } else {
        for (final f in families) {
          skipped.add(
            SkippedAsset(
              'font:$f',
              SkipReason.collision,
              collidesWith: [
                for (final o in families)
                  if (o != f) 'font:$o',
              ],
            ),
          );
        }
      }
    }
    if (fontFamilyIds.isEmpty) return;
    out
      ..writeln()
      ..writeln('/// Font families registered in pubspec.yaml.')
      ..writeln('abstract final class $fontFamilyClass {');
    for (final id in fontFamilyIds.keys.toList()..sort()) {
      out.writeln('  static const String $id = ${_literal(fontFamilyIds[id]!)};');
    }
    out.writeln('}');
  }

  /// Private class name derived from the parent class and the member's
  /// identifier: `_Images` + `onboarding` → `_ImagesOnboarding`. Clashes are
  /// numbered; these names are private, so that is safe.
  String _classNameFor(String identifier, String parentClass) {
    final suffix = identifier[0].toUpperCase() + identifier.substring(1);
    final base = parentClass.isEmpty ? '_$suffix' : '$parentClass$suffix';
    return uniqueIdentifier(base, _classNames);
  }
}

/// The YAML snippet to add to `asset_kit.yaml` so that [skipped] assets get
/// names. Keys are quoted only when YAML needs it.
String namesConfigSnippet(Iterable<SkippedAsset> skipped) {
  final buffer = StringBuffer('codegen:\n  names:\n');
  for (final s in skipped) {
    buffer.writeln('    ${yamlKey(s.key)}: <name>');
  }
  return buffer.toString();
}

/// Quotes [key] for use as a YAML mapping key if it isn't a safe plain scalar.
String yamlKey(String key) {
  final plain = RegExp(r'^[\p{L}\p{N}_][\p{L}\p{N}\p{M}_./-]*$', unicode: true);
  if (plain.hasMatch(key)) return key;
  return '"${key.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// A single-quoted Dart string literal for [value], escaping `\`, `'` and `$`.
String _literal(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');
  return "'$escaped'";
}
