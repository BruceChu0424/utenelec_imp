// 账户主档仓库：扁平分页列表（动态筛选）+ 字段 facets + 详情 + CRUD + 字典。
//
// 仿 DioCurrencyRepository。filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields。
// 端点路径在文件顶部常量化（暂不进 api_endpoints.dart，由用户统一接线时再迁）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/account_node.dart';
import '../models/master_facet.dart';

/// 账户端点（基址 /api，由 ApiClient 注入）。
abstract final class AccountEndpoints {
  static const base = '/master/accounts';
  static const facets = '$base/facets';
  static const dict = '$base/dict';
  static const summary = '$base/summary';
  static const balanceAdjustmentBatch =
      '/finance/account-balance-adjustments/batch';
  static const statement = '/finance/reports/account/statement';
  static String one(String id) => '$base/$id';
  static String warning(String id) => '${one(id)}/warning';
}

abstract interface class AccountRepository {
  Future<PagedResult<AccountListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  });

  Future<AccountFacets> facets();

  Future<AccountSummary> summary();

  /// 全量字典（钱流单据选账户用）。
  Future<List<AccountListItem>> dict();

  Future<AccountDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<AccountDetail> update(String id, Map<String, dynamic> body);

  Future<AccountDetail> updateWarning(String id, {String? balanceFloor});

  Future<AccountStatementPage> statement({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    String? keyword,
    int page = 1,
    int size = 50,
  });

  Future<AccountBalanceAdjustmentBatchResult> adjustBalances({
    required AccountBalanceAdjustmentScope scope,
    required String effectiveDate,
    required String reason,
    required String idempotencyKey,
    required List<AccountBalanceAdjustmentInput> items,
  });

  Future<void> delete(String id);
}

class DioAccountRepository implements AccountRepository {
  DioAccountRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<AccountListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (keyword != null && keyword.trim().isNotEmpty)
        'keyword': keyword.trim(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
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

    final json = await api.get(AccountEndpoints.base, query: query);
    return PagedResult.fromJson(json, AccountListItem.fromJson);
  }

  @override
  Future<AccountFacets> facets() async {
    final json = await api.get(AccountEndpoints.facets);
    return AccountFacets.fromJson(json);
  }

  @override
  Future<AccountSummary> summary() async {
    final json = await api.get(AccountEndpoints.summary);
    return AccountSummary.fromJson(json);
  }

  @override
  Future<List<AccountListItem>> dict() async {
    final list = await api.getList(AccountEndpoints.dict);
    return list.map(AccountListItem.fromJson).toList();
  }

  @override
  Future<AccountDetail> detail(String id) async {
    final json = await api.get(AccountEndpoints.one(id));
    return AccountDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(AccountEndpoints.base, body: body);
  }

  @override
  Future<AccountDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put(AccountEndpoints.one(id), body: body);
    return AccountDetail.fromJson(json);
  }

  @override
  Future<AccountDetail> updateWarning(String id, {String? balanceFloor}) async {
    final json = await api.patch(
      AccountEndpoints.warning(id),
      body: {'balanceFloor': balanceFloor},
    );
    return AccountDetail.fromJson(json);
  }

  @override
  Future<AccountStatementPage> statement({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    String? keyword,
    int page = 1,
    int size = 50,
  }) async {
    final json = await api.get(
      AccountEndpoints.statement,
      query: <String, dynamic>{
        'accountId': accountId,
        'dateFrom': dateFrom,
        'dateTo': dateTo,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        'page': page,
        'size': size,
      },
    );
    return AccountStatementPage.fromJson(json);
  }

  @override
  Future<AccountBalanceAdjustmentBatchResult> adjustBalances({
    required AccountBalanceAdjustmentScope scope,
    required String effectiveDate,
    required String reason,
    required String idempotencyKey,
    required List<AccountBalanceAdjustmentInput> items,
  }) async {
    final json = await api.post(
      AccountEndpoints.balanceAdjustmentBatch,
      body: <String, dynamic>{
        'scope': scope.value,
        'effectiveDate': effectiveDate,
        'reason': reason.trim(),
        'idempotencyKey': idempotencyKey,
        'items': [for (final item in items) item.toJson()],
      },
    );
    return AccountBalanceAdjustmentBatchResult.fromJson(json);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(AccountEndpoints.one(id));
  }
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => DioAccountRepository(ref.watch(apiClientProvider)),
);
