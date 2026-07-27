// 账户流水页 (S/Q/R)（finance_report:view）。
//
// 单独卡：报表类型 chip：
//   · 帐户进出流水 (S)   → /finance/reports/account/statement?accountId&dateFrom&dateTo&keyword（滚动余额）
//   · 银行存取明细 (Q)   → /finance/reports/bank/detail（M_Bank 老库 0 行，空表保结构）
//   · 银行存取汇总 (R)   → /finance/reports/bank/summary（空表）
// 右侧 MasterDataTableView。默认日期范围 = 上月今日..今日（defaultReportFrom()）。账户列表来自 FinanceNameService。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_sort.dart';
import '../providers/finance_name_provider.dart';

enum _FlowView { statement, bankDetail, bankSummary }

class FinanceAccountFlowPage extends ConsumerStatefulWidget {
  const FinanceAccountFlowPage({super.key});

  @override
  ConsumerState<FinanceAccountFlowPage> createState() => _FinanceAccountFlowPageState();
}

class _FinanceAccountFlowPageState extends ConsumerState<FinanceAccountFlowPage> {
  _FlowView _view = _FlowView.statement;
  String? _accountId;
  DateTime _from = defaultReportFrom();
  DateTime _to = DateTime.now();
  String _keyword = '';
  int _page = 1;
  final int _size = 50;

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  ReportData? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded().then((_) {
        final entries = ref.read(financeNameServiceProvider).accountEntries;
        if (entries.isNotEmpty) setState(() => _accountId ??= entries.keys.first);
        _load();
      });
    });
  }

  String get _endpoint => switch (_view) {
        _FlowView.statement => '/finance/reports/account/statement',
        _FlowView.bankDetail => '/finance/reports/bank/detail',
        _FlowView.bankSummary => '/finance/reports/bank/summary',
      };

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        if (_view == _FlowView.statement) ...{
          if (_accountId != null) 'accountId': _accountId,
          'dateFrom': _fmt(_from),
          'dateTo': _fmt(_to),
          if (_keyword.isNotEmpty) 'keyword': _keyword,
        },
        'page': _page,
        'size': _size,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(_endpoint, query: query);
      if (!mounted) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      context.appError('加载流水失败：$e');
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
        ...sortQueryParams(_sortKey, _sortAsc),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (_view) {
      _FlowView.statement => '帐户进出流水帐',
      _FlowView.bankDetail => '银行存取款明细表',
      _FlowView.bankSummary => '银行存取款汇总表',
    };
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(onPressed: () => backTo(context, defaultPath: RouteName.finance)),
        actions: [
          // 仅 S 帐户进出流水支持导出；Q/R 银行存取款为空表（M_Bank 0 行），不显示导出按钮。
          if (_view == _FlowView.statement)
            UtenExportButton(
              endpoint: '/finance/reports/export',
              report: _exportReport,
              queryParams: _exportQuery,
              filename: title,
            ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8, left: UtenSpacing.s4, right: UtenSpacing.s4),
                  child: Row(children: [
                    Icon(Icons.account_balance_outlined, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: UtenSpacing.s8),
                    if (_data != null)
                      Text('共 ${_data!.total} 条',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ),
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: _buildFilterPane(theme),
                    tablePane: _buildTable(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterPane(ThemeData theme) {
    final names = ref.watch(financeNameServiceProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filterLabel('报表类型'),
            Wrap(spacing: 6, runSpacing: 4, children: [
              ChoiceChip(label: const Text('帐户进出流水'), selected: _view == _FlowView.statement, onSelected: (_) => _changeView(_FlowView.statement)),
              ChoiceChip(label: const Text('银行存取明细'), selected: _view == _FlowView.bankDetail, onSelected: (_) => _changeView(_FlowView.bankDetail)),
              ChoiceChip(label: const Text('银行存取汇总'), selected: _view == _FlowView.bankSummary, onSelected: (_) => _changeView(_FlowView.bankSummary)),
            ]),
            if (_view == _FlowView.statement) ...[
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('账户'),
              SizedBox(width: double.infinity, child: DropdownButtonFormField<String?>(
                initialValue: _accountId,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, hintText: '选择账户'),
                items: [
                  for (final e in names.accountEntries.entries)
                    DropdownMenuItem<String?>(value: e.key, child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) { setState(() { _accountId = v; _page = 1; }); _load(); },
              )),
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('日期范围'),
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                TextButton.icon(onPressed: () async {
                  final p = await showDatePicker(context: context, initialDate: _from, firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (p != null) setState(() => _from = p);
                }, icon: const Icon(Icons.event_outlined, size: 18), label: Text('起 ${_fmt(_from)}')),
                TextButton.icon(onPressed: () async {
                  final p = await showDatePicker(context: context, initialDate: _to, firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (p != null) setState(() => _to = p);
                }, icon: const Icon(Icons.event_outlined, size: 18), label: Text('止 ${_fmt(_to)}')),
              ]),
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('搜索'),
              UtenSearchBar(hint: '搜索单号/对方', initialValue: _keyword, onChanged: (v) => _keyword = v),
              const SizedBox(height: UtenSpacing.s12),
              SizedBox(width: double.infinity, child: FilledButton.tonalIcon(
                onPressed: () { _page = 1; _load(); },
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('查询'),
              )),
            ],
            if (_view != _FlowView.statement) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text('银行存取款单老库未启用（0 行），报表为空（结构已就位，启用后自动出数）。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  void _changeView(_FlowView v) {
    if (v == _view) return;
    setState(() { _view = v; _page = 1; _data = null; });
    _load();
  }

  Widget _buildTable() {
    if (_view == _FlowView.statement && _accountId == null) {
      return const Center(child: Text('请先选择账户'));
    }
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final data = _data;
    if (data == null) {
      return const Center(child: Text('点击「查询」加载'));
    }
    final columns = data.columns
        .map((c) => MasterColumnDef<Map<String, dynamic>>(
              key: c.key, label: c.label, width: (c.width ?? 120).toDouble(),
              type: c.type,
              sortable: isSortableReportType(c.type),
              value: (row) => formatReportCell(c, row),
            ))
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      columns: columns,
      items: data.rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, __) {},
      sortColumn: _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      onRowTap: (_) {},
      isLoading: _loading,
      emptyMessage: _view == _FlowView.statement ? '暂无流水数据' : '银行存取款未启用（空表）',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (p) { _page = p; _load(); },
    );
  }

  Widget _filterLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
    );
  }
}
