// 主档批量启停 / 批量删除仓库(ADR-111)。
//
// 取代各主档页「逐条 GET 详情 + 逐条 PATCH/DELETE、catch 吞错」的循环：
// 选 100 条就是 1 次请求，服务端一个事务处理并逐条回原因。
// entityPath 传各主档的集合路径(ApiEndpoints.goods / clients / suppliers /
// moulds / colors / units / warehouses)，本仓库只拼 /batch-status 与 /batch-delete。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/master_batch.dart';

abstract interface class MasterBatchRepository {
  /// 批量启用/停用(status 只能是「使用」或「禁用」)。
  Future<MasterBatchResult> changeStatus({
    required String entityPath,
    required String status,
    required List<MasterBatchItem> items,
  });

  /// 批量删除(软删)：服务端逐条做授权、版本与引用保护，被引用的逐条说明原因。
  Future<MasterBatchResult> delete({
    required String entityPath,
    required List<MasterBatchItem> items,
  });
}

class DioMasterBatchRepository implements MasterBatchRepository {
  DioMasterBatchRepository(this.api);

  final ApiClient api;

  @override
  Future<MasterBatchResult> changeStatus({
    required String entityPath,
    required String status,
    required List<MasterBatchItem> items,
  }) async {
    final json = await api.post(
      '$entityPath/batch-status',
      body: {
        'status': status,
        'items': [for (final i in items) i.toJson()],
      },
    );
    return MasterBatchResult.fromJson(json);
  }

  @override
  Future<MasterBatchResult> delete({
    required String entityPath,
    required List<MasterBatchItem> items,
  }) async {
    final json = await api.post(
      '$entityPath/batch-delete',
      body: {
        'items': [for (final i in items) i.toJson()],
      },
    );
    return MasterBatchResult.fromJson(json);
  }
}

final masterBatchRepositoryProvider = Provider<MasterBatchRepository>(
  (ref) => DioMasterBatchRepository(ref.watch(apiClientProvider)),
);
