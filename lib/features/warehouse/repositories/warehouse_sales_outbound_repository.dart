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

  /// 待出库任务计数（出库任务中心/工作台角标：未交接出库的放行单）。
  Future<int> pendingCount();

  Future<WarehouseSalesOutboundDetail> detail(String id);

  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
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
  Future<int> pendingCount() async {
    final json = await api.get('$_base/count');
    final count = json['count'] ?? json['total'] ?? json['pendingCount'];
    if (count is num) return count.toInt();
    throw const FormatException('销售出库待办计数响应格式不正确');
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
  }) async {
    final body = <String, dynamic>{
      'targetStatus': targetStatus.trim().toUpperCase(),
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
