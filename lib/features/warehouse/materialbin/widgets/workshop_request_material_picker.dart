import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../basic_data/widgets/uten_goods_picker.dart';
import '../../../basic_data/models/goods_node.dart';
import '../../../basic_data/models/product_category_node.dart';
import '../../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

/// Same category tree, cross-page selection and confirmation as stock counting.
/// The source is the workshop's authorized request candidates, not global goods.
Future<List<WmMaterialOption>> showWorkshopRequestMaterialPickerMulti(
  BuildContext context,
  WidgetRef ref, {
  required String workshopId,
  required String workshopName,
}) async {
  final source = _WorkshopRequestPickerSource(
    ref.read(workshopMaterialRepositoryProvider),
    workshopId,
  );
  final selected = await showUtenGoodsPickerMulti(
    context,
    ref,
    scope: UtenGoodsPickerScope.all,
    title: '添加申请物料 · $workshopName',
    dataSource: source,
    readBoundary: ref.read(sensitiveReadBoundaryProvider),
  );
  return [for (final goods in selected) source.snapshots[goods]!];
}

class _WorkshopRequestPickerSource extends UtenGoodsPickerDataSource {
  _WorkshopRequestPickerSource(this.repository, this.workshopId);
  final WorkshopMaterialRepository repository;
  final String workshopId;
  // Metadata follows the DTO retained by the page cache or current selection;
  // browsing new pages must not leave a second unbounded strong-key history.
  final snapshots = Expando<WmMaterialOption>();

  @override
  bool get supportsRelatedSearch => true;
  @override
  Future<List<ProductCategoryNode>> tree() =>
      repository.requestMaterialCategories(workshopId);
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
      repository.requestMaterialCategoryIds(workshopId, keyword);
  @override
  Future<PagedResult<GoodsListItem>> searchWithOptions(
    String keyword, {
    required int page,
    String? categoryId,
    bool includeRelated = false,
  }) => _load(
    keyword: keyword,
    page: page,
    categoryId: categoryId,
    includeRelated: includeRelated,
  );
  @override
  Future<Set<String>> searchCategoryIdsWithOptions(
    String keyword, {
    String? categoryId,
    bool includeRelated = false,
  }) => repository.requestMaterialCategoryIds(
    workshopId,
    keyword,
    categoryId: categoryId,
    includeRelated: includeRelated,
  );

  Future<PagedResult<GoodsListItem>> _load({
    required int page,
    String? keyword,
    String? categoryId,
    bool includeRelated = false,
  }) async {
    final result = await repository.requestMaterials(
      workshopId,
      keyword: keyword ?? '',
      categoryId: categoryId,
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

  GoodsListItem _goods(WmMaterialOption row) {
    final goods = GoodsListItem(
      id: row.key,
      name: row.goodsName,
      code: row.goodsCode,
      colorId: row.colorId,
      colorName: row.colorName,
      unitName: row.unitName,
      categoryId: row.categoryId,
      searchRank: row.searchRank,
      searchMatchKind: row.searchMatchKind,
    );
    snapshots[goods] = row;
    return goods;
  }

  @override
  bool isSelectable(GoodsListItem goods) =>
      snapshots[goods]?.goodsId.isNotEmpty == true;
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
      label: '仓库可发',
      width: 160,
      value: (goods) {
        final row = snapshots[goods];
        return row == null
            ? null
            : '${wmQty(row.warehouseAvailableQty, maxDecimals: 4)} ${row.unitName ?? ''}';
      },
      columnSearchEnabled: false,
    ),
  ];
}

Future<WmMaterialOption?> showWorkshopRequestMaterialPicker(
  BuildContext context, {
  required String workshopId,
}) => showUtenAdaptivePanel<WmMaterialOption>(
  context: context,
  drawerWidth: 720,
  builder: (_) => _RequestMaterialPicker(workshopId: workshopId),
);

/// 搜索在服务端分页，不把前 500 种物料当成全部可选物料。
class _RequestMaterialPicker extends ConsumerStatefulWidget {
  const _RequestMaterialPicker({required this.workshopId});
  final String workshopId;

  @override
  ConsumerState<_RequestMaterialPicker> createState() =>
      _RequestMaterialPickerState();
}

