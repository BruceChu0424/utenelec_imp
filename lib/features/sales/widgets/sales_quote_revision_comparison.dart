import 'package:flutter/material.dart';

import '../../../components/data_display/uten_cell_revision_table.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../shared/business_columns/business_column.dart';
import '../../../shared/business_columns/business_columns_table.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_quote_workflow.dart';

const _fields = <String, String>{
  'goodsName': '货品名称',
  'goodsNameEn': '英文名称',
  'goodsCode': '编号',
  'colorName': '颜色',
  'qty': '数量',
  'unitName': '单位',
  'price': '单价',
  'discount': '折扣',
  'amount': '金额',
  'clientModel': '文件型号',
  'clientGoodsName': '文件品名',
  'remark': '备注',
};
const _headerLabels = {
  'clientName': '客户',
  'billDate': '日期',
  'sellerName': '业务员',
  'validUntil': '有效期',
  'deliverDate': '交货日期',
  'settlementMethodName': '结账方式',
  'contractNo': '合同号',
  'remark': '备注',
  'financeRemark': '财务备注',
};

const _numbers = {'qty', 'price', 'discount', 'amount', 'unitRate'};

List<Map<String, dynamic>> _lines(Map<String, dynamic> snapshot) =>
    (snapshot['lines'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

String? _value(Map<String, dynamic> row, String key) {
  final value = row[key]?.toString();
  return _numbers.contains(key) ? financeExactTrimmed(value) : value;
}

/// Match stable document line ids, never goods ids: two rows may quote the same
/// goods at different quantities or discounts. Missing old lines remain visible.
List<UtenCellRevisionRow<Map<String, dynamic>>> salesQuoteRevisionRows(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  final old = _lines(before);
  final current = _lines(after);
  final oldIds = old
      .map((row) => row['id']?.toString())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
  final byId = {
    for (final row in current)
      if (row['id']?.toString().isNotEmpty == true) row['id'].toString(): row,
  };
  return [
    for (final row in old)
      UtenCellRevisionRow(
        before: row,
        after: byId[row['id']?.toString()],
        changedKeys: _changed(row, byId[row['id']?.toString()]),
      ),
    for (final row in current)
      if (!oldIds.contains(row['id']?.toString()))
        UtenCellRevisionRow(after: row),
  ];
}

Set<String> _changed(Map<String, dynamic> row, Map<String, dynamic>? newer) =>
    newer == null
    ? const {}
    : {
        for (final key in _fields.keys)
          if (_value(row, key) != _value(newer, key)) key,
        ...businessColumnChangedKeys(
          BusinessColumn.read(row['extraColumns']),
          BusinessColumn.read(newer['extraColumns']),
        ),
      };

class SalesQuoteRevisionComparison extends StatefulWidget {
  const SalesQuoteRevisionComparison({super.key, required this.revisions});
  final List<SalesQuoteRevision> revisions;
  @override
  State<SalesQuoteRevisionComparison> createState() =>
      _SalesQuoteRevisionComparisonState();
}

class _SalesQuoteRevisionComparisonState
    extends State<SalesQuoteRevisionComparison> {
  String? _selectedSnapshot;
  String _snapshotKey(SalesQuoteRevision r) =>
      '${r.revision}/${r.action}/${r.createdAt}';

  @override
  Widget build(BuildContext context) {
    final snapshots = widget.revisions.where((r) => r.snapshot != null).toList()
      ..sort((a, b) => (a.revision ?? 0).compareTo(b.revision ?? 0));
    if (snapshots.length < 2) return const SizedBox.shrink();
    final selected = snapshots.indexWhere(
      (r) => _snapshotKey(r) == _selectedSnapshot,
    );
    var latestChange = snapshots.length - 1;
    for (var i = snapshots.length - 1; i > 0; i--) {
      final differences = salesQuoteRevisionRows(
        snapshots[i - 1].snapshot!,
        snapshots[i].snapshot!,
      );
      final beforeHeader =
          snapshots[i - 1].snapshot!['header'] as Map? ??
          snapshots[i - 1].snapshot!;
      final afterHeader =
          snapshots[i].snapshot!['header'] as Map? ?? snapshots[i].snapshot!;
      if (_headerLabels.keys.any(
            (key) => beforeHeader[key] != afterHeader[key],
          ) ||
          differences.any(
            (r) => r.added || r.removed || r.changedKeys.isNotEmpty,
          )) {
        latestChange = i;
        break;
      }
    }
    final index = selected < 1 ? latestChange : selected;
    final previous = snapshots[index - 1];
    final current = snapshots[index];
    final rows = salesQuoteRevisionRows(previous.snapshot!, current.snapshot!);
    final all = rows
        .expand(
          (row) => [
            if (row.before != null) row.before!,
            if (row.after != null) row.after!,
          ],
        )
        .toList();
    final oldHeader =
        previous.snapshot!['header'] as Map? ?? previous.snapshot!;
    final newHeader = current.snapshot!['header'] as Map? ?? current.snapshot!;
    final red = utenRevisionForeground(context, UtenRevisionKind.removed)!;
    return ExpansionTile(
      key: const ValueKey('sales-quote-revision-comparison'),
      initiallyExpanded: true,
      title: const Text('逐项修改对照'),
      subtitle: const Text('仅修改格划去旧值，右侧红字显示新值；删除明细才整行划去'),
      children: [
        DropdownButton<int>(
          value: index,
          isExpanded: true,
          items: [
            for (var i = 1; i < snapshots.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                  '第 ${snapshots[i].revision ?? i} 版 · ${snapshots[i].actorName ?? '—'} · ${snapshots[i].actionLabel ?? snapshots[i].action}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => setState(
            () => _selectedSnapshot = _snapshotKey(snapshots[value!]),
          ),
        ),
        for (final key in _headerLabels.keys)
          if (oldHeader[key] != newHeader[key])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text('${_headerLabels[key]}：'),
                  Flexible(
                    child: Text(
                      '${oldHeader[key] ?? '未填写'}',
                      style: TextStyle(
                        color: red,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                  ),
                  const Text(' → '),
                  Flexible(
                    child: Text(
                      '${newHeader[key] ?? '未填写'}',
                      style: TextStyle(color: red, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
        SizedBox(
          height: 330,
          child: UtenCellRevisionTable<Map<String, dynamic>>(
            rows: rows,
            columns: [
              for (final field in _fields.entries)
                MasterColumnDef(
                  key: field.key,
                  label: field.value,
                  width: field.key == 'goodsName' || field.key == 'remark'
                      ? 200
                      : 120,
                  type: _numbers.contains(field.key) ? 'number' : 'text',
                  value: (row) => _value(row, field.key),
                ),
              ...businessReadOnlyColumns<Map<String, dynamic>>(
                all,
                columnsOf: (row) => BusinessColumn.read(row['extraColumns']),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
