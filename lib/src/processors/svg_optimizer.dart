import 'dart:math' as math;

import 'package:xml/xml.dart';

/// Namespace URIs of editor-specific data (Inkscape, Sodipodi, Illustrator,
/// Sketch, Affinity Serif, Adobe XMP...). Elements and attributes in these
/// namespaces never affect rendering.
const _editorNamespaces = {
  'http://inkscape.sourceforge.net/DTD/sodipodi-0.dtd',
  'http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd',
  'http://www.inkscape.org/namespaces/inkscape',
  'http://www.bohemiancoding.com/sketch/ns',
  'http://ns.adobe.com/AdobeIllustrator/10.0/',
  'http://ns.adobe.com/Graphs/1.0/',
  'http://ns.adobe.com/AdobeSVGViewerExtensions/3.0/',
  'http://ns.adobe.com/Variables/1.0/',
  'http://ns.adobe.com/SaveForWeb/1.0/',
  'http://ns.adobe.com/Extensibility/1.0/',
  'http://ns.adobe.com/Flows/1.0/',
  'http://ns.adobe.com/ImageReplacement/1.0/',
  'http://ns.adobe.com/GenericCustomNamespace/1.0/',
  'http://ns.adobe.com/XPath/1.0/',
  'http://schemas.microsoft.com/visio/2003/SVGExtensions/',
  'http://taptrix.com/vectorillustrator/svg_extensions',
  'http://www.figma.com/figma/ns',
  'http://purl.org/dc/elements/1.1/',
  'http://creativecommons.org/ns#',
  'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
  'http://www.serif.com/',
  'http://www.vector.evaxdesign.sk',
};

/// Attributes that carry no rendering information.
const _junkAttributes = {'data-name', 'enable-background', 'version'};

/// Elements whose text content is significant.
const _textElements = {'text', 'tspan', 'textPath', 'style', 'script', 'title', 'desc'};

/// Attributes that hold plain coordinates or lengths.
const _geometryAttributes = {
  'd',
  'points',
  'viewBox',
  'x',
  'y',
  'width',
  'height',
  'cx',
  'cy',
  'r',
  'rx',
  'ry',
  'x1',
  'y1',
  'x2',
  'y2',
  'fx',
  'fy',
  'stroke-width',
  'stroke-dasharray',
  'stroke-dashoffset',
};

/// Attributes that hold transform matrices, where scale/skew components are
/// unitless and need more precision.
const _transformAttributes = {'transform', 'gradientTransform', 'patternTransform'};

/// Decimal numbers only: integers are left untouched, which keeps compact
/// arc flags like `a1 1 0 011 2` intact.
final _decimal = RegExp(r'-?(?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?');

/// Statistics about one optimisation run.
class SvgOptimizeResult {
  SvgOptimizeResult(this.output, {required this.precision});

  final String output;

  /// Decimal places used for coordinates.
  final int precision;
}

/// Optimises an SVG document without changing how it renders:
///
/// - removes comments, the XML declaration, doctype and processing
///   instructions;
/// - removes `<metadata>` and editor-specific elements, attributes and
///   namespace declarations (Inkscape, Illustrator, Sketch, Figma...);
/// - removes ids that nothing references (only when the file has no
///   `<style>` or `<script>`, which could reference them);
/// - removes empty groups and `<defs>`, and unwraps attribute-less groups;
/// - removes insignificant whitespace;
/// - rounds coordinates to a precision derived from the viewBox size, so
///   the error stays below 1/100,000 of the image.
///
/// Throws [XmlException] if [svg] is not well-formed XML.
SvgOptimizeResult optimizeSvg(String svg) {
  final doc = XmlDocument.parse(svg);
  final root = doc.rootElement;

  doc.children.removeWhere((n) => n is! XmlElement);
  _removeNodes(root);

  final editorPrefixes = <String>{};
  for (final attr in root.attributes) {
    if (attr.name.prefix == 'xmlns' && _editorNamespaces.contains(attr.value)) {
      editorPrefixes.add(attr.name.local);
    }
  }
  _removeEditorData(root, editorPrefixes);

  final canDropIds = root.descendantElements.every(
    (e) => e.name.local != 'style' && e.name.local != 'script',
  );
  if (canDropIds) _removeUnreferencedIds(root);

  _cleanGroups(root);

  final precision = _precisionFor(root);
  _roundNumbers(root, precision);
  _dropUnusedNamespaces(root);

  return SvgOptimizeResult(doc.toXmlString(), precision: precision);
}

void _removeNodes(XmlElement element) {
  final preserveText = _textElements.contains(element.name.local);
  element.children.removeWhere(
    (node) =>
        node is XmlComment ||
        node is XmlProcessing ||
        node is XmlDoctype ||
        (node is XmlText && !preserveText && node.value.trim().isEmpty) ||
        (node is XmlElement && node.name.local == 'metadata'),
  );
  for (final child in element.childElements) {
    _removeNodes(child);
  }
}

