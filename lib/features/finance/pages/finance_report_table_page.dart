// 钱流明细/汇总报表页（finance_report:view）—— 镜像 sales_report_page。
//
// 一张卡（[cardId] = detail|summary）内用 ChoiceChip 切多个报表变体（应收/应付/收款/付款/费用/收入…），
// 每个变体对应后端一个 endpoint（+ 固定参数如 direction=AR）。
//
// 后端 GET /api/finance/reports/{group}/{view} 返回 ReportTableResponse：
//   { columns, rows(显示就绪), facets, page, totalPages, total }。
// UI：左筛选侧栏（报表类型 chip + 日期范围 + 搜索 + 查询 + 已选筛选）+ 右 Excel 风格表格
//   （标题行每列可 autofilter + 横滚 + 翻页）。默认日期范围 = 上月今日..今日（defaultReportFrom()，收紧默认；firstDate 仍 2010 可手选更早）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_sort.dart';
import '../config/finance_report_config.dart';

class FinanceReportTablePage extends ConsumerStatefulWidget {
  const FinanceReportTablePage({required this.cardId, super.key});
  final String cardId;

  @override
  ConsumerState<FinanceReportTablePage> createState() => _FinanceReportTablePageState();
}

class _FinanceReportTablePageState extends ConsumerState<FinanceReportTablePage> {
  late final FinanceReportCard _card = financeReportCardById(widget.cardId);
  int _variantIndex = 0;
  DateTime _from = defaultReportFrom();
  DateTime _to = DateTime.now();
  String _keyword = '';
  int _page = 1;
  final int _size = 50;
  final Map<String, String> _filters = {};

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  ReportData? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  FinanceReportVariant get _variant => _card.variants[_variantIndex];

  /// 导出报表 key（剥离 /finance/reports/ 前缀，与 GET 路径一致：ar-ap/detail / receipt/summary …）。
  String get _exportReport => _variant.endpoint.replaceFirst('/finance/reports/', '');

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
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
        ...sortQueryParams(_sortKey, _sortAsc),
      };

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        ..._variant.fixedParams,
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        'page': _page,
        'size': _size,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(_variant.endpoint, query: query);
      if (!mounted) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      context.appError('加载报表失败：$e');
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

  void _onFilterChanged(String key, String? value) {
    setState(() {
      if (value == null || value.isEmpty) {
        _filters.remove(key);
      } else {
        _filters[key] = value;
      }
      _page = 1;
    });
    _load();
  }

  void _changeVariant(int i) {
    if (i == _variantIndex) return;
    setState(() {
      _variantIndex = i;
      _page = 1;
      _filters.clear();
      _data = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _variant.label;
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.finance)),
        actions: [
          UtenExportButton(
            endpoint: '/finance/reports/export',
            report: _exportReport,
            queryParams: _exportQuery,
            filename: '钱流${_variant.label}',
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
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4, right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.assessment_outlined, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(title,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text('共 ${_data!.total} 条',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
            _filterLabel('报表类型'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (int i = 0; i < _card.variants.length; i++)
                  ChoiceChip(
                    label: Text(_card.variants[i].label),
                    selected: i == _variantIndex,
                    onSelected: (_) => _changeVariant(i),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _filterLabel('日期范围'),
            Wrap(
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
                    if (p != null) setState(() => _from = p);
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
                    if (p != null) setState(() => _to = p);
                  },
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text('止 ${_fmt(_to)}'),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _filterLabel('搜索'),
            UtenSearchBar(
              hint: '搜索单号 / 名称',
              initialValue: _keyword,
              onChanged: (v) => _keyword = v,
            ),
            const SizedBox(height: UtenSpacing.s12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  _page = 1;
                  _load();
                },
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('查询'),
              ),
            ),
            if (_filters.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('已选筛选 (${_filters.length})'),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final e in _filters.entries)
                    Chip(
                      label: Text('${e.key}: ${e.value == kMasterFilterNullValue ? '(空)' : e.value}',
                          style: const TextStyle(fontSize: 11)),
                      onDeleted: () => _onFilterChanged(e.key, null),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTable() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final data = _data;
    if (data == null) {
      return const Center(child: Text('点击「查询」加载'));
    }
    final columns = data.columns
        .map((c) => MasterColumnDef<Map<String, dynamic>>(
              key: c.key,
              label: c.label,
              width: (c.width ?? 120).toDouble(),
              type: c.type,
              sortable: isSortableReportType(c.type),
              value: (row) => formatReportCell(c, row),
            ))
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      columns: columns,
      items: data.rows,
      facets: data.facets,
      nullCounts: const {},
      filters: {for (final e in _filters.entries) e.key: e.value},
      onFilterChanged: _onFilterChanged,
      sortColumn: _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      onRowTap: _onRowTap,
      isLoading: _loading,
      emptyMessage: '暂无数据',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (p) {
        _page = p;
        _load();
      },
    );
  }

  Widget _filterLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
