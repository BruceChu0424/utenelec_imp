import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_repository.dart';

/// Object-scoped material-analysis task/history center.
///
/// The API owns visibility and every readiness quantity. Rows only navigate
/// back to the persisted aggregate by [MaterialAnalysisListItem.analysisId].
class ProductionMaterialAnalysisHistoryPage extends ConsumerStatefulWidget {
  const ProductionMaterialAnalysisHistoryPage({super.key});

  @override
  ConsumerState<ProductionMaterialAnalysisHistoryPage> createState() =>
      _ProductionMaterialAnalysisHistoryPageState();
}

class _ProductionMaterialAnalysisHistoryPageState
    extends ConsumerState<ProductionMaterialAnalysisHistoryPage> {
  static const _statuses = <String, String>{
    'ACTIVE': '进行中',
    'PARTIALLY_PLANNED': '部分已下达，剩余待料',
    'COMPLETED': '已全部下达',
    'CANCELLED': '已取消',
  };

  static const _sourceTypes = <String, String>{
    'SALES_ORDER_ITEM': '销售订单',
    'REWORK': '返工',
    'TRIAL': '试制',
    'SAMPLE': '样品',
    'STOCK': '备库',
    'OTHER': '其他',
    'MAKE_COMPONENT': '自制子需求',
  };

  final _search = TextEditingController();
  Timer? _searchDebounce;
  PagedResult<MaterialAnalysisListItem>? _page;
  String _status = '';
  String _sourceType = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({int page = 1}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisList(
            page: page,
            keyword: _search.text,
            status: _status.isEmpty ? null : _status,
            sourceType: _sourceType.isEmpty ? null : _sourceType,
          );
      if (!mounted) return;
      setState(() {
        _page = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionErrorMessage(error, fallback: '物料分析记录加载失败，请稍后重试');
      });
    }
  }

  void _searchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _load();
    });
  }

  Future<void> _open(MaterialAnalysisListItem item) async {
    await context.push(
      RouteName.productionMaterialAnalysis,
      extra: ProductionMaterialAnalysisSeed(
        analysisId: item.analysisId,
        analysisVersion: item.version,
        warehouseId: item.warehouseId,
      ),
    );
    if (mounted) await _load(page: _page?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = context.breakpoint.isCompact;
    return Scaffold(
      appBar: UtenAppBar(
        title: '物料分析记录',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.productionMaterialAnalysis,
          ),
        ),
        actions: [
          if (compact)
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: '生产计划历史',
              onPressed: _loading
                  ? null
                  : () => context.push(RouteName.productionPlanList),
              icon: const Icon(Icons.history_rounded),
            )
          else
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.history_rounded,
              onPressed: _loading
                  ? null
                  : () => context.push(RouteName.productionPlanList),
              child: const Text('生产计划历史'),
            ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _intro(theme),
                const SizedBox(height: UtenSpacing.s8),
                _filters(compact),
                const SizedBox(height: UtenSpacing.s8),
                Expanded(child: _content(theme, compact)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _intro(ThemeData theme) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
      border: Border.all(color: theme.colorScheme.outlineVariant),
      borderRadius: UtenRadius.mdAll,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.fact_check_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(
          child: Text(
            '这里用于找回销售、返工、试制、样品、备库和自制子需求的物料分析。'
            '记录范围由服务端按负责人和部门权限控制。',
          ),
        ),
      ],
    ),
  );

  Widget _filters(bool compact) => Wrap(
    spacing: UtenSpacing.s8,
    runSpacing: UtenSpacing.s8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      SizedBox(
        width: compact ? double.infinity : 320,
        child: TextField(
          key: const Key('analysis-history-search'),
          controller: _search,
          onChanged: _searchChanged,
          onSubmitted: (_) => _load(),
          decoration: const InputDecoration(
            labelText: '搜索需求编号、销售单号或产品',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
      ),
      SizedBox(
        width: compact ? double.infinity : 190,
        child: DropdownButtonFormField<String>(
          key: ValueKey('analysis-history-status-$_status'),
          initialValue: _status,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '状态'),
          items: [
            const DropdownMenuItem(value: '', child: Text('全部状态')),
            for (final entry in _statuses.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: _loading
              ? null
              : (value) {
                  setState(() => _status = value ?? '');
                  _load();
                },
        ),
      ),
      SizedBox(
        width: compact ? double.infinity : 190,
        child: DropdownButtonFormField<String>(
          key: ValueKey('analysis-history-source-$_sourceType'),
          initialValue: _sourceType,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '需求来源'),
          items: [
            const DropdownMenuItem(value: '', child: Text('全部来源')),
            for (final entry in _sourceTypes.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: _loading
              ? null
              : (value) {
                  setState(() => _sourceType = value ?? '');
                  _load();
                },
        ),
      ),
      UtenButton(
        key: const Key('analysis-history-refresh'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        icon: Icons.refresh_rounded,
        isLoading: _loading,
        onPressed: _loading ? null : () => _load(page: _page?.page ?? 1),
        child: const Text('刷新'),
      ),
    ],
  );

  Widget _content(ThemeData theme, bool compact) {
    final page = _page;
    if (_loading && page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && page == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              onPressed: _loading ? null : _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final items = page?.items ?? const <MaterialAnalysisListItem>[];
    if (compact) return _cards(theme, items);
    return MasterDataTableView<MaterialAnalysisListItem>(
      key: const Key('analysis-history-table'),
      columns: _columns,
      items: items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: _open,
      isLoading: _loading,
      error: _error,
      onRetry: () => _load(page: page?.page ?? 1),
      emptyMessage: '没有符合条件的物料分析记录',
      currentPage: page?.page ?? 1,
      totalPages: page?.totalPages ?? 0,
      onPageChange: (value) => _load(page: value),
    );
  }

  List<MasterColumnDef<MaterialAnalysisListItem>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 120,
      value: (item) => _statusLabel(item.status),
    ),
    const MasterColumnDef(
      key: 'source',
      label: '来源 / 需求编号',
      width: 250,
      value: _sourceSummary,
    ),
    MasterColumnDef(
      key: 'product',
      label: '产品',
      width: 230,
      value: (item) => _join(item.productLabels),
    ),
    const MasterColumnDef(
      key: 'warehouse',
      label: '分析仓库',
      width: 150,
      value: _warehouseLabel,
    ),
    const MasterColumnDef(
      key: 'owner',
      label: '负责人',
      width: 130,
      value: _ownerLabel,
    ),
    MasterColumnDef(
      key: 'progress',
      label: '需求 / 已排',
      width: 170,
      value: (item) =>
          '${_qty(item.requestedQty)} / ${_qty(item.submittedQty + item.approvedQty)}',
    ),
    MasterColumnDef(
      key: 'readiness',
      label: '可立即 / 按期',
      width: 170,
      value: (item) =>
          '${_qty(item.readyNowQty)} / ${_qty(item.readyByDateQty)}',
    ),
    MasterColumnDef(
      key: 'updatedAt',
      label: '更新时间',
      width: 160,
      value: (item) => _dateTime(item.updatedAt ?? item.analyzedAt),
    ),
    MasterColumnDef(
      key: 'action',
      label: '操作',
      width: 120,
      value: (item) => '${_actionLabel(item.status)} →',
    ),
  ];

  Widget _cards(ThemeData theme, List<MaterialAnalysisListItem> items) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          '没有符合条件的物料分析记录',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final page = _page;
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            key: const Key('analysis-history-cards'),
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s8),
            itemBuilder: (_, index) => _card(theme, items[index]),
          ),
        ),
        if ((page?.totalPages ?? 0) > 1) _mobilePager(page!),
      ],
    );
  }

  Widget _card(ThemeData theme, MaterialAnalysisListItem item) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: UtenRadius.mdAll,
      side: BorderSide(color: theme.colorScheme.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: Key('analysis-history-row-${item.analysisId}'),
      onTap: _loading ? null : () => _open(item),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    _join(item.productLabels, fallback: '未命名产品'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                _statusChip(theme, item.status),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            _infoLine(Icons.link_outlined, _sourceSummary(item)),
            _infoLine(
              Icons.person_outline_rounded,
              '负责人 ${_ownerLabel(item)} · 仓库 ${_warehouseLabel(item)}',
            ),
            _infoLine(
              Icons.inventory_2_outlined,
              '需求 ${_qty(item.requestedQty)} · 已提交 ${_qty(item.submittedQty)} · '
              '已批准 ${_qty(item.approvedQty)} · 待处理 ${_qty(item.remainingQty)}',
            ),
            _infoLine(
              Icons.fact_check_outlined,
              '可立即生产 ${_qty(item.readyNowQty)} · 按期可生产 ${_qty(item.readyByDateQty)}',
            ),
            const SizedBox(height: UtenSpacing.s4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '更新 ${_dateTime(item.updatedAt ?? item.analyzedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _actionLabel(item.status),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: theme.colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _statusChip(ThemeData theme, String status) {
    final active = status == 'ACTIVE' || status == 'PARTIALLY_PLANNED';
    final cancelled = status == 'CANCELLED';
    final color = cancelled
        ? theme.colorScheme.error
        : active
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.pillAll,
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_statusIcon(status), size: 16, color: color),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            _statusLabel(status),
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoLine(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _mobilePager(PagedResult<MaterialAnalysisListItem> page) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        tooltip: '上一页',
        onPressed: !_loading && page.page > 1
            ? () => _load(page: page.page - 1)
            : null,
        icon: const Icon(Icons.chevron_left_rounded),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
        child: Text('${page.page} / ${page.totalPages} · 共 ${page.total} 条'),
      ),
      IconButton(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        tooltip: '下一页',
        onPressed: !_loading && page.page < page.totalPages
            ? () => _load(page: page.page + 1)
            : null,
        icon: const Icon(Icons.chevron_right_rounded),
      ),
    ],
  );

  static String _statusLabel(String status) => _statuses[status] ?? '状态待确认';

  static IconData _statusIcon(String status) => switch (status) {
    'ACTIVE' => Icons.play_circle_outline_rounded,
    'PARTIALLY_PLANNED' => Icons.pending_actions_outlined,
    'COMPLETED' => Icons.check_circle_outline_rounded,
    'CANCELLED' => Icons.cancel_outlined,
    _ => Icons.help_outline_rounded,
  };

  static String _actionLabel(String status) =>
      status == 'ACTIVE' || status == 'PARTIALLY_PLANNED' ? '继续处理' : '查看';

  static String _sourceSummary(MaterialAnalysisListItem item) {
    final types = item.sourceTypes
        .map((value) => _sourceTypes[value] ?? value)
        .toList(growable: false);
    final typeText = _join(types, fallback: '来源待确认');
    final refText = _join(item.sourceRefs);
    return refText.isEmpty
        ? '$typeText · ${item.sourceCount} 项'
        : '$typeText · $refText';
  }

  static String _warehouseLabel(MaterialAnalysisListItem item) {
    final values = [item.warehouseCode, item.warehouseName]
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    return values.isEmpty ? '未记录' : values.join(' ');
  }

  static String _ownerLabel(MaterialAnalysisListItem item) =>
      item.makerName?.trim().isNotEmpty == true
      ? item.makerName!.trim()
      : item.makerId?.trim().isNotEmpty == true
      ? item.makerId!.trim()
      : '未记录';

  static String _dateTime(String? value) =>
      ChinaDateTime.formatIsoInstant(value, fallback: '未记录');

  static String _join(List<String> values, {String fallback = ''}) {
    final cleaned = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return cleaned.isEmpty ? fallback : cleaned.join('、');
  }

  static String _qty(double value) {
    if (!value.isFinite) return '0';
    final fixed = value.toStringAsFixed(4);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
