import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/goods_operation_history.dart';

abstract interface class GoodsOperationHistoryRepository {
  Future<GoodsOperationHistory> list();
  Future<GoodsOperationHistory> undo(String id, {required int expectedVersion});
  Future<GoodsOperationHistory> redo(String id, {required int expectedVersion});
}

class ApiGoodsOperationHistoryRepository
    implements GoodsOperationHistoryRepository {
  ApiGoodsOperationHistoryRepository(this.api);
  final ApiClient api;

  static const path = '/master/goods/history';

  @override
  Future<GoodsOperationHistory> list() async =>
      GoodsOperationHistory.fromJson(await api.get(path));

  Future<GoodsOperationHistory> _command(
    String id,
    String action,
    int expectedVersion,
  ) async => GoodsOperationHistory.fromJson(
    await api.post(
      '$path/${Uri.encodeComponent(id)}/$action',
      body: {'expectedVersion': expectedVersion},
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

final goodsOperationHistoryRepositoryProvider =
    Provider<GoodsOperationHistoryRepository>(
      (ref) => ApiGoodsOperationHistoryRepository(ref.watch(apiClientProvider)),
    );
