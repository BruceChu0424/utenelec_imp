import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/sales_return_quality.dart';

/// 销售退货质检冻结 API。
///
/// 处置端点返回整张退货单的最新投影，客户端用返回值整体替换本地快照，
/// 避免并发处置后继续展示过期余量。
class SalesReturnQualityRepository {
  SalesReturnQualityRepository(this.api);

  final ApiClient api;

  Future<List<SalesReturnQualityItem>> list(String returnId) async {
    final rows = await api.getList('/sales/returns/$returnId/quality');
    return rows.map(SalesReturnQualityItem.fromJson).toList(growable: false);
  }

  Future<List<SalesReturnQualityItem>> dispose({
    required String returnId,
    required String returnItemId,
    required SalesReturnQualityAction action,
    required double baseQty,
    required String reason,
    required String idempotencyKey,
  }) async {
    final rows = await api.postList(
      '/sales/returns/$returnId/quality/$returnItemId/dispose',
      body: {
        'action': action.code,
        'baseQty': baseQty,
        'reason': reason.trim(),
        'idempotencyKey': idempotencyKey,
      },
    );
    return rows.map(SalesReturnQualityItem.fromJson).toList(growable: false);
  }
}

final salesReturnQualityRepositoryProvider =
    Provider<SalesReturnQualityRepository>(
      (ref) => SalesReturnQualityRepository(ref.watch(apiClientProvider)),
    );
