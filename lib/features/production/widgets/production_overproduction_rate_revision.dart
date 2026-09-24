import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_table.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../repositories/production_overproduction_rate_repository.dart';

List<UtenRevisionRow<Map<String, dynamic>>>? productionRateRevisionRows(
  ProductionOverproductionRateRequest request,
) {
  final before = request.snapshotItems('beforeSnapshot');
  final after = request.snapshotItems('afterSnapshot');
  if (before == null ||
      after == null ||
      before.length != 1 ||
      after.length != 1 ||
      before.single['itemId'] != request.segmentId ||
      after.single['itemId'] != request.segmentId) {
    return null;
  }
  for (final row in [...before, ...after]) {
    for (final key in [
      'plannedQty',
      'allowedOverproductionRate',
      'allowedTotalQty',
    ]) {
      final value = productionRateNumber(row[key]);
      if (value == null || !value.isFinite || value < 0) return null;
    }
  }
  return [
    UtenRevisionRow(
      value: before.single,
      kind: UtenRevisionKind.removed,
      label: '申请前',
    ),
    UtenRevisionRow(
      value: after.single,
      kind: UtenRevisionKind.added,
      label: '申请后',
    ),
  ];
}

class ProductionOverproductionRateRevision extends StatelessWidget {
  const ProductionOverproductionRateRevision({
    super.key,
    required this.request,
  });
  final ProductionOverproductionRateRequest request;
  @override
  Widget build(BuildContext context) {
    final rows = productionRateRevisionRows(request);
    if (rows == null) return const Center(child: Text('审批快照不完整，请刷新后再处理'));
    return UtenRevisionTable<Map<String, dynamic>>(
      key: const ValueKey('production-rate-revision-table'),
      rows: rows,
      columns: [
        for (final field in const [
          ('goodsName', '货品名称', 220.0),
          ('goodsCode', '编号', 130.0),
          ('colorName', '颜色', 90.0),
          ('unitName', '单位', 80.0),
          ('plannedQty', '计划数量', 110.0),
        ])
          MasterColumnDef(
            key: field.$1,
            label: field.$2,
            width: field.$3,
            value: (row) => row[field.$1]?.toString() ?? '—',
          ),
        MasterColumnDef(
          key: 'allowedOverproductionRate',
          label: '允许超产比例',
          width: 150,
          value: (row) => productionRateText(
            productionRateNumber(row['allowedOverproductionRate']),
          ),
        ),
        MasterColumnDef(
          key: 'allowedTotalQty',
          label: '允许累计报工量',
          width: 160,
          value: (row) => row['allowedTotalQty']?.toString() ?? '—',
        ),
      ],
    );
  }
}
