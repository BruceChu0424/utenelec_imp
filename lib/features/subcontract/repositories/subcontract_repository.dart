// 委外单据仓库（8 单据统一，按 docType 切端点）。
//
// 端点 /api/subcontract/{inquiries|applications|orders|receipts|returns|material-issues|
// material-returns|wastes}（CRUD + /{id}/approve + /{id}/reverse）。
// create/update 收 Map body（编辑页组装 header+items）。
// 报表端点：/api/subcontract/reports/{monthly,in-out-status}。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/subcontract_doc.dart';

class SubcontractDocFilter {
  const SubcontractDocFilter({
    this.keyword,
    this.supplierId,
    this.warehouseId,
    this.status,
    this.dateFrom,
    this.dateTo,
    this.closed,
  });
  final String? keyword;
  final String? supplierId;
  final String? warehouseId;
  final int? status;
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;

  /// 结案筛选（仅委外订货单）：false=未完成（部分入库）/ true=已结案
  final bool? closed;

  Map<String, dynamic> toQuery() => <String, dynamic>{
    if (keyword != null && keyword!.trim().isNotEmpty)
      'keyword': keyword!.trim(),
    if (supplierId != null) 'supplierId': supplierId,
    if (warehouseId != null) 'warehouseId': warehouseId,
    if (status != null) 'status': status,
    if (dateFrom != null) 'dateFrom': dateFrom,
    if (dateTo != null) 'dateTo': dateTo,
    if (closed != null) 'closed': closed,
  };
}

class SubcontractRepository {
  SubcontractRepository(this.api, this.type);
  final ApiClient api;
  final SubcontractDocType type;

  String get pathSegment => type.pathSegment;
  String get _base => '/subcontract/$pathSegment';
  String _doc(String id) => '/subcontract/$pathSegment/$id';

  Future<PagedResult<SubcontractDocListItem>> list({
    int page = 1,
    int size = 20,
    SubcontractDocFilter filter = const SubcontractDocFilter(),
    String? sort,
    String? order,
  }) async {
    final json = await api.get(
      _base,
      query: {
        'page': page,
        'size': size,
        ...filter.toQuery(),
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return PagedResult.fromJson(json, SubcontractDocListItem.fromJson);
  }

  Future<SubcontractDocDetail> detail(String id) async {
    final json = await api.get(_doc(id));
    return SubcontractDocDetail.fromJson(json);
  }

  Future<List<SubcontractDecompositionLine>> decompositionPreview(
    Iterable<String> itemIds,
  ) async {
    final rows = await api.postList(
      '/subcontract/applications/decomposition-preview',
      body: {'itemIds': itemIds.toSet().toList(growable: false)},
    );
    return rows
        .map(SubcontractDecompositionLine.fromJson)
        .toList(growable: false);
  }

  Future<SubcontractDocDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(_base, body: body);
    return SubcontractDocDetail.fromJson(json);
  }

  /// 按明细级委外商自动拆单创建（仅订货单用），返回生成的多张订货单。
  Future<List<SubcontractDocDetail>> createBatch(
    Map<String, dynamic> body,
  ) async {
    final json = await api.post('$_base/batch', body: body);
    final List<dynamic> list = json['items'] as List? ?? const [];
    return [
      for (final entry in list)
        SubcontractDocDetail.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<SubcontractDocDetail> update(
    String id,
    Map<String, dynamic> body,
  ) async {
    final json = await api.put(_doc(id), body: body);
    return SubcontractDocDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete(_doc(id));
  }

  Future<SubcontractDocDetail> approve(String id) async {
    final json = await api.post('${_doc(id)}/approve');
    return SubcontractDocDetail.fromJson(json);
  }

  Future<SubcontractDocDetail> submitFinance(String id) async {
    final json = await api.post('${_doc(id)}/submit-finance');
    return SubcontractDocDetail.fromJson(json);
  }

  Future<SubcontractDocDetail> approveFinance(
    String id, {
    required int expectedVersion,
  }) async {
    final json = await api.post(
      '${_doc(id)}/approve',
      body: {'expectedVersion': expectedVersion},
    );
    return SubcontractDocDetail.fromJson(json);
  }

  Future<SubcontractDocDetail> rejectFinance(
    String id, {
    required int expectedVersion,
    required String reason,
  }) async {
    final json = await api.post(
      '${_doc(id)}/reject',
      body: {'expectedVersion': expectedVersion, 'reason': reason.trim()},
    );
    return SubcontractDocDetail.fromJson(json);
  }

  Future<SubcontractDocDetail> reverse(String id) async {
    final json = await api.post('${_doc(id)}/reverse');
    return SubcontractDocDetail.fromJson(json);
  }
}

/// 报表仓库（独立于单据 family，端点 /api/subcontract/reports/*）。
class SubcontractReportRepository {
  SubcontractReportRepository(this.api);
  final ApiClient api;

  /// 月度汇总（MV 上卷；docType 取值见 kSubcontractReportDocTypes）。
  /// 注：前端已改用 9 张参数化报表（/reports/{doc}/{view} + /in-out-status，返回 ReportTableResponse），
  /// 本 monthly 兜底保留，不再在 UI 暴露入口。
  Future<List<Map<String, dynamic>>> monthly({
    String? docType,
    String? dateFrom,
    String? dateTo,
    int limit = 200,
  }) async {
    final list = await api.getList(
      '/subcontract/reports/monthly',
      query: {
        'docType': ?docType,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'limit': limit,
      },
    );
    return list;
  }
}

/// 按 docType 的单据仓库 family。
final subcontractRepositoryProvider =
    Provider.family<SubcontractRepository, SubcontractDocType>(
      (ref, type) => SubcontractRepository(ref.watch(apiClientProvider), type),
    );

/// 报表仓库单例。
final subcontractReportRepositoryProvider =
    Provider<SubcontractReportRepository>(
      (ref) => SubcontractReportRepository(ref.watch(apiClientProvider)),
    );
