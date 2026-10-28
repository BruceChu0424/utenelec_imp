import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/search/table_column_query.dart';

class GoodsQuoteHistoryRow {
  const GoodsQuoteHistoryRow(this.data);
  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  String get quoteId => text('quoteId');
  String get orderId => text('orderId');
  bool get orderDeleted => data['orderDeleted'] == true;
}

abstract interface class GoodsQuoteHistoryRepository {
  Future<PagedResult<GoodsQuoteHistoryRow>> list(
    String goodsId, {
    int page = 1,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
  });
}

class ApiGoodsQuoteHistoryRepository implements GoodsQuoteHistoryRepository {
  ApiGoodsQuoteHistoryRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<GoodsQuoteHistoryRow>> list(
    String goodsId, {
    int page = 1,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
  }) async {
    final json = await api.get(
      '/sales/quotes/goods/${Uri.encodeComponent(goodsId)}/history',
      query: {
        'page': page,
        'size': 20,
        ...tableColumnParameters(columns, sort, ascending),
      },
    );
    return PagedResult.fromJsonResponsive(json, GoodsQuoteHistoryRow.new);
  }
}

final goodsQuoteHistoryRepositoryProvider =
    Provider<GoodsQuoteHistoryRepository>(
      (ref) => ApiGoodsQuoteHistoryRepository(ref.watch(apiClientProvider)),
    );
