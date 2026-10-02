import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';

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
  });
}

class ApiGoodsQuoteHistoryRepository implements GoodsQuoteHistoryRepository {
  ApiGoodsQuoteHistoryRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<GoodsQuoteHistoryRow>> list(
    String goodsId, {
    int page = 1,
  }) async {
    final json = await api.get(
      '/sales/quotes/goods/${Uri.encodeComponent(goodsId)}/history',
      query: {'page': page, 'size': 20},
    );
    return PagedResult.fromJson(json, GoodsQuoteHistoryRow.new);
  }
}

final goodsQuoteHistoryRepositoryProvider =
    Provider<GoodsQuoteHistoryRepository>(
      (ref) => ApiGoodsQuoteHistoryRepository(ref.watch(apiClientProvider)),
    );
