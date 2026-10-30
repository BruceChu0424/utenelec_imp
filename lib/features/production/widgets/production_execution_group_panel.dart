import 'package:uten_imp/shared/providers/native_facet_options.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/layout/uten_refresh_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import 'package:go_router/go_router.dart';

import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../models/production_material_analysis.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_execution_workbench_repository.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_navigation_session.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';

/// Planning-facing ongoing list: one row per outer analysis/root plan.
///
/// 2026-09-06 起为「大的分析」统筹视角：顶部不再提供生产车间/排序筛选
/// （关键词搜索在大类行，排序/细分信息双击进详情看）；表格只保留分析级
/// 重要列——按货品/颜色/单位统计的产品完成情况、分析批次、关联销售订单、
/// 产品、分析人、分析时间；追加生产仍归同一产品的未完成状态。
/// 工单号/车间/产品编号/数量明细等执行细节双击进物料分析页查看。
class ProductionExecutionGroupPanel extends ConsumerStatefulWidget {
  const ProductionExecutionGroupPanel({
    super.key,
    required this.keyword,
    this.refreshRevision = 0,
  });

  final String keyword;
  final int refreshRevision;

  @override
  ConsumerState<ProductionExecutionGroupPanel> createState() =>
      _ProductionExecutionGroupPanelState();
}

