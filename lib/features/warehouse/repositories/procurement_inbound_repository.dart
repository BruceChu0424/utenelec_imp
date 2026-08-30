import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';

abstract interface class ProcurementInboundRepository {
  Future<PagedResult<InboundExpectation>> expectations({
    int page = 1,
    int size = 20,
    ProcurementInboundOrderType? orderType,
    String? keyword,
  });

  Future<int> expectationCount();

  /// 预计到货按订货类型计数（PURCHASE/SUBCONTRACT → 全量张数；类型筛选卡用）。
  Future<Map<String, int>> expectationTypeCounts();

  Future<PagedResult<ProcurementArrivalException>> warehouseExceptions({
    int page = 1,
    int size = 20,
    String? keyword,
    bool history = false,
  });

  Future<int> warehouseExceptionCount();

  /// 一键入库：财务已定案(RECEIPT_ADJUSTED)的到货异常，按财务接受量入库+立应付。
  Future<ProcurementArrivalException> stockInAccepted(String id);

  /// 到货登记一步完成（登记 + 送检审核）：仓库只登记数量/库位，币族由服务端按
  /// 来源订货单权威回填；正常保存即转品质待检，超量返回 excessQuarantined（已隔离待财务）。
  Future<WarehouseArrivalRegistration> registerArrival({
    required ProcurementInboundOrderType orderType,
    required Map<String, dynamic> body,
  });

  /// 完成中断的到货登记（断点恢复）：草稿收货单一键「继续送检」——服务端先按来源
  /// 订货单权威修复表头币族（老草稿），再走同一审核链路；仓库不进采购/委外单据页。
  Future<WarehouseArrivalRegistration> completeArrival(String receiptId);

  /// 货品资料「学习」回写：登记到货保存成功后回写库位号/系列/编码，返回 (updated, skipped)。
  Future<({int updated, int skipped})> saveGoodsProfileHints(
    List<Map<String, dynamic>> hints,
  );

  Future<PagedResult<ProcurementArrivalException>> ownerTasks({
    int page = 1,
    int size = 20,
    ProcurementInboundOrderType? orderType,
  });

  Future<int> ownerTaskCount({ProcurementInboundOrderType? orderType});

  Future<ProcurementArrivalException> ownerTaskDetail(String id);

  Future<PagedResult<ProcurementArrivalException>> financeTasks({
    int page = 1,
    int size = 20,
  });

  Future<int> financeTaskCount();

  Future<ProcurementArrivalException> financeTaskDetail(String id);

  Future<ProcurementArrivalException> financeDecide({
    required String id,
    required int expectedVersion,
    required FinanceArrivalDecision decision,
    num? customApprovedExcessQty,
    String? financeReason,
  });

  Future<ProcurementArrivalException> completeReturn({
    required String returnTaskId,
    required int expectedVersion,
    String? completionNote,
  });
}

class DioProcurementInboundRepository implements ProcurementInboundRepository {
  const DioProcurementInboundRepository(this.api);

  final ApiClient api;

