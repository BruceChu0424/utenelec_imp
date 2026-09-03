// 即时库存页（仓库管理 hub 入口，stock:view）。
//
// 对标老系统「即时库存」窗口（View_IOStockGoods）的看盘视角（2026-09-01 简化）：
// - 全宽单栏：分类不再用左侧树，改为 UtenFilterToolbar 大类分段（「全部」+
//   各一级分类；无子级的根如「未分类（历史孤儿）」自成一段），父类分段=子树汇总；
// - 工具栏行尾：仓库下拉（全部=参与核算仓库聚合）+「含不良品仓」开关 + 共 N 项；
// - 无搜索框：本页按分类分段 + 仓库维度看盘；找单个货品改走库存列表/详情入口；
// - 表格 = 统一 MasterDataTableView：所属类型 / 物料编码 / 物料系列 / 库位号 /
//   型号 / 客户型号 / 货品名称 / 规格 / 颜色 / 单位 / 备注 / 库存重量 / 库存数量 /
//   待检量 / 合格待入库 / 多排数量。库存台账金额列已从页面与预览打印移除
//  （加密导出 Excel 仍由服务端按 goods:cost:view 独立裁列，口径不受本页影响）。
//
// 数据口径（后端 /api/stock/instant-inventory）：
//   数量/重量 = stock_balances 按货品+颜色聚合（历史=StockGoods 最新年 FactQTY/FactWeight 迁移，
//   增量=单据审核同事务联动，仓库单据含重量）；多排数量 = 生产计划明细可排余量
//  （老库 View_ProductMore 同口径）。
// 性能：后端一次聚合分页（LIMIT/OFFSET + 排序白名单），前端不拉全量，万级数据秒开。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/repositories/product_category_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
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
  // 分类分段数据源（同一 tree 端点，只取一级分类；无子级根自成一段）。
  List<ProductCategoryNode>? _tree;
  String? _treeError;

  // 分类分段选中态：进页面不选（数据等价于不过滤）；点任何分段（含「全部」）才视为已选。
  String? _categoryId;
  bool _categorySelected = false;

  // 库存表格分页态。
  PagedResult<InstantInventoryRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String? _warehouseId; // null = 全部（参与核算仓库聚合）
  // 列排序态：null=后端默认（库存数量 DESC）。
  String? _sortKey;
  bool _sortAsc = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      await _loadTree();
      _load(1); // 无搜索/树定位后页面唯一入口态：进页直接看第一页。
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
      setState(() => _treeError = '加载分类失败'); // TODO(l10n): 补 arb
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
    setState(() {
      _categoryId = id;
      _categorySelected = true;
    });
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
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    final cols = _columns();
    return UtenPrintTable(
      headers: [for (final c in cols) c.label],
      rows: [
        for (final row in r.items) [for (final c in cols) c.value(row) ?? ''],
      ],
    );
  }

  List<MasterColumnDef<InstantInventoryRow>> _columns() =>
      <MasterColumnDef<InstantInventoryRow>>[
        MasterColumnDef(
          key: 'category',
          label: '所属类型',
          width: 120,
          value: (r) => r.categoryName ?? '—',
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '物料编码',
          width: 120,
          value: (r) => r.goodsCode ?? '',
        ),
        MasterColumnDef(
          key: 'series',
          label: '物料系列',
          width: 90,
          value: (r) => r.series ?? '',
        ),
        MasterColumnDef(
          key: 'stockPlace',
          label: '库位号',
          width: 90,
          value: (r) => r.stockPlace ?? '',
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
          key: 'pendingQty',
          label: '待检量',
          width: 100,
          type: 'number',
          sortable: true,
          // 待检量>0 = 采购/委外已收货但 IQC 未放行（货在待检隔离区，不在库存内）。
          value: (r) => _num(r.pendingQty),
        ),
        MasterColumnDef(
          key: 'pendingStockInQty',
          label: '合格待入库',
          width: 120,
          type: 'number',
          sortable: true,
          // 品质 PASS 只形成仓库任务；仓库确认前不进入库存数量。
          value: (r) => _num(r.pendingStockInQty),
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

  /// 分类分段：「全部」+ 各根节点的一级分类；无子级的根（如「未分类（历史孤儿）」）
  /// 自成一段——与原左树可选范围一致，父类分段 = 子树汇总（后端同口径）。
  List<UtenFilterSegment<String?>> _categorySegments() {
    final segments = <UtenFilterSegment<String?>>[
      const UtenFilterSegment(value: null, label: '全部'),
    ];
    for (final root in _tree ?? const <ProductCategoryNode>[]) {
      if (root.children.isEmpty) {
        segments.add(UtenFilterSegment(value: root.id, label: root.name));
      } else {
        for (final child in root.children) {
          segments.add(UtenFilterSegment(value: child.id, label: child.name));
        }
      }
    }
    return segments;
  }

  // ---- 工具栏（分类分段 + 仓库下拉 + 含不良品仓 + 计数）+ 库存表格 --------------

  Widget _buildTablePane() {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final includeDefective = ref.watch(instantInventoryPrefsProvider);
    final total = _page?.total ?? 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: UtenSpacing.s4,
            right: UtenSpacing.s4,
            bottom: UtenSpacing.s8,
          ),
          child: UtenFilterToolbar<String?>(
            segmentsKey: const Key('instant-inventory-category-segments'),
            segments: _categorySegments(),
            selected: _categorySelected ? {_categoryId} : const {},
            onSelectionChanged: _onSelectCategory,
            // 行尾：仓库 + 含不良品仓 + 计数；Wrap 保证超窄屏自动换行不断溢出。
            trailing: Wrap(
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
                          child: Text(
                            e.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() => _warehouseId = v);
                      _load(1);
                    },
                  ),
                ),
                // 「含不良品仓」开关：仅仓库=全部时有效（指定仓库时下拉已锁定单仓）。
                // 默认开 = 老系统口径（不良仓计入全部）；选择按账号服务端持久化
                //（stock.instantInventory）。
                FilterChip(
                  label: const Text('含不良品仓'), // TODO(l10n): 补 arb
                  selected: includeDefective,
                  onSelected: _warehouseId != null
                      ? null
                      : (v) => ref
                            .read(instantInventoryPrefsProvider.notifier)
                            .setIncludeDefective(v),
                ),
                Text(
                  '共 $total 项', // TODO(l10n): 补 arb
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_treeError != null)
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s16,
              right: UtenSpacing.s16,
              bottom: UtenSpacing.s4,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '$_treeError（仅影响分类分段，可刷新重试）', // TODO(l10n): 补 arb
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                TextButton(onPressed: _loadTree, child: const Text('重试')),
              ],
            ),
          ),
        Expanded(
          child: MasterDataTableView<InstantInventoryRow>(
            columns: _columns(),
            items: _page?.items ?? const [],
            toolbarActions: [
              // 导出仍受独立权限、限流、行数上限和审计约束；文件密码可选。
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
            // 行点击 → 库存详情页（该货品各仓余额 + 出入库流水；push 保活本页筛选）
            onRowTap: (r) {
              final gid = r.goodsId;
              if (gid == null || gid.isEmpty) return;
              context.push(RouteName.stockItemDetail(gid));
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
        ],
      ),
      // 局部 SelectionArea：即时库存文字可框选复制（准则 §3.4；表体自带更深 region）。
      body: SelectionArea(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s8,
              left: UtenSpacing.s8,
              right: UtenSpacing.s8,
            ),
            child: _buildTablePane(),
          ),
        ),
      ),
    );
  }
}