class _ProductionExecutionGroupPanelState
    extends ConsumerState<ProductionExecutionGroupPanel>
    with
        UtenRefreshParticipant<ProductionExecutionGroupPanel>,
        ScopedPagedReadViewMixin<ProductionExecutionGroupPanel> {
  final _navigation = PageNavigationSession();
  final _tableRows =
      MasterDataTableRowsController<ProductionExecutionWorkbenchGroup>();
  Object? _acceptedReadQuery;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
  }

  @override
  void dispose() {
    _navigation.dispose();
    super.dispose();
  }

  /// 宿主页路径(创建时捕获), 精准刷新信号只在它就在栈顶时立即重拉。
  String? _hostLocation;

  List<ProductionExecutionWorkbenchGroup> _items = const [];
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  bool _opening = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void scopedPagedReadOwnerChanged() => setState(() {
    _loadGeneration++;
    _tableRows.update(const []);
    _acceptedReadQuery = null;
    _items = const [];
    _totalPages = 0;
    _loading = false;
    _error = scopedPagedReadRejection?.message;
  });

  // 2026-09-25 单号列统一：关联订单列表头排序 + 值筛选（服务端白名单/facets）。
  String? _sortColumn;
  bool _sortAscending = true;
  final Map<String, List<MasterFacetBucket>> _ordersFacets = const {};
  String? _salesOrderFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) trackRefresh(_load());
    });
  }

  @override
  void didUpdateWidget(covariant ProductionExecutionGroupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keywordChanged = oldWidget.keyword != widget.keyword;
    if (keywordChanged || oldWidget.refreshRevision != widget.refreshRevision) {
      if (keywordChanged) _page = 1;
      final generation = ++_loadGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _loadGeneration) trackRefresh(_load());
      });
    }
  }

  Future<void> _load({bool useCache = false}) =>
      trackRefresh(_loadPage(useCache: useCache), replaceKey: 'rows');

  Future<void> _loadPage({bool useCache = false}) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final readQuery = (
      widget.keyword,
      _sortColumn,
      _sortAscending,
      _salesOrderFilter,
    );
    final requestedPage = !useCache && _acceptedReadQuery == readQuery
        ? _tableRows.visiblePage ?? _page
        : _page;
    final requestedKeyword = widget.keyword;
    final requestedSort = _sortColumn;
    final requestedOrder = _sortColumn == null
        ? null
        : (_sortAscending ? 'asc' : 'desc');
    final requestedSalesOrder = _salesOrderFilter;
    final requestedAscending = _sortAscending;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(productionExecutionWorkbenchRepositoryProvider);
      final result = await readScopedPage<ProductionExecutionWorkbenchGroup>(
        requestedPage,
        query: (
          repo,
          requestedKeyword,
          requestedSort,
          requestedAscending,
          requestedSalesOrder,
        ),
        currentQuery: () => (
          ref.read(productionExecutionWorkbenchRepositoryProvider),
          widget.keyword,
          _sortColumn,
          _sortAscending,
          _salesOrderFilter,
        ),
        useCache: useCache,
        fetchPage: (page) => repo.groups(
          page: page,
          keyword: requestedKeyword,
          sort: requestedSort,
          order: requestedOrder,
          salesOrder: requestedSalesOrder,
        ),
      );
      // 关联订单 facets 与列表同上下文（不含单号自身筛选）；失败不阻断列表。

      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _acceptedReadQuery = readQuery;
        _items = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '生产任务加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// 双击批次 → 直达对应详情页：ANALYSIS 根恢复物料分析（该页适合看全链进度），
  /// PLAN 根（历史遗留根计划聚合）打开生产计划详情。不再弹滑窗。
  Future<void> _open(ProductionExecutionWorkbenchGroup group) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      if (group.rootType == 'ANALYSIS') {
        await _navigation.push(
          RouteName.productionMaterialAnalysis,
          extra: ProductionMaterialAnalysisSeed(analysisId: group.rootId),
        );
      } else {
        await _navigation.push(RoutePath.productionPlanDetail(group.rootId));
      }
      // Board return refresh advances refreshRevision for every active panel.
      // The visit owns only its navigation lock, not a second list request.
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _hostLocation ??= currentLocationOr(context, '');
    ref.onListRefresh(_hostLocation!, productionExecutionRefreshKey, () {
      if (!_opening) _load();
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, UtenSpacing.s8, 0, UtenSpacing.s8),
      child: MasterDataTableView<ProductionExecutionWorkbenchGroup>(
        rowsController: _tableRows,
        expensiveRowMounts: false,
        tableKey:
            'features.production.widgets.production_execution_group_panel.ProductionExecutionGroupPanelState.build.1',
        columns: _columns,
        items: _items,
        // 2026-09-25 单号列统一：关联订单值来自服务端 facets（与列表同一过滤上下文）。
        facets: {'orders': _ordersFacets['orders'] ?? const []},
        facetPageLoaders: nativeFacetLoaders(
          ref,
          path: '/production/execution-workbench/facets',
          fields: const ['orders'],
          filters: {'keyword': widget.keyword},
        ),
        facetSearchScope: nativeFacetSearchScope(
          ref,
          '/production/execution-workbench/facets',
          {'keyword': widget.keyword},
        ),

        nullCounts: const {},
        filters: {'orders': ?_salesOrderFilter},
        onFilterChanged: (key, value) {
          // 2026-09-25 单号列统一：关联订单值筛选走服务端精确匹配，分页前生效。
          if (key != 'orders') return;
          setState(() {
            _salesOrderFilter = (value == null || value.isEmpty) ? null : value;
            _page = 1;
          });
          _load();
        },
        onRowTap: _opening ? null : _open,
        canOpenRow: (row) => !_opening,
        rowKeyOf: (row) => row.id,
        rowMenuBuilder: (row) => [
          UtenMenuItem(
            label: row.rootType == 'ANALYSIS' ? '打开物料分析' : '打开生产计划',
            icon: Icons.open_in_new_rounded,
            enabled: !_opening,
            onTap: () => _open(row),
          ),
        ],
        // 2026-09-25 单号列统一：表头排序走服务端白名单（orders）。
        sortColumn: _sortColumn,
        sortAscending: _sortAscending,
        onSortChange: (column, ascending) {
          setState(() {
            _sortColumn = column;
            _sortAscending = ascending;
            _page = 1;
          });
          _load();
        },
        currentPage: _page,
        totalPages: _totalPages,
        paginationScope: widget.keyword,
        onPageChange: (page) {
          _page = page;
          return _load(useCache: true);
        },
        isLoading: _loading,
        error: _error,
        onRetry: _load,
        emptyMessage: widget.keyword.isEmpty ? '暂无进行中的物料分析或生产任务' : '没有匹配的生产任务',
      ),
    );
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchGroup>> get _columns => [
    // 2026-10-08 用户口径（列序）：状态/进度列放最前——进度紧随状态列之后。
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (row) => row.statusLabel,
      // 2026-09-27 用户口径「格内胶囊改单元格背景色」：状态分类色铺整格底，
      // 替代原格内 _GroupStatusBadge 胶囊。
      cellColor: (context, row) =>
          utenStatusBadgeCellColor(_groupStatusType(row.status)),
    ),
    // 追加生产仍按产品身份统计：同货品/颜色/单位的全部有效工单完工才算完成。
    MasterColumnDef(
      key: 'progress',
      label: '产品完成情况',
      width: 220,
      info: '按货品、颜色、单位统计；同一产品所有有效工单完工才算完成，取消和红冲工单不计。双击批次查看实际阶段。',
      value: (row) => row.productCompletionLabel,
    ),
    MasterColumnDef(
      key: 'root',
      label: '分析批次',
      width: 150,
      value: (row) => row.rootLabel,
    ),
    MasterColumnDef(
      key: 'orders',
      label: '关联订单',
      width: 210,
      // 2026-09-25 单号列统一：可排序（服务端白名单 orders）+ 值筛选（facets）。
      sortable: true,
      value: (row) => _preview(
        row.salesOrderPreview,
        row.salesOrderCount,
        row.salesOrderHasMore,
      ),
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    // 同名不同色、同名不同编号的分析批次光看名称分不开。**注意**：三列各自
    // 独立聚合、**不是逐项对齐**的——编号列第 2 个不一定对应名称列第 2 个
    // （列头 ⓘ 已写明），别据此配对。
    // 2026-10-29 用户口径（全站多值格统一，同仓库任务中心「生产工单」列）：
    // 格内只显示首个 +「等 N 个」，点击单元格弹出全部（V969 服务端随行下发
    // 全量）；名称/货品编码弹窗可按条打开货品详情；双击行仍打开批次详情。
    MasterColumnDef(
      key: 'productName',
      label: '产品名称',
      width: 200,
      info:
          '本组全部产品的名称；格内显示首个 +「等 N 个」，点击单元格弹出全部并可按条打开货品详情，双击行打开批次详情。与右侧编号/颜色列各自独立聚合，不逐项对应。',
      value: (row) =>
          _productNames(row).isEmpty ? '—' : _productNames(row).join('、'),
      cellBuilder: (context, row) => UtenMultiValueCell(
        values: _productNames(row),
        title: '产品名称',
        enabled: !_opening,
        detailAvailableOf: (name) => _goodsIdOf(row, name: name) != null,
        onDetail: (name) => _openGoods(context, _goodsIdOf(row, name: name)),
      ),
    ),
    MasterColumnDef(
      key: 'productCode',
      label: '货品编码',
      width: 130,
      info: '本组全部产品的货品编码；格内显示首个 +「等 N 个」，点击单元格弹出全部并可按条打开货品详情。与名称列不逐项对应。',
      value: (row) =>
          _productCodes(row).isEmpty ? '—' : _productCodes(row).join('、'),
      cellBuilder: (context, row) => UtenMultiValueCell(
        values: _productCodes(row),
        title: '货品编码',
        enabled: !_opening,
        detailAvailableOf: (code) => _goodsIdOf(row, code: code) != null,
        onDetail: (code) => _openGoods(context, _goodsIdOf(row, code: code)),
      ),
    ),
    MasterColumnDef(
      key: 'productColor',
      label: '颜色',
      width: 96,
      info: '本组全部产品的颜色；格内显示首个 +「等 N 个」，点击单元格弹出全部。与名称列不逐项对应。',
      value: (row) =>
          _productColors(row).isEmpty ? '—' : _productColors(row).join('、'),
      cellBuilder: (context, row) => UtenMultiValueCell(
        values: _productColors(row),
        title: '颜色',
        enabled: !_opening,
      ),
    ),
    MasterColumnDef(
      key: 'maker',
      label: '分析人',
      width: 130,
      value: (row) => row.ownerEmployeeName?.trim().isEmpty == false
          ? row.ownerEmployeeName!.trim()
          : '—',
    ),
    MasterColumnDef(
      key: 'analyzedAt',
      label: '分析时间',
      width: 160,
      value: (row) => row.analyzedAt?.trim().isEmpty == false
          ? row.analyzedAt!.trim()
          : '—',
    ),
  ];
}

