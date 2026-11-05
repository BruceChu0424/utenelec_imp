import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'print_bounds.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../performance/ui_work_budget.dart';

const sourceTablePaperRendererKind = 'source-table-paper-v1';
final _decimalDisplayText = RegExp(r'^[+-]?\d+(?:\.\d+)?$');
const _templates = {
  'subcontractStatement',
  'supplierStatement',
  'otherReceivableStatement',
  'clientStatement',
};
const _financialTemplates = {'balanceSheet', 'monthlyProfit', 'annualProfit'};
const _financialFields = {
  'columnAlignments',
  'bodyBands',
  'textSpans',
  'keepWithNextRows',
  'protectCompleteValues',
};
const _alignments = {'LEFT', 'CENTER', 'RIGHT'};
final _rgb = RegExp(r'^[0-9a-fA-F]{6}$');

class SourcePaperBodyBand {
  const SourcePaperBodyBand(
    this.row,
    this.firstColumn,
    this.lastColumn,
    this.fill,
    this.bold,
  );
  final int row, firstColumn, lastColumn;
  final String? fill;
  final bool bold;
}

class SourcePaperTextSpan {
  const SourcePaperTextSpan(
    this.row,
    this.column,
    this.start,
    this.end,
    this.color,
  );
  final int row, column, start, end;
  final String color;
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) throw const FormatException('原表纸面资料不完整');
  return Map<String, dynamic>.from(value);
}

List<Object?> _list(Object? value) {
  if (value is! List) throw const FormatException('原表纸面列表不完整');
  return List<Object?>.from(value);
}

double _number(Object? value, double low, double high) {
  final result = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  if (result == null || !result.isFinite || result < low || result > high) {
    throw const FormatException('原表纸面尺寸无效');
  }
  return result;
}

int _integer(Object? value, int low, int high) {
  final number = _number(value, low.toDouble(), high.toDouble());
  if (number != number.truncateToDouble()) {
    throw const FormatException('原表纸面位置无效');
  }
  return number.toInt();
}

String _text(Object? value, {int maximum = 32767}) {
  if (value == null) return '';
  if (value is! String || value.length > maximum) {
    throw const FormatException('原表显示值必须保留原文本');
  }
  return value;
}

