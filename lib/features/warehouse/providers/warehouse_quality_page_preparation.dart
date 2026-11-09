import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_category_read.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../repositories/warehouse_quality_result_repository.dart';

class WarehouseQualityPageQuery {
  const WarehouseQualityPageQuery({
    this.page = 1,
    this.size = 40,
    this.view = WarehouseTaskView.active,
    this.receiptType,
    this.workStatus,
    this.keyword,
    this.dateFrom,
    this.dateTo,
    this.sort,
    this.order,
    this.billNo,
    this.scopeWarehouseId,
  });
  final int page;

  /// 读取批大小（完整读取逐批 50→200 透传；默认保持原 40）。
  final int size;
  final WarehouseTaskView view;
  final WarehouseIqcStockInReceiptType? receiptType;
  final WarehouseQualityWorkStatus? workStatus;
  final String? keyword,
      dateFrom,
      dateTo,
      sort,
      order,
      billNo,
      scopeWarehouseId;

  Future<PagedResult<WarehouseQualityResultTask>> _fetch(
    WarehouseQualityResultGateway repository,
  ) => repository.list(
    page: page,
    size: size,
    view: view,
    receiptType: receiptType,
    workStatus: workStatus,
    keyword: keyword,
    dateFrom: dateFrom,
    dateTo: dateTo,
    sort: sort,
    order: order,
    billNo: billNo,
    scopeWarehouseId: scopeWarehouseId,
  );

  Future<PagedResult<WarehouseQualityResultTask>> read(
    WidgetRef ref,
    WarehouseQualityResultGateway repository,
  ) => _fetch(repository);
}

Future<Map<WarehouseQualityWorkStatus, int>> readWarehouseQualityCounts(
  WidgetRef ref,
  WarehouseQualityResultGateway repository, {
  WarehouseIqcStockInReceiptType? receiptType,
  String keyword = '',
  String? scopeWarehouseId,
  bool force = false,
}) => ref
    .read(scopedCategoryReadProvider)
    .read(
      query: [
        repository,
        'quality-status-counts',
        receiptType,
        keyword.trim(),
        scopeWarehouseId,
      ],
      fetch: () => repository.statusCounts(
        receiptType: receiptType,
        keyword: keyword.trim().isEmpty ? null : keyword.trim(),
        scopeWarehouseId: scopeWarehouseId,
      ),
      force: force,
    );
