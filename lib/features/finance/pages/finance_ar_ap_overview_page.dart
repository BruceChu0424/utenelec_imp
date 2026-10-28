import '../../../shared/paging/paged_query_identity.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
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
import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/uten_hierarchy_search_header.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/repositories/client_category_repository.dart';
import '../../basic_data/repositories/supplier_category_repository.dart';
import '../../basic_data/widgets/category_tree_search.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/models/master_facet.dart';
import '../../../shared/search/report_contact_query.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_column.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_metadata_reuse.dart';
import '../../report/shared/report_paged_read.dart';
import '../../report/shared/report_print_preview.dart';
import '../../report/shared/report_date_range.dart';
import '../widgets/finance_date_range_filter.dart';
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
  int _treeGeneration = 0;
  String? _treeError;

  // 当前选中的分类导航：(categoryType, categoryId)。null/null = 全部。
  String? _categoryType;
  String? _categoryId;

  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _displayMode = 'ALL'; // ALL / ANY / AR_ONLY / AP_ONLY
  String _searchQuery = '';
  // 搜索始终在授权全集查往来单位/分类；导航分类留存，清空后恢复。
  String _keyword = '';
  final Map<String, String?> _filters = {};
  Set<String> _lastColumnSearchKeys = const {};
  final _searchController = TextEditingController();
  final _treeSearchController = TextEditingController();
  bool _syncingSearchControllers = false;
  Timer? _searchDebounce;
  Set<String>? _visibleFilterIds;
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
  final _reportMetadata = ReportMetadataReuse();
  final _tableRows = MasterDataTableRowsController<Map<String, dynamic>>();
  Object? _acceptedReadQuery;
  late final _reportRead = ReportPagedRead(_reportMetadata);

  /// 上一次成功加载的列集：搜索 0 命中/重查/报错时 `_data` 为空，但表格骨架
  ///（工具条打印导出按钮 + 表头列）沿用这列集继续渲染，行区显示提示——
  /// 页面不整块切换（2026-10-09 用户口径）。
  List<ReportColumn> _lastColumns = const [];

  bool _loading = false;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      _searchDebounce?.cancel();
      _syncingSearchControllers = true;
      _searchController.clear();
      _treeSearchController.clear();
      _syncingSearchControllers = false;
      setState(() {
        ++_reportRequestGeneration;
        ++_searchRequestGeneration;
        ++_treeGeneration;
        _reportRead.invalidate();
        _data = null;
        _lastColumns = const [];
        _clientTree = const [];
        _supplierTree = const [];
        _categoryType = null;
        _categoryId = null;
        _keyword = '';
        _filters.clear();
        _lastColumnSearchKeys = const {};
        _searchQuery = '';
        _visibleFilterIds = null;
        _noUnifiedSearchMatches = false;
        _loading = false;
        _treeLoading = false;
        _searchLoading = false;
        _reportError = null;
        _treeError = null;
        _searchError = null;
        _page = 1;
      });
    });
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
    _reportRead.dispose();
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
  /// 筛选项改动后的统一出口：存偏好 + 回第一页重查。
  ///
  /// 2026-09-11 撤掉「查询」按钮后，筛选不再需要用户再点一下确认——改日期/下拉
  /// 即刻生效，关键词走搜索框自身的防抖与回车（用户要求：搜索回车即查询）。
  void _persistAndReload() {
    _persistPrefs();
    _page = 1;
    _load();
  }

  void _persistPrefs() {
    _dirty = true;
    ref
        .read(financeArApOverviewReportPrefsProvider.notifier)
        .update(_snapshot());
  }

  Future<void> _loadTree() async {
    final generation = ++_treeGeneration;
    final readEpoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        generation == _treeGeneration &&
        readEpoch == ref.read(exportContextEpochProvider);
    setState(() {
      _treeLoading = true;
      _treeError = null;
    });
    try {
      final trees = await Future.wait<List<ProductCategoryNode>>([
        ref.read(clientCategoryRepositoryProvider).tree(),
        ref.read(supplierCategoryRepositoryProvider).tree(),
      ]);
      if (!mounted || !current()) return;
      setState(() {
        _clientTree = trees[0];
        _supplierTree = trees[1];
        _treeLoading = false;
      });
      if (_searchQuery.isNotEmpty) {
        _queueUnifiedSearch(immediate: true);
      }
    } catch (e) {
      if (!mounted || !current()) return;
      if (pagedReadAccessDenied(e)) {
        _reportRead.invalidate();
        setState(() {
          _data = null;
        });
      }
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
    // 搜索中的分类树仅提供命中路径提示；展开节点不能把右侧全局结果截成某一类。
    if (_searchQuery.isNotEmpty) return;
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
    setState(() {
      _categoryType = type;
      _categoryId = id;
      _keyword = '';
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
    // 拼音组合中（composing 非空）：不同步对端、不过滤不搜索——半截拼音不触发
    //（组合结束会再通知一次，届时按完整词走；UtenSearchBar 防抖同款守卫，
    // 这里是页面自持 listener，须自己判）。
    if (source.value.composing != TextRange.empty) return;
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
      _keyword = query;
      _page = 1;
      _searchError = null;
      _noUnifiedSearchMatches = false;
      // 旧报表请求已失效，其完成分支不会再清 loading。先保留旧数据并结束
      // 旧 loading；防抖结束后报表按新全局口径独立加载。
      _loading = false;
      if (query.isEmpty) {
        _visibleFilterIds = null;
        _searchLoading = false;
      } else {
        // 左树先显示本地分类命中，授权往来单位的定位结果随后补充路径。
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

  Future<Set<String?>> _collectPartyMatches(
    String query,
    int requestGeneration,
  ) async {
    final categoryIds = <String?>{};
    var page = 1;
    var totalPages = 1;
    do {
      final json = await ref
          .read(apiClientProvider)
          .get(
            '/finance/reports/ar-ap/party-locations',
            query: {'keyword': query, 'page': page, 'size': 100},
          );
      if (!mounted || requestGeneration != _searchRequestGeneration) {
        return const <String?>{};
      }
      final items = json['items'];
      if (items is List) {
        for (final raw in items) {
          if (raw is! Map) continue;
          final partyType = raw['partyType']?.toString();
          if (partyType != 'CLIENT' && partyType != 'SUPPLIER') continue;
          final categoryId = raw['categoryId']?.toString().trim();
          categoryIds.add(
            categoryId == null || categoryId.isEmpty ? null : categoryId,
          );
        }
      }
      final parsedTotalPages = (json['totalPages'] as num?)?.toInt() ?? 1;
      totalPages = parsedTotalPages < 1 ? 1 : parsedTotalPages;
      page++;
    } while (page <= totalPages);
    return categoryIds;
  }

  Future<void> _runUnifiedSearch(String query, int requestGeneration) async {
    // 报表本身决定全局命中与顺序；左侧定位仅补提示，不能阻断、缩小或替换右表。
    unawaited(_load());
    try {
      final categoryIds = await _collectPartyMatches(query, requestGeneration);
      if (!mounted ||
          requestGeneration != _searchRequestGeneration ||
          query != _searchQuery) {
        return;
      }
      final resolution = resolveHierarchySearch<ProductCategoryNode>(
        roots: _forest,
        query: query,
        contentCategoryIds: categoryIds,
      );
      setState(() {
        _visibleFilterIds = resolution.visibleIds;
        _searchLoading = false;
        _searchError = null;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _searchRequestGeneration) return;
      setState(() {
        _searchLoading = false;
        _searchError = '分类定位暂不可用，往来单位搜索结果仍显示在右侧';
      });
    }
  }

  String? get _effectiveCategoryType => _keyword.isEmpty ? _categoryType : null;
  String? get _effectiveCategoryId => _keyword.isEmpty ? _categoryId : null;

  Map<String, dynamic> get _readQuery => <String, dynamic>{
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    'displayMode': _displayMode,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    if (_effectiveCategoryType != null) 'categoryType': _effectiveCategoryType,
    if (_effectiveCategoryId != null) 'categoryId': _effectiveCategoryId,
    'size': _size,
    ...sortQueryParams(_sortKey, _sortAsc),
    for (final entry in _filters.entries) 'f.${entry.key}': entry.value,
  };

  Future<void> _load({int? page, bool reuseMetadata = false}) async {
    final requestGeneration = ++_reportRequestGeneration;
    final readEpoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        requestGeneration == _reportRequestGeneration &&
        readEpoch == ref.read(exportContextEpochProvider);
    setState(() {
      _loading = true;
      _reportError = null;
    });
    final api = ref.read(apiClientProvider);
    try {
      final query = _readQuery;
      const endpoint = '/finance/reports/ar-ap/overview';
      bool queryCurrent() =>
          mounted &&
          readEpoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)) &&
          endpoint == '/finance/reports/ar-ap/overview' &&
          const DeepCollectionEquality().equals(query, _readQuery);
      final readIdentity = [readEpoch, api, endpoint, query];
      final requestedPage =
          page ??
          (const DeepCollectionEquality().equals(
                _acceptedReadQuery,
                readIdentity,
              )
              ? (_tableRows.visiblePage ?? _page)
              : _page);
      final read = _reportRead.begin(
        endpoint: endpoint,
        query: query,
        readerEpoch: readEpoch,
        reusePages: reuseMetadata,
        fetch: (parameters) =>
            ReportContactQuery(parameters).fetch(api, endpoint),
        isCurrent: queryCurrent,
        canPrefetch: () =>
            mounted &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true),
        onPrefetchError: (error) {
          if (!queryCurrent() ||
              error is! ApiException ||
              !pagedReadAccessDenied(error)) {
            return;
          }
          _reportRead.invalidate();
          ++_reportRequestGeneration;
          context.appError(error.message);
          setState(() {
            _data = null;
            _lastColumns = const [];
            _lastColumnSearchKeys = const {};
            _acceptedReadQuery = null;
            _loading = false;
          });
        },
      );
      final snapshot = await read.read(requestedPage) as ReportPageSnapshot;
      if (!mounted || !current() || !_reportRead.accept(snapshot)) return;
      setState(() {
        _data = snapshot.snapshot;
        _page = snapshot.page;
        _acceptedReadQuery = readIdentity;
        _lastColumns = _data!.columns;
        _lastColumnSearchKeys = _data!.columnSearchKeys;
        _noUnifiedSearchMatches = _keyword.isNotEmpty && _data!.total == 0;
        _loading = false;
        _reportError = null;
      });
    } catch (e) {
      if (!mounted || !current()) return;
      context.appError(humanErrorMessage(e) ?? '应收应付没有加载出来，请稍后重试');
      setState(() {
        if (pagedReadAccessDenied(e)) {
          _reportRead.invalidate();
          _data = null;
          _lastColumns = const [];
          _lastColumnSearchKeys = const {};
          _acceptedReadQuery = null;
        }
        _reportError = '加载应收应付失败，请重试';
        _loading = false;
      });
    }
  }

  bool get _acceptedQueryCurrent =>
      _data != null &&
      const DeepCollectionEquality().equals(_acceptedReadQuery, [
        ref.read(exportContextEpochProvider),
        ref.read(apiClientProvider),
        '/finance/reports/ar-ap/overview',
        _readQuery,
      ]);

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

  void _onFilterChanged(String key, String? value) {
    setState(() {
      if (value == null) {
        _filters.remove(key);
        if (!key.startsWith('search.')) _filters.remove('search.$key');
      } else {
        _filters[key] = value;
      }
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
    if (_effectiveCategoryType != null) 'categoryType': _effectiveCategoryType,
    if (_effectiveCategoryId != null) 'categoryId': _effectiveCategoryId,
    ...sortQueryParams(_sortKey, _sortAsc),
    for (final entry in _filters.entries) 'f.${entry.key}': entry.value,
  };

  /// 按真实服务器分页读取当前条件的前2000行，保持原预览上限及列格式。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final generation = _reportRequestGeneration;
    final epoch = ref.read(exportContextEpochProvider);
    return loadBoundedReportPrintPreview(
      api: api,
      endpointOf: () => '/finance/reports/ar-ap/overview',
      queryOf: () => _exportQuery,
      fetch: (endpoint, query) =>
          ReportContactQuery(query).fetch(api, endpoint),
      isCurrent: () =>
          mounted &&
          generation == _reportRequestGeneration &&
          epoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final selectedLabel = _searchQuery.isNotEmpty
        ? '全部搜索结果'
        : _categoryType == null
        ? '全部'
        : _categoryId == null
        ? (_categoryType == 'CLIENT' ? '客户类别(全部)' : '供应商类别(全部)')
        : (_categoryType == 'CLIENT'
              ? '客户：${_findIn(_clientTree, _categoryId!)?.name ?? ''}'
              : '供应商：${_findIn(_supplierTree, _categoryId!)?.name ?? ''}');

    Widget treeWidget = UtenCategoryTreeView<ProductCategoryNode>(
      nodes: _forest,
      flatLevelColors: true,
      nodeEnabledPredicate: (_) => true,
      selectedIds: {
        if (_searchQuery.isEmpty) ...{
          ?_categoryId,
          if (_categoryId == null && _categoryType == 'CLIENT') _clientRootId,
          if (_categoryId == null && _categoryType == 'SUPPLIER')
            _supplierRootId,
        },
      },
      expandOnRowTap: true,
      showSearch: false,
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _searchQuery,
      externalSearchLoading: _searchLoading,
      externalSearchError: _searchError,
      emptySearchText: _searchQuery.isEmpty ? null : '未找到匹配分类，往来单位结果见右侧',
      header: Padding(
        // 左缘贴 0（2026-10-18 全站分栏口径）：与分类页左栏搜索、返回键图标共缘。
        padding: const EdgeInsets.only(
          top: UtenSpacing.s12,
          bottom: UtenSpacing.s8,
        ),
        child: UtenHierarchySearchHeader(
          search: UtenSearchBar(
            key: const ValueKey('finance-ar-ap-unified-search'),
            controller: _treeSearchController,
            hint: '搜索分类/往来单位名称或编号',
            onSubmitted: (_) => _queueUnifiedSearch(immediate: true),
          ),
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

    final body = UtenSplitView(
      persistenceKey: 'finance.arAp',
      minTwoPaneWidth: 840,
      selectedLeadingLabel: selectedLabel,
      selectedLeadingKey: (_categoryType, _categoryId),
      compactHeader: Padding(
        // 左缘贴 0（2026-10-18 全站分栏口径），与展开态左栏搜索同缘。
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 180,
            child: UtenSearchBar(
              key: const ValueKey('finance-ar-ap-compact-search'),
              controller: _searchController,
              hint: '搜索分类/往来单位名称或编号',
              onSubmitted: (_) => _queueUnifiedSearch(immediate: true),
            ),
          ),
        ),
      ),
      leading: treeWidget,
      trailing: _buildRightPane(),
    );

    return Scaffold(
      appBar: UtenAppBar(
        title: '应收应付',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          UtenRefreshButton(
            busy: _loading || _treeLoading,
            // 整页刷新：分类树 + 台账（与 initState 同口径）。
            onRefresh: () async {
              await Future.wait([_loadTree(), _load()]);
            },
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _buildRightPane() {
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: _buildTable(),
      ),
    );
  }

  List<Widget> _buildFilters() => [
    FinanceDateRangeFilter(
      from: _from,
      to: _to,
      onChanged: (from, to) {
        setState(() {
          _from = from!;
          _to = to!;
        });
        _persistAndReload();
      },
    ),
    UtenDropdownScrollScope(
      nativeDropdown: true,
      child: DropdownButton<String>(
        key: const ValueKey('finance-ar-ap-display-mode'),
        value: _displayMode,
        isDense: true,
        items: const [
          DropdownMenuItem(value: 'ALL', child: Text('全部显示')),
          DropdownMenuItem(value: 'ANY', child: Text('应收≠0或应付≠0')),
          DropdownMenuItem(value: 'AR_ONLY', child: Text('只应收≠0')),
          DropdownMenuItem(value: 'AP_ONLY', child: Text('只应付≠0')),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() => _displayMode = value);
          _persistAndReload();
        },
      ),
    ),
    if (_data != null)
      Text(
        '共 ${_data!.total}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
  ];

  Widget _initialTableState(Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: _buildFilters(),
      ),
      Expanded(child: child),
    ],
  );

  Widget _buildTable() {
    final data = _acceptedQueryCurrent
        ? _data
        : (_data?.pendingQuery() ??
              (_loading ? _reportMetadata.loadingData : null));
    // 元数据未知时也先显示公共表壳；真实列确认后复用其布局。
    if (data == null && _lastColumns.isEmpty) {
      if (_noUnifiedSearchMatches) {
        return _initialTableState(
          Center(
            child: Text(
              '未找到匹配「$_searchQuery」的分类或往来单位',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      if (_reportError != null) {
        return _initialTableState(
          Center(
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
          ),
        );
      }
      return _initialTableState(
        Center(
          child: _loading
              ? const CircularProgressIndicator(strokeWidth: 2.5)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('请重新查询'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('查询'),
                    ),
                  ],
                ),
        ),
      );
    }
    final columns = (data?.columns ?? _lastColumns)
        .map(
          (c) => MasterColumnDef<Map<String, dynamic>>(
            key: c.key,
            label: c.label,
            width: (c.width ?? 120).toDouble(),
            type: c.type,
            columnSearchEnabled:
                (data?.columnSearchKeys ?? _lastColumnSearchKeys).contains(
                  c.key,
                ),
            exactValueOf:
                const {'number', 'money', 'count', 'int'}.contains(c.type)
                ? (row) => row[c.key] == null
                      ? null
                      : (row['${c.key}Exact'] ?? row[c.key]).toString()
                : null,
            sortable: isSortableReportType(c.type),
            value: (row) => formatReportCell(c, row),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      rowsController: _tableRows,
      expensiveRowMounts: false,
      tableKey:
          'features.finance.pages.finance_ar_ap_overview_page.FinanceArApOverviewPageState._buildTable.1',
      columns: columns,
      serverColumnSearchKeys: data?.columnSearchKeys ?? _lastColumnSearchKeys,
      headerFilterScopeDescription: '按往来单位汇总本币余额后筛选；合计覆盖当前条件的全部单位',
      items: data?.rows ?? const [],
      toolbarLeadingActions: _buildFilters(),
      toolbarActions: [
        UtenPrintPreviewButton(
          title: '应收应付',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}(最多前 2000 行)',
          loader: _printLoader,
          exportEndpoint: '/finance/reports/export',
          exportPermission: Perm.financeReportExport,
          exportReport: _exportReport,
          exportQuery: ReportContactQuery(_exportQuery).query,
          exportBody: ReportContactQuery(_exportQuery).exportBody,
          exportFilename: '应收应付',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/finance/reports/export',
          requiredPermission: Perm.financeReportExport,
          report: _exportReport,
          queryParams: ReportContactQuery(_exportQuery).query,
          bodyParams: ReportContactQuery(_exportQuery).exportBody,
          filename: '应收应付',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
      ],
      facets: {
        ...?data?.facets,
        'partyType': const [
          MasterFacetBucket(value: '客户', label: '客户', count: 0),
          MasterFacetBucket(value: '供应商', label: '供应商', count: 0),
        ],
      },
      nullCounts: const {},
      filters: _filters,
      onFilterChanged: _onFilterChanged,
      sortColumn: _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      isLoading: _loading,
      error: _acceptedQueryCurrent ? null : _reportError,
      onRetry: _load,
      emptyMessage: _noUnifiedSearchMatches && _filters.isEmpty
          ? '未找到匹配「$_searchQuery」的分类或往来单位'
          : '暂无应收应付数据',
      currentPage: data?.page ?? 1,
      totalPages: data?.totalPages ?? 1,
      paginationScope: (
        _reportRead.snapshotRevision,
        _effectiveCategoryType,
        _effectiveCategoryId,
        _from,
        _to,
        _displayMode,
        _keyword,
        PagedReadQueryKey(_filters),
      ),
      onPageChange: (p) {
        _page = p;
        return _load(page: p, reuseMetadata: true);
      },
    );
  }
}