/// Geometry comes from the same server contract as XLSX. Decimal strings are
/// accepted for geometry because frozen originals preserve all JSON numbers as
/// text; business cell values are never parsed or reformatted here.
class SourceTablePaper {
  SourceTablePaper._(
    this.raw,
    this.mainColumns,
    this.canvasColumns,
    this.widths,
    this.hidden,
    this.headerRow,
    this.headerStartRow,
    this.rowHeight,
    this.rowHeights,
    this.headings,
    this.merges,
    this.minimumRows,
    this.footer,
    this.landscape,
    this.financial,
    this.columnAlignments,
    this.bodyBands,
    this.textSpans,
    this.keepWithNextRows,
  );
  factory SourceTablePaper.parse(
    Object? input, {
    required int expectedColumns,
    int? expectedBodyRows,
  }) {
    final raw = _map(input);
    final financial = _financialTemplates.contains(raw['templateKey']);
    if (!{1, 2, '1', '2'}.contains(raw['version']) ||
        !(_templates.contains(raw['templateKey']) || financial) ||
        financial && raw['version'].toString() != '1' ||
        !financial && _financialFields.any(raw.containsKey)) {
      throw const FormatException('原表纸面版本不匹配');
    }
    if (raw['version'].toString() == '2') {
      final source = _map(raw['sourcePrint']);
      if (source['version'].toString() != '2' ||
          source['sourceSha256'] !=
              '47e2a017451b2c25e3a5f75f7848eec7e1589975056baf4b08673b2fd2c44a4d' ||
          source['geometrySha256'] != raw['geometrySha256'] ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(raw['geometrySha256']?.toString() ?? '')) {
        throw const FormatException('原表打印设置与来源版本不一致');
      }
    }
    final main = _integer(raw['mainColumnCount'], 1, 160),
        canvas = _integer(raw['canvasColumns'], main, 160);
    if (main != expectedColumns) throw const FormatException('原表字段与纸面列未完整对应');
    final widths = [
      for (final value in _list(raw['widths'])) _number(value, 1, 120),
    ];
    if (widths.length != canvas) throw const FormatException('原表列宽未完整对应');
    final hidden = {
      for (final value in _list(raw['hiddenColumns']))
        _integer(value, 0, canvas - 1),
    };
    if (hidden.length != _list(raw['hiddenColumns']).length) {
      throw const FormatException('原隐藏列重复');
    }
    final rowHeight = _number(raw['rowHeight'], 10, 80),
        header = _integer(raw['headerRow'], 0, 12),
        start = _integer(raw['headerStartRow'], 0, header);
    final heights = <int, double>{};
    for (final entry in _map(raw['headingRowHeights']).entries) {
      final row = int.tryParse(entry.key);
      if (row == null || row < 0 || row > header) {
        throw const FormatException('原行高位置无效');
      }
      heights[row] = _number(entry.value, 1, 200);
    }
    final headings = [for (final item in _list(raw['headings'])) _map(item)],
        merges = [for (final item in _list(raw['merges'])) _map(item)];
    if (headings.length > 100 || merges.length > 160) {
      throw const FormatException('原表表头超过范围');
    }
    for (final heading in headings) {
      _integer(heading['row'], 0, header);
      _integer(heading['column'], 0, canvas - 1);
      _text(heading['text'], maximum: 1000);
      _number(heading['fontSize'], 8, 32);
    }
    for (final merge in merges) {
      final first = _integer(merge['firstRow'], 0, header);
      _integer(merge['lastRow'], first, header);
      final column = _integer(merge['firstColumn'], 0, canvas - 1);
      _integer(merge['lastColumn'], column, canvas - 1);
    }
    final footerMap = _map(raw['footer']),
        minimum = _integer(footerMap['minimumDataRows'], 0, 20000);
    final footer = [for (final item in _list(footerMap['cells'])) _map(item)];
    if (footer.length > 120) throw const FormatException('原表表尾超过范围');
    final occupied = <String>{};
    for (final cell in footer) {
      final row = _integer(cell['rowOffset'], 0, 64),
          span = _integer(cell['rowSpan'], 1, 8),
          column = _integer(cell['column'], 0, canvas - 1),
          last = _integer(cell['lastColumn'], column, canvas - 1);
      _number(cell['fontSize'], 8, 32);
      _text(cell['value']);
      for (int at = row; at < row + span; at++) {
        for (int col = column; col <= last; col++) {
          if (!occupied.add('$at:$col')) {
            throw const FormatException('原表尾部单元格重叠');
          }
        }
      }
    }
    final alignments = <String>[],
        bands = <SourcePaperBodyBand>[],
        spans = <SourcePaperTextSpan>[],
        keep = <int>{};
    if (financial) {
      if (minimum != 0) {
        throw const FormatException('财务原表不补造空白数据行');
      }
      if (raw['landscape'] is! bool ||
          raw.containsKey('protectCompleteValues') &&
              raw['protectCompleteValues'] != true) {
        throw const FormatException('财务原表必须完整显示全部文本');
      }
      if (raw['fontName'] is! String ||
          _text(raw['fontName'], maximum: 100).trim().isEmpty) {
        throw const FormatException('财务原表字体资料不完整');
      }
      _number(raw['fontSize'], 8, 32);
      if (raw.containsKey('columnAlignments')) {
        for (final value in _list(raw['columnAlignments'])) {
          if (value is! String || !_alignments.contains(value)) {
            throw const FormatException('财务原表列对齐方式无效');
          }
          alignments.add(value);
        }
        if (alignments.length != main) {
          throw const FormatException('财务原表列对齐未完整对应');
        }
      } else {
        alignments.addAll(List.filled(main, 'LEFT'));
      }
      for (final cell in [...headings, ...footer]) {
        if (cell.containsKey('alignment') &&
            !_alignments.contains(cell['alignment'])) {
          throw const FormatException('财务原表单元格对齐方式无效');
        }
        if (cell.containsKey('bold') && cell['bold'] is! bool) {
          throw const FormatException('财务原表字体样式无效');
        }
      }
      final merged = <(int, int), (int, int)>{};
      for (final merge in merges) {
        final firstRow = _integer(merge['firstRow'], 0, header),
            lastRow = _integer(merge['lastRow'], firstRow, header),
            firstColumn = _integer(merge['firstColumn'], 0, canvas - 1),
            lastColumn = _integer(merge['lastColumn'], firstColumn, canvas - 1);
        for (var row = firstRow; row <= lastRow; row++) {
          for (var column = firstColumn; column <= lastColumn; column++) {
            if (merged.containsKey((row, column))) {
              throw const FormatException('财务原表合并范围重叠');
            }
            merged[(row, column)] = (firstRow, firstColumn);
          }
        }
      }
      final anchors = <(int, int)>{};
      for (final heading in headings) {
        final position = (
          _integer(heading['row'], 0, header),
          _integer(heading['column'], 0, canvas - 1),
        );
        if (!anchors.add(position) ||
            merged.containsKey(position) && merged[position] != position) {
          throw const FormatException('财务原表抬头与合并位置冲突');
        }
      }
      final maximumRow =
          (expectedBodyRows ?? maximumCompleteOriginalPrintRows) - 1;
      final bandCells = <(int, int), (String?, bool)>{};
      var bandCoverage = 0;
      final rawBands = raw.containsKey('bodyBands')
          ? _list(raw['bodyBands'])
          : const <Object?>[];
      if (rawBands.length > 4096) throw const FormatException('财务原表填色超过范围');
      for (final value in rawBands) {
        final band = _map(value),
            row = _integer(band['row'], 0, maximumRow),
            first = _integer(band['firstColumn'], 0, main - 1),
            last = _integer(band['lastColumn'], first, main - 1),
            fill = band['fill'];
        if (band['bold'] is! bool ||
            fill != null && (fill is! String || !_rgb.hasMatch(fill))) {
          throw const FormatException('财务原表填色或字体样式无效');
        }
        final style = (fill as String?, band['bold'] as bool);
        bandCoverage += last - first + 1;
        if (bandCoverage > 4096) {
          throw const FormatException('财务原表填色超过范围');
        }
        for (var column = first; column <= last; column++) {
          final previous = bandCells[(row, column)];
          if (previous != null && previous != style) {
            throw const FormatException('财务原表填色或字体样式冲突');
          }
          bandCells[(row, column)] = style;
          if (bandCells.length > 4096) {
            throw const FormatException('财务原表填色超过范围');
          }
        }
        bands.add(SourcePaperBodyBand(row, first, last, style.$1, style.$2));
      }
      final rawSpans = raw.containsKey('textSpans')
          ? _list(raw['textSpans'])
          : const <Object?>[];
      if (rawSpans.length > 4096) throw const FormatException('财务原表文字样式超过范围');
      final spanCells = <(int, int), List<SourcePaperTextSpan>>{};
      for (final value in rawSpans) {
        final span = _map(value),
            row = _integer(span['row'], 0, maximumRow),
            column = _integer(span['column'], 0, main - 1),
            start = _integer(span['start'], 0, 32766),
            end = _integer(span['end'], start + 1, 32767),
            color = span['color'];
        if (color is! String || !_rgb.hasMatch(color)) {
          throw const FormatException('财务原表文字颜色无效');
        }
        final at = spanCells.putIfAbsent((row, column), () => []);
        final parsed = SourcePaperTextSpan(row, column, start, end, color);
        at.add(parsed);
        spans.add(parsed);
      }
      for (final at in spanCells.values) {
        at.sort((a, b) => a.start.compareTo(b.start));
        for (var index = 1; index < at.length; index++) {
          if (at[index].start < at[index - 1].end) {
            throw const FormatException('财务原表文字样式重叠');
          }
        }
      }
      final rawKeep = raw.containsKey('keepWithNextRows')
          ? _list(raw['keepWithNextRows'])
          : const <Object?>[];
      if (rawKeep.length > 4096) throw const FormatException('财务原表连排位置超过范围');
      for (final value in rawKeep) {
        if (!keep.add(_integer(value, 0, maximumRow))) {
          throw const FormatException('财务原表连排位置重复');
        }
      }
    }
    return SourceTablePaper._(
      Map.unmodifiable(raw),
      main,
      canvas,
      List.unmodifiable(widths),
      Set.unmodifiable(hidden),
      header,
      start,
      rowHeight,
      Map.unmodifiable(heights),
      headings,
      merges,
      minimum,
      footer,
      raw['landscape'] == true,
      financial,
      List.unmodifiable(alignments),
      List.unmodifiable(bands),
      List.unmodifiable(spans),
      Set.unmodifiable(keep),
    );
  }
  final Map<String, dynamic> raw;
  final int mainColumns, canvasColumns, headerRow, headerStartRow, minimumRows;
  final List<double> widths;
  final Set<int> hidden;
  final double rowHeight;
  final Map<int, double> rowHeights;
  final List<Map<String, dynamic>> headings, merges, footer;
  final bool landscape;
  final bool financial;
  final List<String> columnAlignments;
  final List<SourcePaperBodyBand> bodyBands;
  final List<SourcePaperTextSpan> textSpans;
  final Set<int> keepWithNextRows;
}

