import 'package:uten_imp/shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
import 'package:uten_imp/shared/providers/native_facet_options.dart';
// 账户流水页 (S/Q/R)（finance_report:view）。
//
// 单独卡：报表类型分段（UtenFilterToolbar）：
//   · 帐户进出流水 (S)   → /finance/reports/account/statement?accountId&dateFrom&dateTo&keyword（滚动余额）
//   · 银行存取明细 (Q)   → /finance/reports/bank/detail（M_Bank 老库 0 行，空表保结构）
//   · 银行存取汇总 (R)   → /finance/reports/bank/summary（空表）
// 右侧 MasterDataTableView。默认日期范围 = 上月今日..今日（defaultReportFrom()）。账户列表来自 FinanceNameService。
//
// 筛选口径（报表类型/账户/日期范围/排序）按账号服务端持久化
// （report.finance.accountFlow，ReportFilterPrefs：docType=view、extra={accountId}）；关键字不持久化。
import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import '../../report/shared/account_statement_column_query.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

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
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
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
import '../providers/finance_name_provider.dart';

enum _FlowView { statement, bankDetail, bankSummary }

class FinanceAccountFlowPage extends ConsumerStatefulWidget {
  const FinanceAccountFlowPage({super.key});

  @override
  ConsumerState<FinanceAccountFlowPage> createState() =>
      _FinanceAccountFlowPageState();
}

