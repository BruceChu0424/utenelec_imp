// 委外领料出仓(ADR-143 §4.3)测试共用假数据: 一张领料单 = 拣货视图
// GET /warehouse/subcontract-outbound/tasks/{issueId} + 同 id 的出仓单草稿
// GET/PUT /subcontract/material-issues/{issueId}, 审核 POST .../approve,
// 整单不发 POST /warehouse/subcontract-outbound/tasks/{issueId}/return-to-draw。
// PUT 与服务端同口径: 没回传的明细行删掉(填 0 = 本次不发); 领料单被撤回 / 退回委外后
// 再读拣货视图或草稿 = 404。
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const subcontractOutboundPermissions = {
  Perm.subcontractOutboundView,
  Perm.subcontractOutboundExecute,
  Perm.subcontractMaterialIssueView,
  Perm.subcontractMaterialIssueEdit,
  Perm.subcontractMaterialIssueApprove,
};

class OutboundNames extends MasterNameService {
  OutboundNames(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'actual-leaf', name: '轨道车间'),
    WarehouseDictEntry(id: 'actual-leaf-b', name: '补充仓'),
  ];
  @override
  String warehouse(String? id) => id == 'actual-leaf'
      ? '轨道车间'
      : id == 'actual-leaf-b'
      ? '补充仓'
      : '—';
}

/// 拣货视图的一条明细(不含当前数量, 当前数量由假接口按草稿实时给出)。
Map<String, dynamic> outboundPickLine({
  required String issueItemId,
  required String planItemId,
  String goodsId = 'goods-1',
  String goodsCode = 'M-1',
  String goodsName = '直属物料',
  String colorName = '黑色',
  String unitName = '个',
  num requestedQty = 100,
  num? stockAvailableQty = 500,
  String? locationHint = 'A-01',
  String parentGoodsName = '委外件',
  String parentGoodsCode = 'SC-1',
}) => {
  'issueItemId': issueItemId,
  'planItemId': planItemId,
  'lineNo': 1,
  'parentGoodsName': parentGoodsName,
  'parentGoodsCode': parentGoodsCode,
  'goodsId': goodsId,
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'colorName': colorName,
  'unitName': unitName,
  'requestedQty': requestedQty,
  'stockAvailableQty': stockAvailableQty,
  'locationHint': locationHint,
};

/// 出仓单草稿的一条明细(货品/颜色/单位/来源链 UUID 的唯一来源)。
Map<String, dynamic> outboundDocItem({
  required String id,
  required String planItemId,
  String orderItemId = 'order-item-1',
  String goodsId = 'goods-1',
  String colorId = 'color-1',
  String unitId = 'unit-1',
  num unitRate = 1,
  num qty = 100,
  num? weight,
  String parentGoodsId = 'sc-goods-1',
  String? remark,
}) => {
  'id': id,
  'planItemId': planItemId,
  'orderItemId': orderItemId,
  'goodsId': goodsId,
  'colorId': colorId,
  'unitId': unitId,
  'unitRate': unitRate,
  'qty': qty,
  'weight': ?weight,
  'parentGoodsId': parentGoodsId,
  'remark': ?remark,
};

/// 假接口: [issues] 张领料单, 每张一条明细(可再 [addLine])。
class SubcontractOutboundFakeApi extends ApiClient {
  SubcontractOutboundFakeApi({int issues = 3}) : super(Dio()) {
    for (var index = 1; index <= issues; index++) {
      addIssue(index);
    }
  }

  final taskHeaders = <String, Map<String, dynamic>>{};
  final pickLines = <String, List<Map<String, dynamic>>>{};
  final documents = <String, Map<String, dynamic>>{};
  final updates = <String>[];
  final approvals = <String>[];
  final savedBodies = <Map<String, dynamic>>[];

  /// 退回委外(不发)的请求: (领料单 id, 请求体)。
  final returns = <(String, Map<String, dynamic>)>[];

  /// 已被委外撤回 / 已退回委外的领料单(再读 = 404)。
  final goneIssues = <String>{};
  final taskQueries = <Map<String, dynamic>>[];
  final taskReads = <String>[];
  int listRequests = 0;
  bool failNextList = false;
  Future<Map<String, dynamic>>? employeeResult;
  int employeeLookups = 0;
  bool timeoutAfterSecondApproval = false;

  void addIssue(int index) {
    final issueId = 'issue-$index';
    taskHeaders[issueId] = {
      'issueId': issueId,
      'issueBillNo': 'EC-$index',
      'planId': 'plan-$index',
      'orderId': 'order-$index',
      'orderBillNo': 'EO-$index',
      'supplierName': 'Supplier $index',
      'warehouseId': 'actual-leaf',
      'warehouseName': '轨道车间',
      'version': 3,
    };
    pickLines[issueId] = [
      outboundPickLine(
        issueItemId: 'issue-item-$index',
        planItemId: 'plan-item-$index',
        goodsId: 'goods-$index',
        goodsCode: 'M-$index',
        goodsName: '直属物料 $index',
      ),
    ];
    documents[issueId] = {
      'id': issueId,
      'billNo': 'EC-$index',
      'billDate': '2026-10-04',
      'status': 0,
      'warehouseId': 'actual-leaf',
      'supplierId': 'supplier-$index',
      'makerName': '委外小王',
      'createdAt': '2026-10-04T01:00:00Z',
      'items': [
        outboundDocItem(
          id: 'issue-item-$index',
          planItemId: 'plan-item-$index',
          orderItemId: 'order-item-$index',
          goodsId: 'goods-$index',
        ),
      ],
    };
  }

