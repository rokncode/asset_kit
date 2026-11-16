import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'codegen/identifier.dart';
import 'errors.dart';

const defaultConfigFileName = 'asset_kit.yaml';

enum ImageFormat {
  webp,
  png,

  /// Keep each image in its original format.
  keep,
}

class ImagesConfig {
  const ImagesConfig({
    this.format = ImageFormat.webp,
    this.quality = 80,
    this.losslessFor = const [],
  });

  final ImageFormat format;

  /// Lossy encoder quality, 0–100.
  final int quality;

  /// Glob patterns (matched against the path relative to the source folder,
  /// and against the bare file name) of images to encode losslessly.
  final List<String> losslessFor;

  bool isLossless(String relativePath) {
    final posixPath = p.split(relativePath).join('/');
    final name = p.posix.basename(posixPath);
    return losslessFor.any((pattern) {
      final glob = Glob(pattern, context: p.posix);
      return glob.matches(posixPath) || glob.matches(name);
    });
  }
}

class SvgConfig {
  const SvgConfig({this.optimize = true, this.precompile = false});

  final bool optimize;

  /// Also compile SVGs with `vector_graphics_compiler` into `.vec` files.
  final bool precompile;
}

class FontsConfig {
  const FontsConfig({this.registerInPubspec = true, this.overrides = const {}});

  final bool registerInPubspec;

  /// Manual family/weight/style for font files whose names can't be parsed,
  /// keyed by path relative to the output folder:
  /// `fonts/Tajawal-Hairline.ttf: { family: Tajawal, weight: 100 }`.
  final Map<String, FontOverride> overrides;
}

class FontOverride {
  const FontOverride({this.family, this.weight, this.italic});

  final String? family;

  /// 100–900 in steps of 100.
  final int? weight;

  /// Null keeps what the file name says.
  final bool? italic;
}

class CodegenConfig {
  const CodegenConfig({
    this.output = 'lib/gen/assets.gen.dart',
    this.className = 'Assets',
    this.names = const {},
  });

  final String output;
  final String className;

  /// Manual identifiers for assets or folders, keyed by path relative to the
  /// output folder: `images/شعار.webp: logo`.
  final Map<String, String> names;
}

class UnusedConfig {
  const UnusedConfig({
    this.scanDirs = const ['lib'],
    this.ignore = const [],
    this.extraScanFiles = const [],
  });

  final List<String> scanDirs;

  /// Glob patterns (relative to the project root) of other files to search
  /// for asset paths, e.g. `assets/config/*.json` or `lib/l10n/*.arb`.
  final List<String> extraScanFiles;

  /// Glob patterns of asset paths (relative to the project root, e.g.
  /// `assets/images/onboarding/*`) that are never reported as unused.
  final List<String> ignore;

  bool isIgnored(String projectRelativePath) {
    final posixPath = p.split(projectRelativePath).join('/');
    return ignore.any((pattern) => Glob(pattern, context: p.posix).matches(posixPath));
  }
}

/// The parsed contents of `asset_kit.yaml`.
///
/// All paths are stored as written (relative to [projectRoot]); use the
/// `*Dir` getters for absolute paths.
class AssetKitConfig {
  AssetKitConfig({
    required this.projectRoot,
    this.source = 'assets_src',
    this.output = 'assets',
    this.sourceScale = 3,
    this.folderScales = const {},
    this.scales = const [1, 2, 3],
    this.images = const ImagesConfig(),
    this.svg = const SvgConfig(),
    this.fonts = const FontsConfig(),
    this.codegen = const CodegenConfig(),
    this.unused = const UnusedConfig(),
    this.warnings = const [],
    this.loadedFromFile = false,
    this.configFile,
  });

  final String projectRoot;
  final String source;
  final String output;

  /// Default scale at which originals are exported.
  final double sourceScale;

  /// Per-folder overrides of [sourceScale], keyed by a folder path relative
  /// to [source] (e.g. `images/hero: 4`).
  final Map<String, double> folderScales;

  /// Scales to generate, sorted ascending. Always contains 1.
  final List<double> scales;

  final ImagesConfig images;
  final SvgConfig svg;
  final FontsConfig fonts;
  final CodegenConfig codegen;
  final UnusedConfig unused;

  /// Non-fatal problems found while parsing, such as unknown keys.
  final List<String> warnings;

  /// False when no config file existed and defaults are in use.
  final bool loadedFromFile;

  /// Absolute path of the config file, if one was loaded.
  final String? configFile;

