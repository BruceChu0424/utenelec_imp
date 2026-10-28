import '../../../shared/paging/paged_query_identity.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
// 钱流明细/汇总报表页（finance_report:view）—— 镜像 sales_report_page。
//
// 一张卡（[cardId] = detail|summary）内用 UtenFilterToolbar 分段切多个报表变体（应收/应付/收款/付款/费用/收入…），
// 每个变体对应后端一个 endpoint（+ 固定参数如 direction=AR）。
//
// 后端 GET /api/finance/reports/{group}/{view} 返回 ReportTableResponse：
//   { columns, rows(显示就绪), facets, page, totalPages, total }。
// UI：分类与短搜索同排，日期范围与业务筛选按需换行，表格随页面滚动承接
//   （标题行每列可 autofilter + 横滚 + 翻页）。默认日期范围 = 上月今日..今日（defaultReportFrom()，收紧默认；firstDate 仍 2010 可手选更早）。
//
// 筛选口径（报表变体/日期范围/facet/排序）按账号服务端持久化
// （report.finance.detail|summary，ReportFilterPrefs；变体存下标字符串于 docType）；关键字不持久化。
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../shared/models/paged_result.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
import '../../basic_data/models/client_node.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_metadata_reuse.dart';
import '../../report/shared/report_paged_read.dart';
import '../../report/shared/report_print_preview.dart';
import '../../report/shared/report_date_range.dart';
import '../widgets/finance_date_range_filter.dart';
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../../report/shared/report_total.dart';
import '../config/finance_report_config.dart';
import '../widgets/gl_report_line_bindings_dialog.dart';
import '../widgets/inventory_cost_posting_dialog.dart';

class FinanceReportTablePage extends ConsumerStatefulWidget {
  const FinanceReportTablePage({required this.cardId, super.key});
  final String cardId;

  @override
  ConsumerState<FinanceReportTablePage> createState() =>
      _FinanceReportTablePageState();
}

