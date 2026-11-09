// 委外任务中心「物料」列与物料弹窗(2026-11-09 用户口径「跟我的车间任务那里显示一样」)。
//
// 委外件下面可能有很多种直属物料，任务行上不再显示一个合成的领料数量(多物料时一个数
// 说不清)，改为和「我的车间任务」同一个物料列：已领 a/n 种 · 缺 k 种 · 计划未下单 j 种 ·
// 可领 m 种 · 待发 p 种；点开同一个任务物料弹窗看每种物料的仓库可用库存，勾选可领的
// 物料(可多选、全选可领)后去领料页填本次数量——支持分批，少领的下次再领。
// 摘要、单元格、弹窗壳、卡片都是车间与委外共用的公共组件，这里只把委外的服务端事实
// (任务行逐种分桶、任务详情物料表)接上去。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/widgets/task_material_cards.dart';
import '../../../shared/widgets/task_material_kind_summary.dart';
import '../../../shared/widgets/task_material_selection_dialog.dart';
import '../models/subcontract_draw.dart';
import '../repositories/subcontract_draw_repository.dart';
import 'subcontract_draw_status.dart';

/// 「物料」列分段：计数部分与车间同一入口；已结束领料的物料单独点出(灰)。
/// 「已领」= 已发外发齐的物料种数(委外的「领到」就是发给委外商)。
List<MaterialKindSegment> subcontractMaterialKindSegments(
  SubcontractDrawTaskRow row,
) {
  if (row.materialKindCount == 0) {
    return const [('无需物料', MaterialKindTone.plain)];
  }
  return [
    ...materialKindCountSegments(
      kindCount: row.materialKindCount,
      issuedKindCount: row.sentFullKindCount,
      shortKindCount: row.shortKindCount,
      planningGapKindCount: row.unplannedShortKindCount,
      drawableKindCount: row.drawableKindCount,
      awaitingWarehouseKindCount: row.pendingKindCount,
    ),
    if (row.closedKindCount > 0)
      ('已结束领料 ${row.closedKindCount} 种', MaterialKindTone.muted),
  ];
}

/// 「物料」列悬停：逐桶解释(与车间物料列同一种说法)。
String subcontractMaterialKindTooltip(SubcontractDrawTaskRow row) {
  if (row.materialKindCount == 0) return '本委外任务没有需要发给委外商的直属物料';
  return [
    '共 ${row.materialKindCount} 种直属物料：',
    '已发给委外商(发齐) ${row.sentFullKindCount} 种',
    if (row.drawableKindCount > 0) '仓库有货、可以领料 ${row.drawableKindCount} 种',
    if (row.pendingKindCount > 0) '已提交领料、待仓库发出 ${row.pendingKindCount} 种',
    if (row.shortKindCount > 0) '还缺、仓库没货 ${row.shortKindCount} 种',
    if (row.unplannedShortKindCount > 0)
      '其中计划还没下单 ${row.unplannedShortKindCount} 种',
    if (row.closedKindCount > 0) '已结束领料 ${row.closedKindCount} 种',
    '点击查看每种物料的仓库库存并选择要领的物料',
  ].join('\n');
}

