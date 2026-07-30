// 钱流仓库（5 单据统一 + 应收应付台账 + 账户流水 + 报表）。
//
// 5 单据按 docType 切端点：/api/finance/{receipts|payments|expenses|incomes|bank-transfers}
// （CRUD + /{id}/approve + /{id}/reverse）。
// 应收应付台账 /api/finance/ar-ap（只读分页 + 详情）。
// 账户流水 /api/finance/reconciliations（只读分页）。
// 报表 /api/finance/reports/*（只读列表，4 大类）。
//
// 端点路径常量化在文件顶部（暂不进 api_endpoints.dart，由用户统一接线时再迁）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/finance_doc.dart';

/// 钱流端点（基址 /api，由 ApiClient 注入）。
abstract final class FinanceEndpoints {
  static String docBase(String seg) => '/finance/$seg';
  static String docOne(String seg, String id) => '/finance/$seg/$id';
  static String docApprove(String seg, String id) => '/finance/$seg/$id/approve';
  static String docReverse(String seg, String id) => '/finance/$seg/$id/reverse';

  static const arAp = '/finance/ar-ap';
  static String arApOne(String id) => '/finance/ar-ap/$id';

  static const reconciliations = '/finance/reconciliations';

  static const reports = '/finance/reports';
}

// ===== 5 单据仓库（按 docType family）=====

class FinanceDocFilter {
  const FinanceDocFilter({
    this.keyword,
    this.partyId, // receipt→clientId / payment→supplierId
    this.accountId,
    this.outAccountId, // bankTransfer
    this.departmentId, // expense/income
    this.status,
    this.dateFrom,
    this.dateTo,
  });
  final String? keyword;
  final String? partyId;
  final String? accountId;
  final String? outAccountId;
  final String? departmentId;
  final int? status;
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;
}

class FinanceRepository {
  FinanceRepository(this.api, this.type);
  final ApiClient api;
  final FinanceDocType type;

  String get _seg => type.pathSegment;
  String get _partyKey {
    switch (type) {
      case FinanceDocType.receipt:
        return 'clientId';
      case FinanceDocType.payment:
        return 'supplierId';
      default:
        return 'accountId';
    }
  }

  Future<PagedResult<FinanceDocListItem>> list({
    int page = 1,
    int size = 20,
    FinanceDocFilter filter = const FinanceDocFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
        'keyword': filter.keyword!.trim(),
      if (filter.partyId != null) _partyKey: filter.partyId,
      if (type == FinanceDocType.bankTransfer && filter.outAccountId != null)
        'outAccountId': filter.outAccountId,
      if (type != FinanceDocType.bankTransfer && filter.accountId != null)
        'accountId': filter.accountId,
      if ((type == FinanceDocType.expense ||
              type == FinanceDocType.otherIncome) &&
          filter.departmentId != null)
        'departmentId': filter.departmentId,
      if (filter.status != null) 'status': filter.status,
      if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
      if (filter.dateTo != null) 'dateTo': filter.dateTo,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get(FinanceEndpoints.docBase(_seg), query: query);
    return PagedResult.fromJson(json, FinanceDocListItem.fromJson);
  }

  Future<FinanceDocDetail> detail(String id) async {
    final json = await api.get(FinanceEndpoints.docOne(_seg, id));
    return FinanceDocDetail.fromJson(json);
  }

  Future<FinanceDocDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(FinanceEndpoints.docBase(_seg), body: body);
    return FinanceDocDetail.fromJson(json);
  }

  Future<FinanceDocDetail> update(String id, Map<String, dynamic> body) async {
    final json =
        await api.put(FinanceEndpoints.docOne(_seg, id), body: body);
    return FinanceDocDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete(FinanceEndpoints.docOne(_seg, id));
  }

  Future<FinanceDocDetail> approve(String id) async {
    final json = await api.post(FinanceEndpoints.docApprove(_seg, id));
    return FinanceDocDetail.fromJson(json);
  }

  Future<FinanceDocDetail> reverse(String id) async {
    final json = await api.post(FinanceEndpoints.docReverse(_seg, id));
    return FinanceDocDetail.fromJson(json);
  }

  /// C6 财务确认（仅费用单）：已过账的费用单确认入账（gl_status 1→2）。
  Future<FinanceDocDetail> glConfirm(String id) async {
    final json = await api.post('/finance/$_seg/$id/gl-confirm'); // ENDPOINT
    return FinanceDocDetail.fromJson(json);
  }
}

final financeRepositoryProvider =
    Provider.family<FinanceRepository, FinanceDocType>(
  (ref, type) => FinanceRepository(ref.watch(apiClientProvider), type),
);

// ===== 应收应付台账（只读）=====

class ArApFilter {
  const ArApFilter({
    this.keyword,
    this.direction, // AR / AP
    this.sourceDocType,
    this.partyId,
    this.settled,
    this.dateFrom,
    this.dateTo,
  });
  final String? keyword;
  final String? direction;
  final String? sourceDocType;
  final String? partyId;
  final bool? settled;
  final String? dateFrom;
  final String? dateTo;
}

