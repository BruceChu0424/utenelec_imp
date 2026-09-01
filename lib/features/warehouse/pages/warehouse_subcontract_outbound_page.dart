// 委外目标件出仓任务中心（/warehouse/subcontract-outbound）—— 仓库专属页面（V436）。
//
// 财务批准委外订货后，服务端逐行判断准备路线：无子层级核对并预留目标件合格库存；
// 有子层级完成完整前置自制、FQC 与仓库实收入仓。只有已经备齐并释放的目标件才出现在本页。
// 与委外模块单据页分立设计：仓库视角只有数量/重量/库位/委外商名，无价格金额。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_outbound.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';

class WarehouseSubcontractOutboundPage extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundPage({super.key});

  @override
  ConsumerState<WarehouseSubcontractOutboundPage> createState() =>
      _WarehouseSubcontractOutboundPageState();
}

class _WarehouseSubcontractOutboundPageState
    extends ConsumerState<WarehouseSubcontractOutboundPage> {
  PagedResult<OutboundTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  String _keyword = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
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
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外出仓任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : () => _load(result?.page ?? 1),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _buildTable(result)),
    );
  }

  Widget _buildTable(PagedResult<OutboundTask>? value) {
    final result =
        value ??
        const PagedResult<OutboundTask>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(result),
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
        ),
      ),
    );
  }

  Widget _buildToolbar(PagedResult<OutboundTask> result) {
    final search = UtenSearchBar(
      key: const Key('subcontract-outbound-search'),
      hint: '搜索委外订货单号 / 委外商',
      initialValue: _keyword,
      onInputChanged: (_) => _requestVersion++,
      onChanged: _applySearch,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final summary = Text(
              '共 ${result.total} 项 · 单击选中，双击详情',
              key: const Key('subcontract-outbound-table-summary'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
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
        ),
        const SizedBox(height: UtenSpacing.s8),
        // 仓库只执行服务端已经放行的目标件，不在本页判断 BOM 或前置自制状态。
        const _OutboundHintBanner(),
      ],
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
