// 委外领料(ADR-143)页面测试共用的假数据源：记录每次调用，按脚本返回。
import 'package:uten_imp/features/subcontract/models/subcontract_draw.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_draw_repository.dart';

class FakeSubcontractDrawGateway implements SubcontractDrawGateway {
  FakeSubcontractDrawGateway({
    List<SubcontractDrawTaskRow>? rows,
    this.canSubmitDraw = true,
    this.count = 0,
    this.submittedCount = 0,
    Map<String, int>? statusCounts,
  }) : rows = rows ?? [],
       statusCounts = statusCounts ?? const {};

  List<SubcontractDrawTaskRow> rows;
  bool canSubmitDraw;
  int count;
  int submittedCount;
  Map<String, int> statusCounts;

  /// 非空时 drawCounts 抛出它(模拟无订货查看权限等)。
  Object? countError;

  final listQueries = <Map<String, Object?>>[];
  int countCalls = 0;
  final details = <String, SubcontractDrawTaskDetail>{};
  final detailCalls = <String>[];
  final withdrawn = <List<String>>[];
  final closed = <(String, String)>[];
  final previews = <List<SubcontractDrawRequestItem>>[];
  final submits = <(List<SubcontractDrawRequestItem>, String)>[];

  /// 预览脚本；为空时按 [rows] 回一个简单预览。
  Future<SubcontractDrawPreview> Function(List<SubcontractDrawRequestItem>)?
  onPreview;
  Future<SubcontractDrawSubmitResult> Function(
    List<SubcontractDrawRequestItem> items,
    String key,
  )?
  onSubmit;

  @override
  Future<SubcontractDrawTaskList> list({
    int page = 1,
    int size = 50,
    String? keyword,
    String? status,
    String? orderId,
    List<String> orderItemIds = const [],
  }) async {
    listQueries.add({
      'page': page,
      'keyword': keyword,
      'status': status,
      'orderId': orderId,
      'orderItemIds': orderItemIds,
    });
    return SubcontractDrawTaskList.fromJson(<String, dynamic>{
      'page': <String, dynamic>{
        'items': [for (final row in rows) drawRowJson(row)],
        'page': page,
        'size': size,
        'total': rows.length,
        'totalPages': 1,
      },
      'statusCounts': statusCounts,
      'capabilities': <String, dynamic>{'canSubmitDraw': canSubmitDraw},
    });
  }

  @override
  Future<({int drawable, int submitted})> drawCounts() async {
    countCalls++;
    final error = countError;
    if (error != null) throw error;
    return (drawable: count, submitted: submittedCount);
  }

  @override
  Future<SubcontractDrawTaskDetail> detail(String orderItemId) async {
    detailCalls.add(orderItemId);
    final detail = details[orderItemId];
    if (detail == null) throw StateError('no detail for $orderItemId');
    return detail;
  }

  @override
  Future<SubcontractDrawPreview> preview(
    List<SubcontractDrawRequestItem> items,
  ) {
    previews.add(List.of(items));
    final script = onPreview;
    if (script != null) return script(items);
    throw StateError('no preview script');
  }

  @override
  Future<SubcontractDrawSubmitResult> submit({
    required List<SubcontractDrawRequestItem> items,
    required String idempotencyKey,
  }) {
    submits.add((List.of(items), idempotencyKey));
    final script = onSubmit;
    if (script != null) return script(items, idempotencyKey);
    return Future.value(
      const SubcontractDrawSubmitResult(
        issueIds: ['issue-1'],
        issueBillNos: ['WF-1'],
        documentCount: 1,
        replayed: false,
      ),
    );
  }

  @override
  Future<SubcontractDrawWithdrawResult> withdraw(
    List<String> orderItemIds,
  ) async {
    withdrawn.add(List.of(orderItemIds));
    return const SubcontractDrawWithdrawResult(
      withdrawnIssueIds: ['issue-1'],
      removedLineCount: 2,
    );
  }

  @override
  Future<void> close(String orderItemId, String reason) async {
    closed.add((orderItemId, reason));
  }
}

