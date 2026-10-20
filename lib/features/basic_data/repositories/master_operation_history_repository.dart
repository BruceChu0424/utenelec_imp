import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/goods_operation_history.dart';
import 'goods_operation_history_repository.dart';

class ApiMasterOperationHistoryRepository
    implements GoodsOperationHistoryRepository {
  ApiMasterOperationHistoryRepository(this.api, this.entityType);
  final ApiClient api;
  final String entityType;
  static const path = '/master/operation-history';
  String get _query => '?entityType=${Uri.encodeQueryComponent(entityType)}';

  @override
  Future<GoodsOperationHistory> list() async => GoodsOperationHistory.fromJson(
    await api.get(path, query: {'entityType': entityType}),
  );
  Future<GoodsOperationHistory> _command(
    String id,
    String action,
    int version,
  ) async => GoodsOperationHistory.fromJson(
    await api.post(
      '$path/${Uri.encodeComponent(id)}/$action$_query',
      body: {'expectedVersion': version},
    ),
  );
  @override
  Future<GoodsOperationHistory> undo(
    String id, {
    required int expectedVersion,
  }) => _command(id, 'undo', expectedVersion);
  @override
  Future<GoodsOperationHistory> redo(
    String id, {
    required int expectedVersion,
  }) => _command(id, 'redo', expectedVersion);
}

final masterOperationHistoryRepositoryProvider =
    Provider.family<GoodsOperationHistoryRepository, String>(
      (ref, entityType) => ApiMasterOperationHistoryRepository(
        ref.watch(apiClientProvider),
        entityType,
      ),
    );
