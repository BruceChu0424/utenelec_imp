// 车间内料仓「首次用途影响」预览组件（ADR-131）。
// 升位自 features/warehouse/materialbin/widgets：盘点审核（stock）与内料仓发料
// （warehouse）两个 feature 共用，按架构口径放 shared/warehouse（同 warehouse_task_scope）。
import 'package:flutter/material.dart';

import '../../components/feedback/uten_inline_notice.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/models/goods_issue_method.dart';
import '../formatters/quantity_display.dart';

/// Reasons a preview cannot support this material's proposed first use.
/// The caller owns loading, permission and submission state; no data is changed.
List<String> workshopMaterialFirstUseBlockers({
  required GoodsIssueMethodPreview? preview,
  required String goodsId,
  required String basis,
  int? expectedVersion,
}) {
  if (preview == null) return const ['首次用途影响未读到，请重试'];
  return <String>{
    if (preview.goodsId != goodsId || !preview.matches('PERIODIC', basis))
      '用途预览与当前材料不一致，请重新核对',
    ...preview.blockers,
    if (!preview.massUnit) '该材料基本单位不是重量单位，不能整批发到车间内料仓',
    if (preview.version == null) '没有读到货品版本，请重新核对',
    if (expectedVersion != null && preview.version != expectedVersion)
      '申请后货品版本已变化，请退回重新盘点，不能沿用旧的用途确认',
    if (!preview.canSwitch && preview.blockers.isEmpty) '当前条件不允许切换，请先处理后重新核对',
    if (preview.bomRows.any((row) => row.mustFixFirst))
      '有 BOM 行需要先处理，详情见下方影响清单',
  }.toList(growable: false);
}

/// Shared first-use gate for stock-count approval and material issue forms.
bool canConfirmWorkshopMaterialFirstUse({
  required GoodsIssueMethodPreview? preview,
  required String goodsId,
  required String basis,
  int? expectedVersion,
  bool enabled = true,
  bool canConfigure = true,
  bool loading = false,
}) =>
    enabled &&
    canConfigure &&
    !loading &&
    workshopMaterialFirstUseBlockers(
      preview: preview,
      goodsId: goodsId,
      basis: basis,
      expectedVersion: expectedVersion,
    ).isEmpty;

/// Read-only impact details, shared by issuance and stock-count approval.
class WorkshopMaterialFirstUseImpact extends StatelessWidget {
  const WorkshopMaterialFirstUseImpact({
    super.key,
    required this.preview,
    required this.goodsId,
    required this.basis,
    this.expectedVersion,
    this.approvalContext = false,
  });

  final GoodsIssueMethodPreview preview;
  final String goodsId;
  final String basis;
  final int? expectedVersion;
  final bool approvalContext;

  String _qty(double? value) =>
      value == null ? '未知' : formatQty(value, maxDecimals: 6);

  Widget _details(String title, List<String> details) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    title: Text(title),
    children: [
      for (final detail in details)
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
          child: Text('· $detail'),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final unit = preview.unitName ?? '';
    final changed = preview.bomRows
        .where((row) => row.action != GoodsIssueMethodBomRow.actionKeep)
        .length;
    final blockers = workshopMaterialFirstUseBlockers(
      preview: preview,
      goodsId: goodsId,
      basis: basis,
      expectedVersion: expectedVersion,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blockers.isNotEmpty)
          UtenInlineNotice(
            key: ValueKey('wm-first-use-blockers-$goodsId'),
            level: UtenInlineNoticeLevel.error,
            title: approvalContext ? '暂不能批准，申请继续保留' : '暂不能按此用途发料，申请继续保留',
            message: blockers.join('\n'),
          ),
        _details('关联 BOM ${preview.bomRows.length} 行，其中 $changed 行将调整', [
          for (final row in preview.bomRows)
            '${[row.productCode, row.productName].whereType<String>().join(' ')}：'
                '${row.actionLabel}'
                '${row.qty == null ? '' : '；当前用量 ${_qty(row.qty)} $unit'}'
                '${row.unitWeightGrams == null ? '' : '；单个重量 ${_qty(row.unitWeightGrams)} 克'}'
                '${row.note == null ? '' : '；${row.note}'}',
        ]),
        if (preview.unclearedDemands.isNotEmpty)
          _details('未清账的按单领料 ${preview.unclearedDemands.length} 项', [
            for (final demand in preview.unclearedDemands)
              '${demand.orderLabel} ${demand.productName ?? ''}：'
                  '${_qty(demand.unclearedQty)} $unit 未清账'
                  '${demand.note == null ? '' : '；${demand.note}'}',
          ]),
        if (preview.binBalances.isNotEmpty)
          _details('现有内料仓余额 ${preview.binBalances.length} 项', [
            for (final balance in preview.binBalances)
              '${balance.warehouseName ?? '内料仓'}：${_qty(balance.qty)} $unit',
          ]),
        if (preview.openPeriods.isNotEmpty)
          _details('尚未结算期间 ${preview.openPeriods.length} 项', [
            for (final period in preview.openPeriods)
              '${period.binName ?? '内料仓'} 第 ${period.periodNo ?? '—'} 期：'
                  '${period.startDate ?? ''} 至 ${period.endDate ?? '尚未截止'}',
          ]),
        if (preview.unsettledTheory.isNotEmpty)
          _details('未结算理论用量 ${preview.unsettledTheory.length} 项', [
            for (final theory in preview.unsettledTheory)
              '${theory.binName ?? '内料仓'}：${theory.productCount} 个产品，'
                  '${_qty(theory.theoryQty)} $unit',
          ]),
        if (preview.inProgressSegments.isNotEmpty)
          _details('涉及在产工单 ${preview.inProgressSegments.length} 张', [
            for (final segment in preview.inProgressSegments)
              [
                segment.segmentCode,
                segment.productCode,
                segment.productName,
              ].whereType<String>().join(' '),
          ]),
        if (preview.activeChoices.isNotEmpty)
          _details('切换后需要重新认料的产品 ${preview.activeChoices.length} 个', [
            for (final choice in preview.activeChoices)
              [
                choice.productCode,
                choice.productName,
              ].whereType<String>().join(' '),
          ]),
      ],
    );
  }
}
