import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config.dart';
import '../errors.dart';
import '../scanner/asset_index.dart';

/// Weight names (lowercase, without separators) → CSS/Flutter weight.
const fontWeightNames = {
  'thin': 100,
  'extralight': 200,
  'ultralight': 200,
  'light': 300,
  'regular': 400,
  'book': 400,
  'normal': 400,
  'medium': 500,
  'semibold': 600,
  'demibold': 600,
  'bold': 700,
  'extrabold': 800,
  'ultrabold': 800,
  'black': 900,
  'heavy': 900,
};

/// What a font file name says about the face.
typedef ParsedFontName = ({String family, int? weight, bool italic, bool variable});

final _variableBrackets = RegExp(r'\[[^\]]*\]$'); // Cairo[wght], Cairo-Italic[slnt,wght]
final _variableSuffix = RegExp(r'-?VariableFont(_[\w,]+)?$'); // Cairo-VariableFont_wght
final _camelWeightSuffix = RegExp(
  r'[a-z0-9](Thin|ExtraLight|UltraLight|Light|Regular|Book|Normal|Medium|SemiBold|DemiBold|'
  r'Bold|ExtraBold|UltraBold|Black|Heavy|Italic)(Italic)?$',
);

/// Parses a font file name (without extension) into family, weight and
/// style. Returns null if the name can't be read without guessing.
///
/// - `Cairo-Bold` → Cairo 700; `Cairo-BoldItalic` → Cairo 700 italic;
///   `Cairo-Italic` → Cairo 400 italic; `Cairo` → Cairo 400.
/// - Multi-word families work: `Noto-Sans-Arabic-SemiBold` → `Noto-Sans-Arabic`
///   600; `Cairo-Extra-Light` → Cairo 200 (the first split that yields a
///   known suffix wins).
/// - Variable fonts (`Cairo[wght]`, `Cairo-VariableFont_wght`,
///   `Cairo-Italic[wght]`) have no weight.
/// - Unknown suffixes (`Tajawal-Hairline`) and run-together names
///   (`CairoBold`) return null.
ParsedFontName? parseFontFileName(String name) {
  var base = name;
  var variable = false;
  if (_variableBrackets.hasMatch(base)) {
    base = base.replaceFirst(_variableBrackets, '');
    variable = true;
  }
  if (_variableSuffix.hasMatch(base)) {
    base = base.replaceFirst(_variableSuffix, '');
    variable = true;
  }
  if (base.isEmpty) return null;

  for (var i = base.indexOf('-'); i > 0; i = base.indexOf('-', i + 1)) {
    final family = base.substring(0, i);
    final style = _parseStyle(base.substring(i + 1));
    if (style != null) {
      return (
        family: family,
        weight: variable ? null : style.weight,
        italic: style.italic,
        variable: variable,
      );
    }
  }
  if (base.contains('-')) return null; // has a suffix, but not one we know
  if (!variable && _camelWeightSuffix.hasMatch(base)) return null; // CairoBold: ambiguous
  return (family: base, weight: variable ? null : 400, italic: false, variable: variable);
}

({int weight, bool italic})? _parseStyle(String suffix) {
  var s = suffix.toLowerCase().replaceAll(RegExp(r'[-_ ]'), '');
  final italic = s.contains('italic');
  s = s.replaceAll('italic', '');
  if (s.isEmpty) return (weight: 400, italic: italic);
  final weight = fontWeightNames[s];
  return weight == null ? null : (weight: weight, italic: italic);
}

/// Whether [bytes] is an OpenType/TrueType font with an `fvar` table,
/// i.e. a variable font.
bool hasFvarTable(Uint8List bytes) {
  if (bytes.length < 12) return false;
  final data = ByteData.sublistView(bytes);
  final numTables = data.getUint16(4);
  for (var i = 0; i < numTables; i++) {
    final offset = 12 + i * 16;
    if (offset + 4 > bytes.length) return false;
    if (String.fromCharCodes(bytes, offset, offset + 4) == 'fvar') return true;
  }
  return false;
}

/// One font file as registered under `flutter: fonts:`.
class FontFace {
  FontFace({
    required this.asset,
    required this.family,
    this.weight,
    this.italic = false,
    this.variable = false,
  });

  /// Project-relative path, e.g. `assets/fonts/Cairo-Bold.ttf`.
  final String asset;
  final String family;

  /// Null for variable fonts (and overrides without a weight).
  final int? weight;
  final bool italic;
  final bool variable;

