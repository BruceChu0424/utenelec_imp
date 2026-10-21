// 往来对帐单页 (I/J/K/L/X)（finance_report:view）。
//
// 单独卡：side 分段切换 应收(客户)/应付(供应商) + 选往来单位 + 报表类型分段：
//   · 流水对帐 (I 单客户 / K 单供应商)   → /finance/reports/statement/flow?partyId&side
//   · 明细对帐 (J 单客户 / L 单供应商)   → /finance/reports/statement/detail?partyId&side
//   · 年度对帐 (X 客户/供应商，按月)      → /finance/reports/statement/annual?partyId&side&year
// 右侧 MasterDataTableView（滚动余额列）。默认日期范围 = 上月今日..今日（defaultReportFrom()）。
//
// 筛选口径（方向/报表类型/往来单位/年度/日期范围/排序）按账号服务端持久化
// （report.finance.statement，ReportFilterPrefs：docType=side、extra={view,partyId,year}）；
// 关键字不持久化。
import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
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
import '../../report/shared/report_date_range.dart';
import '../widgets/finance_date_range_filter.dart';
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../../report/shared/report_total.dart';

enum _StmtView { flow, detail, annual }

class _Party {
  const _Party(this.id, this.name);
  final String id;
  final String name;
}

class FinanceStatementPage extends ConsumerStatefulWidget {
  const FinanceStatementPage({super.key});

  @override
  ConsumerState<FinanceStatementPage> createState() =>
      _FinanceStatementPageState();
}

class _FinanceStatementPageState extends ConsumerState<FinanceStatementPage> {
  String _side = 'AR'; // AR=客户 / AP=供应商
  _StmtView _view = _StmtView.flow;
  String? _partyId;
  List<_Party> _partyList = const [];
  bool _partyLoading = false;
  int _year = ChinaDateTime.today().year;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _keyword = '';
  int _page = 1;
  final int _size = 50;

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  ReportData? _data;
  bool _loading = false;
  int _loadGeneration = 0;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyPrefs(ref.read(financeStatementReportPrefsProvider));
      _loadParties();
      _load();
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      if (p.docType == 'AR' || p.docType == 'AP') _side = p.docType!;
      final v = p.extra['view']?.toString();
      if (v != null) {
        _view = _StmtView.values.firstWhere(
          (e) => e.name == v,
          orElse: () => _view,
        );
      }
      _partyId = p.extra['partyId']?.toString();
      final y = p.extra['year'];
      if (y is num) _year = y.toInt();
      // 日期范围不回灌：进页始终用默认日期范围（上月今日..今日），避免历史持久化
      // 的过时日期范围把新数据滤空（销售报表已踩此坑，见 sales_report_page.dart）。
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _side,
    sortKey: _sortKey,
    sortAsc: _sortAsc,
    extra: {
      'view': _view.name,
      if (_partyId != null) 'partyId': _partyId,
      'year': _year,
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
    ref.read(financeStatementReportPrefsProvider.notifier).update(_snapshot());
  }

  Future<void> _loadParties() async {
    setState(() => _partyLoading = true);
    final api = ref.read(apiClientProvider);
    try {
      final path = _side == 'AR'
          ? ApiEndpoints.clientsDict
          : ApiEndpoints.suppliersDict;
      final list = await api.getList(path);
      final parties = list
          .map((j) {
            return _Party(
              j['id']?.toString() ?? '',
              j['name']?.toString() ?? '',
            );
          })
          .where((p) => p.id.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _partyList = parties;
        // 保留仍然有效的 partyId（偏好恢复的选中不被覆盖）；已失效（被删/换方向）才清空。
        if (_partyId != null && parties.every((p) => p.id != _partyId)) {
          _partyId = null;
        }
        _partyLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _partyLoading = false);
    }
  }

  String get _endpoint => switch (_view) {
    _StmtView.flow => '/finance/reports/statement/flow',
    _StmtView.detail => '/finance/reports/statement/detail',
    _StmtView.annual => '/finance/reports/statement/annual',
  };

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final requestedPage = _page;
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        if (_partyId != null) 'partyId': _partyId,
        'side': _side,
        'page': requestedPage,
        'size': _size,
        if (_view != _StmtView.annual) ...{
          'dateFrom': _fmt(_from),
          'dateTo': _fmt(_to),
        },
        if (_view == _StmtView.annual) 'year': _year,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(_endpoint, query: query);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _data = parseReportResponse(json, requestedPage);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      context.appError(humanErrorMessage(e) ?? '对账单没有加载出来，请稍后重试');
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

  /// 导出报表 key（与 GET 路径一致：statement/{flow,detail,annual}）。
  String get _exportReport => switch (_view) {
    _StmtView.flow => 'statement/flow',
    _StmtView.detail => 'statement/detail',
    _StmtView.annual => 'statement/annual',
  };

