import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_order_finance_confirmation.dart';

List<UtenRevisionRow<SalesOrderRevisionLine>> salesOrderRevisionRows(
  SalesOrderRevisionDiff diff,
) {
  final after = {for (final row in diff.afterItems) row.itemId: row};
  final beforeIds = diff.beforeItems.map((row) => row.itemId).toSet();
  return [
    for (final old in diff.beforeItems)
      if (!diff.changedItemIds.contains(old.itemId))
        UtenRevisionRow(
          value: after[old.itemId] ?? old,
          kind: UtenRevisionKind.unchanged,
        )
      else ...[
        UtenRevisionRow(
          value: old,
          kind: UtenRevisionKind.removed,
          label: after.containsKey(old.itemId) ? '修改前' : '已删除',
        ),
        if (after.containsKey(old.itemId))
          UtenRevisionRow(
            value: after[old.itemId]!,
            kind: UtenRevisionKind.added,
            changedKeys: _changedColumns(old, after[old.itemId]!),
          ),
      ],
    for (final row in diff.afterItems)
      if (!beforeIds.contains(row.itemId))
        UtenRevisionRow(
          value: row,
          kind: diff.changedItemIds.contains(row.itemId)
              ? UtenRevisionKind.added
              : UtenRevisionKind.unchanged,
          label: diff.changedItemIds.contains(row.itemId) ? '新增' : null,
        ),
  ];
}

Set<String> _changedColumns(
  SalesOrderRevisionLine before,
  SalesOrderRevisionLine after,
) => {
  for (final key in {...before.values.keys, ...after.values.keys})
    if (key != '行号' &&
        before.values.containsKey(key) &&
        after.values.containsKey(key) &&
        before.values[key] != after.values[key])
      key,
  if (before.goodsName != null && after.goodsName != null
      ? before.goodsName != after.goodsName
      : before.values.containsKey('货品') &&
            after.values.containsKey('货品') &&
            before.values['货品'] != after.values['货品'])
    'goodsName',
  if (before.goodsCode != null &&
      after.goodsCode != null &&
      before.goodsCode != after.goodsCode)
    'goodsCode',
};

class SalesOrderRevisionTable extends StatelessWidget {
  const SalesOrderRevisionTable({
    super.key,
    required this.diff,
    required this.currencyLabel,
    this.summaryBar,
  });
  final SalesOrderRevisionDiff diff;
  final String currencyLabel;
  final Widget? summaryBar;

  @override
  Widget build(BuildContext context) {
    final fields = <(String, String, double)>[
      ('颜色', '颜色', 90),
      // 2026-09-25 用户口径：与编辑页列序对齐——数量后紧跟单位；客户型号退役。
      ('数量', '数量', 100),
      ('单位', '单位', 80),
      ('单价', '单价', 100),
      ('折扣', '折扣', 80),
      (
        '原币金额',
        diff.headerChanges.any((change) => change.field == '币种')
            ? '原币金额'
            : '金额($currencyLabel)',
        130,
      ),
      ('交货日期', '交货日期', 120),
      ('客户编号', '客户编号', 120),
      ('换算率', '换算率', 100),
      ('重量', '重量', 100),
      ('加工费', '机加价', 100),
      ('周长', '围数', 100),
      ('来源单号', '来源单号', 140),
      ('备注', '备注', 180),
    ];
    final allRows = [...diff.beforeItems, ...diff.afterItems];
    // Keep ordinary identity/commercial columns; include additional fields when
    // either version has content, so an emptied value cannot disappear.
    bool show(String key) =>
        const {'颜色', '单位', '数量', '单价', '折扣', '原币金额'}.contains(key) ||
        allRows.any((row) {
          final value = row.values[key];
          return value != null &&
              value.isNotEmpty &&
              value != '未填写' &&
              value != '未设置';
        });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '产品明细 · 红色为原内容，绿色为修改后',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (!diff.baselineComplete) ...[
          const SizedBox(height: UtenSpacing.s4),
          const Text('历史记录仅保留部分旧值，未保存的信息显示为“—”。'),
        ],
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: UtenRevisionTable<SalesOrderRevisionLine>(
            key: const Key('sales-order-revision-table'),
            primary: true,
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            rows: salesOrderRevisionRows(diff),
            columns: [
              MasterColumnDef(
                key: 'goodsName',
                label: '货品名称',
                width: 200,
                value: (row) => row.goodsName ?? row.values['货品'] ?? '—',
              ),
              MasterColumnDef(
                key: 'goodsCode',
                label: '编号',
                width: 130,
                value: (row) => row.goodsCode ?? '—',
              ),
              for (final (key, label, width) in fields)
                if (show(key))
                  MasterColumnDef(
                    key: key,
                    label: label,
                    width: width,
                    value: (row) => row.values[key] ?? '—',
                  ),
            ],
            summaryBar: summaryBar,
          ),
        ),
      ],
    );
  }
}