void _validateFinancialSpans(SourceTablePaper paper, List<List<String>> rows) {
  if (!paper.financial) return;
  bool splitPair(String text, int offset) =>
      offset > 0 &&
      offset < text.length &&
      text.codeUnitAt(offset - 1) >= 0xd800 &&
      text.codeUnitAt(offset - 1) <= 0xdbff &&
      text.codeUnitAt(offset) >= 0xdc00 &&
      text.codeUnitAt(offset) <= 0xdfff;
  for (final span in paper.textSpans) {
    if (span.row >= rows.length || span.column >= rows[span.row].length) {
      throw const FormatException('财务原表文字样式未对应原行列');
    }
    final text = rows[span.row][span.column];
    if (span.end > text.length ||
        splitPair(text, span.start) ||
        splitPair(text, span.end)) {
      throw const FormatException('财务原表文字样式未完整对应原文本');
    }
  }
}

Future<String> encodeSourceTablePaper({
  required Map<String, dynamic> layout,
  required List<String> headers,
  required List<List<String>> rows,
  String? notice,
  bool Function()? isCurrent,
}) async {
  final work = UiWorkBudget(
    isCurrent: isCurrent ?? () => true,
    debugLabel: 'print.source-paper-prepare',
  );
  work.ensureCurrent();
  final paper = SourceTablePaper.parse(
    layout,
    expectedColumns: headers.length,
    expectedBodyRows: rows.length,
  );
  if (rows.length > maximumCompleteOriginalPrintRows ||
      rows.any((row) => row.length != headers.length)) {
    throw const FormatException('原表纸面行列不完整或超过预览范围');
  }
  _validateFinancialSpans(paper, rows);
  final result = StringBuffer('{"layout":')
    ..write(jsonEncode(layout))
    ..write(',"headers":')
    ..write(jsonEncode(headers))
    ..write(',"rows":[');
  for (int index = 0; index < rows.length; index++) {
    if (index > 0) result.write(',');
    result.write(jsonEncode(rows[index]));
    if (result.length > maximumOriginalPrintPayloadCharacters) {
      throw const FormatException('原表纸面资料超过范围');
    }
    await work.checkpoint(
      rows[index].fold<int>(0, (sum, text) => sum + text.length) + 1,
    );
  }
  result.write(']');
  if (notice != null) {
    result.write(',"notice":');
    result.write(jsonEncode(notice));
  }
  result.write('}');
  work.ensureCurrent();
  return result.toString();
}

class _Cell {
  const _Cell(
    this.row,
    this.column,
    this.lastColumn,
    this.rowSpan,
    this.text,
    this.size,
    this.bold,
    this.alignment,
    this.border, {
    this.fill,
    this.spans = const [],
  });
  final int row, column, lastColumn, rowSpan;
  final String text, alignment;
  final double size;
  final bool bold, border;
  final String? fill;
  final List<SourcePaperTextSpan> spans;
}

class _TextSlice {
  const _TextSlice(this.start, this.end);
  final int start, end;
}

Future<List<_TextSlice>> _wrapFinancialText(
  String text,
  double width,
  double Function(String) measure,
  UiWorkBudget work,
) async {
  final result = <_TextSlice>[];
  var start = 0, offset = 0, count = 0;
  var used = 0.0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    if (character == '\n') {
      result.add(_TextSlice(start, offset));
      offset += character.length;
      start = offset;
      used = 0;
    } else {
      final advance = measure(character);
      if (advance > width + .001) {
        throw const FormatException('财务原表列宽不足完整显示字符');
      }
      if (offset > start && used + advance > width) {
        var end = offset;
        var carriedWidth = 0.0;
        // Keep a closing mark with its preceding character when both fit;
        // punctuation must not become a lone line in a narrow original label.
        if ('）)]}》】〉」』”’、。，：；！？'.contains(character)) {
          var previous = offset - 1;
          if (previous > start &&
              text.codeUnitAt(previous) >= 0xdc00 &&
              text.codeUnitAt(previous) <= 0xdfff &&
              text.codeUnitAt(previous - 1) >= 0xd800 &&
              text.codeUnitAt(previous - 1) <= 0xdbff) {
            previous--;
          }
          final priorWidth = measure(text.substring(previous, offset));
          if (previous > start && priorWidth + advance <= width) {
            end = previous;
            carriedWidth = priorWidth;
          }
        }
        result.add(_TextSlice(start, end));
        start = end;
        used = carriedWidth;
      }
      used += advance;
      offset += character.length;
    }
    if (++count % 128 == 0) await work.checkpoint(128);
  }
  result.add(_TextSlice(start, text.length));
  return result;
}

pw.TextAlign _textAlignment(String alignment) => alignment == 'CENTER'
    ? pw.TextAlign.center
    : alignment == 'RIGHT'
    ? pw.TextAlign.right
    : pw.TextAlign.left;

