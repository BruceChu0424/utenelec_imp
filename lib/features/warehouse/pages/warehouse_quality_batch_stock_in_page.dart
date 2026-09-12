// 品质检查结果「批量入库」页（2026-09-12 弹窗改页，对齐品质批量审批页范式）。
//
// 用户口径：入库中心点击入库不要弹窗，都去对应页面。原 _BatchStockInDialog
//（980×560 大弹窗）改为独立页：所选任务的放行切片集中成一张表，默认勾选并按
// 剩余量全额入库；可取消勾选/改小数量（批量部分入库）、改实际库位；底部
// 「确认批量入库」按收货单分组整批同事务提交（每单独立幂等键，重试不重复）。
// 提交失败保留原表单与幂等键，原地重试。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../repositories/warehouse_quality_result_repository.dart';
import '../widgets/warehouse_quality_slice_table.dart';

class WarehouseQualityBatchStockInPage extends ConsumerStatefulWidget {
  const WarehouseQualityBatchStockInPage({super.key, required this.targets});

  /// 列表页多选的待入库任务（receiptType + receiptId 携带即可）。
  final List<WarehouseQualityResultTask> targets;

  @override
  ConsumerState<WarehouseQualityBatchStockInPage> createState() =>
      _WarehouseQualityBatchStockInPageState();
}