/// 全量优先（V969），旧载荷/测试夹具回退拆 preview（' / ' 前 3 项）。
List<String> _splitPreview(String? preview) => [
  for (final part in (preview ?? '').split(' / '))
    if (part.trim().isNotEmpty) part.trim(),
];

List<String> _productNames(ProductionExecutionWorkbenchGroup row) {
  final names = [
    for (final entry in row.productEntries)
      if ((entry['name'] ?? '').trim().isNotEmpty) entry['name']!.trim(),
  ];
  return names.isNotEmpty ? names : _splitPreview(row.productNamePreview);
}

List<String> _productCodes(ProductionExecutionWorkbenchGroup row) {
  final codes = [
    for (final entry in row.productEntries)
      if ((entry['code'] ?? '').trim().isNotEmpty) entry['code']!.trim(),
  ];
  return codes.isNotEmpty ? codes : _splitPreview(row.productCodePreview);
}

List<String> _productColors(ProductionExecutionWorkbenchGroup row) {
  final colors = [
    for (final color in row.productColorsAll)
      if (color.trim().isNotEmpty) color.trim(),
  ];
  return colors.isNotEmpty ? colors : _splitPreview(row.productColorPreview);
}

String? _goodsIdOf(
  ProductionExecutionWorkbenchGroup row, {
  String? name,
  String? code,
}) {
  for (final entry in row.productEntries) {
    if (name != null && entry['name']?.trim() != name) continue;
    if (code != null && entry['code']?.trim() != code) continue;
    final id = entry['goodsId']?.trim();
    if (id != null && id.isNotEmpty) return id;
  }
  return null;
}

