import 'package:asset_kit/src/scanner/dart_lexer.dart';
import 'package:test/test.dart';

void main() {
  List<String> strings(String src) => lexDart(src).strings.map((s) => s.value).toList();

  test('extracts single, double, triple and raw strings', () {
    expect(
      strings('''
var a = 'one';
var b = "two";
var c = \'\'\'three
lines\'\'\';
var d = r'raw\\n\$x';
'''),
      ['one', 'two', 'three\nlines', r'raw\n$x'],
    );
  });

  test('resolves escapes', () {
    expect(strings(r"var a = 'it\'s\n';"), ["it's\n"]);
  });

  test('marks interpolations', () {
    final s = lexDart(r"var p = 'assets/$dir/${name}.png';").strings.single;
    expect(s.hasInterpolation, isTrue);
    expect(s.parts, ['assets/', '/', '.png']);
  });

  test('strings nested inside interpolations are found too', () {
    final lexed = lexDart(r"""var p = 'a ${cond ? 'assets/x.png' : "b"} c';""");
    expect(lexed.strings.map((s) => s.value), containsAll(['assets/x.png', 'b']));
  });

  test('interpolated code stays in the code view', () {
    final lexed = lexDart(r"var p = '${Assets.images.logo}';");
    expect(lexed.code, contains('Assets.images.logo'));
  });

  test('comments are blanked; strings inside comments are ignored', () {
    final lexed = lexDart('''
// Assets.images.a 'assets/a.png'
/* Assets.images.b /* nested */ 'assets/b.png' */
/// doc Assets.images.c
var x = Assets.images.d; // trailing
''');
    expect(lexed.code, isNot(contains('images.a')));
    expect(lexed.code, isNot(contains('images.b')));
    expect(lexed.code, isNot(contains('images.c')));
    expect(lexed.code, contains('Assets.images.d'));
    expect(lexed.strings, isEmpty);
  });

  test('// inside a string is not a comment', () {
    final lexed = lexDart("var u = 'https://x.dev/a.png'; var y = Assets.images.e;");
    expect(lexed.strings.single.value, 'https://x.dev/a.png');
    expect(lexed.code, contains('Assets.images.e'));
  });

  test('string contents are blanked in the code view', () {
    final lexed = lexDart("var s = 'Assets.images.fake';");
    expect(lexed.code, isNot(contains('Assets')));
  });

  test('keeps offsets and reports line numbers', () {
    const src = "var a = 1;\n\n  var b = 'x';\n";
    final lexed = lexDart(src);
    expect(lexed.code.length, src.length);
    expect(lexed.strings.single.line, 3);
    expect(lexed.lineOf(src.indexOf('b')), 3);
  });

  test('an identifier ending in r before a quote is not a raw string', () {
    expect(strings(r"var s = bar + '$x';").single, interpolationMarker);
  });

  test('unterminated strings do not hang', () {
    expect(strings("var s = 'oops\nvar t = 'ok';"), ['oops', 'ok']);
  });
}
