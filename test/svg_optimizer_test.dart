import 'package:asset_kit/src/processors/svg_optimizer.dart';
import 'package:test/test.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vgc;

import 'support/source_images.dart';

String opt(String svg) => optimizeSvg(svg).output;

List<double> _coords(vgc.PathCommand c) => switch (c) {
  vgc.MoveToCommand(:final x, :final y) => [0, x, y],
  vgc.LineToCommand(:final x, :final y) => [1, x, y],
  vgc.CubicToCommand(:final x1, :final y1, :final x2, :final y2, :final x3, :final y3) => [
    2,
    x1,
    y1,
    x2,
    y2,
    x3,
    y3,
  ],
  vgc.CloseCommand() => [3],
  _ => throw StateError('unexpected $c'),
};

/// Asserts that [a] and [b] produce the same drawing instructions, with
/// coordinates equal within [tolerance] (in SVG user units).
void expectSameRendering(String a, String b, {double tolerance = 1e-3}) {
  final x = vgc.parseWithoutOptimizers(a);
  final y = vgc.parseWithoutOptimizers(b);
  expect(y.width, x.width);
  expect(y.height, x.height);
  // Paints can embed geometry (gradient endpoints derived from bounding
  // boxes), so compare their descriptions with numbers rounded.
  String rounded(Object o) => '$o'.replaceAllMapped(
    RegExp(r'-?\d+\.\d+'),
    (m) => double.parse(m.group(0)!).toStringAsFixed(3),
  );
  expect(y.paints.map(rounded), x.paints.map(rounded), reason: 'paints differ');
  expect(y.commands, x.commands, reason: 'draw commands differ');
  expect(y.paths.length, x.paths.length);
  for (var i = 0; i < x.paths.length; i++) {
    expect(y.paths[i].fillType, x.paths[i].fillType);
    final cx = x.paths[i].commands.map(_coords).toList();
    final cy = y.paths[i].commands.map(_coords).toList();
    expect(cy.length, cx.length, reason: 'path $i command count');
    for (var j = 0; j < cx.length; j++) {
      expect(cy[j].length, cx[j].length, reason: 'path $i command $j type');
      for (var k = 0; k < cx[j].length; k++) {
        expect(cy[j][k], closeTo(cx[j][k], tolerance), reason: 'path $i command $j value $k');
      }
    }
  }
}

void main() {
  group('optimizeSvg on an Inkscape export', () {
    late String out;
    setUpAll(() => out = opt(inkscapeSvg));

    test('renders the same', () => expectSameRendering(inkscapeSvg, out));

    test('is much smaller', () => expect(out.length, lessThan(inkscapeSvg.length ~/ 2)));

    test('removes comments, declaration, metadata and editor data', () {
      for (final junk in [
        '<!--',
        '<?xml',
        'metadata',
        'inkscape',
        'sodipodi',
        'rdf:',
        'dc:',
        'version=',
      ]) {
        expect(out, isNot(contains(junk)), reason: junk);
      }
    });

    test('removes unused namespace declarations', () {
      expect(out, isNot(contains('xmlns:svg')));
      expect(out, isNot(contains('xmlns:xlink')));
      expect(out, contains('xmlns="http://www.w3.org/2000/svg"'));
    });

    test('keeps referenced ids and drops the rest', () {
      expect(out, contains('id="grad"'));
      for (final id in ['svg8', 'layer1', 'g10', 'path12', 'defs2']) {
        expect(out, isNot(contains('"$id"')), reason: id);
      }
    });

    test('removes empty groups and unwraps attribute-less ones', () {
      expect(out, isNot(contains('<g')));
    });

    test('rounds redundant precision', () {
      expect(out, contains('d="M 12,3 L 2,12.5 H 5 V 21'));
      expect(out, contains('r="1.5"'));
    });

    test('keeps compact arc flags intact', () {
      expect(out, contains('a1 1 0 011 1'));
    });
  });

  test('precision follows the viewBox size', () {
    const small =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">'
        '<path d="M0.123456789 0.5L0.98765432 0.5"/></svg>';
    expect(optimizeSvg(small).precision, 5);
    expect(opt(small), contains('d="M0.12346 0.5L0.98765 0.5"'));
    expectSameRendering(small, opt(small), tolerance: 1e-5);

    const large =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2000 1000">'
        '<path d="M10.123456 20.5L1999.987654 0"/></svg>';
    expect(optimizeSvg(large).precision, 3);
    expect(opt(large), contains('d="M10.123 20.5L1999.988 0"'));
  });

  test('transform matrices keep at least 5 decimals', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2000 2000">'
        '<rect width="10" height="10" transform="matrix(0.70710678 0.70710678 -0.70710678 0.70710678 0 0)"/></svg>';
    expect(opt(svg), contains('matrix(0.70711 0.70711 -0.70711 0.70711 0 0)'));
  });

  test('integers and exponent-free tokens are left alone', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M1 2L10 20"/></svg>';
    expect(opt(svg), contains('d="M1 2L10 20"'));
  });

  test('keeps ids when a <style> element could reference them', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<style>#dot{fill:red}</style><circle id="dot" cx="5" cy="5" r="2"/></svg>';
    expect(opt(svg), contains('id="dot"'));
  });

  test('keeps ids used by xlink:href and its namespace', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        'viewBox="0 0 10 10"><defs><circle id="c" r="2"/></defs><use xlink:href="#c" x="5" y="5"/></svg>';
    final out = opt(svg);
    expect(out, contains('id="c"'));
    expect(out, contains('xmlns:xlink'));
    expectSameRendering(svg, out);
  });

  test('keeps text whitespace and xml:space', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 20">'
        '<text xml:space="preserve" x="0" y="10">Hello  <tspan>world</tspan> !</text></svg>';
    final out = opt(svg);
    expect(out, contains('xml:space="preserve"'));
    expect(out, contains('Hello  <tspan>world</tspan> !'));
  });

  test('does not unwrap groups inside <switch>', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<switch><g><rect width="1" height="1"/><rect x="2" width="1" height="1"/></g></switch></svg>';
    expect(opt(svg), contains('<switch><g>'));
  });

  test('keeps groups that carry attributes', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<g fill="red" opacity="0.5"><rect width="5" height="5"/></g></svg>';
    final out = opt(svg);
    expect(out, contains('<g fill="red" opacity="0.5">'));
    expectSameRendering(svg, out);
  });

  test('rejects malformed XML', () {
    expect(() => optimizeSvg('<svg><g></svg>'), throwsA(anything));
  });
}
