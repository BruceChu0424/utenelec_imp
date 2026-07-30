// 应收应付总览页 (Z)（finance_report:view）—— 还原老系统树形分组功能，用已有组件。
//
// 布局镜像「货品资料」：左分类树（UtenCategoryTreeView，客户类别 + 供应商类别两棵子树，
//   点击父类展示含子类的全部往来单位、点击自动展开/缩回）+ 右 Excel 风格表格
//   （MasterDataTableView：往来单位/应收金额/应付金额/电话/联系地址，表头 autofilter + 翻页）。
// 顶部筛选：起止日期 / 显示方式（全部·应收≠0或应付≠0·只应收≠0·只应付≠0）/ 搜索。
//
// 后端 GET /api/finance/reports/ar-ap/overview?dateFrom&dateTo&displayMode&keyword&categoryType&categoryId
//   返回 ReportTableResponse；categoryType=CLIENT/SUPPLIER + categoryId 时后端按分类树递归下溯过滤。
//
// 筛选口径（类别导航/显示方式/日期范围/排序）按账号服务端持久化
// （report.finance.arApOverview，ReportFilterPrefs：docType=categoryType、extra={categoryId,displayMode}）；
// 关键字不持久化。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/repositories/client_category_repository.dart';
import '../../basic_data/repositories/supplier_category_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../../basic_data/widgets/uten_category_tree_view.dart';

const _clientRootId = '__client_root__';
const _supplierRootId = '__supplier_root__';

class FinanceArApOverviewPage extends ConsumerStatefulWidget {
  const FinanceArApOverviewPage({super.key});

  @override
  ConsumerState<FinanceArApOverviewPage> createState() =>
      _FinanceArApOverviewPageState();
}

