// 采购报表页（采购管理，purchase_report:view）：
//
// 镜像销售报表（sales_report_page）。3 张卡共用本页，由 [kind] 区分：
//   · 明细（detail）/ 汇总（summary）：卡内 ChoiceChip 切 4 类单据（申请/订货/收货/退货）
//   · 催料（expediting）：**独立**，无单据类型切换，直接查 /expediting
//
// 后端 GET /api/purchase/reports/{docType}/{detail|summary} 或 /api/purchase/reports/expediting
//   返回 ReportTableResponse {columns, rows, facets, page, totalPages, total}。
//   名称（供应商/仓库/货品/颜色/单位/类别/人员）服务端 JOIN 出；前端按 columns 动态建列。
//
// UI：左筛选侧栏（单据类型[非催料] + 日期范围 + 搜索 + 查询）+ 右 Excel 风格表格（标题行每列可筛 + 横滚 + 翻页）。
// 默认日期范围 = 上月今日..今日（defaultReportFrom()，收紧默认避免一进拉全量；firstDate 仍 2010 可手选更早）。
// 列筛选（供应商/仓库/是否审核/结帐方式…）走表头 autofilter（facets），左栏只放公共过滤。
//
// 筛选口径（单据类型/日期范围/facet/排序）按账号服务端持久化
// （report.purchase.detail|summary|expediting，ReportFilterPrefs）；关键字不持久化。
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
import '../../../shared/auth/permissions.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../config/purchase_report_config.dart';

class PurchaseReportTablePage extends ConsumerStatefulWidget {
  const PurchaseReportTablePage({required this.kind, super.key});
  final PurchaseReportKind kind;

  @override
  ConsumerState<PurchaseReportTablePage> createState() =>
      _PurchaseReportTablePageState();
}

class _PurchaseReportTablePageState
    extends ConsumerState<PurchaseReportTablePage> {
  late final PurchaseReportKind _kind = widget.kind;
  // 默认单据类型：订货（用户可在左栏切换；催料页不显示切换）。
  PurchaseReportDocType _docType = PurchaseReportDocType.order;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
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

  /// 本页（kind）对应的偏好 provider：催料独立 key，明细/汇总各一。
  NotifierProvider<ReportFilterPrefsNotifier, ReportFilterPrefs>
  get _prefsProvider {
    if (_kind.isStandalone) return purchaseExpeditingReportPrefsProvider;
    return _kind.isDetail
        ? purchaseDetailReportPrefsProvider
        : purchaseSummaryReportPrefsProvider;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyPrefs(ref.read(_prefsProvider));
      _load();
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认；催料页忽略 docType）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      if (!_kind.isStandalone && p.docType != null) {
        _docType = PurchaseReportDocType.values.firstWhere(
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

  /// 当前筛选口径快照（不含关键字/分页；催料页不带 docType）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _kind.isStandalone ? null : _docType.code,
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
      final path = _kind.isStandalone
          ? '/purchase/reports/${_kind.endpoint}'
          : '/purchase/reports/${_docType.code}/${_kind.endpoint}';
      final json = await api.get(path, query: query);
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

  /// 行点击跳源头单据编辑页：明细/汇总/催料每行都带隐藏的 __srcId（= 单据头 id），
  /// push 编辑页 → pop 回报表（保活筛选/分页状态）。汇总跨单据聚合的无 __srcId 行不响应。
  void _onRowTap(Map<String, dynamic> row) {
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    // 催料源于订货单；其余按当前单据类型 code + s（request→requests …）。
    final seg = _kind.isStandalone ? 'orders' : '${_docType.code}s';
    context.push(RoutePath.purchaseDocEdit(seg, srcId));
  }

  void _changeDocType(PurchaseReportDocType t) {
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

  /// 页面标题：催料=独立标题；明细/汇总="${单据}${短词}报表"（如"订货明细报表"）。
  String get _title => _kind.isStandalone
      ? _kind.label
      : '${_docType.label}${_kind.shortLabel}报表';

  /// 导出报表 key（与 GET 路径一致：催料=endpoint，其余=docType/endpoint）。
  String get _exportReport => _kind.isStandalone
      ? _kind.endpoint
      : '${_docType.code}/${_kind.endpoint}';

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
    final query = <String, dynamic>{..._exportQuery, 'page': 1, 'size': 2000};
    final path = _kind.isStandalone
        ? '/purchase/reports/${_kind.endpoint}'
        : '/purchase/reports/${_docType.code}/${_kind.endpoint}';
    final json = await api.get(path, query: query);
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
        title: _title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.purchase),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题 + 计数（内联 Icon+Text，勿换 UtenSectionHeader）
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
                        _title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text(
                          '共 ${_data!.total} ${_kind.isStandalone || _kind.isDetail ? '条明细' : '张单'}',
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
          // 催料是独立报表，无单据类型切换；明细/汇总才显示。
          if (!_kind.isStandalone) ...[
            _filterLabel('单据类型'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final t in PurchaseReportDocType.values)
                  ChoiceChip(
                    label: Text(t.label),
                    selected: t == _docType,
                    onSelected: (_) => _changeDocType(t),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
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
          title: '采购$_title',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}（最多前 2000 行）',
          loader: _printLoader,
          exportEndpoint: '/purchase/reports/export',
          exportPermission: Perm.purchaseReportExport,
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '采购$_title',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/purchase/reports/export',
          requiredPermission: Perm.purchaseReportExport,
          report: _exportReport,
          queryParams: _exportQuery,
          filename: '采购$_title',
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
      emptyMessage: (_kind.isStandalone || _kind.isDetail)
          ? '暂无明细数据'
          : '暂无汇总数据',
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