/// 委外一种直属物料 → 公共物料卡片(与车间任务物料弹窗同一组件)。
TaskMaterialEntry subcontractMaterialEntry(SubcontractDrawMaterial material) {
  String qty(String key) =>
      formatExactQtyWithUnit(material.quantityText(key), material.unitName);
  final supply = subcontractDrawSupplyText(material);
  return TaskMaterialEntry(
    id: material.planItemId,
    goodsName: material.goodsName,
    goodsCode: material.goodsCode,
    colorName: material.colorName,
    stateLabel: subcontractDrawMaterialStateLabel(material),
    stateType:
        subcontractDrawMaterialBadgeType(material) ??
        UtenStatusBadgeType.neutral,
    sourceLabel: supply == '—' ? null : '供应来源 $supply',
    headline: [
      TaskMaterialFact('需求', qty('requiredQty')),
      TaskMaterialFact('仓库可用', qty('availableQty')),
      TaskMaterialFact('可领', qty('drawableQty'), selectionOnly: true),
      TaskMaterialFact('还缺', qty('shortQty'), error: material.shortQty > 0),
    ],
    details: [
      TaskMaterialFact('已发外', qty('sentQty')),
      TaskMaterialFact('待仓库发', qty('pendingQty')),
      TaskMaterialFact(
        '仓库可用',
        qty('availableQty'),
        hint: '本任务专属批次加扣除他人占用后可用的公共库存，按作业仓合计；去领料后可分仓填写。',
      ),
      TaskMaterialFact('本次可领', qty('drawableQty')),
      TaskMaterialFact('每套用量', qty('perUnitQty')),
    ],
    footnotes: [if (supply != '—') ('供应来源 $supply', true)],
  );
}

/// 打开委外任务的物料弹窗。返回所选物料(冻结计划行 id)，取消返回 null。
/// [canSubmitDraw] = 账号能力；能否勾选还要服务端在任务详情里给出 DRAW 动作。
Future<Set<String>?> showSubcontractMaterialDialog(
  BuildContext context, {
  required SubcontractDrawGateway gateway,
  required SubcontractDrawTaskRow row,
  required bool canSubmitDraw,
  bool Function()? isCurrent,
}) => UtenDialog.showAndWaitForExit<Set<String>>(
  context,
  builder: (_) => SubcontractMaterialDialog(
    gateway: gateway,
    row: row,
    canSubmitDraw: canSubmitDraw,
    isCurrent: isCurrent,
  ),
);

/// 委外任务的物料弹窗：公共任务物料弹窗壳 + 委外任务详情(一次读取同时给出逐种事实与
/// 「本次可领」；勾选门 = 服务端 DRAW 动作 × 本次可领 > 0)。
class SubcontractMaterialDialog extends StatefulWidget {
  const SubcontractMaterialDialog({
    super.key,
    required this.gateway,
    required this.row,
    required this.canSubmitDraw,
    this.isCurrent,
  });

  final SubcontractDrawGateway gateway;
  final SubcontractDrawTaskRow row;
  final bool canSubmitDraw;
  final bool Function()? isCurrent;

  @override
  State<SubcontractMaterialDialog> createState() =>
      _SubcontractMaterialDialogState();
}

class _SubcontractMaterialDialogState extends State<SubcontractMaterialDialog> {
  /// 最近一次任务详情给出的 DRAW 动作。放在 State 里：弹窗路由重建换了闭包，
  /// 读取中途也不会丢掉服务端的勾选门。
  bool _drawAllowed = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final identity = [
      row.orderBillNo,
      row.goodsName,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    return TaskMaterialSelectionDialog<SubcontractDrawMaterial>(
      dialogKey: ValueKey('subcontract-material-dialog-${row.orderItemId}'),
      title: identity.isEmpty ? '委外任务物料' : '委外任务物料 · $identity',
      compactTitle: '委外任务物料 · ${row.orderBillNo}',
      keyPrefix: 'subcontract-material',
      cardKeyPrefix: 'subcontract-material-card',
      selectKeyPrefix: 'subcontract-material-select',
      canRequestDraw: widget.canSubmitDraw,
      isCurrent: widget.isCurrent,
      loadMaterials: (_) async {
        final detail = await widget.gateway.detail(row.orderItemId);
        _drawAllowed = detail.allows(SubcontractDrawTaskDetail.drawAction);
        return detail.materials;
      },
      entryOf: subcontractMaterialEntry,
      isShort: (material) => material.shortQty > 0,
      drawTargetsOf: (materials) => {
        if (_drawAllowed)
          for (final material in materials)
            if (material.drawableQty > 0)
              material.planItemId: {material.planItemId},
      },
    );
  }
}