/// 一行「领料」任务(经 fromJson 构造，与服务端字段同名)。
SubcontractDrawTaskRow drawRow(
  String orderItemId, {
  String status = 'DRAWABLE',
  String orderId = 'order-1',
  String orderBillNo = 'WD-001',
  String goodsName = '委外件A',
  String goodsCode = 'SC-A',
  String unitName = '个',
  num orderQty = 100,
  num drawnQty = 0,
  num pendingQty = 0,
  num drawableQty = 40,
  num shortQty = 60,
  int materialKindCount = 2,
  int readyKindCount = 1,
  int unplannedShortKindCount = 0,
  bool canDraw = true,
  String? planNo,
}) => SubcontractDrawTaskRow.fromJson(<String, dynamic>{
  'orderItemId': orderItemId,
  'orderId': orderId,
  'orderBillNo': orderBillNo,
  'lineNo': 1,
  'supplierId': 'supplier-1',
  'supplierName': '华信加工',
  'goodsId': 'goods-$orderItemId',
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'colorId': 'color-1',
  'colorName': '本色',
  'unitId': 'unit-1',
  'unitName': unitName,
  'orderQty': orderQty,
  'drawnQty': drawnQty,
  'pendingQty': pendingQty,
  'drawableQty': drawableQty,
  'shortQty': shortQty,
  'materialKindCount': materialKindCount,
  'readyKindCount': readyKindCount,
  'shortKindCount': materialKindCount - readyKindCount,
  'unplannedShortKindCount': unplannedShortKindCount,
  'status': status,
  'deliverDate': '2026-10-20',
  'canDraw': canDraw,
  'planNo': ?planNo,
});

Map<String, dynamic> drawRowJson(SubcontractDrawTaskRow row) =>
    <String, dynamic>{
      'orderItemId': row.orderItemId,
      'orderId': row.orderId,
      'orderBillNo': row.orderBillNo,
      'lineNo': row.lineNo,
      'supplierId': row.supplierId,
      'supplierName': row.supplierName,
      'goodsId': row.goodsId,
      'goodsCode': row.goodsCode,
      'goodsName': row.goodsName,
      'colorId': row.colorId,
      'colorName': row.colorName,
      'unitId': row.unitId,
      'unitName': row.unitName,
      'orderQty': row.orderQty,
      'drawnQty': row.drawnQty,
      'pendingQty': row.pendingQty,
      'drawableQty': row.drawableQty,
      'shortQty': row.shortQty,
      'materialKindCount': row.materialKindCount,
      'readyKindCount': row.readyKindCount,
      'shortKindCount': row.shortKindCount,
      'unplannedShortKindCount': row.unplannedShortKindCount,
      'status': row.status.wireName,
      'deliverDate': row.deliverDate,
      'canDraw': row.canDraw,
      'planNo': ?row.planNo,
    };

/// 预览任务行。
Map<String, dynamic> previewTaskJson(
  String orderItemId, {
  num batchDrawableQty = 40,
  num? qty,
  num drawnQty = 0,
  num drawableQty = 40,
  String orderBillNo = 'WD-001',
  String goodsName = '委外件A',
}) => <String, dynamic>{
  'orderItemId': orderItemId,
  'orderId': 'order-$orderItemId',
  'orderBillNo': orderBillNo,
  'lineNo': 1,
  'supplierName': '华信加工',
  'goodsId': 'goods-$orderItemId',
  'goodsCode': 'SC-$orderItemId',
  'goodsName': goodsName,
  'colorName': '本色',
  'unitName': '个',
  'orderQty': 100,
  'drawnQty': drawnQty,
  'drawableQty': drawableQty,
  'batchDrawableQty': batchDrawableQty,
  'qty': qty ?? batchDrawableQty,
};

/// 预览物料行。
Map<String, dynamic> previewLineJson(
  String orderItemId,
  String planItemId, {
  String warehouseId = 'wh-1',
  String warehouseName = '原料仓',
  String goodsName = '物料A',
  String goodsId = 'material-a',
  num qty = 80,
  num warehouseAvailableQty = 200,
}) => <String, dynamic>{
  'orderItemId': orderItemId,
  'planItemId': planItemId,
  'warehouseId': warehouseId,
  'warehouseName': warehouseName,
  'goodsId': goodsId,
  'goodsCode': 'M-$goodsId',
  'goodsName': goodsName,
  'colorId': 'color-1',
  'colorName': '本色',
  'unitId': 'unit-kg',
  'unitName': 'kg',
  'qty': qty,
  'warehouseAvailableQty': warehouseAvailableQty,
};
