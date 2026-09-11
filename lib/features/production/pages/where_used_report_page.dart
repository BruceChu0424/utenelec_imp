// 物料反查产成品（production_where_used:view，只读 CQRS 报表）。
//
// 当前 BOM、旧生产快照、新生产履约需求和委外历史证据由后端分别聚合；
// 日期只过滤历史证据，当前 BOM 始终表示查询时现状。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_sort.dart';
import '../widgets/where_used_material_picker.dart';
import '../widgets/where_used_product_detail_dialog.dart';

enum _WhereUsedSource {
  all('all', '全部已知关系', '当前 BOM 与所有历史证据'),
  current('current', '当前 BOM', '只看查询时仍有效的理论关系'),
  history('history', '全部历史', '新旧生产与委外历史证据'),
  production('production', '生产关系', '新生产需求与旧生产快照'),
  subcontract('subcontract', '委外关系', '委外需求、成本快照与发料痕迹');

  const _WhereUsedSource(this.apiValue, this.label, this.description);

  final String apiValue;
  final String label;
  final String description;
}

class _WhereUsedQuerySnapshot {
  const _WhereUsedQuerySnapshot({
    required this.material,
    required this.source,
    required this.from,
    required this.to,
    required this.page,
    required this.sortKey,
    required this.sortAscending,
  });

  final GoodsListItem material;
  final _WhereUsedSource source;
  final DateTime? from;
  final DateTime? to;
  final int page;
  final String? sortKey;
  final bool sortAscending;
}

class WhereUsedReportPage extends ConsumerStatefulWidget {
  const WhereUsedReportPage({super.key});

  @override
  ConsumerState<WhereUsedReportPage> createState() =>
      _WhereUsedReportPageState();
}

class _WhereUsedReportPageState extends ConsumerState<WhereUsedReportPage> {
  GoodsListItem? _material;
  _WhereUsedSource _source = _WhereUsedSource.all;
  bool _limitHistoryDates = false;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  int _page = 1;
  static const _size = 50;

  String? _sortKey;
  bool _sortAscending = true;
  ReportData? _data;
  _WhereUsedQuerySnapshot? _loadedQuery;
  int _loadGeneration = 0;
  bool _loading = false;
  bool _openingDetail = false;
  String? _loadError;

  String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String _historyRangeLabel(_WhereUsedQuerySnapshot query) {
    if (query.from == null && query.to == null) return '全部历史';
    if (query.from == null) return '截至 ${_formatDate(query.to!)}';
    if (query.to == null) return '${_formatDate(query.from!)} 起';
    return '${_formatDate(query.from!)} 至 ${_formatDate(query.to!)}';
  }

  void _invalidateLoadedResults() {
    _loadGeneration += 1;
    _data = null;
    _loadedQuery = null;
    _loadError = null;
    _loading = false;
  }

  Future<void> _pickMaterial() async {
    final selected = await showWhereUsedMaterialPicker(context, ref);
    if (selected == null || !mounted) return;
    setState(() {
      _invalidateLoadedResults();
      _material = selected;
      _page = 1;
      _sortKey = null;
      _sortAscending = true;
    });
    await _load();
  }