class _FinanceAccountFlowPageState
    extends ConsumerState<FinanceAccountFlowPage> {
  _FlowView _view = _FlowView.statement;
  String? _accountId;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _keyword = '';
  String? _billNoFilter;
  final _columnQuery = <String, String?>{};
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
  bool _loading = false;
  int _loadGeneration = 0;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // Keep the monotonic reader epoch observed for this page's whole lifetime.
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      setState(() {
        ++_loadGeneration;
        _reportRead.invalidate();
        _data = null;
        _loading = false;
        _page = 1;
        _keyword = '';
        _accountId = null;
        _billNoFilter = null;
        _columnQuery.clear();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final readEpoch = ref.read(exportContextEpochProvider);
      _applyPrefs(ref.read(financeAccountFlowReportPrefsProvider));
      // 已恢复的账户已有精确身份；名称预热不应阻塞它的流水读取。
      final canLoad = _view != _FlowView.statement || _accountId != null;
      if (canLoad) _load();
      ref
          .read(financeNameServiceProvider)
          .ensureLoaded()
          .then<void>(
            (_) {
              if (!mounted ||
                  readEpoch != ref.read(exportContextEpochProvider)) {
                return;
              }
              final entries = ref
                  .read(financeNameServiceProvider)
                  .accountEntries;
              final previousAccount = _accountId;
              // 偏好恢复的账户优先；无恢复值才默认第一个
              if (entries.isNotEmpty) {
                setState(() {
                  if (_accountId == null || !entries.containsKey(_accountId)) {
                    _accountId = entries.keys.first;
                  }
                });
              }
              if (!canLoad || previousAccount != _accountId) _load();
            },
            onError: (Object error, StackTrace stack) {
              if (!mounted ||
                  readEpoch != ref.read(exportContextEpochProvider)) {
                return;
              }
              if (!canLoad) {
                context.appError(humanErrorMessage(error) ?? '账户没有加载出来，请刷新重试');
              }
            },
          );
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      final v = p.docType;
      if (v != null) {
        _view = _FlowView.values.firstWhere(
          (e) => e.name == v,
          orElse: () => _view,
        );
      }
      _accountId = p.extra['accountId']?.toString();
      // 日期范围不回灌：进页始终用默认日期范围（上月今日..今日），避免历史持久化
      // 的过时日期范围把新数据滤空（销售报表已踩此坑，见 sales_report_page.dart）。
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _view.name,
    sortKey: _sortKey,
    sortAsc: _sortAsc,
    extra: {if (_accountId != null) 'accountId': _accountId},
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
        .read(financeAccountFlowReportPrefsProvider.notifier)
        .update(_snapshot());
  }

  String get _endpoint => switch (_view) {
    _FlowView.statement => '/finance/reports/account/statement',
    _FlowView.bankDetail => '/finance/reports/bank/detail',
    _FlowView.bankSummary => '/finance/reports/bank/summary',
  };

  Map<String, dynamic> get _readQuery => <String, dynamic>{
    if (_view == _FlowView.statement) ...{
      if (_accountId != null) 'accountId': _accountId,
      'dateFrom': _fmt(_from),
      'dateTo': _fmt(_to),
      if (_keyword.isNotEmpty) 'keyword': _keyword,
      if (_billNoFilter != null) 'billNo': _billNoFilter,
      ...accountStatementColumnParameters(_columnQuery),
    },
    'size': _size,
    if (_view != _FlowView.statement) ...sortQueryParams(_sortKey, _sortAsc),
  };

  Future<void> _load({int? page, bool reuseMetadata = false}) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final readEpoch = ref.read(exportContextEpochProvider);
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        readEpoch == ref.read(exportContextEpochProvider);
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = _readQuery;
      final endpoint = _endpoint;
      bool queryCurrent() =>
          mounted &&
          readEpoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)) &&
          endpoint == _endpoint &&
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
          _reportRead.invalidate();
          ++_loadGeneration;
          context.appError(error.message);
          setState(() {
            _data = null;
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
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !current()) return;
      if (pagedReadAccessDenied(e)) {
        _reportRead.invalidate();
        setState(() {
          _data = null;
        });
      }
      context.appError(humanErrorMessage(e) ?? '流水没有加载出来，请稍后重试');
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

  /// 导出报表 key（仅 S 帐户进出流水纳入导出；Q/R 银行存取款老库 0 行空表，不纳入）。
  String get _exportReport => 'account/statement';

  /// 导出查询参数（与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_accountId != null) 'accountId': _accountId,
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    if (_billNoFilter != null) 'billNo': _billNoFilter,
    ...accountStatementColumnParameters(_columnQuery),
  };

  /// 按真实服务器分页读取当前条件的前2000行，保留余额原有入账顺序。
  /// 仅 S 帐户进出流水（与导出口径一致）。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final generation = _loadGeneration, view = _view;
    final epoch = ref.read(exportContextEpochProvider);
    return loadBoundedReportPrintPreview(
      api: api,
      endpointOf: () => '/finance/reports/account/statement',
      queryOf: () => _exportQuery,
      cellTextOf: formatAccountStatementReportCell,
      isCurrent: () =>
          mounted &&
          generation == _loadGeneration &&
          view == _view &&
          epoch == ref.read(exportContextEpochProvider) &&
          identical(api, ref.read(apiClientProvider)),
    );
  }

  /// 当前视图标题（build 与表格工具条共用）。
  String get _title => switch (_view) {
    _FlowView.statement => '帐户进出流水帐',
    _FlowView.bankDetail => '银行存取款明细表',
    _FlowView.bankSummary => '银行存取款汇总表',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _title;
    // 服务端偏好同步晚到：仅在用户未动手时回灌并重查（避免覆盖在输状态）。
    ref.listen(financeAccountFlowReportPrefsProvider, (prev, next) {
      if (!_dirty && prev != next && !next.isEmpty && mounted) {
        _applyPrefs(next);
        _page = 1;
        _load();
      }
    });
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

  Widget _buildFilterPane(ThemeData theme) {
    final names = ref.watch(financeNameServiceProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenFilterToolbar<_FlowView>(
            compactBreakpoint: UtenBreakpoints.mediumStart,
            segments: const [
              UtenFilterSegment(value: _FlowView.statement, label: '帐户进出流水'),
              UtenFilterSegment(value: _FlowView.bankDetail, label: '银行存取明细'),
              UtenFilterSegment(value: _FlowView.bankSummary, label: '银行存取汇总'),
            ],
            selected: {_view},
            onSelectionChanged: _changeView,
            searchHint: _view == _FlowView.statement ? '搜索单号 / 对方' : null,
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
          if (_view == _FlowView.statement)
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  child: UtenDropdownScrollScope(
                    nativeDropdown: true,
                    child: DropdownButtonFormField<String?>(
                      initialValue: _accountId,
                      isExpanded: true,
                      decoration: const UtenInputDecoration(
                        InputDecoration(isDense: true, labelText: '账户'),
                      ),
                      items: [
                        for (final entry in names.accountEntries.entries)
                          DropdownMenuItem<String?>(
                            value: entry.key,
                            child: Text(
                              entry.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _accountId = value;
                          _billNoFilter = null;
                          _columnQuery.clear();
                        });
                        _persistAndReload();
                      },
                    ),
                  ),
                ),
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
              ],
            )
          else
            Text(
              '银行存取款数据尚未启用，当前暂无记录。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  void _changeView(_FlowView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _page = 1;
      _data = null;
      _billNoFilter = null;
      _columnQuery.clear();
    });
    _persistPrefs();
    _load();
  }

  Widget _buildTable() {
    if (_view == _FlowView.statement && _accountId == null) {
      return const Center(child: Text('请先选择账户'));
    }
    final data = _data ?? (_loading ? _reportMetadata.loadingData : null);
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
            sortable:
                _view != _FlowView.statement && isSortableReportType(c.type),
            columnSearchEnabled: _view == _FlowView.statement
                ? accountStatementSearchKeys.contains(c.key)
                : null,
            exactValueOf:
                const {'inAmount', 'outAmount', 'balance'}.contains(c.key)
                ? (row) => row[c.key] == null
                      ? null
                      : (row['${c.key}Exact'] ?? row[c.key]).toString()
                : null,
            value: (row) => _view == _FlowView.statement
                ? formatAccountStatementReportCell(c, row)
                : formatReportCell(c, row),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      rowsController: _tableRows,
      expensiveRowMounts: false,
      primary: true,
      tableKey:
          'features.finance.pages.finance_account_flow_page.FinanceAccountFlowPageState._buildTable.1',
      columns: columns,
      headerFilterScopeDescription: _view == _FlowView.statement
          ? '余额按日期和入账顺序完整累计后筛选；收支合计按筛选结果，余额不合计'
          : null,
      serverColumnSearchKeys: _view == _FlowView.statement
          ? accountStatementSearchKeys
          : const {},
      items: data.rows,
      // 仅 S 帐户进出流水支持预览打印/导出；Q/R 银行存取款为空表（M_Bank 0 行），不显示。
      toolbarActions: [
        if (_view == _FlowView.statement) ...[
          UtenPrintPreviewButton(
            title: _title,
            subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}(最多前 2000 行)',
            loader: _printLoader,
            exportEndpoint: '/finance/reports/export',
            exportPermission: Perm.financeReportExport,
            exportReport: _exportReport,
            exportQuery: _exportQuery,
            exportFilename: _title,
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
          ),
          UtenExportButton(
            endpoint: '/finance/reports/export',
            requiredPermission: Perm.financeReportExport,
            report: _exportReport,
            queryParams: _exportQuery,
            filename: _title,
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
          ),
        ],
      ],
      facets: _view == _FlowView.statement
          ? const {'entryKind': accountStatementEntryKinds}
          : const {},
      facetPageLoaders: _view == _FlowView.statement
          ? nativeFacetLoaders(
              ref,
              path: '/finance/reports/account/statement/facets',
              fields: const ['billNo'],
              filters: {
                'accountId': _accountId,
                'dateFrom': _fmt(_from),
                'dateTo': _fmt(_to),
                'keyword': _keyword,
              },
            )
          : const {},
      facetSearchScope: nativeFacetSearchScope(
        ref,
        '/finance/reports/account/statement/facets',
        {
          'accountId': _accountId,
          'dateFrom': _fmt(_from),
          'dateTo': _fmt(_to),
          'keyword': _keyword,
        },
      ),
      nullCounts: const {},
      filters: {'billNo': _billNoFilter, ..._columnQuery},
      onFilterChanged: (key, value) {
        if (key != 'billNo' &&
            !key.startsWith('search.') &&
            !accountStatementChoiceKeys.contains(key)) {
          return;
        }
        setState(() {
          _dirty = true;
          if (key == 'billNo') {
            _billNoFilter = value;
          } else if (value == null) {
            _columnQuery.remove(key);
          } else {
            _columnQuery[key] = value;
          }
          _page = 1;
        });
        _load();
      },
      sortColumn: _view == _FlowView.statement ? null : _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _view == _FlowView.statement ? null : _onSortChange,
      isLoading: _loading,
      onRetry: _load,
      emptyMessage: _view == _FlowView.statement ? '暂无流水数据' : '银行存取款未启用(空表)',
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
        _view,
        _accountId,
        _from,
        _to,
        _keyword,
        _billNoFilter,
        jsonEncode(accountStatementColumnParameters(_columnQuery)),
      ),
      onPageChange: (p) {
        _page = p;
        return _load(page: p, reuseMetadata: true);
      },
    );
  }
}