class _FinanceArApOverviewPageState
    extends ConsumerState<FinanceArApOverviewPage> {
  List<ProductCategoryNode> _clientTree = const [];
  List<ProductCategoryNode> _supplierTree = const [];
  bool _treeLoading = false;

  // 当前选中的分类导航：(categoryType, categoryId)。null/null = 全部。
  String? _categoryType;
  String? _categoryId;

  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _displayMode = 'ALL'; // ALL / ANY / AR_ONLY / AP_ONLY
  String _keyword = '';
  int _page = 1;
  final int _size = 50;

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  ReportData? _data;
  bool _loading = false;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTree();
      _applyPrefs(ref.read(financeArApOverviewReportPrefsProvider));
      _load();
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      _categoryType = p.docType;
      _categoryId = p.extra['categoryId']?.toString();
      final dm = p.extra['displayMode']?.toString();
      if (dm != null &&
          const ['ALL', 'ANY', 'AR_ONLY', 'AP_ONLY'].contains(dm)) {
        _displayMode = dm;
      }
      if (p.from != null) _from = DateTime.tryParse(p.from!) ?? _from;
      if (p.to != null) _to = DateTime.tryParse(p.to!) ?? _to;
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _categoryType,
    from: _fmt(_from),
    to: _fmt(_to),
    sortKey: _sortKey,
    sortAsc: _sortAsc,
    extra: {
      if (_categoryId != null) 'categoryId': _categoryId,
      'displayMode': _displayMode,
    },
  );

  /// 任何筛选变更后调用：标记已动手 + 防抖持久化到服务端。
  void _persistPrefs() {
    _dirty = true;
    ref
        .read(financeArApOverviewReportPrefsProvider.notifier)
        .update(_snapshot());
  }

  Future<void> _loadTree() async {
    setState(() => _treeLoading = true);
    try {
      final c = await ref.read(clientCategoryRepositoryProvider).tree();
      final s = await ref.read(supplierCategoryRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _clientTree = c;
        _supplierTree = s;
        _treeLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _treeLoading = false);
    }
  }

  /// 合成森林：客户类别根（挂客户分类树）+ 供应商类别根（挂供应商分类树）。
  List<ProductCategoryNode> get _forest => [
    ProductCategoryNode(
      id: _clientRootId,
      code: 'CLIENT',
      name: '客户类别',
      level: 0,
      children: _clientTree,
    ),
    ProductCategoryNode(
      id: _supplierRootId,
      code: 'SUPPLIER',
      name: '供应商类别',
      level: 0,
      children: _supplierTree,
    ),
  ];

  ProductCategoryNode? _findIn(List<ProductCategoryNode> tree, String id) {
    for (final n in tree) {
      if (n.id == id) return n;
      final f = _findIn(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  void _onTreeTap(ProductCategoryNode node) {
    String? type;
    String? id;
    if (node.id == _clientRootId) {
      type = 'CLIENT';
      id = null;
    } else if (node.id == _supplierRootId) {
      type = 'SUPPLIER';
      id = null;
    } else if (_findIn(_clientTree, node.id) != null) {
      type = 'CLIENT';
      id = node.id;
    } else if (_findIn(_supplierTree, node.id) != null) {
      type = 'SUPPLIER';
      id = node.id;
    }
    setState(() {
      _categoryType = type;
      _categoryId = id;
      _page = 1;
    });
    _persistPrefs();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        'displayMode': _displayMode,
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        if (_categoryType != null) 'categoryType': _categoryType,
        if (_categoryId != null) 'categoryId': _categoryId,
        'page': _page,
        'size': _size,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(
        '/finance/reports/ar-ap/overview',
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      context.appError('加载应收应付失败：$e');
      setState(() => _loading = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 表头排序回调：column=null 取消排序回到默认；否则按该列升/降序重新请求后端。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
      _page = 1;
    });
    _persistPrefs();
    _load();
  }

  /// 导出报表 key（Z 总览 = ar-ap/overview，与 GET 路径一致）。
  String get _exportReport => 'ar-ap/overview';

  /// 导出查询参数（过滤+排序，与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    'displayMode': _displayMode,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    if (_categoryType != null) 'categoryType': _categoryType,
    if (_categoryId != null) 'categoryId': _categoryId,
    ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final json = await api.get(
      '/finance/reports/ar-ap/overview',
      query: <String, dynamic>{..._exportQuery, 'page': 1, 'size': 2000},
    );
    final data = parseReportResponse(json, 1);
    return UtenPrintTable(
      headers: [for (final c in data.columns) c.label],
      rows: [
        for (final r in data.rows)
          [for (final c in data.columns) formatReportCell(c, r) ?? ''],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    // 服务端偏好同步晚到：仅在用户未动手时回灌并重查（避免覆盖在输状态）。
    ref.listen(financeArApOverviewReportPrefsProvider, (prev, next) {
      if (!_dirty && prev != next && !next.isEmpty && mounted) {
        _applyPrefs(next);
        _page = 1;
        _load();
      }
    });
    final selectedLabel = _categoryType == null
        ? '全部'
        : _categoryId == null
        ? (_categoryType == 'CLIENT' ? '客户类别（全部）' : '供应商类别（全部）')
        : (_categoryType == 'CLIENT'
              ? '客户：${_findIn(_clientTree, _categoryId!)?.name ?? ''}'
              : '供应商：${_findIn(_supplierTree, _categoryId!)?.name ?? ''}');

    Widget treeWidget = UtenCategoryTreeView<ProductCategoryNode>(
      nodes: _forest,
      nodeEnabledPredicate: (_) => true,
      selectedIds: {
        ?_categoryId,
        if (_categoryId == null && _categoryType == 'CLIENT') _clientRootId,
        if (_categoryId == null && _categoryType == 'SUPPLIER') _supplierRootId,
      },
      expandOnRowTap: true,
      onNodeTap: _onTreeTap,
    );
    if (_treeLoading) {
      treeWidget = const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }

    Widget body;
    if (bp == UtenBreakpoint.compact) {
      body = _buildRightPane(theme, selectedLabel);
    } else {
      body = Row(
        children: [
          SizedBox(width: 300, child: treeWidget),
          Container(width: 1, color: theme.colorScheme.outlineVariant),
          Expanded(child: _buildRightPane(theme, selectedLabel)),
        ],
      );
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '应收应付',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _load,
          ),
          if (bp == UtenBreakpoint.compact)
            Builder(
              builder: (sctx) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: '分类树',
                onPressed: () => Scaffold.of(sctx).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: bp == UtenBreakpoint.compact
          ? Drawer(child: SafeArea(child: treeWidget))
          : null,
      body: SafeArea(child: body),
    );
  }

  Widget _buildRightPane(ThemeData theme, String selectedLabel) {
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(
                bottom: UtenSpacing.s8,
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '应收应付 · $selectedLabel',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_data != null)
                    Text(
                      '共 ${_data!.total}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            // 顶部筛选条：日期 + 显示方式 + 搜索
            Padding(
              padding: const EdgeInsets.only(
                bottom: UtenSpacing.s8,
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: _from,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (p != null) {
                        setState(() => _from = p);
                        _persistPrefs();
                      }
                    },
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('起 ${_fmt(_from)}'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: _to,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (p != null) {
                        setState(() => _to = p);
                        _persistPrefs();
                      }
                    },
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('止 ${_fmt(_to)}'),
                  ),
                  DropdownButton<String>(
                    value: _displayMode,
                    isDense: true,
                    items: const [
                      DropdownMenuItem(value: 'ALL', child: Text('全部显示')),
                      DropdownMenuItem(value: 'ANY', child: Text('应收≠0或应付≠0')),
                      DropdownMenuItem(value: 'AR_ONLY', child: Text('只应收≠0')),
                      DropdownMenuItem(value: 'AP_ONLY', child: Text('只应付≠0')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _displayMode = v);
                      _persistPrefs();
                    },
                  ),
                  SizedBox(
                    width: 200,
                    child: UtenSearchBar(
                      hint: '搜索往来单位',
                      initialValue: _keyword,
                      onChanged: (v) => _keyword = v,
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      _page = 1;
                      _load();
                    },
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: const Text('查询'),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildTable()),
          ],
        ),
      ),
    );
  }

  Widget _buildTable() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final data = _data;
    if (data == null) {
      return const Center(child: Text('点击「查询」加载'));
    }
    final columns = data.columns
        .map(
          (c) => MasterColumnDef<Map<String, dynamic>>(
            key: c.key,
            label: c.label,
            width: (c.width ?? 120).toDouble(),
            type: c.type,
            sortable: isSortableReportType(c.type),
            value: (row) => formatReportCell(c, row),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      columns: columns,
      items: data.rows,
      toolbarActions: [
        UtenPrintPreviewButton(
          title: '应收应付',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}（最多前 2000 行）',
          loader: _printLoader,
          exportEndpoint: '/finance/reports/export',
          exportPermission: Perm.financeReportExport,
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '应收应付',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/finance/reports/export',
          requiredPermission: Perm.financeReportExport,
          report: _exportReport,
          queryParams: _exportQuery,
          filename: '应收应付',
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
      onRowTap: (_) {},
      isLoading: _loading,
      emptyMessage: '暂无应收应付数据',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (p) {
        _page = p;
        _load();
      },
    );
  }
}
