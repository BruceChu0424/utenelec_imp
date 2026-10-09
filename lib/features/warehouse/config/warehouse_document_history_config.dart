import 'package:flutter/material.dart';

import '../../../core/theme/uten_colors.dart';

/// Warehouse-owned, quantity-only history projections.
///
/// These routes deliberately do not reuse purchase/subcontract document pages:
/// the server contract and Flutter models contain physical-operation facts only.
enum WarehouseDocumentHistoryType {
  purchaseReceipt,
  subcontractReceipt,
  subcontractMaterialIssue,
  subcontractReturn,
  subcontractMaterialReturn,
  subcontractWaste;

  static WarehouseDocumentHistoryType? tryParse(String? raw) {
    final value = raw?.trim().toLowerCase().replaceAll('_', '-');
    return switch (value) {
      'purchase-receipt' || 'purchase-receipts' => purchaseReceipt,
      'subcontract-receipt' || 'subcontract-receipts' => subcontractReceipt,
      'subcontract-material-issue' ||
      'subcontract-material-issues' => subcontractMaterialIssue,
      'subcontract-return' || 'subcontract-returns' => subcontractReturn,
      'subcontract-material-return' ||
      'subcontract-material-returns' => subcontractMaterialReturn,
      'subcontract-waste' || 'subcontract-wastes' => subcontractWaste,
      _ => null,
    };
  }

  String get segment => switch (this) {
    purchaseReceipt => 'purchase-receipts',
    subcontractReceipt => 'subcontract-receipts',
    subcontractMaterialIssue => 'subcontract-material-issues',
    subcontractReturn => 'subcontract-returns',
    subcontractMaterialReturn => 'subcontract-material-returns',
    subcontractWaste => 'subcontract-wastes',
  };

  String get title => switch (this) {
    purchaseReceipt => '采购收货历史',
    subcontractReceipt => '委外进仓历史',
    subcontractMaterialIssue => '委外出仓历史',
    subcontractReturn => '委外成品退货历史',
    subcontractMaterialReturn => '委外材料退回历史',
    subcontractWaste => '委外损耗历史',
  };

  String get documentLabel => switch (this) {
    purchaseReceipt => '采购收货单',
    subcontractReceipt => '委外进仓单',
    subcontractMaterialIssue => '委外出仓记录',
    subcontractReturn => '委外成品退货单',
    subcontractMaterialReturn => '委外材料退回单',
    subcontractWaste => '委外损耗记录',
  };

  String get description => switch (this) {
    purchaseReceipt => '查看采购到货的数量、重量、当前建议库位、质量与来源记录',
    subcontractReceipt => '查看委外成品回厂的数量、重量、当前建议库位与质量记录',
    subcontractMaterialIssue => '查看发给委外商的直属物料实物出仓记录',
    subcontractReturn => '查看委外成品退回委外商的实物记录',
    subcontractMaterialReturn => '查看委外商退回余料的实物记录',
    subcontractWaste => '查看委外材料损耗的数量、原因与责任记录',
  };

  IconData get icon => switch (this) {
    purchaseReceipt => Icons.inventory_2_outlined,
    subcontractReceipt => Icons.move_to_inbox_outlined,
    subcontractMaterialIssue => Icons.outbound_outlined,
    subcontractReturn => Icons.undo_outlined,
    subcontractMaterialReturn => Icons.assignment_return_outlined,
    subcontractWaste => Icons.delete_sweep_outlined,
  };

  String get emptyMessage => '暂无$title';

  String listPath() => '/warehouse/history/$segment';

  String detailPath(String id) {
    return '/warehouse/history/$segment/${Uri.encodeComponent(id)}';
  }

  List<WarehouseHistoryStatusFilter> get statusFilters => const [
    WarehouseHistoryStatusFilter(value: null, label: '全部'),
    WarehouseHistoryStatusFilter(value: '0', label: '草稿'),
    WarehouseHistoryStatusFilter(value: '1', label: '已审核'),
    WarehouseHistoryStatusFilter(value: '-1', label: '已红冲'),
  ];
}

class WarehouseHistoryStatusFilter {
  const WarehouseHistoryStatusFilter({
    required this.value,
    required this.label,
  });

  final String? value;
  final String label;
}

String warehouseHistoryStatusLabel(String? raw, {required bool closed}) {
  if (closed) return '已完成';
  final status = raw?.trim().toUpperCase();
  return switch (status) {
    null || '' => '状态未知',
    '0' || 'DRAFT' || 'PENDING' => '草稿',
    '1' || 'APPROVED' || 'POSTED' => '已审核',
    '-1' || 'REVERSED' || 'VOIDED' => '已红冲',
    'CLOSED' || 'COMPLETED' => '已完成',
    _ => raw!,
  };
}

/// 历史单据状态列整格底色（ADR-169 逐页显式映射；分支与
/// [warehouseHistoryStatusLabel] 同一判定）：已红冲=红（红冲负向事件）/
/// 已审核=绿（已审）/ 草稿=灰、已完成(closed)=灰（草稿未办、办结皆中性，
/// 办结不再是本队列动作对象，同领料任务「已完成=灰」口径）；状态未知与
/// 未识别文案保持无色纯文本。
Color? warehouseHistoryStatusCellColor(String? raw, {required bool closed}) {
  if (closed) return UtenColors.statusNeutral;
  switch (raw?.trim().toUpperCase()) {
    case '-1' || 'REVERSED' || 'VOIDED':
      return UtenColors.statusDanger;
    case '1' || 'APPROVED' || 'POSTED':
      return UtenColors.statusSuccess;
    case '0' || 'DRAFT' || 'PENDING':
      return UtenColors.statusNeutral;
    default:
      return null;
  }
}

/// 历史明细「质量状态」列整格底色（ADR-169，分支与
/// [warehouseInspectionStatusLabel] 对齐）：不合格=红 / 检验完成(PASSED 族)=绿 /
/// 待检=黄（等检查，无异常）/ 部分完成=橙（部分完成待判定，同质检记录页
/// PARTIAL=橙）/ 已撤销=灰；未关联质检与无需质检不是流程状态，保持无色。
Color? warehouseInspectionCellColor(String? raw) {
  switch (raw?.trim().toUpperCase()) {
    case 'FAILED' || 'FAIL':
      return UtenColors.statusDanger;
    case 'PASSED' || 'PASS' || 'COMPLETED' || 'RESOLVED':
      return UtenColors.statusSuccess;
    case 'PENDING':
      return UtenColors.warningStrong;
    case 'PARTIAL':
      return UtenColors.statusOrange;
    case 'REVERSED':
      return UtenColors.statusNeutral;
    default:
      return null;
  }
}

String warehouseInspectionStatusLabel(String? raw) {
  final status = raw?.trim().toUpperCase();
  return switch (status) {
    null || '' => '未关联质检',
    'PENDING' => '待检',
    'PARTIAL' => '部分完成',
    'PASSED' || 'PASS' || 'COMPLETED' || 'RESOLVED' => '检验完成',
    'FAILED' || 'FAIL' => '不合格',
    'REVERSED' => '已撤销',
    'NOT_REQUIRED' => '无需质检',
    _ => raw!,
  };
}