class _RequestMaterialPickerState extends ConsumerState<_RequestMaterialPicker>
    with ScopedPagedReadViewMixin<_RequestMaterialPicker> {
  final _rows = MasterDataTableRowsController<WmMaterialOption>();
  PagedResult<WmMaterialOption>? _page;
  WmMaterialOption? _selected;
  SensitiveReadBoundary? _loadedBoundary;
  String? _loadedKeyword;
  String _keyword = '';
  String? _error;
  int _generation = 0;
  bool _loading = true;
  bool _rowsReady = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (old, next) {
      if (old == next) return;
      setState(() {
        _invalidate();
        _error = '账号、服务器或权限已变化，请重新搜索';
      });
    });
    _load(1);
  }

  void _invalidate() {
    ++_generation;
    _page = null;
    _selected = null;
    _loadedBoundary = null;
    _loadedKeyword = null;
    _rows.update(const []);
    _error = null;
    _loading = false;
    _rowsReady = false;
  }

  @override
  void scopedPagedReadOwnerChanged() {
    if (!mounted) return;
    setState(() {
      _invalidate();
      _error = scopedPagedReadRejection?.message;
    });
  }

  Future<void> _load(int page, {bool useCache = false}) async {
    if (!mounted) return;
    final generation = ++_generation;
    final keyword = _keyword;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _loading = true;
      _error = null;
      _rowsReady = false;
    });
    try {
      final repository = ref.read(workshopMaterialRepositoryProvider);
      final workshop = widget.workshopId;
      final result = await readScopedPage<WmMaterialOption>(
        page,
        query: [repository, workshop, keyword, boundary],
        currentQuery: () => [
          ref.read(workshopMaterialRepositoryProvider),
          widget.workshopId,
          _keyword,
          ref.read(sensitiveReadBoundaryProvider),
        ],
        useCache: useCache,
        fetchPage: (target) => repository.requestMaterials(
          workshop,
          keyword: keyword,
          page: target,
        ),
      );
      if (mounted &&
          generation == _generation &&
          boundary == ref.read(sensitiveReadBoundaryProvider)) {
        setState(() {
          _page = result;
          _loadedBoundary = boundary;
          _loadedKeyword = keyword;
          _loading = false;
        });
        _reconcileSelection(generation);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error is ApiException ? error.message : '物料未读到，请重试';
          _loading = false;
          _selected = null;
        });
      }
    }
  }

  // Page-window insertion/eviction can finish after an extra layout. Keep a
  // draft only when that settled window still contains its server candidate.
  void _reconcileSelection(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (_rows.isAppending) {
        _reconcileSelection(generation);
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      setState(() {
        final selected = _selected;
        if (selected != null) {
          _selected = _rows.items
              .where((material) => material.key == selected.key)
              .firstOrNull;
        }
        _rowsReady = true;
      });
    });
  }

  bool _canSelect(WmMaterialOption material) =>
      mounted &&
      !_loading &&
      _rowsReady &&
      _error == null &&
      _loadedBoundary == ref.read(sensitiveReadBoundaryProvider) &&
      _loadedKeyword == _keyword &&
      material.goodsId.isNotEmpty &&
      _rows.items.contains(material);

  void _select(WmMaterialOption material) {
    if (_canSelect(material)) setState(() => _selected = material);
  }

  void _confirm() {
    final material = _selected;
    if (material != null && _canSelect(material)) {
      Navigator.of(context).pop(material);
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: UtenAppBar(
      showPagePermissionAction: false,
      title: '选择申请物料',
      actions: [
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        children: [
          UtenSearchBar(
            key: const Key('wm-request-material-search'),
            hint: '搜索物料名称、编号或颜色',
            onInputChanged: (value) {
              setState(() {
                _keyword = value.trim();
                _invalidate();
                _loading = true;
              });
            },
            onChanged: (_) => _load(1),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: MasterDataTableView<WmMaterialOption>(
              columns: [
                MasterColumnDef(
                  key: 'name',
                  label: '物料名称',
                  width: 200,
                  value: (material) => material.goodsName,
                  columnSearchEnabled: false,
                ),
                MasterColumnDef(
                  key: 'code',
                  label: '编号',
                  width: 130,
                  value: (material) => material.goodsCode,
                  columnSearchEnabled: false,
                ),
                MasterColumnDef(
                  key: 'color',
                  label: '颜色',
                  width: 110,
                  value: (material) => material.colorName ?? '未指定颜色',
                  columnSearchEnabled: false,
                ),
                MasterColumnDef(
                  key: 'available',
                  label: '仓库可发',
                  width: 180,
                  value: (material) =>
                      '${wmQty(material.warehouseAvailableQty, maxDecimals: 4)} ${material.unitName ?? '未设置单位'}',
                  columnSearchEnabled: false,
                ),
              ],
              items: _page?.items ?? const [],
              rowsController: _rows,
              idOf: (material) => material.key,
              rowWidgetKeyOf: (material) =>
                  ValueKey('wm-request-material-${material.key}'),
              singleTapRows: true,
              isSelected: (material) => material.key == _selected?.key,
              onRowTap: _select,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              currentPage: _page?.page ?? 1,
              totalPages: _page?.totalPages ?? 1,
              paginationScope: (widget.workshopId, _keyword, _loadedBoundary),
              isLoading: _loading && _page == null,
              loadingMore: _loading && _page != null,
              error: _error,
              onRetry: () => _load(_page?.page ?? 1),
              onPageChange: (page) => _load(page, useCache: true),
              emptyMessage: '没有找到可申请的物料，请换个关键词',
              showFullscreenToggle: false,
              showColumnChooser: false,
              enableTextSelection: false,
            ),
          ),
        ],
      ),
    ),
    bottomNavigationBar: UtenPickerConfirmBar(
      selectedCount: _selected == null ? 0 : 1,
      selectedLabel: _selected?.displayName,
      confirmButtonKey: const Key('wm-request-material-confirm'),
      confirmEnabled: _selected != null && _canSelect(_selected!),
      onConfirm: _confirm,
    ),
  );
}
