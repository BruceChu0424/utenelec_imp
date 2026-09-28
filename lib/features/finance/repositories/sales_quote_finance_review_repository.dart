import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/sales_quote_finance_review.dart';

/// 销售报价财务核价(ADR-134)：队列 / 详情 / 改价保存 / 退回 / 确认 / 撤销确认。
///
/// 改价、退回、确认带页面看到的 [expectedRevision](乐观锁)与本人认领的 [expectedClaimId]
/// (TaskClaim SALES_QUOTE_FINANCE_REVIEW)；撤销确认只带 [expectedRevision]——已核价的报价
/// 不能认领(服务端认领只接受待核价的报价)。请求体与服务端 QuoteFinanceEditRequest /
/// QuoteFinanceDecisionRequest / QuoteActionRequest 逐字一致。
abstract interface class SalesQuoteFinanceReviewRepository {
  Future<PagedResult<SalesQuoteFinanceListItem>> list({
    required SalesQuoteFinanceState state,
    int page = 1,
    int size = 20,
    String? keyword,
  });

  Future<SalesQuoteFinanceReview> review(String quoteId);

  /// 保存改价，返回最新详情。[header] 是表头整体状态(总是带当前值，空 = 清空)；
  /// [lines] 只列改过的行。
  Future<SalesQuoteFinanceReview> saveEdits(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required SalesQuoteFinanceHeader header,
    List<SalesQuoteFinanceLineEdit> lines = const [],
  });

  /// 退回销售(原因必填，服务端字段 text)。
  Future<void> returnToSales(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required String reason,
  });

  Future<void> confirm(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
  });

  /// 撤销确认(1 → 2，未转订货单前；不认领)，返回最新详情。
  Future<SalesQuoteFinanceReview> reopen(
    String quoteId, {
    required int expectedRevision,
  });
}

class DioSalesQuoteFinanceReviewRepository
    implements SalesQuoteFinanceReviewRepository {
  const DioSalesQuoteFinanceReviewRepository(this.api);

  final ApiClient api;

  @override
  Future<PagedResult<SalesQuoteFinanceListItem>> list({
    required SalesQuoteFinanceState state,
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    final normalized = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.salesQuoteFinanceReviewList,
      query: <String, dynamic>{
        'state': state.query,
        'page': page,
        'size': size,
        if (normalized != null && normalized.isNotEmpty) 'keyword': normalized,
      },
    );
    return PagedResult.fromJson(json, SalesQuoteFinanceListItem.fromJson);
  }

  @override
  Future<SalesQuoteFinanceReview> review(String quoteId) async {
    final json = await api.get(ApiEndpoints.salesQuoteFinanceReview(quoteId));
    return SalesQuoteFinanceReview.fromJson(json);
  }

  @override
  Future<SalesQuoteFinanceReview> saveEdits(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required SalesQuoteFinanceHeader header,
    List<SalesQuoteFinanceLineEdit> lines = const [],
  }) async {
    final json = await api.put(
      ApiEndpoints.salesQuoteFinanceEdit(quoteId),
      body: quoteFinanceEditBody(
        expectedRevision: expectedRevision,
        expectedClaimId: expectedClaimId,
        header: header,
        lines: lines,
      ),
    );
    return SalesQuoteFinanceReview.fromJson(json);
  }

  @override
  Future<void> returnToSales(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required String reason,
  }) async {
    await api.post(
      ApiEndpoints.salesQuoteFinanceReturn(quoteId),
      body: quoteFinanceDecisionBody(
        expectedRevision: expectedRevision,
        expectedClaimId: expectedClaimId,
        text: reason,
      ),
    );
  }

  @override
  Future<void> confirm(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
  }) async {
    await api.post(
      ApiEndpoints.salesQuoteFinanceConfirm(quoteId),
      body: quoteFinanceDecisionBody(
        expectedRevision: expectedRevision,
        expectedClaimId: expectedClaimId,
      ),
    );
  }

  @override
  Future<SalesQuoteFinanceReview> reopen(
    String quoteId, {
    required int expectedRevision,
  }) async {
    final json = await api.post(
      ApiEndpoints.salesQuoteFinanceReopen(quoteId),
      body: quoteFinanceReopenBody(expectedRevision: expectedRevision),
    );
    return SalesQuoteFinanceReview.fromJson(json);
  }
}

/// PUT /sales/quotes/{id}/finance 请求体(服务端 QuoteFinanceEditRequest)。
Map<String, dynamic> quoteFinanceEditBody({
  required int expectedRevision,
  required String expectedClaimId,
  required SalesQuoteFinanceHeader header,
  List<SalesQuoteFinanceLineEdit> lines = const [],
}) => <String, dynamic>{
  'expectedRevision': expectedRevision,
  'expectedClaimId': expectedClaimId,
  ...header.toJson(),
  'lines': [for (final line in lines) line.toJson()],
};

/// 撤销确认请求体(服务端 QuoteActionRequest；不带认领)。
Map<String, dynamic> quoteFinanceReopenBody({required int expectedRevision}) =>
    <String, dynamic>{'expectedRevision': expectedRevision};

/// 退回 / 确认请求体(服务端 QuoteFinanceDecisionRequest；退回原因写在 text)。
Map<String, dynamic> quoteFinanceDecisionBody({
  required int expectedRevision,
  required String expectedClaimId,
  String? text,
}) {
  final trimmed = text?.trim();
  return <String, dynamic>{
    'expectedRevision': expectedRevision,
    'expectedClaimId': expectedClaimId,
    if (trimmed != null && trimmed.isNotEmpty) 'text': trimmed,
  };
}

final salesQuoteFinanceReviewRepositoryProvider =
    Provider<SalesQuoteFinanceReviewRepository>(
      (ref) =>
          DioSalesQuoteFinanceReviewRepository(ref.watch(apiClientProvider)),
    );

/// 报价核价的认领目标类型(与服务端 TaskClaimPolicy 登记一致)。
const kSalesQuoteFinanceClaimType = 'SALES_QUOTE_FINANCE_REVIEW';
