/// A minimal Dart lexer for reference scanning.
///
/// It understands just enough of Dart to separate code, comments and string
/// literals: single, double, triple-quoted and raw strings, escapes,
/// `$name` and `${expr}` interpolation (including strings nested inside
/// interpolations), and nested block comments.
library;

/// Marks an interpolation inside [StringLiteral.value].
const interpolationMarker = '\u0000';

/// A string literal found in Dart source.
class StringLiteral {
  StringLiteral(this.value, this.offset, this.line);

  /// Contents with escapes resolved and each interpolation replaced by
  /// [interpolationMarker].
  final String value;

  /// Offset of the opening quote.
  final int offset;

  /// 1-based line number.
  final int line;

  bool get hasInterpolation => value.contains(interpolationMarker);

  /// The literal parts between interpolations.
  List<String> get parts => value.split(interpolationMarker);

  @override
  String toString() => "'${value.replaceAll(interpolationMarker, r'${…}')}'";
}

class LexedDart {
  LexedDart(this.code, this.strings, this._lineStarts);

  /// The source with comments and string contents replaced by spaces
  /// (newlines kept, so offsets and line numbers still match). Code inside
  /// `${...}` interpolations is kept.
  final String code;
  final List<StringLiteral> strings;
  final List<int> _lineStarts;

  /// 1-based line number of [offset].
  int lineOf(int offset) {
    var lo = 0, hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }
}

LexedDart lexDart(String source) => _Lexer(source).run();

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F; // A-Z a-z _

bool _isIdentPart(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x24; // 0-9 $

class _Lexer {
  _Lexer(this.src) : out = src.codeUnits.toList();

  final String src;
  final List<int> out;
  final strings = <StringLiteral>[];
  late final List<int> lineStarts = [
    0,
    for (var i = 0; i < src.length; i++)
      if (src.codeUnitAt(i) == 0x0A) i + 1,
  ];
  late final _tmp = LexedDart('', const [], lineStarts);

  LexedDart run() {
    var i = 0;
    while (i < src.length) {
      i = _step(i, stopAtBrace: false).$1;
    }
    strings.sort((a, b) => a.offset.compareTo(b.offset));
    return LexedDart(String.fromCharCodes(out), strings, lineStarts);
  }

  void _blank(int from, int to) {
    for (var k = from; k < to && k < out.length; k++) {
      if (out[k] != 0x0A) out[k] = 0x20;
    }
  }

  /// Consumes one token at [i]. Returns the next index and, when
  /// [stopAtBrace] is set, whether an unmatched `}` was reached.
  (int, bool) _step(int i, {required bool stopAtBrace}) {
    final c = src.codeUnitAt(i);
    if (c == 0x2F && i + 1 < src.length) {
      final next = src.codeUnitAt(i + 1);
      if (next == 0x2F) {
        final end = src.indexOf('\n', i);
        final stop = end == -1 ? src.length : end;
        _blank(i, stop);
        return (stop, false);
      }
      if (next == 0x2A) return (_blockComment(i), false);
    }
    if (c == 0x27 || c == 0x22) return (_string(i, raw: false), false);
    if ((c == 0x72 || c == 0x52) &&
        i + 1 < src.length &&
        (src.codeUnitAt(i + 1) == 0x27 || src.codeUnitAt(i + 1) == 0x22) &&
        (i == 0 || !_isIdentPart(src.codeUnitAt(i - 1)))) {
      return (_string(i + 1, raw: true), false);
    }
    if (stopAtBrace && c == 0x7D) return (i, true);
    return (i + 1, false);
  }

  int _blockComment(int start) {
    var depth = 0;
    var i = start;
    while (i < src.length) {
      if (src.startsWith('/*', i)) {
        depth++;
        i += 2;
      } else if (src.startsWith('*/', i)) {
        depth--;
        i += 2;
        if (depth == 0) break;
      } else {
        i++;
      }
    }
    _blank(start, i);
    return i;
  }

  /// Lexes the string whose opening quote is at [q]. Returns the index
  /// after the closing quote.
  int _string(int q, {required bool raw}) {
    final quoteChar = src[q];
    final triple = src.startsWith(quoteChar * 3, q);
    final quote = triple ? quoteChar * 3 : quoteChar;
    final start = raw ? q - 1 : q;
    final value = StringBuffer();
    final keep = <(int, int)>[]; // interpolation code ranges, not blanked
    var i = q + quote.length;

    while (i < src.length) {
      if (src.startsWith(quote, i)) {
        i += quote.length;
        break;
      }
      final c = src.codeUnitAt(i);
      if (!triple && c == 0x0A) break; // unterminated
      if (!raw && c == 0x5C && i + 1 < src.length) {
        value.write(_escape(src[i + 1]));
        i += 2;
        continue;
      }
      if (!raw && c == 0x24 && i + 1 < src.length) {
        final next = src.codeUnitAt(i + 1);
        if (next == 0x7B) {
          final exprStart = i + 2;
          var j = exprStart;
          var depth = 0;
          while (j < src.length) {
            final ch = src.codeUnitAt(j);
            if (ch == 0x7B) {
              depth++;
              j++;
              continue;
            }
            if (ch == 0x7D && depth > 0) {
              depth--;
              j++;
              continue;
            }
            final (nextJ, closed) = _step(j, stopAtBrace: true);
            if (closed) break;
            j = nextJ;
          }
          keep.add((exprStart, j));
          value.write(interpolationMarker);
          i = j + 1;
          continue;
        }
        if (_isIdentStart(next)) {
          var j = i + 1;
          while (j < src.length && _isIdentPart(src.codeUnitAt(j)) && src.codeUnitAt(j) != 0x24) {
            j++;
          }
          value.write(interpolationMarker);
          i = j;
          continue;
        }
      }
      value.writeCharCode(c);
      i++;
    }

    var from = start;
    for (final (a, b) in keep) {
      _blank(from, a);
      from = b;
    }
    _blank(from, i);
    strings.add(StringLiteral(value.toString(), start, _tmp.lineOf(start)));
    return i;
  }

  String _escape(String c) => switch (c) {
    'n' => '\n',
    't' => '\t',
    'r' => '\r',
    _ => c,
  };
}