  String get sourceDir => p.normalize(p.join(projectRoot, source));
  String get outputDir => p.normalize(p.join(projectRoot, output));
  String get codegenOutputFile => p.normalize(p.join(projectRoot, codegen.output));
  String get pubspecFile => p.join(projectRoot, 'pubspec.yaml');
  String get cacheDir => p.join(projectRoot, '.asset_kit');

  /// The scale an original at [relativePath] (relative to [source]) was
  /// exported at. Folder overrides win over the default; the most specific
  /// folder wins. A filename `@Nx` suffix is handled by the caller and takes
  /// precedence over both.
  double sourceScaleFor(String relativePath) {
    final segments = p.split(p.dirname(relativePath));
    for (var i = segments.length; i > 0; i--) {
      final folder = p.posix.joinAll(segments.take(i));
      final scale = folderScales[folder];
      if (scale != null) return scale;
    }
    return sourceScale;
  }

  /// Loads the config.
  ///
  /// If [configPath] is null, `asset_kit.yaml` in [workingDir] is used and
  /// built-in defaults apply when it doesn't exist. An explicit [configPath]
  /// that doesn't exist is an error.
  static AssetKitConfig load({String? configPath, required String workingDir}) {
    final explicit = configPath != null;
    final path = p.normalize(p.absolute(workingDir, configPath ?? defaultConfigFileName));
    final file = File(path);
    if (!file.existsSync()) {
      if (explicit) {
        throw ConfigException('Config file not found: $path');
      }
      return AssetKitConfig(projectRoot: p.normalize(p.absolute(workingDir)));
    }
    return parse(file.readAsStringSync(), projectRoot: p.dirname(path), sourceUrl: path);
  }

  /// Parses YAML [content]. Throws [ConfigException] with a precise message
  /// (including line and column) on invalid input.
  static AssetKitConfig parse(String content, {required String projectRoot, String? sourceUrl}) {
    final Object? doc;
    try {
      doc = loadYamlNode(content, sourceUrl: sourceUrl == null ? null : Uri.file(sourceUrl));
    } on YamlException catch (e) {
      final line = e.span == null ? '' : ' (line ${e.span!.start.line + 1})';
      throw ConfigException('Invalid YAML in config$line: ${e.message}');
    }
    final warnings = <String>[];
    if (doc is YamlScalar && doc.value == null) {
      return AssetKitConfig(projectRoot: projectRoot, loadedFromFile: true);
    }
    final root = _Section(_requireMap(doc as YamlNode, 'config root'), '', warnings);
    final cfg = AssetKitConfig(
      projectRoot: projectRoot,
      source: root.string('source', 'assets_src'),
      output: root.string('output', 'assets'),
      sourceScale: root.positiveNumber('source_scale', 3),
      folderScales: root.folderScales('folder_scales'),
      scales: root.scales('scales', const [1, 2, 3]),
      images: root.section(
        'images',
        (s) => ImagesConfig(
          format: s.enumValue('format', ImageFormat.values, ImageFormat.webp),
          quality: s.intInRange('quality', 80, 0, 100),
          losslessFor: s.globList('lossless_for'),
        ),
      ),
      svg: root.section(
        'svg',
        (s) => SvgConfig(
          optimize: s.boolean('optimize', true),
          precompile: s.boolean('precompile', false),
        ),
      ),
      fonts: root.section(
        'fonts',
        (s) => FontsConfig(
          registerInPubspec: s.boolean('register_in_pubspec', true),
          overrides: s.fontOverrides('overrides'),
        ),
      ),
      codegen: root.section(
        'codegen',
        (s) => CodegenConfig(
          output: s.string('output', 'lib/gen/assets.gen.dart'),
          className: s.dartClassName('class_name', 'Assets'),
          names: s.identifierMap('names'),
        ),
      ),
      unused: root.section(
        'unused',
        (s) => UnusedConfig(
          scanDirs: s.stringList('scan_dirs', const ['lib']),
          ignore: s.globList('ignore'),
          extraScanFiles: s.globList('extra_scan_files'),
        ),
      ),
      warnings: warnings,
      loadedFromFile: true,
      configFile: sourceUrl,
    );
    root.warnUnknownKeys();
    cfg._validate();
    return cfg;
  }

  void _validate() {
    if (p.equals(sourceDir, outputDir)) {
      throw ConfigException(
        '`source` and `output` must be different folders (both are "$source").',
      );
    }
    if (p.isWithin(sourceDir, outputDir) || p.isWithin(outputDir, sourceDir)) {
      throw ConfigException(
        '`source` ($source) and `output` ($output) must not be nested inside each other.',
      );
    }
    if (!codegen.output.endsWith('.dart')) {
      throw ConfigException('`codegen.output` must be a .dart file, got "${codegen.output}".');
    }
  }
}

