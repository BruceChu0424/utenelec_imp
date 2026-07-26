// 仓库单据模型（8 类统一，对应后端 StockDocListItem/Detail/ItemDto，端点 /api/stock/docs）。
// 8 类 doc_type：调拨/其它入/出/领料/退料/产成品进仓/出仓/盘点（损耗空，跳过）。
// 与采购单据模型同构（主从表 + 状态机）；UUID=String，金额/数量=(json as num?)，日期=ISO 串。

import 'package:flutter/material.dart';

enum StockDocType {
  transfer('TRANSFER', '仓库调拨'),
  otherIn('OTHER_IN', '其它入库'),
  otherOut('OTHER_OUT', '其它出库'),
  draw('DRAW', '生产领料'),
  wdraw('WDRAW', '生产退料'),
  finishedIn('FINISHED_IN', '产成品进仓'),
  finishedOut('FINISHED_OUT', '产成品出仓'),
  check('CHECK', '盘点');

  const StockDocType(this.code, this.label);
  final String code;
  final String label;

  static StockDocType byCode(String c) =>
      StockDocType.values.firstWhere((e) => e.code == c, orElse: () => StockDocType.otherIn);
}

class StockDocListItem {
  const StockDocListItem({
    required this.id,
    this.docType,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.toWarehouseId,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.legacyId,
    this.assTeam,
  });
  final String id;
  final String? docType;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? toWarehouseId;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final int? legacyId;
  final String? assTeam;

  factory StockDocListItem.fromJson(Map<String, dynamic> json) => StockDocListItem(
        id: json['id'] as String,
        docType: json['docType'] as String?,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        warehouseId: json['warehouseId'] as String?,
        toWarehouseId: json['toWarehouseId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        assTeam: json['assTeam'] as String?,
      );
}

class StockDocItem {
  const StockDocItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.qty,
    this.baseQty,
    this.price,
    this.amountLocal,
    this.surplusQty,
    this.countQty,
    this.place,
    this.remark,
  });
  final String? id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? qty;
  final double? baseQty;
  final double? price;
  final double? amountLocal;
  final double? surplusQty;
  final double? countQty;
  final String? place;
  final String? remark;

  factory StockDocItem.fromJson(Map<String, dynamic> json) => StockDocItem(
        id: json['id'] as String?,
        lineNo: (json['lineNo'] as num?)?.toInt(),
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        qty: (json['qty'] as num?)?.toDouble(),
        baseQty: (json['baseQty'] as num?)?.toDouble(),
        price: (json['price'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        surplusQty: (json['surplusQty'] as num?)?.toDouble(),
        countQty: (json['countQty'] as num?)?.toDouble(),
        place: json['place'] as String?,
        remark: json['remark'] as String?,
      );
}

class StockDocDetail {
  const StockDocDetail({
    required this.id,
    this.docType,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.toWarehouseId,
    this.remark,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.assTeam,
    this.items = const [],
  });
  final String id;
  final String? docType;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? toWarehouseId;
  final String? remark;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final String? assTeam;
  final List<StockDocItem> items;

  factory StockDocDetail.fromJson(Map<String, dynamic> json) => StockDocDetail(
        id: json['id'] as String,
        docType: json['docType'] as String?,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        warehouseId: json['warehouseId'] as String?,
        toWarehouseId: json['toWarehouseId'] as String?,
        remark: json['remark'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        assTeam: json['assTeam'] as String?,
        items: (json['items'] as List?)
                ?.map((e) => StockDocItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

// 状态标签/色（与采购同：0草稿/1已审/-1红冲）
String stockStatusLabel(int? s) => const {0: '草稿', 1: '已审', -1: '红冲'}[s] ?? '—';
Color stockStatusColor(int? s, ThemeData t) =>
    s == 1 ? Colors.green : (s == -1 ? t.colorScheme.error : t.colorScheme.onSurfaceVariant);

/// 各单据类型图标。
IconData iconFor(StockDocType t) => {
      StockDocType.transfer: Icons.swap_horiz_rounded,
      StockDocType.otherIn: Icons.login_rounded,
      StockDocType.otherOut: Icons.logout_rounded,
      StockDocType.draw: Icons.outbond_outlined,
      StockDocType.wdraw: Icons.undo_outlined,
      StockDocType.finishedIn: Icons.inbox_rounded,
      StockDocType.finishedOut: Icons.outbox_rounded,
      StockDocType.check: Icons.fact_check_outlined,
    }[t]!;
