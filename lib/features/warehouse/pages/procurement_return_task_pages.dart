import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';

String procurementReturnTasksLocation(ProcurementInboundOrderType orderType) {
  return Uri(
    path: RouteName.procurementArrivalExceptions,
    queryParameters: {'orderType': orderType.name.toUpperCase()},
  ).toString();
}

class ProcurementReturnTasksPage extends ConsumerStatefulWidget {
  const ProcurementReturnTasksPage({super.key, required this.orderType});

  final ProcurementInboundOrderType orderType;

  @override
  ConsumerState<ProcurementReturnTasksPage> createState() =>
      _ProcurementReturnTasksPageState();
}

class _ProcurementReturnTasksPageState
    extends ConsumerState<ProcurementReturnTasksPage> {
  PagedResult<ProcurementArrivalException>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  final Set<String> _selected = {};
  bool _batchSaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(procurementInboundRepositoryProvider)
          .ownerTasks(page: page, orderType: widget.orderType);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(procurementArrivalReturnCountProvider(widget.orderType));
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待退供应商任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  String get _moduleLabel => widget.orderType.label;

  List<ProcurementArrivalException> get _selectedTasks =>
      _result?.items.where((t) => _selected.contains(t.id)).toList() ??
      const [];

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _selectAll() {
    final items = _result?.items ?? const <ProcurementArrivalException>[];
    setState(() {
      _selected
        ..clear()
        ..addAll(items.map((t) => t.id));
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// 批量确认退回（物流凭证）：超量未入库，确认即记录实物已退并关闭任务，不冲库存/应付。
  Future<void> _batchConfirmReturn() async {
    final tasks = _selectedTasks
        .where((t) => t.canCompleteReturn)
        .toList(growable: false);
    if (tasks.isEmpty) return;
    final noteCtl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量确认退回 ${tasks.length} 条'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将记录以下 ${tasks.length} 条超量已实际退回供应商，'
              '并关闭对应退回任务(超量未入库，不冲库存/应付)。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: noteCtl,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: '退回说明(可选，批量共用)',
                hintText: '例如：供应商司机已带回',
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, noteCtl.text.trim()),
            icon: const Icon(Icons.assignment_return_outlined),
            label: const Text('确认退回'),
          ),
        ],
      ),
    );
    noteCtl.dispose();
    if (note == null || !mounted) return;
    setState(() {
      _batchSaving = true;
      _loading = true;
    });
    final repo = ref.read(procurementInboundRepositoryProvider);
    var ok = 0;
    var fail = 0;
    for (final task in tasks) {
      final returnTask = task.returnTask;
      if (returnTask == null) continue;
      try {
        await repo.completeReturn(
          returnTaskId: returnTask.id,
          expectedVersion: returnTask.version,
          completionNote: note,
        );
        ok++;
      } catch (_) {
        fail++;
      }
    }
    _selected.clear();
    if (!mounted) return;
    ref.invalidate(procurementArrivalReturnCountProvider(widget.orderType));
    ref.invalidate(warehouseArrivalExceptionCountProvider);
    await _load(_result?.page ?? 1);
    if (!mounted) return;
    if (fail == 0) {
      context.appSuccess('已确认退回 $ok 条');
    } else {
      context.appWarning('已确认 $ok 条，$fail 条失败(可能已被处理，请刷新)');
    }
    if (mounted) setState(() => _batchSaving = false);
  }

  String get _defaultBack =>
      widget.orderType == ProcurementInboundOrderType.subcontract
      ? RouteName.subcontract
      : RouteName.purchase;

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '$_moduleLabel待退供应商',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: _defaultBack),
        ),
        actions: [
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && result != null,
            onPressed: _loading ? null : () => _load(1),
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
            : _buildList(result),
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                  vertical: UtenSpacing.s8,
                ),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed:
                          _selectedTasks.length == (_result?.items.length ?? 0)
                          ? _clearSelection
                          : _selectAll,
                      icon: Icon(
                        _selectedTasks.length == (_result?.items.length ?? 0)
                            ? Icons.deselect_rounded
                            : Icons.select_all_rounded,
                      ),
                      label: Text(
                        _selectedTasks.length == (_result?.items.length ?? 0)
                            ? '清空'
                            : '全选本页',
                      ),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed:
                          _batchSaving ||
                              _selectedTasks
                                  .where((t) => t.canCompleteReturn)
                                  .isEmpty
                          ? null
                          : _batchConfirmReturn,
                      icon: const Icon(Icons.assignment_return_outlined),
                      label: Text(
                        '批量确认退回 ${_selectedTasks.where((t) => t.canCompleteReturn).length}',
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildList(PagedResult<ProcurementArrivalException>? value) {
    final result =
        value ??
        const PagedResult<ProcurementArrivalException>(
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
            // 顶部计数卡与任务工作台统一（MetricFilterCards 横幅式单卡，纯展示）。
            MetricFilterCards(
              itemWidth: double.infinity,
              items: [
                MetricFilterCardItem(
                  key: 'pending-return',
                  label: '待退供应商',
                  value: result.total,
                  tone: 'warning',
                  icon: Icons.assignment_return_outlined,
                  description: '仅原$_moduleLabel下单人确认实物已退回，不再决定入库数量。',
                ),
              ],
            ),
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
                  icon: Icons.task_alt_rounded,
                  message: '目前没有待退供应商任务',
                  description: '只显示由您本人下单、且财务未批准入库的$_moduleLabel数量。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ReturnTaskListCard(
                  key: Key('procurement-return-task-${result.items[i].id}'),
                  task: result.items[i],
                  selected: _selected.contains(result.items[i].id),
                  onToggle: () => _toggle(result.items[i].id),
                  onOpen: () => context.push(
                    RoutePath.procurementArrivalException(result.items[i].id),
                  ),
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

class _ReturnTaskListCard extends StatelessWidget {
  const _ReturnTaskListCard({
    super.key,
    required this.task,
    required this.onOpen,
    this.selected = false,
    this.onToggle,
  });

  final ProcurementArrivalException task;
  final VoidCallback onOpen;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qty = task.returnTask?.qty ?? task.unacceptedQty;
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: task.id.isEmpty ? null : onOpen,
        child: Container(
          constraints: const BoxConstraints(minHeight: 136),
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            borderRadius: UtenRadius.lgAll,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (onToggle != null)
                    Checkbox(value: selected, onChanged: (_) => onToggle!()),
                  UtenStatusBadge(
                    label: task.orderType.label,
                    type: task.orderType == ProcurementInboundOrderType.purchase
                        ? UtenStatusBadgeType.info
                        : UtenStatusBadgeType.accent,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      task.orderBillNo,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 28),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text('${task.goodsCode} ${task.goodsName}'.trim()),
              const SizedBox(height: UtenSpacing.s4),
              Text('供应商：${task.supplierName ?? '—'}'),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '待退 ${procurementQty(qty)} ${task.unitName ?? ''}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProcurementReturnTaskDetailPage extends ConsumerStatefulWidget {
  const ProcurementReturnTaskDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<ProcurementReturnTaskDetailPage> createState() =>
      _ProcurementReturnTaskDetailPageState();
}

class _ProcurementReturnTaskDetailPageState
    extends ConsumerState<ProcurementReturnTaskDetailPage> {
  ProcurementArrivalException? _task;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final task = await ref
          .read(procurementInboundRepositoryProvider)
          .ownerTaskDetail(widget.id);
      if (!mounted) return;
      setState(() {
        _task = task;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '退回任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _completeReturn() async {
    final task = _task;
    final returnTask = task?.returnTask;
    if (_saving ||
        task == null ||
        returnTask == null ||
        !task.canCompleteReturn) {
      return;
    }
    final noteController = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认已退回供应商'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '请确认 ${procurementQty(returnTask.qty)} ${task.unitName ?? ''} 已实际交还供应商。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: noteController,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: '退回说明(可选)',
                hintText: '例如：供应商司机已带回',
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () =>
                Navigator.pop(dialogContext, noteController.text.trim()),
            icon: const Icon(Icons.assignment_return_outlined),
            label: const Text('确认已退回'),
          ),
        ],
      ),
    );
    noteController.dispose();
    if (note == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(procurementInboundRepositoryProvider)
          .completeReturn(
            returnTaskId: returnTask.id,
            expectedVersion: returnTask.version,
            completionNote: note,
          );
      if (!mounted) return;
      setState(() => _task = updated);
      ref.invalidate(procurementArrivalReturnCountProvider(updated.orderType));
      ref.invalidate(warehouseArrivalExceptionCountProvider);
      context.appSuccess('已记录退回供应商');
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(error.message);
      if (error.code == 'CONFLICT') await _load();
    } catch (_) {
      if (mounted) context.appError('确认退回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final defaultBack = task == null
        ? RouteName.purchase
        : procurementReturnTasksLocation(task.orderType);
    return Scaffold(
      appBar: UtenAppBar(
        title: '供应商退回详情',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: defaultBack),
        ),
        actions: task == null
            ? null
            : [
                UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            onPressed: _loading || _saving ? null : _load,
          ),
              ],
      ),
      body: SafeArea(
        child: _loading && task == null
            ? const UtenSkeletonList()
            : _error != null && task == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : task == null
            ? UtenEmpty.error(message: '任务不存在或并非由您下单')
            : UtenContentContainer.narrow(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _ReturnStatusBanner(task: task),
                    const SizedBox(height: UtenSpacing.s12),
                    _ReturnFactsCard(task: task),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: task?.canCompleteReturn != true
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: UtenButton(
                    key: const Key('supplier-return-confirm'),
                    size: UtenButtonSize.large,
                    isLoading: _saving,
                    icon: Icons.assignment_return_outlined,
                    onPressed: _saving ? null : _completeReturn,
                    child: const Text('确认退回供应商'),
                  ),
                ),
              ),
            ),
    );
  }
}

