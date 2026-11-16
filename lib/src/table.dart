/// Formats a byte count: `512 B`, `12.3 KB`, `4.56 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2)} ${units[unit]}';
}

/// Percentage saved going from [before] to [after]; negative if it grew.
double percentSaved(int before, int after) => before == 0 ? 0 : (before - after) * 100 / before;

/// Renders a plain-text table. [rightAligned] lists column indexes to
/// right-align. [colorize] may wrap a cell (after padding) for display.
String renderTable(
  List<String> headers,
  List<List<String>> rows, {
  Set<int> rightAligned = const {},
  List<String>? footer,
  String Function(int row, int column, String padded)? colorize,
}) {
  final all = [headers, ...rows, ?footer];
  final widths = [
    for (var c = 0; c < headers.length; c++)
      all.map((r) => r[c].length).reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells, int rowIndex) => [
    for (var c = 0; c < cells.length; c++)
      () {
        final padded = rightAligned.contains(c)
            ? cells[c].padLeft(widths[c])
            : cells[c].padRight(widths[c]);
        return colorize == null ? padded : colorize(rowIndex, c, padded);
      }(),
  ].join('  ').trimRight();
  final rule = widths.map((w) => '─' * w).join('  ');
  return [
    line(headers, -1),
    rule,
    for (var i = 0; i < rows.length; i++) line(rows[i], i),
    if (footer != null) ...[rule, line(footer, rows.length)],
  ].join('\n');
}
