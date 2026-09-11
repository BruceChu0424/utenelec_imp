// 仓库报表页（仓库管理，stock_report:view）：
//
// 2 张卡（明细/汇总）共用本页，由 [kind] 区分；卡内用 UtenFilterToolbar 分段切 7 类单据
// （调拨/其它入库/生产领料/生产退料/产成品进仓/产成品出仓/盘点）。**无其它出库/生产损耗**。
//
// 后端 GET /api/stock/reports/{docType}/{kind} 返回 ReportTableResponse：
//   { columns:[{key,label,type,width}], rows:[{...显示就绪}], facets:{colKey:[{value,label,count}]},
//     page, size, total, totalPages }
// 名称（仓库/货品/颜色/单位/人员）服务端 JOIN 出；前端按 columns 动态建列。
//
// UI：顶部筛选区（单据类型分段与搜索同处一条 UtenFilterToolbar + 日期范围）
// + 下方 Excel 风格表格（标题行每列可筛 + 横滚 + 翻页）。
// 默认日期范围 = 上月今日..今日（defaultReportFrom()，收紧默认避免一进拉全量；firstDate 仍 2010 可手选更早）。
// 列筛选（仓库/是否审核…）走表头 autofilter（facets），筛选区只放公共过滤。
//
// 筛选口径（单据类型/日期范围/facet/排序）按账号服务端持久化（report.warehouse.detail|summary，
// ReportFilterPrefs，见 lib/features/report/shared/report_filter_prefs.dart）：
// 进页面带上次口径；服务端同步晚到时仅在用户未动手（_dirty=false）才应用；关键字不持久化。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../../report/shared/report_total.dart';
import '../config/warehouse_report_config.dart';

class WarehouseReportTablePage extends ConsumerStatefulWidget {
  const WarehouseReportTablePage({required this.kind, super.key});
  final WarehouseReportKind kind;

  @override
  ConsumerState<WarehouseReportTablePage> createState() =>
      _WarehouseReportTablePageState();
}

class _WarehouseReportTablePageState
    extends ConsumerState<WarehouseReportTablePage> {
  late final WarehouseReportKind _kind = widget.kind;
  // 默认单据类型：调拨（用户可在左栏切换）。
  WarehouseReportDocType _docType = WarehouseReportDocType.transfer;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _keyword = '';
  String? _departmentId; // 领料车间筛选（仅 DRAW）
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
      ? warehouseDetailReportPrefsProvider
      : warehouseSummaryReportPrefsProvider;

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
        _docType = WarehouseReportDocType.values.firstWhere(
          (t) => t.code == p.docType,
          orElse: () => _docType,
        );
      }
      // 日期范围与 facet 筛选不回灌：进页始终用默认日期范围（上月今日..今日）
      // + 空 filters = 「时间范围内的全部」，避免历史持久化的过时日期范围或失效
      // 筛选值把新数据滤成空白（销售报表已踩此坑，见 sales_report_page.dart）。
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _docType.code,
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
        if (_docType == WarehouseReportDocType.draw && _departmentId != null)
          'departmentId': _departmentId,
        'page': _page,
        'size': _size,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(
        '/stock/reports/${_docType.code}/${_kind.endpoint}',
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

  /// 行点击跳源头单据详情页：明细/汇总每行都带隐藏的 __srcId（= stock_documents.id），
  /// push 详情页 → pop 回报表（保活筛选/分页状态）。code 即大写 docType（与路由段一致）。
  void _onRowTap(Map<String, dynamic> row) {
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    context.push(RoutePath.stockDocDetail(_docType.code, srcId));
  }

  void _changeDocType(WarehouseReportDocType t) {
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

  /// 导出报表 key（与 GET 路径一致：docType/kind，如 'TRANSFER/detail'）。
  String get _exportReport => '${_docType.code}/${_kind.endpoint}';

  /// 导出查询参数（过滤+排序，与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    if (_docType == WarehouseReportDocType.draw && _departmentId != null)
      'departmentId': _departmentId,
    for (final e in _filters.entries) 'f.${e.key}': e.value,
    ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final json = await api.get(
      '/stock/reports/${_docType.code}/${_kind.endpoint}',
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
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            // 「顶部折叠 + 表格吸顶内滚」：标题行随上滑收起腾出空间，
            // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
            child: UtenCollapsingHeaderScrollView(
              collapsingHeader: Padding(
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
              body: UtenListTwoPane(
                filterPane: _buildFilterPane(theme),
                tablePane: _buildTable(),
              ),
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
          // 全平台统一筛选工具条：7 类单据分段 + 同一行右侧的搜索框
          //（2026-09-11 用户要求搜索不再单独占一行，宽度由 searchWidth 封顶；
          // 窄屏工具条自己换行）。
          UtenFilterToolbar<WarehouseReportDocType>(
            segments: [
              for (final t in WarehouseReportDocType.values)
                UtenFilterSegment(value: t, label: t.label),
            ],
            selected: {_docType},
            onSelectionChanged: _changeDocType,
            searchHint: '搜索单号 / 货品',
            initialSearchValue: _keyword,
            // 防抖到点即查；回车立刻查（不等防抖）。
            onSearchChanged: (v) {
              _keyword = v;
              _persistAndReload();
            },
            onSearchSubmitted: (v) {
              _keyword = v;
              _persistAndReload();
            },
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
                    _persistAndReload();
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
                    _persistAndReload();
                  }
                },
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text('止 ${_fmt(_to)}'),
              ),
            ],
          ),
          // DRAW：领料车间筛选（各车间领料单独统计）
          // 间距放在各选填区块的开头：搜索并入工具条后，尾随间距会在区块缺席时
          // 变成悬空留白。
          if (_docType == WarehouseReportDocType.draw) ...[
            const SizedBox(height: UtenSpacing.s12),
            _filterLabel('领料车间'),
            UtenDropdownField(
              value: _departmentId,
              hintText: '全部车间',
              items: [
                for (final e
                    in ref
                        .watch(masterNameServiceProvider)
                        .departmentEntries
                        .entries)
                  UtenDropdownItem(value: e.key, label: e.value),
              ],
              onChanged: (v) {
                setState(() => _departmentId = v);
                _persistAndReload();
              },
            ),
          ],
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
                      style: Theme.of(context).textTheme.labelSmall,
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
      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
      primary: true,
      columns: columns,
      items: data.rows,
      toolbarActions: [
        UtenPrintPreviewButton(
          title: '仓库${_docType.label}${_kind.shortLabel}报表',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}(最多前 2000 行)',
          loader: _printLoader,
          exportEndpoint: '/stock/reports/export',
          exportPermission: Perm.stockReportExport,
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '仓库${_docType.label}${_kind.shortLabel}报表',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/stock/reports/export',
          requiredPermission: Perm.stockReportExport,
          report: _exportReport,
          queryParams: _exportQuery,
          filename: '仓库${_docType.label}${_kind.shortLabel}报表',
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
      // 服务端分页表格：合计由后端在整个结果集上算（reportTotalsBar），
      // 不是对当前这一页求和；后端未声明合计列时返回 null，整条不渲染。
      summaryBar: reportTotalsBar(data.totals),
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
