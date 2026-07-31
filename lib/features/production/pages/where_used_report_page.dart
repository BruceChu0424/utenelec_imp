// 物料反查产成品报表（生产管理 · production_where_used:view · 只读）。
//
// 工程部需求：输入一个原材料（如 A 螺丝），查出它被用在了哪些产成品上（BOM where-used）。
//
// 数据源 production_plan_costs（源 F_PlanCostItem，136 万行 BOM 展开快照）。后端按 master_goods_id 汇总：
//   GET /api/production/reports/where-used?materialGoodsId=&dateFrom=&dateTo=&page=&size=&sort=&order=
//   返回 ReportTableResponse { columns, rows, facets(空), page, size, total, totalPages }
// 列：产成品编号 / 名称 / 规格 / 分类 / 单支用量 / 涉及计划数 / 历史总用量 / 最近使用。
//
// ⚠ 只读历史数据：仅含曾经排产过的自制产成品（未投产新品 / 委外路径不覆盖）。
//
// UI：左栏（材料选择器[必选] + 日期范围 + 查询）+ 右 Excel 风格表格（列排序 + 翻页）。
// 默认日期 = 上月今日..今日（defaultReportFrom()）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_sort.dart';

class WhereUsedReportPage extends ConsumerStatefulWidget {
  const WhereUsedReportPage({super.key});

  @override
  ConsumerState<WhereUsedReportPage> createState() =>
      _WhereUsedReportPageState();
}

class _WhereUsedReportPageState extends ConsumerState<WhereUsedReportPage> {
  // 必选：被反查的材料。
  GoodsListItem? _material;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  int _page = 1;
  final int _size = 50;

  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认"涉及计划数"降序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  ReportData? _data;
  bool _loading = false;

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickMaterial() async {
    final g = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.material,
    );
    if (g != null) {
      setState(() {
        _material = g;
        _page = 1;
      });
      _load();
    }
  }

  Future<void> _load() async {
    if (_material == null) {
      context.appError('请先选择要反查的材料');
      return;
    }
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        'materialGoodsId': _material!.id,
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        'page': _page,
        'size': _size,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(
        '/production/reports/where-used',
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

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
      _page = 1;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '物料反查产成品',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _material == null ? null : () => _load(),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 只读告示
                Container(
                  margin: const EdgeInsets.only(
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                    bottom: UtenSpacing.s8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s12,
                    vertical: UtenSpacing.s8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 18,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Text(
                          '只读历史数据 · 仅含曾经排产过的自制产成品（未含委外与未投产新品）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 标题行
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.find_in_page_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '物料反查产成品',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      if (_data != null)
                        Text(
                          '共 ${_data!.total} 个产成品',
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
          _filterLabel('要反查的材料（必选）'),
          SizedBox(
            width: double.infinity,
            child: UtenButton(
              type: UtenButtonType.tonal,
              icon: _material == null
                  ? Icons.widgets_outlined
                  : Icons.swap_horiz_rounded,
              onPressed: _pickMaterial,
              child: Text(_material == null ? '选择材料' : '更换材料'),
            ),
          ),
          // 选中材料名独立展示（按钮文案保持简短防溢出；长名在此换行）
          if (_material != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s8,
                vertical: UtenSpacing.s4,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _material!.name ?? '（无名称）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    softWrap: true,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if ((_material!.code ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '编号: ${_material!.code}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
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
        ],
      ),
    );
  }

  Widget _buildTable() {
    if (_material == null) {
      return const Center(child: Text('请在左侧选择要反查的材料'));
    }
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
      facets: data.facets,
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      sortColumn: _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      // BOM 成本展开页已下线，行不再下钻（表格组件必填回调，置空操作）。
      onRowTap: (_) {},
      isLoading: _loading,
      emptyMessage: '该材料未用在任何产成品上（历史排产范围内）',
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
