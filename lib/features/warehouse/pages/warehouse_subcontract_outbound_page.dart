// 委外出仓任务中心（/warehouse/subcontract-outbound）—— 仓库专属页面（V304）。
//
// 财务批准委外订货后，系统按当时 BOM 展开发料计划并自动生出仓草稿；
// 本页列出全部「待出仓」任务（OPEN 计划且有剩余量），点卡进拣货出仓页。
// 与委外模块单据页分立设计：仓库视角只有数量/重量/库位/委外商名，无价格金额。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
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
      body: SafeArea(
        child: result == null && _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(result),
      ),
    );
  }

  Widget _buildList(PagedResult<OutboundTask>? value) {
    final result =
        value ??
        const PagedResult<OutboundTask>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return UtenContentContainer.narrow(
      child: RefreshIndicator(
        onRefresh: () => _load(result.page),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            UtenSearchBar(
              key: const Key('subcontract-outbound-search'),
              hint: '搜索委外订货单号 / 委外商',
              initialValue: _keyword,
              onInputChanged: (_) => _requestVersion++,
              onChanged: _applySearch,
            ),
            const SizedBox(height: UtenSpacing.s12),
            // 口径说明：委外先出（材料）后进（成品）；本页任务由财务批准的订货单自动生成。
            const _OutboundHintBanner(),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '刷新失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              SizedBox(
                height: 380,
                child: UtenEmpty(
                  icon: Icons.outbound_outlined,
                  message: _keyword.isNotEmpty
                      ? '没有匹配「$_keyword」的出仓任务'
                      : '目前没有待出仓任务',
                  description: _keyword.isNotEmpty
                      ? '换个关键字试试，或清除搜索查看全部。'
                      : '财务批准委外订货单后，材料出仓任务会自动出现在这里。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _OutboundTaskCard(
                  key: Key('subcontract-outbound-${result.items[i].planId}'),
                  task: result.items[i],
                  onTap: () => _openTask(result.items[i]),
                ),
                if (i != result.items.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (result.totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              _Pager(
                page: result.page,
                totalPages: result.totalPages,
                loading: _loading,
                onPage: _load,
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }
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
        '委外 = 材料先出仓给委外商加工，成品再回厂进仓。'
        '本页任务由财务批准的委外订货单自动生成；分批出仓时余量会自动生成下一批草稿。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _OutboundTaskCard extends StatelessWidget {
  const _OutboundTaskCard({super.key, required this.task, required this.onTap});

  final OutboundTask task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDraft = task.draftId != null;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(UtenRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenStatusBadge(
                    label: hasDraft ? '出仓草稿待拣货' : '待生成出仓单',
                    type: hasDraft
                        ? UtenStatusBadgeType.warning
                        : UtenStatusBadgeType.info,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      task.orderBillNo ?? '—',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              _InfoLine(
                icon: Icons.storefront_outlined,
                label: '委外商',
                value: task.supplierName ?? '—',
              ),
              _InfoLine(
                icon: Icons.event_outlined,
                label: '交货日期',
                value: task.deliverDate ?? '未填写',
              ),
              _InfoLine(
                icon: Icons.inventory_outlined,
                label: '出仓进度',
                value:
                    '计划 ${_fmtQty(task.plannedQty)}，已出仓 ${_fmtQty(task.issuedQty)}，'
                    '待出仓 ${_fmtQty(task.remainingQty)}(${task.lineCount} 行材料)',
              ),
              if (hasDraft)
                _InfoLine(
                  icon: Icons.description_outlined,
                  label: '出仓草稿',
                  value: task.draftBillNo ?? '—',
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s8),
          Text(
            '$label：',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPage,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        UtenButton(
          type: UtenButtonType.tonal,
          icon: Icons.chevron_left_rounded,
          onPressed: loading || page <= 1 ? null : () => onPage(page - 1),
          child: const Text('上一页'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Text('$page / $totalPages'),
        ),
        UtenButton(
          type: UtenButtonType.tonal,
          icon: Icons.chevron_right_rounded,
          onPressed: loading || page >= totalPages
              ? null
              : () => onPage(page + 1),
          child: const Text('下一页'),
        ),
      ],
    );
  }
}
