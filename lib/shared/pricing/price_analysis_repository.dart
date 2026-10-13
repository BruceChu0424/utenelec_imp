import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import 'price_analysis_models.dart';
import '../models/paged_result.dart';

abstract interface class PriceAnalysisRepository {
  Future<bool> subcontractApplicable(String goodsId);
  Future<Map<String, dynamic>> historyFacets(
    String goodsId,
    Map<String, dynamic> query,
  );
  Future<Map<String, dynamic>> subcontractSuppliers(
    String goodsId,
    Map<String, dynamic> query,
  );
  Future<PagedResult<PriceObservation>> historyTable(
    String goodsId,
    Map<String, dynamic> query,
  );
  Future<PriceObservationDetail> detail(
    String goodsId,
    String kind,
    PriceObservation row,
  );
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
  Future<bool> subcontractApplicable(String goodsId) async =>
      (await api.get(
        '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/subcontract-capability',
      ))['applicable'] ==
      true;
  @override
  Future<Map<String, dynamic>> historyFacets(
    String goodsId,
    Map<String, dynamic> query,
  ) => api.get(
    '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/history/table/facets',
    query: query,
  );
  @override
  Future<Map<String, dynamic>> subcontractSuppliers(
    String goodsId,
    Map<String, dynamic> query,
  ) => api.get(
    '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/subcontract-suppliers',
    query: query,
  );
  @override
  Future<PagedResult<PriceObservation>> historyTable(
    String goodsId,
    Map<String, dynamic> query,
  ) async {
    final result = await api.get(
      '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/history/table',
      query: query,
    );
    return PriceHistoryTableResult.fromResponse(result);
  }

  @override
  Future<PriceObservationDetail> detail(
    String goodsId,
    String kind,
    PriceObservation row,
  ) async => PriceObservationDetail(
    await api.get(
      '/master/goods/${Uri.encodeComponent(goodsId)}/price-analysis/detail',
      query: {
        'kind': kind,
        'sourceType': row.text('sourceType'),
        'sourceId': row.text('sourceId'),
        'sourceItemId': row.text('sourceItemId'),
        'expectedSourceRevision': row.text('sourceRevision'),
        if (row.text('historyVersionId').isNotEmpty)
          'historyVersionId': row.text('historyVersionId'),
      },
    ),
  );
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
