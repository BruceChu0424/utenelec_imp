import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../models/production_material_analysis.dart';
import '../providers/production_execution_group_count_provider.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_execution_workbench_repository.dart';
import '../widgets/production_flow_stage_cell.dart';
import '../../../shared/providers/list_refresh_provider.dart';

/// Planning-facing ongoing list: one row per outer analysis/root plan.
///
/// 2026-09-06 起为「大的分析」统筹视角：顶部不再提供生产车间/排序筛选
/// （关键词搜索在大类行，排序/细分信息双击进详情看）；表格只保留分析级
/// 重要列——顶层产品完工进度（进度条+百分比，只统计参与分析的销售下单
/// 产品，不含子层）、分析批次、关联销售订单、产品、分析人、分析时间。
/// 工单号/车间/产品编号/数量明细等执行细节双击进物料分析页查看。
class ProductionExecutionGroupPanel extends ConsumerStatefulWidget {
  const ProductionExecutionGroupPanel({super.key, required this.keyword});

  final String keyword;

  @override
  ConsumerState<ProductionExecutionGroupPanel> createState() =>
      _ProductionExecutionGroupPanelState();
}

class _ProductionExecutionGroupPanelState
    extends ConsumerState<ProductionExecutionGroupPanel> {
  List<ProductionExecutionWorkbenchGroup> _items = const [];
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  bool _opening = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant ProductionExecutionGroupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) {
      _page = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final requestedPage = _page;
    final requestedKeyword = widget.keyword;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .groups(page: requestedPage, keyword: requestedKeyword);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
      });
      // 大类行「进行中 N」计数与列表同源，随本列表加载一并刷新。
      ref.invalidate(productionExecutionGroupCountProvider);
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '生产任务加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// 双击批次 → 直达对应详情页：ANALYSIS 根恢复物料分析（该页适合看全链进度），
  /// PLAN 根（历史遗留根计划聚合）打开生产计划详情。不再弹滑窗。
  Future<void> _open(ProductionExecutionWorkbenchGroup group) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      if (group.rootType == 'ANALYSIS') {
        await context.push(
          RouteName.productionMaterialAnalysis,
          extra: ProductionMaterialAnalysisSeed(analysisId: group.rootId),
        );
      } else {
        await context.push(RoutePath.productionPlanDetail(group.rootId));
      }
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(listRefreshTickProvider(productionExecutionRefreshKey), (_, _) {
      if (!_opening) _load();
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s8,
      ),
      child: MasterDataTableView<ProductionExecutionWorkbenchGroup>(
        columns: _columns,
        items: _items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        onRowTap: _opening ? null : _open,
        canOpenRow: (row) => !_opening,
        rowKeyOf: (row) => row.id,
        rowMenuBuilder: (row) => [
          UtenMenuItem(
            label: row.rootType == 'ANALYSIS' ? '打开物料分析' : '打开生产计划',
            icon: Icons.open_in_new_rounded,
            enabled: !_opening,
            onTap: () => _open(row),
          ),
        ],
        currentPage: _page,
        totalPages: _totalPages,
        onPageChange: (page) {
          _page = page;
          _load();
        },
        isLoading: _loading,
        error: _error,
        onRetry: _load,
        emptyMessage: widget.keyword.isEmpty ? '暂无进行中的物料分析或生产任务' : '没有匹配的生产任务',
        toolbarActions: [
          IconButton(
            key: const Key('production-progress-refresh'),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchGroup>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 170,
      value: (row) => row.statusLabel,
      cellBuilder: (_, row) => _GroupStatusBadge(row: row),
    ),
    MasterColumnDef(
      key: 'root',
      label: '分析批次',
      width: 150,
      value: (row) => row.rootLabel,
    ),
    MasterColumnDef(
      key: 'orders',
      label: '关联订单',
      width: 210,
      value: (row) => _preview(
        row.salesOrderPreview,
        row.salesOrderCount,
        row.salesOrderHasMore,
      ),
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    // 同名不同色、同名不同编号的分析批次光看名称分不开。**注意**：这三条
    // preview 各自是本组「前三项聚合」，列与列之间**不是逐项对齐**的——
    // 编号列第 2 个不一定对应名称列第 2 个（列头 ⓘ 已写明），别据此配对。
    MasterColumnDef(
      key: 'productName',
      label: '产品名称',
      width: 200,
      info: '本组前几个产品的名称汇总；与右侧编号/颜色列各自独立聚合，不逐项对应。',
      value: (row) => _productNameLine(row) ?? '—',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) =>
          UtenGoodsIdentityCell(name: _productNameLine(row)),
    ),
    MasterColumnDef(
      key: 'productCode',
      label: '编号',
      width: 130,
      info: '本组前几个产品的编号汇总，与名称列不逐项对应。',
      value: (row) =>
          UtenGoodsAttributeCell.text(_blankToNull(row.productCodePreview)),
      cellBuilder: (_, row) =>
          UtenGoodsAttributeCell(_blankToNull(row.productCodePreview)),
    ),
    MasterColumnDef(
      key: 'productColor',
      label: '颜色',
      width: 96,
      info: '本组前几个产品的颜色汇总，与名称列不逐项对应。',
      value: (row) =>
          UtenGoodsAttributeCell.text(_blankToNull(row.productColorPreview)),
      cellBuilder: (_, row) =>
          UtenGoodsAttributeCell(_blankToNull(row.productColorPreview)),
    ),
    // 顶层产品完工进度：只统计参与分析的销售下单产品（多张销售单联合
    // 分析也按根产品行聚合），子层自制/委外的完工不冒充顶层进度。
    MasterColumnDef(
      key: 'progress',
      label: '进度',
      width: 220,
      value: (row) => row.rootProgressPercent == null
          ? '—'
          : '完工 ${row.rootProgressPercent}%',
      cellBuilder: (_, row) => ProductionFlowProgress(
        ratio: row.rootProgressRatio,
        semanticsLabel: '顶层产品完工进度',
      ),
    ),
    MasterColumnDef(
      key: 'maker',
      label: '分析人',
      width: 130,
      value: (row) => row.ownerEmployeeName?.trim().isEmpty == false
          ? row.ownerEmployeeName!.trim()
          : '—',
    ),
    MasterColumnDef(
      key: 'analyzedAt',
      label: '分析时间',
      width: 160,
      value: (row) => row.analyzedAt?.trim().isEmpty == false
          ? row.analyzedAt!.trim()
          : '—',
    ),
  ];
}

String _preview(String? value, int count, bool hasMore) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  return hasMore ? '$text · 共 $count 项' : text;
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

/// 产品身份主行：名称预览 +「共 N 项」（预览截断时提示还有更多产品）。
/// 名称全空时返回 null——身份格会把编号顶到主行，不显示占位词。
String? _productNameLine(ProductionExecutionWorkbenchGroup row) {
  final text = _blankToNull(row.productNamePreview);
  if (text == null) return null;
  return row.productHasMore ? '$text · 共 ${row.productCount} 项' : text;
}

class _GroupStatusBadge extends StatelessWidget {
  const _GroupStatusBadge({required this.row});

  final ProductionExecutionWorkbenchGroup row;

  @override
  Widget build(BuildContext context) {
    final type = switch (row.status) {
      'PREPARED' => UtenStatusBadgeType.success,
      'IN_PROGRESS' => UtenStatusBadgeType.info,
      'KIT_SHORT' ||
      'PREPARING' ||
      'PARTIALLY_SCHEDULED' => UtenStatusBadgeType.warning,
      'ASSIGNMENT_REQUIRED' => UtenStatusBadgeType.danger,
      _ => UtenStatusBadgeType.neutral,
    };
    return UtenStatusBadge(label: row.statusLabel, type: type);
  }
}
