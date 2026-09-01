import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';

class WarehouseArrivalExceptionsPage extends ConsumerStatefulWidget {
  const WarehouseArrivalExceptionsPage({super.key});

  @override
  ConsumerState<WarehouseArrivalExceptionsPage> createState() =>
      _WarehouseArrivalExceptionsPageState();
}

class _WarehouseArrivalExceptionsPageState
    extends ConsumerState<WarehouseArrivalExceptionsPage> {
  PagedResult<ProcurementArrivalException>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  String _keyword = '';
  bool _history = false;
  String? _stockingId;
  Set<String> _selectedIds = const {};
  bool _batchStocking = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _applySearch(String value) async {
    setState(() {
      _keyword = value.trim();
      _selectedIds = const {};
    });
    await _load(1);
  }

  Future<void> _switchHistory(bool history) async {
    if (_history == history) return;
    setState(() {
      _history = history;
      _selectedIds = const {};
    });
    await _load(1);
  }

  void _setSelectedIds(Set<String> next) {
    setState(() => _selectedIds = next);
  }

  Future<void> _openDetail(
    ProcurementArrivalException task, {
    required bool canStockIn,
  }) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _WarehouseExceptionDetailDialog(
        task: task,
        stocking: _stockingId == task.id,
        onStockIn: canStockIn && _stockingId == null && task.canStockIn
            ? () {
                Navigator.of(dialogContext).pop();
                _stockIn(task);
              }
            : null,
      ),
    );
  }

  String _batchKey(Set<String> ids) {
    final sorted = ids.toList()..sort();
    final fingerprint = sorted.join('|');
    if (_batchSelectionFingerprint != fingerprint ||
        _batchIdempotencyKey == null) {
      _batchSelectionFingerprint = fingerprint;
      _batchIdempotencyKey = 'arrival-stock-in-batch-${const Uuid().v4()}';
    }
    return _batchIdempotencyKey!;
  }

  Future<void> _batchStockInSelected(Set<String> selectedIds) async {
    if (_batchStocking || selectedIds.isEmpty) {
      if (selectedIds.isEmpty) context.appWarning('请先选择可按财务批准量处理的异常');
      return;
    }
    final currentItems =
        _result?.items ?? const <ProcurementArrivalException>[];
    final selected = currentItems
        .where((task) => selectedIds.contains(task.id))
        .toList(growable: false);
    if (selected.length != selectedIds.length ||
        selected.any((task) => !task.canStockIn)) {
      context.appWarning('所选异常状态已变化，请刷新后重新选择');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('批量按批准量处理 ${selected.length} 条'),
        content: const Text(
          '系统将按财务批准量审核对应收货单，进入 IQC 待检隔离，并按现有收货链路回写到货与应付事实。'
          '这不代表已经进入可用库存；品质检验合格后只形成仓库待入库任务，'
          '仓库确认实物数量和实际库位后才会增加可用库存。'
          '任一状态、版本、权限、审核、应付或并发校验失败，整批都会回滚。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('确认批量处理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _batchStocking = true);
    try {
      final result = await ref
          .read(procurementInboundRepositoryProvider)
          .batchStockInAccepted(
            items: [
              for (final task in selected)
                (exceptionId: task.id, expectedVersion: task.version),
            ],
            idempotencyKey: _batchKey(selectedIds),
          );
      if (!mounted) return;
      final current = _result;
      final completedIds = result.processedExceptionIds.isEmpty
          ? selectedIds
          : result.processedExceptionIds;
      setState(() {
        if (current != null) {
          final remaining = current.items
              .where((task) => !completedIds.contains(task.id))
              .toList(growable: false);
          final removed = current.items.length - remaining.length;
          final total = (current.total - removed).clamp(0, 1 << 31);
          _result = PagedResult(
            items: remaining,
            page: current.page,
            size: current.size,
            total: total,
            totalPages: total == 0
                ? 0
                : (total + current.size - 1) ~/ current.size,
          );
        }
        _selectedIds = const {};
        _batchSelectionFingerprint = null;
        _batchIdempotencyKey = null;
      });
      ref.invalidate(warehouseArrivalExceptionCountProvider);
      context.appSuccess(
        result.replay
            ? '该批次已完成，已安全重放 ${result.processedCount} 条结果'
            : '已批量按财务批准量处理 ${result.processedCount} 条到货异常',
      );
      await _load(_result?.page ?? 1);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('批量处理失败，请保持当前选择后重试');
    } finally {
      if (mounted) setState(() => _batchStocking = false);
    }
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.length;
    return [
      Tooltip(
        message: count == 0 ? '请选择“等待仓库重新审核”的异常' : '按财务批准量原子审核并送品质待检',
        child: UtenButton(
          key: const Key('warehouse-arrival-exception-batch-stock-in'),
          size: UtenButtonSize.large,
          icon: Icons.fact_check_outlined,
          isLoading: _batchStocking,
          onPressed: _batchStocking || count == 0
              ? null
              : () => _batchStockInSelected(selectedIds),
          onDisabledTap: count == 0
              ? () => context.appWarning('请先选择可按财务批准量处理的异常')
              : null,
          child: Text(count == 0 ? '批量按批准量处理' : '批量按批准量处理($count)'),
        ),
      ),
    ];
  }

  /// 单条处理：按财务接受量审核收货、进入 IQC 待检隔离并沿既有链路入账。
  Future<void> _stockIn(ProcurementArrivalException task) async {
    if (_stockingId != null || !task.canStockIn) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认按批准量处理'),
        content: Text(
          '将按财务批准的 ${procurementQty(task.acceptedQty)} ${task.unitName ?? ''} '
          '审核收货并送入 IQC 待检隔离，同时沿既有链路回写到货与应付事实；'
          '品质检验合格后只形成仓库待入库任务，仓库确认后才会进入可用库存。'
          '未批准的 ${procurementQty(task.unacceptedQty)} '
          '${task.unitName ?? ''} 仍由采购退回供应商。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.inbox_outlined),
            label: const Text('确认处理批准量'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _stockingId = task.id);
    try {
      await ref
          .read(procurementInboundRepositoryProvider)
          .stockInAccepted(task.id);
      if (!mounted) return;
      ref.invalidate(warehouseArrivalExceptionCountProvider);
      context.appSuccess('已按批准数量审核收货并送检');
      await _load(_result?.page ?? 1);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
      if (e.code == 'CONFLICT') await _load(_result?.page ?? 1);
    } catch (_) {
      if (mounted) context.appError('按批准量处理失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _stockingId = null);
    }
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(procurementInboundRepositoryProvider)
          .warehouseExceptions(
            page: page,
            keyword: _keyword,
            history: _history,
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseArrivalExceptionCountProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '到货异常加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final permissions = ref.watch(currentPermissionsProvider);
    final canBatchStockIn =
        !_history &&
        (ref.watch(isSuperAdminProvider) ||
            permissions.contains(Perm.warehouseInboundStockIn));
    return Scaffold(
      appBar: UtenAppBar(
        title: '到货异常任务中心',
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
        child: _loading && result == null
            ? const UtenSkeletonList()
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(result, canBatchStockIn: canBatchStockIn),
      ),
    );
  }

  Widget _buildList(
    PagedResult<ProcurementArrivalException>? value, {
    required bool canBatchStockIn,
  }) {
    final result =
        value ??
        const PagedResult<ProcurementArrivalException>(
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
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Semantics(
                liveRegion: true,
                child: Text(
                  '刷新失败：${_error!}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: MasterDataTableView<ProcurementArrivalException>(
                key: const Key('warehouse-arrival-exception-task-table'),
                columns: _columns,
                items: result.items,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: canBatchStockIn,
                idOf: (task) => task.canStockIn ? task.id : null,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: _setSelectedIds,
                batchActionsBuilder: canBatchStockIn ? _batchActions : null,
                onRowTap: (task) =>
                    _openDetail(task, canStockIn: canBatchStockIn),
                rowMenuBuilder: (task) => [
                  UtenMenuItem(
                    label: '查看异常详情',
                    icon: Icons.open_in_new_rounded,
                    onTap: () => _openDetail(task, canStockIn: canBatchStockIn),
                  ),
                  if (canBatchStockIn && task.canStockIn && _stockingId == null)
                    UtenMenuItem(
                      label: '按财务批准量处理',
                      icon: Icons.inbox_outlined,
                      onTap: () => _stockIn(task),
                    ),
                ],
                rowColor: (task) {
                  if (task.status == 'PENDING_FINANCE') {
                    return Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: 0.30);
                  }
                  if (task.canStockIn) {
                    return Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.withValues(alpha: 0.28);
                  }
                  return null;
                },
                isLoading: _loading,
                loadingMore: _loading && _result != null,
                error: result.items.isEmpty ? _error : null,
                onRetry: () => _load(result.page),
                emptyMessage: _history
                    ? '历史中没有已完成的到货异常'
                    : _keyword.isNotEmpty
                    ? '没有匹配的到货异常'
                    : '目前没有到货异常',
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

  Widget _buildToolbar(PagedResult<ProcurementArrivalException> result) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          label: _history
              ? '共有 ${result.total} 条历史到货异常'
              : '共有 ${result.total} 条进行中到货异常',
          // 全平台统一筛选工具条：分段 + 胶囊搜索框（尾挂总数文案）。
          child: UtenFilterToolbar<bool>(
            segmentsKey: const Key('warehouse-arrival-exception-mode'),
            searchKey: const Key('warehouse-arrival-exception-search'),
            segments: const [
              UtenFilterSegment(value: false, label: '进行中'),
              UtenFilterSegment(value: true, label: '历史'),
            ],
            selected: _history,
            onSelectionChanged: _switchHistory,
            searchHint: '搜索收货单 / 订货单 / 货品 / 供应商',
            initialSearchValue: _keyword,
            onSearchInputChanged: (_) => _requestVersion++,
            onSearchChanged: _applySearch,
            trailing: Text(
              '共 ${result.total} 条 · 单击多选，双击详情',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _history ? Icons.history_rounded : Icons.warning_amber_rounded,
              size: 18,
              color: _history
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                _history
                    ? '入库完成或取消的到货异常归档于此。'
                    : '财务已定案且等待仓库重新审核的行可多选，并在右下角批量按批准量处理；'
                          '处理后先进入 IQC 待检；品质放行并经仓库确认入库前，不进入可用库存。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<MasterColumnDef<ProcurementArrivalException>> get _columns => [
    MasterColumnDef(
      key: 'orderType',
      label: '来源',
      width: 90,
      value: (task) => task.orderType.label,
    ),
    MasterColumnDef(
      key: 'receiptBillNo',
      label: '收货单号',
      width: 170,
      value: (task) => task.receiptBillNo,
    ),
    MasterColumnDef(
      key: 'orderBillNo',
      label: '订货单号',
      width: 170,
      value: (task) => task.orderBillNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 190,
      value: (task) => task.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'goods',
      label: '货品',
      width: 240,
      value: (task) => '${task.goodsCode} ${task.goodsName}'.trim(),
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '仓库',
      width: 140,
      value: (task) => task.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'declaredQty',
      label: '实到数量',
      width: 110,
      type: 'number',
      value: (task) => procurementQty(task.declaredQty),
    ),
    MasterColumnDef(
      key: 'approvedRemainingQty',
      label: '批准剩余',
      width: 110,
      type: 'number',
      value: (task) => procurementQty(task.approvedRemainingQty),
    ),
    MasterColumnDef(
      key: 'acceptedQty',
      label: '财务接收',
      width: 110,
      type: 'number',
      value: (task) =>
          task.acceptedQty > 0 ? procurementQty(task.acceptedQty) : '—',
    ),
    MasterColumnDef(
      key: 'unacceptedQty',
      label: '待退数量',
      width: 110,
      type: 'number',
      value: (task) =>
          task.unacceptedQty > 0 ? procurementQty(task.unacceptedQty) : '—',
    ),
    MasterColumnDef(
      key: 'status',
      label: '当前状态',
      width: 260,
      value: (task) => task.statusLabel,
    ),
    const MasterColumnDef(
      key: 'nextAction',
      label: '下一步',
      width: 160,
      value: _nextActionLabel,
    ),
  ];
}

String _nextActionLabel(ProcurementArrivalException task) {
  if (task.canStockIn) return '仓库按批准量处理';
  return switch (task.status) {
    'PENDING_FINANCE' => '等待财务定案',
    'RETURN_REQUIRED' => '采购退回供应商',
    'RECEIPT_POSTED' => '等待余量退回归档',
    'CLOSED' => '已结束',
    'CANCELED' => '已结束',
    _ => '查看详情',
  };
}

class _WarehouseExceptionDetailDialog extends StatelessWidget {
  const _WarehouseExceptionDetailDialog({
    required this.task,
    required this.stocking,
    this.onStockIn,
  });

  final ProcurementArrivalException task;
  final bool stocking;
  final VoidCallback? onStockIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pendingFinance = task.status == 'PENDING_FINANCE';
    final unit = task.unitName?.trim().isNotEmpty == true
        ? ' ${task.unitName!}'
        : '';
    return AlertDialog(
      title: Row(
        children: [
          UtenStatusBadge(
            label: task.orderType.label,
            type: task.orderType == ProcurementInboundOrderType.purchase
                ? UtenStatusBadgeType.info
                : UtenStatusBadgeType.accent,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              task.receiptBillNo,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: pendingFinance
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.secondaryContainer,
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      pendingFinance
                          ? Icons.block_rounded
                          : Icons.info_outline_rounded,
                      color: pendingFinance
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        task.statusLabel,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: pendingFinance
                              ? theme.colorScheme.onErrorContainer
                              : theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _DetailLine(label: '订货单', value: task.orderBillNo),
              _DetailLine(label: '供应商', value: task.supplierName ?? '—'),
              _DetailLine(label: '仓库', value: task.warehouseName ?? '—'),
              _DetailLine(
                label: '货品',
                value: '${task.goodsCode} ${task.goodsName}'.trim(),
              ),
              if (task.colorName?.isNotEmpty == true)
                _DetailLine(label: '颜色', value: task.colorName!),
              const Divider(height: UtenSpacing.s24),
              _DetailLine(
                label: '实到数量',
                value: procurementQty(task.declaredQty) + unit,
              ),
              _DetailLine(
                label: '批准剩余',
                value: procurementQty(task.approvedRemainingQty) + unit,
              ),
              _DetailLine(
                label: '超量申请',
                value: procurementQty(task.requestedExcessQty) + unit,
              ),
              _DetailLine(
                label: '财务接收',
                value: procurementQty(task.acceptedQty) + unit,
              ),
              _DetailLine(
                label: '待退数量',
                value: procurementQty(task.unacceptedQty) + unit,
              ),
              const Divider(height: UtenSpacing.s24),
              _DetailLine(label: '下一步', value: _nextActionLabel(task)),
              if (task.financeReason?.isNotEmpty == true)
                _DetailLine(label: '财务说明', value: task.financeReason!),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                task.canStockIn
                    ? '只会按财务批准量入库并立应付；未批准余量仍需采购退回供应商。'
                    : '当前仅查看进度；系统不会在审批或退回闭环完成前把异常数量计入库存。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (onStockIn != null)
          UtenButton(
            key: ValueKey('warehouse-arrival-exception-stock-in-${task.id}'),
            size: UtenButtonSize.large,
            icon: Icons.inbox_outlined,
            isLoading: stocking,
            onPressed: stocking ? null : onStockIn,
            child: Text('处理批准量 ${procurementQty(task.acceptedQty)}$unit'),
          ),
      ],
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              '$label：',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
