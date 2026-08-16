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
// 仅持久化单据类型 + 列排序（report.sales.detail|summary，ReportFilterPrefs）。
// 日期范围与 facet 筛选（客户/仓库…）**不持久化**：每次进页都用默认日期范围
// （上月今日..今日）+ 无筛选 = 「时间范围内的全部」——避免历史持久化的过时日期
// 范围或失效客户 UUID 把新数据滤成空白（曾发生：prefs 记了 5~7 月，8 月新单全被滤空）。
// 关键字亦不持久化。
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
  ///
  /// 仅回灌单据类型 + 列排序；**不回灌日期范围与 facet 筛选**——每次进页都用
  /// 默认日期范围（上月今日..今日）+ 空 filters，保证默认展示「时间范围内的全部」，
  /// 避免历史持久化的过时日期范围或失效客户 UUID 导致报表空白。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      if (p.docType != null) {
        _docType = SalesReportDocType.values.firstWhere(
          (t) => t.code == p.docType,
          orElse: () => _docType,
        );
      }
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（仅单据类型 + 排序；不含日期/facet/关键字/分页）。
  /// 日期范围与 facet 不持久化（见 [_applyPrefs] 说明），故不写入 from/to/filters。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _docType.code,
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

  /// 行点击：
  ///  - 明细表：每行带隐藏 __srcId（= 单据头 id），push 源头单据详情页 → pop 回报表（保活筛选/分页）。
  ///  - 汇总表：每行带隐藏 __clientId（= 客户 id，可空）；订货汇总另带
  ///    __currencyId，弹该客户、该币种的本期明细对话框（表格内可再点行跳单据）。
  /// docType.code（ORDER/SHIPMENT/RETURN/OTHER_SHIPMENT）→ 销售单据路由 seg：
  ///   ORDER→orders、SHIPMENT→shipments、RETURN→returns、OTHER_SHIPMENT→other-shipments（kebab）。
  ///   不能简单 `${code}s`：OTHER_SHIPMENT 期望 other-shipments（短横）非 OTHER_SHIPMENTs。
  void _onRowTap(Map<String, dynamic> row) {
    if (!_kind.isDetail) {
      _showClientDetail(row);
      return;
    }
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    context.push(RoutePath.salesDocDetail(_docSeg, srcId));
  }

  String get _docSeg => switch (_docType) {
    SalesReportDocType.order => 'orders',
    SalesReportDocType.shipment => 'shipments',
    SalesReportDocType.returnDoc => 'returns',
    SalesReportDocType.otherShipment => 'other-shipments',
  };

  /// 汇总表钻取：弹「客户 · 日期范围内全部明细」对话框。
  ///
  /// 订货汇总按「客户 + 币种」分组，故钻取必须把隐藏 [__currencyId] 一并传给
  /// detail 端点；缺失时宁可阻止钻取，也不能退化为同客户全部币种混合明细。
  void _showClientDetail(Map<String, dynamic> row) {
    final clientId = row['__clientId']?.toString();
    final rawCurrencyId = row['__currencyId']?.toString();
    final currencyId = (rawCurrencyId == null || rawCurrencyId.isEmpty)
        ? null
        : rawCurrencyId;
    if (_docType == SalesReportDocType.order && currencyId == null) {
      context.appError('订货汇总缺少币种信息，请刷新后重试');
      return;
    }
    final clientName = row['clientName']?.toString() ?? '(未指定客户)';
    showDialog<void>(
      context: context,
      builder: (_) => SalesClientDetailDialog(
        docType: _docType,
        docSeg: _docSeg,
        clientId: (clientId == null || clientId.isEmpty) ? null : clientId,
        currencyId: _docType == SalesReportDocType.order ? currencyId : null,
        clientName: clientName,
        dateFrom: _fmt(_from),
        dateTo: _fmt(_to),
      ),
    );
  }

  /// 「已选筛选」chip 文案：key 映射列中文名（不暴露 clientName 等内部键），
  /// 值映射 facet 桶展示名（客户 UUID → 客户名，不暴露内部 id）。
  String _filterChipText(String key, String value) {
    final data = _data;
    String label = key;
    if (data != null) {
      for (final c in data.columns) {
        if (c.key == key) {
          label = c.label;
          break;
        }
      }
    }
    if (value == kMasterFilterNullValue) return '$label: (空)';
    final buckets = data?.facets[key];
    if (buckets != null) {
      for (final b in buckets) {
        if (b.value == value) return '$label: ${b.display}';
      }
    }
    return '$label: $value';
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
                          '共 ${_data!.total} ${_kind.isDetail ? '条明细' : '个客户'}',
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
            hint: _kind.isDetail ? '搜索单号 / 货品 / 客户' : '搜索客户 / 单号',
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
                      _filterChipText(e.key, e.value),
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
      columns: columns,
      items: data.rows,
      toolbarActions: [
        UtenPrintPreviewButton(
          title: '销售${_docType.label}${_kind.shortLabel}报表',
          subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}（最多前 2000 行）',
          loader: _printLoader,
          exportEndpoint: '/sales/reports/export',
          exportPermission: Perm.salesReportExport,
          exportReport: _exportReport,
          exportQuery: _exportQuery,
          exportFilename: '销售${_docType.label}${_kind.shortLabel}报表',
          type: UtenButtonType.primary,
          size: UtenButtonSize.large,
        ),
        UtenExportButton(
          endpoint: '/sales/reports/export',
          requiredPermission: Perm.salesReportExport,
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

/// 汇总表钻取对话框：某客户在日期范围内的全部明细（表格）。
///
/// 数据复用 detail 端点（clientId 过滤；空客户走 f.clientName=__null__ 档），
/// 列集与该单据类型明细报表一致；点行可继续跳源头单据详情页。
class SalesClientDetailDialog extends ConsumerStatefulWidget {
  const SalesClientDetailDialog({
    required this.docType,
    required this.docSeg,
    required this.clientId,
    this.currencyId,
    required this.clientName,
    required this.dateFrom,
    required this.dateTo,
    super.key,
  });

  final SalesReportDocType docType;

  /// 单据路由 seg（orders/shipments/returns/other-shipments），行点击跳详情用。
  final String docSeg;

  /// 客户 id；null = 未指定客户（按 facet 空值档过滤）。
  final String? clientId;

  /// 订货汇总钻取的币种 id；其它销售单据不按币种分组，保持 null。
  final String? currencyId;
  final String clientName;
  final String dateFrom; // yyyy-MM-dd
  final String dateTo;

  @override
  ConsumerState<SalesClientDetailDialog> createState() =>
      _SalesClientDetailDialogState();
}

class _SalesClientDetailDialogState
    extends ConsumerState<SalesClientDetailDialog> {
  ReportData? _data;
  bool _loading = false;
  int _page = 1;
  final int _size = 50;
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final json = await api.get(
        '/sales/reports/${widget.docType.code}/detail',
        query: <String, dynamic>{
          'dateFrom': widget.dateFrom,
          'dateTo': widget.dateTo,
          if (widget.clientId != null)
            'clientId': widget.clientId
          else
            'f.clientName': kMasterFilterNullValue, // 空客户档
          if (widget.docType == SalesReportDocType.order &&
              widget.currencyId != null)
            'currencyId': widget.currencyId,
          'page': _page,
          'size': _size,
          ...sortQueryParams(_sortKey, _sortAsc),
        },
      );
      if (!mounted) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      context.appError('加载客户明细失败');
      setState(() => _loading = false);
    }
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
      _page = 1;
    });
    _load();
  }

  void _onRowTap(Map<String, dynamic> row) {
    final srcId = row['__srcId']?.toString();
    if (srcId == null || srcId.isEmpty) return;
    context.push(RoutePath.salesDocDetail(widget.docSeg, srcId));
  }

  /// 预览打印数据：按当前客户+日期范围+排序拉全量（上限 2000 行），列/格式化与对话框表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final headers = <String>[];
    final rows = <List<String>>[];
    var page = 1;
    while (true) {
      final json = await api.get(
        '/sales/reports/${widget.docType.code}/detail',
        query: <String, dynamic>{
          'dateFrom': widget.dateFrom,
          'dateTo': widget.dateTo,
          if (widget.clientId != null)
            'clientId': widget.clientId
          else
            'f.clientName': kMasterFilterNullValue,
          if (widget.docType == SalesReportDocType.order &&
              widget.currencyId != null)
            'currencyId': widget.currencyId,
          'page': page,
          'size': 500,
          ...sortQueryParams(_sortKey, _sortAsc),
        },
      );
      final data = parseReportResponse(json, page);
      if (headers.isEmpty) {
        headers.addAll([for (final c in data.columns) c.label]);
      }
      for (final r in data.rows) {
        rows.add([for (final c in data.columns) formatReportCell(c, r) ?? '']);
      }
      if (rows.length >= data.total || data.rows.length < 500) break;
      if (rows.length >= 2000) break;
      page++;
    }
    return UtenPrintTable(headers: headers, rows: rows);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final data = _data;
    final columns = (data?.columns ?? const [])
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
    return Dialog(
      insetPadding: const EdgeInsets.all(UtenSpacing.s16),
      child: SizedBox(
        width: size.width > 1240 ? 1200 : size.width * 0.95,
        height: size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.person_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '${widget.clientName} · ${widget.docType.label}明细'
                      '（${widget.dateFrom} ~ ${widget.dateTo}'
                      '${data != null ? '，共 ${data.total} 条' : ''}）',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  UtenPrintPreviewButton(
                    title: '${widget.clientName} · ${widget.docType.label}明细',
                    subtitle:
                        '${widget.dateFrom} ~ ${widget.dateTo}（最多前 2000 行）',
                    loader: _printLoader,
                    type: UtenButtonType.primary,
                    size: UtenButtonSize.large,
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Expanded(
                child: data == null && _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : data == null
                    ? const Center(child: Text('暂无数据'))
                    : MasterDataTableView<Map<String, dynamic>>(
                        columns: columns,
                        items: data.rows,
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        sortColumn: _sortKey,
                        sortAscending: _sortAsc,
                        onSortChange: _onSortChange,
                        onRowTap: _onRowTap,
                        isLoading: _loading,
                        emptyMessage: '该客户在此日期范围内暂无明细',
                        currentPage: data.page,
                        totalPages: data.totalPages,
                        onPageChange: (p) {
                          _page = p;
                          _load();
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
