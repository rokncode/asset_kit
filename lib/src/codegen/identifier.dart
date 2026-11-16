/// Conversion of file and folder names into valid Dart identifiers.
library;

/// Dart reserved words, which can never be identifiers.
const _reservedWords = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default',
  'do', 'else', 'enum', 'extends', 'false', 'final', 'finally', 'for', 'if',
  'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch', 'this',
  'throw', 'true', 'try', 'var', 'void', 'while', 'with',
  // Not reserved, but unusable as identifiers in some contexts.
  'await', 'yield',
};

/// Members inherited from `Object` that a generated field must not shadow.
const _objectMembers = {'hashCode', 'runtimeType', 'toString', 'noSuchMethod'};

/// Splits on separators and on camelCase / digit boundaries:
/// `HTTPLogo` → [HTTP, Logo], `step_1` → [step, 1], `iconV2` → [icon, V, 2].
/// Lowercase letters directly after digits stay attached: `1st`, `2x`.
final _words = RegExp(r'[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+[a-z]*');

List<String> _splitWords(String input) => _words.allMatches(input).map((m) => m.group(0)!).toList();

String _capitalize(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1).toLowerCase();

/// Converts [name] to a lowerCamelCase Dart identifier.
///
/// - Separators (`-`, `_`, spaces, dots) are dropped: `my-logo.dark` → `myLogoDark`.
/// - A leading digit gets an `asset` prefix: `1st_place` → `asset1stPlace`.
/// - Reserved words and `Object` members get an `Asset` suffix:
///   `default` → `defaultAsset`.
/// - Names with no ASCII letters or digits (e.g. Arabic `شعار`) fall back to
///   [fallback]; collisions are resolved by the caller.
String toLowerCamelCase(String name, {String fallback = 'asset'}) {
  final words = _splitWords(name);
  if (words.isEmpty) return fallback;
  final buffer = StringBuffer(words.first.toLowerCase());
  for (final word in words.skip(1)) {
    buffer.write(_capitalize(word));
  }
  var id = buffer.toString();
  if (RegExp(r'^\d').hasMatch(id)) id = 'asset$id';
  if (_reservedWords.contains(id) || _objectMembers.contains(id)) id = '${id}Asset';
  return id;
}

/// Converts [name] to an UpperCamelCase identifier fragment: `on-boarding` →
/// `OnBoarding`. Used to build private class names.
String toUpperCamelCase(String name, {String fallback = 'Asset'}) {
  final words = _splitWords(name);
  if (words.isEmpty) return fallback;
  return words.map(_capitalize).join();
}

/// Whether [name] converts to an identifier without losing information:
/// it must be plain ASCII and contain at least one letter or digit.
///
/// `step-2`, `My Logo` and `1st_place` are fine; `شعار`, `logo_شعار` and
/// `café` are not, because the non-ASCII part would be silently dropped.
bool isCleanlyConvertible(String name) =>
    !name.codeUnits.any((c) => c > 0x7F) && !hasNoIdentifierChars(name);

/// Whether [name] can be used as-is as a generated member name: a
/// lowerCamelCase identifier that is not reserved.
bool isValidMemberName(String name) =>
    RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(name) &&
    !_reservedWords.contains(name) &&
    !_objectMembers.contains(name);

/// Whether [name] yields no usable identifier characters (e.g. an all-Arabic
/// file name), so [toLowerCamelCase] would return its fallback.
bool hasNoIdentifierChars(String name) => _splitWords(name).isEmpty;

/// Returns a variant of [candidate] that is not in [taken] by appending
/// 2, 3, … and records the result in [taken].
String uniqueIdentifier(String candidate, Set<String> taken) {
  var id = candidate;
  for (var i = 2; taken.contains(id); i++) {
    id = '$candidate$i';
  }
  taken.add(id);
  return id;
}