  Future<void> _load() async {
    final material = _material;
    if (material == null) {
      context.appError('请先选择要反查的物料');
      return;
    }
    if (_limitHistoryDates && _from.isAfter(_to)) {
      context.appError('起始日期不能晚于结束日期');
      return;
    }

    final snapshot = _WhereUsedQuerySnapshot(
      material: material,
      source: _source,
      from: _limitHistoryDates ? _from : null,
      to: _limitHistoryDates ? _to : null,
      page: _page,
      sortKey: _sortKey,
      sortAscending: _sortAscending,
    );
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final query = <String, dynamic>{
        'materialGoodsId': snapshot.material.id,
        'source': snapshot.source.apiValue,
        if (snapshot.from != null) 'dateFrom': _formatDate(snapshot.from!),
        if (snapshot.to != null) 'dateTo': _formatDate(snapshot.to!),
        'page': snapshot.page,
        'size': _size,
        ...sortQueryParams(snapshot.sortKey, snapshot.sortAscending),
      };
      final json = await ref
          .read(apiClientProvider)
          .get('/production/reports/where-used', query: query);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _data = parseReportResponse(json, snapshot.page);
        _loadedQuery = snapshot;
        _page = snapshot.page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = error is ApiException ? error.message : '反查加载失败，请稍后重试';
        _loading = false;
        final loaded = _loadedQuery;
        if (_data != null && loaded != null) {
          _page = loaded.page;
          _sortKey = loaded.sortKey;
          _sortAscending = loaded.sortAscending;
        }
      });
    }
  }

  Future<void> _openProductDetail(Map<String, dynamic> row) async {
    if (_openingDetail) return;
    final loadedQuery = _loadedQuery;
    if (loadedQuery == null) {
      context.appInfo('请先按当前条件查询后再打开详情');
      return;
    }

    _openingDetail = true;
    try {
      final permissions = ref.read(currentPermissionsProvider);
      final result = await showWhereUsedProductDetailDialog(
        context: context,
        row: row,
        material: loadedQuery.material,
        historyRangeLabel: _historyRangeLabel(loadedQuery),
        canViewGoods: permissions.contains(Perm.goodsView),
        canViewStock: permissions.contains(Perm.stockView),
      );
      if (!mounted || result == null) return;

      if (result.link == WhereUsedProductLink.stockMovements) {
        context.push(_stockMovementPath(result.productId));
        return;
      }
      final detail = result.detail;
      if (detail == null) return;
      // 货品详情整页（tab=1 组装信息直达 BOM）；「出入库流水」按钮
      // 由详情页按 stock:view 权限自行决定是否显示。
      await context.push(
        RoutePath.basicinfoGoodsDetail(
          detail.id,
          tab: result.link == WhereUsedProductLink.bom ? 1 : 0,
        ),
      );
    } finally {
      _openingDetail = false;
    }
  }

  String _stockMovementPath(String goodsId) => Uri(
    path: RouteName.stockMovement,
    queryParameters: {'goodsId': goodsId},
  ).toString();

  void _onSortChange(String? column, bool ascending) {
    if (_loading) return;
    setState(() {
      _sortKey = column;
      _sortAscending = ascending;
      _page = 1;
    });
    _load();
  }

  void _changeSource(_WhereUsedSource? value) {
    if (value == null || value == _source) return;
    setState(() {
      _source = value;
      _page = 1;
      _invalidateLoadedResults();
    });
    if (_material != null) _load();
  }

  void _setAllHistory(bool allHistory) {
    final newLimit = !allHistory;
    if (newLimit == _limitHistoryDates) return;
    setState(() {
      _limitHistoryDates = newLimit;
      _page = 1;
      _invalidateLoadedResults();
    });
    if (_material != null && allHistory) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unattributed =
        (_data?.meta['unattributedDemandCount'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '物料反查产成品',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新当前结果',
            onPressed: _material == null || _loading
                ? null
                : () async {
                    setState(() => _page = 1);
                    await _load();
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            // 「顶部折叠 + 表格吸顶内滚」：提示条与标题行随上滑收起腾出空间，
            // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
            child: UtenCollapsingHeaderScrollView(
              collapsingHeader: Column(
                children: [
                  _CoverageNotice(theme: theme),
                  if (unattributed > 0)
                    _UnattributedNotice(
                      count: unattributed,
                      quantity: _data?.meta['unattributedDemandQty'],
                    ),
                  _buildTitle(theme),
                ],
              ),
              body: LayoutBuilder(
                builder: (context, constraints) {
                  final filterPane = _buildFilterPane(theme);
                  return UtenListTwoPane(
                    filterPane: context.breakpoint.isExpanded
                        ? filterPane
                        : ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight * 0.48,
                            ),
                            child: filterPane,
                          ),
                    tablePane: _buildTablePane(theme),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 19,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '关系结果 · 点击行查看详情',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (_data != null)
            Text(
              '共 ${_data!.total} 个成品/半成品',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterPane(ThemeData theme) {
    // primary:false：筛选区是页面局部滚动件，不参与外层折叠联动，
    // 避免与表体 primary 列表争抢 PrimaryScrollController（多 ScrollPosition 冲突）。
    return SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('反查物料(必选)'),
          SizedBox(
            width: double.infinity,
            child: UtenButton(
              type: UtenButtonType.tonal,
              icon: _material == null
                  ? Icons.search_rounded
                  : Icons.swap_horiz_rounded,
              onPressed: _loading ? null : _pickMaterial,
              child: Text(_material == null ? '搜索并选择物料' : '更换物料'),
            ),
          ),
          if (_material != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            _SelectedMaterialCard(material: _material!),
          ],
          const SizedBox(height: UtenSpacing.s16),
          _filterLabel('关系来源'),
          DropdownButtonFormField<_WhereUsedSource>(
            key: const Key('where-used-source-filter'),
            initialValue: _source,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final source in _WhereUsedSource.values)
                DropdownMenuItem(value: source, child: Text(source.label)),
            ],
            onChanged: _loading ? null : _changeSource,
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            _source.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _filterLabel('历史日期范围'),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            children: [
              ChoiceChip(
                key: const Key('where-used-all-history'),
                label: const Text('全部历史'),
                selected: !_limitHistoryDates,
                onSelected: _loading ? null : (_) => _setAllHistory(true),
              ),
              ChoiceChip(
                key: const Key('where-used-custom-history'),
                label: const Text('自定义'),
                selected: _limitHistoryDates,
                onSelected: _loading ? null : (_) => _setAllHistory(false),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '日期只过滤生产/委外历史，当前 BOM 不受影响',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_limitHistoryDates) ...[
            const SizedBox(height: UtenSpacing.s8),
            _dateButton(
              key: const Key('where-used-date-from'),
              label: '起 ${_formatDate(_from)}',
              initialDate: _from,
              onPicked: (value) {
                setState(() {
                  _from = value;
                  _page = 1;
                  _invalidateLoadedResults();
                });
              },
            ),
            const SizedBox(height: UtenSpacing.s4),
            _dateButton(
              key: const Key('where-used-date-to'),
              label: '止 ${_formatDate(_to)}',
              initialDate: _to,
              onPicked: (value) {
                setState(() {
                  _to = value;
                  _page = 1;
                  _invalidateLoadedResults();
                });
              },
            ),
          ],
          const SizedBox(height: UtenSpacing.s16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('where-used-search'),
              onPressed: _material == null || _loading
                  ? null
                  : () {
                      _page = 1;
                      _load();
                    },
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded, size: 18),
              label: Text(_loading ? '查询中…' : '查询已知关系'),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
      ),
    );
  }

  Widget _dateButton({
    required Key key,
    required String label,
    required DateTime initialDate,
    required ValueChanged<DateTime> onPicked,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: key,
        onPressed: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: initialDate,
            firstDate: DateTime(2010),
            lastDate: DateTime(2100),
          );
          if (picked != null && picked != initialDate) onPicked(picked);
        },
        icon: const Icon(Icons.event_outlined, size: 18),
        label: Align(alignment: Alignment.centerLeft, child: Text(label)),
      ),
    );
  }

  Widget _buildTablePane(ThemeData theme) {
    if (_material == null) {
      return _StatePanel(
        icon: Icons.manage_search_rounded,
        title: '先搜索一个物料',
        message: '可搜索当前、停用、软删除及迁移占位的历史物料。',
        actionLabel: '选择物料',
        onAction: _pickMaterial,
      );
    }
    if (_loading && _data == null) {
      return const _StatePanel(
        loading: true,
        icon: Icons.account_tree_outlined,
        title: '正在汇总已知关系',
        message: '正在核对当前 BOM、生产需求与委外历史…',
      );
    }
    if (_loadError != null && _data == null) {
      return _StatePanel(
        icon: Icons.cloud_off_outlined,
        title: '暂时无法加载反查结果',
        message: _loadError!,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final data = _data;
    if (data == null) {
      return _StatePanel(
        icon: Icons.search_rounded,
        title: '条件已更新',
        message: '点击“查询已知关系”加载当前条件。',
        actionLabel: '查询',
        onAction: _load,
      );
    }

    final table = _buildTable(data);
    if (!_loading && _loadError == null) return table;
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_loadError != null)
          Material(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
            child: ListTile(
              dense: true,
              leading: Icon(
                Icons.error_outline_rounded,
                color: theme.colorScheme.error,
              ),
              title: Text('刷新失败，已保留上次成功结果：$_loadError'),
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          ),
        Expanded(child: table),
      ],
    );
  }

  Widget _buildTable(ReportData data) {
    final columns = data.columns
        .map(
          (column) => MasterColumnDef<Map<String, dynamic>>(
            key: column.key,
            label: column.label,
            width: (column.width ?? 120).toDouble(),
            type: column.type,
            sortable: isSortableReportType(column.type),
            value: (row) => formatReportCell(column, row),
          ),
        )
        .toList();
    final range = _loadedQuery == null
        ? '当前条件'
        : _historyRangeLabel(_loadedQuery!);
    return MasterDataTableView<Map<String, dynamic>>(
      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
      primary: true,
      columns: columns,
      items: data.rows,
      facets: data.facets,
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      sortColumn: _sortKey,
      sortAscending: _sortAscending,
      onSortChange: _onSortChange,
      onRowTap: _openProductDetail,
      isLoading: _loading,
      emptyMessage:
          '未找到可识别的已知关系(来源：${_source.label}，历史范围：$range)。'
          '可切换到“全部已知关系”或“全部历史”；当前仍可能受 BOM 拒绝行影响。',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (page) {
        if (_loading) return;
        _page = page;
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
          letterSpacing: 0.25,
        ),
      ),
    );
  }
}

class _CoverageNotice extends StatelessWidget {
  const _CoverageNotice({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.38),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.hub_outlined,
            size: 20,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '当前可用的已知关系 = 当前 BOM + 新生产需求 + 旧生产快照 + 委外历史证据。'
              '各来源分别显示、不混算；旧委外发料数量仍待迁移复核，仅作追溯。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnattributedNotice extends StatelessWidget {
  const _UnattributedNotice({required this.count, required this.quantity});

  final int count;
  final Object? quantity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Text(
        '另有 $count 条旧版生产需求(需求量 ${quantity ?? '—'})没有执行段，'
        '无法可靠归属到具体产成品，系统未作猜配。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

class _SelectedMaterialCard extends StatelessWidget {
  const _SelectedMaterialCard({required this.material});

  final GoodsListItem material;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = <String>[
      if ((material.code ?? '').isNotEmpty) '编号 ${material.code}',
      if ((material.status ?? '').isNotEmpty) '状态 ${material.status}',
      if (material.autoCreated) '历史占位',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            material.name ?? '(无名称)',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (labels.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              labels.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const CircularProgressIndicator(strokeWidth: 2.5)
                  else
                    Icon(
                      icon,
                      size: 42,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    FilledButton.tonal(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