YamlMap _requireMap(YamlNode node, String what) {
  if (node is YamlMap) return node;
  throw ConfigException(
    'Expected $what to be a map ${_where(node)}',
    hint: 'Run `asset_kit init` to see a complete example config.',
  );
}

String _where(YamlNode node) {
  final start = node.span.start;
  return '(line ${start.line + 1}, column ${start.column + 1})';
}

/// Typed accessors over one YAML map that track which keys were read so that
/// unknown keys (usually typos) can be reported.
class _Section {
  _Section(this.map, this.prefix, this.warnings);

  final YamlMap map;
  final String prefix;
  final List<String> warnings;
  final _seen = <String>{};

  String _key(String key) => '$prefix$key';

  YamlNode? _node(String key) {
    _seen.add(key);
    final node = map.nodes[key];
    if (node is YamlScalar && node.value == null) return null;
    return node;
  }

  Never _fail(String key, YamlNode node, String expected) {
    throw ConfigException(
      '`${_key(key)}` must be $expected, got "${node.span.text}" ${_where(node)}',
    );
  }

  void warnUnknownKeys() {
    for (final key in map.keys) {
      if (!_seen.contains(key)) {
        final node = map.nodes[key]!;
        warnings.add('Unknown config key `${_key('$key')}` ${_where(node)} — ignored.');
      }
    }
  }

  T section<T>(String key, T Function(_Section) build) {
    final node = _node(key);
    final sub = _Section(
      node == null ? YamlMap() : _requireMap(node, '`${_key(key)}`'),
      '${_key(key)}.',
      warnings,
    );
    final result = build(sub);
    sub.warnUnknownKeys();
    return result;
  }

  String string(String key, String fallback) {
    final node = _node(key);
    if (node == null) return fallback;
    final value = (node as YamlScalar).value;
    if (value is! String || value.trim().isEmpty) _fail(key, node, 'a non-empty string');
    return value.trim();
  }

  bool boolean(String key, bool fallback) {
    final node = _node(key);
    if (node == null) return fallback;
    final value = node is YamlScalar ? node.value : null;
    if (value is! bool) _fail(key, node, 'true or false');
    return value;
  }

  double positiveNumber(String key, double fallback) {
    final node = _node(key);
    if (node == null) return fallback;
    return _positive(key, node);
  }

  double _positive(String key, YamlNode node) {
    final value = node is YamlScalar ? node.value : null;
    if (value is! num || value <= 0) _fail(key, node, 'a positive number');
    return value.toDouble();
  }

  int intInRange(String key, int fallback, int min, int max) {
    final node = _node(key);
    if (node == null) return fallback;
    final value = node is YamlScalar ? node.value : null;
    if (value is! int || value < min || value > max) {
      _fail(key, node, 'an integer from $min to $max');
    }
    return value;
  }

  T enumValue<T extends Enum>(String key, List<T> values, T fallback) {
    final node = _node(key);
    if (node == null) return fallback;
    final value = node is YamlScalar ? node.value : null;
    for (final v in values) {
      if (v.name == value) return v;
    }
    _fail(key, node, 'one of ${values.map((v) => v.name).join(' | ')}');
  }

  List<String> stringList(String key, List<String> fallback) {
    final node = _node(key);
    if (node == null) return fallback;
    if (node is! YamlList) _fail(key, node, 'a list of strings');
    return [
      for (final item in node.nodes)
        if (item is YamlScalar && item.value is String && (item.value as String).isNotEmpty)
          item.value as String
        else
          _fail(key, item, 'a list of non-empty strings'),
    ];
  }

  List<String> globList(String key) {
    final patterns = stringList(key, const []);
    for (final pattern in patterns) {
      try {
        Glob(pattern);
      } on FormatException catch (e) {
        throw ConfigException('Invalid glob pattern "$pattern" in `${_key(key)}`: ${e.message}');
      }
    }
    return patterns;
  }

  List<double> scales(String key, List<double> fallback) {
    final node = _node(key);
    if (node == null) return fallback;
    if (node is! YamlList || node.isEmpty) _fail(key, node, 'a non-empty list of positive numbers');
    final values = {for (final item in node.nodes) _positive(key, item)}.toList()..sort();
    if (values.first != 1) {
      throw ConfigException(
        '`${_key(key)}` must include 1 ${_where(node)}',
        hint: 'Flutter needs the 1x "main" asset to resolve the 2.0x/3.0x variants.',
      );
    }
    return values;
  }

