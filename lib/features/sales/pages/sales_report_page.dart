// 销售报表页（销售管理，sales_report:view）：
//
// 2 张卡（明细/汇总）共用本页，由 [kind] 区分；卡内用 ChoiceChip 切 4 类单据（订货/出货/退货/其它出货），
// **无报价**（报价无报表）。
//
// 后端 GET /api/sales/reports/{docType}/{kind} 返回 ReportTableResponse：
//   { columns:[{key,label,type,width}], rows:[{...显示就绪}], facets:{colKey:[{value,label,count}]},
//     page, size, total, totalPages }
// 名称（客户/仓库/货品/颜色/类别/人员/总监）服务端 JOIN 出；前端按 columns 动态建列。
//
// UI：左筛选侧栏（单据类型 + 日期范围 + 搜索 + 查询）+ 右 Excel 风格表格（标题行每列可筛 + 横滚 + 翻页）。
// 默认日期范围 = 上月今日..今日（defaultReportFrom()，收紧默认避免一进拉十几年全量；firstDate 仍 2010 可手选更早）。
// 列筛选（客户/仓库/是否审核/结帐方式…）走表头 autofilter（facets），左栏只放公共过滤。
//
// 筛选口径（单据类型/日期范围/facet/排序）按账号服务端持久化
// （report.sales.detail|summary，ReportFilterPrefs）；关键字不持久化。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
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
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../config/sales_doc_config.dart';
import '../config/sales_report_config.dart';

class SalesReportPage extends ConsumerStatefulWidget {
  const SalesReportPage({required this.kind, super.key});
  final SalesReportKind kind;

  @override
  ConsumerState<SalesReportPage> createState() => _SalesReportPageState();
}

class _SalesReportPageState extends ConsumerState<SalesReportPage> {
  late final SalesReportKind _kind = widget.kind;
  // 默认单据类型：明细=订货、汇总=订货（用户可在左栏切换）。
  SalesReportDocType _docType = SalesReportDocType.order;
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

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  /// 本页（kind）对应的偏好 provider。
  NotifierProvider<ReportFilterPrefsNotifier, ReportFilterPrefs>
  get _prefsProvider => _kind.isDetail
      ? salesDetailReportPrefsProvider
      : salesSummaryReportPrefsProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyPrefs(ref.read(_prefsProvider));
      _load();
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      if (p.docType != null) {
        _docType = SalesReportDocType.values.firstWhere(
          (t) => t.code == p.docType,
          orElse: () => _docType,
        );
      }
      if (p.from != null) _from = DateTime.tryParse(p.from!) ?? _from;
      if (p.to != null) _to = DateTime.tryParse(p.to!) ?? _to;
      _filters
        ..clear()
        ..addAll(p.filters);
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _docType.code,
    from: _fmt(_from),
    to: _fmt(_to),
    filters: Map.of(_filters),
    sortKey: _sortKey,
    sortAsc: _sortAsc,
  );

  /// 任何筛选变更后调用：标记已动手 + 防抖持久化到服务端。
  void _persistPrefs() {
    _dirty = true;
    ref.read(_prefsProvider.notifier).update(_snapshot());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        'page': _page,
        'size': _size,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(
        '/sales/reports/${_docType.code}/${_kind.endpoint}',
        query: query,
      );
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
      _page = 1;
    });
    _persistPrefs();
    _load();
  }

  /// 行点击跳源头单据详情页：明细/汇总每行都带隐藏的 __srcId（= 单据头 id），
  /// push 详情页 → pop 回报表（保活筛选/分页状态）。
  /// docType.code（ORDER/SHIPMENT/RETURN/OTHER_SHIPMENT）→ 销售单据路由 seg：
  ///   ORDER→orders、SHIPMENT→shipments、RETURN→returns、OTHER_SHIPMENT→other-shipments（kebab）。
  ///   不能简单 `${code}s`：OTHER_SHIPMENT 期望 other-shipments（短横）非 OTHER_SHIPMENTs。
  void _onRowTap(Map<String, dynamic> row) {
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    final seg = switch (_docType) {
      SalesReportDocType.order => 'orders',
      SalesReportDocType.shipment => 'shipments',
      SalesReportDocType.returnDoc => 'returns',
      SalesReportDocType.otherShipment => 'other-shipments',
    };
    context.push(RoutePath.salesDocDetail(seg, srcId));
  }

  void _changeDocType(SalesReportDocType t) {
    if (t == _docType) return;
    setState(() {
      _docType = t;
      _page = 1;
      _filters.clear();
      _data = null;
    });
    _persistPrefs();
    _load();
  }

  /// 导出报表 key（与 GET 路径一致：{docType}/{endpoint}，docType 大写）。
  String get _exportReport => '${_docType.code}/${_kind.endpoint}';

  /// 导出查询参数（过滤+排序，与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    for (final e in _filters.entries) 'f.${e.key}': e.value,
    ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final json = await api.get(
      '/sales/reports/${_docType.code}/${_kind.endpoint}',
      query: <String, dynamic>{..._exportQuery, 'page': 1, 'size': 2000},
    );
    final data = parseReportResponse(json, 1);
    return UtenPrintTable(
      headers: [for (final c in data.columns) c.label],
      rows: [
        for (final r in data.rows)
          [for (final c in data.columns) formatReportCell(c, r) ?? ''],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docLabel = _docType.label;
    // 服务端偏好同步晚到：仅在用户未动手时回灌并重查（避免覆盖在输状态）。
    ref.listen(_prefsProvider, (prev, next) {
      if (!_dirty && prev != next && !next.isEmpty && mounted) {
        _applyPrefs(next);
        _page = 1;
        _load();
      }
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: '$docLabel${_kind.shortLabel}报表',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: SalesRoutePath.hub),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _kind.icon,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '$docLabel${_kind.shortLabel}报表',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text(
                          '共 ${_data!.total} ${_kind.isDetail ? '条明细' : '张单'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
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
          _filterLabel('单据类型'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final t in SalesReportDocType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: t == _docType,
                  onSelected: (_) => _changeDocType(t),
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
                  if (p != null) {
                    setState(() => _from = p);
                    _persistPrefs();
                  }
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
                  if (p != null) {
                    setState(() => _to = p);
                    _persistPrefs();
                  }
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
                    label: Text(
                      '${e.key}: ${e.value == kMasterFilterNullValue ? '(空)' : e.value}',
                      style: const TextStyle(fontSize: 11),
                    ),
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
        .map(
          (c) => MasterColumnDef<Map<String, dynamic>>(
            key: c.key,
            label: c.label,
            width: (c.width ?? 120).toDouble(),
            type: c.type,
            sortable: isSortableReportType(c.type),
            value: (row) => formatReportCell(c, row),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      columns: columns,
      items: data.rows,
      toolbarActions: [
        UtenPrintPreviewButton(
          title: '销售${_docType.label}${_kind.shortLabel}报表',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}（最多前 2000 行）',
          loader: _printLoader,
          exportEndpoint: '/sales/reports/export',
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '销售${_docType.label}${_kind.shortLabel}报表',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/sales/reports/export',
          report: _exportReport,
          queryParams: _exportQuery,
          filename: '销售${_docType.label}${_kind.shortLabel}报表',
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
