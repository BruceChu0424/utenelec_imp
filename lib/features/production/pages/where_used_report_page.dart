import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/router/page_navigation_session.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
// 物料反查产成品（production_where_used:view，只读 CQRS 报表）。
//
// 当前 BOM、旧生产快照、新生产履约需求和委外历史证据由后端分别聚合；
// 日期只过滤历史证据，当前 BOM 始终表示查询时现状。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_close_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_reference_picker_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_refresh_scope.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/network/api_client.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/paging/paged_query_identity.dart';
import '../../../shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/stock_ledger/material_trace_models.dart';
import '../../../shared/stock_ledger/material_trace_repository.dart';
import '../../../shared/stock_ledger/widgets/goods_production_trace_view.dart';
import '../../../shared/stock_ledger/widgets/material_trace_subject_picker.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_metadata_reuse.dart';
import '../../report/shared/report_paged_read.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_sort.dart';
import '../widgets/where_used_material_picker.dart';
import '../widgets/where_used_product_detail_dialog.dart';
import '../widgets/where_used_replacement_dialog.dart';

enum _WhereUsedSource {
  all('all', '全部已知关系', '当前 BOM 与所有历史证据'),
  current('current', '当前 BOM', '只看查询时仍有效的理论关系'),
  history('history', '全部历史', '新旧生产与委外历史证据'),
  production('production', '生产关系', '新生产需求与旧生产快照'),
  subcontract('subcontract', '委外关系', '委外需求、成本快照与发料痕迹');

  const _WhereUsedSource(this.apiValue, this.label, this.description);

  final String apiValue;
  final String label;
  final String description;
}

enum _TraceEntry {
  goods('goods', '货品'),
  document('document', '单据'),
  batch('batch', '生产批次');

  const _TraceEntry(this.value, this.label);
  final String value, label;
}

enum _TraceResultMode { actual, relationships }

typedef _TraceCandidate = ({
  MaterialTraceSubject subject,
  GoodsListItem? material,
});

typedef _WhereUsedFilters = ({
  _WhereUsedSource source,
  bool limitHistoryDates,
  DateTime from,
  DateTime to,
});

class _WhereUsedQuerySnapshot {
  const _WhereUsedQuerySnapshot({
    required this.material,
    required this.source,
    required this.from,
    required this.to,
    required this.page,
    required this.sortKey,
    required this.sortAscending,
    required this.headers,
  });

  final GoodsListItem material;
  final _WhereUsedSource source;
  final DateTime? from;
  final DateTime? to;
  final int page;
  final String? sortKey;
  final bool sortAscending;
  final Map<String, String> headers;
}

class WhereUsedReportPage extends ConsumerStatefulWidget {
  const WhereUsedReportPage({super.key});

  @override
  ConsumerState<WhereUsedReportPage> createState() =>
      _WhereUsedReportPageState();
}