  Map<String, double> folderScales(String key) {
    final node = _node(key);
    if (node == null) return const {};
    final map = _requireMap(node, '`${_key(key)}`');
    return {
      for (final entry in map.nodes.entries)
        p.posix.normalize('${(entry.key as YamlNode).value}'): _positive(
          '$key.${(entry.key as YamlNode).value}',
          entry.value,
        ),
    };
  }

  Map<String, String> identifierMap(String key) {
    final node = _node(key);
    if (node == null) return const {};
    final map = _requireMap(node, '`${_key(key)}`');
    final result = <String, String>{};
    for (final MapEntry(key: k, value: v) in map.nodes.entries) {
      final path = p.posix.normalize('${(k as YamlNode).value}'.replaceAll(r'\', '/'));
      final value = v is YamlScalar ? v.value : null;
      if (value is! String || !isValidMemberName(value)) {
        _fail('$key.$path', v, 'a lowerCamelCase Dart identifier that is not a reserved word');
      }
      result[path] = value;
    }
    return result;
  }

  Map<String, FontOverride> fontOverrides(String key) {
    final node = _node(key);
    if (node == null) return const {};
    final map = _requireMap(node, '`${_key(key)}`');
    final result = <String, FontOverride>{};
    for (final MapEntry(key: k, value: v) in map.nodes.entries) {
      final path = p.posix.normalize('${(k as YamlNode).value}'.replaceAll(r'\', '/'));
      final entry = _Section(
        _requireMap(v, '`${_key(key)}.$path`'),
        '${_key(key)}.$path.',
        warnings,
      );
      final family = entry.map.nodes.containsKey('family') ? entry.string('family', '') : null;
      final weightNode = entry._node('weight');
      int? weight;
      if (weightNode != null) {
        final w = weightNode is YamlScalar ? weightNode.value : null;
        if (w is! int || w < 100 || w > 900 || w % 100 != 0) {
          entry._fail('weight', weightNode, 'one of 100, 200, … 900');
        }
        weight = w;
      }
      final styleNode = entry._node('style');
      bool? italic;
      if (styleNode != null) {
        final style = styleNode is YamlScalar ? styleNode.value : null;
        if (style != 'normal' && style != 'italic') {
          entry._fail('style', styleNode, 'normal or italic');
        }
        italic = style == 'italic';
      }
      entry.warnUnknownKeys();
      result[path] = FontOverride(family: family, weight: weight, italic: italic);
    }
    return result;
  }

  String dartClassName(String key, String fallback) {
    final value = string(key, fallback);
    if (!RegExp(r'^[A-Z][A-Za-z0-9]*$').hasMatch(value)) {
      _fail(key, map.nodes[key]!, 'an UpperCamelCase Dart class name');
    }
    return value;
  }
}

/// The default config written by `asset_kit init`.
const defaultConfigYaml = '''
# asset_kit configuration. Paths are relative to this file.

# Where you drop high-resolution originals.
source: assets_src
# Where processed, resolution-aware assets are written (bundled by Flutter).
output: assets

# Scale the originals were exported at. A file name suffix wins over this:
# `logo@4x.png` is treated as a 4x original and outputs `logo`.
source_scale: 3
# Per-folder overrides, relative to `source`:
# folder_scales:
#   images/illustrations: 4

# Variants to generate. Must include 1. Never upscales.
scales: [1, 2, 3]

images:
  format: webp           # webp | png | keep
  quality: 80            # 0-100, lossy quality
  lossless_for: ["*.icon.png"]

svg:
  optimize: true
  precompile: false      # also emit .vec files via vector_graphics_compiler

fonts:
  register_in_pubspec: true
  # Weight and style come from file names (Cairo-BoldItalic.ttf → 700 italic).
  # For names that can't be read, set them here (paths relative to `output`):
  # overrides:
  #   fonts/Tajawal-Hairline.ttf: { family: Tajawal, weight: 100 }

codegen:
  output: lib/gen/assets.gen.dart
  class_name: Assets
  # Identifiers for names that can't be converted automatically (e.g. Arabic
  # file names) or that clash. Keys are paths relative to `output`.
  # names:
  #   images/شعار.webp: logoAr

unused:
  scan_dirs: [lib]
  ignore: []             # e.g. ["assets/images/onboarding/*"]
  # Other files that reference assets, searched as plain text:
  extra_scan_files: []   # e.g. ["assets/config/*.json", "lib/l10n/*.arb"]
''';