  /// The pubspec entry for this face.
  Map<String, Object> toPubspec() => {
    'asset': asset,
    'weight': ?weight,
    if (italic) 'style': 'italic',
  };

  String get describe => '${weight ?? 'variable'}${italic ? ' italic' : ''}';
}

/// A font whose name could not be parsed; it needs a `fonts.overrides`
/// entry.
class UnknownFont {
  UnknownFont(this.key, this.guessedFamily);

  /// Path relative to the output folder, e.g. `fonts/Tajawal-Hairline.ttf`.
  final String key;

  /// Used only to pre-fill the suggested YAML.
  final String guessedFamily;
}

class FontPlan {
  FontPlan(this.faces, this.unknown);

  final List<FontFace> faces;
  final List<UnknownFont> unknown;

  /// Families in name order, each with faces ordered by weight then style.
  Map<String, List<FontFace>> get byFamily {
    final map = <String, List<FontFace>>{};
    for (final f in faces) {
      (map[f.family] ??= []).add(f);
    }
    for (final list in map.values) {
      list.sort((a, b) {
        final w = (a.weight ?? 0).compareTo(b.weight ?? 0);
        return w != 0 ? w : (a.italic ? 1 : 0).compareTo(b.italic ? 1 : 0);
      });
    }
    return Map.fromEntries(map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  List<FontFace> get variableFaces => faces.where((f) => f.variable).toList();
}

/// Reads every `.ttf`/`.otf` in the output folder and works out how to
/// register it. Throws [AssetKitException] if two files define the same
/// family, weight and style.
FontPlan planFonts(AssetKitConfig config) {
  final outputRoot = p.posix.joinAll(
    p.split(p.relative(config.outputDir, from: config.projectRoot)),
  );
  final index = AssetIndex.scan(projectRoot: config.projectRoot, assetsDir: config.outputDir);
  final faces = <FontFace>[];
  final unknown = <UnknownFont>[];

  for (final entry in index.entries.where((e) => e.kind == AssetKind.font)) {
    final key = p.posix.relative(entry.path, from: outputRoot);
    final stem = p.posix.basenameWithoutExtension(entry.path);
    final parsed = parseFontFileName(stem);
    final override = config.fonts.overrides[key];
    final fvar = hasFvarTable(File(p.join(config.projectRoot, entry.path)).readAsBytesSync());

    if (override != null) {
      final family = override.family ?? parsed?.family;
      if (family == null) {
        throw ConfigException('`fonts.overrides` entry "$key" needs a `family`.');
      }
      final variable = fvar || (parsed?.variable ?? false);
      faces.add(
        FontFace(
          asset: entry.path,
          family: family,
          weight: override.weight ?? (variable ? null : parsed?.weight),
          italic: override.italic ?? parsed?.italic ?? false,
          variable: variable,
        ),
      );
    } else if (parsed == null) {
      unknown.add(UnknownFont(key, stem.split('-').first.replaceAll(_variableBrackets, '')));
    } else {
      final variable = parsed.variable || fvar;
      faces.add(
        FontFace(
          asset: entry.path,
          family: parsed.family,
          weight: variable ? null : parsed.weight,
          italic: parsed.italic,
          variable: variable,
        ),
      );
    }
  }

  final seen = <String, FontFace>{};
  final clashes = <String>[];
  for (final face in faces) {
    final key = '${face.family}|${face.weight}|${face.italic}';
    final other = seen[key];
    if (other != null) {
      clashes.add('  ${face.family} ${face.describe}: ${other.asset} and ${face.asset}');
    } else {
      seen[key] = face;
    }
  }
  if (clashes.isNotEmpty) {
    throw AssetKitException(
      'Two font files define the same family, weight and style:\n${clashes.join('\n')}',
      hint: 'Remove one of them, or give one a different weight/style in `fonts.overrides`.',
    );
  }
  return FontPlan(faces, unknown..sort((a, b) => a.key.compareTo(b.key)));
}

/// Every family name under `flutter: fonts:` in [pubspecPath], in file
/// order. Includes families the user registered by hand.
List<String> registeredFontFamilies(String pubspecPath) {
  final file = File(pubspecPath);
  if (!file.existsSync()) return const [];
  try {
    final doc = loadYaml(file.readAsStringSync());
    final fonts = doc is Map && doc['flutter'] is Map ? (doc['flutter'] as Map)['fonts'] : null;
    if (fonts is! List) return const [];
    return [
      for (final f in fonts)
        if (f is Map && f['family'] is String) f['family'] as String,
    ];
  } on YamlException {
    return const [];
  }
}
