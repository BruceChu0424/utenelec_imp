// 即时库存页（仓库管理 hub 入口，stock:view）。
//
// 对标老系统「即时库存」窗口（View_IOStockGoods）：
// - 左侧 = 货品分类树抽屉（与货品资料同款 UtenCategoryTreeView；compact 收进 endDrawer）；
// - 右侧 = 库存表格（统一 MasterDataTableView）：
//   所属类型 / 型号 / 客户型号 / 货品名称 / 规格 / 颜色 / 单位 / 备注
//   / 库存重量 / 库存数量 / 成本金额 / 多排数量；
// - 顶部 = 仓库下拉（全部=参与核算仓库聚合）+ 搜索（名称/编号/型号/客户型号）。
//
// 数据口径（后端 /api/stock/instant-inventory）：
//   数量/重量 = stock_balances 按货品+颜色聚合（历史=StockGoods 最新年 FactQTY/FactWeight 迁移，
//   增量=单据审核同事务联动，仓库单据含重量）；成本金额 = 货品成本 c_total × 数量；
//   多排数量 = 生产计划明细可排余量（老库 View_ProductMore 同口径）。
// 性能：后端一次聚合分页（LIMIT/OFFSET + 排序白名单），前端不拉全量，万级数据秒开。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/repositories/product_category_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/uten_category_tree_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_query.dart';
import '../providers/instant_inventory_prefs_provider.dart';
import '../repositories/stock_query_repository.dart';

class InstantInventoryPage extends ConsumerStatefulWidget {
  const InstantInventoryPage({super.key});

  @override
  ConsumerState<InstantInventoryPage> createState() =>
      _InstantInventoryPageState();
}

class _InstantInventoryPageState extends ConsumerState<InstantInventoryPage> {
  // 分类树（货品资料同款数据源）。
  List<ProductCategoryNode>? _tree;
  String? _treeError;
  String? _categoryId; // null = 全部

