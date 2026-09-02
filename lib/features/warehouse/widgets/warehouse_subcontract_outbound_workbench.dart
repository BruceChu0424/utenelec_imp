// 委外出仓工作台（可嵌入）：财务批准委外订货后，服务端逐行判断准备路线——
// 无子层级核对并预留目标件合格库存；有子层级完成完整前置自制、FQC 与仓库实收
// 入仓。只有已备齐并释放的目标件才出现在本列表。仓库视角只有数量/重量/库位/
// 委外商名，无价格金额。
//
// 2026-09-01 起「出库任务中心 · 委外出库」分段内嵌本组件（embedded=true 时不带
// 搜索框——关键字由任务中心页级工具条统一下发）；独立路由
// /warehouse/subcontract-outbound 由对应页面以 embedded=false 包一层继续承接。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_outbound.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';

class WarehouseSubcontractOutboundWorkbench extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundWorkbench({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
    this.showHintBanner = true,
  });

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在出库任务中心分段内（表格，无搜索框）。
  final bool embedded;

  /// 是否显示业务口径提示条。
  final bool showHintBanner;

  @override
  ConsumerState<WarehouseSubcontractOutboundWorkbench> createState() =>
      _WarehouseSubcontractOutboundWorkbenchState();
}

class _WarehouseSubcontractOutboundWorkbenchState
    extends ConsumerState<WarehouseSubcontractOutboundWorkbench> {
  PagedResult<OutboundTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(WarehouseSubcontractOutboundWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _keyword = widget.keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  void _applySearch(String value) {
    if (value == _keyword) return;
    setState(() => _keyword = value);
    _load(1);
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
      final result = await repo.tasks(page: page, keyword: _keyword);
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseSubcontractOutboundCountProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '委外出仓任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _openTask(OutboundTask task) async {
    // 拣货页保存/审核成功会 pop(true)：重载列表，任务即时反映最新剩余量。
    final done = await context.push<bool>(
      '/warehouse/subcontract-outbound/${task.planId}',
    );
    if (done == true && mounted) {
      await _load(_result?.page ?? 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result =
        _result ??
        const PagedResult<OutboundTask>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded) ...[
          _buildStandaloneSearch(result),
          const SizedBox(height: UtenSpacing.s8),
        ],
        if (widget.showHintBanner) const _OutboundHintBanner(),
        if (!widget.embedded) const SizedBox(height: UtenSpacing.s12),
        if (_error != null && result.items.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: MasterDataTableView<OutboundTask>(
            key: const Key('subcontract-outbound-task-table'),
            columns: _columns,
            items: result.items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: _openTask,
            rowMenuBuilder: (item) => [
              UtenMenuItem(
                label: '进入目标件拣货出仓',
                icon: Icons.outbound_outlined,
                onTap: () => _openTask(item),
              ),
            ],
            isLoading: _loading,
            loadingMore: _loading && _result != null,
            error: result.items.isEmpty ? _error : null,
            onRetry: () => _load(result.page),
            emptyMessage: _keyword.isNotEmpty
                ? '没有匹配「$_keyword」的出仓任务'
                : '目前没有待出仓任务',
            currentPage: result.page,
            totalPages: result.totalPages,
            onPageChange: _load,
          ),
        ),
      ],
    );
  }

  Widget _buildStandaloneSearch(PagedResult<OutboundTask> result) {
    final search = UtenSearchBar(
      key: const Key('subcontract-outbound-search'),
      hint: '搜索委外订货单号 / 委外商',
      initialValue: _keyword,
      onInputChanged: (_) => _requestVersion++,
      onChanged: _applySearch,
    );
    final summary = Text(
      '共 ${result.total} 项 · 单击选中，双击详情',
      key: const Key('subcontract-outbound-table-summary'),
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: UtenSpacing.s8),
              Align(alignment: Alignment.centerRight, child: summary),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 360, child: search),
            const Spacer(),
            summary,
          ],
        );
      },
    );
  }

  List<MasterColumnDef<OutboundTask>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '任务状态',
      width: 150,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'orderBillNo',
      label: '委外订货单',
      width: 180,
      value: (item) => item.orderBillNo ?? '—',
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '委外商',
      width: 200,
      value: (item) => item.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'deliverDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      value: (item) => item.deliverDate ?? '—',
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: '目标件行数',
      width: 100,
      type: 'number',
      value: (item) => item.lineCount.toString(),
    ),
    MasterColumnDef(
      key: 'draftBillNo',
      label: '出仓草稿单',
      width: 180,
      value: (item) => item.draftBillNo ?? '—',
    ),
  ];
}

class _OutboundHintBanner extends StatelessWidget {
  const _OutboundHintBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(UtenRadius.md),
      ),
      child: Text(
        '仓库只看到已经备齐并由服务端放行的委外目标件。无子层级时先预留合格库存；'
        '有子层级时必须完成物料分析、领料、自制报工、FQC 和成品入仓后才会出现在这里。'
        '历史 BOM 子件发料单仍按原单据只读兼容。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