class _ReturnStatusBanner extends StatelessWidget {
  const _ReturnStatusBanner({required this.task});

  final ProcurementArrivalException task;

  @override
  Widget build(BuildContext context) {
    final returnTask = task.returnTask;
    final completed = returnTask?.status == 'COMPLETED';
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: completed
            ? Theme.of(context).colorScheme.secondaryContainer
            : Theme.of(context).colorScheme.errorContainer,
        borderRadius: UtenRadius.lgAll,
      ),
      child: Row(
        children: [
          Icon(
            completed
                ? Icons.task_alt_rounded
                : Icons.assignment_return_outlined,
            size: 32,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Text(
              completed ? '已退回供应商' : '财务未批准的数量待退供应商',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReturnFactsCard extends StatelessWidget {
  const _ReturnFactsCard({required this.task});

  final ProcurementArrivalException task;

  @override
  Widget build(BuildContext context) {
    final returnTask = task.returnTask;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${task.goodsCode} ${task.goodsName}'.trim(),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Divider(height: UtenSpacing.s24),
            _Fact(
              label: '来源订货单',
              value: '${task.orderType.label} ${task.orderBillNo}',
            ),
            _Fact(label: '收货单', value: task.receiptBillNo),
            _Fact(label: '供应商', value: task.supplierName ?? '—'),
            _Fact(label: '仓库', value: task.warehouseName ?? '—'),
            _Fact(
              label: '实际到货',
              value:
                  '${procurementQty(task.declaredQty)} ${task.unitName ?? ''}',
            ),
            _Fact(
              label: '财务批准入库',
              value:
                  '${procurementQty(task.acceptedQty)} ${task.unitName ?? ''}',
            ),
            _Fact(
              label: '应退供应商',
              value:
                  '${procurementQty(returnTask?.qty ?? task.unacceptedQty)} ${task.unitName ?? ''}',
            ),
            if (returnTask?.completionNote?.isNotEmpty == true)
              _Fact(label: '退回说明', value: returnTask!.completionNote!),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text('$label：')),
          Expanded(child: Text(value)),
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
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_left_rounded,
          onPressed: !loading && page > 1 ? () => onPage(page - 1) : null,
          child: const Text('上一页'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Text('第 $page / $totalPages 页'),
        ),
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_right_rounded,
          onPressed: !loading && page < totalPages
              ? () => onPage(page + 1)
              : null,
          child: const Text('下一页'),
        ),
      ],
    );
  }
}