  @override
  Future<PagedResult<InboundExpectation>> expectations({
    int page = 1,
    int size = 20,
    ProcurementInboundOrderType? orderType,
    String? keyword,
  }) async {
    final kw = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseInboundExpectations,
      query: {
        'page': page,
        'size': size,
        if (orderType != null) 'orderType': orderType.name.toUpperCase(),
        if (kw != null && kw.isNotEmpty) 'keyword': kw,
      },
    );
    return PagedResult.fromJson(json, InboundExpectation.fromJson);
  }

  @override
  Future<int> expectationCount() =>
      _count(ApiEndpoints.warehouseInboundExpectationCount);

  @override
  Future<Map<String, int>> expectationTypeCounts() async {
    final json = await api.get(
      ApiEndpoints.warehouseInboundExpectationTypeCounts,
    );
    return {
      for (final entry in (json as Map).entries)
        entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  @override
  Future<PagedResult<ProcurementArrivalException>> warehouseExceptions({
    int page = 1,
    int size = 20,
    String? keyword,
    bool history = false,
  }) async {
    final kw = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseArrivalExceptions,
      query: {
        'page': page,
        'size': size,
        if (history) 'history': true,
        if (kw != null && kw.isNotEmpty) 'keyword': kw,
      },
    );
    return PagedResult.fromJson(json, ProcurementArrivalException.fromJson);
  }

  @override
  Future<int> warehouseExceptionCount() =>
      _count(ApiEndpoints.warehouseArrivalExceptionCount);

  @override
  Future<ProcurementArrivalException> stockInAccepted(String id) async {
    final json = await api.post(
      ApiEndpoints.warehouseArrivalExceptionStockIn(id),
    );
    return ProcurementArrivalException.fromJson(json);
  }

  @override
  Future<WarehouseArrivalRegistration> registerArrival({
    required ProcurementInboundOrderType orderType,
    required Map<String, dynamic> body,
  }) async {
    final json = await api.post(
      ApiEndpoints.warehouseInboundArrivals,
      body: {'orderType': orderType.name.toUpperCase(), ...body},
    );
    return WarehouseArrivalRegistration.fromJson(json);
  }

  @override
  Future<WarehouseArrivalRegistration> completeArrival(String receiptId) async {
    final json = await api.post(
      ApiEndpoints.warehouseInboundArrivalComplete(receiptId),
    );
    return WarehouseArrivalRegistration.fromJson(json);
  }

  @override
  Future<({int updated, int skipped})> saveGoodsProfileHints(
    List<Map<String, dynamic>> hints,
  ) async {
    final json = await api.post(
      ApiEndpoints.warehouseInboundGoodsProfileHints,
      body: hints,
    );
    int read(String key) {
      final value = json[key];
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return (updated: read('updated'), skipped: read('skipped'));
  }

  @override
  Future<PagedResult<ProcurementArrivalException>> ownerTasks({
    int page = 1,
    int size = 20,
    ProcurementInboundOrderType? orderType,
  }) async {
    final json = await api.get(
      ApiEndpoints.procurementArrivalExceptionTasks,
      query: {
        'page': page,
        'size': size,
        if (orderType != null) 'orderType': orderType.name.toUpperCase(),
      },
    );
    return PagedResult.fromJson(json, ProcurementArrivalException.fromJson);
  }

  @override
  Future<int> ownerTaskCount({ProcurementInboundOrderType? orderType}) =>
      _count(
        ApiEndpoints.procurementArrivalExceptionTaskCount,
        query: orderType == null
            ? null
            : {'orderType': orderType.name.toUpperCase()},
      );

  @override
  Future<ProcurementArrivalException> ownerTaskDetail(String id) async {
    final json = await api.get(ApiEndpoints.procurementArrivalException(id));
    return ProcurementArrivalException.fromJson(json);
  }

  @override
  Future<PagedResult<ProcurementArrivalException>> financeTasks({
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.financeArrivalExceptionTasks,
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(json, ProcurementArrivalException.fromJson);
  }

  @override
  Future<int> financeTaskCount() =>
      _count(ApiEndpoints.financeArrivalExceptionCount);

  @override
  Future<ProcurementArrivalException> financeTaskDetail(String id) async {
    final json = await api.get(ApiEndpoints.financeArrivalException(id));
    return ProcurementArrivalException.fromJson(json);
  }

  @override
  Future<ProcurementArrivalException> financeDecide({
    required String id,
    required int expectedVersion,
    required FinanceArrivalDecision decision,
    num? customApprovedExcessQty,
    String? financeReason,
  }) async {
    final normalizedReason = financeReason?.trim();
    final json = await api.post(
      ApiEndpoints.financeArrivalExceptionDecision(id),
      body: <String, dynamic>{
        'expectedVersion': expectedVersion,
        'decision': decision.apiValue,
        if (decision == FinanceArrivalDecision.approveCustom)
          'customApprovedExcessQty': customApprovedExcessQty,
        if (normalizedReason?.isNotEmpty == true)
          'financeReason': normalizedReason,
      },
    );
    return ProcurementArrivalException.fromJson(json);
  }

  @override
  Future<ProcurementArrivalException> completeReturn({
    required String returnTaskId,
    required int expectedVersion,
    String? completionNote,
  }) async {
    final note = completionNote?.trim();
    final json = await api.post(
      ApiEndpoints.procurementArrivalReturnTaskComplete(returnTaskId),
      body: <String, dynamic>{
        'expectedVersion': expectedVersion,
        if (note?.isNotEmpty == true) 'completionNote': note,
      },
    );
    return ProcurementArrivalException.fromJson(json);
  }

  Future<int> _count(String path, {Map<String, dynamic>? query}) async {
    final json = await api.get(path, query: query);
    final value = json['count'] ?? json['total'] ?? json['pendingCount'];
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }
}

final procurementInboundRepositoryProvider =
    Provider<ProcurementInboundRepository>(
      (ref) => DioProcurementInboundRepository(ref.watch(apiClientProvider)),
    );
