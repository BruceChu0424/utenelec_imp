// 车间内料仓用量报表与结算仓库 (ADR-131；后端 /api/workshop-material)。
//
// 只读报表 + 两个结算动作 (立即重试 / 撤销结算)。撤销结算要再认证：服务端回
// 403 REAUTH_REQUIRED 时由网络层统一弹「重新输入密码」框，拿到凭证后原请求重发
// (StepUpInterceptor)，这里不用管。
//
// 写接口都带幂等键：同一次动作重试得到同一个键 (响应丢了再点，服务端返回原结果)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/models/paged_result.dart';
import '../models/workshop_material_report_models.dart';

abstract interface class WorkshopMaterialReportRepository {
  /// 有内料仓的车间 (报表按车间成员范围由服务端过滤)。
  Future<List<WmReportBin>> bins();

  /// 某内料仓的期间列表。
  Future<List<WmReportPeriod>> periods(String binId);

  Future<WmReportCloseStatus> closeStatus(String periodId);

  /// 立即重试结算 (服务端受理后异步结算，返回当时的结算状态)。
  Future<WmReportCloseStatus> retryClose(WmReportCloseStatus current);

  /// 撤销结算 (需再认证；撤销后保留 24 小时，改完点「重新结算」或到时自动重结)。
  Future<WmReportCloseStatus> reopen(
    String periodId, {
    required int? expectedVersion,
    required String reason,
  });

  Future<List<WmBinUsageRow>> binUsage(
    String binId, {
    String? from,
    String? to,
  });

  Future<List<WmProductUsageRow>> productUsage(
    String binId, {
    String? from,
    String? to,
  });

  /// 浪费率趋势；[goodsId] 为空 = 本仓全部主料。
  Future<List<WmWasteTrendPoint>> wasteTrend(String binId, {String? goodsId});

  Future<List<WmMissingWeightRow>> missingWeights(String binId);

  Future<PagedResult<WmLedgerRow>> ledger(
    String binId, {
    String? from,
    String? to,
    int page = 1,
    int size = 50,
  });
}

class DioWorkshopMaterialReportRepository
    implements WorkshopMaterialReportRepository {
  DioWorkshopMaterialReportRepository(this.api);
  final ApiClient api;

  Map<String, dynamic> _range(String binId, String? from, String? to) => {
    'binId': binId,
    'from': ?from,
    'to': ?to,
  };

  @override
  Future<List<WmReportBin>> bins() async {
    final list = await api.getList(ApiEndpoints.workshopMaterialSettings);
    return [for (final json in list) ?WmReportBin.fromSettingsJson(json)];
  }

  @override
  Future<List<WmReportPeriod>> periods(String binId) async {
    // 服务端回 {periods:[...]}。
    final json = await api.get(
      ApiEndpoints.workshopMaterialPeriods,
      query: {'binId': binId},
    );
    final list = json['periods'];
    return list is List
        ? list
              .whereType<Map<String, dynamic>>()
              .map(WmReportPeriod.fromJson)
              .toList()
        : const [];
  }

  @override
  Future<WmReportCloseStatus> closeStatus(String periodId) async {
    final json = await api.get(
      ApiEndpoints.workshopMaterialCloseStatus(periodId),
    );
    return WmReportCloseStatus.fromJson(json, periodId: periodId);
  }

  @override
  Future<WmReportCloseStatus> retryClose(WmReportCloseStatus current) async {
    // 以当时的尝试次数与时间为内容：同一次点击重试同键，下一次重试换新键。
    final key = businessIdempotencyKey(
      'wm-close-retry',
      '${current.periodId}|${current.attempts}|${current.attemptedAt ?? ''}',
    );
    final json = await api.post(
      ApiEndpoints.workshopMaterialCloseRetry(current.periodId),
      body: {'idempotencyKey': key},
    );
    return WmReportCloseStatus.fromJson(json, periodId: current.periodId);
  }

  @override
  Future<WmReportCloseStatus> reopen(
    String periodId, {
    required int? expectedVersion,
    required String reason,
  }) async {
    final key = businessIdempotencyKey(
      'wm-close-reopen',
      '$periodId|${expectedVersion ?? ''}|$reason',
    );
    final json = await api.post(
      ApiEndpoints.workshopMaterialReopen(periodId),
      body: {
        'expectedVersion': expectedVersion,
        'reason': reason,
        'idempotencyKey': key,
      },
    );
    return WmReportCloseStatus.fromJson(json, periodId: periodId);
  }

  @override
  Future<List<WmBinUsageRow>> binUsage(
    String binId, {
    String? from,
    String? to,
  }) async {
    final list = await api.getList(
      ApiEndpoints.workshopMaterialReport('bin-usage'),
      query: _range(binId, from, to),
    );
    return list.map(WmBinUsageRow.fromJson).toList();
  }

  @override
  Future<List<WmProductUsageRow>> productUsage(
    String binId, {
    String? from,
    String? to,
  }) async {
    final list = await api.getList(
      ApiEndpoints.workshopMaterialReport('product-usage'),
      query: _range(binId, from, to),
    );
    return list.map(WmProductUsageRow.fromJson).toList();
  }

  @override
  Future<List<WmWasteTrendPoint>> wasteTrend(
    String binId, {
    String? goodsId,
  }) async {
    final list = await api.getList(
      ApiEndpoints.workshopMaterialReport('waste-trend'),
      query: {'binId': binId, 'goodsId': ?goodsId},
    );
    return list.map(WmWasteTrendPoint.fromJson).toList();
  }

  @override
  Future<List<WmMissingWeightRow>> missingWeights(String binId) async {
    final list = await api.getList(
      ApiEndpoints.workshopMaterialReport('missing-weights'),
      query: {'binId': binId},
    );
    return list.map(WmMissingWeightRow.fromJson).toList();
  }

  @override
  Future<PagedResult<WmLedgerRow>> ledger(
    String binId, {
    String? from,
    String? to,
    int page = 1,
    int size = 50,
  }) async {
    final json = await api.get(
      ApiEndpoints.workshopMaterialReport('ledger'),
      query: {..._range(binId, from, to), 'page': page, 'size': size},
    );
    return PagedResult.fromJson(json, WmLedgerRow.fromJson);
  }
}

final workshopMaterialReportRepositoryProvider =
    Provider<WorkshopMaterialReportRepository>(
      (ref) =>
          DioWorkshopMaterialReportRepository(ref.watch(apiClientProvider)),
    );
