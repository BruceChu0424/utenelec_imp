// 销售订单进度看板行（订单进度查询卡）。镜像后端 OrderProgressRow：
// 每张已审订单聚合 订货/已排/已产/已发/可发 + 派生生产进度百分比与链路阶段。
import '../../../components/data_display/uten_status_badge.dart';
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
    this.shipmentDraftQty = 0,
    this.shipmentPendingFinanceQty = 0,
    this.shipmentFinanceRejectedQty = 0,
    this.shipmentApprovedQty = 0,
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
  /// DRAFT 草稿（status=0 未提交且未被财务驳回——本人开了头没交出去的单，
  /// 只在进度页「草稿」段可见，不参与链路阶段派生）；
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

  // ===== 出货在途（V631）：本单 status=0 的出货单按阶段汇总的数量 =====
  /// 出货草稿（销售尚未确认提交财务）。
  final double shipmentDraftQty;

  /// 已提交、等待财务审核。
  final double shipmentPendingFinanceQty;

  /// 被财务退回、待销售处理。
  final double shipmentFinanceRejectedQty;

  /// 财务已放行、等仓库确认出库。
  final double shipmentApprovedQty;

  /// 在途出货合计（含退回件，它仍占着预留）。
  double get shipmentInFlightQty =>
      shipmentDraftQty +
      shipmentPendingFinanceQty +
      shipmentFinanceRejectedQty +
      shipmentApprovedQty;

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
        shipmentDraftQty: (json['shipmentDraftQty'] as num?)?.toDouble() ?? 0,
        shipmentPendingFinanceQty:
            (json['shipmentPendingFinanceQty'] as num?)?.toDouble() ?? 0,
        shipmentFinanceRejectedQty:
            (json['shipmentFinanceRejectedQty'] as num?)?.toDouble() ?? 0,
        shipmentApprovedQty:
            (json['shipmentApprovedQty'] as num?)?.toDouble() ?? 0,
      );
}

/// 进度阶段标签。
String salesProgressStageLabel(String stage) => switch (stage) {
  'DRAFT' => '草稿',
  'REJECTED' => '财务驳回',
  'PENDING' => '待排产',
  'PRODUCING' => '生产中',
  'SHIPPABLE' => '可分批发货',
  'SHIPMENT_PENDING' => '出货待财审',
  'WAREHOUSE_PENDING' => '等仓库出货',
  'SHIPPED' => '仓库已发货',
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
  // 出货在途（V631）：阶段文案直接带数量，退回件优先提示——它要销售处理。
  if (row.stage == 'SHIPMENT_PENDING') {
    if (row.shipmentFinanceRejectedQty > 0.0001) {
      return '出货被财务退回 ${salesQtyText(row.shipmentFinanceRejectedQty)}';
    }
    if (row.shipmentPendingFinanceQty > 0.0001) {
      return '出货待财审 ${salesQtyText(row.shipmentPendingFinanceQty)}';
    }
    return '出货草稿待确认 ${salesQtyText(row.shipmentDraftQty)}';
  }
  if (row.stage == 'WAREHOUSE_PENDING') {
    return '等仓库出货 ${salesQtyText(row.shipmentApprovedQty)}';
  }
  return salesProgressStageLabel(row.stage);
}

/// 「出货在途」列：按阶段列出本单未出库的出货数量；没有在途出货返回 null。
String? salesProgressShipmentInFlightText(SalesOrderProgressRow row) {
  final parts = <String>[
    if (row.shipmentDraftQty > 0.0001)
      '草稿 ${salesQtyText(row.shipmentDraftQty)}',
    if (row.shipmentPendingFinanceQty > 0.0001)
      '待财审 ${salesQtyText(row.shipmentPendingFinanceQty)}',
    if (row.shipmentFinanceRejectedQty > 0.0001)
      '财务退回 ${salesQtyText(row.shipmentFinanceRejectedQty)}',
    if (row.shipmentApprovedQty > 0.0001)
      '待出库 ${salesQtyText(row.shipmentApprovedQty)}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 进度阶段的状态徽章配色（2026-09-21 用户口径「不同状态不同颜色表示，色差要大，
/// 不要相近颜色」，ADR-100）。
///
/// 改之前六个在途阶段挤在三种颜色里：可分批发货/已发货/已结案同绿、
/// 财务驳回/待排产/已中止同红、出货待财审(tertiary)与等仓库出货(teal)还是相邻色相
/// ——一眼分不出单子卡在哪一环，正是用户要改的毛病。
///
/// 现在六个在途阶段各占一个色相，刻意拉到最开：
/// 红=要销售动手改单 · 琥珀=等计划排产 · 青=在机台上 · 紫=可以开发货单了 ·
/// 蓝=球在财务 · 品红=球在仓库。终态不抢色：已发/已结案绿，已中止中性灰。
/// 「等待财务审核」(订单级财务闸门，不是 stage)与「出货待财审」同为蓝——
/// 同样是球在财务手上，共用一色是有意的，不是撞色。
UtenStatusBadgeType salesProgressStageBadgeType(String stage) =>
    switch (stage) {
      'DRAFT' => UtenStatusBadgeType.neutral,
      'REJECTED' => UtenStatusBadgeType.danger,
      'PENDING' => UtenStatusBadgeType.warning,
      'PRODUCING' => UtenStatusBadgeType.accent,
      'SHIPPABLE' => UtenStatusBadgeType.violet,
      'SHIPMENT_PENDING' => UtenStatusBadgeType.info,
      'WAREHOUSE_PENDING' => UtenStatusBadgeType.fuchsia,
      'SHIPPED' || 'CLOSED' => UtenStatusBadgeType.success,
      'CANCELED' => UtenStatusBadgeType.neutral,
      _ => UtenStatusBadgeType.neutral,
    };
