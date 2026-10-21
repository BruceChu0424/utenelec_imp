import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import 'material_market_models.dart';

abstract interface class MaterialMarketRepository {
  Future<MaterialMarketAnalysis> analysis(String goodsId);
  Future<List<MaterialMarketBenchmark>> catalog(String goodsId);
  Future<MaterialMarketAnalysis> bind(
    String goodsId, {
    required String? seriesId,
    required int expectedVersion,
  });
}

class ApiMaterialMarketRepository implements MaterialMarketRepository {
  ApiMaterialMarketRepository(this.api);
  final ApiClient api;

  String _path(String goodsId) =>
      '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/market';

  @override
  Future<MaterialMarketAnalysis> analysis(String goodsId) async =>
      MaterialMarketAnalysis(await api.get(_path(goodsId)));

  @override
  Future<List<MaterialMarketBenchmark>> catalog(String goodsId) async =>
      (await api.getList(
        '${_path(goodsId)}/catalog',
      )).map(MaterialMarketBenchmark.new).toList(growable: false);

  @override
  Future<MaterialMarketAnalysis> bind(
    String goodsId, {
    required String? seriesId,
    required int expectedVersion,
  }) async {
    final result = MaterialMarketAnalysis(
      await api.put(
        _path(goodsId),
        body: {'seriesId': seriesId, 'expectedVersion': expectedVersion},
      ),
    );
    if (result.seriesId != seriesId ||
        result.bindingVersion! <= expectedVersion) {
      throw const FormatException('Market binding was not confirmed');
    }
    return result;
  }
}

final materialMarketRepositoryProvider = Provider<MaterialMarketRepository>(
  (ref) => ApiMaterialMarketRepository(ref.watch(apiClientProvider)),
);

/// Injectable only to verify expiry transitions without waiting in tests.
final materialMarketClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
