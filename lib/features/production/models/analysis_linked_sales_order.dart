// 物料分析「关联销售订单 → 订单货品清单」只读投影 (ADR-088)。
//
// 后端 GET /api/production/material-analyses/{id}/sales-orders/{orderId}
// 的线上契约镜像：纯数量口径，**没有任何单价/金额/折扣字段**——计划员看订单
// 只需要知道订了些什么货、还差多少要生产，看不到销售价格。

/// 订单头 + 货品行。
class AnalysisLinkedSalesOrder {
  const AnalysisLinkedSalesOrder({
    required this.orderId,
    this.billNo,
    this.billDate,
    this.deliverDate,
    this.clientId,
    this.clientName,
    this.sellerName,
    this.status,
    this.financeConfirmed = false,
    this.closed = false,
    this.stopped = false,
    this.lines = const [],
  });

  final String orderId;
  final String? billNo;
  final String? billDate;
  final String? deliverDate;
  final String? clientId;
  final String? clientName;
  final String? sellerName;
  final int? status;
  final bool financeConfirmed;
  final bool closed;
  final bool stopped;
  final List<AnalysisLinkedSalesOrderLine> lines;

  /// 单头状态中文标签 (0 待审核 / 1 已审核 / 其它未知)，再叠加结案/中止两个独立位。
  String get statusLabel {
    final parts = <String>[
      switch (status) {
        0 => '待审核',
        1 => '已审核',
        _ => '未知状态',
      },
      if (financeConfirmed) '已财务确认',
      if (closed) '已结案',
      if (stopped) '已中止',
    ];
    return parts.join(' · ');
  }

  factory AnalysisLinkedSalesOrder.fromJson(Map<String, dynamic> json) =>
      AnalysisLinkedSalesOrder(
        orderId: _string(json['orderId']) ?? '',
        billNo: _string(json['billNo']),
        billDate: _string(json['billDate']),
        deliverDate: _string(json['deliverDate']),
        clientId: _string(json['clientId']),
        clientName: _string(json['clientName']),
        sellerName: _string(json['sellerName']),
        status: (json['status'] as num?)?.toInt(),
        financeConfirmed: json['financeConfirmed'] == true,
        closed: json['closed'] == true,
        stopped: json['stopped'] == true,
        lines: [
          for (final raw in (json['lines'] as List? ?? const []))
            if (raw is Map<String, dynamic>)
              AnalysisLinkedSalesOrderLine.fromJson(raw),
        ],
      );
}

/// 订单货品行 (纯数量口径)。
class AnalysisLinkedSalesOrderLine {
  const AnalysisLinkedSalesOrderLine({
    required this.orderItemId,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.qty = 0,
    this.shippedQty = 0,
    this.returnedQty = 0,
    this.flagQty = 0,
    this.outstandingQty = 0,
    this.reservedQty = 0,
    this.plannedQty = 0,
    this.producedQty = 0,
    this.unplannedQty = 0,
    this.deliverDate,
    this.chainStatus,
    this.inAnalysis = false,
  });

  final String orderItemId;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;

  /// 订货量。
  final double qty;
  final double shippedQty;
  final double returnedQty;

  /// 核销量 (结案扣减项)。
  final double flagQty;

  /// 未交付量 = 订货 − 已发 + 已退 − 核销。
  final double outstandingQty;
  final double reservedQty;
  final double plannedQty;
  final double producedQty;

  /// 剩余未排量 = 未交付 − 预留 − max(已排 − 已产, 0)。
  final double unplannedQty;
  final String? deliverDate;
  final int? chainStatus;

  /// 本行是否就是当前这张物料分析的来源行 (表格里高亮)。
  final bool inAnalysis;

  factory AnalysisLinkedSalesOrderLine.fromJson(Map<String, dynamic> json) =>
      AnalysisLinkedSalesOrderLine(
        orderItemId: _string(json['orderItemId']) ?? '',
        lineNo: (json['lineNo'] as num?)?.toInt(),
        goodsId: _string(json['goodsId']),
        goodsCode: _string(json['goodsCode']),
        goodsName: _string(json['goodsName']),
        spec: _string(json['spec']),
        colorId: _string(json['colorId']),
        colorName: _string(json['colorName']),
        unitId: _string(json['unitId']),
        unitName: _string(json['unitName']),
        qty: _double(json['qty']),
        shippedQty: _double(json['shippedQty']),
        returnedQty: _double(json['returnedQty']),
        flagQty: _double(json['flagQty']),
        outstandingQty: _double(json['outstandingQty']),
        reservedQty: _double(json['reservedQty']),
        plannedQty: _double(json['plannedQty']),
        producedQty: _double(json['producedQty']),
        unplannedQty: _double(json['unplannedQty']),
        deliverDate: _string(json['deliverDate']),
        chainStatus: (json['chainStatus'] as num?)?.toInt(),
        inAnalysis: json['inAnalysis'] == true,
      );
}

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0;
  return 0;
}
