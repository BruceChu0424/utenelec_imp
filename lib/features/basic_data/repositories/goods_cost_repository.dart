import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../models/goods_cost_sheet.dart';

abstract interface class GoodsCostRepository {
  Future<Map<String, dynamic>> convertCurrency(
    Map<String, dynamic> input,
    String? targetCurrencyId,
    String targetExchangeRateToLocal,
  );
  Future<Map<String, dynamic>> importPreview(
    String goodsId,
    Uint8List bytes,
    String filename,
  );
  Future<Map<String, dynamic>> importApply(Map<String, dynamic> request);
  Future<List<Map<String, dynamic>>> list(String goodsId);
  Future<GoodsCostSheet> detail(String id);
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input);
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  });
  Future<GoodsCostSheet> confirm(String id, int version, String idempotencyKey);
  Future<GoodsCostSheet> copy(
    String id,
    int version,
    String idempotencyKey,
    String name,
  );
  Future<GoodsCostSnapshot> snapshot(
    String id,
    int version,
    String idempotencyKey,
  );
  Future<List<Map<String, dynamic>>> snapshots(String id);
  Future<GoodsCostSnapshot> snapshotDetail(String id);
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  );
  Future<Map<String, dynamic>> saveTemplate(
    Map<String, dynamic> input,
    String idempotencyKey,
  );
  Future<Map<String, dynamic>> actual(
    String goodsId,
    Map<String, dynamic> filters,
  );
}

class DioGoodsCostRepository implements GoodsCostRepository {
  DioGoodsCostRepository(this.api);
  final ApiClient api;
  static const base = '/master/goods/cost-sheets';
  @override
  Future<Map<String, dynamic>> convertCurrency(
    Map<String, dynamic> input,
    String? targetCurrencyId,
    String targetExchangeRateToLocal,
  ) => api.post(
    '$base/convert-currency',
    body: {
      'input': input,
      'targetCurrencyId': targetCurrencyId,
      'targetExchangeRateToLocal': targetExchangeRateToLocal,
    },
  );
  @override
  Future<Map<String, dynamic>> importPreview(
    String goodsId,
    Uint8List bytes,
    String filename,
  ) => api.postMultipartFile(
    '$base/import-preview?goodsId=${Uri.encodeQueryComponent(goodsId)}',
    bytes,
    filename,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  @override
  Future<Map<String, dynamic>> importApply(Map<String, dynamic> request) =>
      api.post('$base/import-apply', body: request);
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) =>
      api.getList(base, query: {'goodsId': goodsId});
  @override
  Future<GoodsCostSheet> detail(String id) async =>
      GoodsCostSheet(await api.get('$base/$id'));
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async =>
      GoodsCostCalculation(await api.post('$base/preview', body: input));
  @override
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  }) async {
    final body = {
      'input': input,
      'idempotencyKey': idempotencyKey,
      'expectedVersion': ?expectedVersion,
    };
    return GoodsCostSheet(
      id == null
          ? await api.post(base, body: body)
          : await api.put('$base/$id', body: body),
    );
  }

  Map<String, dynamic> _command(int version, String key) => {
    'expectedVersion': version,
    'idempotencyKey': key,
  };
  @override
  Future<GoodsCostSheet> confirm(
    String id,
    int version,
    String idempotencyKey,
  ) async => GoodsCostSheet(
    await api.post(
      '$base/$id/confirm',
      body: _command(version, idempotencyKey),
    ),
  );
  @override
  Future<GoodsCostSheet> copy(
    String id,
    int version,
    String idempotencyKey,
    String name,
  ) async => GoodsCostSheet(
    await api.post(
      '$base/$id/copy',
      body: {..._command(version, idempotencyKey), 'name': name},
    ),
  );
  @override
  Future<GoodsCostSnapshot> snapshot(
    String id,
    int version,
    String idempotencyKey,
  ) async => GoodsCostSnapshot(
    await api.post(
      '$base/$id/snapshots',
      body: _command(version, idempotencyKey),
    ),
  );
  @override
  Future<List<Map<String, dynamic>>> snapshots(String id) =>
      api.getList('$base/$id/snapshots');
  @override
  Future<GoodsCostSnapshot> snapshotDetail(String id) async =>
      GoodsCostSnapshot(await api.get('$base/snapshots/$id'));
  @override
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  ) => api.getList(
    '$base/templates',
    query: {'goodsId': goodsId, 'clientId': ?clientId},
  );
  @override
  Future<Map<String, dynamic>> saveTemplate(
    Map<String, dynamic> input,
    String idempotencyKey,
  ) => api.post(
    '$base/templates',
    body: {'input': input, 'idempotencyKey': idempotencyKey},
  );
  @override
  Future<Map<String, dynamic>> actual(
    String goodsId,
    Map<String, dynamic> filters,
  ) => api.get('$base/actual', query: {'goodsId': goodsId, ...filters});
}

final goodsCostRepositoryProvider = Provider<GoodsCostRepository>(
  (ref) => DioGoodsCostRepository(ref.watch(apiClientProvider)),
);
