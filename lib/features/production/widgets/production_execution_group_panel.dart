import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../models/production_material_analysis.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_execution_workbench_repository.dart';
import '../widgets/production_flow_stage_cell.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/nav_helpers.dart';

/// Planning-facing ongoing list: one row per outer analysis/root plan.
///
/// 2026-09-06 起为「大的分析」统筹视角：顶部不再提供生产车间/排序筛选
/// （关键词搜索在大类行，排序/细分信息双击进详情看）；表格只保留分析级
/// 重要列——顶层产品完工进度（进度条+百分比，只统计参与分析的销售下单
/// 产品，不含子层）、分析批次、关联销售订单、产品、分析人、分析时间。
/// 工单号/车间/产品编号/数量明细等执行细节双击进物料分析页查看。
class ProductionExecutionGroupPanel extends ConsumerStatefulWidget {
  const ProductionExecutionGroupPanel({super.key, required this.keyword});

  final String keyword;

  @override
  ConsumerState<ProductionExecutionGroupPanel> createState() =>
      _ProductionExecutionGroupPanelState();
}

class _ProductionExecutionGroupPanelState
    extends ConsumerState<ProductionExecutionGroupPanel> {
  /// 宿主页路径(创建时捕获), 精准刷新信号只在它就在栈顶时立即重拉。
  String? _hostLocation;

  List<ProductionExecutionWorkbenchGroup> _items = const [];
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  bool _opening = false;
  String? _error;
  int _loadGeneration = 0;

  // 2026-09-25 单号列统一：关联订单列表头排序 + 值筛选（服务端白名单/facets）。
  String? _sortColumn;
  bool _sortAscending = true;
  Map<String, List<MasterFacetBucket>> _ordersFacets = const {};
  String? _salesOrderFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant ProductionExecutionGroupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) {
      _page = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final requestedPage = _page;
    final requestedKeyword = widget.keyword;
    final requestedSort = _sortColumn;
    final requestedOrder = _sortColumn == null
        ? null
        : (_sortAscending ? 'asc' : 'desc');
    final requestedSalesOrder = _salesOrderFilter;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(productionExecutionWorkbenchRepositoryProvider);
      final result = await repo.groups(
        page: requestedPage,
        keyword: requestedKeyword,
        sort: requestedSort,
        order: requestedOrder,
        salesOrder: requestedSalesOrder,
      );
      // 关联订单 facets 与列表同上下文（不含单号自身筛选）；失败不阻断列表。
      Map<String, List<MasterFacetBucket>> facets = const {};
      try {
        facets = await repo.groupFacets(keyword: requestedKeyword);
      } catch (_) {
        facets = const {};
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _ordersFacets = facets;
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
        await context.push(
          RouteName.productionMaterialAnalysis,
          extra: ProductionMaterialAnalysisSeed(analysisId: group.rootId),
        );
      } else {
        await context.push(RoutePath.productionPlanDetail(group.rootId));
      }
      if (mounted) await _load();
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
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s8,
      ),
      child: MasterDataTableView<ProductionExecutionWorkbenchGroup>(
        tableKey:
            'features.production.widgets.production_execution_group_panel.ProductionExecutionGroupPanelState.build.1',
        columns: _columns,
        items: _items,
        // 2026-09-25 单号列统一：关联订单值来自服务端 facets（与列表同一过滤上下文）。
        facets: {'orders': _ordersFacets['orders'] ?? const []},
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
          _load();
        },
        isLoading: _loading,
        error: _error,
        onRetry: _load,
        emptyMessage: widget.keyword.isEmpty ? '暂无进行中的物料分析或生产任务' : '没有匹配的生产任务',
        toolbarActions: [
          IconButton(
            key: const Key('production-progress-refresh'),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchGroup>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (row) => row.statusLabel,
      // 2026-09-27 用户口径「格内胶囊改单元格背景色」：状态分类色铺整格底，
      // 替代原格内 _GroupStatusBadge 胶囊。
      cellColor: (context, row) =>
          udenStatusBadgeCellColor(context, _groupStatusType(row.status)),
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
    // 同名不同色、同名不同编号的分析批次光看名称分不开。**注意**：这三条
    // preview 各自是本组「前三项聚合」，列与列之间**不是逐项对齐**的——
    // 编号列第 2 个不一定对应名称列第 2 个（列头 ⓘ 已写明），别据此配对。
    MasterColumnDef(
      key: 'productName',
      label: '产品名称',
      width: 200,
      info: '本组前几个产品的名称汇总；与右侧编号/颜色列各自独立聚合，不逐项对应。',
      // 2026-09-29 用户口径：名称行只放名称；聚合截断时的「共 N 项」从名称
      // 文本里拆出来，改挂身份格后缀标签（不占副行、不混进名称文字）。
      value: (row) => _blankToNull(row.productNamePreview) ?? '—',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => UtenGoodsIdentityCell(
        name: _blankToNull(row.productNamePreview),
        trailing: row.productHasMore
            ? _GroupCountTag(count: row.productCount)
            : null,
      ),
    ),
    MasterColumnDef(
      key: 'productCode',
      label: '编号',
      width: 130,
      info: '本组前几个产品的编号汇总，与名称列不逐项对应。',
      value: (row) =>
          UtenGoodsAttributeCell.text(_blankToNull(row.productCodePreview)),
      cellBuilder: (_, row) =>
          UtenGoodsAttributeCell(_blankToNull(row.productCodePreview)),
    ),
    MasterColumnDef(
      key: 'productColor',
      label: '颜色',
      width: 96,
      info: '本组前几个产品的颜色汇总，与名称列不逐项对应。',
      value: (row) =>
          UtenGoodsAttributeCell.text(_blankToNull(row.productColorPreview)),
      cellBuilder: (_, row) =>
          UtenGoodsAttributeCell(_blankToNull(row.productColorPreview)),
    ),
    // 顶层产品完工进度：只统计参与分析的销售下单产品（多张销售单联合
    // 分析也按根产品行聚合），子层自制/委外的完工不冒充顶层进度。
    MasterColumnDef(
      key: 'progress',
      label: '进度',
      width: 220,
      value: (row) => row.rootProgressPercent == null
          ? '—'
          : '完工 ${row.rootProgressPercent}%',
      cellBuilder: (_, row) => ProductionFlowProgress(
        ratio: row.rootProgressRatio,
        semanticsLabel: '顶层产品完工进度',
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

String _preview(String? value, int count, bool hasMore) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  return hasMore ? '$text · 共 $count 项' : text;
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

/// 分组状态 → 徽章类型（状态列 cellColor 的色源，与旧胶囊同分支）。
UtenStatusBadgeType _groupStatusType(String status) => switch (status) {
  'PREPARED' => UtenStatusBadgeType.success,
  'IN_PROGRESS' => UtenStatusBadgeType.info,
  'KIT_SHORT' ||
  'PREPARING' ||
  'PARTIALLY_SCHEDULED' => UtenStatusBadgeType.warning,
  'ASSIGNMENT_REQUIRED' => UtenStatusBadgeType.danger,
  _ => UtenStatusBadgeType.neutral,
};

/// 名称右侧的「共 N 项」后缀标签：聚合预览截断时提示还有更多产品。
/// 样式与身份格副行同款次要色，但不占副行——名称行内只有名称本身。
class _GroupCountTag extends StatelessWidget {
  const _GroupCountTag({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '共 $count 项',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