  void addLine(
    String issueId, {
    required Map<String, dynamic> pick,
    required Map<String, dynamic> item,
  }) {
    pickLines[issueId]!.add(pick);
    (documents[issueId]!['items'] as List).add(item);
  }

  Map<String, dynamic> listRow(String issueId) {
    final header = taskHeaders[issueId]!;
    return {
      ...header,
      'lineCount': pickLines[issueId]!.length,
      'materialKindCount': pickLines[issueId]!
          .map((line) => line['goodsId'])
          .toSet()
          .length,
      'submittedAt': '2026-10-04T01:00:00Z',
      'submittedByName': '委外小王',
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  /// 领料单被委外撤回(或退回委外)：服务端软删，之后读它 404。
  void withdraw(String issueId) {
    taskHeaders.remove(issueId);
    pickLines.remove(issueId);
    documents.remove(issueId);
    goneIssues.add(issueId);
  }

  static ApiException _gone() =>
      ApiException('NOT_FOUND', '委外领料出仓任务不存在或已处理', httpStatus: 404);

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    for (final issueId in goneIssues) {
      if (path == ApiEndpoints.warehouseSubcontractOutboundTask(issueId) ||
          path == '/subcontract/material-issues/$issueId') {
        throw _gone();
      }
    }
    if (employeeResult != null && path.startsWith('/org/employees/')) {
      employeeLookups++;
      return employeeResult!;
    }
    if (path == ApiEndpoints.warehouseSubcontractOutboundTasks) {
      listRequests++;
      taskQueries.add(Map<String, dynamic>.from(query ?? const {}));
      if (failNextList) {
        failNextList = false;
        throw StateError('offline');
      }
      final keyword = query?['keyword']?.toString();
      final rows = [
        for (final issueId in taskHeaders.keys)
          if (keyword == null || keyword.isEmpty || issueId.contains(keyword))
            listRow(issueId),
      ];
      return {
        'items': rows,
        'page': (query?['page'] as num?)?.toInt() ?? 1,
        'size': 20,
        'total': rows.length,
        'totalPages': 1,
      };
    }
    for (final issueId in taskHeaders.keys) {
      if (path == ApiEndpoints.warehouseSubcontractOutboundTask(issueId)) {
        taskReads.add(issueId);
        final items = (documents[issueId]!['items'] as List)
            .cast<Map<String, dynamic>>();
        return {
          ...taskHeaders[issueId]!,
          'lines': [
            for (final line in pickLines[issueId]!)
              {
                ...line,
                'qty': items.firstWhere(
                  (item) => item['id'] == line['issueItemId'],
                )['qty'],
              },
          ],
        };
      }
      if (path == '/subcontract/material-issues/$issueId') {
        return {
          ...documents[issueId]!,
          'items': [
            for (final item in documents[issueId]!['items'] as List)
              Map<String, dynamic>.from(item as Map),
          ],
        };
      }
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final issueId = path.split('/').last;
    final document = documents[issueId];
    if (!path.startsWith('/subcontract/material-issues/') || document == null) {
      throw StateError('Unexpected PUT $path');
    }
    final payload = Map<String, dynamic>.from(body! as Map);
    updates.add(issueId);
    savedBodies.add(payload);
    final items = (document['items'] as List).cast<Map<String, dynamic>>();
    final sent = (payload['items'] as List).cast<Map<String, dynamic>>();
    if (sent.isEmpty) {
      throw ApiException('CONFLICT', '整单不发请由委外人员撤回领料', httpStatus: 409);
    }
    for (final row in sent) {
      final existing = items.where((item) => item['id'] == row['id']);
      if (existing.length != 1) {
        throw ApiException('CONFLICT', '不能新增明细', httpStatus: 409);
      }
      if ((row['qty'] as num) <= 0) {
        throw ApiException(
          'VALIDATION',
          '出仓数量必须大于 0；本次不发的物料请删除该行',
          httpStatus: 400,
        );
      }
      existing.single.addAll(row);
    }
    // 没回传的行 = 本次不发: 服务端删行(拣货视图同步少一行)。
    final kept = sent.map((row) => row['id']).toSet();
    items.removeWhere((item) => !kept.contains(item['id']));
    pickLines[issueId]!.removeWhere(
      (line) => !kept.contains(line['issueItemId']),
    );
    final header = Map<String, dynamic>.from(payload)..remove('items');
    document.addAll(header);
    return get('/subcontract/material-issues/$issueId');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    for (final issueId in goneIssues) {
      if (path ==
          ApiEndpoints.warehouseSubcontractOutboundReturnToDraw(issueId)) {
        throw _gone();
      }
    }
    for (final issueId in taskHeaders.keys.toList()) {
      if (path ==
          ApiEndpoints.warehouseSubcontractOutboundReturnToDraw(issueId)) {
        returns.add((issueId, Map<String, dynamic>.from(body! as Map)));
        withdraw(issueId);
        return {'issueId': issueId, 'returned': true};
      }
    }
    if (path.startsWith('/subcontract/material-issues/') &&
        path.endsWith('/approve')) {
      final issueId = path.split('/')[3];
      approvals.add(issueId);
      documents[issueId]!['status'] = 1;
      if (issueId == 'issue-2' && timeoutAfterSecondApproval) {
        timeoutAfterSecondApproval = false;
        throw NetworkTimeoutException();
      }
      return get('/subcontract/material-issues/$issueId');
    }
    throw StateError('Unexpected POST $path');
  }
}