pw.RichText _financialCellText(
  _Cell cell,
  List<_TextSlice> lines,
  pw.Font font,
) {
  final children = <pw.InlineSpan>[];
  final spans = List<SourcePaperTextSpan>.of(cell.spans)
    ..sort((a, b) => a.start.compareTo(b.start));
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    var cursor = line.start;
    for (final span in spans) {
      final first = math.max(line.start, span.start),
          last = math.min(line.end, span.end);
      if (first >= last) continue;
      if (cursor < first) {
        children.add(pw.TextSpan(text: cell.text.substring(cursor, first)));
      }
      children.add(
        pw.TextSpan(
          text: cell.text.substring(first, last),
          style: pw.TextStyle(color: PdfColor.fromHex(span.color)),
        ),
      );
      cursor = last;
    }
    if (cursor < line.end) {
      children.add(pw.TextSpan(text: cell.text.substring(cursor, line.end)));
    }
    if (index + 1 < lines.length) children.add(const pw.TextSpan(text: '\n'));
  }
  return pw.RichText(
    text: pw.TextSpan(
      style: pw.TextStyle(
        font: font,
        fontSize: cell.size,
        lineSpacing: 2,
        color: PdfColors.black,
        fontWeight: cell.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
      children: children,
    ),
    softWrap: false,
    tightBounds: true,
    textAlign: _textAlignment(cell.alignment),
  );
}

List<_PageRows> _financialPages(
  SourceTablePaper paper,
  List<double> y,
  int footerStart,
  int rowCount,
  double availableHeight,
) {
  final headerCount = paper.headerRow + 1,
      bodySpace = availableHeight - y[headerCount];
  final keep = {for (final row in paper.keepWithNextRows) headerCount + row};
  final pages = <_PageRows>[];
  var first = headerCount;
  if (first == rowCount) return [_PageRows(first, first)];
  while (first < rowCount) {
    var last = first;
    var used = 0.0;
    while (last < rowCount) {
      var next = last + 1;
      while (next < rowCount && keep.contains(next - 1)) {
        next++;
      }
      // Footer merged cells stay together. Keep the last data row with its
      // full footnote rather than creating a page containing only a footnote.
      if (last >= footerStart ||
          next >= footerStart && footerStart < rowCount) {
        next = rowCount;
      }
      final height = y[next] - y[last];
      if (height > bodySpace + .001) {
        throw const FormatException('财务原表连排行高超出纸张');
      }
      if (used + height > bodySpace + .001) break;
      used += height;
      last = next;
    }
    if (last == first) throw const FormatException('财务原表行高超出纸张');
    pages.add(_PageRows(first, last));
    first = last;
  }
  return pages;
}

class _PageRows {
  const _PageRows(this.from, this.to);
  final int from, to;
}

