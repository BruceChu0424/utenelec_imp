import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_table.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

bool arrivalQtyHasDecision(ProcurementArrivalException task) =>
    task.decision?.isNotEmpty == true ||
    const {
      'RECEIPT_ADJUSTED',
      'RETURN_REQUIRED',
      'RECEIPT_POSTED',
      'CLOSED',
    }.contains(task.status);

bool arrivalQtyWasModified(ProcurementArrivalException task) =>
    arrivalQtyHasDecision(task) && task.acceptedQty != task.declaredQty;

class ArrivalQtyRevisionLine {
  const ArrivalQtyRevisionLine({required this.task, required this.qty});
  final ProcurementArrivalException task;
  final num qty;
}

/// A pending exception's default acceptedQty=0 is not a deletion. Only an
/// explicit preview or a recorded finance decision establishes the new row.
List<UtenRevisionRow<ArrivalQtyRevisionLine>> arrivalQtyRevisionRows(
  ProcurementArrivalException task, {
  num? proposedQty,
}) {
  final preview = proposedQty != null;
  final hasAfter = preview || arrivalQtyHasDecision(task);
  final after = proposedQty ?? task.acceptedQty;
  final before = ArrivalQtyRevisionLine(task: task, qty: task.declaredQty);
  if (!hasAfter || after == task.declaredQty) {
    return [
      UtenRevisionRow(
        value: before,
        kind: UtenRevisionKind.unchanged,
        label: !hasAfter
            ? '原申报'
            : preview
            ? '拟接收'
            : '数量未变',
      ),
    ];
  }
  return [
    UtenRevisionRow(
      value: before,
      kind: UtenRevisionKind.removed,
      label: after == 0 ? (preview ? '拟删除' : '已删除') : '原申报',
    ),
    if (after > 0)
      UtenRevisionRow(
        value: ArrivalQtyRevisionLine(task: task, qty: after),
        kind: UtenRevisionKind.added,
        label: preview ? '拟接收' : '批准接收',
        changedKeys: const {'qty'},
      ),
  ];
}

/// Declared and accepted quantities are authoritative facts of the same
/// receipt line. Accepted amounts are not available in this projection, so
/// this table deliberately does not derive or repeat historical amounts.
class ArrivalQtyRevisionTable extends StatelessWidget {
  const ArrivalQtyRevisionTable({
    super.key,
    required this.task,
    this.proposedQty,
  });

  final ProcurementArrivalException task;
  final num? proposedQty;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        proposedQty != null
            ? '收货数量修改预览'
            : arrivalQtyWasModified(task)
            ? '收货数量修改'
            : '收货明细',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      UtenRevisionTable<ArrivalQtyRevisionLine>(
        key: const Key('arrival-qty-revision-table'),
        embedded: true,
        rows: arrivalQtyRevisionRows(task, proposedQty: proposedQty),
        columns: [
          MasterColumnDef(
            key: 'goodsName',
            label: '货品名称',
            width: 190,
            value: (line) => line.task.goodsName,
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 120,
            value: (line) => line.task.goodsCode,
          ),
          MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 90,
            value: (line) => line.task.colorName,
          ),
          MasterColumnDef(
            key: 'unit',
            label: '单位',
            width: 80,
            value: (line) => line.task.unitName,
          ),
          MasterColumnDef(
            key: 'qty',
            label: '数量',
            width: 110,
            type: 'number',
            value: (line) => financeExactTrimmed(line.qty.toString()),
          ),
          if (!task.priceMasked && task.unitPrice != null)
            MasterColumnDef(
              key: 'unitPrice',
              label: '单价',
              width: 120,
              type: 'money',
              value: (line) => financeExactTrimmed(line.task.unitPrice),
            ),
        ],
      ),
    ],
  );
}
