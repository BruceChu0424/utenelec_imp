import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';
import 'finance_source_table.dart';

/// Explicit private inspection of the original hidden calculation canvas.
/// This table is never joined to the main paper/export column projection.
class FinanceStatementSupplementalCells extends StatefulWidget {
  const FinanceStatementSupplementalCells({super.key, required this.metadata});
  final Map<String, dynamic> metadata;
  @override
  State<FinanceStatementSupplementalCells> createState() =>
      _SupplementalState();
}

class _SupplementalState extends State<FinanceStatementSupplementalCells> {
  bool _expanded = false;
  @override
  void didUpdateWidget(covariant FinanceStatementSupplementalCells oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata['sourceFingerprint'] !=
            widget.metadata['sourceFingerprint'] ||
        oldWidget.metadata['reviewId'] != widget.metadata['reviewId'] ||
        oldWidget.metadata['materialContextId'] !=
            widget.metadata['materialContextId']) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final metadata = widget.metadata,
        raw = widget.metadata['supplementalCells'];
    if (raw is! List ||
        raw.isEmpty ||
        metadata['hiddenColumns'] is! List ||
        (metadata['hiddenColumns'] as List).isEmpty) {
      return const SizedBox.shrink();
    }
    final canvas = metadata['canvasColumns'];
    final widths = metadata['supplementalWidths'];
    final start = canvas is int && widths is List ? canvas - widths.length : -1;
    if (canvas is! int ||
        start < 0 ||
        canvas > 160 ||
        start >= canvas ||
        raw.length > 2000) {
      return const Text('隐藏区资料尚未完整读取，请重新读取原表后核对');
    }
    final cells = <(int, int), Map<dynamic, dynamic>>{};
    var first = 10000, last = 0;
    for (final item in raw) {
      if (item is! Map) return const Text('隐藏区资料尚未完整读取，请重新读取原表后核对');
      final match = RegExp(
        r'^([A-Z]{1,2})([1-9][0-9]{0,3})$',
      ).firstMatch(item['sourceCell']?.toString() ?? '');
      if (match == null) return const Text('隐藏区资料尚未完整读取，请重新读取原表后核对');
      var col = 0;
      for (final code in match[1]!.codeUnits) {
        col = col * 26 + code - 64;
      }
      col--;
      final row = int.parse(match[2]!);
      if (col < start || col >= canvas || cells.containsKey((row, col))) {
        return const Text('隐藏区原坐标存在冲突，请重新读取原表后核对');
      }
      cells[(row, col)] = item;
      if (row < first) first = row;
      if (row > last) last = row;
    }
    if (last - first > 1000) return const Text('隐藏区资料超出本次核对范围，请缩小原表期间');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: UtenButton(
            key: const ValueKey('statement-supplemental-toggle'),
            type: UtenButtonType.tonal,
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '收起原表隐藏计算区' : '展开原表隐藏计算区'),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: UtenSpacing.s8),
          const Text('仅在此处展开核对，打印保持原表隐藏设置。'),
          SizedBox(
            height: 190,
            child: financeSourceTable(
              tableKey:
                  'finance-statement-hidden-source-${metadata['materialContextId'] ?? metadata['reviewId'] ?? 'current'}',
              columns: [
                financeSourceColumn('__row', '原表行', width: 76),
                for (var col = start; col < canvas; col++)
                  financeSourceColumn('$col', _letter(col), width: 145),
              ],
              rows: [
                for (var row = first; row <= last; row++)
                  {
                    '__row': '$row',
                    for (var col = start; col < canvas; col++)
                      '$col': cells[(row, col)]?['value']?.toString() ?? '',
                  },
              ],
              idOf: (row) => row['__row'].toString(),
              showColumnChooser: false,
            ),
          ),
        ],
      ],
    );
  }

  String _letter(int column) {
    var value = column + 1, result = '';
    while (value > 0) {
      value--;
      result = String.fromCharCode(65 + value % 26) + result;
      value ~/= 26;
    }
    return result;
  }
}