class _WarehouseQualityBatchStockInPageState
    extends ConsumerState<WarehouseQualityBatchStockInPage> {
  List<WarehouseQualitySliceDraft>? _drafts;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _canConfirmStockIn {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInConfirm);
  }

  @override
  void dispose() {
    _drafts?.forEach((draft) => draft.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(warehouseQualityResultRepositoryProvider);
      // 并行拉取所选任务的放行切片（串行 await 时 N 张单要排 N 个往返）。
      final fetched = await Future.wait(
        widget.targets.map(
          (task) => repo.detail(task.receiptTypeValue, task.receiptId),
        ),
        eagerError: true,
      );
      final details = [
        for (final detail in fetched)
          if (detail.canConfirm) detail,
      ];
      if (!mounted) return;
      if (details.isEmpty) {
        setState(() {
          _loading = false;
          _error = '所选任务当前均不可确认（可能已由同事处理完，或已无待入库明细）';
        });
        return;
      }
      final drafts = [
        for (final detail in details)
          for (final slice in detail.items)
            WarehouseQualitySliceDraft(
              slice,
              receiptTypeValue: detail.receiptType.apiValue,
              receiptId: detail.receiptId,
              receiptNo: detail.billNo,
            ),
      ];
      _drafts?.forEach((draft) => draft.dispose());
      setState(() {
        _drafts = drafts;
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
        _error = '待入库明细加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  List<WarehouseQualitySliceDraft> get _selected =>
      (_drafts ?? const []).where((draft) => draft.selected).toList();

  Future<void> _submit() async {
    if (_saving || !_canConfirmStockIn) return;
    final selected = _selected;
    if (selected.isEmpty) {
      setState(() => _error = '请至少勾选一条待入库明细');
      return;
    }
    for (final draft in selected) {
      final error = draft.validate();
      if (error != null) {
        setState(() => _error = error);
        return;
      }
    }
    // 按收货单分组成批量命令；每张单独立幂等键（服务端按 用户+键 去重）。
    final byReceipt = <String, List<WarehouseQualitySliceDraft>>{};
    for (final draft in selected) {
      byReceipt.putIfAbsent(draft.receiptKey, () => []).add(draft);
    }
    final entries = <WarehouseQualityBatchConfirmEntry>[];
    for (final mapEntry in byReceipt.entries) {
      final group = mapEntry.value;
      final items = [
        for (final draft in group)
          WarehouseIqcStockInConfirmItem(
            passEventId: draft.slice.passEventId,
            baseQty: double.parse(draft.quantity.text.trim()),
            expectedRemainingBaseQty: draft.slice.remainingBaseQty,
            place: draft.place.text.trim(),
          ),
      ];
      entries.add(
        WarehouseQualityBatchConfirmEntry(
          receiptType: group.first.receiptTypeValue!,
          receiptId: group.first.receiptId!,
          idempotencyKey: businessIdempotencyKey(
            'warehouse-iqc-stock-in',
            '${mapEntry.key}|${warehouseQualitySliceFingerprint(items)}',
          ),
          items: items,
        ),
      );
    }
    // 2026-09-04 用户口径（随弹窗改页保留）：表内可改数量/库位，本页即唯一确认，
    // 不再叠加第二层确认弹窗；成功直接入库不弹结果，只有失败才弹失败结果弹窗。
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(warehouseQualityResultRepositoryProvider)
          .batchConfirm(WarehouseQualityBatchConfirmCommand(batches: entries));
      if (!mounted) return;
      context.appSuccess(
        '已批量入库 ${result.confirmedReceipts} 张收货单 / '
        '${result.confirmedItemCount} 条明细，库存已更新',
      );
      if (context.canPop()) context.pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      await _showFailureDialog(
        error.code == 'CONFLICT'
            ? '${error.message}（整批已回滚，未产生任何入库；请刷新后重新核对）'
            : error.message,
      );
    } catch (_) {
      if (mounted) {
        await _showFailureDialog('批量入库失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保留原批次、数量和库位。网络结果不明时原请求可安全重试，不能先丢弃表单。
  Future<void> _showFailureDialog(String message) async {
    setState(() => _saving = false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量入库失败'),
        content: _MessagePanel(
          message: message,
          icon: Icons.error_outline_rounded,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            size: UtenButtonSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '批量入库 · ${widget.targets.length} 张收货单',
          leading: UtenBackButton(
            color: _saving ? theme.disabledColor : null,
            onPressed: _saving
                ? null
                : () => popOrBackTo(
                    context,
                    defaultPath: RouteName.warehouseQualityResults,
                  ),
          ),
        ),
        body: SafeArea(
          child: _loading
              ? const UtenSkeletonList()
              : AbsorbPointer(
                  absorbing: _saving,
                  child: UtenContentContainer.wide(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _drafts == null || _drafts!.isEmpty
                              ? UtenEmpty.error(
                                  message: _error ?? '所选任务没有可入库明细',
                                  description: '可能已由其他同事处理完毕，请返回刷新。',
                                  actionLabel: '重新加载',
                                  onAction: _load,
                                )
                              : _buildBody(theme),
                        ),
                        _buildBottomBar(theme),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      children: [
        Text(
          '默认勾选全部待入库明细并按剩余量全额入库（批量全部入库）；'
          '可取消勾选或改小数量做批量部分入库。实际库位必填，已按货品建议库位预填。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: UtenSpacing.s8),
        WarehouseQualitySliceTable(
          drafts: _drafts!,
          editable: true,
          saving: _saving,
          onChanged: () => setState(() {}),
          showReceipt: true,
        ),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          _MessagePanel(message: _error!, icon: Icons.error_outline_rounded),
        ],
      ],
    );
  }

  /// 吸底操作栏（对齐品质批量审批页）：已选计数胶囊 + 说明 + 确认批量入库。
  /// 窄屏竖排（横排会在 375px 溢出），大屏同款横排。
  Widget _buildBottomBar(ThemeData theme) {
    final selectedCount = _selected.length;
    final confirm = UtenButton(
      key: const Key('warehouse-quality-batch-confirm'),
      // 「点了就往下走一步」的主动作统一红底白字（全站口径）。
      type: UtenButtonType.danger,
      size: UtenButtonSize.large,
      icon: Icons.move_to_inbox_rounded,
      isLoading: _saving,
      onPressed: _saving || selectedCount == 0 || !_canConfirmStockIn
          ? null
          : _submit,
      onDisabledTap: selectedCount == 0
          ? () => context.appWarning('请至少勾选一条待入库明细')
          : !_canConfirmStockIn
          ? () => context.appWarning('当前账号没有仓库入库确认权限')
          : null,
      child: Text('确认批量入库($selectedCount 条)'),
    );
    final summary = Row(
      children: [
        UtenSelectionSummaryPill(
          key: const Key('warehouse-quality-batch-selected-count'),
          count: selectedCount,
          onClear: selectedCount == 0 ? null : _clearSelection,
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Text(
            '提交成功后增加可用库存；失败时保留本次输入，可直接重试',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
    return UtenBottomActionBar(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                summary,
                const SizedBox(height: UtenSpacing.s8),
                Align(alignment: Alignment.centerRight, child: confirm),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: UtenSpacing.s12),
              confirm,
            ],
          );
        },
      ),
    );
  }

  void _clearSelection() {
    if (_saving) return;
    setState(() {
      for (final draft in _drafts ?? const <WarehouseQualitySliceDraft>[]) {
        draft.selected = false;
      }
    });
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message, required this.icon});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}
