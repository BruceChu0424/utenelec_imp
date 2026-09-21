import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/warehouse_sales_outbound.dart';

abstract interface class WarehouseSalesOutboundGateway {
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
  });

  /// 仓库作业状态分组计数(出库任务中心「销售出库」父分类红徽章 + 小类行:
  /// 待出库红徽章 / 已出库中性括号数), 与列表同一读范围, 一次请求.
  Future<WarehouseSalesOutboundCounts> counts();

  Future<WarehouseSalesOutboundDetail> detail(String id);

  /// 一步确认出库：逐行实际库位 [stockPlaces] 与逐行实际发出仓 [lineWarehouses]
  /// (行 id → 仓 id，V631)；服务端按行解析发出仓，缺一行即拒绝。
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
    Map<String, String>? stockPlaces,
    Map<String, String?>? lineWarehouses,
  });
}

class WarehouseSalesOutboundRepository
    implements WarehouseSalesOutboundGateway {
  const WarehouseSalesOutboundRepository(this.api);

  static const _base = '/warehouse/sales-outbound';
  final ApiClient api;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
  }) async {
    final query = <String, dynamic>{
      'page': page < 1 ? 1 : page,
      'size': size.clamp(1, 100),
    };
    if (_trimmed(keyword) case final value?) query['keyword'] = value;
    if (_trimmed(warehouseWorkStatus) case final value?) {
      query['warehouseWorkStatus'] = value;
    }
    if (_trimmed(dateFrom) case final value?) query['dateFrom'] = value;
    if (_trimmed(dateTo) case final value?) query['dateTo'] = value;
    final json = await api.get(_base, query: query);
    return PagedResult.fromJson(json, WarehouseSalesOutboundSummary.fromJson);
  }

  @override
  Future<WarehouseSalesOutboundCounts> counts() async {
    final json = await api.get('$_base/counts');
    return WarehouseSalesOutboundCounts.fromJson(json);
  }

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async {
    final json = await api.get('$_base/${Uri.encodeComponent(_id(id))}');
    return WarehouseSalesOutboundDetail.fromJson(_body(json));
  }

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
    Map<String, String>? stockPlaces,
    Map<String, String?>? lineWarehouses,
  }) async {
    final lineIds = <String>{...?stockPlaces?.keys, ...?lineWarehouses?.keys};
    final body = <String, dynamic>{
      'targetStatus': targetStatus.trim().toUpperCase(),
      if (stockPlaces != null || lineWarehouses != null)
        'stockPlaces': [
          for (final lineId in lineIds)
            {
              'shipmentItemId': lineId,
              'stockPlace': stockPlaces?[lineId]?.trim() ?? '',
              'warehouseId': ?_trimmed(lineWarehouses?[lineId]),
            },
        ],
    };
    final safeReason = _trimmed(reason);
    if (safeReason != null) {
      body['reason'] = safeReason;
    }
    final json = await api.post(
      '$_base/${Uri.encodeComponent(_id(id))}/warehouse-work',
      body: body,
    );
    return WarehouseSalesOutboundDetail.fromJson(_body(json));
  }
}

Map<String, dynamic> _body(Map<String, dynamic> json) {
  return json['data'] is Map
      ? Map<String, dynamic>.from(json['data'] as Map)
      : json;
}

String _id(String value) {
  final id = value.trim();
  if (id.isEmpty) throw const FormatException('销售出库任务 id 不能为空');
  return id;
}

String? _trimmed(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

final warehouseSalesOutboundRepositoryProvider =
    Provider<WarehouseSalesOutboundGateway>((ref) {
      return WarehouseSalesOutboundRepository(ref.watch(apiClientProvider));
    });
