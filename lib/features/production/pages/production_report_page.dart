// 生产报表页（生产管理 · production_report:view）：
//
// 2 张卡（明细/汇总）共用本页，由 [ProductionReportKind] 区分。生产计划只有一种单据
// （不像销售 4 类），左栏用"状态"ChoiceChip（全部/已审/草稿/红冲）代替销售的单据类型。
//
// 后端 GET /api/production/reports/plan/{detail|summary} 返回 ReportTableResponse：
//   { columns:[{key,label,type,width}], rows:[{...显示就绪}], facets:{colKey:[{value,label,count}]},
//     page, size, total, totalPages }
// 名称（货品/颜色/类别/制单员/审核员）服务端 JOIN 出；前端按 columns 动态建列。
//
// UI：左筛选侧栏（状态 + 日期范围 + 搜索 + 查询）+ 右 Excel 风格表格（标题行每列可筛 + 横滚 + 翻页）。
// 默认日期范围 = 上月今日..今日（defaultReportFrom()，收紧默认避免一进拉全量；firstDate 仍 2010 可手选更早）。
// 列筛选（是否审核/是否完成/车间/类别…）走表头 autofilter（facets），左栏只放公共过滤。
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
import '../config/production_report_config.dart';

class ProductionReportPage extends ConsumerStatefulWidget {
  const ProductionReportPage({required this.kind, super.key});
  final ProductionReportKind kind;

  @override
  ConsumerState<ProductionReportPage> createState() => _ProductionReportPageState();
}

class _ProductionReportPageState extends ConsumerState<ProductionReportPage> {
  late final ProductionReportKind _kind = widget.kind;
  // 状态过滤：null=全部 / 0=草稿 / 1=已审 / -1=红冲。
  int? _status;
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

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        if (_status != null) 'status': _status,
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        'page': _page,
        'size': _size,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get('/production/reports/plan/${_kind.endpoint}', query: query);
      if (!mounted) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      context.appError('加载报表失败');
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

  void _changeStatus(int? s) {
    if (s == _status) return;
    setState(() {
      _status = s;
      _page = 1;
      _filters.clear();
      _data = null;
    });
    _load();
  }

  /// 行点击跳源头单据详情页：明细/汇总每行都带隐藏的 __srcId（= 生产计划单头 id），
  /// push 详情页 → pop 回报表（保活筛选/分页状态）。无 __srcId 的行不响应。
  /// 本页 Kind 仅 plan 的 detail/summary（日报结构留位、未挂前端），统一跳生产计划详情页。
  void _onRowTap(Map<String, dynamic> row) {
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    context.push(RoutePath.productionPlanDetail(srcId));
  }

  /// 导出报表 key（与 GET 路径一致：plan/${endpoint}）。
  String get _exportReport => 'plan/${_kind.endpoint}';

  /// 导出查询参数（过滤+排序，与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        if (_status != null) 'status': _status,
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
        ...sortQueryParams(_sortKey, _sortAsc),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: _kind.label,
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.production)),
        actions: [
          UtenExportButton(
            endpoint: '/production/reports/export',
            report: _exportReport,
            queryParams: _exportQuery,
            filename: '生产${_kind.label}',
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
                      Icon(_kind.icon, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(_kind.label,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text('共 ${_data!.total} ${_kind.isDetail ? '条明细' : '张单'}',
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('单据状态'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final s in const [
                ['全部', null],
                ['已审', 1],
                ['草稿', 0],
                ['红冲', -1]
              ])
                ChoiceChip(
                  label: Text(s[0] as String),
                  selected: _status == s[1],
                  onSelected: (_) => _changeStatus(s[1] as int?),
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
                    firstDate: DateTime(2010),
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
                    firstDate: DateTime(2010),
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
            hint: '搜索单号 / 货品',
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
      emptyMessage: _kind.isDetail ? '暂无明细数据' : '暂无汇总数据',
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
