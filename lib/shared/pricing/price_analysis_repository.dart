import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import 'price_analysis_models.dart';

abstract interface class PriceAnalysisRepository {
  Future<PriceHistoryPage> history(String goodsId, Map<String, dynamic> query);
  Future<GoodsPriceAnalysis> analysis(
    String goodsId,
    Map<String, dynamic> query,
  );
  Future<List<PriceCheckResult>> check(
    String kind,
    List<Map<String, dynamic>> items, {
    String? excludeOrderId,
    CancelToken? cancelToken,
  });
}

class ApiPriceAnalysisRepository implements PriceAnalysisRepository {
  ApiPriceAnalysisRepository(this.api);
  final ApiClient api;
  @override
  Future<PriceHistoryPage> history(
    String goodsId,
    Map<String, dynamic> query,
  ) async => PriceHistoryPage(
    await api.get(
      '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/history',
      query: query,
    ),
  );
  @override
  Future<GoodsPriceAnalysis> analysis(
    String goodsId,
    Map<String, dynamic> query,
  ) async => GoodsPriceAnalysis(
    await api.get(
      '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis',
      query: query,
    ),
  );
  @override
  Future<List<PriceCheckResult>> check(
    String kind,
    List<Map<String, dynamic>> items, {
    String? excludeOrderId,
    CancelToken? cancelToken,
  }) async {
    final result = await api.postCancellable(
      '/master/goods/price-analysis/check',
      cancelToken: cancelToken,
      body: {
        'kind': kind,
        'days': 180,
        'items': items,
        'excludeOrderId': ?excludeOrderId,
      },
    );
    return priceMaps(
      result['rows'],
    ).map(PriceCheckResult.new).toList(growable: false);
  }
}

final priceAnalysisRepositoryProvider = Provider<PriceAnalysisRepository>(
  (ref) => ApiPriceAnalysisRepository(ref.watch(apiClientProvider)),
);
