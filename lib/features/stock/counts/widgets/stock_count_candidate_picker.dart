import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/models/paged_result.dart';
import '../../../basic_data/models/goods_node.dart';
import '../../../basic_data/models/product_category_node.dart';
import '../../../basic_data/widgets/uten_goods_picker.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';

/// Reuses sales' category tree, cross-page selection and selected-items drawer.
/// The source remains the authorized single-warehouse inventory snapshot API.
Future<List<CountStockRow>> showStockCountCandidatePicker(
  BuildContext context,
  WidgetRef ref, {
  required StockCountWarehouse warehouse,
}) async {
  final source = _StockCountPickerSource(
    ref.read(stockCountRequestRepositoryProvider),
    warehouse.id,
  );
  final selected = await showUtenGoodsPickerMulti(
    context,
    ref,
    scope: UtenGoodsPickerScope.all,
    title: '添加盘点物料 · ${warehouse.name}',
    dataSource: source,
  );
  return [for (final goods in selected) source.snapshots[goods]!];
}

class _StockCountPickerSource extends UtenGoodsPickerDataSource {
  _StockCountPickerSource(this.repository, this.warehouseId);
  final StockCountRequestRepository repository;
  final String warehouseId;
  // Each option owns its snapshot; ignored old requests cannot replace it.
  final snapshots = <GoodsListItem, CountStockRow>{};

  @override
  bool get supportsRelatedSearch => true;

  @override
  Future<List<ProductCategoryNode>> tree() =>
      repository.candidateCategories(warehouseId);

  @override
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    required int page,
    String? keyword,
  }) => _load(categoryId: categoryId, keyword: keyword, page: page);

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    required int page,
  }) => _load(keyword: keyword, page: page);

  @override
  Future<Set<String>> searchCategoryIds(String keyword) =>
      repository.candidateCategoryIds(warehouseId, keyword);

  @override
  Future<PagedResult<GoodsListItem>> searchWithOptions(
    String keyword, {
    required int page,
    String? categoryId,
    bool includeRelated = false,
  }) => _load(
    page: page,
    keyword: keyword,
    categoryId: categoryId,
    includeRelated: includeRelated,
  );

  @override
  Future<Set<String>> searchCategoryIdsWithOptions(
    String keyword, {
    String? categoryId,
    bool includeRelated = false,
  }) => repository.candidateCategoryIds(
    warehouseId,
    keyword,
    categoryId: categoryId,
    includeRelated: includeRelated,
  );

  Future<PagedResult<GoodsListItem>> _load({
    String? categoryId,
    String? keyword,
    required int page,
    bool includeRelated = false,
  }) async {
    final result = await repository.candidates(
      warehouseId: warehouseId,
      categoryId: categoryId,
      keyword: keyword,
      includeRelated: includeRelated,
      page: page,
    );
    return PagedResult(
      items: [for (final row in result.items) _goods(row)],
      page: result.page,
      size: result.size,
      total: result.total,
      totalPages: result.totalPages,
    );
  }

  // The selection identity includes color, including historical stock colors.
  GoodsListItem _goods(CountStockRow row) {
    final goods = GoodsListItem(
      id: row.key,
      name: row.goodsName,
      code: row.goodsCode,
      colorId: row.colorId,
      colorName: row.colorName,
      unitId: row.unitId,
      unitName: row.unitName,
      categoryId: row.categoryId,
      searchRank: row.searchRank,
      searchMatchKind: row.searchMatchKind,
    );
    snapshots[goods] = row;
    return goods;
  }

  @override
  bool isSelectable(GoodsListItem goods) => snapshots[goods]?.canEdit ?? false;

  @override
  List<MasterColumnDef<GoodsListItem>> get pickerColumns => [
    MasterColumnDef(
      key: 'name',
      label: '物料名称',
      width: 200,
      value: (goods) => goods.name,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 130,
      value: (goods) => goods.code,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'color',
      label: '颜色',
      width: 100,
      value: (goods) => goods.colorName,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'quantity',
      label: '当前库存',
      width: 150,
      value: (goods) {
        final row = snapshots[goods];
        return row == null ? null : '${row.qty} ${row.unitName}';
      },
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'weight',
      label: '重量',
      width: 130,
      value: (goods) {
        final row = snapshots[goods];
        return row == null
            ? null
            : row.weightKg == null
            ? '未称'
            : '${row.weightKg} kg';
      },
      columnSearchEnabled: false,
    ),
  ];
}