/// Pure renderer for native isolates and the self-hosted worker. It receives
/// already-authorised text and source geometry only, never API access or state.
Future<Uint8List> renderSourceTablePaper(
  String payload,
  Uint8List? fontBytes,
) async {
  if (payload.length > maximumOriginalPrintPayloadCharacters) {
    throw const FormatException('原表纸面资料超过范围');
  }
  final input = _map(jsonDecode(payload)),
      headers = [
        for (final value in _list(input['headers']))
          _text(value, maximum: 1000),
      ];
  final paper = SourceTablePaper.parse(
    input['layout'],
    expectedColumns: headers.length,
    expectedBodyRows: _list(input['rows']).length,
  );
  if (paper.raw['version'].toString() == '2') {
    return _renderSourcePageSetup(input, paper, fontBytes);
  }
  final rows = [
    for (final row in _list(input['rows']))
      [for (final value in _list(row)) _text(value)],
  ];
  if (rows.length > maximumCompleteOriginalPrintRows ||
      rows.any((row) => row.length != paper.mainColumns)) {
    throw const FormatException('原表纸面行列不完整');
  }
  _validateFinancialSpans(paper, rows);
  // Financial headings come from the report's own company/period snapshot.
  // A client-side caption cannot add a second or differently scoped heading.
  final notice = paper.financial ? '' : _text(input['notice'], maximum: 4000),
      font = fontBytes == null
          ? pw.Font.helvetica()
          : pw.Font.ttf(ByteData.sublistView(fontBytes));
  final format = paper.landscape
      ? PdfPageFormat.a4.landscape
      : PdfPageFormat.a4;
  const margin = 28.0;
  final availableWidth = format.width - margin * 2,
      availableHeight = format.height - margin * 2 - 16;
  // Excel widths are character units. One uniform fit preserves relative source
  // positions, font sizes and row heights without changing any financial text.
  final nominal = [
    for (int col = 0; col < paper.canvasColumns; col++)
      paper.hidden.contains(col) ? 0.0 : (paper.widths[col] * 7 + 5) * .75,
  ];
  final totalWidth = nominal.fold<double>(0, (a, b) => a + b);
  if (totalWidth <= 0) throw const FormatException('原表没有可见纸面列');
  final scale = math.min(1.0, availableWidth / totalWidth), x = <double>[0];
  final textScale = paper.financial ? 1.0 : scale;
  for (final width in nominal) {
    x.add(x.last + width * scale);
  }
  final bodyCount = math.max(rows.length, paper.minimumRows),
      footerStart = paper.headerRow + 1 + bodyCount;
  int footerRows = 0;
  for (final cell in paper.footer) {
    footerRows = math.max(
      footerRows,
      _integer(cell['rowOffset'], 0, 64) + _integer(cell['rowSpan'], 1, 8),
    );
  }
  final rowCount = footerStart + footerRows;
  final cells = <_Cell>[],
      work = UiWorkBudget(debugLabel: 'print.source-paper');
  final bodyStyles = <(int, int), SourcePaperBodyBand>{};
  for (final band in paper.bodyBands) {
    for (var column = band.firstColumn; column <= band.lastColumn; column++) {
      bodyStyles[(band.row, column)] = band;
    }
  }
  final textStyles = <(int, int), List<SourcePaperTextSpan>>{};
  for (final span in paper.textSpans) {
    (textStyles[(span.row, span.column)] ??= []).add(span);
  }
  for (final heading in paper.headings) {
    final row = _integer(heading['row'], 0, paper.headerRow),
        column = _integer(heading['column'], 0, paper.canvasColumns - 1);
    int last = column, span = 1;
    for (final merge in paper.merges) {
      if (_integer(merge['firstRow'], 0, paper.headerRow) == row &&
          _integer(merge['firstColumn'], 0, paper.canvasColumns - 1) ==
              column) {
        last = _integer(merge['lastColumn'], column, paper.canvasColumns - 1);
        span = _integer(merge['lastRow'], row, paper.headerRow) - row + 1;
        break;
      }
    }
    cells.add(
      _Cell(
        row,
        column,
        last,
        span,
        _text(heading['text']),
        _number(heading['fontSize'], 8, 32),
        heading['bold'] == true,
        heading['alignment']?.toString() ?? 'LEFT',
        row >= paper.headerStartRow,
      ),
    );
  }
  for (int row = 0; row < bodyCount; row++) {
    for (int col = 0; col < paper.mainColumns; col++) {
      final text = row < rows.length ? rows[row][col] : '';
      cells.add(
        _Cell(
          paper.headerRow + 1 + row,
          col,
          col,
          1,
          text,
          paper.raw['fontSize'] == null
              ? 10
              : _number(paper.raw['fontSize'], 8, 32),
          bodyStyles[(row, col)]?.bold ?? false,
          paper.financial
              ? paper.columnAlignments[col]
              : _decimalDisplayText.hasMatch(text)
              ? 'RIGHT'
              : 'LEFT',
          true,
          fill: bodyStyles[(row, col)]?.fill,
          spans: textStyles[(row, col)] ?? const [],
        ),
      );
    }
    await work.checkpoint(paper.mainColumns);
  }
  for (final cell in paper.footer) {
    final value = cell['value'];
    final pending = cell['pending'] == true;
    final text =
        value == null &&
            pending &&
            const {'money', 'qty', 'number'}.contains(cell['type'])
        ? '待核验'
        : _text(value);
    cells.add(
      _Cell(
        footerStart + _integer(cell['rowOffset'], 0, 64),
        _integer(cell['column'], 0, paper.canvasColumns - 1),
        _integer(cell['lastColumn'], 0, paper.canvasColumns - 1),
        _integer(cell['rowSpan'], 1, 8),
        text,
        _number(cell['fontSize'], 8, 32),
        cell['bold'] == true,
        cell['alignment']?.toString() ?? 'LEFT',
        false,
      ),
    );
  }
  final doc = pw.Document();
  final rawMeasureContext = pw.Context(document: doc.document);
  final metrics = font.getFont(rawMeasureContext);
  final measureContext = paper.financial
      ? rawMeasureContext.inheritFrom(pw.ThemeData.base())
      : rawMeasureContext;
  final heights = [
    for (int row = 0; row < rowCount; row++)
      (paper.rowHeights[row] ?? paper.rowHeight) * textScale,
  ];
  final display = <_Cell, String>{},
      wrapped = <_Cell>{},
      wrapCache = <String, String>{};
  final financialLines = <_Cell, List<_TextSlice>>{},
      financialWrapCache = <(String, double, double), List<_TextSlice>>{};
  if (paper.financial) {
    for (final cell in cells) {
      if (cell.text.isEmpty) continue;
      final width = x[cell.lastColumn + 1] - x[cell.column] - 4;
      if (width <= 0) continue;
      final key = (cell.text, width, cell.size);
      var lines = financialWrapCache[key];
      if (lines == null) {
        lines = await _wrapFinancialText(
          cell.text,
          width,
          (text) => metrics.stringMetrics(text).advanceWidth * cell.size,
          work,
        );
        financialWrapCache[key] = lines;
      }
      financialLines[cell] = lines;
      // Measure the same PDF text widget that will be painted. Source heights
      // are minima; preserve the source font instead of fitting away a tail.
      final measured = _financialCellText(cell, lines, font)
        ..layout(measureContext, pw.BoxConstraints(maxWidth: width));
      final required = measured.box!.height + 2 + (cell.border ? .6 : 0);
      final existing = heights
          .sublist(cell.row, cell.row + cell.rowSpan)
          .fold<double>(0, (sum, value) => sum + value);
      if (required > existing) {
        heights[cell.row + cell.rowSpan - 1] += required - existing;
      }
      await work.checkpoint(cell.text.length + 1);
    }
  } else {
    // Source heights are minima. A long exact amount wraps at its source font
    // size instead of losing digits or becoming unreadably small. Row identities
    // and footer offsets remain unchanged in the shared contract.
    for (final cell in cells) {
      if (cell.row <= paper.headerRow ||
          !_decimalDisplayText.hasMatch(cell.text)) {
        continue;
      }
      final size = cell.size * scale,
          width = x[cell.lastColumn + 1] - x[cell.column] - 4 * scale;
      if (width <= 0 ||
          metrics.stringMetrics(cell.text).advanceWidth * size <= width) {
        continue;
      }
      final key = '${cell.text}:$width:$size';
      final text = wrapCache.putIfAbsent(key, () {
        final lines = <String>[];
        var line = '', used = 0.0;
        for (final rune in cell.text.runes) {
          final ch = String.fromCharCode(rune),
              advance = metrics.stringMetrics(ch).advanceWidth * size;
          if (line.isNotEmpty && used + advance > width) {
            lines.add(line);
            line = '';
            used = 0;
          }
          line += ch;
          used += advance;
        }
        if (line.isNotEmpty) lines.add(line);
        return lines.join('\n');
      });
      display[cell] = text;
      wrapped.add(cell);
      final required = text.split('\n').length * size * 1.35 + 4 * scale;
      final existing = heights
          .sublist(cell.row, cell.row + cell.rowSpan)
          .fold<double>(0, (sum, value) => sum + value);
      if (required > existing) {
        heights[cell.row + cell.rowSpan - 1] += required - existing;
      }
      await work.checkpoint(cell.text.length);
    }
  }
  final y = <double>[0];
  for (final height in heights) {
    y.add(y.last + height);
  }
  if (y[paper.headerRow + 1] > availableHeight ||
      y.last - y[footerStart] > availableHeight) {
    throw const FormatException('原表抬头或表尾超出一页，请核对源尺寸');
  }
  final pages = paper.financial
      ? _financialPages(paper, y, footerStart, rowCount, availableHeight)
      : <_PageRows>[];
  int first = 0;
  while (!paper.financial && first < rowCount) {
    int last = first;
    double used = 0;
    while (last < rowCount) {
      final height = y[last + 1] - y[last];
      if (last == footerStart &&
          last > first &&
          used + y.last - y[footerStart] > availableHeight) {
        break;
      }
      if (used + height > availableHeight) break;
      used += height;
      last++;
    }
    if (last == first) throw const FormatException('原表行高超出纸张');
    pages.add(_PageRows(first, last));
    first = last;
  }
  final cellsByRow = <int, List<_Cell>>{};
  for (final cell in cells) {
    (cellsByRow[cell.row] ??= <_Cell>[]).add(cell);
  }
  for (int index = 0; index < pages.length; index++) {
    final page = pages[index];
    final pieces = <pw.Widget>[];
    final sourceRows = paper.financial
        ? [
            for (var row = 0; row <= paper.headerRow; row++) row,
            for (var row = page.from; row < page.to; row++) row,
          ]
        : [for (var row = page.from; row < page.to; row++) row];
    for (final sourceRow in sourceRows) {
      for (final cell in cellsByRow[sourceRow] ?? const <_Cell>[]) {
        if (x[cell.lastColumn + 1] <= x[cell.column] ||
            ((!paper.financial || cell.row > paper.headerRow) &&
                (cell.row < page.from || cell.row >= page.to))) {
          continue;
        }
        final height = y[cell.row + cell.rowSpan] - y[cell.row],
            width = x[cell.lastColumn + 1] - x[cell.column];
        final alignment = cell.alignment == 'CENTER'
            ? pw.Alignment.center
            : cell.alignment == 'RIGHT'
            ? pw.Alignment.centerRight
            : pw.Alignment.centerLeft;
        pieces.add(
          pw.Positioned(
            left: x[cell.column],
            top: paper.financial && cell.row <= paper.headerRow
                ? y[cell.row]
                : y[cell.row] -
                      y[page.from] +
                      (paper.financial ? y[paper.headerRow + 1] : 0),
            child: pw.Container(
              width: width,
              height: height,
              alignment: alignment,
              padding: pw.EdgeInsets.symmetric(
                horizontal: 2 * textScale,
                vertical: 1 * textScale,
              ),
              decoration: paper.financial
                  ? pw.BoxDecoration(
                      color: cell.fill == null
                          ? null
                          : PdfColor.fromHex(cell.fill!),
                      border: cell.border ? pw.Border.all(width: .4) : null,
                    )
                  : cell.border
                  ? pw.BoxDecoration(border: pw.Border.all(width: .4 * scale))
                  : null,
              child: cell.text.trim().isEmpty
                  ? pw.SizedBox()
                  : paper.financial
                  ? _financialCellText(
                      cell,
                      financialLines[cell] ?? [_TextSlice(0, cell.text.length)],
                      font,
                    )
                  : wrapped.contains(cell)
                  ? pw.Text(
                      display[cell]!,
                      softWrap: false,
                      style: pw.TextStyle(
                        font: font,
                        color: PdfColors.black,
                        fontSize: cell.size * scale,
                        fontWeight: cell.bold
                            ? pw.FontWeight.bold
                            : pw.FontWeight.normal,
                      ),
                      textAlign: pw.TextAlign.right,
                    )
                  : pw.FittedBox(
                      fit: pw.BoxFit.scaleDown,
                      alignment: alignment,
                      child: pw.Text(
                        cell.text,
                        softWrap: false,
                        style: pw.TextStyle(
                          font: font,
                          color: PdfColors.black,
                          fontSize: cell.size * scale,
                          fontWeight: cell.bold
                              ? pw.FontWeight.bold
                              : pw.FontWeight.normal,
                        ),
                        textAlign: cell.alignment == 'CENTER'
                            ? pw.TextAlign.center
                            : cell.alignment == 'RIGHT'
                            ? pw.TextAlign.right
                            : pw.TextAlign.left,
                      ),
                    ),
            ),
          ),
        );
      }
    }
    pieces.add(
      pw.Positioned(
        left: 0,
        bottom: 0,
        child: pw.SizedBox(
          width: availableWidth,
          child: pw.Text(
            '${index + 1}/${pages.length}${notice.isEmpty ? '' : '  $notice'}',
            style: pw.TextStyle(font: font, fontSize: 7),
            textAlign: pw.TextAlign.right,
          ),
        ),
      ),
    );
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(margin),
        build: (_) => pw.SizedBox(
          width: availableWidth,
          height: availableHeight + 16,
          child: pw.Stack(children: pieces),
        ),
      ),
    );
    await work.checkpoint(256);
  }
  return doc.save();
}

