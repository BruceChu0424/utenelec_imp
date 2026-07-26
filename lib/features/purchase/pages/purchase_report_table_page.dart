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
// 默认日期 2018 至今（老库采购数据跨多年，默认"今年"会滤掉历史）。
// 列筛选（供应商/仓库/是否审核/结帐方式…）走表头 autofilter（facets），左栏只放公共过滤。
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
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/purchase_report_config.dart';

class _Col {
  const _Col(this.key, this.label, this.type, this.width);
  final String key;
  final String label;
  final String type;
  final double? width;
}

class _ReportData {
  const _ReportData(this.columns, this.rows, this.facets, this.page, this.totalPages, this.total);
  final List<_Col> columns;
  final List<Map<String, dynamic>> rows;
  final Map<String, List<MasterFacetBucket>> facets;
  final int page;
  final int totalPages;
  final int total;
}

class PurchaseReportTablePage extends ConsumerStatefulWidget {
  const PurchaseReportTablePage({required this.kind, super.key});
  final PurchaseReportKind kind;

  @override
  ConsumerState<PurchaseReportTablePage> createState() => _PurchaseReportTablePageState();
}

class _PurchaseReportTablePageState extends ConsumerState<PurchaseReportTablePage> {
  late final PurchaseReportKind _kind = widget.kind;
  // 默认单据类型：订货（用户可在左栏切换；催料页不显示切换）。
  PurchaseReportDocType _docType = PurchaseReportDocType.order;
  DateTime _from = DateTime(2018);
  DateTime _to = DateTime.now();
  String _keyword = '';
  int _page = 1;
  final int _size = 50;
  final Map<String, String> _filters = {};

  _ReportData? _data;
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
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        'page': _page,
        'size': _size,
        for (final e in _filters.entries) 'f.${e.key}': e.value,
      };
      final path = _kind.isStandalone
          ? '/purchase/reports/${_kind.endpoint}'
          : '/purchase/reports/${_docType.code}/${_kind.endpoint}';
      final json = await api.get(path, query: query);
      final cols = (json['columns'] as List? ?? const [])
          .map((c) => _Col(
                (c as Map)['key']?.toString() ?? '',
                c['label']?.toString() ?? '',
                c['type']?.toString() ?? 'text',
                (c['width'] as num?)?.toDouble(),
              ))
          .toList();
      final rows = (json['rows'] as List? ?? const []).cast<Map<String, dynamic>>();
      final facets = <String, List<MasterFacetBucket>>{};
      final fjson = json['facets'];
      if (fjson is Map) {
        fjson.forEach((k, v) {
          if (v is List) {
            facets[k.toString()] = v
                .map((b) => MasterFacetBucket.fromJson(b as Map<String, dynamic>))
                .toList();
          }
        });
      }
      if (!mounted) return;
      setState(() {
        _data = _ReportData(
          cols,
          rows,
          facets,
          (json['page'] as num?)?.toInt() ?? _page,
          (json['totalPages'] as num?)?.toInt() ?? 1,
          (json['total'] as num?)?.toInt() ?? 0,
        );
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

  String? _cell(_Col col, Map<String, dynamic> row) {
    final v = row[col.key];
    if (v == null) return null;
    switch (col.type) {
      case 'money':
      case 'number':
        final n = v is num ? v : num.tryParse('$v');
        return n == null ? '$v' : n.toStringAsFixed(2);
      case 'bool':
        final b = v is bool ? v : '$v' == 'true';
        return b ? '是' : '否';
      case 'date':
        final s = '$v';
        return s.length >= 10 ? s.substring(0, 10) : s;
      default:
        return '$v';
    }
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

  void _changeDocType(PurchaseReportDocType t) {
    if (t == _docType) return;
    setState(() {
      _docType = t;
      _page = 1;
      _filters.clear();
      _data = null;
    });
    _load();
  }

  /// 页面标题：催料=独立标题；明细/汇总="${单据}${短词}报表"（如"订货明细报表"）。
  String get _title => _kind.isStandalone
      ? _kind.label
      : '${_docType.label}${_kind.shortLabel}报表';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: _title,
        leading: UtenBackButton(onPressed: () => backTo(context, defaultPath: RouteName.purchase)),
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
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4, right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(_kind.icon, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(_title,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text('共 ${_data!.total} ${_kind.isStandalone || _kind.isDetail ? '条明细' : '张单'}',
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
              value: (row) => _cell(c, row),
            ))
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      columns: columns,
      items: data.rows,
      facets: data.facets,
      nullCounts: const {},
      filters: {for (final e in _filters.entries) e.key: e.value},
      onFilterChanged: _onFilterChanged,
      onRowTap: (_) {},
      isLoading: _loading,
      emptyMessage: (_kind.isStandalone || _kind.isDetail) ? '暂无明细数据' : '暂无汇总数据',
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
