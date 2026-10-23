// CSV / 分隔符文本解析：把一屏逗号渲染成对齐表格，而不是一堵墙。
//
// 只做预览需要的最小正确性：RFC 4180 的引号规则（成对引号转义、引号内可含分隔符与
// 换行）、CRLF/LF/CR 三种换行、逗号/分号/制表符三种分隔符自动嗅探（中文 Windows 的
// Excel 在部分区域设置下导出的是分号）。不做类型推断、不做公式求值——预览就是看原文。

import '../../core/performance/ui_work_budget.dart';

/// 解析结果。`truncated` 为真表示行数超限、只保留了前 [rows] 行。
class DelimitedTable {
  const DelimitedTable({
    required this.rows,
    required this.delimiter,
    required this.totalRows,
    required this.truncated,
  });

  /// 已解析的行（含表头行，即第一行）。
  final List<List<String>> rows;

  /// 实际采用的分隔符。
  final String delimiter;

  /// 文件里的总行数（可能大于 `rows.length`）。
  final int totalRows;

  final bool truncated;

  /// 最宽一行的列数；表格按它补齐空单元格。
  int get columnCount =>
      rows.fold(0, (widest, row) => row.length > widest ? row.length : widest);
}

/// 预览最多解析的行数：再多也看不过来，且要守住内存。
const int kDelimitedPreviewMaxRows = 1000;

/// 候选分隔符，按常见度排序。
const List<String> _candidates = [',', ';', '\t'];

/// 解析分隔符文本。[delimiter] 为空时自动嗅探。
DelimitedTable parseDelimitedText(
  String text, {
  String? delimiter,
  int maxRows = kDelimitedPreviewMaxRows,
}) {
  final separator = delimiter ?? sniffDelimiter(text);
  final parser = _DelimitedParser(text, separator, maxRows);
  while (!parser.done) {
    parser.advance(16384);
  }
  return parser.finish();
}

/// Shares the parser state machine with the synchronous/native path; quotes,
/// escaped quotes and CRLF may cross any slice boundary without changing rows.
Future<DelimitedTable> parseDelimitedTextInUiSlices(
  String text, {
  String? delimiter,
  int maxRows = kDelimitedPreviewMaxRows,
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget();
  work.ensureCurrent();
  var separator = delimiter;
  if (separator == null) {
    final sniffer = _DelimiterSniffer(text, 20);
    while (!sniffer.done) {
      sniffer.advance(16384);
      await work.checkpoint(16384);
    }
    separator = sniffer.result;
  }
  final parser = _DelimitedParser(text, separator, maxRows);
  while (!parser.done) {
    parser.advance(16384);
    await work.checkpoint(16384);
  }
  work.ensureCurrent();
  return parser.finish();
}

class _DelimitedParser {
  _DelimitedParser(this.text, this.separator, this.maxRows);
  final String text;
  final String separator;
  final int maxRows;
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  bool cellHasContent = false;
  bool rowHasCells = false;
  var quoted = false;
  var total = 0;
  var index = 0;
  bool get done => index >= text.length;

  void endCell() {
    if (rows.length < maxRows) row.add(cell.toString());
    rowHasCells = true;
    cell.clear();
    cellHasContent = false;
  }

  void endRow() {
    endCell();
    total++;
    if (rows.length < maxRows) rows.add(row);
    row = <String>[];
    rowHasCells = false;
  }

  void write(String char) {
    // Past the visible limit we only count records; do not allocate the
    // discarded cell contents. Quote/empty-tail decisions still use the flag.
    if (rows.length < maxRows) cell.write(char);
    cellHasContent = true;
  }

  void advance(int characters) {
    final end = index + characters;
    while (index < text.length && index < end) {
      final char = text[index];
      if (quoted) {
        if (char == '"') {
          if (index + 1 < text.length && text[index + 1] == '"') {
            write('"');
            index += 2;
            continue;
          }
          quoted = false;
          index++;
          continue;
        }
        write(char);
        index++;
        continue;
      }
      if (char == '"' && !cellHasContent) {
        quoted = true;
        index++;
        continue;
      }
      if (char == separator) {
        endCell();
        index++;
        continue;
      }
      if (char == '\n' || char == '\r') {
        endRow();
        // CRLF 只算一次换行。
        if (char == '\r' &&
            index + 1 < text.length &&
            text[index + 1] == '\n') {
          index++;
        }
        index++;
        continue;
      }
      write(char);
      index++;
    }
  }

  DelimitedTable finish() {
    // 最后一行没有换行符结尾时补上；纯空尾行不算一行。
    if (cellHasContent || rowHasCells) {
      endRow();
    }

    return DelimitedTable(
      rows: rows,
      delimiter: separator,
      totalRows: total,
      truncated: total > rows.length,
    );
  }
}

/// 分隔符嗅探：取前若干行，数引号外的候选字符，谁多用谁；都没有则用逗号。
String sniffDelimiter(String text, {int sampleLines = 20}) {
  final sniffer = _DelimiterSniffer(text, sampleLines);
  while (!sniffer.done) {
    sniffer.advance(16384);
  }
  return sniffer.result;
}

class _DelimiterSniffer {
  _DelimiterSniffer(this.text, this.sampleLines);
  final String text;
  final int sampleLines;
  final counts = <String, int>{
    for (final candidate in _candidates) candidate: 0,
  };
  var quoted = false;
  var lines = 0;
  var index = 0;
  bool get done => index >= text.length || lines >= sampleLines;

  void advance(int characters) {
    final end = index + characters;
    for (; index < text.length && lines < sampleLines && index < end; index++) {
      final char = text[index];
      if (char == '"') {
        quoted = !quoted;
        continue;
      }
      if (quoted) continue;
      if (char == '\n') {
        lines++;
        continue;
      }
      if (counts.containsKey(char)) counts[char] = counts[char]! + 1;
    }
  }

  String get result {
    var best = ',';
    var bestCount = 0;
    for (final candidate in _candidates) {
      final count = counts[candidate]!;
      if (count > bestCount) {
        best = candidate;
        bestCount = count;
      }
    }
    return best;
  }
}