  /// 导出查询参数（与 _load 一致，不含 page/size）。year/日期按报表类型给。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_partyId != null) 'partyId': _partyId,
    'side': _side,
    if (_view != _StmtView.annual) ...{
      'dateFrom': _fmt(_from),
      'dateTo': _fmt(_to),
    },
    if (_view == _StmtView.annual) 'year': _year,
    ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// 打印预览数据：按当前视图/往来单位口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final json = await api.get(
      _endpoint,
      query: <String, dynamic>{..._exportQuery, 'page': 1, 'size': 2000},
    );
    final data = parseReportResponse(json, 1);
    return UtenPrintTable(
      columnKeys: [for (final c in data.columns) c.key],
      rowIds: [for (final r in data.rows) r['id']?.toString()],
      factValues: [
        for (final r in data.rows)
          {for (final entry in r.entries) entry.key: entry.value?.toString()},
      ],
      headers: [for (final c in data.columns) c.label],
      rows: [
        for (final r in data.rows)
          [for (final c in data.columns) formatReportCell(c, r) ?? ''],
      ],
    );
  }

  /// 当前视图标签（build 与表格工具条共用）。
  String get _viewLabel => switch (_view) {
    _StmtView.flow => _side == 'AR' ? '单客户流水对帐单' : '单供应商流水对帐单',
    _StmtView.detail => _side == 'AR' ? '单客户明细对帐单' : '单供应商明细对帐单',
    _StmtView.annual => _side == 'AR' ? '客户年度对帐单' : '供应商年度对帐单',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 服务端偏好同步晚到：仅在用户未动手时回灌并重查（避免覆盖在输状态）。
    ref.listen(financeStatementReportPrefsProvider, (prev, next) {
      if (!_dirty && prev != next && !next.isEmpty && mounted) {
        _applyPrefs(next);
        _loadParties();
        _page = 1;
        _load();
      }
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: _viewLabel,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenFilterToolbar<String>(
            compactBreakpoint: UtenBreakpoints.mediumStart,
            segments: const [
              UtenFilterSegment(value: 'AR', label: '应收(客户)'),
              UtenFilterSegment(value: 'AP', label: '应付(供应商)'),
            ],
            selected: {_side},
            onSelectionChanged: _changeSide,
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenFilterToolbar<_StmtView>(
            compactBreakpoint: UtenBreakpoints.mediumStart,
            segments: const [
              UtenFilterSegment(value: _StmtView.flow, label: '流水对帐'),
              UtenFilterSegment(value: _StmtView.detail, label: '明细对帐'),
              UtenFilterSegment(value: _StmtView.annual, label: '年度对帐'),
            ],
            selected: {_view},
            onSelectionChanged: _changeView,
            searchHint: _view == _StmtView.annual ? null : '搜索单号',
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
              SizedBox(
                width: 240,
                child: _partyLoading
                    ? const LinearProgressIndicator()
                    : DropdownButtonFormField<String?>(
                        initialValue: _partyId,
                        isExpanded: true,
                        decoration: UtenInputDecoration(
                          InputDecoration(
                            isDense: true,
                            labelText: _side == 'AR' ? '客户' : '供应商',
                          ),
                        ),
                        items: [
                          for (final party in _partyList)
                            DropdownMenuItem<String?>(
                              value: party.id,
                              child: Text(
                                party.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          setState(() => _partyId = value);
                          _persistAndReload();
                        },
                      ),
              ),
              if (_view == _StmtView.annual)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '上一年',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () {
                        setState(() => _year--);
                        _persistAndReload();
                      },
                    ),
                    Text('$_year', style: theme.textTheme.titleMedium),
                    IconButton(
                      tooltip: '下一年',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () {
                        setState(() => _year++);
                        _persistAndReload();
                      },
                    ),
                  ],
                )
              else
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
          ),
        ],
      ),
    );
  }

  void _changeView(_StmtView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _page = 1;
      _data = null;
    });
    _persistPrefs();
    _load();
  }

  /// 方向切换（原两个 ChoiceChip 的 onSelected 内联逻辑，语义原样收拢）：
  /// 换边即清往来单位（AR 客户表 ↔ AP 供应商表）并回第 1 页重查。
  void _changeSide(String side) {
    if (_side == side) return;
    setState(() {
      _side = side;
      _partyId = null;
      _page = 1;
      _data = null;
    });
    _persistPrefs();
    _loadParties();
    _load();
  }

  Widget _buildTable() {
    if (_partyId == null) {
      return const Center(child: Text('请先选择往来单位'));
    }
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final data = _data;
    if (data == null) {
      return const Center(child: Text('点击「查询」加载'));
    }
    // 状态列前置（全站口径）：列元数据来自服务端，客户端映射时把「状态」类列
    // 排到最前，其余列保持服务端顺序；两个分区各自保持原有相对顺序。
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
            sortable: isSortableReportType(c.type),
            value: (row) => formatReportCell(c, row),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      primary: true,
      tableKey:
          'features.finance.pages.finance_statement_page.FinanceStatementPageState._buildTable.1',
      columns: columns,
      items: data.rows,
      toolbarActions: [
        // 对帐单需先选往来单位；未选时按钮仍显，点击后后端返回空表（partyStatement* 空结构）。
        UtenPrintPreviewButton(
          title: '往来对帐单 · $_viewLabel',
          subtitle: _view == _StmtView.annual
              ? '年度 $_year(最多前 2000 行)'
              : '日期 ${_fmt(_from)} ~ ${_fmt(_to)}(最多前 2000 行)',
          loader: _printLoader,
          exportEndpoint: '/finance/reports/export',
          exportPermission: Perm.financeReportExport,
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '往来对帐单',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/finance/reports/export',
          requiredPermission: Perm.financeReportExport,
          report: _exportReport,
          queryParams: _exportQuery,
          filename: '往来对帐单',
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
      emptyMessage: '暂无对帐数据',
      // 服务端分页表格：合计由后端在整个结果集上算（reportTotalsBar），
      // 不是对当前这一页求和；后端未声明合计列时返回 null，整条不渲染。
      summaryBar: reportTotalsBar(data.totals),
      currentPage: data.page,
      totalPages: data.totalPages,
      paginationScope: (_side, _view, _partyId, _year, _from, _to, _keyword),
      onPageChange: (p) {
        _page = p;
        _load();
      },
    );
  }

  static bool _isStatusColumnLabel(String label) => label.contains('状态');
}
