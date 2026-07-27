// 账户流水页 (S/Q/R)（finance_report:view）。
//
// 单独卡：报表类型 chip：
//   · 帐户进出流水 (S)   → /finance/reports/account/statement?accountId&dateFrom&dateTo&keyword（滚动余额）
//   · 银行存取明细 (Q)   → /finance/reports/bank/detail（M_Bank 老库 0 行，空表保结构）
//   · 银行存取汇总 (R)   → /finance/reports/bank/summary（空表）
// 右侧 MasterDataTableView。默认日期 2010 至今。账户列表来自 FinanceNameService。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
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
import '../providers/finance_name_provider.dart';

enum _FlowView { statement, bankDetail, bankSummary }

class _Col {
  const _Col(this.key, this.label, this.type, this.width);
  final String key;
  final String label;
  final String type;
  final double? width;
}

class _ReportData {
  const _ReportData(this.columns, this.rows, this.page, this.totalPages, this.total);
  final List<_Col> columns;
  final List<Map<String, dynamic>> rows;
  final int page;
  final int totalPages;
  final int total;
}

class FinanceAccountFlowPage extends ConsumerStatefulWidget {
  const FinanceAccountFlowPage({super.key});

  @override
  ConsumerState<FinanceAccountFlowPage> createState() => _FinanceAccountFlowPageState();
}

class _FinanceAccountFlowPageState extends ConsumerState<FinanceAccountFlowPage> {
  _FlowView _view = _FlowView.statement;
  String? _accountId;
  DateTime _from = DateTime(2010);
  DateTime _to = DateTime.now();
  String _keyword = '';
  int _page = 1;
  final int _size = 50;

  _ReportData? _data;
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
      };
      final json = await api.get(_endpoint, query: query);
      final cols = (json['columns'] as List? ?? const [])
          .map((c) => _Col(
                (c as Map)['key']?.toString() ?? '',
                c['label']?.toString() ?? '',
                c['type']?.toString() ?? 'text',
                (c['width'] as num?)?.toDouble(),
              ))
          .toList();
      final rows = (json['rows'] as List? ?? const []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _data = _ReportData(
          cols,
          rows,
          (json['page'] as num?)?.toInt() ?? _page,
          (json['totalPages'] as num?)?.toInt() ?? 1,
          (json['total'] as num?)?.toInt() ?? 0,
        );
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

  String? _cell(_Col col, Map<String, dynamic> row) {
    final v = row[col.key];
    if (v == null) return null;
    switch (col.type) {
      case 'money':
      case 'number':
        final n = v is num ? v : num.tryParse('$v');
        return n == null ? '$v' : n.toStringAsFixed(2);
      case 'date':
        final s = '$v';
        return s.length >= 10 ? s.substring(0, 10) : s;
      default:
        return '$v';
    }
  }

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
              value: (row) => _cell(c, row),
            ))
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      columns: columns,
      items: data.rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, __) {},
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