void _openGoods(BuildContext context, String? goodsId) {
  if (goodsId == null) return;
  context.push(RoutePath.basicinfoGoodsDetail(goodsId));
}

String _preview(String? value, int count, bool hasMore) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  return hasMore ? '$text · 共 $count 项' : text;
}

/// 分组状态 → 徽章类型（状态列 cellColor 的色源，ADR-169 档位锚定）：
/// 分析处理中=蓝（正在执行）；备料中/不齐套=琥珀（等仓库/在途，无异常）；
/// 部分已排=紫（部分就绪）；备料完毕=绿（就绪可动手）；生产中=蓝（正在执行）；
/// 车间信息待补录=红（没补录不能往下，硬阻断）；其余（计划待审核/下达等
/// 词表 pending 族与未知态）=灰。同页同现各档互可区分。
UtenStatusBadgeType _groupStatusType(String status) => switch (status) {
  'ANALYZING' => UtenStatusBadgeType.info,
  'IN_PROGRESS' => UtenStatusBadgeType.info,
  'PARTIALLY_SCHEDULED' => UtenStatusBadgeType.violet,
  'KIT_SHORT' || 'PREPARING' => UtenStatusBadgeType.warning,
  'PREPARED' => UtenStatusBadgeType.success,
  'ASSIGNMENT_REQUIRED' => UtenStatusBadgeType.danger,
  _ => UtenStatusBadgeType.neutral,
};

/// 名称右侧的「共 N 项」后缀标签：聚合预览截断时提示还有更多产品。
/// 样式与身份格副行同款次要色，但不占副行——名称行内只有名称本身。
