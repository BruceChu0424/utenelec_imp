import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// IQC 待检单聚合行（仍有 PENDING/PARTIAL 明细的采购/委外收货单）。
class PendingInspectionReceipt {
  const PendingInspectionReceipt({
    required this.receiptType,
    required this.receiptId,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.itemCount = 0,
    this.pendingBaseQty,
    this.firstReceivedAt,
    this.lastReceivedAt,
  });

  final String receiptType; // PURCHASE / SUBCONTRACT
  final String receiptId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final int itemCount;
  final double? pendingBaseQty;
  final String? firstReceivedAt;
  final String? lastReceivedAt;

  bool get isSubcontract => receiptType == 'SUBCONTRACT';

  factory PendingInspectionReceipt.fromJson(Map<String, dynamic> json) =>
      PendingInspectionReceipt(
        receiptType: json['receiptType'] as String? ?? 'PURCHASE',
        receiptId: json['receiptId'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        supplierName: json['supplierName'] as String?,
        warehouseId: json['warehouseId'] as String?,
        itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
        pendingBaseQty: (json['pendingBaseQty'] as num?)?.toDouble(),
        firstReceivedAt: json['firstReceivedAt'] as String?,
        lastReceivedAt: json['lastReceivedAt'] as String?,
      );
}

/// IQC 待检明细行（收货单维度下钻；含货品/颜色/来源订货单号溯源）。
class ProcurementInspectionItem {
  const ProcurementInspectionItem({
    required this.id,
    this.receiptItemId,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitRate,
    this.receivedBaseQty,
    this.passedBaseQty,
    this.failedBaseQty,
    this.remainingBaseQty,
    this.status,
    this.sourceOrderNo,
  });

  final String id;
  final String? receiptItemId;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitId;
  final double? unitRate;
  final double? receivedBaseQty;
  final double? passedBaseQty;
  final double? failedBaseQty;
  final double? remainingBaseQty;
  final String? status; // PENDING / PARTIAL / RESOLVED / REVERSED
  final String? sourceOrderNo;

  factory ProcurementInspectionItem.fromJson(Map<String, dynamic> json) =>
      ProcurementInspectionItem(
        id: json['id'] as String,
        receiptItemId: json['receiptItemId'] as String?,
        goodsId: json['goodsId'] as String?,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorName: json['colorName'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: (json['unitRate'] as num?)?.toDouble(),
        receivedBaseQty: (json['receivedBaseQty'] as num?)?.toDouble(),
        passedBaseQty: (json['passedBaseQty'] as num?)?.toDouble(),
        failedBaseQty: (json['failedBaseQty'] as num?)?.toDouble(),
        remainingBaseQty: (json['remainingBaseQty'] as num?)?.toDouble(),
        status: json['status'] as String?,
        sourceOrderNo: json['sourceOrderNo'] as String?,
      );
}

abstract interface class ProcurementInspectionRepository {
  Future<List<PendingInspectionReceipt>> pendingReceipts();

  /// 待检处置角标：仍有 PENDING/PARTIAL 明细的收货单张数。
  Future<int> pendingCount();

  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  );

  /// PASS 合格放行（进可用库存 + 整单结案后唤醒生产）/ FAIL 不合格（只记事实）。
  /// baseQty 可空 = 全部剩余待检量；reason 必填；idempotencyKey 必填（服务端幂等）。
  Future<void> dispose({
    required String receiptType,
    required String receiptId,
    required String inspectionItemId,
    required String action,
    double? baseQty,
    required String reason,
    required String idempotencyKey,
  });
}

class DioProcurementInspectionRepository
    implements ProcurementInspectionRepository {
  const DioProcurementInspectionRepository(this.api);

  final ApiClient api;

  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async {
    final rows = await api.getList(
      ApiEndpoints.procurementInspectionPendingReceipts,
    );
    return rows.map(PendingInspectionReceipt.fromJson).toList();
  }

  @override
  Future<int> pendingCount() async {
    final json = await api.get(ApiEndpoints.procurementInspectionPendingCount);
    final value = json['count'];
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async {
    final rows = await api.getList(
      ApiEndpoints.procurementInspectionItems(receiptType, receiptId),
    );
    return rows.map(ProcurementInspectionItem.fromJson).toList();
  }

  @override
  Future<void> dispose({
    required String receiptType,
    required String receiptId,
    required String inspectionItemId,
    required String action,
    double? baseQty,
    required String reason,
    required String idempotencyKey,
  }) async {
    await api.post(
      ApiEndpoints.procurementInspectionDispose(
        receiptType,
        receiptId,
        inspectionItemId,
      ),
      body: {
        'action': action,
        'baseQty': baseQty,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
      },
    );
  }
}

final procurementInspectionRepositoryProvider =
    Provider<ProcurementInspectionRepository>(
      (ref) => DioProcurementInspectionRepository(ref.read(apiClientProvider)),
    );
