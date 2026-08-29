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
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
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
import '../../basic_data/widgets/category_tree_search.dart';
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
  String? _treeError;

  // 当前选中的分类导航：(categoryType, categoryId)。null/null = 全部。
  String? _categoryType;
  String? _categoryId;

  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _displayMode = 'ALL'; // ALL / ANY / AR_ONLY / AP_ONLY
  String _searchQuery = '';
  // 仅“往来单位内容命中”时赋值；纯分类命中时保持空，让右侧展示该分类全部。
  String _keyword = '';
  final _searchController = TextEditingController();
  final _treeSearchController = TextEditingController();
  bool _syncingSearchControllers = false;
  Timer? _searchDebounce;
  Set<String>? _visibleFilterIds;
  Set<String> _contentMatchCategoryIds = {};
  bool _searchLoading = false;
  String? _searchError;
  bool _noUnifiedSearchMatches = false;
  String? _reportError;
  int _searchRequestGeneration = 0;
  int _reportRequestGeneration = 0;
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
    _searchController.addListener(_onPrimarySearchInputChanged);
    _treeSearchController.addListener(_onTreeSearchInputChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTree();
      _applyPrefs(ref.read(financeArApOverviewReportPrefsProvider));
      _load();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.removeListener(_onPrimarySearchInputChanged);
    _treeSearchController.removeListener(_onTreeSearchInputChanged);
    _searchController.dispose();
    _treeSearchController.dispose();
    super.dispose();
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
      // 日期范围不回灌：进页始终用默认日期范围（上月今日..今日），避免历史持久化
      // 的过时日期范围把新数据滤空（销售报表已踩此坑，见 sales_report_page.dart）。
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _categoryType,
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
    setState(() {
      _treeLoading = true;
      _treeError = null;
    });
    try {
      final trees = await Future.wait<List<ProductCategoryNode>>([
        ref.read(clientCategoryRepositoryProvider).tree(),
        ref.read(supplierCategoryRepositoryProvider).tree(),
      ]);
      if (!mounted) return;
      setState(() {
        _clientTree = trees[0];
        _supplierTree = trees[1];
        _treeLoading = false;
      });
      if (_searchQuery.isNotEmpty) {
        _queueUnifiedSearch(immediate: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _treeLoading = false;
        _treeError = '分类加载失败，请重试：$e';
      });
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
    // Manual navigation cancels both a pending debounce and any in-flight
    // locator so an older search cannot take the selection back afterwards.
    _searchDebounce?.cancel();
    _searchRequestGeneration++;
    _reportRequestGeneration++;
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
    final keepKeyword =
        _searchQuery.isNotEmpty &&
        hierarchyBranchContainsAny(_forest, node.id, _contentMatchCategoryIds);
    setState(() {
      _categoryType = type;
      _categoryId = id;
      // 统一搜索仍由左框控制；点纯分类结果不退出搜索，只是不把分类词误传给右表。
      _keyword = keepKeyword ? _searchQuery : '';
      _noUnifiedSearchMatches = false;
      _searchLoading = false;
      _searchError = null;
      _page = 1;
    });
    _persistPrefs();
    _load();
  }

  void _onPrimarySearchInputChanged() =>
      _onSearchInputChanged(_searchController, _treeSearchController);

  void _onTreeSearchInputChanged() =>
      _onSearchInputChanged(_treeSearchController, _searchController);

  void _onSearchInputChanged(
    TextEditingController source,
    TextEditingController peer,
  ) {
    if (_syncingSearchControllers) return;
    if (peer.text != source.text) {
      _syncingSearchControllers = true;
      peer.value = TextEditingValue(
        text: source.text,
        selection: TextSelection.collapsed(offset: source.text.length),
      );
      _syncingSearchControllers = false;
    }
    // TextEditingController 在焦点/selection 改变时也会通知；只有文本真的变化才搜索，
    // 避免点击搜索框本身被误判成“清空”并触发一笔全量报表请求。
    if (source.text.trim() == _searchQuery) return;
    _queueUnifiedSearch();
  }

  void _queueUnifiedSearch({bool immediate = false}) {
    _searchDebounce?.cancel();
    final query = _searchController.text.trim();
    final requestGeneration = ++_searchRequestGeneration;
    // 输入一发生变化就让旧报表请求失效，避免 300ms 防抖窗口内旧结果回写。
    _reportRequestGeneration++;
    if (!mounted) return;
    setState(() {
      _searchQuery = query;
      _keyword = '';
      _page = 1;
      _searchError = null;
      _noUnifiedSearchMatches = false;
      // 旧报表请求已失效，其完成分支不会再清 loading。先保留旧数据并结束
      // 旧 loading；定位成功后的 _load 会为新口径重新进入加载态。
      _loading = false;
      if (query.isEmpty) {
        _visibleFilterIds = null;
        _contentMatchCategoryIds = {};
        _searchLoading = false;
      } else {
        // 新搜索开始即丢弃上一轮内容命中，避免定位请求返回前（或失败后）点击树节点时
        // 错把新关键词当成旧分支的内容关键词传给右侧报表。
        _contentMatchCategoryIds = {};
        _visibleFilterIds = categoryHits(_forest, query);
        _searchLoading = true;
      }
    });
    if (query.isEmpty) {
      _load();
      return;
    }
    if (immediate) {
      unawaited(_runUnifiedSearch(query, requestGeneration));
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || requestGeneration != _searchRequestGeneration) return;
      _runUnifiedSearch(query, requestGeneration);
    });
  }

  Future<_CategoryLocationMatches> _collectPartyMatches(
    String query,
    int requestGeneration,
  ) async {
    final categoryIds = <String?>{};
    var page = 1;
    var totalPages = 1;
    var hasParties = false;
    do {
      final json = await ref
          .read(apiClientProvider)
          .get(
            '/finance/reports/ar-ap/party-locations',
            query: {'keyword': query, 'page': page, 'size': 100},
          );
      if (!mounted || requestGeneration != _searchRequestGeneration) {
        return const _CategoryLocationMatches();
      }
      final items = json['items'];
      if (items is List) {
        for (final raw in items) {
          if (raw is! Map) continue;
          final partyType = raw['partyType']?.toString();
          if (partyType != 'CLIENT' && partyType != 'SUPPLIER') continue;
          hasParties = true;
          final categoryId = raw['categoryId']?.toString().trim();
          categoryIds.add(
            categoryId == null || categoryId.isEmpty ? null : categoryId,
          );
        }
      }
      hasParties = hasParties || ((json['total'] as num?)?.toInt() ?? 0) > 0;
      final parsedTotalPages = (json['totalPages'] as num?)?.toInt() ?? 1;
      totalPages = parsedTotalPages < 1 ? 1 : parsedTotalPages;
      page++;
    } while (page <= totalPages);
    return _CategoryLocationMatches(
      categoryIds: categoryIds,
      hasParties: hasParties,
    );
  }

  Future<void> _runUnifiedSearch(String query, int requestGeneration) async {
    try {
      final matches = await _collectPartyMatches(query, requestGeneration);
      if (!mounted ||
          requestGeneration != _searchRequestGeneration ||
          query != _searchQuery) {
        return;
      }
      final hasParties = matches.hasParties;
      final resolution = resolveHierarchySearch<ProductCategoryNode>(
        roots: _forest,
        query: query,
        contentCategoryIds: matches.categoryIds,
      );

      String? type;
      String? id;
      // 有往来单位命中、但它未归类或分类不在当前授权树中时，右侧退回全局结果，
      // 不能错误沿用旧分类把真实结果过滤掉。
      final selectedId = hasParties && !resolution.hasContentMatches
          ? null
          : resolution.selectedId;
      if (selectedId == _clientRootId) {
        type = 'CLIENT';
      } else if (selectedId == _supplierRootId) {
        type = 'SUPPLIER';
      } else if (selectedId != null &&
          _findIn(_clientTree, selectedId) != null) {
        type = 'CLIENT';
        id = selectedId;
      } else if (selectedId != null &&
          _findIn(_supplierTree, selectedId) != null) {
        type = 'SUPPLIER';
        id = selectedId;
      }

      setState(() {
        _visibleFilterIds = resolution.visibleIds;
        _contentMatchCategoryIds = resolution.contentCategoryIds;
        _keyword = hasParties ? query : '';
        _searchLoading = false;
        _searchError = null;
        _noUnifiedSearchMatches = !hasParties && !resolution.hasAnyMatches;
        _categoryType = type;
        _categoryId = id;
        _page = 1;
      });
      await _load();
    } catch (e) {
      if (!mounted || requestGeneration != _searchRequestGeneration) return;
      setState(() {
        _searchLoading = false;
        _searchError = '往来单位搜索失败，请重试：$e';
        // 定位失败时不发起第二次报表请求：保留既有右表数据并明确报错，避免
        // “搜索定位失败但表格偷偷变了”的双重状态；用户可修改关键词或清空后重试。
        _keyword = '';
        _noUnifiedSearchMatches = false;
      });
    }
  }

  Future<void> _load() async {
    // 搜索框非空时，定位完成前（或定位失败后）不得从日期/偏好/刷新等旁路发起
    // 无关键词报表请求；否则慢响应可能把搜索态短暂覆盖成全量数据。
    if (_searchQuery.isNotEmpty && (_searchLoading || _searchError != null)) {
      return;
    }
    final requestGeneration = ++_reportRequestGeneration;
    if (_noUnifiedSearchMatches) {
      setState(() {
        _loading = false;
        _reportError = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _reportError = null;
    });
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
      if (!mounted || requestGeneration != _reportRequestGeneration) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
        _reportError = null;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _reportRequestGeneration) return;
      context.appError('加载应收应付失败：$e');
      setState(() {
        _reportError = '加载应收应付失败，请重试';
        _loading = false;
      });
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
      if (!_dirty &&
          _searchQuery.isEmpty &&
          prev != next &&
          !next.isEmpty &&
          mounted) {
        _applyPrefs(next);
        _page = 1;
        _load();
      }
    });
    final selectedLabel = _categoryType == null
        ? '全部'
        : _categoryId == null
        ? (_categoryType == 'CLIENT' ? '客户类别(全部)' : '供应商类别(全部)')
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
      showSearch: false,
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _searchQuery,
      externalSearchLoading: _searchLoading,
      externalSearchError: _searchError,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: UtenSearchBar(
          key: const ValueKey('finance-ar-ap-unified-search'),
          controller: _treeSearchController,
          hint: '搜索分类/往来单位名称或编号',
          onSubmitted: (_) => _queueUnifiedSearch(immediate: true),
        ),
      ),
      onNodeTap: _onTreeTap,
    );
    if (_treeLoading) {
      treeWidget = const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else if (_treeError != null) {
      treeWidget = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _treeError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadTree,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    Widget body;
    if (bp == UtenBreakpoint.compact) {
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: UtenSearchBar(
              key: const ValueKey('finance-ar-ap-compact-search'),
              controller: _searchController,
              hint: '搜索分类/往来单位名称或编号',
              onSubmitted: (_) => _queueUnifiedSearch(immediate: true),
            ),
          ),
          Expanded(child: _buildRightPane(theme, selectedLabel)),
        ],
      );
    } else {
      body = UtenSplitView(
        persistenceKey: 'finance.arAp',
        leading: treeWidget,
        trailing: _buildRightPane(theme, selectedLabel),
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
            // 顶部筛选条：日期 + 显示方式。统一搜索位于左侧分类栏。
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
    if (_noUnifiedSearchMatches) {
      return Center(
        child: Text(
          '未找到匹配「$_searchQuery」的分类或往来单位',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_reportError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _reportError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
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
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}(最多前 2000 行)',
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

class _CategoryLocationMatches {
  const _CategoryLocationMatches({
    this.categoryIds = const <String?>{},
    this.hasParties = false,
  });

  final Set<String?> categoryIds;
  final bool hasParties;
}