class _ColumnBand {
  const _ColumnBand(this.from, this.to);
  final int from, to;
}

/// Version 2 preserves the source physical page setup. The version 1 path above
/// remains the interpreter for already frozen version 1 originals.
Future<Uint8List> _renderSourcePageSetup(
  Map<String, dynamic> input,
  SourceTablePaper paper,
  Uint8List? fontBytes,
) async {
  final rows = [
    for (final row in _list(input['rows']))
      [for (final value in _list(row)) _text(value)],
  ];
  if (rows.length > maximumCompleteOriginalPrintRows ||
      rows.any((row) => row.length != paper.mainColumns)) {
    throw const FormatException('原表纸面行列不完整');
  }
  final setup = _map(paper.raw['sourcePrint']),
      margins = _map(setup['marginsPoints']),
      widths = _list(setup['columnWidthsPoints']);
  if (setup['fitToPage'] != false ||
      _number(setup['scalePercent'], 10, 400) != 100 ||
      setup['orientation'] != 'portrait' ||
      paper.landscape ||
      setup['effectivePaperSize'] != 'A4' ||
      setup['pageOrder'] != 'downThenOver' ||
      _list(setup['repeatRows']).isNotEmpty ||
      _list(setup['repeatColumns']).isNotEmpty ||
      widths.length < paper.canvasColumns) {
    throw const FormatException('原表打印设置尚未受支持，不能暗用整页缩放');
  }
  final left = _number(margins['left'], 0, 144),
      right = _number(margins['right'], 0, 144),
      top = _number(margins['top'], 0, 144),
      bottom = _number(margins['bottom'], 0, 144),
      footerMargin = _number(margins['footer'], 0, 144),
      format = PdfPageFormat.a4,
      pageWidth = format.width - left - right,
      pageHeight = format.height - top - bottom;
  if (pageWidth <= 0 || pageHeight <= 0 || footerMargin > bottom) {
    throw const FormatException('原表页边距无效');
  }
  final x = <double>[0];
  final sourceCharacters = _list(setup['columnWidthCharacters']);
  if (sourceCharacters.length < paper.canvasColumns) {
    throw const FormatException('原列宽缺少同源物理尺寸依据');
  }
  for (int column = 0; column < paper.canvasColumns; column++) {
    if ((_number(sourceCharacters[column], 1, 120) - paper.widths[column])
            .abs() >
        .0001) {
      throw const FormatException('原列宽与同源物理尺寸不一致');
    }
    x.add(
      x.last +
          (paper.hidden.contains(column)
              ? 0
              : _number(widths[column], 1, 1200)),
    );
  }
  final bands = <_ColumnBand>[];
  int firstColumn = 0;
  while (firstColumn < paper.canvasColumns) {
    int end = firstColumn;
    while (end < paper.canvasColumns &&
        x[end + 1] - x[firstColumn] <= pageWidth + .01) {
      end++;
    }
    if (end == firstColumn) {
      throw const FormatException('原表单列超过纸张宽度，不能缩字或截断');
    }
    if (x[end] > x[firstColumn]) bands.add(_ColumnBand(firstColumn, end));
    firstColumn = end;
  }
  final bodyCount = math.max(rows.length, paper.minimumRows),
      footerStart = paper.headerRow + 1 + bodyCount;
  int footerRows = 0;
  for (final cell in paper.footer) {
    footerRows = math.max(
      footerRows,
      _integer(cell['rowOffset'], 0, 64) + _integer(cell['rowSpan'], 1, 8),
    );
  }
  final rowCount = footerStart + footerRows,
      cells = <_Cell>[],
      flags = <_Cell, Map<String, dynamic>>{},
      work = UiWorkBudget(debugLabel: 'print.source-paper-physical');
  for (final heading in paper.headings) {
    final row = _integer(heading['row'], 0, paper.headerRow),
        column = _integer(heading['column'], 0, paper.canvasColumns - 1);
    int last = column, span = 1;
    for (final merge in paper.merges) {
      if (_integer(merge['firstRow'], 0, paper.headerRow) == row &&
          _integer(merge['firstColumn'], 0, paper.canvasColumns - 1) ==
              column) {
        last = _integer(merge['lastColumn'], column, paper.canvasColumns - 1);
        span = _integer(merge['lastRow'], row, paper.headerRow) - row + 1;
        break;
      }
    }
    final cell = _Cell(
      row,
      column,
      last,
      span,
      _text(heading['text']),
      _number(heading['fontSize'], 8, 32),
      heading['bold'] == true,
      heading['alignment']?.toString() ?? 'LEFT',
      row >= paper.headerStartRow,
    );
    cells.add(cell);
    flags[cell] = heading;
  }
  final bodyStyles = _list(setup['bodyStyles']);
  if (bodyStyles.length != paper.mainColumns) {
    throw const FormatException('原表正文样式与原列未对应');
  }
  for (int row = 0; row < bodyCount; row++) {
    for (int column = 0; column < paper.mainColumns; column++) {
      final text = row < rows.length ? rows[row][column] : '',
          style = _map(bodyStyles[column]),
          alignment = style['alignment']?.toString();
      final cell = _Cell(
        paper.headerRow + 1 + row,
        column,
        column,
        1,
        text,
        _number(style['fontSize'], 8, 32),
        style['bold'] == true,
        {'LEFT', 'CENTER', 'RIGHT'}.contains(alignment)
            ? alignment!
            : _decimalDisplayText.hasMatch(text)
            ? 'RIGHT'
            : 'LEFT',
        true,
      );
      cells.add(cell);
      flags[cell] = style;
    }
    await work.checkpoint(paper.mainColumns);
  }
  for (final footer in paper.footer) {
    final value = footer['value'];
    final text =
        value == null &&
            footer['pending'] == true &&
            {'money', 'qty', 'number'}.contains(footer['type'])
        ? '待核验'
        : _text(value);
    final cell = _Cell(
      footerStart + _integer(footer['rowOffset'], 0, 64),
      _integer(footer['column'], 0, paper.canvasColumns - 1),
      _integer(footer['lastColumn'], 0, paper.canvasColumns - 1),
      _integer(footer['rowSpan'], 1, 8),
      text,
      _number(footer['fontSize'], 8, 32),
      footer['bold'] == true,
      footer['alignment']?.toString() ?? 'LEFT',
      false,
    );
    cells.add(cell);
    flags[cell] = footer;
  }
  final doc = pw.Document(),
      font = fontBytes == null
          ? pw.Font.helvetica()
          : pw.Font.ttf(ByteData.sublistView(fontBytes)),
      metrics = font.getFont(pw.Context(document: doc.document)),
      heights = [
        for (int row = 0; row < rowCount; row++)
          paper.rowHeights[row] ?? paper.rowHeight,
      ],
      display = <_Cell, String>{},
      cache = <String, String>{};
  for (final cell in cells) {
    final width = x[cell.lastColumn + 1] - x[cell.column] - 4;
    if (width <= 0 || cell.text.isEmpty) continue;
    // Complete body facts retain their source font/width and grow vertically.
    // Source nowrap remains recorded; it cannot authorise losing a value tail.
    final bodyValue = cell.row > paper.headerRow && cell.row < footerStart;
    final wrap =
        bodyValue ||
        flags[cell]?['wrapText'] == true ||
        _decimalDisplayText.hasMatch(cell.text);
    if (!wrap || flags[cell]?['shrinkToFit'] == true) continue;
    final key = '${cell.text}:$width:${cell.size}';
    final text = cache.putIfAbsent(key, () {
      final lines = <String>[];
      for (final sourceLine in cell.text.split('\n')) {
        var line = '', used = 0.0;
        for (final rune in sourceLine.runes) {
          final ch = String.fromCharCode(rune),
              advance = metrics.stringMetrics(ch).advanceWidth * cell.size;
          if (advance > width + .01) {
            throw const FormatException('原表单字超出源列，不能缩字或剪裁');
          }
          if (line.isNotEmpty && used + advance > width) {
            lines.add(line);
            line = '';
            used = 0;
          }
          line += ch;
          used += advance;
        }
        lines.add(line);
      }
      return lines.join('\n');
    });
    display[cell] = text;
    final lineCount = text.split('\n').length;
    final required = (lineCount == 1
            ? cell.size + 2
            : lineCount * cell.size * 1.35 + 4),
        existing = heights
            .sublist(cell.row, cell.row + cell.rowSpan)
            .fold<double>(0, (sum, height) => sum + height);
    if (required > pageHeight) {
      throw const FormatException('原表单格超出一页，请核对原尺寸');
    }
    if (required > existing) {
      heights[cell.row + cell.rowSpan - 1] += required - existing;
    }
    await work.checkpoint(cell.text.length + 1);
  }
  final y = <double>[0];
  for (final height in heights) {
    y.add(y.last + height);
  }
  final pages = <_PageRows>[];
  final financialMerges = [
    for (final cell in cells)
      if (cell.rowSpan > 1 &&
          ({'money', 'qty', 'number'}.contains(flags[cell]?['type']) ||
              _decimalDisplayText.hasMatch(cell.text)))
        cell,
  ];
  int first = 0;
  while (first < rowCount) {
    int end = first;
    while (end < rowCount && y[end + 1] - y[first] <= pageHeight + .01) {
      end++;
    }
    bool moved;
    do {
      moved = false;
      for (final cell in financialMerges) {
        if (cell.row >= first &&
            cell.row < end &&
            cell.row + cell.rowSpan > end) {
          end = cell.row;
          moved = true;
          break;
        }
      }
    } while (moved);
    if (end == first) throw const FormatException('原表行高超出纸张');
    pages.add(_PageRows(first, end));
    first = end;
  }
  final totalPages = pages.length * bands.length,
      notice = _text(input['notice'], maximum: 4000);
  final cellsByRow = <int, List<_Cell>>{};
  for (final cell in cells) {
    (cellsByRow[cell.row] ??= <_Cell>[]).add(cell);
  }
  int pageNumber = 0;
  for (final band in bands) {
    for (final page in pages) {
      final pieces = <pw.Widget>[];
      for (
        int sourceRow = math.max(0, page.from - 12);
        sourceRow < page.to;
        sourceRow++
      ) {
        for (final cell in cellsByRow[sourceRow] ?? const <_Cell>[]) {
          if (cell.row >= page.to ||
              cell.row + cell.rowSpan <= page.from ||
              cell.column >= band.to ||
              cell.lastColumn < band.from ||
              x[cell.lastColumn + 1] <= x[cell.column]) {
            continue;
          }
          final alignment = cell.alignment == 'CENTER'
              ? pw.Alignment.center
              : cell.alignment == 'RIGHT'
              ? pw.Alignment.centerRight
              : pw.Alignment.centerLeft;
          pw.Widget text = pw.Text(
            display[cell] ?? cell.text,
            softWrap: false,
            textAlign: cell.alignment == 'CENTER'
                ? pw.TextAlign.center
                : cell.alignment == 'RIGHT'
                ? pw.TextAlign.right
                : pw.TextAlign.left,
            style: pw.TextStyle(
              font: font,
              fontSize: cell.size,
              color: PdfColors.black,
              fontWeight: cell.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          );
          if (flags[cell]?['shrinkToFit'] == true) {
            text = pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: alignment,
              child: text,
            );
          }
          pieces.add(
            pw.Positioned(
              left: x[cell.column] - x[band.from],
              top: y[cell.row] - y[page.from],
              child: pw.Container(
                width: x[cell.lastColumn + 1] - x[cell.column],
                height: y[cell.row + cell.rowSpan] - y[cell.row],
                alignment: alignment,
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 1,
                ),
                decoration: cell.border
                    ? pw.BoxDecoration(border: pw.Border.all(width: .4))
                    : null,
                child: cell.text.trim().isEmpty ? pw.SizedBox() : text,
              ),
            ),
          );
        }
      }
      pageNumber++;
      final currentPageNumber = pageNumber;
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.fromLTRB(left, top, right, footerMargin),
          build: (_) => pw.SizedBox(
            width: pageWidth,
            height: format.height - top - footerMargin,
            child: pw.Stack(
              children: [
                pw.Positioned(
                  left: 0,
                  top: 0,
                  child: pw.SizedBox(
                    width: x[band.to] - x[band.from],
                    height: pageHeight,
                    child: pw.ClipRect(child: pw.Stack(children: pieces)),
                  ),
                ),
                pw.Positioned(
                  left: 0,
                  bottom: 0,
                  child: pw.SizedBox(
                    width: pageWidth,
                    child: pw.Text(
                      '$currentPageNumber/$totalPages${notice.isEmpty ? '' : '  $notice'}',
                      style: pw.TextStyle(font: font, fontSize: 7),
                      textAlign: pw.TextAlign.right,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await work.checkpoint(pieces.length + 256);
    }
  }
  return doc.save();
}
