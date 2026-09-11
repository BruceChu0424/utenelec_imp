import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../models/expense_claim.dart';
import '../models/expense_payment.dart';

/// 审批列表筛选桶所属队列（与后端 /expense-claims/facets?queue= 对齐）。
enum ApprovalFacetQueue { pending, payable }

abstract interface class ExpenseRepository {
  Future<PagedResult<ExpenseClaim>> listMine({
    Iterable<ExpenseClaimStatus>? statuses,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  });
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  });
  Future<PagedResult<ExpenseClaim>> listPayable({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  });

  /// 审批/打款队列表头筛选桶（部门 / 年月），queue = pending | payable。
  /// 键与列 key 对齐：departmentName（value=部门 id，label=部门名）、yearMonth（yyyy-MM）。
  Future<Map<String, List<MasterFacetBucket>>> facets(ApprovalFacetQueue queue);
  Future<ExpenseClaim> getById(String id);
  Future<ExpenseClaim> create(ExpenseClaimCreateInput input);
  Future<void> delete(String id);
  Future<ExpenseClaim?> submit(String id);
  Future<ExpenseClaim?> withdraw(String id);
  Future<ExpenseClaim?> approve(String id);
  Future<ExpenseClaim?> reject(String id, String reason);
  Future<ExpenseClaim?> pay(String id, ExpensePaymentInput input);
}

class DioExpenseRepository implements ExpenseRepository {
  DioExpenseRepository(this._api);

  final ApiClient _api;

  static const _claims = '/expense-claims';

  @override
  Future<PagedResult<ExpenseClaim>> listMine({
    Iterable<ExpenseClaimStatus>? statuses,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) => _list(
    '$_claims/mine',
    statuses: statuses,
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
  );

  @override
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) => _list(
    '$_claims/pending',
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
  );

  @override
  Future<PagedResult<ExpenseClaim>> listPayable({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) => _list(
    '$_claims/payable',
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
  );

  Future<PagedResult<ExpenseClaim>> _list(
    String path, {
    Iterable<ExpenseClaimStatus>? statuses,
    required int page,
    required int size,
    int? year,
    int? month,
    String? departmentId,
  }) async {
    final normalizedStatuses = statuses?.map((status) => status.apiValue);
    final json = await _api.get(
      path,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (normalizedStatuses != null && normalizedStatuses.isNotEmpty)
          'status': normalizedStatuses.join(','),
        'year': ?year,
        'month': ?month,
        if (departmentId != null && departmentId.isNotEmpty)
          'departmentId': departmentId,
      },
    );
    return PagedResult.fromJson(json, ExpenseClaim.fromJson);
  }

  @override
  Future<Map<String, List<MasterFacetBucket>>> facets(
    ApprovalFacetQueue queue,
  ) async {
    final json = await _api.get(
      '$_claims/facets',
      query: <String, dynamic>{'queue': queue.name},
    );
    List<MasterFacetBucket> parse(Object? raw) => [
      for (final e in (raw as List<dynamic>? ?? const []))
        MasterFacetBucket.fromJson(e as Map<String, dynamic>),
    ];
    return {
      'departmentName': parse(json['departments']),
      'yearMonth': parse(json['months']),
    };
  }

  @override
  Future<ExpenseClaim> getById(String id) async {
    final json = await _api.get('$_claims/$id');
    return ExpenseClaim.fromJson(_requireJson(json, '报销单详情'));
  }

  @override
  Future<ExpenseClaim> create(ExpenseClaimCreateInput input) async {
    final json = await _api.post(_claims, body: input.toJson());
    return ExpenseClaim.fromJson(_requireJson(json, '报销单创建结果'));
  }

  @override
  Future<void> delete(String id) => _api.delete('$_claims/$id');

  @override
  Future<ExpenseClaim?> submit(String id) => _action('$_claims/$id/submit');

  @override
  Future<ExpenseClaim?> withdraw(String id) => _action('$_claims/$id/withdraw');

  @override
  Future<ExpenseClaim?> approve(String id) => _action('$_claims/$id/approve');

  @override
  Future<ExpenseClaim?> reject(String id, String reason) =>
      _action('$_claims/$id/reject', body: {'reason': reason});

  @override
  Future<ExpenseClaim?> pay(String id, ExpensePaymentInput input) =>
      _action('$_claims/$id/pay', body: input.toJson());

  Future<ExpenseClaim?> _action(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final json = await _api.post(path, body: body);
    return json.isEmpty ? null : ExpenseClaim.fromJson(json);
  }
}

Map<String, dynamic> _requireJson(
  Map<String, dynamic> json,
  String responseName,
) {
  if (json.isEmpty) {
    throw FormatException('$responseName响应为空');
  }
  return json;
}

final expenseRepositoryProvider = Provider<ExpenseRepository>(
  (ref) => DioExpenseRepository(ref.watch(apiClientProvider)),
);
