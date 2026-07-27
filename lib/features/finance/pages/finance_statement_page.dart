// 往来对帐单页 (I/J/K/L/X)（finance_report:view）。
//
// 单独卡：side 切换 应收(客户)/应付(供应商) + 选往来单位 + 报表类型 chip：
//   · 流水对帐 (I 单客户 / K 单供应商)   → /finance/reports/statement/flow?partyId&side
//   · 明细对帐 (J 单客户 / L 单供应商)   → /finance/reports/statement/detail?partyId&side
//   · 年度对帐 (X 客户/供应商，按月)      → /finance/reports/statement/annual?partyId&side&year
// 右侧 MasterDataTableView（滚动余额列）。默认日期范围 = 上月今日..今日（defaultReportFrom()）。
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

enum _StmtView { flow, detail, annual }

class _Party {
  const _Party(this.id, this.name);
  final String id;
  final String name;
}

class FinanceStatementPage extends ConsumerStatefulWidget {
  const FinanceStatementPage({super.key});

  @override
  ConsumerState<FinanceStatementPage> createState() => _FinanceStatementPageState();
}

class _FinanceStatementPageState extends ConsumerState<FinanceStatementPage> {
  String _side = 'AR'; // AR=客户 / AP=供应商
  _StmtView _view = _StmtView.flow;
  String? _partyId;
  List<_Party> _partyList = const [];
  bool _partyLoading = false;
  int _year = DateTime.now().year;
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
      _loadParties();
      _load();
    });
  }

  Future<void> _loadParties() async {
    setState(() => _partyLoading = true);
    final api = ref.read(apiClientProvider);
    try {
      final path = _side == 'AR' ? '/master/clients' : '/master/suppliers';
      final list = await api.getList(path, query: {'size': 9999});
      final parties = list.map((m) {
        final j = m as Map<String, dynamic>;
        return _Party(j['id']?.toString() ?? '', j['name']?.toString() ?? '');
      }).where((p) => p.id.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        _partyList = parties;
        _partyId = null;
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
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        if (_partyId != null) 'partyId': _partyId,
        'side': _side,
        'page': _page,
        'size': _size,
        if (_view != _StmtView.annual) ...{
          'dateFrom': _fmt(_from),
          'dateTo': _fmt(_to),
        },
        if (_view == _StmtView.annual) 'year': _year,
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
      context.appError('加载对帐单失败：$e');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewLabel = switch (_view) {
      _StmtView.flow => _side == 'AR' ? '单客户流水对帐单' : '单供应商流水对帐单',
      _StmtView.detail => _side == 'AR' ? '单客户明细对帐单' : '单供应商明细对帐单',
      _StmtView.annual => _side == 'AR' ? '客户年度对帐单' : '供应商年度对帐单',
    };
    return Scaffold(
      appBar: UtenAppBar(
        title: '往来对帐单',
        leading: UtenBackButton(onPressed: () => backTo(context, defaultPath: RouteName.finance)),
        actions: [
          // 对帐单需先选往来单位；未选时按钮仍显，点击后后端返回空表（partyStatement* 空结构）。
          UtenExportButton(
            endpoint: '/finance/reports/export',
            report: _exportReport,
            queryParams: _exportQuery,
            filename: '往来对帐单',
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
                  child: Row(
                    children: [
                      Icon(Icons.receipt_long_outlined, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(viewLabel, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text('共 ${_data!.total} 条',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filterLabel('方向'),
            Wrap(spacing: 6, runSpacing: 4, children: [
              ChoiceChip(label: const Text('应收（客户）'), selected: _side == 'AR', onSelected: (_) {
                setState(() { _side = 'AR'; _page = 1; _data = null; });
                _loadParties();
                _load();
              }),
              ChoiceChip(label: const Text('应付（供应商）'), selected: _side == 'AP', onSelected: (_) {
                setState(() { _side = 'AP'; _page = 1; _data = null; });
                _loadParties();
                _load();
              }),
            ]),
            const SizedBox(height: UtenSpacing.s12),
            _filterLabel('报表类型'),
            Wrap(spacing: 6, runSpacing: 4, children: [
              ChoiceChip(label: const Text('流水对帐'), selected: _view == _StmtView.flow, onSelected: (_) => _changeView(_StmtView.flow)),
              ChoiceChip(label: const Text('明细对帐'), selected: _view == _StmtView.detail, onSelected: (_) => _changeView(_StmtView.detail)),
              ChoiceChip(label: const Text('年度对帐'), selected: _view == _StmtView.annual, onSelected: (_) => _changeView(_StmtView.annual)),
            ]),
            const SizedBox(height: UtenSpacing.s12),
            _filterLabel(_side == 'AR' ? '客户' : '供应商'),
            if (_partyLoading)
              const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else
              DropdownButtonFormField<String?>(
                initialValue: _partyId,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, hintText: '选择往来单位'),
                items: [
                  for (final p in _partyList) DropdownMenuItem<String?>(value: p.id, child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) {
                  setState(() { _partyId = v; _page = 1; });
                  _load();
                },
              ),
            if (_view == _StmtView.annual) ...[
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('年度'),
              Row(children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () { setState(() => _year--); _page = 1; _load(); }),
                Text('$_year', style: theme.textTheme.titleMedium),
                IconButton(icon: const Icon(Icons.chevron_right), onPressed: () { setState(() => _year++); _page = 1; _load(); }),
              ]),
            ] else ...[
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
              UtenSearchBar(hint: '搜索单号', initialValue: _keyword, onChanged: (v) => _keyword = v),
              const SizedBox(height: UtenSpacing.s12),
              SizedBox(width: double.infinity, child: FilledButton.tonalIcon(
                onPressed: () { _page = 1; _load(); },
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('查询'),
              )),
            ],
          ],
        ),
      ),
    );
  }

  void _changeView(_StmtView v) {
    if (v == _view) return;
    setState(() { _view = v; _page = 1; _data = null; });
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
      emptyMessage: '暂无对帐数据',
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
