import 'package:flutter/material.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';

/// 销售订货单财务确认工作台（V294 闸门，V300 驳回，批量确认）。
///
/// 桌面端使用系统自研表格：单击选择、双击进入审核详情、复选多选和批量确认；
/// 紧凑端使用可勾选的密集列表，并保留显式详情按钮，不把双击作为唯一入口。
class FinanceSalesOrderConfirmationPage extends ConsumerStatefulWidget {
  const FinanceSalesOrderConfirmationPage({
    super.key,
    this.changesOnly = false,
  });

  final bool changesOnly;

  @override
  ConsumerState<FinanceSalesOrderConfirmationPage> createState() =>
      _FinanceSalesOrderConfirmationPageState();
}

class _FinanceSalesOrderConfirmationPageState
    extends ConsumerState<FinanceSalesOrderConfirmationPage> {
  static const int _maxBatchSize = 100;

  SalesOrderFinancePendingPage? _result;
  bool _loading = false;
  bool _batchBusy = false;
  String? _error;
  String _keyword = '';
  int _requestVersion = 0;
  final Set<String> _selectedIds = <String>{};
  final Map<String, SalesOrderFinancePendingItem> _selectedItems =
      <String, SalesOrderFinancePendingItem>{};
  SalesOrderFinancePendingItem? _activeItem;
  TaskClaimSession? _batchClaim;

  @override
  void dispose() {
    ++_requestVersion;
    _batchClaim?.releaseAll().ignore();
    super.dispose();
  }

  /// 分段视图：false=待确认（默认）；true=已驳回。
  bool _showRejected = false;

  bool get _canView {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.salesOrderFinanceView);
  }

  bool get _canConfirm {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.salesOrderFinanceConfirm);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    if (!_canView) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .pending(
            page: page,
            rejected: _showRejected,
            keyword: _keyword.isEmpty ? null : _keyword,
            changesOnly: widget.changesOnly,
          );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        for (final item in result.items) {
          if (_selectedIds.contains(item.orderId)) {
            _selectedItems[item.orderId] = item;
          }
        }
        if (_activeItem != null &&
            !result.items.any((item) => item.orderId == _activeItem!.orderId)) {
          _activeItem = null;
        }
      });
      ref.invalidate(salesOrderFinanceConfirmationCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待确认任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _switchTab(bool rejected) {
    if (rejected == _showRejected) return;
    ++_requestVersion;
    setState(() {
      _showRejected = rejected;
      _result = null;
      _error = null;
      _clearSelectionState();
    });
    _load(1);
  }

  void _clearSelectionState() {
    _selectedIds.clear();
    _selectedItems.clear();
    _activeItem = null;
  }

  void _clearSelection() {
    if (_selectedIds.isEmpty) return;
    setState(_clearSelectionState);
  }

  Future<void> _refreshCurrent() async {
    setState(_clearSelectionState);
    await _load(_result?.page ?? 1);
  }

  void _invalidateSearchRequest(String _) {
    ++_requestVersion;
  }

  void _applyKeyword(String value) {
    final next = value.trim();
    if (next == _keyword) return;
    setState(() {
      _keyword = next;
      _result = null;
      _error = null;
      _clearSelectionState();
    });
    _load(1);
  }

  void _setSelectedIds(Set<String> next) {
    if (_batchClaim != null) return;
    if (next.length > _maxBatchSize) {
      context.appWarning('单次最多选择 $_maxBatchSize 笔订单');
      return;
    }
    final pageItems = {
      for (final item
          in _result?.items ?? const <SalesOrderFinancePendingItem>[])
        item.orderId: item,
    };
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
      _selectedItems.removeWhere((id, _) => !next.contains(id));
      for (final id in next) {
        final item = pageItems[id];
        if (item != null) _selectedItems[id] = item;
      }
    });
  }

  void _toggleSelected(SalesOrderFinancePendingItem item) {
    final next = Set<String>.of(_selectedIds);
    if (!next.add(item.orderId)) next.remove(item.orderId);
    _setSelectedIds(next);
  }

  void _selectCurrentPage() {
    final next = Set<String>.of(_selectedIds)
      ..addAll(
        (_result?.items ?? const <SalesOrderFinancePendingItem>[])
            .where((item) => item.canConfirm)
            .map((item) => item.orderId),
      );
    _setSelectedIds(next);
  }

  /// 打开财务审核详情页；确认/驳回后返回 true → 刷新当前视图。
  Future<void> _open(SalesOrderFinancePendingItem item) async {
    final route = Uri.parse(item.detailRoute).replace(
      queryParameters: {
        'returnTo': widget.changesOnly
            ? '/finance/sales-order-changes'
            : '/finance/sales-order-confirmations',
      },
    );
    final changed = await context.push<bool>(route.toString());
    if (changed == true && mounted) {
      setState(() {
        _selectedIds.remove(item.orderId);
        _selectedItems.remove(item.orderId);
      });
      _load(_result?.page ?? 1);
    }
  }

  List<SalesOrderFinancePendingItem> get _selectedTasks {
    final tasks = _selectedItems.values.toList(growable: false);
    tasks.sort((a, b) => a.billNo.compareTo(b.billNo));
    return tasks;
  }

  Future<void> _confirmSelected() async {
    if (_batchBusy || _batchClaim != null) return;
    if (_showRejected) {
      context.appWarning('已驳回订单须由销售修订并重新审核后才能确认');
      return;
    }
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
      return;
    }
    final tasks = _selectedTasks;
    if (tasks.isEmpty) {
      context.appWarning('请先选择需要确认的订单');
      return;
    }

    final claim = financeReviewClaim(
      ProviderScope.containerOf(context, listen: false),
    );
    _batchClaim = claim;
    setState(() => _batchBusy = true);
    try {
      await claim.claimAll(
        'SALES_ORDER_FINANCE_CONFIRM',
        tasks.map((task) => task.orderId),
      );
      if (!mounted || !claim.isReady) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '整批未取得审核占用，请重试');
        }
        return;
      }
      for (final task in tasks) {
        final snapshot = await ref
            .read(salesOrderFinanceConfirmationRepositoryProvider)
            .review(task.orderId);
        if (!mounted || !claim.isReady) return;
        if (snapshot.financeReviewRevision != task.financeReviewRevision ||
            snapshot.financeConfirmed ||
            snapshot.financeRejected) {
          context.appWarning('订单内容或状态已变化，请刷新并重新核对后再批量审核');
          return;
        }
      }

      setState(() => _batchBusy = false);
      final controller = TextEditingController();
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('批量确认 ${tasks.length} 笔销售订单'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const UtenReviewerResponsibilityNotice(
                    actionLabel: '销售订单批量财务确认',
                    description: '本次选择将作为一个原子审核事务提交；任一订单校验失败时全部不放行。',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  const Text(
                    '确认只放行计划部可见与排产，不代表已收款，也不会在此建立正式应收。'
                    '请确认下列订单已逐笔核对金额、客户应收和发运策略：',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(
                            dialogContext,
                          ).colorScheme.outlineVariant,
                        ),
                        borderRadius: UtenRadius.mdAll,
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: Theme.of(
                            dialogContext,
                          ).colorScheme.outlineVariant,
                        ),
                        itemBuilder: (context, index) {
                          final item = tasks[index];
                          return ListTile(
                            dense: true,
                            title: Text(
                              item.billNo,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(item.clientName ?? '未标注客户'),
                            trailing: Text(
                              _orderAmount(item),
                              textAlign: TextAlign.end,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    key: const Key('sales-order-finance-batch-remark'),
                    controller: controller,
                    maxLength: 500,
                    maxLines: 2,
                    decoration: UtenInputDecoration(
                      const InputDecoration(
                        labelText: '统一确认备注(选填)',
                        border: OutlineInputBorder(),
                      ),
                      info:
                          '${workflowFieldText(context).workflowFinanceReviewHint} 该备注写入本次选中的每笔订单。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FinanceReviewClaimButton(
              key: const Key('sales-order-finance-batch-submit'),
              claim: claim,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text('确认通过 ${tasks.length} 笔'),
            ),
          ],
        ),
      );
      final remark = controller.text;
      Future<void>.delayed(
        const Duration(milliseconds: 300),
        controller.dispose,
      );
      if (approved != true || !mounted) return;

      setState(() => _batchBusy = true);
      try {
        if (!await claim.validateForDecision() || !mounted) {
          if (mounted) {
            context.appWarning(claim.failureMessage ?? '审核占用已失效，请重新核对');
          }
          return;
        }
        await ref
            .read(salesOrderFinanceConfirmationRepositoryProvider)
            .confirmBatch(
              tasks.map((item) => item.orderId),
              remark: remark,
              expectedRevisions: {
                for (final task in tasks)
                  task.orderId: task.financeReviewRevision,
              },
              expectedClaimIds: {
                for (final task in tasks)
                  task.orderId: claim.claimIdFor(
                    'SALES_ORDER_FINANCE_CONFIRM',
                    task.orderId,
                  )!,
              },
            );
        if (!mounted) return;
        context.appSuccess('已批量确认 ${tasks.length} 笔，计划部可接手排产');
        final page = _result?.page ?? 1;
        setState(_clearSelectionState);
        ref.invalidate(salesOrderFinanceConfirmationCountProvider);
        await _load(page);
      } on ApiException catch (error) {
        if (mounted) {
          context.appError('批量确认未提交，所有订单保持原状态：${error.message}');
        }
      } catch (_) {
        if (mounted) {
          context.appError('批量确认失败，所有订单保持原状态，请稍后重试');
        }
      }
    } on ApiException catch (error) {
      if (mounted) context.appError('整批尚未提交：${error.message}');
    } catch (_) {
      if (mounted) context.appError('未能核对整批审核占用和内容，请重新选择后重试');
    } finally {
      await claim.releaseAll();
      if (identical(_batchClaim, claim)) _batchClaim = null;
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final returnPath = widget.changesOnly
        ? '/finance/sales-order-changes'
        : '/finance/sales-order-confirmations';
    ref.listen(listRefreshTickProvider('finance:sales-order:$returnPath'), (
      _,
      _,
    ) {
      if (mounted) _refreshCurrent();
    });
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceView);
    final canConfirm =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceConfirm);
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.changesOnly ? '销售订单修改' : '销售订单财务确认',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: '/finance'),
        ),
        actions: allowed
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: UtenButton(
                    key: const Key('sales-order-finance-confirm-refresh'),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    isLoading: _loading || _batchBusy,
                    onPressed: _loading || _batchBusy ? null : _refreshCurrent,
                    child: const Text('刷新'),
                  ),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: !allowed
            ? UtenEmpty.error(
                message: '无权查看销售订单财务确认任务',
                description:
                    '只有被授权的财务人员可以进入（权限设置中授予 sales_order_finance:view）。',
              )
            : _loading && _result == null
            ? const UtenSkeletonList()
            : _error != null && _result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildBody(context, canConfirm: canConfirm),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: allowed && canConfirm && !_showRejected
          ? _floatingSelectionActions()
          : null,
    );
  }

  Widget _floatingSelectionActions() {
    final selectedCount = _selectedIds.length;
    final selectedItem = selectedCount == 1
        ? _selectedItems[_selectedIds.single]
        : null;
    final canConfirmNow = selectedCount > 0 && !_loading && !_batchBusy;
    const disabledReason = '请先选择至少一笔待确认订单';
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          key: const Key('sales-order-finance-open-selected'),
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          icon: Icons.open_in_new_rounded,
          onPressed: selectedItem == null || _batchBusy
              ? null
              : () => _open(selectedItem),
          onDisabledTap: selectedCount > 1
              ? () => context.appWarning('查看详情时只能选择一笔订单')
              : null,
          child: const Text('查看详情'),
        ),
        Tooltip(
          message: canConfirmNow ? '批量确认所选订单' : disabledReason,
          child: UtenButton(
            key: const Key('sales-order-finance-batch-confirm'),
            size: UtenButtonSize.large,
            icon: Icons.fact_check_outlined,
            isLoading: _batchBusy,
            onPressed: canConfirmNow ? _confirmSelected : null,
            onDisabledTap: canConfirmNow
                ? null
                : () => context.appWarning(disabledReason),
            child: Text(selectedCount == 0 ? '批量确认' : '批量确认($selectedCount)'),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, {required bool canConfirm}) {
    final result =
        _result ??
        const SalesOrderFinancePendingPage(
          items: <SalesOrderFinancePendingItem>[],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final expanded = breakpointForWidth(
              constraints.maxWidth,
            ).isExpanded;
            return expanded
                ? _desktopWorkbench(context, result, canConfirm: canConfirm)
                : _compactWorkbench(context, result, canConfirm: canConfirm);
          },
        ),
      ),
    );
  }

  Widget _desktopWorkbench(
    BuildContext context,
    SalesOrderFinancePendingPage result, {
    required bool canConfirm,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _filters(theme),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _InlineError(message: _error!, onRetry: () => _load(result.page)),
        ],
        if (_batchBusy) ...[
          const SizedBox(height: UtenSpacing.s8),
          const LinearProgressIndicator(
            key: Key('sales-order-finance-batch-progress'),
          ),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: AbsorbPointer(
            absorbing: _batchBusy,
            child: MasterDataTableView<SalesOrderFinancePendingItem>(
              key: const Key('sales-order-finance-desktop-table'),
              selectable: !_showRejected && canConfirm,
              idOf: (item) => item.orderId,
              selectedIds: _selectedIds,
              onSelectedIdsChanged: _setSelectedIds,
              // 传空动作只启用共享选择摘要；真正业务动作由页面右下 FAB 渲染。
              batchActionsBuilder: !_showRejected && canConfirm
                  ? (_, _) => const <Widget>[]
                  : null,
              columns: _columns(),
              items: result.items,
              facets: const <String, List<MasterFacetBucket>>{},
              nullCounts: const <String, int>{},
              filters: const <String, String?>{},
              onFilterChanged: (_, _) {},
              onRowTap: _open,
              onSelectionChanged: canConfirm
                  ? null
                  : (item) => setState(() => _activeItem = item),
              onSelectionCleared: canConfirm
                  ? null
                  : () => setState(() => _activeItem = null),
              rowMenuBuilder: (item) => [
                UtenMenuItem(
                  label: '查看审核详情',
                  icon: Icons.open_in_new_rounded,
                  onTap: () => _open(item),
                ),
              ],
              rowColor: (item) => _rowColor(theme, item),
              isLoading: _loading,
              emptyMessage: _emptyMessage,
              currentPage: result.page,
              totalPages: result.totalPages,
              onPageChange: _load,
              toolbarActions: canConfirm
                  ? null
                  : [
                      UtenButton(
                        key: const Key('sales-order-finance-open-selected'),
                        size: UtenButtonSize.large,
                        type: UtenButtonType.secondary,
                        icon: Icons.open_in_new_rounded,
                        onPressed: _activeItem == null || _batchBusy
                            ? null
                            : () => _open(_activeItem!),
                        child: const Text('查看选中详情'),
                      ),
                    ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _compactWorkbench(
    BuildContext context,
    SalesOrderFinancePendingPage result, {
    required bool canConfirm,
  }) {
    final selectable = !_showRejected && canConfirm;
    return RefreshIndicator(
      onRefresh: () async => _refreshCurrent(),
      child: ListView(
        key: const Key('sales-order-finance-mobile-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: selectable ? 96 : UtenSpacing.s24),
        children: [
          _filters(Theme.of(context)),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            _InlineError(message: _error!, onRetry: () => _load(result.page)),
          ],
          if (selectable) ...[
            const SizedBox(height: UtenSpacing.s12),
            _mobileSelectionBar(result),
          ],
          if (_batchBusy)
            const Padding(
              padding: EdgeInsets.only(top: UtenSpacing.s8),
              child: LinearProgressIndicator(
                key: Key('sales-order-finance-batch-progress'),
              ),
            ),
          const SizedBox(height: UtenSpacing.s12),
          if (result.items.isEmpty)
            SizedBox(
              height: 320,
              child: UtenEmpty(
                icon: _showRejected
                    ? Icons.undo_rounded
                    : Icons.task_alt_rounded,
                message: _emptyMessage,
                description: _emptyDescription,
              ),
            )
          else
            for (final item in result.items) ...[
              AbsorbPointer(
                absorbing: _batchBusy,
                child: _CompactTaskRow(
                  key: Key('sales-order-finance-task-${item.orderId}'),
                  item: item,
                  selected: selectable && _selectedIds.contains(item.orderId),
                  onSelected: selectable ? () => _toggleSelected(item) : null,
                  onOpen: () => _open(item),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          if (result.totalPages > 1)
            _Pager(
              page: result.page,
              totalPages: result.totalPages,
              loading: _loading || _batchBusy,
              onPage: _load,
            ),
        ],
      ),
    );
  }

  List<MasterColumnDef<SalesOrderFinancePendingItem>> _columns() => [
    MasterColumnDef(
      key: 'billNo',
      label: '销售单号',
      width: 172,
      value: (item) => item.billNo,
    ),
    MasterColumnDef(
      key: 'clientName',
      label: '客户',
      width: 180,
      value: (item) => item.clientName ?? '—',
    ),
    MasterColumnDef(
      key: 'sellerName',
      label: '业务员',
      width: 112,
      value: (item) => item.sellerName ?? '—',
    ),
    const MasterColumnDef(
      key: 'totalOriginal',
      label: '订单金额',
      width: 150,
      type: 'money',
      value: _orderAmount,
    ),
    MasterColumnDef(
      key: 'clientOutstanding',
      label: '客户应收（本币）',
      width: 150,
      type: 'money',
      value: (item) => item.clientOutstanding ?? '—',
    ),
    MasterColumnDef(
      key: 'deliverDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      value: (item) => item.deliverDate ?? '未定',
    ),
    MasterColumnDef(
      key: 'shipmentPolicy',
      label: '发运策略',
      width: 148,
      value: (item) => _shipmentPolicyLabel(item.shipmentPolicy),
    ),
    MasterColumnDef(
      key: 'urgency',
      label: '紧迫度',
      width: 104,
      value: (item) => _urgencyLabel(_urgencyFor(item)),
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '明细行',
      width: 84,
      type: 'number',
      value: (item) => '${item.itemCount}',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '开单日期',
      width: 120,
      type: 'date',
      value: (item) => item.billDate ?? '—',
    ),
    MasterColumnDef(
      key: 'status',
      label: '审核状态 / 原因',
      width: 260,
      value: (item) => item.financeRejected
          ? '已驳回：${item.financeRejectedReason ?? '未注明原因'}'
          : item.changeCount > 0
          ? '修改后待确认 · ${item.changeCount} 次变更'
          : '待财务确认',
      cellColor: (context, item) =>
          item.changeCount > 0 && !item.financeRejected
          ? (Theme.of(context).brightness == Brightness.dark
                ? UtenColors.warning.withValues(alpha: 0.18)
                : UtenColors.warningBg)
          : null,
    ),
  ];

  Widget _filters(ThemeData theme) {
    final count = ref.watch(
      salesOrderFinanceQueueCountProvider(widget.changesOnly),
    );
    final pendingCount = count.isLoading || count.hasError
        ? null
        : count.valueOrNull;
    // 全平台统一筛选工具条：分段 + 胶囊搜索框（窄屏自动换行）。
    // 整批提交期间不响应分段切换（原 onSelectionChanged 置空的语义收进回调守卫）。
    return UtenFilterToolbar<bool>(
      segmentsKey: const Key('sales-order-finance-tabs'),
      searchKey: const Key('sales-order-finance-search'),
      compactBreakpoint: UtenBreakpoints.mediumStart,
      segments: [
        UtenFilterSegment(value: false, label: '待确认', count: pendingCount),
        const UtenFilterSegment(value: true, label: '已驳回'),
      ],
      selected: {_showRejected},
      onSelectionChanged: (value) {
        if (_batchBusy) return;
        _switchTab(value);
      },
      searchHint: '搜索单号 / 客户 / 业务员',
      initialSearchValue: _keyword,
      onSearchInputChanged: _invalidateSearchRequest,
      onSearchChanged: _applyKeyword,
      trailing: Text(
        '单击选择 · 双击查看详情',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _mobileSelectionBar(SalesOrderFinancePendingPage result) {
    final theme = Theme.of(context);
    final selectedCount = _selectedIds.length;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '已选择 $selectedCount 笔订单',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        decoration: BoxDecoration(
          color: selectedCount == 0
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primaryContainer.withValues(alpha: 0.42),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
              child: Text(
                '已选 $selectedCount 笔',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            UtenButton(
              size: UtenButtonSize.small,
              type: UtenButtonType.secondary,
              onPressed: _batchBusy || result.items.isEmpty
                  ? null
                  : _selectCurrentPage,
              child: const Text('全选本页'),
            ),
            UtenButton(
              size: UtenButtonSize.small,
              type: UtenButtonType.ghost,
              onPressed: _batchBusy || selectedCount == 0
                  ? null
                  : _clearSelection,
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
  }

  Color? _rowColor(ThemeData theme, SalesOrderFinancePendingItem item) {
    if (item.financeRejected) {
      return theme.colorScheme.errorContainer.withValues(alpha: 0.30);
    }
    return switch (_urgencyFor(item)) {
      _DeliverUrgency.overdue => theme.colorScheme.errorContainer.withValues(
        alpha: 0.24,
      ),
      _DeliverUrgency.soon => theme.colorScheme.tertiaryContainer.withValues(
        alpha: 0.24,
      ),
      _ => null,
    };
  }

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配“$_keyword”的订单';
    return _showRejected ? '没有被财务驳回的销售订单' : '目前没有待财务确认的销售订单';
  }

  String get _emptyDescription => _showRejected
      ? '被驳回的订单会出现在这里；销售修订并重新审核后会回到待确认。'
      : '销售订单审核后会进入这里；确认后计划部才可见并排产。';
}

class _CompactTaskRow extends StatelessWidget {
  const _CompactTaskRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  final SalesOrderFinancePendingItem item;
  final bool selected;
  final VoidCallback? onSelected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urgency = _urgencyFor(item);
    final accent = item.financeRejected || urgency == _DeliverUrgency.overdue
        ? theme.colorScheme.error
        : urgency == _DeliverUrgency.soon
        ? theme.colorScheme.tertiary
        : theme.colorScheme.outlineVariant;
    return Semantics(
      container: true,
      selected: selected,
      label:
          '${item.billNo}，客户 ${item.clientName ?? '未标注'}，${_orderAmount(item)}',
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.40)
            : theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelected ?? onOpen,
          child: Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.mdAll,
              border: Border(
                left: BorderSide(width: 3, color: accent),
                top: BorderSide(color: theme.colorScheme.outlineVariant),
                right: BorderSide(color: theme.colorScheme.outlineVariant),
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (onSelected != null) ...[
                  Checkbox(
                    value: selected,
                    semanticLabel: '选择订单 ${item.billNo}',
                    onChanged: (_) => onSelected!(),
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.billNo,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            _orderAmount(item),
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '${item.clientName ?? '未标注客户'} · ${item.sellerName ?? '未标注业务员'}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '交货 ${item.deliverDate ?? '未定'} · '
                        '${_urgencyLabel(urgency)} · '
                        '${item.itemCount} 行明细 · '
                        '应收（本币）${item.clientOutstanding ?? '—'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (item.changeCount > 0 && !item.financeRejected) ...[
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '订单修改 ${item.changeCount} 次：请在详情页「修改清单」'
                          '复核每行 以前→现在 数量',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: UtenColors.warningText,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (item.financeRejected) ...[
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '驳回原因：${item.financeRejectedReason ?? '未注明原因'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  key: Key('sales-order-finance-review-${item.orderId}'),
                  size: UtenButtonSize.small,
                  type: UtenButtonType.secondary,
                  icon: Icons.open_in_new_rounded,
                  onPressed: onOpen,
                  child: const Text('详情'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _DeliverUrgency { none, normal, soon, overdue }

_DeliverUrgency _urgencyFor(SalesOrderFinancePendingItem item) {
  final raw = item.deliverDate;
  if (raw == null || raw.isEmpty) return _DeliverUrgency.none;
  final date = DateTime.tryParse(raw);
  if (date == null) return _DeliverUrgency.none;
  final today = DateTime.now();
  final diff = DateTime(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime(today.year, today.month, today.day)).inDays;
  if (diff < 0) return _DeliverUrgency.overdue;
  if (diff <= 3) return _DeliverUrgency.soon;
  return _DeliverUrgency.normal;
}

String _urgencyLabel(_DeliverUrgency urgency) => switch (urgency) {
  _DeliverUrgency.overdue => '已逾期',
  _DeliverUrgency.soon => '临近交货',
  _DeliverUrgency.normal => '正常',
  _DeliverUrgency.none => '未定',
};

String _orderAmount(SalesOrderFinancePendingItem item) {
  final currency =
      financeCurrencyDisplayLabel(
        name: item.currencyName,
        code: item.currencyCode,
      ) ??
      '订单币种';
  return '$currency ${item.totalOriginal ?? '—'}';
}

String _shipmentPolicyLabel(String? policy) => switch (policy) {
  'ALLOW_PARTIAL' => '允许分批发货',
  'REQUIRE_COMPLETE' => '整单齐套后发货',
  'CUSTOMER_CONFIRM' => '客户确认后分批',
  'LEGACY' || null || '' => '历史未指定',
  _ => '未知策略（$policy）',
};

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.lgAll,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
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
        IconButton(
          tooltip: '上一页',
          onPressed: loading || page <= 1 ? null : () => onPage(page - 1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text('$page / $totalPages'),
        IconButton(
          tooltip: '下一页',
          onPressed: loading || page >= totalPages
              ? null
              : () => onPage(page + 1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}