class _FinanceReportTablePageState
    extends ConsumerState<FinanceReportTablePage> {
  FinanceReportCard get _card => financeReportCardById(widget.cardId);
  int _variantIndex = 0;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _keyword = '';
  String? _clientId;
  String? _clientName;
  int _page = 1;
  final int _size = 50;
  final Map<String, String> _filters = {};

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  final _reportPages = PagedListController<Map<String, dynamic>>();
  final _reportMetadata = ReportMetadataReuse();
  late final _reportRead = ReportPagedRead(_reportMetadata);

  ReportData? _data;
  Object? _acceptedReadQuery;
  bool _loading = false;
  int _loadGeneration = 0;
  String? _error;

  /// 「返回即刷新」登记用的本页路径（build 首次捕获）。
  String? _myLocation;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  /// 本页（cardId）对应的偏好 provider。
  NotifierProvider<ReportFilterPrefsNotifier, ReportFilterPrefs>
  get _prefsProvider => widget.cardId == 'summary'
      ? financeSummaryReportPrefsProvider
      : financeDetailReportPrefsProvider;

  @override
  void dispose() {
    _reportRead.dispose();
    _reportPages.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Keep the monotonic reader epoch observed for this page's whole lifetime.
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      setState(() {
        _reportPages.invalidateReadOwner(notify: false);
        _reportRead.invalidate();
        ++_loadGeneration;
        _data = null;
        _acceptedReadQuery = null;
        _loading = false;
        _page = 1;
        _keyword = '';
        _filters.clear();
        _clientId = null;
        _clientName = null;
        _error = null;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCustomerPrepaymentEvents) {
        _applyPrefs(ref.read(_prefsProvider));
      }
      _load();
    });
  }

  @override
  void didUpdateWidget(covariant FinanceReportTablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardId == widget.cardId) return;
    // A route can reuse this State for a different report. Retire the whole
    // former schema/query before either its foreground or prepared read returns.
    ++_loadGeneration;
    _reportPages.invalidateReadOwner(notify: false);
    _reportRead.invalidate();
    _data = null;
    _acceptedReadQuery = null;
    _loading = true;
    _page = 1;
    _keyword = '';
    _filters.clear();
    _sortKey = null;
    _sortAsc = true;
    _from = defaultReportFrom();
    _to = ChinaDateTime.today();
    _dirty = false;
    _myLocation = null;
    _variantIndex = 0;
    _clientId = null;
    _clientName = null;
    _error = null;
    if (!_isCustomerPrepaymentEvents) _applyPrefs(ref.read(_prefsProvider));
    final identity = widget.cardId;
    final generation = _loadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identity == widget.cardId &&
          generation == _loadGeneration) {
        _load();
      }
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认；变体存下标字符串，越界则回落 0）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      final vi = p.docType == null ? null : int.tryParse(p.docType!);
      if (vi != null && vi >= 0 && vi < _card.variants.length) {
        _variantIndex = vi;
      }
      // 日期范围与 facet 筛选不回灌：进页始终用默认日期范围（上月今日..今日）
      // + 空 filters = 「时间范围内的全部」，避免历史持久化的过时日期范围或失效
      // 筛选值把新数据滤成空白（销售报表已踩此坑，见 sales_report_page.dart）。
      _sortKey = _fixedFinanceRowOrder ? null : p.sortKey;
      if (_nonQueryableColumns.contains(_sortKey)) _sortKey = null;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页；变体存下标字符串）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _variantIndex.toString(),
    sortKey: _sortKey,
    sortAsc: _sortAsc,
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
    if (_isCustomerPrepaymentEvents) return;
    _dirty = true;
    ref.read(_prefsProvider.notifier).update(_snapshot());
  }

  FinanceReportVariant get _variant => _card.variants[_variantIndex];
  bool get _isCustomerPrepaymentEvents =>
      widget.cardId == 'customer-prepayment';

  bool get _fixedFinanceRowOrder =>
      _isCustomerPrepaymentEvents ||
      _exportReport == 'statements/other-receivable' ||
      const {
        'gl/balance-sheet',
        'gl/profit-annual',
        'gl/profit-monthly',
        'gl/manufacturing-expense',
        'gl/admin-expense',
        'gl/sales-expense',
        'gl/operating-pl',
      }.contains(_exportReport);

  Set<String> get _nonQueryableColumns => switch (_exportReport) {
    'statements/subcontract' => const {'materialPrice', 'materialAmount'},
    'statements/other-receivable' => const {'price', 'processAmount'},
    'cost/plastic' => const {'rejectQty'},
    'cost/sales-summary' => const {
      'manageFee',
      'saleFee',
      'taxFee',
      'freight',
      'netProfit',
      'profitRate',
    },
    'ar-ap/summary' => const {'materialAmount'},
    'payment/detail' => const {'incomeItem'},
    _ => const {},
  };

  /// 导出报表 key（剥离 /finance/reports/ 前缀，与 GET 路径一致：ar-ap/detail / receipt/summary …）。
  String get _exportReport =>
      _variant.endpoint.replaceFirst('/finance/reports/', '');

  /// 行点击跳源头单据详情页：明细/汇总每行带隐藏的 __srcId（= 单据头 id），
  /// push 详情页 → pop 回报表（保活筛选/分页状态）。聚合/台账类报表无 __srcId，行不响应。
  /// _exportReport 前缀 → 钱流单据路由 seg：
  ///   receipt/*→receipts、payment/*→payments、expense/*→expenses、income/*→incomes、
  ///   fee-offset/*→receipts（费用冲销源单为收款单）；ar-ap/* 无单据编辑页，不跳。
  void _onRowTap(Map<String, dynamic> row) {
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    final report = _exportReport;
    final seg = switch (report.split('/').first) {
      'receipt' => 'receipts',
      'payment' => 'payments',
      'expense' => 'expenses',
      'income' => 'incomes',
      'fee-offset' => 'receipts',
      _ => null, // ar-ap 等聚合/台账报表无单据编辑页
    };
    if (seg == null) return;
    context.push(RoutePath.financeDocDetail(seg, srcId));
  }

  /// 导出查询参数（含 direction 等固定参数 + 过滤+排序，与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    ..._variant.fixedParams,
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    if (_clientId != null) 'clientId': _clientId,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    for (final e in _filters.entries) 'f.${e.key}': e.value,
    if (!_fixedFinanceRowOrder && !_nonQueryableColumns.contains(_sortKey))
      ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// 按真实服务器分页读取当前条件的前2000行，保持原预览上限及列格式。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final generation = _loadGeneration;
    final epoch = ref.read(exportContextEpochProvider);
    return loadBoundedReportPrintPreview(
      api: api,
      endpointOf: () => _variant.endpoint,
      queryOf: () => _exportQuery,
      isCurrent: () =>
          mounted &&
          generation == _loadGeneration &&
          epoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)),
    );
  }

  String get _readEndpoint => _variant.endpoint;

  Map<String, dynamic> get _readQuery => <String, dynamic>{
    ..._variant.fixedParams,
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    if (_clientId != null) 'clientId': _clientId,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    'size': _size,
    for (final e in _filters.entries) 'f.${e.key}': e.value,
    if (!_fixedFinanceRowOrder && !_nonQueryableColumns.contains(_sortKey))
      ...sortQueryParams(_sortKey, _sortAsc),
  };

  Future<void> _load({
    bool background = false,
    bool reuseMetadata = false,
  }) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final readEpoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        readEpoch == ref.read(exportContextEpochProvider);
    final requestedPage = _page;
    final api = ref.read(apiClientProvider);
    final endpoint = _readEndpoint;
    final query = _readQuery;
    final readIdentity = [endpoint, query, readEpoch, api];
    bool queryCurrent() =>
        mounted &&
        readEpoch == ref.read(exportContextEpochProvider) &&
        identical(api, ref.read(apiClientProvider)) &&
        endpoint == _readEndpoint &&
        const DeepCollectionEquality().equals(query, _readQuery);
    final read = _reportRead.begin(
      endpoint: endpoint,
      query: query,
      readerEpoch: readEpoch,
      reusePages: reuseMetadata && !background,
      revalidatingWindow: background,
      fetch: (parameters) => api.get(endpoint, query: parameters),
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
        _reportPages.invalidateReadOwner(notify: false);
        _reportPages.error = error.message;
        _reportRead.invalidate();
        ++_loadGeneration;
        setState(() {
          _data = null;
          _loading = false;
        });
      },
      failureMessage: AppLocalizations.of(context).financeReportLoadFailed,
    );
    Future<PagedResult<Map<String, dynamic>>> fetchPage(int targetPage) =>
        read.read(targetPage);

    final pending = _reportPages.load(
      requestedPage,
      silent: background && _data != null,
      fetch: () => fetchPage(requestedPage),
      fetchPage: fetchPage,
      isCurrent: current,
    );
    setState(() {
      _loading = _reportPages.loading;
      _error = null;
    });
    await pending;
    if (!mounted || !current()) return;
    final failure = _reportPages.refreshError ?? _reportPages.error;
    setState(() {
      _loading = false;
      _error = failure;
      if (_reportPages.page == null) {
        _data = null;
      } else if (failure == null && _reportRead.accept(_reportPages.page)) {
        _data = (_reportPages.page! as ReportPageSnapshot).snapshot;
        _acceptedReadQuery = readIdentity;
        _page = _reportPages.pageNum;
      }
    });
    if (failure != null && !background) context.appError(failure);
  }

  Future<ClientListItem?> _pickClient() => showUtenClientPicker(context, ref);

  bool get _acceptedQueryCurrent =>
      const DeepCollectionEquality().equals(_acceptedReadQuery, [
        _readEndpoint,
        _readQuery,
        ref.read(exportContextEpochProvider),
        ref.read(apiClientProvider),
      ]);

  void _onClientChanged(String? id) {
    setState(() {
      _clientId = id;
      if (id == null) _clientName = null;
      _page = 1;
      _data = null;
    });
    _load();
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 表头排序回调：column=null 取消排序回到默认；否则按该列升/降序重新请求后端。
  void _onSortChange(String? column, bool ascending) {
    if (_fixedFinanceRowOrder || _nonQueryableColumns.contains(column)) return;
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
      if (value == null || value.isEmpty) {
        _filters.remove(key);
      } else {
        _filters[key] = value;
      }
      if (key == 'currencyCode' &&
          (value == null || value.isEmpty || value == kMasterFilterNullValue)) {
        for (final column in _data?.columns ?? const <Never>[]) {
          if (column.unitKey == 'currencyCode' && column.type == 'money') {
            _filters.remove('search.${column.key}');
            if (_sortKey == column.key) _sortKey = null;
          }
        }
      }
      _page = 1;
    });
    _persistPrefs();
    _load();
  }

  void _changeVariant(int i) {
    if (i == _variantIndex) return;
    setState(() {
      _variantIndex = i;
      _page = 1;
      _filters.clear();
      _data = null;
      _sortKey = null;
      _sortAsc = true;
    });
    _persistPrefs();
    _load();
  }

  String _filterCaption(String key, String value) {
    final columnKey = key.startsWith('search.') ? key.substring(7) : key;
    final label =
        _data?.columns
            .firstWhereOrNull((column) => column.key == columnKey)
            ?.label ??
        '筛选';
    final display = value == kMasterFilterNullValue
        ? '(空)'
        : key.startsWith('search.')
        ? value
        : _data?.facets[columnKey]
                  ?.firstWhereOrNull((bucket) => bucket.value == value)
                  ?.display ??
              value;
    return '$label: $display';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _variant.label;
    // 服务端偏好同步晚到：仅在用户未动手时回灌并重查（避免覆盖在输状态）。
    if (!_isCustomerPrepaymentEvents) {
      ref.listen(_prefsProvider, (prev, next) {
        if (!_dirty && prev != next && !next.isEmpty && mounted) {
          _applyPrefs(next);
          _page = 1;
          _load();
        }
      });
    }
    // 返回即刷新：行点击 push 的钱流单据详情里做过审核/红冲后返回，重拉报表
    // （此前报表无任何返回刷新，已红冲单据的旧金额一直挂在页上）。
    _myLocation ??= currentLocationOr(context, RouteName.finance);
    ref.onPageResume(
      _myLocation!,
      () => _reportPages.revalidate(_load(background: true)),
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenCollapsingHeaderScrollView(
              collapsingHeader: _buildFilterPane(theme),
              body: _buildTable(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLineBindings() async {
    final changed = await showGlReportLineBindingsDialog(
      context,
      canEdit: ref
          .read(currentPermissionsProvider)
          .contains(Perm.paymentStyleEdit),
    );
    if (changed && mounted) _load();
  }

  Future<void> _openInventoryCostPosting() async {
    final changed = await showInventoryCostPostingDialog(
      context,
      from: _from,
      to: _to,
    );
    if (changed && mounted) _load();
  }

  Widget _buildFilterPane(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenFilterToolbar<int>(
            compactBreakpoint: UtenBreakpoints.mediumStart,
            segments: [
              for (int i = 0; i < _card.variants.length; i++)
                UtenFilterSegment(value: i, label: _card.variants[i].label),
            ],
            selected: {_variantIndex},
            onSelectionChanged: _changeVariant,
            searchHint: _isCustomerPrepaymentEvents ? null : '搜索单号 / 名称',
            initialSearchValue: _keyword,
            onSearchChanged: (value) {
              _keyword = value;
              _persistAndReload();
            },
            onSearchSubmitted: (value) {
              _keyword = value;
              _persistAndReload();
            },
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
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
              if (_isCustomerPrepaymentEvents)
                SizedBox(
                  width: 240,
                  child: ClientPickerField(
                    key: ValueKey(
                      'prepayment-report-client-${_clientId ?? 'all'}',
                    ),
                    initialId: _clientId,
                    initialName: _clientName,
                    onPick: () async {
                      final selected = await _pickClient();
                      if (selected != null) _clientName = selected.name;
                      return selected;
                    },
                    onChanged: _onClientChanged,
                  ),
                ),
              if (widget.cardId == 'gl')
                TextButton.icon(
                  key: const ValueKey('gl-line-bindings'),
                  onPressed: _openLineBindings,
                  icon: const Icon(Icons.tune_outlined, size: 18),
                  label: const Text('附表取数设置'),
                ),
              for (final entry in _filters.entries)
                Chip(
                  label: Text(
                    _filterCaption(entry.key, entry.value),
                    style: theme.textTheme.labelSmall,
                  ),
                  onDeleted: () => _onFilterChanged(entry.key, null),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTable() {
    final data = _acceptedQueryCurrent
        ? _data
        : (_data?.pendingQuery() ??
              (_loading ? _reportMetadata.loadingData : null));
    if (_error != null && _data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: UtenSpacing.s8),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (data == null) {
      return const Center(child: Text('点击「查询」加载'));
    }
    // 状态列前置（全站口径）：列元数据来自服务端，客户端映射时把「状态」类列
    // （单据状态/审核状态等）排到最前，其余列保持服务端顺序；两个分区各自保持
    // 原有相对顺序。
    final orderedColumns = [
      ...data.columns.where((c) => _isStatusColumnLabel(c.label)),
      ...data.columns.where((c) => !_isStatusColumnLabel(c.label)),
    ];
    final columns = orderedColumns
        .map(
          (c) => MasterColumnDef<Map<String, dynamic>>(
            key: c.key,
            label: c.label,
            // 状态列收窄为声明下限 72（value 即显示文案，表格按内容自适应加宽）。
            width: _isStatusColumnLabel(c.label)
                ? 72
                : (c.width ?? 120).toDouble(),
            type: c.type,
            columnSearchEnabled:
                data.columnSearchKeys.contains(c.key) &&
                !_nonQueryableColumns.contains(c.key) &&
                (c.type != 'money' ||
                    c.unitKey != 'currencyCode' ||
                    (_filters['currencyCode'] != null &&
                        _filters['currencyCode'] != kMasterFilterNullValue)),
            info: c.unitKey == 'currencyCode' && c.type == 'money'
                ? '原币金额检索与排序请先选择一个币别；合计按币种分别列出'
                : _exportReport == 'statements/subcontract' &&
                      const {
                        'prevStock',
                        'issueQty',
                        'lossAllowed',
                        'receiptQty',
                        'balance',
                      }.contains(c.key)
                ? '同委外商、货品、颜色及数量单位的完整库存事实，在各加工币别行重复显示，不累计'
                : null,
            sortable:
                !_fixedFinanceRowOrder &&
                !_nonQueryableColumns.contains(c.key) &&
                (data.columnSearchKeys.isEmpty ||
                    data.columnSearchKeys.contains(c.key)) &&
                (c.type != 'money' ||
                    c.unitKey != 'currencyCode' ||
                    (_filters['currencyCode'] != null &&
                        _filters['currencyCode'] != kMasterFilterNullValue)) &&
                isSortableReportType(c.type),
            value: (row) => formatReportCell(c, row),
            exactValueOf: (row) => row['${c.key}Exact']?.toString(),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      expensiveRowMounts: false,
      primary: true,
      tableKey:
          'features.finance.pages.finance_report_table_page.FinanceReportTablePageState._buildTable.1',
      columns: columns,
      serverColumnSearchKeys: data.columnSearchKeys,
      headerFilterScopeDescription: _exportReport == 'statements/subcontract'
          ? '库存为同委外商、货品、颜色及数量单位的整组事实，在各加工币别重复显示，不累计；加工金额按本币别计价数量检索'
          : _exportReport == 'cost/copper-fee'
          ? '按往来方、货品、单位及币别核算；金额使用组内最近已知单价'
          : widget.cardId == 'gl' && _fixedFinanceRowOrder
          ? '定位已计算行，原会计合计不重算'
          : '检索所选条件的完整报表；合计与导出沿用同一范围',
      items: data.rows,
      toolbarActions: [
        if (widget.cardId == 'gl' &&
            ref.watch(costWorkbenchCapabilityProvider).canReadPostings)
          UtenButton(
            key: const ValueKey('inventory-cost-open'),
            type: UtenButtonType.secondary,
            onPressed: _openInventoryCostPosting,
            child: Text(AppLocalizations.of(context).inventoryCostTitle),
          ),
        UtenPrintPreviewButton(
          title: '钱流${_variant.label}',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}(最多前 2000 行)',
          loader: _printLoader,
          exportEndpoint: '/finance/reports/export',
          exportPermission: Perm.financeReportExport,
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '钱流${_variant.label}',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/finance/reports/export',
          requiredPermission: Perm.financeReportExport,
          report: _exportReport,
          queryParams: _exportQuery,
          filename: '钱流${_variant.label}',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
      ],
      facets: data.facets,
      nullCounts: const {},
      filters: {for (final e in _filters.entries) e.key: e.value},
      onFilterChanged: _onFilterChanged,
      sortColumn: _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      onRowTap: _onRowTap,
      isLoading: _loading,
      isRefreshing: _reportPages.refreshing,
      refreshError: _reportPages.refreshError,
      refreshedPages: _reportPages.refreshedPages,
      onRetainedPagesChanged: _reportPages.retainPages,
      paginationRevision: _reportPages.paginationRevision,
      error: _acceptedQueryCurrent ? _reportPages.error : _error,
      onRetry: () => _load(background: _data != null),
      emptyMessage: _isCustomerPrepaymentEvents ? '所选日期和客户暂无客户预收流水' : '暂无报表数据',
      // 服务端分页表格：合计由后端在整个结果集上算（reportTotalsBar），
      // 不是对当前这一页求和；后端未声明合计列时返回 null，整条不渲染。
      summaryBar: reportTotalsBar(
        data.totals,
        statisticsGeneratedAt: data.statisticsGeneratedAt,
      ),
      currentPage: data.page,
      totalPages: data.totalPages,
      paginationScope: (
        _reportRead.snapshotRevision,
        widget.cardId,
        _variantIndex,
        _from,
        _to,
        _keyword,
        _clientId,
        PagedReadQueryKey(_filters),
        _sortKey,
        _sortAsc,
      ),
      onPageChange: (p) {
        _page = p;
        _load(reuseMetadata: true);
      },
    );
  }

  /// 状态类列判定：label 为「状态」或含「状态」（如 单据状态/审核状态）。
  static bool _isStatusColumnLabel(String label) => label.contains('状态');
}
