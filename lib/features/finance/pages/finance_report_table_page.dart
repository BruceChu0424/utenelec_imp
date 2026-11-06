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
import '../../../core/print/print_bounds.dart';
import '../widgets/finance_subcontract_quantity_evidence_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../providers/finance_report_facet_options.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_month_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/master_dictionary_repository.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../shared/models/paged_result.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/responsive/compact_presentation.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
import '../../basic_data/models/client_node.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
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
import '../config/finance_requirement_names.dart';
import '../widgets/gl_report_line_bindings_dialog.dart';
import '../widgets/finance_chart_dialog.dart';
import '../widgets/finance_accounting_import_dialog.dart';
import '../widgets/finance_auxiliary_dialog.dart';
import '../widgets/finance_auxiliary_import_dialog.dart';
import '../widgets/finance_template_input_dialog.dart';
import '../widgets/finance_expense_analysis_dialog.dart';
import '../widgets/finance_open_item_classification_dialog.dart';
import '../widgets/finance_supplier_prepayment_dialog.dart';
import '../widgets/finance_asset_opening_group_dialog.dart';
import '../widgets/finance_statement_document_dialog.dart';
import '../widgets/finance_procurement_confirmation_dialog.dart';
import '../widgets/finance_material_context_picker.dart';
import '../widgets/finance_material_statement_dialog.dart';
import '../widgets/finance_subcontract_loss_policy_dialog.dart';
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
  String? _partyId, _partyName, _currencyId, _binId, _statementReviewId;
  bool _clientStatementDetail = false;
  String? _materialContextId, _materialContextName, _materialPartyRole;
  List<Map<String, dynamic>> _currencies = [], _bins = [];
  int _contextGeneration = 0;
  String? _contextError;
  bool _loadingContexts = false;
  final int _size = 50;
  final Map<String, String> _filters = {};

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  final _reportPages = PagedListController<Map<String, dynamic>>();
  final _reportMetadata = ReportMetadataReuse();
  late final _reportRead = ReportPagedRead(_reportMetadata);

  ReportData? _data;
  bool _preparingTemplate = false;
  Object? _acceptedReadQuery;
  String? _retainedSchemaVersion;
  bool _loading = false;
  int _loadGeneration = 0;
  String? _error;

  /// 「返回即刷新」登记用的本页路径（build 首次捕获）。
  String? _myLocation;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  /// 本页（cardId）对应的偏好 provider。
  NotifierProvider<ReportFilterPrefsNotifier, ReportFilterPrefs>
  get _prefsProvider => switch (widget.cardId) {
    'summary' => financeSummaryReportPrefsProvider,
    'recon' => financeReconReportPrefsProvider,
    'cost' => financeCostReportPrefsProvider,
    'gl' => financeGlReportPrefsProvider,
    _ => financeDetailReportPrefsProvider,
  };

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
        _keyword = '';
        _filters.clear();
        _clientId = null;
        _clientName = null;
        _partyId = _partyName = _currencyId = _binId = null;
        _statementReviewId = null;
        _materialContextId = _materialContextName = _materialPartyRole = null;
        _currencies = [];
        _bins = [];
        ++_contextGeneration;
        _loadingContexts = false;
        _contextError = null;
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
    _partyId = _partyName = _currencyId = _binId = null;
    _statementReviewId = null;
    _materialContextId = _materialContextName = _materialPartyRole = null;
    _currencies = [];
    _bins = [];
    ++_contextGeneration;
    _loadingContexts = false;
    _contextError = null;
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
  Future<void> _persistAndReload() {
    _persistPrefs();
    return _load();
  }

  void _persistPrefs() {
    if (_isCustomerPrepaymentEvents) return;
    _dirty = true;
    ref.read(_prefsProvider.notifier).update(_snapshot());
  }

  FinanceReportVariant get _variant => _card.variants[_variantIndex];
  bool get _isCustomerPrepaymentEvents =>
      widget.cardId == 'customer-prepayment';

  bool get _partyStatement =>
      (_exportReport != 'statements/client' || !_clientStatementDetail) &&
      const {
        'statements/subcontract',
        'statements/supplier',
        'statements/client',
      }.contains(_exportReport);
  bool get _materialStatement => _exportReport == 'statements/other-receivable';
  bool get _copperReport =>
      const {'cost/copper-fee', 'cost/copper-pickling'}.contains(_exportReport);
  bool get _auxiliaryReport => _exportReport.startsWith('auxiliary/');
  bool get _accountingMonth => const {
    'gl/profit-monthly',
    'gl/profit-annual',
    'gl/manufacturing-expense',
    'gl/admin-expense',
    'gl/sales-expense',
    'gl/operating-pl',
  }.contains(_exportReport);
  bool get _replicatedReport =>
      !(_exportReport == 'statements/client' && _clientStatementDetail) &&
      (widget.cardId == 'gl' ||
          widget.cardId == 'recon' ||
          widget.cardId == 'cost' && _exportReport != 'cost/product' ||
          _auxiliaryReport ||
          _exportReport == 'ar-ap/summary');
  bool get _canMaintainTemplates =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit) &&
      ref.read(currentPermissionsProvider).contains(Perm.financeViewAll);
  DateTime get _queryFrom => !_accountingMonth
      ? _from
      : _exportReport == 'gl/profit-monthly'
      ? DateTime(_to.year, _to.month)
      : DateTime(_to.year);
  DateTime get _queryTo =>
      _accountingMonth ? DateTime(_to.year, _to.month + 1, 0) : _to;
  Map<String, dynamic> get _sourceContext => {
    if (_statementReviewId != null) 'statementReviewId': _statementReviewId,
    if (_partyStatement || _materialStatement) 'layout': 'template',
    if (_materialStatement && _materialContextId != null)
      'materialContextId': _materialContextId,
    if (_materialStatement) 'allMaterialContexts': true,
    if ((_partyStatement || _materialStatement) && _partyId != null)
      'partyId': _partyId,
    if (_copperReport && _partyId != null) 'supplierId': _partyId,
    if ((_partyStatement || _materialStatement || _auxiliaryReport) &&
        _currencyId != null)
      'currencyId': _currencyId,
    if (_exportReport == 'cost/plastic' && _binId != null)
      'binWarehouseId': _binId,
  };

  Future<void> _loadContexts() async {
    if (!_partyStatement &&
        !_copperReport &&
        !_auxiliaryReport &&
        _exportReport != 'cost/plastic') {
      return;
    }
    final generation = ++_contextGeneration;
    final api = ref.read(apiClientProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final endpoint = _exportReport;
    final from = _fmt(_queryFrom), to = _fmt(_queryTo);
    bool current() =>
        mounted &&
        generation == _contextGeneration &&
        epoch == ref.read(exportContextEpochProvider) &&
        identical(api, ref.read(apiClientProvider)) &&
        endpoint == _exportReport &&
        from == _fmt(_queryFrom) &&
        to == _fmt(_queryTo);
    setState(() {
      _loadingContexts = true;
      _contextError = null;
    });
    try {
      if (_exportReport == 'cost/plastic') {
        final result = await api.get(
          '/finance/reports/context/plastic-bins',
          query: {'dateFrom': from, 'dateTo': to},
        );
        if (!current()) return;
        setState(() {
          _bins = [
            for (final row in result['items'] as List? ?? [])
              if (row is Map) Map<String, dynamic>.from(row),
          ];
          if (!_bins.any((r) => r['id'] == _binId)) _binId = null;
        });
      } else if (_partyStatement || _auxiliaryReport) {
        final result = await ref
            .read(masterDictionaryRepositoryProvider)
            .load(ApiEndpoints.currenciesDict);
        if (!current()) return;
        setState(() => _currencies = result);
      }
    } catch (_) {
      if (current()) setState(() => _contextError = '读取往来/币别或料仓范围失败，请重试');
    } finally {
      if (current()) setState(() => _loadingContexts = false);
    }
  }

  bool get _fixedFinanceRowOrder =>
      _statementReviewId != null ||
      _isCustomerPrepaymentEvents ||
      _exportReport == 'statements/other-receivable' ||
      const {
        'gl/trial-balance',
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
  bool get _statementTemplate => const {
    'gl/balance-sheet',
    'gl/profit-monthly',
    'gl/profit-annual',
  }.contains(_exportReport);

  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    ..._variant.fixedParams,
    ..._sourceContext,
    if (_replicatedReport) 'layout': 'template',
    'dateFrom': _fmt(_queryFrom),
    'dateTo': _fmt(_queryTo),
    if (_clientId != null) 'clientId': _clientId,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    for (final e in _filters.entries) 'f.${e.key}': e.value,
    if (!_fixedFinanceRowOrder && !_nonQueryableColumns.contains(_sortKey))
      ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// Complete filtered output; source originals retain their separate paper budget.
  Future<UtenPrintTable> _printLoader({bool template = false}) async {
    final api = ref.read(apiClientProvider);
    final generation = _loadGeneration;
    final epoch = ref.read(exportContextEpochProvider);
    final complete =
        _partyStatement || _materialStatement || template && _statementTemplate;
    final table = await loadBoundedReportPrintPreview(
      rowLimit: complete
          ? maximumCompleteOriginalPrintRows
          : maximumTableOutputRows,
      useSuggestedWidths: template || _replicatedReport,
      includeValueUnits: !_replicatedReport,
      repeatColumnHeaders: _replicatedReport,
      api: api,
      endpointOf: () => _variant.endpoint,
      queryOf: () => {..._exportQuery, if (template) 'layout': 'template'},
      isCurrent: () =>
          mounted &&
          generation == _loadGeneration &&
          epoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)),
    );
    if (template &&
        _statementTemplate &&
        table.documentMetadata['paperLayout'] is! Map) {
      throw const FormatException('服务端未提供完整财务原表版式，请刷新后重试');
    }
    return table;
  }

  Future<void> _openStatementTemplate() async {
    if (_preparingTemplate) return;
    setState(() => _preparingTemplate = true);
    try {
      await showUtenPrintPreview(
        context: context,
        title: _exportReport == 'gl/balance-sheet'
            ? FinanceRequirementNames.balanceSheetTitle
            : _exportReport == 'gl/profit-annual'
            ? FinanceRequirementNames.annualProfitTitle.replaceAll(
                '{year}',
                '${_to.year}',
              )
            : FinanceRequirementNames.monthlyProfitTitle,
        loader: () => _printLoader(template: true),
        applyTableProjection: false,
        exportEndpoint: '/finance/reports/export',
        exportPermission: Perm.financeReportExport,
        exportReport: _exportReport,
        exportQuery: {..._exportQuery, 'layout': 'template'},
        exportFilename: _variant.label,
      );
    } catch (caughtError) {
      if (mounted) {
        context.appApiError(caughtError, fallback: '模板预览加载失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _preparingTemplate = false);
    }
  }

  String get _readEndpoint => _variant.endpoint;

  Map<String, dynamic> get _readQuery => <String, dynamic>{
    ..._variant.fixedParams,
    ..._sourceContext,
    if (_replicatedReport) 'layout': 'template',
    'dateFrom': _fmt(_queryFrom),
    'dateTo': _fmt(_queryTo),
    if (_clientId != null) 'clientId': _clientId,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    'size': _size,
    for (final e in _filters.entries) 'f.${e.key}': e.value,
    if (!_fixedFinanceRowOrder && !_nonQueryableColumns.contains(_sortKey))
      ...sortQueryParams(_sortKey, _sortAsc),
  };

  Future<void> _load({bool background = false}) async {
    if (!mounted) return;
    if ((_partyStatement || _auxiliaryReport) && _currencies.isEmpty ||
        _exportReport == 'cost/plastic' && _bins.isEmpty) {
      if (!_loadingContexts) _loadContexts();
    }
    if (_partyStatement && (_partyId == null || _currencyId == null) ||
        _materialStatement && _materialContextId == null) {
      ++_loadGeneration;
      _reportRead.invalidate();
      _reportPages.invalidateReadOwner(notify: false);
      setState(() {
        _data = null;
        _acceptedReadQuery = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    final generation = ++_loadGeneration;
    final readEpoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        readEpoch == ref.read(exportContextEpochProvider);
    final api = ref.read(apiClientProvider);
    final endpoint = _readEndpoint;
    final query = _readQuery;
    final readIdentity = [endpoint, query, readEpoch, api];
    final previousSchema = _data;
    final previousIdentity = _acceptedReadQuery;
    Map<String, dynamic> schemaQuery(Map<dynamic, dynamic> values) => {
      for (final entry in values.entries)
        if (entry.key is String &&
            !(entry.key as String).startsWith('f.search.') &&
            !const {'sort', 'order', 'page'}.contains(entry.key))
          entry.key as String: entry.value,
    };
    final mayKeepSchema =
        previousSchema != null &&
        (previousSchema.readScopeVersion ?? _retainedSchemaVersion)
                ?.isNotEmpty ==
            true &&
        previousIdentity is List &&
        previousIdentity.length == 4 &&
        previousIdentity[0] == endpoint &&
        previousIdentity[2] == readEpoch &&
        identical(previousIdentity[3], api) &&
        previousIdentity[1] is Map &&
        const DeepCollectionEquality().equals(
          schemaQuery(previousIdentity[1] as Map),
          schemaQuery(query),
        );
    Object? readFailure;

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
      reusePages: false,
      revalidatingWindow: background,
      fetch: (parameters) => api.get(endpoint, query: parameters),
      isCurrent: queryCurrent,
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
          _acceptedReadQuery = null;
          _retainedSchemaVersion = null;
          _error = error.message;
          _loading = false;
        });
      },
      failureMessage: AppLocalizations.of(context).financeReportLoadFailed,
    );
    Future<PagedResult<Map<String, dynamic>>> fetchPage(int targetPage) async {
      try {
        return await read.read(targetPage);
      } catch (error) {
        readFailure = error;
        rethrow;
      }
    }

    final pending = _reportPages.load(
      1,
      silent: background && _data != null,
      fetch: () => fetchPage(1),
      fetchPage: fetchPage,
      isCurrent: current,
      ownerIsCurrent: queryCurrent,
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
        final failureCause = readFailure;
        final ownerRetired =
            failureCause != null &&
            (pagedReadAccessDenied(failureCause) ||
                failureCause is ApiException &&
                    failureCause.code == 'SESSION_CHANGED');
        // An ordinary failed search can keep previously authorized controls;
        // it never inherits old facts, aggregates or proof for the new query.
        _data = failure != null && mayKeepSchema && !ownerRetired
            ? previousSchema.pendingQuery()
            : null;
        if (ownerRetired) {
          _acceptedReadQuery = null;
          _retainedSchemaVersion = null;
        }
      } else if (failure == null && _reportRead.accept(_reportPages.page)) {
        _data = (_reportPages.page! as ReportPageSnapshot).snapshot;
        _retainedSchemaVersion = _data!.readScopeVersion;
        _acceptedReadQuery = readIdentity;
      }
    });
    if (failure != null && !background) {
      context.appError(failure);
    }
  }

  Future<ClientListItem?> _pickClient() =>
      showUtenClientPicker(context, ref, selectableOnly: false);

  bool get _acceptedQueryCurrent =>
      _data != null &&
      _reportPages.page != null &&
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
    });
    _persistPrefs();
    _load();
  }

  void _onFilterChanged(String key, String? value) {
    if (_statementReviewId != null) {
      context.appWarning('已保存原件保留完整明细；返回当前账载后可重新筛选');
      return;
    }
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
    });
    _persistPrefs();
    _load();
  }

  void _changeVariant(int i) {
    if (i == _variantIndex) return;
    setState(() {
      _variantIndex = i;
      _clientStatementDetail = false;
      _partyId = _partyName = _currencyId = _binId = null;
      _statementReviewId = null;
      _materialContextId = _materialContextName = _materialPartyRole = null;
      _currencies = [];
      _bins = [];
      _contextError = null;
      _loadingContexts = false;
      ++_contextGeneration;
      _filters.clear();
      _data = null;
      _sortKey = null;
      _sortAsc = true;
    });
    _persistPrefs();
    _load();
  }

  void _toggleClientStatementDetail() {
    setState(() {
      _clientStatementDetail = !_clientStatementDetail;
      _statementReviewId = null;
      _partyId = _partyName = _currencyId = null;
      _contextError = null;
      _loadingContexts = false;
      ++_contextGeneration;
      _filters.clear();
      _data = null;
      _sortKey = null;
      _sortAsc = true;
    });
    _load();
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
          _load();
        }
      });
    }
    // 返回即刷新：行点击 push 的钱流单据详情里做过审核/红冲后返回，重拉报表
    // （此前报表无任何返回刷新，已红冲单据的旧金额一直挂在页上）。
    _myLocation ??= currentLocationOr(context, RouteName.finance);
    Future<void> visibleReadReturn() =>
        _reportPages.revalidate(_load(background: true));
    _reportRead.bindView(context, onResume: visibleReadReturn);
    ref.onPageResume(_myLocation!, visibleReadReturn);
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        info: _pendingSourceNotes.isEmpty
            ? null
            : '待核对：$_pendingSourceNotes。未核对金额保留空白，可打开该行查看来源。${_statementTemplate ? '完整模板暂不可导出。' : ''}',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
      ),
      body: Stack(
        children: [
          SafeArea(
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
          if (_loading)
            const UtenBusyOverlay(title: '正在查询报表', showDoNotLeaveHint: false),
        ],
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

  Future<void> _openChart() async {
    final changed = await showFinanceChartDialog(
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

  Future<void> _openAccountingImport() async {
    final changed = await showFinanceAccountingImportDialog(context);
    if (changed && mounted) _load();
  }

  Future<void> _pickStatementParty() async {
    final api = ref.read(apiClientProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final report = _exportReport;
    final customer = report == 'statements/client';
    String? id, name;
    if (customer) {
      final item = await showUtenClientPicker(
        context,
        ref,
        selectableOnly: false,
      );
      id = item?.id;
      name = item == null ? null : clientPickerLabel(item);
    } else {
      final item = await showUtenSupplierPicker(
        context,
        ref,
        selectableOnly: false,
        allowQuickCreate: false,
      );
      id = item?.id;
      name = item == null ? null : '${item.code} ${item.name}';
    }
    if (!mounted ||
        id == null ||
        report != _exportReport ||
        epoch != ref.read(exportContextEpochProvider) ||
        !identical(api, ref.read(apiClientProvider))) {
      return;
    }
    setState(() {
      _partyId = id;
      _partyName = name;
      _statementReviewId = null;
    });
    _persistAndReload();
  }

  Future<void> _openAuxiliaryImport() async {
    if (_currencyId == null) {
      context.appWarning('请先选择原表币别');
      return;
    }
    final changed = await showFinanceAuxiliaryImportDialog(
      context,
      receivable: _exportReport == 'auxiliary/receivable',
      currencyId: _currencyId!,
      dateFrom: _fmt(_queryFrom),
      dateTo: _fmt(_queryTo),
    );
    if (changed && mounted) _load();
  }

  Future<void> _openExpenseInput(
    String mode, {
    Map<String, dynamic>? row,
  }) async {
    final changed = await showFinanceExpenseAnalysisDialog(
      context,
      period: UtenMonthField.format(_queryTo),
      mode: mode,
      lineKey: row?['__lineKey']?.toString(),
      entryId: row?['__entryId']?.toString(),
      groupId: row?['__groupId']?.toString(),
    );
    if (changed && mounted) _load();
  }

  Future<void> _openReportRow(Map<String, dynamic> row) async {
    if (!_acceptedQueryCurrent) return;
    final generation = _loadGeneration,
        epoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        epoch == ref.read(exportContextEpochProvider) &&
        _acceptedQueryCurrent;
    if (row['__basis'] != null ||
        row['__pending'] == true ||
        _replicatedReport) {
      await showDialog<void>(
        context: context,
        builder: (_) => UtenAlertDialog(
          showCloseButton: true,
          onClose: () => Navigator.pop(context),
          title: UtenDialogTitleWithHint(
            title: Text(
              (row['item'] ??
                      row['styleName'] ??
                      row['goodsName'] ??
                      row['clientName'] ??
                      _variant.label)
                  .toString(),
            ),
            info: row['__pending'] == true ? '此行仍有待核对来源，空白金额不代表零。' : null,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (row['__basis'] != null)
                  SelectableText(row['__basis'].toString()),
                if (_exportReport == 'statements/subcontract' &&
                    _partyId != null &&
                    row['__goodsId'] != null &&
                    row['__unitId'] != null)
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) _openSubcontractLossPolicy(row: row);
                    },
                    child: const Text('允许损耗率'),
                  ),
                if (_exportReport == 'statements/subcontract' &&
                    _partyId != null &&
                    ref
                        .read(currentPermissionsProvider)
                        .contains(Perm.financeViewAll))
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) _openSubcontractQuantityEvidence(row: row);
                    },
                    child: const Text('原表数量核对'),
                  ),
                if (_canMaintainTemplates &&
                    _exportReport == 'gl/operating-pl' &&
                    row['__lineKey'] != null)
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) _openExpenseInput('note', row: row);
                    },
                    child: const Text('备注/差异原因'),
                  ),
                if (_canMaintainTemplates &&
                    _exportReport == 'cost/sales-summary' &&
                    row['__clientId'] != null)
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) {
                        _openTemplateRow('sales', {
                          'clientId': row['__clientId'],
                          'period': UtenMonthField.format(_queryTo),
                        });
                      }
                    },
                    child: const Text('维护原表资料'),
                  ),
                if (_canMaintainTemplates &&
                    _exportReport == 'cost/plastic' &&
                    row['__periodLineId'] != null)
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) {
                        _openTemplateRow('plastic', {
                          'periodLineId': row['__periodLineId'],
                          'period': UtenMonthField.format(_queryTo),
                        });
                      }
                    },
                    child: const Text('维护原表资料'),
                  ),
                if (_canMaintainTemplates &&
                    _exportReport == 'cost/copper-pickling' &&
                    row['__sourceId'] != null)
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) {
                        _openTemplateRow('copper', {
                          'sourceLineId': row['__sourceId'],
                          'period': UtenMonthField.format(_queryTo),
                        });
                      }
                    },
                    child: const Text('维护原表资料'),
                  ),
                if (_canMaintainTemplates &&
                    _exportReport == 'cost/plastic-detail' &&
                    row['__requisitionId'] != null)
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) {
                        _openTemplateRow('order', {
                          'requisitionId': row['__requisitionId'],
                        });
                      }
                    },
                    child: const Text('维护原表订单号'),
                  ),
                if (_exportReport.startsWith('fa/') &&
                    row['__assetId'] != null &&
                    ref
                        .read(currentPermissionsProvider)
                        .contains(Perm.financeAssetEdit))
                  UtenButton(
                    onPressed: () {
                      Navigator.pop(context);
                      if (current()) {
                        _openTemplateRow('asset', {
                          'objectType': row['__assetType'],
                          'objectId': row['__assetId'],
                          'validFrom': _fmt(_queryTo),
                          'template':
                              _exportReport ==
                                  'fa/completed-depreciation-schedule'
                              ? 'depreciationCompleted'
                              : _exportReport == 'fa/amortization-schedule'
                              ? 'amortization'
                              : 'depreciation',
                        });
                      }
                    },
                    child: const Text('维护原表资料'),
                  ),
              ],
            ),
          ),
        ),
      );
    } else {
      _onRowTap(row);
    }
  }

  Future<void> _openSubcontractLossPolicy({Map<String, dynamic>? row}) async {
    final supplier = _partyId;
    if (!mounted ||
        supplier == null ||
        _exportReport != 'statements/subcontract') {
      return;
    }
    final epoch = ref.read(exportContextEpochProvider),
        generation = _loadGeneration;
    await showFinanceSubcontractLossPolicyDialog(
      context,
      supplierId: supplier,
      sourceRow: row,
    );
    if (mounted &&
        epoch == ref.read(exportContextEpochProvider) &&
        generation == _loadGeneration &&
        _partyId == supplier) {
      await _load();
    }
  }

  Future<void> _openSubcontractQuantityEvidence({
    Map<String, dynamic>? row,
  }) async {
    final supplier = _partyId;
    if (!mounted ||
        supplier == null ||
        _exportReport != 'statements/subcontract' ||
        !ref.read(currentPermissionsProvider).contains(Perm.financeViewAll)) {
      return;
    }
    final epoch = ref.read(exportContextEpochProvider),
        generation = _loadGeneration;
    await showFinanceSubcontractQuantityEvidenceDialog(
      context,
      scope: {
        'supplierId': supplier,
        'dateFrom': _fmt(_queryFrom),
        'dateTo': _fmt(_queryTo),
      },
      sourceRow: row,
    );
    if (mounted &&
        epoch == ref.read(exportContextEpochProvider) &&
        generation == _loadGeneration &&
        _partyId == supplier) {
      await _load();
    }
  }

  Future<void> _openTemplateRow(String kind, Map<String, dynamic> scope) async {
    final changed = await showFinanceTemplateInputDialog(
      context,
      kind: kind,
      scope: scope,
    );
    if (changed && mounted) _load();
  }

  Future<void> _openAssetOpeningGroup() async {
    await showFinanceAssetOpeningGroupDialog(
      context,
      template: _exportReport == 'fa/amortization-schedule'
          ? 'amortization'
          : _exportReport == 'fa/completed-depreciation-schedule'
          ? 'depreciationCompleted'
          : 'depreciation',
      period: UtenMonthField.format(_queryTo),
    );
    if (mounted) _load();
  }

  Future<void> _openStatementDocuments() async {
    if (_partyId == null ||
        _currencyId == null ||
        _materialStatement &&
            (_materialContextId == null || _materialPartyRole == null)) {
      context.appWarning('请先选择原表实际往来对象和币别');
      return;
    }
    final report = _exportReport,
        party = _partyId!,
        currency = _currencyId!,
        materialContextId = _materialContextId,
        from = _fmt(_queryFrom),
        to = _fmt(_queryTo),
        epoch = ref.read(exportContextEpochProvider),
        api = ref.read(apiClientProvider);
    bool current() =>
        mounted &&
        report == _exportReport &&
        party == _partyId &&
        currency == _currencyId &&
        materialContextId == _materialContextId &&
        from == _fmt(_queryFrom) &&
        to == _fmt(_queryTo) &&
        epoch == ref.read(exportContextEpochProvider) &&
        identical(api, ref.read(apiClientProvider));
    final changed = await showFinanceStatementDocumentDialog(
      context,
      templateKey: _materialStatement
          ? 'otherReceivableStatement'
          : report == 'statements/client'
          ? 'clientStatement'
          : report == 'statements/subcontract'
          ? 'subcontractStatement'
          : 'supplierStatement',
      partyRole: _materialStatement
          ? _materialPartyRole!
          : report == 'statements/client'
          ? 'CUSTOMER'
          : 'SUPPLIER',
      partyId: party,
      currencyId: currency,
      dateFrom: from,
      dateTo: to,
      materialContextId: materialContextId,
      onOpenOriginal: (id) async {
        if (!current()) return;
        setState(() {
          _statementReviewId = id;
          _keyword = '';
          _filters.clear();
          _sortKey = null;
        });
        await _load();
      },
    );
    if (changed && current()) _load();
  }

  Future<void> _pickMaterialContext() async {
    final api = ref.read(apiClientProvider),
        epoch = ref.read(exportContextEpochProvider),
        report = _exportReport;
    final selected = await showFinanceMaterialContextPicker(context);
    if (!mounted ||
        selected == null ||
        report != _exportReport ||
        epoch != ref.read(exportContextEpochProvider) ||
        !identical(api, ref.read(apiClientProvider))) {
      return;
    }
    final id = selected['id']?.toString(),
        party = selected['partyId']?.toString(),
        currency = selected['actualCurrencyId']?.toString(),
        role = selected['partyRole']?.toString();
    if (id == null || party == null || currency == null || role == null) return;
    setState(() {
      _materialContextId = id;
      _materialPartyRole = role;
      _materialContextName = '${selected['auxiliaryName'] ?? ''} 全部分组'.trim();
      _partyId = party;
      _partyName = selected['auxiliaryName']?.toString();
      _currencyId = currency;
      _statementReviewId = null;
      _keyword = '';
      _filters.clear();
      _sortKey = null;
    });
    _persistAndReload();
  }

  Future<void> _openMaterialSourceData() async {
    await showFinanceMaterialStatementDialog(
      context,
      initialContextId: _materialContextId,
      dateFrom: _fmt(_queryFrom),
      dateTo: _fmt(_queryTo),
    );
    if (mounted && _materialStatement) _load();
  }

  Future<void> _openProcurementConfirmation() async {
    if (_partyId == null || _currencyId == null) {
      context.appWarning('请先选择原表实际供应商和币别');
      return;
    }
    await showFinanceProcurementConfirmationDialog(
      context,
      supplierId: _partyId!,
      currencyId: _currencyId!,
    );
    if (mounted) _load();
  }

  Widget _documentMetadata(ReportData data, {required bool header}) {
    final metadata = data.documentMetadata;
    final lines = metadata[header ? 'headerLines' : 'footerLines'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header && metadata['title'] != null)
            Text(
              metadata['title'].toString(),
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          if (header && metadata['currencyName'] != null)
            Text('币别：${metadata['currencyName']}'),
          if (lines is List)
            Wrap(
              spacing: 24,
              runSpacing: 4,
              children: [
                for (final line in lines)
                  if (line is Map)
                    Text(
                      '${line['label'] ?? ''}${line['value'] ?? (const {'counterpartConfirmation', 'internalConfirmation'}.contains(line['key']) ? '________' : '待维护/核对')}',
                    ),
              ],
            ),
        ],
      ),
    );
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
            searchHint:
                _isCustomerPrepaymentEvents || _statementReviewId != null
                ? null
                : '搜索单号 / 名称',
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
              if (_exportReport == 'statements/client')
                UtenButton(
                  key: const Key('finance-client-statement-view-toggle'),
                  onPressed: _toggleClientStatementDetail,
                  child: Text(_clientStatementDetail ? '查看原表' : '查看业务明细'),
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
              if (_materialStatement)
                UtenButton(
                  key: const Key('finance-material-maintain'),
                  onPressed: _openMaterialSourceData,
                  child: const Text('原表资料'),
                ),
              if (_materialStatement)
                UtenButton(
                  key: const Key('finance-material-context-select'),
                  onPressed: _pickMaterialContext,
                  child: Text(_materialContextName ?? '选择对账资料'),
                ),
              if (_materialStatement && _materialContextId != null)
                UtenButton(
                  onPressed: () {
                    setState(() {
                      _materialContextId = _materialContextName =
                          _materialPartyRole = null;
                      _partyId = _partyName = _currencyId = null;
                      _statementReviewId = null;
                    });
                    _persistAndReload();
                  },
                  child: const Text('清除资料'),
                ),
              if (_partyStatement || _copperReport)
                UtenButton(
                  key: const Key('finance-report-party'),
                  onPressed: _pickStatementParty,
                  child: Text(
                    _partyName ??
                        (_exportReport == 'statements/client'
                            ? '选择客户'
                            : '选择供应商/加工商'),
                  ),
                ),
              if (_partyId != null && (_partyStatement || _copperReport))
                UtenButton(
                  onPressed: () {
                    setState(() {
                      _partyId = _partyName = null;
                      _statementReviewId = null;
                    });
                    _persistAndReload();
                  },
                  child: const Text('清除往来'),
                ),
              if (_partyStatement || _auxiliaryReport)
                SizedBox(
                  width: 200,
                  child: UtenDropdownField(
                    key: const Key('finance-report-currency'),
                    label: '币别',
                    value: _currencyId,
                    items: [
                      for (final c in _currencies)
                        UtenDropdownItem(
                          value: c['id'].toString(),
                          label: (c['name'] ?? c['code'] ?? '').toString(),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _currencyId = value;
                        _statementReviewId = null;
                      });
                      _persistAndReload();
                    },
                  ),
                ),
              if (_exportReport == 'cost/plastic')
                SizedBox(
                  width: 240,
                  child: UtenDropdownField(
                    key: const Key('finance-report-bin'),
                    label: '内料仓',
                    value: _binId,
                    items: [
                      for (final b in _bins)
                        UtenDropdownItem(
                          value: b['id'].toString(),
                          label: '${b['code'] ?? ''} ${b['name'] ?? ''}'.trim(),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() => _binId = value);
                      _persistAndReload();
                    },
                  ),
                ),
              if (_contextError != null)
                UtenButton(
                  onPressed: _loadContexts,
                  child: Text(_contextError!),
                ),
              if (widget.cardId == 'gl')
                TextButton.icon(
                  key: const ValueKey('gl-line-bindings'),
                  onPressed: _openLineBindings,
                  icon: const Icon(Icons.tune_outlined, size: 18),
                  label: const Text('报表取数设置'),
                ),
            ],
          ),
          if (_acceptedQueryCurrent &&
              _data?.documentMetadata.isNotEmpty == true)
            _documentMetadata(_data!, header: true),
        ],
      ),
    );
  }

  Widget _buildTable() {
    final data = _acceptedQueryCurrent && _data != null
        ? _data!
        : (_data?.pendingQuery() ?? _reportMetadata.loadingData);
    // 状态列前置（全站口径）：列元数据来自服务端，客户端映射时把「状态」类列
    // （单据状态/审核状态等）排到最前，其余列保持服务端顺序；两个分区各自保持
    // 原有相对顺序。
    final orderedColumns = _replicatedReport
        ? data.columns
        : [
            ...data.columns.where((c) => _isStatusColumnLabel(c.label)),
            ...data.columns.where((c) => !_isStatusColumnLabel(c.label)),
          ];
    final columns = orderedColumns
        .map(
          (c) => MasterColumnDef<Map<String, dynamic>>(
            key: c.key,
            label: c.label,
            headerGroups: c.headerGroups,
            // 状态列收窄为声明下限 72（value 即显示文案，表格按内容自适应加宽）。
            width: _isStatusColumnLabel(c.label)
                ? 72
                : (c.width ?? 120).toDouble(),
            minimumWidthOf:
                _exportReport == 'statements/client' && c.key == 'clientName'
                ? (_) => (c.width ?? 180).toDouble()
                : null,
            type: c.type,
            facetCandidatesUseKeyword:
                c.type == 'text' &&
                c.key != 'currencyCode' &&
                !(_exportReport.startsWith('gl/') &&
                    const {'side', 'category'}.contains(c.key)),
            columnSearchEnabled:
                _statementReviewId == null &&
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
            value: (row) =>
                formatReportCell(c, row, includeUnit: !_replicatedReport),
            exactValueOf: (row) => row['${c.key}Exact']?.toString(),
            cellColor: _exportReport == 'gl/balance-sheet'
                ? (context, row) {
                    final styles = row['__cellStyles'];
                    final style = styles is Map ? styles[c.key] : null;
                    final fill = style is Map ? style['fillRgb'] : null;
                    if (fill is! String ||
                        !RegExp(r'^[0-9A-F]{6}$').hasMatch(fill) ||
                        fill == 'FFFFFF') {
                      return null;
                    }
                    return Color(0xff000000 | int.parse(fill, radix: 16));
                  }
                : null,
          ),
        )
        .toList();
    final pendingNotes = _pendingSourceNotes;
    final totalsBar = reportTotalsBar(
      data.totals,
      statisticsGeneratedAt: data.statisticsGeneratedAt,
    );
    return LayoutBuilder(
      builder: (context, tableConstraints) =>
          MasterDataTableView<Map<String, dynamic>>(
            expensiveRowMounts: false,
            primary: true,
            tableKey:
                'finance.report.${widget.cardId}.$_exportReport.${_variant.fixedParams['direction'] ?? ''}.source-v1',
            columns: columns,
            serverColumnSearchKeys: data.columnSearchKeys,
            facetPageLoaders: financeReportFacetLoaders(
              ref,
              report: _exportReport,
              query: _exportQuery,
              fields: [
                for (final column in columns)
                  if (column.type == 'text' &&
                      data.columnSearchKeys.contains(column.key) &&
                      !_nonQueryableColumns.contains(column.key) &&
                      column.key != 'currencyCode' &&
                      !(_exportReport.startsWith('gl/') &&
                          const {'side', 'category'}.contains(column.key)))
                    column.key,
              ],
            ),
            facetSearchScope: financeReportFacetScope(
              ref,
              report: _exportReport,
              query: _exportQuery,
            ),
            headerFilterScopeDescription:
                _exportReport == 'statements/subcontract'
                ? '库存为同委外商、货品、颜色及数量单位的整组事实，在各加工币别重复显示，不累计；加工金额按本币别计价数量检索'
                : _exportReport == 'cost/copper-fee'
                ? '按往来方、货品、单位及币别核算；金额累计原成交金额'
                : widget.cardId == 'gl' && _fixedFinanceRowOrder
                ? '定位已计算行，原会计合计不重算'
                : '检索所选条件的完整报表；合计与导出沿用同一范围',
            items: data.rows,
            rowColor: (row) =>
                const {
                  'SUBTOTAL',
                  'TOTAL',
                  'CURRENCY',
                }.contains(row['__rowKind'])
                ? Theme.of(context).colorScheme.surfaceContainerHigh
                : null,
            toolbarActions: _fitFinancialActions(tableConstraints.maxWidth, [
              if (_accountingMonth)
                SizedBox(
                  width: 220,
                  child: UtenMonthField(
                    label: _exportReport == 'gl/profit-monthly'
                        ? '会计月份'
                        : '截至月份',
                    value: UtenMonthField.format(_to),
                    info: _exportReport == 'gl/profit-monthly'
                        ? '本月金额及同年1月至本月累计'
                        : '${_to.year}年1月至${_to.month}月；后续月份不适用',
                    firstYear: 2010,
                    onChanged: (value) {
                      final month = UtenMonthField.parse(value);
                      if (month == null) return;
                      setState(() {
                        _to = DateTime(month.year, month.month + 1, 0);
                      });
                      _persistAndReload();
                    },
                  ),
                )
              else
                FinanceDateRangeFilter(
                  from: _from,
                  to: _to,
                  info:
                      _exportReport == 'gl/balance-sheet' ||
                          _exportReport.startsWith('fa/')
                      ? '余额与明细截至所选截止日'
                      : null,
                  onChanged: (from, to) {
                    setState(() {
                      _from = from!;
                      _to = to!;
                      _statementReviewId = null;
                      _binId = null;
                      _bins = [];
                      ++_contextGeneration;
                      _loadingContexts = false;
                    });
                    return _persistAndReload();
                  },
                ),
              if (_exportReport.startsWith('fa/') &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.financeAssetView))
                UtenButton(
                  key: const Key('finance-asset-opening-group-open'),
                  onPressed: _openAssetOpeningGroup,
                  child: const Text('原表接续'),
                ),
              if (_partyStatement || _materialStatement)
                UtenButton(
                  key: const Key('finance-statement-documents-open'),
                  onPressed: _openStatementDocuments,
                  child: const Text('原件及打印资料'),
                ),
              if (_exportReport == 'statements/subcontract' &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.financeViewAll))
                UtenButton(
                  key: const Key('finance-subcontract-loss-policy-open'),
                  onPressed: _partyId == null
                      ? null
                      : _openSubcontractLossPolicy,
                  child: const Text('允许损耗率'),
                ),
              if (_exportReport == 'statements/subcontract' &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.financeViewAll))
                UtenButton(
                  key: const Key('finance-subcontract-quantity-evidence-open'),
                  onPressed: _partyId == null
                      ? null
                      : _openSubcontractQuantityEvidence,
                  child: const Text('原表数量核对'),
                ),
              if (_partyStatement &&
                  _exportReport != 'statements/client' &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.supplierSettlementView))
                UtenButton(
                  key: const Key('finance-procurement-confirmation-open'),
                  onPressed: _openProcurementConfirmation,
                  child: const Text('对账确认'),
                ),
              if (_statementReviewId != null)
                UtenButton(
                  onPressed: () {
                    setState(() {
                      _statementReviewId = null;
                      _filters.clear();
                      _sortKey = null;
                    });
                    _load();
                  },
                  child: const Text('返回当前账载'),
                ),
              if (widget.cardId == 'gl' &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.financeViewAll))
                UtenButton(
                  key: const Key('finance-accounting-import-open'),
                  onPressed: _openAccountingImport,
                  child: const Text(
                    FinanceRequirementNames.accountingContinuation,
                  ),
                ),
              if ((widget.cardId == 'gl' ||
                      widget.cardId == 'summary' ||
                      widget.cardId == 'recon') &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.financeViewAll))
                UtenButton(
                  key: const Key('finance-auxiliary-open'),
                  onPressed: () async {
                    await showFinanceAuxiliaryPicker(
                      context,
                      canEdit: _canMaintainTemplates,
                      selection: false,
                    );
                    if (mounted) _load();
                  },
                  child: const Text('辅助核算项目'),
                ),
              if (_auxiliaryReport && _canMaintainTemplates)
                UtenButton(
                  key: const Key('finance-auxiliary-import-open'),
                  onPressed: _openAuxiliaryImport,
                  child: const Text('导入原明细表'),
                ),
              if (_exportReport == 'ar-ap/summary' &&
                  _variant.fixedParams['direction'] == 'AR' &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.arApLedgerView) &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.financeViewAll))
                UtenButton(
                  key: const Key('finance-receivable-classification-open'),
                  onPressed: () async {
                    if (!_acceptedQueryCurrent) return;
                    final epoch = ref.read(exportContextEpochProvider),
                        generation = _loadGeneration;
                    await showFinanceOpenItemClassificationDialog(
                      context,
                      partyId: _partyId,
                      currencyId: _currencyId,
                      receivable: true,
                    );
                    if (mounted &&
                        epoch == ref.read(exportContextEpochProvider) &&
                        generation == _loadGeneration) {
                      await _load();
                    }
                  },
                  child: const Text('货款/物料分类'),
                ),
              if (_exportReport == 'ar-ap/summary' &&
                  _variant.fixedParams['direction'] == 'AP' &&
                  ref
                      .watch(currentPermissionsProvider)
                      .contains(Perm.arApLedgerView)) ...[
                UtenButton(
                  onPressed: () async {
                    await showFinanceOpenItemClassificationDialog(
                      context,
                      partyId: _partyId,
                      currencyId: _currencyId,
                    );
                    if (mounted) _load();
                  },
                  child: const Text('货款/模具款分类'),
                ),
                UtenButton(
                  onPressed: () async {
                    await showFinanceSupplierPrepaymentDialog(
                      context,
                      supplierId: _partyId,
                      currencyId: _currencyId,
                    );
                    if (mounted) _load();
                  },
                  child: const Text('供应商预付款'),
                ),
              ],
              if (_canMaintainTemplates &&
                  const {
                    'gl/manufacturing-expense',
                    'gl/operating-pl',
                  }.contains(_exportReport))
                UtenButton(
                  onPressed: () => _openExpenseInput('labor'),
                  child: const Text('人工归属'),
                ),
              if (_canMaintainTemplates &&
                  _exportReport == 'gl/operating-pl') ...[
                UtenButton(
                  onPressed: () => _openExpenseInput('note'),
                  child: const Text('备注/差异原因'),
                ),
                UtenButton(
                  onPressed: () => _openExpenseInput('policy'),
                  child: const Text('核对成本口径'),
                ),
              ],
              if (_canMaintainTemplates &&
                  _exportReport == 'gl/sales-expense') ...[
                UtenButton(
                  onPressed: () => _openExpenseInput('group'),
                  child: const Text('人员/渠道归属'),
                ),
                UtenButton(
                  onPressed: () => _openExpenseInput('assignment'),
                  child: const Text('费用归属'),
                ),
              ],
              if (widget.cardId == 'gl')
                UtenButton(
                  key: const Key('finance-chart-open'),
                  onPressed: _openChart,
                  child: const Text(FinanceRequirementNames.chartCodes),
                ),
              if (widget.cardId == 'gl' &&
                  ref.watch(costWorkbenchCapabilityProvider).canReadPostings)
                UtenButton(
                  key: const ValueKey('inventory-cost-open'),
                  type: UtenButtonType.secondary,
                  onPressed: _openInventoryCostPosting,
                  child: Text(AppLocalizations.of(context).inventoryCostTitle),
                ),
              if (_statementTemplate)
                UtenButton(
                  key: const Key('finance-statement-template-preview'),
                  onPressed:
                      _filters.isEmpty &&
                          _acceptedQueryCurrent &&
                          !_loading &&
                          !_preparingTemplate &&
                          pendingNotes.isEmpty
                      ? _openStatementTemplate
                      : null,
                  height: UtenTableToolbar.controlHeight,
                  icon: Icons.print_outlined,
                  size: UtenButtonSize.large,
                  child: const Text('预览打印'),
                )
              else
                UtenPrintPreviewButton(
                  applyTableProjection: !_replicatedReport,
                  title: _variant.label,
                  subtitle: _partyStatement || _materialStatement
                      ? null
                      : '日期 ${_fmt(_queryFrom)} ~ ${_fmt(_queryTo)}(最多前 2000 行)',
                  loader: _printLoader,
                  exportEndpoint: '/finance/reports/export',
                  exportPermission: Perm.financeReportExport,
                  exportReport: _exportReport,
                  exportQuery: _exportQuery,
                  exportFilename: _variant.label,
                  type: UtenButtonType.primary,
                  size: UtenButtonSize.large,
                ),
              UtenExportButton(
                enabled:
                    !_statementTemplate ||
                    (_acceptedQueryCurrent &&
                        !_loading &&
                        (!_statementTemplate || _filters.isEmpty) &&
                        pendingNotes.isEmpty),
                endpoint: '/finance/reports/export',
                requiredPermission: Perm.financeReportExport,
                report: _exportReport,
                queryParams: _exportQuery,
                filename: _variant.label,
                type: UtenButtonType.primary,
                size: UtenButtonSize.large,
              ),
            ]),
            facets: data.facets,
            nullCounts: const {},
            filters: {for (final e in _filters.entries) e.key: e.value},
            onFilterChanged: _onFilterChanged,
            sortColumn: _sortKey,
            sortAscending: _sortAsc,
            onSortChange: _onSortChange,
            onRowTap: _openReportRow,
            isLoading: _loading,
            isRefreshing: _reportPages.refreshing,
            refreshError: _reportPages.refreshError,
            refreshedPages: _reportPages.refreshedPages,
            paginationRevision: _reportPages.paginationRevision,
            error: _acceptedQueryCurrent ? _reportPages.error : _error,
            onRetry: () => _load(background: _data != null),
            emptyMessage: _isCustomerPrepaymentEvents
                ? '所选日期和客户暂无客户预收流水'
                : _materialStatement && _materialContextId == null
                ? '请选择已审核的对账资料，按原表查看'
                : _partyStatement && (_partyId == null || _currencyId == null)
                ? '请选择实际往来对象和币别，按原表查看对账单'
                : '暂无报表数据',
            // 服务端分页表格：合计由后端在整个结果集上算（reportTotalsBar），
            // 不是对当前这一页求和；后端未声明合计列时返回 null，整条不渲染。
            summaryBar: data.documentMetadata.isEmpty
                ? totalsBar
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ?totalsBar,
                      if (data.documentMetadata.isNotEmpty)
                        _documentMetadata(data, header: false),
                    ],
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
              _partyId,
              _currencyId,
              _binId,
              PagedReadQueryKey(_filters),
              _sortKey,
              _sortAsc,
            ),
          ),
    );
  }

  String get _pendingSourceNotes {
    if (!_acceptedQueryCurrent) return '';
    return _data?.rows
            .where((row) => row['__pending'] == true)
            .map(
              (row) =>
                  (row['__basis'] ?? row['basis'] ?? '取数尚未核对完整').toString(),
            )
            .toSet()
            .take(3)
            .join('；') ??
        '';
  }

  /// Keep dates, printing and export immediately available. The retained Uten
  /// controls move into the existing project action panel when maintenance
  /// actions would squeeze column settings/fullscreen into a narrow column.
  List<Widget> _fitFinancialActions(double width, List<Widget> actions) {
    if (!width.isFinite || UtenCompactPresentation.of(context)) return actions;
    bool primary(Widget child) =>
        child is UtenPrintPreviewButton ||
        child is UtenExportButton ||
        child.key == const Key('finance-statement-template-preview');
    final maintenance = actions
        .where((child) => UtenActionOverflow.isAction(child) && !primary(child))
        .toList();
    if (maintenance.isEmpty) return actions;
    final controls = actions
        .where((child) => !UtenActionOverflow.isAction(child))
        .toList();
    final mainActions = actions.where(primary).toList();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final reserved =
        UtenTableToolbar.controlHeight * (5 + mainActions.length * 3) * scale +
        controls.length * 320 +
        UtenSpacing.s8 * 5;
    final budget = (width - reserved)
        .clamp(UtenTableToolbar.controlHeight, double.infinity)
        .toDouble();
    return [
      ...controls,
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: budget),
        child: UtenActionOverflow(
          key: const ValueKey('finance-report-maintenance-actions'),
          label: '财务操作',
          children: maintenance,
        ),
      ),
      ...mainActions,
    ];
  }

  /// 状态类列判定：label 为「状态」或含「状态」（如 单据状态/审核状态）。
  static bool _isStatusColumnLabel(String label) => label.contains('状态');
}