class ArApLedgerRepository {
  ArApLedgerRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ArApLedgerItem>> list({
    int page = 1,
    int size = 20,
    ArApFilter filter = const ArApFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
        'keyword': filter.keyword!.trim(),
      if (filter.direction != null) 'direction': filter.direction,
      if (filter.sourceDocType != null) 'sourceDocType': filter.sourceDocType,
      if (filter.partyId != null) 'partyId': filter.partyId,
      if (filter.settled != null) 'settled': filter.settled,
      if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
      if (filter.dateTo != null) 'dateTo': filter.dateTo,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get(FinanceEndpoints.arAp, query: query);
    return PagedResult.fromJson(json, ArApLedgerItem.fromJson);
  }

  /// 按 direction + partyId 取未清台账（核销引入用）。
  Future<PagedResult<ArApLedgerItem>> openItemsForParty({
    required String direction,
    required String partyId,
    int size = 50,
  }) async {
    final query = <String, dynamic>{
      'page': 1,
      'size': size,
      'direction': direction,
      'partyId': partyId,
      'settled': false,
    };
    final json = await api.get(FinanceEndpoints.arAp, query: query);
    return PagedResult.fromJson(json, ArApLedgerItem.fromJson);
  }
}

final arApLedgerRepositoryProvider = Provider<ArApLedgerRepository>(
  (ref) => ArApLedgerRepository(ref.watch(apiClientProvider)),
);

// ===== 账户流水（只读）=====

class ReconciliationFilter {
  const ReconciliationFilter({
    this.keyword,
    this.accountId,
    this.sourceDocType,
    this.checkNo,
    this.dateFrom,
    this.dateTo,
  });
  final String? keyword;
  final String? accountId;
  final String? sourceDocType;
  final String? checkNo;
  final String? dateFrom; // ISO date-time
  final String? dateTo;
}

class ReconciliationRepository {
  ReconciliationRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ReconciliationItem>> list({
    int page = 1,
    int size = 20,
    ReconciliationFilter filter = const ReconciliationFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
        'keyword': filter.keyword!.trim(),
      if (filter.accountId != null) 'accountId': filter.accountId,
      if (filter.sourceDocType != null) 'sourceDocType': filter.sourceDocType,
      if (filter.checkNo != null) 'checkNo': filter.checkNo,
      if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
      if (filter.dateTo != null) 'dateTo': filter.dateTo,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json =
        await api.get(FinanceEndpoints.reconciliations, query: query);
    return PagedResult.fromJson(json, ReconciliationItem.fromJson);
  }
}

final reconciliationRepositoryProvider = Provider<ReconciliationRepository>(
  (ref) => ReconciliationRepository(ref.watch(apiClientProvider)),
);

// ===== 报表（只读，4 大类）=====

class FinanceReportRepository {
  FinanceReportRepository(this.api);
  final ApiClient api;

  // A. 应收应付类
  Future<List<ArApSummaryRow>> arApSummary({
    String? direction,
    String? partyId,
    String? dateFrom,
    String? dateTo,
    int limit = 500,
  }) async {
    final list = await api.getList('${FinanceEndpoints.reports}/ar-ap/summary',
        query: {
            if (direction != null) 'direction': direction,
            if (partyId != null) 'partyId': partyId,
            if (dateFrom != null) 'dateFrom': dateFrom,
            if (dateTo != null) 'dateTo': dateTo,
            'limit': limit,
          });
    return list.map(ArApSummaryRow.fromJson).toList();
  }

  Future<List<FinanceDocReportRow>> docDetail(
    String kind, {
    String? partyId,
    String? clientId,
    String? supplierId,
    String? accountId,
    String? departmentId,
    int? status,
    String? dateFrom,
    String? dateTo,
    int limit = 500,
  }) async {
    final list = await api.getList('${FinanceEndpoints.reports}/$kind/detail',
        query: {
            if (clientId != null) 'clientId': clientId,
            if (supplierId != null) 'supplierId': supplierId,
            if (partyId != null) 'partyId': partyId,
            if (accountId != null) 'accountId': accountId,
            if (departmentId != null) 'departmentId': departmentId,
            if (status != null) 'status': status,
            if (dateFrom != null) 'dateFrom': dateFrom,
            if (dateTo != null) 'dateTo': dateTo,
            'limit': limit,
          });
    return list.map(FinanceDocReportRow.fromJson).toList();
  }

  Future<List<FinanceDocReportRow>> docSummary(
    String kind, {
    String? clientId,
    String? supplierId,
    String? departmentId,
    String? styleId,
    String? dateFrom,
    String? dateTo,
    int limit = 500,
  }) async {
    final list = await api.getList('${FinanceEndpoints.reports}/$kind/summary',
        query: {
            if (clientId != null) 'clientId': clientId,
            if (supplierId != null) 'supplierId': supplierId,
            if (departmentId != null) 'departmentId': departmentId,
            if (styleId != null) '${kind}StyleId': styleId,
            if (dateFrom != null) 'dateFrom': dateFrom,
            if (dateTo != null) 'dateTo': dateTo,
            'limit': limit,
          });
    return list.map(FinanceDocReportRow.fromJson).toList();
  }

  // D. 账户流水类（S 报表）
  Future<List<AccountStatementRow>> accountStatement({
    required String accountId,
    String? dateFrom,
    String? dateTo,
    int limit = 1000,
  }) async {
    final list = await api.getList(
        '${FinanceEndpoints.reports}/accounts/statement',
        query: {
          'accountId': accountId,
          if (dateFrom != null) 'dateFrom': dateFrom,
          if (dateTo != null) 'dateTo': dateTo,
          'limit': limit,
        });
    return list.map(AccountStatementRow.fromJson).toList();
  }
}

final financeReportRepositoryProvider = Provider<FinanceReportRepository>(
  (ref) => FinanceReportRepository(ref.watch(apiClientProvider)),
);