class _WhereUsedReportPageState extends ConsumerState<WhereUsedReportPage> {
  final _navigation = PageNavigationSession();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
  }

  final _subjectController = TextEditingController();
  bool _queryDirty = false;
  GoodsListItem? _material;
  MaterialTraceSubject? _subject;
  _TraceEntry _entry = _TraceEntry.goods;
  _TraceResultMode _mode = _TraceResultMode.relationships;
  String _traceDirection = 'usage';
  int _readEpoch = 0;
  int _traceReloadTick = 0;
  final _refreshController = UtenRefreshController();
  _WhereUsedSource _source = _WhereUsedSource.all;
  bool _limitHistoryDates = false;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  int _page = 1;
  static const _size = 50;

  String? _sortKey;
  bool _sortAscending = true;
  final Map<String, String> _headers = {};
  ReportData? _data;
  final _reportMetadata = ReportMetadataReuse();
  late final _reportRead = ReportPagedRead(_reportMetadata);
  final _tableRows = MasterDataTableRowsController<Map<String, dynamic>>();
  Object? _acceptedPageReadQuery;
  _WhereUsedQuerySnapshot? _loadedQuery;
  int _loadGeneration = 0;
  bool _loading = false;
  bool _openingDetail = false;
  bool _replacing = false;
  Set<String> _selectedProductIds = {};
  String? _loadError;
  ModalRoute<dynamic>? _filterRoute;
  ModalRoute<dynamic>? _basisRoute;
  final _closingRoutes = <ModalRoute<dynamic>>{};

  /// 「返回即刷新」登记用的本页路径（build 首次捕获）。
  String? _myLocation;

  String get _subjectHint => switch (_entry) {
    _TraceEntry.goods => '搜索物料名称或编号',
    _TraceEntry.document => '搜索单据编号',
    _TraceEntry.batch => '搜索生产批次号',
  };

  static String _subjectLabel(MaterialTraceSubject subject) =>
      subject.code.isEmpty || subject.displayName == subject.code
      ? subject.displayName
      : '${subject.displayName} · ${subject.code}';

  void _restoreSubjectDisplay() {
    final subject = _subject;
    _subjectController.text = subject == null ? '' : _subjectLabel(subject);
    _queryDirty = false;
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      setState(() {
        ++_readEpoch;
        _invalidateLoadedResults();
      });
    });
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous == next || !mounted) return;
      _closeReadRoute(_filterRoute);
      _closeReadRoute(_basisRoute);
      setState(() {
        ++_readEpoch;
        ++_traceReloadTick;
        _subject = null;
        _material = null;
        _restoreSubjectDisplay();
        _entry = _TraceEntry.goods;
        _mode = _TraceResultMode.relationships;
        _traceDirection = 'usage';
        _page = 1;
        _sortKey = null;
        _sortAscending = true;
        _headers.clear();
        _invalidateLoadedResults();
      });
    });
  }

  void _closeReadRoute(ModalRoute<dynamic>? route) {
    if (route == null || !_closingRoutes.add(route)) return;
    unawaited(route.completed.whenComplete(() => _closingRoutes.remove(route)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route.navigator;
      if (navigator == null || !route.isActive) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  Widget _readPanel(
    BuildContext context,
    SensitiveReadBoundary boundary,
    Widget child, {
    bool filters = false,
  }) {
    final route = ModalRoute.of(context);
    if (filters) {
      _filterRoute = route;
    } else {
      _basisRoute = route;
    }
    return Consumer(
      builder: (context, ref, _) {
        if (ref.watch(sensitiveReadBoundaryProvider) != boundary) {
          _closeReadRoute(route);
          return const SizedBox.shrink();
        }
        return child;
      },
    );
  }

  @override
  void dispose() {
    _reportRead.dispose();
    _navigation.dispose();
    _refreshController.dispose();
    ++_loadGeneration;
    _closeReadRoute(_filterRoute);
    _closeReadRoute(_basisRoute);
    _subjectController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String _historyRangeLabel(_WhereUsedQuerySnapshot query) {
    if (query.from == null && query.to == null) return '全部历史';
    if (query.from == null) return '截至 ${_formatDate(query.to!)}';
    if (query.to == null) return '${_formatDate(query.from!)} 起';
    return '${_formatDate(query.from!)} 至 ${_formatDate(query.to!)}';
  }

  void _invalidateLoadedResults() {
    _loadGeneration += 1;
    _reportRead.invalidate();
    _data = null;
    _acceptedPageReadQuery = null;
    _loadedQuery = null;
    _loadError = null;
    _loading = false;
    _selectedProductIds = {};
  }

  static _TraceCandidate _materialCandidate(GoodsListItem material) => (
    material: material,
    subject: MaterialTraceSubject(
      type: 'GOODS',
      id: material.id,
      code: material.code ?? '',
      label: material.name ?? material.code ?? '',
      goodsId: material.id,
      goodsCode: material.code,
      goodsName: material.name,
      status: material.status,
    ),
  );

  Future<List<_TraceCandidate>> _loadSubjectSuggestions(
    String keyword,
    _TraceEntry entry,
  ) async {
    if (entry == _TraceEntry.goods) {
      final materials = await loadWhereUsedMaterialSuggestions(
        ref.read(apiClientProvider),
        keyword,
      );
      return materials.map(_materialCandidate).toList();
    }
    final result = await ref
        .read(materialTraceRepositoryProvider)
        .subjects(kind: entry.value, keyword: keyword);
    return [
      for (final subject in result.items) (subject: subject, material: null),
    ];
  }

  Future<void> _selectSubject(_TraceCandidate candidate) async {
    setState(() {
      _invalidateLoadedResults();
      _material = candidate.material;
      _subject = candidate.subject;
      _restoreSubjectDisplay();
      _mode = candidate.material == null
          ? _TraceResultMode.actual
          : _TraceResultMode.relationships;
      _traceDirection = 'usage';
      _page = 1;
      _sortKey = null;
      _sortAscending = true;
      _headers.clear();
      ++_traceReloadTick;
    });
    if (candidate.material != null) await _load();
  }

  void _clearSubject() {
    setState(() {
      ++_readEpoch;
      _subject = null;
      _material = null;
      _headers.clear();
      _restoreSubjectDisplay();
      _invalidateLoadedResults();
      ++_traceReloadTick;
    });
  }

  Future<void> _pickSubject([String keyword = '']) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = _readEpoch;
    final entry = _entry;
    final initialKeyword = _queryDirty ? keyword : '';
    _TraceCandidate? candidate;
    if (entry == _TraceEntry.goods) {
      final material = await showWhereUsedMaterialPicker(
        context,
        ref,
        initialKeyword: initialKeyword,
      );
      if (material != null) candidate = _materialCandidate(material);
    } else {
      final subject = await showMaterialTraceSubjectPicker(
        context,
        ref,
        kind: entry.value,
        initialKeyword: initialKeyword,
      );
      if (subject != null) candidate = (subject: subject, material: null);
    }
    if (!mounted ||
        candidate == null ||
        entry != _entry ||
        epoch != _readEpoch ||
        boundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    // The picker owns record selection, not the report GET it starts. Releasing
    // its busy state here lets an identity/endpoint/permission change retire a
    // pending report immediately, just like selecting an inline suggestion.
    unawaited(_selectSubject(candidate));
  }

  void _changeEntry(String? value) {
    final entry = _TraceEntry.values.where((e) => e.value == value).firstOrNull;
    if (entry == null || entry == _entry) return;
    setState(() {
      ++_readEpoch;
      _entry = entry;
      _subject = null;
      _material = null;
      _restoreSubjectDisplay();
      _mode = entry == _TraceEntry.goods
          ? _TraceResultMode.relationships
          : _TraceResultMode.actual;
      _traceDirection = 'usage';
      _page = 1;
      _sortKey = null;
      _sortAscending = true;
      _headers.clear();
      _invalidateLoadedResults();
      ++_traceReloadTick;
    });
  }

  Future<void> _refreshQuery() async {
    if (_subject == null) return _pickSubject();
    if (_mode == _TraceResultMode.actual) {
      await _refreshController.run(() => setState(() => ++_traceReloadTick));
    } else {
      _page = 1;
      await _load();
    }
  }

  Future<void> _load({bool reuseMetadata = false, int? page}) async {
    final material = _material;
    if (material == null) {
      context.appError('请先选择要反查的物料');
      return;
    }
    if (_limitHistoryDates && _from.isAfter(_to)) {
      context.appError('起始日期不能晚于结束日期');
      return;
    }

    final snapshot = _WhereUsedQuerySnapshot(
      material: material,
      source: _source,
      from: _limitHistoryDates ? _from : null,
      to: _limitHistoryDates ? _to : null,
      page:
          page ??
          (_data != null &&
                  samePagedReadQuery(_acceptedPageReadQuery, _pageReadQuery)
              ? _tableRows.visiblePage ?? _page
              : _page),
      sortKey: _sortKey,
      sortAscending: _sortAscending,
      headers: Map.unmodifiable(_headers),
    );
    final generation = ++_loadGeneration;
    final readEpoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        readEpoch == ref.read(exportContextEpochProvider);
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final query = <String, dynamic>{
        'materialGoodsId': snapshot.material.id,
        'source': snapshot.source.apiValue,
        if (snapshot.from != null) 'dateFrom': _formatDate(snapshot.from!),
        if (snapshot.to != null) 'dateTo': _formatDate(snapshot.to!),
        'size': _size,
        ...sortQueryParams(snapshot.sortKey, snapshot.sortAscending),
        for (final entry in snapshot.headers.entries)
          'f.${entry.key}': entry.value,
      };
      final api = ref.read(apiClientProvider);
      bool queryCurrent() =>
          mounted &&
          readEpoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)) &&
          samePagedReadQuery(query, _pageReadQuery);
      final read = _reportRead.begin(
        endpoint: '/production/reports/where-used',
        query: query,
        readerEpoch: readEpoch,
        reusePages: reuseMetadata,
        fetch: (parameters) =>
            api.get('/production/reports/where-used', query: parameters),
        isCurrent: queryCurrent,
        canPrefetch: () =>
            mounted &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true),
        onPrefetchError: (error) {
          if (!queryCurrent() || !pagedReadAccessDenied(error)) return;
          setState(() {
            _invalidateLoadedResults();
            _loadError = (error as ApiException).message;
          });
        },
      );
      final cached = await read.read(snapshot.page) as ReportPageSnapshot;
      if (!mounted || !current() || !_reportRead.accept(cached)) return;
      setState(() {
        _acceptedPageReadQuery = freezePagedReadQuery(query);
        _data = cached.snapshot;
        _loadedQuery = snapshot;
        _page = snapshot.page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || !current()) return;
      final revoked =
          error is ApiException &&
          ({401, 403, 404}.contains(error.httpStatus) ||
              {'UNAUTHORIZED', 'FORBIDDEN', 'NOT_FOUND'}.contains(error.code));
      setState(() {
        if (revoked) {
          _data = null;
          _loadedQuery = null;
        }
        _loadError = error is ApiException ? error.message : '反查加载失败，请稍后重试';
        _loading = false;
        final loaded = _loadedQuery;
        if (_data != null && loaded != null) {
          _page = loaded.page;
          _sortKey = loaded.sortKey;
          _sortAscending = loaded.sortAscending;
          _headers
            ..clear()
            ..addAll(loaded.headers);
        }
      });
    }
  }

  Map<String, dynamic> get _pageReadQuery => {
    'materialGoodsId': _material?.id,
    'source': _source.apiValue,
    if (_limitHistoryDates) 'dateFrom': _formatDate(_from),
    if (_limitHistoryDates) 'dateTo': _formatDate(_to),
    'size': _size,
    ...sortQueryParams(_sortKey, _sortAscending),
    for (final entry in _headers.entries) 'f.${entry.key}': entry.value,
  };

  Future<void> _openProductDetail(Map<String, dynamic> row) async {
    if (_openingDetail) return;
    final loadedQuery = _loadedQuery;
    if (loadedQuery == null) {
      context.appInfo('请先按当前条件查询后再打开详情');
      return;
    }

    _openingDetail = true;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = _readEpoch;
    try {
      final permissions = ref.read(currentPermissionsProvider);
      final result = await showWhereUsedProductDetailDialog(
        context: context,
        row: row,
        material: loadedQuery.material,
        historyRangeLabel: _historyRangeLabel(loadedQuery),
        canViewGoods: permissions.contains(Perm.goodsView),
        canViewStock: permissions.contains(Perm.stockView),
        readBoundary: boundary,
      );
      if (!mounted ||
          result == null ||
          epoch != _readEpoch ||
          boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }

      if (result.link == WhereUsedProductLink.stockMovements) {
        context.push(_stockMovementPath(result.productId));
        return;
      }
      final detail = result.detail;
      if (detail == null) return;
      // 货品详情整页 (tab=bom 组装信息直达 BOM)；「出入库流水」按钮
      // 由详情页按 stock:view 权限自行决定是否显示。
      await _navigation.push(
        RoutePath.basicinfoGoodsDetail(
          detail.id,
          tab: result.link == WhereUsedProductLink.bom ? 'bom' : 'basic',
        ),
      );
    } finally {
      _openingDetail = false;
    }
  }

  String _stockMovementPath(String goodsId) => Uri(
    path: RouteName.stockMovement,
    queryParameters: {'goodsId': goodsId},
  ).toString();

  void _onSortChange(String? column, bool ascending) {
    if (_loading) return;
    setState(() {
      _sortKey = column;
      _sortAscending = ascending;
      _page = 1;
    });
    _load();
  }

  void _onHeaderChanged(String key, String? value) {
    if (_loading) return;
    setState(() {
      if (value == null || value.isEmpty) {
        _headers.remove(key);
      } else {
        _headers[key] = value;
      }
      _selectedProductIds = {};
      _page = 1;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unattributed =
        (_data?.meta['unattributedDemandCount'] as num?)?.toInt() ?? 0;
    // 返回即刷新：已查出的结果在行点击 push 的计划详情操作后可能过期，
    // 返回时重查当前查询；尚未查询（无物料/无结果）不触发，避免弹「请先选物料」。
    _myLocation ??= currentLocationOr(context, RouteName.production);
    ref.onPageResume(_myLocation!, () {
      if (_subject != null) _refreshQuery();
    });
    return UtenRefreshScope(
      controller: _refreshController,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '物料反查与追溯',
          leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.production),
          ),
          actions: [
            IconButton(
              key: const Key('where-used-basis'),
              icon: const Icon(Icons.info_outline_rounded),
              tooltip: '依据说明',
              onPressed: _showBasis,
            ),
            UtenRefreshButton(
              tooltip: '刷新当前结果',
              enabled: !(_subject == null || _loading),
              busy: _loading,
              onRefresh: _refreshQuery,
            ),
          ],
        ),
        body: SafeArea(
          child: UtenContentContainer.wide(
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: UtenCollapsingHeaderScrollView(
                collapsingHeader: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        child: _buildQueryToolbar(),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    if (_entry != _TraceEntry.document) ...[
                      _buildTitle(theme),
                      const SizedBox(height: UtenSpacing.s12),
                    ],
                    if (_mode == _TraceResultMode.relationships &&
                        unattributed > 0)
                      _UnattributedNotice(
                        count: unattributed,
                        quantity:
                            _data?.meta['unattributedDemandQtyExact'] ??
                            _data?.meta['unattributedDemandQty'],
                      ),
                  ],
                ),
                body: _buildResultPane(theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_entry == _TraceEntry.goods)
          UtenSegmentRow<_TraceResultMode>(
            key: const Key('where-used-result-mode'),
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(
                value: _TraceResultMode.actual,
                label: Text('实际追溯'),
              ),
              ButtonSegment(
                value: _TraceResultMode.relationships,
                label: const Text('BOM 与历史关系'),
                enabled: _subject?.isGoods ?? _entry == _TraceEntry.goods,
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (values) {
              final mode = values.single;
              if (mode == _mode) return;
              setState(() => _mode = mode);
              if (mode == _TraceResultMode.relationships &&
                  _material != null &&
                  _data == null) {
                _load();
              }
            },
          ),
        if (_mode == _TraceResultMode.actual &&
            (_entry != _TraceEntry.document))
          UtenSegmentRow<String>(
            key: const Key('where-used-trace-direction'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'usage', label: Text('用到哪些产品')),
              ButtonSegment(value: 'materials', label: Text('用了哪些物料')),
            ],
            selected: {_traceDirection},
            onSelectionChanged: (values) =>
                setState(() => _traceDirection = values.single),
          ),
      ],
    );
  }

  Widget _buildQueryToolbar() {
    final theme = Theme.of(context);
    final height = UtenControlMetrics.controlHeight(context);
    ButtonStyle toolbarAction(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          minimumSize: WidgetStatePropertyAll(Size.square(height)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
        );
    // This query row has a standard command height, independently of the
    // compact filter-row and ordinary form-field heights elsewhere.
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          isDense: true,
          visualDensity: VisualDensity.standard,
          floatingLabelBehavior: FloatingLabelBehavior.never,
          constraints: BoxConstraints(minHeight: height),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          prefixIconConstraints: BoxConstraints(
            minWidth: height,
            minHeight: height,
          ),
          suffixIconConstraints: BoxConstraints(
            minWidth: height,
            minHeight: height,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: toolbarAction(theme.textButtonTheme.style),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: toolbarAction(theme.iconButtonTheme.style),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boundary = ref.watch(sensitiveReadBoundaryProvider);
          final epoch = _readEpoch;
          final entryKind = _entry;
          bool current() =>
              mounted &&
              epoch == _readEpoch &&
              entryKind == _entry &&
              boundary == ref.read(sensitiveReadBoundaryProvider);
          final entryText = TextPainter(
            text: TextSpan(
              text: _entry.label,
              style: theme.textTheme.bodyLarge,
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final entryWidth = (entryText.width + height + UtenSpacing.s24)
              .clamp(112.0, double.infinity)
              .clamp(0.0, constraints.maxWidth);
          entryText.dispose();
          Widget entry() => Semantics(
            label: '查询入口',
            child: UtenDropdownField(
              key: const Key('where-used-entry-kind'),
              value: _entry.value,
              allowClear: false,
              menuMatchContentWidth: true,
              enabled: !_loading,
              items: [
                for (final entry in _TraceEntry.values)
                  UtenDropdownItem(value: entry.value, label: entry.label),
              ],
              onChanged: _changeEntry,
            ),
          );
          Widget subject(double width) => SizedBox(
            key: const Key('where-used-query-subject'),
            width: width,
            child: UtenReferencePickerField<_TraceCandidate>(
              controller: _subjectController,
              label: _subjectHint,
              hint: _subjectHint,
              enabled: !_loading,
              suggestionScope: (boundary, epoch, entryKind),
              isCurrent: current,
              loadSuggestions: (keyword) async {
                if (!current()) return const [];
                final candidates = await _loadSubjectSuggestions(
                  keyword,
                  entryKind,
                );
                return current() ? candidates : const [];
              },
              labelOf: (candidate) => _subjectLabel(candidate.subject),
              onInputChanged: (text) {
                _queryDirty =
                    text != (_subject == null ? '' : _subjectLabel(_subject!));
              },
              onSelected: (candidate) {
                if (current()) unawaited(_selectSubject(candidate));
              },
              onOpenPicker: (keyword) async {
                if (current()) await _pickSubject(keyword);
              },
              onClear: () {
                if (current()) _clearSubject();
              },
              onEditingDismissed: () {
                if (current()) _restoreSubjectDisplay();
              },
              optionBuilder: (context, candidate) {
                final material = candidate.material;
                final subject = candidate.subject;
                final details = [
                  if (material != null) ...[
                    if (material.model?.isNotEmpty ?? false) material.model!,
                    if (material.spec?.isNotEmpty ?? false) material.spec!,
                  ] else
                    materialTraceSubjectTypeLabel(subject.type),
                  if (subject.status?.isNotEmpty ?? false)
                    materialTraceStatusLabel(subject.status!),
                ];
                return ListTile(
                  key: ValueKey((
                    'where-used-suggestion',
                    subject.type,
                    subject.id,
                  )),
                  dense: true,
                  title: Text(
                    _subjectLabel(subject),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: details.isEmpty ? null : Text(details.join(' · ')),
                );
              },
            ),
          );
          final hasFilters =
              _limitHistoryDates ||
              (_mode == _TraceResultMode.relationships &&
                  _source != _WhereUsedSource.all);
          final filterLabel = hasFilters ? '筛选 · 已设置' : '筛选';
          final actions = <Widget>[
            UtenButton(
              key: const Key('where-used-search'),
              onPressed: _loading || _subject == null ? null : _refreshQuery,
              isLoading: _loading,
              child: const Text('查询'),
            ),
            if (constraints.maxWidth < 460)
              IconButton.outlined(
                key: const Key('where-used-filters'),
                tooltip: filterLabel,
                isSelected: hasFilters,
                icon: const Icon(Icons.filter_alt_outlined),
                selectedIcon: const Icon(Icons.filter_alt_rounded),
                onPressed: _loading ? null : _showFilters,
              )
            else
              UtenButton(
                key: const Key('where-used-filters'),
                type: UtenButtonType.secondary,
                onPressed: _loading ? null : _showFilters,
                child: Text(filterLabel),
              ),
          ];
          if (constraints.maxWidth >= 760 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21) {
            return Row(
              children: [
                SizedBox(width: entryWidth, child: entry()),
                const SizedBox(width: UtenSpacing.s12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: LayoutBuilder(
                      builder: (_, available) => subject(available.maxWidth),
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                ...actions.expand(
                  (action) => [action, const SizedBox(width: UtenSpacing.s8)],
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(width: entryWidth, child: entry()),
                  ...actions,
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Align(
                alignment: Alignment.centerLeft,
                child: subject(constraints.maxWidth.clamp(0.0, 360.0)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showBasis() {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    return showUtenAdaptivePanel<void>(
      context: context,
      widthFraction: UtenPanelWidth.form,
      builder: (panelContext) => _readPanel(
        panelContext,
        boundary,
        Column(
          children: [
            ListTile(
              title: const Text('关系依据说明'),
              trailing: UtenCloseButton(
                onPressed: () => Navigator.of(panelContext).pop(),
                tooltip: '关闭',
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Column(
                  children: [
                    const Text('实际追溯读取凭证与过账事实；BOM、冻结需求和旧快照只说明关系，不表示实际耗用。'),
                    const SizedBox(height: UtenSpacing.s12),
                    if (_material != null) ...[
                      _SelectedMaterialCard(material: _material!),
                      const SizedBox(height: UtenSpacing.s12),
                    ],
                    _CoverageNotice(theme: Theme.of(panelContext)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(() => _basisRoute = null);
  }

  Future<void> _showFilters() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = _readEpoch;
    var draft = (
      source: _source,
      limitHistoryDates: _limitHistoryDates,
      from: _from,
      to: _to,
    );
    String? error;
    final result = await showUtenAdaptivePanel<_WhereUsedFilters>(
      context: context,
      widthFraction: UtenPanelWidth.form,
      builder: (panelContext) => _readPanel(
        panelContext,
        boundary,
        StatefulBuilder(
          builder: (context, update) => Column(
            children: [
              ListTile(
                title: Text(
                  _mode == _TraceResultMode.actual ? '筛选实际追溯' : '筛选 BOM 与历史关系',
                ),
                trailing: UtenCloseButton(
                  onPressed: () => Navigator.of(panelContext).pop(),
                  tooltip: '关闭',
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: _buildFilterPane(Theme.of(context), draft, (value) {
                    update(() {
                      draft = value;
                      error = null;
                    });
                  }),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(panelContext).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('where-used-filter-apply'),
                        onPressed: () {
                          if (draft.limitHistoryDates &&
                              draft.from.isAfter(draft.to)) {
                            update(() => error = '起始日期不能晚于结束日期');
                            return;
                          }
                          Navigator.of(panelContext).pop(draft);
                        },
                        child: const Text('应用筛选'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        filters: true,
      ),
    );
    _filterRoute = null;
    if (!mounted ||
        result == null ||
        epoch != _readEpoch ||
        boundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    setState(() {
      _source = result.source;
      _limitHistoryDates = result.limitHistoryDates;
      _from = result.from;
      _to = result.to;
      _page = 1;
      _invalidateLoadedResults();
    });
    if (_subject != null) await _refreshQuery();
  }

  Widget _buildFilterPane(
    ThemeData theme,
    _WhereUsedFilters filters,
    ValueChanged<_WhereUsedFilters> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_mode == _TraceResultMode.relationships) ...[
          _filterLabel('关系来源', info: filters.source.description),
          UtenDropdownField(
            key: const Key('where-used-source-filter'),
            value: filters.source.apiValue,
            allowClear: false,
            enabled: !_loading,
            items: [
              for (final source in _WhereUsedSource.values)
                UtenDropdownItem(value: source.apiValue, label: source.label),
            ],
            onChanged: (value) {
              final source = _WhereUsedSource.values
                  .where((s) => s.apiValue == value)
                  .firstOrNull;
              if (source != null) {
                onChanged((
                  source: source,
                  limitHistoryDates: filters.limitHistoryDates,
                  from: filters.from,
                  to: filters.to,
                ));
              }
            },
          ),
          const SizedBox(height: UtenSpacing.s16),
        ],
        _filterLabel(_mode == _TraceResultMode.actual ? '凭证日期范围' : '历史日期范围'),
        UtenSegmentRow<bool>(
          key: const Key('where-used-history-range'),
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('全部历史', key: Key('where-used-all-history')),
            ),
            ButtonSegment(
              value: false,
              label: Text('自定义', key: Key('where-used-custom-history')),
            ),
          ],
          selected: {!filters.limitHistoryDates},
          onSelectionChanged: (values) => onChanged((
            source: filters.source,
            limitHistoryDates: !values.single,
            from: filters.from,
            to: filters.to,
          )),
        ),
        const SizedBox(height: UtenSpacing.s4),
        if (_mode == _TraceResultMode.relationships)
          Text(
            '日期只过滤生产/委外历史，当前 BOM 不受影响',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (filters.limitHistoryDates) ...[
          const SizedBox(height: UtenSpacing.s8),
          _dateButton(
            key: const Key('where-used-date-from'),
            label: '起 ${_formatDate(filters.from)}',
            initialDate: filters.from,
            onPicked: (value) => onChanged((
              source: filters.source,
              limitHistoryDates: filters.limitHistoryDates,
              from: value,
              to: filters.to,
            )),
          ),
          const SizedBox(height: UtenSpacing.s4),
          _dateButton(
            key: const Key('where-used-date-to'),
            label: '止 ${_formatDate(filters.to)}',
            initialDate: filters.to,
            onPicked: (value) => onChanged((
              source: filters.source,
              limitHistoryDates: filters.limitHistoryDates,
              from: filters.from,
              to: value,
            )),
          ),
        ],
        const SizedBox(height: UtenSpacing.s12),
      ],
    );
  }

  Widget _dateButton({
    required Key key,
    required String label,
    required DateTime initialDate,
    required ValueChanged<DateTime> onPicked,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: key,
        onPressed: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: initialDate,
            firstDate: DateTime(2010),
            lastDate: DateTime(2100),
          );
          if (picked != null) {
            final date = ChinaDateTime.dateOnly(picked);
            if (date != ChinaDateTime.dateOnly(initialDate)) onPicked(date);
          }
        },
        icon: const Icon(Icons.event_outlined, size: 18),
        label: Align(alignment: Alignment.centerLeft, child: Text(label)),
      ),
    );
  }

  Widget _buildTablePane(ThemeData theme) {
    if (_material == null) {
      return _StatePanel(
        icon: Icons.manage_search_rounded,
        title: '先搜索一个物料',
        info: '可搜索当前、停用、软删除及迁移占位的历史物料。',
        actionLabel: '选择物料',
        onAction: _pickSubject,
      );
    }
    if (_loading && _data == null) {
      return _buildTable(_reportMetadata.loadingData);
    }
    if (_loadError != null && _data == null) {
      return _StatePanel(
        icon: Icons.cloud_off_outlined,
        title: '暂时无法加载反查结果',
        message: _loadError!,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final data = _data;
    if (data == null) {
      return _StatePanel(
        icon: Icons.search_rounded,
        title: '条件已更新',
        message: '点击“查询已知关系”加载当前条件。',
        actionLabel: '查询',
        onAction: _load,
      );
    }

    final table = _buildTable(data);
    if (!_loading && _loadError == null) return table;
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_loadError != null)
          Material(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
            child: ListTile(
              dense: true,
              leading: Icon(
                Icons.error_outline_rounded,
                color: theme.colorScheme.error,
              ),
              title: Text('刷新失败，已保留上次成功结果：$_loadError'),
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          ),
        Expanded(child: table),
      ],
    );
  }

  Widget _buildResultPane(ThemeData theme) {
    if (_mode == _TraceResultMode.relationships) return _buildTablePane(theme);
    final subject = _subject;
    if (subject == null) {
      return _StatePanel(
        icon: Icons.manage_search_rounded,
        title: '选择要追溯的${_entry.label}',
        message: _entry == _TraceEntry.batch
            ? '按系统实际生产批次查询来源与去向。'
            : '选择具体货品或单据后查看权限范围内的实际记录。',
        actionLabel: '选择${_entry.label}',
        onAction: _pickSubject,
      );
    }
    final epoch = _readEpoch;
    return GoodsProductionTraceView.query(
      key: ValueKey(('where-used-actual', subject.identity, _readEpoch)),
      subject: subject,
      direction: _traceDirection,
      showDirectionSelector: false,
      dateFrom: _limitHistoryDates ? _formatDate(_from) : null,
      dateTo: _limitHistoryDates ? _formatDate(_to) : null,
      reloadTick: _traceReloadTick,
      onTraceSubject: (value) {
        if (mounted && epoch == _readEpoch) _followTraceSubject(value);
      },
    );
  }

  void _followTraceSubject(MaterialTraceSubject subject) {
    setState(() {
      _traceDirection = 'usage';
      _subject = subject;
      _entry = subject.isGoods
          ? _TraceEntry.goods
          : subject.type == 'PRODUCTION_OUTPUT_LOT'
          ? _TraceEntry.batch
          : _TraceEntry.document;
      _material = subject.isGoods
          ? GoodsListItem(
              id: subject.id,
              code: subject.code,
              name: subject.displayName,
              status: subject.status,
            )
          : null;
      _mode = _TraceResultMode.actual;
      _page = 1;
      _invalidateLoadedResults();
      ++_traceReloadTick;
    });
  }

  Map<String, dynamic> _exportQuery(_WhereUsedQuerySnapshot query) => {
    'materialGoodsId': query.material.id,
    'source': query.source.apiValue,
    if (query.from != null) 'dateFrom': _formatDate(query.from!),
    if (query.to != null) 'dateTo': _formatDate(query.to!),
    ...sortQueryParams(query.sortKey, query.sortAscending),
    for (final entry in query.headers.entries) 'f.${entry.key}': entry.value,
  };

  Future<UtenExportSelection?> _selectExportFormat() async {
    final query = _loadedQuery;
    if (query == null) return null;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final l10n = AppLocalizations.of(context);
    final format = await showDialog<String>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(l10n.whereUsedExportFiltered),
        content: Text(l10n.whereUsedExportDescription),
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          UtenButton(
            onPressed: () => Navigator.of(dialogContext).pop('xlsx'),
            child: Text(l10n.whereUsedExportExcel),
          ),
          UtenButton(
            onPressed: () => Navigator.of(dialogContext).pop('pdf'),
            child: Text(l10n.whereUsedExportPdf),
          ),
        ],
      ),
    );
    if (!mounted || format == null) return null;
    return UtenExportSelection(
      bodyParams: {'format': format},
      extension: format,
      stillCurrent: () =>
          mounted &&
          identical(query, _loadedQuery) &&
          boundary == ref.read(sensitiveReadBoundaryProvider),
    );
  }

  Future<void> _replaceSelected() async {
    final query = _loadedQuery;
    if (_replacing ||
        _loading ||
        query == null ||
        _selectedProductIds.isEmpty ||
        !ref.read(currentPermissionsProvider).contains(Perm.goodsBomEdit)) {
      return;
    }
    final epoch = _readEpoch;
    setState(() => _replacing = true);
    try {
      final applied = await showWhereUsedReplacementDialog(
        context: context,
        material: query.material,
        productIds: _selectedProductIds,
      );
      if (!mounted || epoch != _readEpoch) return;
      if (applied == null) {
        setState(() => _selectedProductIds = {});
        await _load();
        return;
      }
      if (!applied) return;
      setState(() => _selectedProductIds = {});
      context.appSuccess(
        AppLocalizations.of(context).whereUsedReplacementSuccess,
      );
      await _load();
    } finally {
      if (mounted) setState(() => _replacing = false);
    }
  }

  Widget _buildTable(ReportData acceptedData) {
    final matches = samePagedReadQuery(_acceptedPageReadQuery, _pageReadQuery);
    final data = matches ? acceptedData : acceptedData.pendingQuery();
    final l10n = AppLocalizations.of(context);
    final columns = data.columns
        .map(
          (column) => MasterColumnDef<Map<String, dynamic>>(
            key: column.key,
            label: column.label,
            width: (column.width ?? 120).toDouble(),
            type: column.type,
            sortable: isSortableReportType(column.type),
            columnSearchEnabled: data.columnSearchKeys.contains(column.key),
            exactValueOf:
                const {'number', 'money', 'count', 'int'}.contains(column.type)
                ? (row) => row[column.key] == null
                      ? null
                      : (row['${column.key}Exact'] ?? row[column.key])
                            .toString()
                : null,
            value: (row) => formatReportCell(column, row),
            defaultVisible: !const {
              'categoryName',
              'executionSegmentCount',
              'legacyPlanCount',
              'subcontractOrderCount',
              'subcontractIssueCount',
            }.contains(column.key),
          ),
        )
        .toList();
    final range = !matches || _loadedQuery == null
        ? '当前条件'
        : _historyRangeLabel(_loadedQuery!);
    return MasterDataTableView<Map<String, dynamic>>(
      rowsController: _tableRows,
      expensiveRowMounts: false,
      tableKey:
          'features.production.pages.where_used_report_page.WhereUsedReportPageState._buildTable.1',
      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
      primary: true,
      columns: columns,
      requiredLeadingColumnKeys: const ['goodsName', 'goodsCode', 'colorName'],
      selectable: true,
      idOf: (row) =>
          row['__currentBom'] == true ? row['__productId']?.toString() : null,
      selectedIds: _selectedProductIds,
      onSelectedIdsChanged: (ids) => setState(() => _selectedProductIds = ids),
      unselectableLeadingBuilder: (context, row) => Tooltip(
        message: l10n.whereUsedHistoryNotReplaceable,
        child: const Icon(Icons.history_rounded, size: 18),
      ),
      batchActionsBuilder: (context, ids) => [
        if (ref.watch(currentPermissionsProvider).contains(Perm.goodsBomEdit))
          UtenButton(
            key: const Key('where-used-replace'),
            onPressed: ids.isEmpty || _loading || _replacing
                ? null
                : _replaceSelected,
            child: Text(l10n.whereUsedReplaceAction),
          ),
      ],
      toolbarLeadingActions: [
        Text(_source.label, style: Theme.of(context).textTheme.bodySmall),
      ],
      toolbarActions: [
        if (_loadedQuery != null)
          UtenExportButton(
            key: const Key('where-used-export'),
            endpoint: '/production/reports/where-used/export',
            report: 'where-used',
            queryParams: _exportQuery(_loadedQuery!),
            requiredPermission: Perm.productionWhereUsedExport,
            enabled: !_loading,
            label: l10n.whereUsedExportFiltered,
            filename: l10n.whereUsedExportFilename,
            prepareExport: _selectExportFormat,
          ),
        Text(
          data.total < 0
              ? (_loading ? '正在加载当前条件的已知关系' : '当前条件尚未取得结果')
              : '共 ${data.total} 个成品/半成品',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_limitHistoryDates)
          Text(range, style: Theme.of(context).textTheme.bodySmall),
      ],
      items: data.rows,
      facets: data.facets,
      nullCounts: const {},
      filters: _headers,
      serverColumnSearchKeys: data.columnSearchKeys,
      onFilterChanged: _onHeaderChanged,
      sortColumn: _sortKey,
      sortAscending: _sortAscending,
      onSortChange: _onSortChange,
      onRowTap: _openProductDetail,
      isLoading: _loading,
      emptyMessage:
          '未找到可识别的已知关系(来源：${_source.label}，历史范围：$range)。'
          '可切换到“全部已知关系”或“全部历史”；当前仍可能受 BOM 拒绝行影响。',
      currentPage: data.page,
      totalPages: data.totalPages,
      paginationScope: (
        _reportRead.snapshotRevision,
        _material?.id,
        _source,
        _limitHistoryDates,
        _from,
        _to,
        _sortKey,
        _sortAscending,
      ),
      onPageChange: (page) async {
        if (_loading) return;
        _page = page;
        await _load(page: page, reuseMetadata: true);
      },
    );
  }

  Widget _filterLabel(String text, {String? info}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Row(
        children: [
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.25,
              ),
            ),
          ),
          if (info != null) UtenFieldHintIcon(info: info, dense: true),
        ],
      ),
    );
  }
}

class _CoverageNotice extends StatelessWidget {
  const _CoverageNotice({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.38),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.hub_outlined,
            size: 20,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '当前可用的已知关系 = 当前 BOM + 新生产需求 + 旧生产快照 + 委外历史证据。'
              '各来源分别显示、不混算；旧委外发料数量仍待迁移复核，仅作追溯。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnattributedNotice extends StatelessWidget {
  const _UnattributedNotice({required this.count, required this.quantity});

  final int count;
  final Object? quantity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Text(
        '另有 $count 条旧版生产需求(需求量 ${quantity ?? '—'})没有执行段，'
        '无法可靠归属到具体产成品，系统未作猜配。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

class _SelectedMaterialCard extends StatelessWidget {
  const _SelectedMaterialCard({required this.material});

  final GoodsListItem material;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = <String>[
      if ((material.code ?? '').isNotEmpty) '编号 ${material.code}',
      if ((material.status ?? '').isNotEmpty) '状态 ${material.status}',
      if (material.autoCreated) '历史占位',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            material.name ?? '(无名称)',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (labels.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              labels.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    this.message,
    this.info,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? info;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 42,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (info?.isNotEmpty == true)
                        UtenFieldHintIcon(info: info, dense: true),
                    ],
                  ),
                  if (message?.isNotEmpty == true) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      message!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    FilledButton.tonal(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
