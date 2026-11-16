import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// The `dart format` settings that apply to a project, so generated code is
/// byte-for-byte what `dart format` would produce there.
///
/// `dart format` picks its style from the package's language version (the
/// lower bound of `environment: sdk:` — "tall" style from 3.7) and its line
/// length from `formatter: page_width:` in `analysis_options.yaml`.
class FormatSettings {
  const FormatSettings({this.languageVersion, this.pageWidth});

  final Version? languageVersion;
  final int? pageWidth;

  static FormatSettings forProject(String projectRoot) => FormatSettings(
    languageVersion: _languageVersion(p.join(projectRoot, 'pubspec.yaml')),
    pageWidth: _pageWidth(p.join(projectRoot, 'analysis_options.yaml')),
  );

  DartFormatter formatter() => DartFormatter(
    languageVersion: languageVersion ?? DartFormatter.latestLanguageVersion,
    pageWidth: pageWidth,
  );

  static Object? _readYaml(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return loadYaml(file.readAsStringSync());
    } on YamlException {
      return null;
    }
  }

  static Version? _languageVersion(String pubspecPath) {
    final doc = _readYaml(pubspecPath);
    if (doc is! Map) return null;
    final env = doc['environment'];
    final sdk = env is Map ? env['sdk'] : null;
    if (sdk is! String) return null;
    try {
      final constraint = VersionConstraint.parse(sdk);
      final min = constraint is VersionRange ? constraint.min : null;
      if (min == null) return null;
      return Version(min.major, min.minor, 0);
    } on FormatException {
      return null;
    }
  }

  static int? _pageWidth(String optionsPath) {
    final doc = _readYaml(optionsPath);
    if (doc is! Map) return null;
    final formatter = doc['formatter'];
    final width = formatter is Map ? formatter['page_width'] : null;
    return width is int && width > 0 ? width : null;
  }
}
