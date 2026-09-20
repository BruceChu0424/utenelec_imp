import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../models/expense_claim.dart';
import '../models/expense_invoice.dart';
import '../models/expense_payment.dart';

/// 审批列表筛选桶所属队列（与后端 /expense-claims/facets?queue= 对齐）。
enum ApprovalFacetQueue { pending, payable, history }

abstract interface class ExpenseRepository {
  Future<PagedResult<ExpenseClaim>> listMine({
    Iterable<ExpenseClaimStatus>? statuses,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  });
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  });
  Future<PagedResult<ExpenseClaim>> listPayable({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  });
  Future<PagedResult<ExpenseClaim>> listHistory({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  });

  /// 审批/打款队列表头筛选桶（部门 / 年月），queue = pending | payable。
  /// 键与列 key 对齐：departmentName（value=部门 id，label=部门名）、yearMonth（yyyy-MM）。
  Future<Map<String, List<MasterFacetBucket>>> facets(ApprovalFacetQueue queue);

  /// 队列汇总（审批页统计卡：两队列单数/金额 + 本月提交/打款）。
  Future<ExpenseQueueSummary> summary();
  Future<ExpenseClaim> getById(String id);
  Future<ExpenseClaim> create(ExpenseClaimCreateInput input);

  /// 编辑（DRAFT/REJECTED；明细整组替换，V608）。
  Future<ExpenseClaim> update(String id, ExpenseClaimCreateInput input);
  Future<void> delete(String id, {int? expectedVersion});
  Future<ExpenseClaim?> submit(String id, {int? expectedVersion});
  Future<ExpenseClaim?> withdraw(String id, {int? expectedVersion});
  Future<ExpenseClaim?> approve(String id, {int? expectedVersion});
  Future<ExpenseClaim?> reject(
    String id,
    String reason, {
    int? expectedVersion,
  });

  /// 批量通过/驳回（V608 后端单事务全成全败，返回处理单数）。
  Future<int> approveBatch(
    Iterable<String> ids, {
    Map<String, int> expectedVersions = const {},
  });
  Future<int> rejectBatch(
    Iterable<String> ids,
    String reason, {
    Map<String, int> expectedVersions = const {},
  });
  Future<ExpenseClaim?> pay(
    String id,
    ExpensePaymentInput input, {
    int? expectedVersion,
  });

  /// 发票查重预检（登记表单即时提示，财会〔2020〕6 号防重复入账）。
  Future<ExpenseInvoiceCheckResult> checkInvoice(
    String invoiceNo, {
    String? invoiceCode,
    String? excludeClaimId,
    String? invoiceType,
    String? sellerName,
  });

  /// 发票图片 OCR 识别（预填建议；服务未配置时后端返回业务错误）。
  Future<RecognizedInvoice> recognizeInvoice(
    Uint8List bytes,
    String filename,
    String contentType,
  );

  Future<ExpenseClaim> addInvoice(
    String claimId,
    ExpenseClaimInvoiceInput input,
  );
  Future<ExpenseClaim> updateInvoice(
    String claimId,
    String invoiceId,
    ExpenseClaimInvoiceInput input,
  );

  Future<ExpenseClaim> verifyInvoice(
    String claimId,
    String invoiceId, {
    required int expectedVersion,
    required bool verified,
    required String remark,
  });

  /// 删除发票登记行（要素行删除；发票影像附件不受影响）。
  Future<void> deleteInvoice(
    String claimId,
    String invoiceId, {
    int? expectedVersion,
  });
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
    String? category,
  }) => _list(
    '$_claims/mine',
    statuses: statuses,
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
    category: category,
  );

  @override
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) => _list(
    '$_claims/pending',
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
    category: category,
  );

  @override
  Future<PagedResult<ExpenseClaim>> listPayable({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) => _list(
    '$_claims/payable',
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
    category: category,
  );

  @override
  Future<PagedResult<ExpenseClaim>> listHistory({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) => _list(
    '$_claims/history',
    page: page,
    size: size,
    year: year,
    month: month,
    departmentId: departmentId,
    category: category,
  );

  Future<PagedResult<ExpenseClaim>> _list(
    String path, {
    Iterable<ExpenseClaimStatus>? statuses,
    required int page,
    required int size,
    int? year,
    int? month,
    String? departmentId,
    String? category,
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
        // 类别表头筛选（2026-09-16）：明细项类别码（TRANSPORT/TRAVEL/...），空 = 不筛。
        if (category != null && category.isNotEmpty) 'category': category,
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
      // 类别桶（2026-09-16 扩 facets 响应）：value=类别码（明细项级别聚合）。
      'category': parse(json['categories']),
    };
  }

  @override
  Future<ExpenseQueueSummary> summary() async {
    final json = await _api.get('$_claims/summary');
    return ExpenseQueueSummary.fromJson(_requireJson(json, '报销队列汇总'));
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
  Future<ExpenseClaim> update(String id, ExpenseClaimCreateInput input) async {
    final json = await _api.put('$_claims/$id', body: input.toJson());
    return ExpenseClaim.fromJson(_requireJson(json, '报销单保存结果'));
  }

  @override
  Future<void> delete(String id, {int? expectedVersion}) =>
      _api.delete('$_claims/$id?expectedVersion=$expectedVersion');

  @override
  Future<ExpenseClaim?> submit(String id, {int? expectedVersion}) => _action(
    '$_claims/$id/submit',
    body: {'expectedVersion': expectedVersion},
  );

  @override
  Future<ExpenseClaim?> withdraw(String id, {int? expectedVersion}) => _action(
    '$_claims/$id/withdraw',
    body: {'expectedVersion': expectedVersion},
  );

  @override
  Future<ExpenseClaim?> approve(String id, {int? expectedVersion}) => _action(
    '$_claims/$id/approve',
    body: {'expectedVersion': expectedVersion},
  );

  @override
  Future<ExpenseClaim?> reject(
    String id,
    String reason, {
    int? expectedVersion,
  }) => _action(
    '$_claims/$id/reject',
    body: {'reason': reason, 'expectedVersion': expectedVersion},
  );

  @override
  Future<int> approveBatch(
    Iterable<String> ids, {
    Map<String, int> expectedVersions = const {},
  }) async {
    final json = await _api.post(
      '$_claims/approve-batch',
      body: {
        'ids': ids.toList(growable: false),
        'expectedVersions': expectedVersions,
      },
    );
    return (json['processed'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> rejectBatch(
    Iterable<String> ids,
    String reason, {
    Map<String, int> expectedVersions = const {},
  }) async {
    final json = await _api.post(
      '$_claims/reject-batch',
      body: {
        'ids': ids.toList(growable: false),
        'reason': reason,
        'expectedVersions': expectedVersions,
      },
    );
    return (json['processed'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<ExpenseClaim?> pay(
    String id,
    ExpensePaymentInput input, {
    int? expectedVersion,
  }) => _action(
    '$_claims/$id/pay',
    body: {...input.toJson(), 'expectedVersion': expectedVersion},
  );

  @override
  Future<ExpenseInvoiceCheckResult> checkInvoice(
    String invoiceNo, {
    String? invoiceCode,
    String? excludeClaimId,
    String? invoiceType,
    String? sellerName,
  }) async {
    final json = await _api.get(
      '$_claims/invoices/check',
      query: <String, dynamic>{
        'invoiceNo': invoiceNo,
        'invoiceType': ?invoiceType,
        'sellerName': ?sellerName,
        if (invoiceCode != null && invoiceCode.isNotEmpty)
          'invoiceCode': invoiceCode,
        if (excludeClaimId != null && excludeClaimId.isNotEmpty)
          'excludeClaimId': excludeClaimId,
      },
    );
    return ExpenseInvoiceCheckResult.fromJson(_requireJson(json, '发票查重'));
  }

  @override
  Future<RecognizedInvoice> recognizeInvoice(
    Uint8List bytes,
    String filename,
    String contentType,
  ) async {
    final json = await _api.postMultipartFile(
      '$_claims/invoices/recognize',
      bytes,
      filename,
      contentType,
      receiveTimeout: const Duration(seconds: 140),
    );
    return RecognizedInvoice.fromJson(_requireJson(json, '发票识别'));
  }

  @override
  Future<ExpenseClaim> addInvoice(
    String claimId,
    ExpenseClaimInvoiceInput input,
  ) async {
    final json = await _api.post(
      '$_claims/$claimId/invoices',
      body: input.toJson(),
    );
    return ExpenseClaim.fromJson(_requireJson(json, '发票登记'));
  }

  @override
  Future<ExpenseClaim> updateInvoice(
    String claimId,
    String invoiceId,
    ExpenseClaimInvoiceInput input,
  ) async {
    final json = await _api.put(
      '$_claims/$claimId/invoices/$invoiceId',
      body: input.toJson(),
    );
    return ExpenseClaim.fromJson(_requireJson(json, '发票修改'));
  }

  @override
  Future<void> deleteInvoice(
    String claimId,
    String invoiceId, {
    int? expectedVersion,
  }) => _api.delete(
    '$_claims/$claimId/invoices/$invoiceId?expectedVersion=$expectedVersion',
  );

  @override
  Future<ExpenseClaim> verifyInvoice(
    String claimId,
    String invoiceId, {
    required int expectedVersion,
    required bool verified,
    required String remark,
  }) async {
    final json = await _api.post(
      '$_claims/$claimId/invoices/$invoiceId/verify',
      body: {
        'expectedVersion': expectedVersion,
        'result': verified ? 'VERIFIED_MANUAL' : 'MISMATCH',
        'remark': remark,
      },
    );
    return ExpenseClaim.fromJson(_requireJson(json, '凭证查验登记'));
  }

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