  // 库存表格分页态。
  PagedResult<InstantInventoryRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String? _warehouseId; // null = 全部（参与核算仓库聚合）
  String _keyword = '';
  // 列排序态：null=后端默认（库存数量 DESC）。
  String? _sortKey;
  bool _sortAsc = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      await Future.wait([_loadTree(), _load(1)]);
    });
  }

  Future<void> _loadTree() async {
    try {
      final tree = await ref.read(productCategoryRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _treeError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _treeError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _treeError = '加载分类树失败'); // TODO(l10n): 补 arb
    }
  }

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(stockQueryRepositoryProvider)
          .instantInventory(
            page: page,
            categoryId: _categoryId,
            warehouseId: _warehouseId,
            includeDefective: ref.read(instantInventoryPrefsProvider),
            keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _page = r);
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _error = '加载失败'); // TODO(l10n): 补 arb
    } finally {
      if (mounted && _loadRequests.isCurrent(generation)) {
        setState(() => _loading = false);
      }
    }
  }

  void _onSelectCategory(String? id) {
    setState(() => _categoryId = id);
    _load(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  /// 导出查询参数（与 _load 一致，不含 page/size；report 固定 'instant-inventory' 走后端独立分支）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_categoryId != null) 'categoryId': _categoryId,
    if (_warehouseId != null) 'warehouseId': _warehouseId,
    'includeDefective': ref.read(instantInventoryPrefsProvider),
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 数字格式化：最多 2 位小数，去掉无意义的尾随 0（1.50→1.5；0→0）。
  static String _num(double? v) {
    if (v == null) return '—';
    final s = v.toStringAsFixed(2);
    return s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
  }

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final r = await ref
        .read(stockQueryRepositoryProvider)
        .instantInventory(
          size: 2000,
          categoryId: _categoryId,
          warehouseId: _warehouseId,
          includeDefective: ref.read(instantInventoryPrefsProvider),
          keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    final cols = _columns;
    return UtenPrintTable(
      headers: [for (final c in cols) c.label],
      rows: [
        for (final row in r.items) [for (final c in cols) c.value(row) ?? ''],
      ],
    );
  }

  List<MasterColumnDef<InstantInventoryRow>> get _columns =>
      <MasterColumnDef<InstantInventoryRow>>[
        MasterColumnDef(
          key: 'category',
          label: '所属类型',
          width: 120,
          value: (r) => r.categoryName ?? '—',
        ),
        MasterColumnDef(
          key: 'model',
          label: '型号',
          width: 110,
          value: (r) => r.model ?? '',
        ),
        MasterColumnDef(
          key: 'cNumber',
          label: '客户型号',
          width: 120,
          value: (r) => r.cNumber ?? '',
        ),
        MasterColumnDef(
          key: 'name',
          label: '货品名称',
          width: 220,
          sortable: true,
          value: (r) => r.name ?? '',
        ),
        MasterColumnDef(
          key: 'spec',
          label: '规格',
          width: 120,
          value: (r) => r.spec ?? '',
        ),
        MasterColumnDef(
          key: 'color',
          label: '颜色',
          width: 90,
          value: (r) => r.colorName ?? '',
        ),
        MasterColumnDef(
          key: 'unit',
          label: '单位',
          width: 70,
          value: (r) => r.unitName ?? '',
        ),
        MasterColumnDef(
          key: 'remark',
          label: '备注',
          width: 90,
          value: (r) => r.remark ?? '',
        ),
        MasterColumnDef(
          key: 'weight',
          label: '库存重量',
          width: 110,
          type: 'number',
          sortable: true,
          value: (r) => _num(r.weight),
        ),
        MasterColumnDef(
          key: 'qty',
          label: '库存数量',
          width: 110,
          type: 'number',
          sortable: true,
          value: (r) => _num(r.qty),
        ),
        MasterColumnDef(
          key: 'costAmount',
          label: '成本金额',
          width: 120,
          type: 'number',
          sortable: true,
          value: (r) => r.costAmount?.toStringAsFixed(2) ?? '—',
        ),
        MasterColumnDef(
          key: 'moreQty',
          label: '多排数量',
          width: 100,
          type: 'number',
          sortable: true,
          value: (r) => _num(r.moreQty),
        ),
      ];

  // ---- 左侧：分类树（含「全部」顶行） ------------------------------------------

  Widget _buildTree({required void Function(String? id) onSelect}) {
    final theme = Theme.of(context);
    final tree = _tree;
    if (_treeError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text(
            _treeError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }
    if (tree == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final allSelected = _categoryId == null;
    return Column(
      children: [
        // 「全部」顶行（老系统树根部「全部」节点）：清空分类过滤。
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => onSelect(null),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s16,
                vertical: UtenSpacing.s12,
              ),
              decoration: BoxDecoration(
                color: allSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.08)
                    : null,
                border: Border(
                  bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.all_inbox_rounded,
                    size: 18,
                    color: allSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '全部', // TODO(l10n): 补 arb
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: allSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: allSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: UtenCategoryTreeView(
            nodes: tree,
            nodeEnabledPredicate: (_) => true,
            selectedIds: {?_categoryId},
            expandOnRowTap: true,
            onNodeTap: (node) => onSelect(node.id),
          ),
        ),
      ],
    );
  }

  // ---- 右侧：仓库筛选 + 搜索 + 库存表格 --------------------------------------

  Widget _buildTablePane() {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final includeDefective = ref.watch(instantInventoryPrefsProvider);
    final total = _page?.total ?? 0;
    return Column(
      children: [
        // 顶部筛选行：仓库下拉（老系统同款「仓库 全部」）+ 搜索 + 计数
        Padding(
          padding: const EdgeInsets.only(
            left: UtenSpacing.s4,
            right: UtenSpacing.s4,
            bottom: UtenSpacing.s8,
          ),
          child: Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  initialValue: _warehouseId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '仓库',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(child: Text('全部')),
                    for (final e in names.warehouseEntries.entries)
                      DropdownMenuItem<String?>(
                        value: e.key,
                        child: Text(e.value),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => _warehouseId = v);
                    _load(1);
                  },
                ),
              ),
              SizedBox(
                width: 280,
                child: UtenSearchBar(
                  hint: '搜索（名称/编号/型号/客户型号）', // TODO(l10n): 补 arb
                  onChanged: (kw) {
                    setState(() => _keyword = kw);
                    _load(1);
                  },
                ),
              ),
              // 「含不良品仓」开关：仅仓库=全部时有效（指定仓库时下拉已锁定单仓）。
              // 默认开 = 老系统口径（不良仓计入全部）；选择按账号服务端持久化（stock.instantInventory）。
              FilterChip(
                label: const Text('含不良品仓'), // TODO(l10n): 补 arb
                selected: includeDefective,
                onSelected: _warehouseId != null
                    ? null
                    : (v) => ref
                          .read(instantInventoryPrefsProvider.notifier)
                          .setIncludeDefective(v),
              ),
              // 加密 Excel 导出 / 预览打印：已移入表格工具条（表头设置旁，深绿大按钮）。
              Text(
                '共 $total 项', // TODO(l10n): 补 arb
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<InstantInventoryRow>(
            columns: _columns,
            items: _page?.items ?? const [],
            toolbarActions: [
              // 加密 Excel 导出（stock_report:export 权限 + 限流 + AES-256 密码 + 10 万行上限 + 审计）
              // 预览打印（A4 预览 → 系统打印；与导出口径一致，上限 2000 行）
              UtenPrintPreviewButton(
                title: '即时库存',
                subtitle: '最多前 2000 行',
                loader: _printLoader,
                exportEndpoint: '/stock/reports/export',
                exportPermission: Perm.stockReportExport,
                exportReport: 'instant-inventory',
                exportQuery: _exportQuery,
                exportFilename: '即时库存',
                type: UtenButtonType.primary,
                size: UtenButtonSize.large,
              ),
              UtenExportButton(
                endpoint: '/stock/reports/export',
                requiredPermission: Perm.stockReportExport,
                report: 'instant-inventory',
                queryParams: _exportQuery,
                filename: '即时库存',
                type: UtenButtonType.primary,
                size: UtenButtonSize.large,
              ),
            ],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            sortColumn: _sortKey,
            sortAscending: _sortAsc,
            onSortChange: _onSortChange,
            // 行点击 → 出入库流水页（带该货品过滤，push 保活本页筛选；流水页可清除过滤看全部）
            onRowTap: (r) {
              final gid = r.goodsId;
              if (gid == null || gid.isEmpty) return;
              context.push('${RouteName.stockMovement}?goodsId=$gid');
            },
            isLoading: _loading && _page == null,
            loadingMore: _loading && _page != null,
            error: _error,
            onRetry: () => _load(_pageNum),
            emptyMessage: '暂无库存', // TODO(l10n): 补 arb
            currentPage: _page?.page ?? 1,
            totalPages: _page?.totalPages ?? 1,
            onPageChange: (p) => _load(p),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final isCompact = bp == UtenBreakpoint.compact;
    // 「含不良品仓」偏好变化（点开关 / 服务端同步到达）→ 回第 1 页重查。
    ref.listen(instantInventoryPrefsProvider, (prev, next) {
      if (prev != null && prev != next && mounted) {
        _load(1);
      }
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: '即时库存', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: () => _load(_pageNum),
          ),
          if (isCompact)
            Builder(
              builder: (scaffoldCtx) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: '货品类型', // TODO(l10n): 补 arb
                onPressed: () => Scaffold.of(scaffoldCtx).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: isCompact
          ? Drawer(
              child: SafeArea(
                child: _buildTree(
                  onSelect: (id) {
                    _onSelectCategory(id);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: isCompact
              ? _buildTablePane()
              : Row(
                  children: [
                    SizedBox(
                      width: 300,
                      child: _buildTree(onSelect: _onSelectCategory),
                    ),
                    Container(
                      width: 1,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: UtenSpacing.s12,
                          right: UtenSpacing.s8,
                        ),
                        child: _buildTablePane(),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
