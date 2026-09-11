// 销售订单进度看板行（订单进度查询卡）。镜像后端 OrderProgressRow：
// 每张已审订单聚合 订货/已排/已产/已发/可发 + 派生生产进度百分比与链路阶段。
import 'package:flutter/material.dart';

import 'sales_doc.dart' show salesQtyText;

class SalesOrderProgressRow {
  const SalesOrderProgressRow({
    required this.orderId,
    required this.billNo,
    this.billDate,
    this.deliverDate,
    this.clientName,
    required this.orderQty,
    required this.producedQty,
    required this.shippedQty,
    required this.reservedQty,
    required this.plannedQty,
    this.unplannedQty = 0,
    required this.productionPct,
    required this.stage,
    this.financeConfirmed = true,
    this.financeRejected = false,
    this.financeRejectedReason,
    this.financeRejectedAt,
    this.financeRejectedByName,
    this.stopped = false,
    this.closed = false,
  });

  final String orderId;
  final String billNo;
  final String? billDate;
  final String? deliverDate;
  final String? clientName;
  final double orderQty;
  final double producedQty;
  final double shippedQty;
  final double reservedQty;
  final double plannedQty;

  /// 剩余未排量 = Σ行(未交付 − 预留 − 未完工计划量)（V545 服务端派生）；
  /// >0 即该单仍在「待排产」段，即使已排/已产 > 0。
  final double unplannedQty;

  /// 生产进度 = 已产/订货（外层总进度环口径，clamp≤1）。
  final double productionPct;

  /// PENDING 待排产（含部分排产：unplannedQty>0）/ PRODUCING 生产中 /
  /// SHIPPABLE 可分批发货 / SHIPPED 已发货；
  /// 终态：CANCELED 已中止（整单取消）/ CLOSED 已结案——不占活跃阶段段，
  /// 只在「历史记录」（全部订单）中可见。
  final String stage;

  /// 财务确认（V300）：false = 等待财务审核，确认前不展示排产进度。
  final bool financeConfirmed;

  /// 财务已驳回且尚未解决；服务端 `REJECTED` 阶段优先于生产阶段。
  final bool financeRejected;
  final String? financeRejectedReason;
  final String? financeRejectedAt;
  final String? financeRejectedByName;

  /// 已中止（整单取消，服务端 stopped）；历史记录里以「已中止」阶段呈现。
  final bool stopped;

  /// 已结案（正常履约完结）；历史记录里以「已结案」阶段呈现。
  final bool closed;

  /// 是否有可发货量（reserved_qty>0）。
  bool get shippable => reservedQty > 0.0001;

  /// 订单未交数量；分批可发不代表订单已经完成。
  double get remainingQty =>
      (orderQty - shippedQty).clamp(0, double.infinity).toDouble();

  factory SalesOrderProgressRow.fromJson(Map<String, dynamic> json) =>
      SalesOrderProgressRow(
        orderId: json['orderId'] as String,
        billNo: json['billNo'] as String? ?? '',
        billDate: json['billDate'] as String?,
        deliverDate: json['deliverDate'] as String?,
        clientName: json['clientName'] as String?,
        orderQty: (json['orderQty'] as num?)?.toDouble() ?? 0,
        producedQty: (json['producedQty'] as num?)?.toDouble() ?? 0,
        shippedQty: (json['shippedQty'] as num?)?.toDouble() ?? 0,
        reservedQty: (json['reservedQty'] as num?)?.toDouble() ?? 0,
        plannedQty: (json['plannedQty'] as num?)?.toDouble() ?? 0,
        unplannedQty: (json['unplannedQty'] as num?)?.toDouble() ?? 0,
        productionPct: (json['productionPct'] as num?)?.toDouble() ?? 0,
        stage: json['stage'] as String? ?? 'PENDING',
        financeConfirmed: (json['financeConfirmed'] as bool?) ?? true,
        financeRejected: (json['financeRejected'] as bool?) ?? false,
        financeRejectedReason: json['financeRejectedReason'] as String?,
        financeRejectedAt: json['financeRejectedAt'] as String?,
        financeRejectedByName: json['financeRejectedByName'] as String?,
        stopped: (json['stopped'] as bool?) ?? false,
        closed: (json['closed'] as bool?) ?? false,
      );
}

/// 进度阶段标签。
String salesProgressStageLabel(String stage) => switch (stage) {
  'REJECTED' => '财务驳回',
  'PENDING' => '待排产',
  'PRODUCING' => '生产中',
  'SHIPPABLE' => '可分批发货',
  'SHIPPED' => '已发货',
  'CANCELED' => '已中止',
  'CLOSED' => '已结案',
  _ => '—',
};

/// 阶段列文本：待排产且已排一部分（plannedQty>0）时显示
/// 「待排产·部分已排 已排/订货」（V545：部分排产的单仍留在待排产段，
/// 只在文本上标明已排多少），其余同 [salesProgressStageLabel]。
String salesProgressStageText(SalesOrderProgressRow row) {
  if (row.stage == 'PENDING' && row.plannedQty > 0.0001) {
    return '待排产·部分已排 '
        '${salesQtyText(row.plannedQty)}/${salesQtyText(row.orderQty)}';
  }
  return salesProgressStageLabel(row.stage);
}

/// 进度阶段色（绿=可发/已发/已结案，橙=生产中，红=驳回/中止，灰=未上链）。
Color salesProgressStageColor(String stage, ThemeData theme) => switch (stage) {
  'REJECTED' || 'CANCELED' => theme.colorScheme.error,
  'SHIPPABLE' || 'SHIPPED' || 'CLOSED' => Colors.green,
  'PRODUCING' => Colors.orange,
  'PENDING' => theme.colorScheme.error,
  _ => theme.colorScheme.onSurfaceVariant,
};
