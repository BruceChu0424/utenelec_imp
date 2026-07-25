// 币种主档仓库：扁平分页列表（动态筛选）+ 字段 facets + 详情 + CRUD + 字典。
//
// 仿 DioColorRepository。filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/currency_node.dart';
import '../models/master_facet.dart';

abstract interface class CurrencyRepository {
  Future<PagedResult<CurrencyListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  });

  Future<CurrencyFacets> facets();

  /// 全量字典（采购单据选币种用）。
  Future<List<CurrencyListItem>> dict();

  Future<CurrencyDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioCurrencyRepository implements CurrencyRepository {
  DioCurrencyRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<CurrencyListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (keyword != null && keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
    };
    final nullFields = <String>[];
    filters.forEach((k, v) {
      if (v == kMasterFilterNullValue) {
        nullFields.add(k);
      } else {
        query[k] = v;
      }
    });
    if (nullFields.isNotEmpty) query['nullFields'] = nullFields;

    final json = await api.get(ApiEndpoints.currencies, query: query);
    return PagedResult.fromJson(json, CurrencyListItem.fromJson);
  }

  @override
  Future<CurrencyFacets> facets() async {
    final json = await api.get(ApiEndpoints.currenciesFacets);
    return CurrencyFacets.fromJson(json);
  }

  @override
  Future<List<CurrencyListItem>> dict() async {
    final list = await api.getList(ApiEndpoints.currenciesDict);
    return list.map(CurrencyListItem.fromJson).toList();
  }

  @override
  Future<CurrencyDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.currency(id));
    return CurrencyDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.currencies, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.currency(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.currency(id));
  }
}

final currencyRepositoryProvider = Provider<CurrencyRepository>(
  (ref) => DioCurrencyRepository(ref.watch(apiClientProvider)),
);