bool _isEditorName(XmlName name, Set<String> editorPrefixes) {
  final prefix = name.prefix;
  if (prefix == null) return false;
  if (prefix == 'xmlns') return editorPrefixes.contains(name.local);
  if (editorPrefixes.contains(prefix)) return true;
  final uri = name.namespaceUri;
  return uri != null && _editorNamespaces.contains(uri);
}

void _removeEditorData(XmlElement element, Set<String> editorPrefixes) {
  element.attributes.removeWhere(
    (a) => _isEditorName(a.name, editorPrefixes) || _junkAttributes.contains(a.name.qualified),
  );
  element.children.removeWhere((n) => n is XmlElement && _isEditorName(n.name, editorPrefixes));
  for (final child in element.childElements) {
    _removeEditorData(child, editorPrefixes);
  }
}

void _removeUnreferencedIds(XmlElement root) {
  final referenced = <String>{};
  final ref = RegExp(r'''#([^\s)"';,]+)''');
  for (final e in [root, ...root.descendantElements]) {
    for (final a in e.attributes) {
      for (final m in ref.allMatches(a.value)) {
        referenced.add(m.group(1)!);
      }
      // SMIL timing references such as begin="other.end".
      if (a.name.local == 'begin' || a.name.local == 'end') {
        referenced.addAll(RegExp(r'([\w-]+)\.').allMatches(a.value).map((m) => m.group(1)!));
      }
    }
  }
  for (final e in [root, ...root.descendantElements]) {
    e.attributes.removeWhere((a) => a.name.local == 'id' && !referenced.contains(a.value));
  }
}

/// Removes empty `<g>`/`<defs>` and unwraps `<g>` elements without
/// attributes, bottom-up.
void _cleanGroups(XmlElement element) {
  for (final child in element.childElements.toList()) {
    _cleanGroups(child);
  }
  final children = element.children;
  for (var i = children.length - 1; i >= 0; i--) {
    final node = children[i];
    if (node is! XmlElement) continue;
    final name = node.name.local;
    if ((name == 'g' || name == 'defs') && node.children.isEmpty) {
      children.removeAt(i);
    } else if (name == 'g' && node.attributes.isEmpty && element.name.local != 'switch') {
      final grandChildren = node.children.toList();
      node.children.clear();
      children
        ..removeAt(i)
        ..insertAll(i, grandChildren);
    }
  }
}

/// Decimal places such that rounding error stays below ~1e-5 of the image.
int _precisionFor(XmlElement root) {
  double? size;
  final viewBox = root.getAttribute('viewBox');
  if (viewBox != null) {
    final parts = viewBox.trim().split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
    if (parts.length == 4 && parts[2] != null && parts[3] != null) {
      size = math.max(parts[2]!.abs(), parts[3]!.abs());
    }
  }
  size ??= [root.getAttribute('width'), root.getAttribute('height')]
      .map((v) => v == null ? null : double.tryParse(v.replaceAll(RegExp(r'[a-z%]+$'), '')))
      .whereType<double>()
      .fold<double?>(null, (m, v) => m == null ? v : math.max(m, v));
  if (size == null || size <= 0) return 5;
  final decimals = (5 - math.log(size) / math.ln10).ceil();
  return decimals.clamp(3, 8);
}

String _round(String token, int decimals) {
  final value = double.parse(token);
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  if (text == '-0') text = '0';
  // Never make a token longer than the original.
  return text.length <= token.length ? text : token;
}

void _roundNumbers(XmlElement element, int precision) {
  for (final a in element.attributes) {
    final name = a.name.local;
    final decimals = _transformAttributes.contains(name)
        ? math.max(precision, 5)
        : _geometryAttributes.contains(name)
        ? precision
        : null;
    if (decimals == null) continue;
    a.value = a.value.replaceAllMapped(_decimal, (m) => _round(m.group(0)!, decimals));
  }
  for (final child in element.childElements) {
    _roundNumbers(child, precision);
  }
}

/// Removes `xmlns:prefix` declarations whose prefix is no longer used by
/// any element or attribute (e.g. `xmlns:svg`, `xmlns:xlink`).
void _dropUnusedNamespaces(XmlElement root) {
  final used = <String>{};
  for (final e in [root, ...root.descendantElements]) {
    if (e.name.prefix case final prefix?) used.add(prefix);
    for (final a in e.attributes) {
      final prefix = a.name.prefix;
      if (prefix != null && prefix != 'xmlns') used.add(prefix);
    }
  }
  for (final e in [root, ...root.descendantElements]) {
    e.attributes.removeWhere((a) => a.name.prefix == 'xmlns' && !used.contains(a.name.local));
  }
}
