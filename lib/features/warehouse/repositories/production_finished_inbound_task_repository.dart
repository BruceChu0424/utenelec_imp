import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_finished_inbound_task.dart';
import '../../basic_data/models/master_facet.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

class ProductionFinishedInboundTaskRepository {
  const ProductionFinishedInboundTaskRepository(this.api);

  final ApiClient api;

  Future<PagedResult<ProductionFinishedInboundTask>> tasks({
    int page = 1,
    int size = 40,
    String? keyword,
    String? taskStage,
    String? warehouseId,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
    String? sort,
    String? order,
    String? taskNo,
    String? planNo,
  }) async {
    final normalized = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.productionFinishedInboundTasks,
      query: {
        'page': page,
        'size': size,
        if (normalized != null && normalized.isNotEmpty) 'keyword': normalized,
        if (taskStage != null && taskStage.isNotEmpty) 'taskStage': taskStage,
        if (warehouseId != null && warehouseId.isNotEmpty)
          'warehouseId': warehouseId,
        ...scope.queryParameters,
        // 2026-09-25 单号列统一：表头排序 + 任务单号/生产计划号表头值筛选。
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
        if (taskNo != null && taskNo.trim().isNotEmpty) 'taskNo': taskNo.trim(),
        if (planNo != null && planNo.trim().isNotEmpty) 'planNo': planNo.trim(),
      },
    );
    return PagedResult.fromJson(json, ProductionFinishedInboundTask.fromJson);
  }

  /// 产成品入库任务单号列值筛选桶（2026-09-25 单号列统一）：
  /// {taskNo:[…], planNo:[…]}，与列表同一过滤口径。
  Future<Map<String, List<MasterFacetBucket>>> taskBillNoFacets({
    String? keyword,
    String? taskStage,
    String? warehouseId,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
  }) async {
    final normalized = keyword?.trim();
    final json =
        await api.get(
              ApiEndpoints.productionFinishedInboundTaskFacets,
              query: {
                if (normalized != null && normalized.isNotEmpty)
                  'keyword': normalized,
                if (taskStage != null && taskStage.isNotEmpty)
                  'taskStage': taskStage,
                if (warehouseId != null && warehouseId.isNotEmpty)
                  'warehouseId': warehouseId,
                ...scope.queryParameters,
              },
            )
            as Map;
    return {
      'taskNo': parseFacetBuckets(json, 'taskNo'),
      'planNo': parseFacetBuckets(json, 'planNo'),
    };
  }

  Future<({int confirmedCount, bool replay, Set<String> confirmedDocumentIds})>
  confirmAll({
    required List<String> documentIds,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedInboundBatchConfirm,
      body: {'documentIds': documentIds, 'idempotencyKey': idempotencyKey},
    );
    final items = (json['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final confirmedDocumentIds = <String>{
      for (final item in items)
        if (item['documentId']?.toString().isNotEmpty == true)
          item['documentId'].toString(),
    };
    return (
      confirmedCount: (json['confirmedCount'] as num?)?.toInt() ?? items.length,
      replay: json['replay'] == true,
      confirmedDocumentIds: confirmedDocumentIds,
    );
  }

  /// 产成品登记(单张 = 1 个来源、多选 = N 个来源)：一次拉取各报工待登记的实物交接批(已登记的按只读带回)。
  Future<List<ProductionFinishedArrivalRegistration>> batchArrivalRegistrations(
    List<String> reportIds,
  ) async {
    final rows = await api.getList(
      ApiEndpoints.productionFinishedArrivalBatchBase,
      query: {'reportIds': reportIds.join(',')},
    );
    return rows
        .map(ProductionFinishedArrivalRegistration.fromJson)
        .toList(growable: false);
  }

  /// 产成品登记的唯一命令：lots = [{lotId, warehouseId, place, countedQty?, weight?}]，
  /// 服务端按「报工 x 实际仓」分组成登记批次，一个事务。
  Future<ProductionFinishedBatchRegistrationResult>
  saveArrivalRegistrationBatch(Map<String, dynamic> body) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedArrivalBatchBase,
      body: body,
    );
    return ProductionFinishedBatchRegistrationResult.fromJson(json);
  }

  /// V548 登记撤回（仅品质未处理）：原因必填，幂等键在页面弹窗生命周期内复用。
  Future<ProductionFinishedArrivalRegistration> reverseArrivalRegistration(
    String registrationId, {
    required String reason,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedArrivalReverse(registrationId),
      body: {'idempotencyKey': idempotencyKey, 'reason': reason.trim()},
    );
    return ProductionFinishedArrivalRegistration.fromJson(json);
  }
}

final productionFinishedInboundTaskRepositoryProvider =
    Provider<ProductionFinishedInboundTaskRepository>(
      (ref) =>
          ProductionFinishedInboundTaskRepository(ref.watch(apiClientProvider)),
    );
