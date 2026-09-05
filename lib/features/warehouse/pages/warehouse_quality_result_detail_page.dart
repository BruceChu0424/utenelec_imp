import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../models/warehouse_iqc_return.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../providers/warehouse_quality_result_count_provider.dart';
import '../repositories/warehouse_iqc_return_repository.dart';
import '../repositories/warehouse_iqc_stock_in_repository.dart';
import '../repositories/warehouse_quality_result_repository.dart';
import '../widgets/warehouse_quality_merged_table.dart';
import '../widgets/warehouse_quality_slice_table.dart';
import '../widgets/warehouse_inbound_allocation_view.dart';

/// 品质检查结果详情（完整页面，非弹窗）：上方单据信息卡，随后**合并明细表**——
/// 每个货品行一列到底：判定结果（合格绿对勾 / 不合格红禁止 / 部分合格黄警告 /
/// 待检蓝沙漏，整行浅底色随判定）+ 收货/合格/不合格数量 + 待入库余量（有待入库
/// 放行切片的行可勾选，就地输入本次实收与实际库位）+ 检验状态 + 放行信息；
/// 再往下是不合格退回案件（就地登记）与只读入库历史。
class WarehouseQualityResultDetailPage extends ConsumerStatefulWidget {
  const WarehouseQualityResultDetailPage({
    super.key,
    required this.receiptType,
    required this.receiptId,
  });

  final String receiptType;
  final String receiptId;

  @override
  ConsumerState<WarehouseQualityResultDetailPage> createState() =>
      _WarehouseQualityResultDetailPageState();
}

class _WarehouseQualityResultDetailPageState
    extends ConsumerState<WarehouseQualityResultDetailPage> {
  WarehouseQualityResultDetail? _detail;
  List<WarehouseQualitySliceDraft> _drafts = const [];
  final UtenEditableGridController<WarehouseQualityMergedRow> _grid =
      UtenEditableGridController<WarehouseQualityMergedRow>();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _conflictMessage;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    _grid.dispose();
    super.dispose();
  }

  bool get _hasConfirmPermission {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInConfirm);
  }

  bool get _canRecordReturn {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.procurementIqcRejectionRecordReturn);
  }

  bool get _canConfirm => _detail?.canConfirm == true && _hasConfirmPermission;

  Future<void> _load({bool preserveInputs = false}) async {
    final version = ++_requestVersion;
    final snapshots = preserveInputs
        ? {for (final draft in _drafts) draft.slice.passEventId: draft.snapshot}
        : const <String, WarehouseQualitySliceSnapshot>{};
    setState(() => _loading = true);
    try {
      final detail = await ref
          .read(warehouseQualityResultRepositoryProvider)
          .detail(widget.receiptType, widget.receiptId);
      if (!mounted || version != _requestVersion) return;
      final nextDrafts = [
        for (final slice in detail.items)
          WarehouseQualitySliceDraft(
            slice,
            receiptTypeValue: detail.receiptType.apiValue,
            receiptId: detail.receiptId,
            receiptNo: detail.billNo,
            snapshot: snapshots[slice.passEventId],
          ),
      ];
      final previous = _drafts;
      setState(() {
        _detail = detail;
        _drafts = nextDrafts;
        _grid.replaceAll(_buildRows(detail, nextDrafts));
        _loading = false;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final draft in previous) {
          draft.dispose();
        }
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '检查结果详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 合并明细表行集：每条检查明细行 × 它的待入库放行切片——有待入库切片的行
  /// 按切片逐行展开（可勾选办理），无切片的行单行只读展示。
  static List<WarehouseQualityMergedRow> _buildRows(
    WarehouseQualityResultDetail detail,
    List<WarehouseQualitySliceDraft> drafts,
  ) {
    final byLine = <String, List<WarehouseQualitySliceDraft>>{};
    for (final draft in drafts) {
      byLine.putIfAbsent(draft.slice.inspectionItemId, () => []).add(draft);
    }
    final rows = <WarehouseQualityMergedRow>[];
    for (final line in detail.lines) {
      final slices = byLine[line.inspectionItemId] ?? const [];
      if (slices.isEmpty) {
        rows.add(WarehouseQualityMergedRow(line: line));
        continue;
      }
      for (var i = 0; i < slices.length; i++) {
        rows.add(
          WarehouseQualityMergedRow(
            line: line,
            draft: slices[i],
            sliceOrdinal: i + 1,
            sliceTotal: slices.length,
          ),
        );
      }
    }
    return rows;
  }

  Future<void> _confirmStockIn() async {
    if (_saving || !_canConfirm) return;
    final selected = _drafts.where((draft) => draft.selected).toList();
    if (selected.isEmpty) {
      context.appWarning('请至少勾选一条品质放行明细');
      return;
    }
    for (final draft in selected) {
      final error = draft.validate();
      if (error != null) {
        context.appWarning(error);
        return;
      }
    }
    final items = [
      for (final draft in selected)
        WarehouseIqcStockInConfirmItem(
          passEventId: draft.slice.passEventId,
          baseQty: double.parse(draft.quantity.text.trim()),
          expectedRemainingBaseQty: draft.slice.remainingBaseQty,
          place: draft.place.text.trim(),
        ),
    ];
    final fingerprint = warehouseQualitySliceFingerprint(items);
    final key = businessIdempotencyKey('warehouse-iqc-stock-in', fingerprint);
    final ownRelease = _detail?.containsOwnRelease == true;
    final sections = [
      for (final draft in selected)
        WarehouseInboundAllocationSection(
          id: draft.slice.passEventId,
          goodsLabel: draft.slice.goodsLabel,
          quantity: double.parse(draft.quantity.text.trim()),
          unitName: draft.slice.unitName,
          sourceOrderNo: draft.slice.sourceOrderNo,
          allocations: draft.slice.expectedAllocations,
        ),
    ];
    final approved = await showWarehouseInboundAllocationConfirmDialog(
      context,
      title: '确认 IQC 合格品入库',
      actionLabel: '仓库实物入库确认',
      ownRelease: ownRelease,
      sections: sections,
      description: ownRelease
          ? '注意：本单品质放行由当前账号执行（单人兼任品质与仓库）。'
                '请再次核对实物数量与实际库位后确认；提交成功后才会增加可用库存。'
          : '本次将确认 ${items.length} 条品质放行切片的实收数量与实际库位，'
                '提交成功后才会增加可用库存并推进对应生产供给。',
    );
    if (!approved || !mounted) return;
    setState(() {
      _saving = true;
      _conflictMessage = null;
    });
    try {
      final result = await ref
          .read(warehouseIqcStockInRepositoryProvider)
          .confirm(
            widget.receiptType,
            widget.receiptId,
            WarehouseIqcStockInConfirmCommand(
              idempotencyKey: key,
              items: items,
            ),
          );
      if (!mounted) return;
      ref.invalidate(warehouseQualityResultPendingCountProvider);
      setState(() => _saving = false);
      final allocationsByPassEvent =
          <String, List<WarehouseInboundAllocation>>{};
      for (final allocation in result.allocations) {
        final passEventId = allocation.passEventId;
        if (passEventId == null) continue;
        allocationsByPassEvent
            .putIfAbsent(passEventId, () => [])
            .add(allocation);
      }
      await showWarehouseInboundAllocationResultDialog(
        context,
        title: result.replayed ? '入库结果 · 安全重放' : '入库完成 · 实际去向',
        description: result.replayed
            ? '该命令此前已经完成；以下为服务端重放的 ${result.confirmedCount} 条实际分配事实。'
            : '已确认入库 ${result.confirmedCount} 条品质放行明细；以下为本次实际形成的预留与公共库存。',
        sections: [
          for (final section in sections)
            WarehouseInboundAllocationSection(
              id: section.id,
              goodsLabel: section.goodsLabel,
              quantity: section.quantity,
              unitName: section.unitName,
              sourceOrderNo: section.sourceOrderNo,
              allocations: allocationsByPassEvent[section.id] ?? const [],
            ),
        ],
      );
      if (!mounted) return;
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        final message = '${error.message}；已保留当前输入，请按刷新后的余量重新核对。';
        context.appWarning(message, force: true);
        await _load(preserveInputs: true);
        if (mounted) {
          setState(() => _conflictMessage = message);
        }
      } else {
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) {
        context.appError('入库确认失败，当前输入已保留，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _recordReturn(WarehouseQualityRejectionCase rejection) async {
    if (_saving || !_canRecordReturn || !rejection.canRecordReturn) return;
    final command = await showDialog<WarehouseIqcRecordReturnCommand>(
      context: context,
      builder: (_) => _RecordReturnDialog(rejection: rejection),
    );
    if (command == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(warehouseIqcReturnRepositoryProvider)
          .recordReturn(rejection.id, command);
      if (!mounted) return;
      context.appSuccess('实物退回凭证已登记');
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(error.message);
      if (error.code == 'CONFLICT') await _load();
    } catch (_) {
      if (mounted) context.appError('实物退回登记失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: '品质检查结果详情',
        subtitle: detail == null
            ? '收货单办理'
            : '${detail.billNo ?? detail.receiptId} · ${detail.receiptType.label}',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.warehouseQualityResults,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-quality-detail-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && detail != null,
              onPressed: _loading || _saving
                  ? null
                  : () => _load(preserveInputs: true),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _body()),
      bottomNavigationBar: detail != null && _canConfirm && _drafts.isNotEmpty
          ? _bottomBar()
          : null,
    );
  }

  Widget _body() {
    final detail = _detail;
    if (detail == null && _loading) return const UtenSkeletonList();
    if (detail == null) {
      return UtenEmpty.error(
        message: _error ?? '品质检查结果任务不存在',
        actionLabel: '重新加载',
        onAction: _load,
      );
    }
    return UtenContentContainer.wide(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          0,
          UtenSpacing.s16,
          0,
          UtenSpacing.s24,
        ),
        children: [
          _headerCard(detail),
          if (detail.containsOwnRelease && detail.items.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _OwnReleaseNotice(editable: _canConfirm),
          ],
          if (_conflictMessage != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            _MessagePanel(message: _conflictMessage!),
          ],
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            _MessagePanel(message: '刷新失败：$_error'),
          ],
          if (_loading) ...[
            const SizedBox(height: UtenSpacing.s8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: UtenSpacing.s20),
          _mergedSection(detail),
          if (detail.rejections.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s20),
            _rejectionsSection(detail),
          ],
          if (detail.history.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s20),
            _historySection(detail),
          ],
        ],
      ),
    );
  }

  Widget _headerCard(WarehouseQualityResultDetail detail) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                UtenStatusBadge(
                  label: detail.workStatus.label,
                  type: _workStatusBadgeType(detail.workStatus),
                  icon: _workStatusIcon(detail.workStatus),
                ),
                UtenStatusBadge(
                  label: detail.receiptType.label,
                  type: UtenStatusBadgeType.accent,
                ),
                UtenStatusBadge(
                  label: detail.qualityStatusLabel,
                  type: detail.qualityStatus == 'REVERSED'
                      ? UtenStatusBadgeType.danger
                      : UtenStatusBadgeType.info,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              detail.billNo ?? detail.receiptId,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth >= 900
                    ? (constraints.maxWidth - UtenSpacing.s24) / 3
                    : constraints.maxWidth >= 560
                    ? (constraints.maxWidth - UtenSpacing.s12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s12,
                  children: [
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '收货日期',
                        value: detail.billDate ?? '—',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '供应商 / 委外商',
                        value: detail.supplierName ?? '—',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '目标仓库',
                        value: detail.warehouseName ?? '—',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '品质结论',
                        value:
                            '合格 ${detail.passedLineCount} 行 · 不合格 '
                            '${detail.failedLineCount} 行 · 待检 '
                            '${detail.openItemCount} 行 / 共 '
                            '${detail.goodsLineCount} 行',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '待入库批次',
                        value: detail.pendingSliceCount > 0
                            ? '${detail.pendingSliceCount} 个放行批次'
                            : '无',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '不合格待退回',
                        value: detail.pendingReturnCount > 0
                            ? '${detail.pendingReturnCount} 笔'
                            : '无',
                      ),
                    ),
                    const SizedBox(
                      width: 200,
                      child: _InfoTile(label: '商业字段', value: '本页不提供'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 合并明细表（原「检查结果明细」+「品质放行待入库明细」两表合一）：每行一个
  /// 货品的检查结论；有待入库放行切片的行可勾选，就地输入本次实收与实际库位，
  /// 右下角「确认入库」批量提交。判定文案始终在场，不只靠颜色。
  Widget _mergedSection(WarehouseQualityResultDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          '检查结果与待入库明细',
          _canConfirm
              ? '勾选本次要点收的放行切片（默认全额，可改小做部分入库），'
                    '实际库位必填；不合格行请在下方登记实物退回。'
              : '当前为只读查看；入库确认需要 IQC 待入库查看 + 确认入库权限。',
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (detail.lines.isEmpty)
          const UtenEmpty(
            icon: Icons.fact_check_outlined,
            message: '暂无检查明细',
            description: '该收货单可能尚未送检。',
          )
        else
          WarehouseQualityMergedTable(
            controller: _grid,
            editable: _canConfirm,
            saving: _saving,
            onChanged: () => setState(() {}),
          ),
      ],
    );
  }

  Widget _rejectionsSection(WarehouseQualityResultDetail detail) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('不合格实物退回', '核对该批不合格货品后登记真实退回凭证、日期与说明。'),
        const SizedBox(height: UtenSpacing.s8),
        for (final rejection in detail.rejections)
          Card(
            key: ValueKey('quality-rejection-${rejection.id}'),
            margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.block_outlined,
                    size: 20,
                    color: UtenColors.error,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rejection.goodsLabel.isEmpty
                              ? '未命名货品'
                              : rejection.goodsLabel,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          [
                            '不合格 ${_qty(rejection.failedQty, rejection.unitName)}',
                            if (rejection.returnReference?.isNotEmpty == true)
                              '凭证 ${rejection.returnReference}',
                            if (rejection.returnDate?.isNotEmpty == true)
                              '退回日 ${rejection.returnDate}',
                            if (rejection.returnRecordedByName?.isNotEmpty ==
                                true)
                              '登记人 ${rejection.returnRecordedByName}',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (rejection.returnNote?.isNotEmpty == true) ...[
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            '退回说明：${rejection.returnNote}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  UtenStatusBadge(
                    label: rejection.statusLabel,
                    type: rejection.canRecordReturn
                        ? UtenStatusBadgeType.warning
                        : UtenStatusBadgeType.neutral,
                  ),
                  if (rejection.canRecordReturn && _canRecordReturn) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      size: UtenButtonSize.large,
                      type: UtenButtonType.tonal,
                      icon: Icons.assignment_return_outlined,
                      onPressed: _saving
                          ? null
                          : () => _recordReturn(rejection),
                      child: const Text('登记退回'),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _historySection(WarehouseQualityResultDetail detail) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('仓库入库历史', '已落库存事实，只读保留；不可在本页修改。'),
        const SizedBox(height: UtenSpacing.s8),
        for (final item in detail.history)
          Card(
            key: ValueKey('quality-history-${item.stockInItemId}'),
            margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.goodsLabel.isEmpty ? '未命名货品' : item.goodsLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    [
                      '入库 ${_qty(item.baseQty, item.unitName)}',
                      '实际库位 ${item.place}',
                      '确认人 ${item.confirmedBy ?? '—'}',
                      '确认时间 ${warehouseQualityDateTime(item.confirmedAt)}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  WarehouseInboundAllocationSummary(
                    allocations: item.actualAllocations,
                    qtyText: warehouseQualityQuantity,
                    onTap: () => showWarehouseInboundAllocationDetails(
                      context,
                      title: '实际入库去向 · ${item.goodsLabel}',
                      actual: true,
                      sections: [
                        WarehouseInboundAllocationSection(
                          id: item.stockInItemId,
                          goodsLabel: item.goodsLabel,
                          quantity: item.baseQty,
                          unitName: item.unitName,
                          allocations: item.actualAllocations,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _bottomBar() {
    final selected = _drafts.where((draft) => draft.selected).length;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s12,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final summary = Text(
              selected == 0 ? '请勾选本次要点收的放行切片' : '已选择 $selected 条放行切片',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            );
            final action = UtenButton(
              key: const Key('warehouse-quality-detail-confirm'),
              size: UtenButtonSize.large,
              icon: Icons.move_to_inbox_rounded,
              isLoading: _saving,
              onPressed: _saving || selected == 0 ? null : _confirmStockIn,
              child: Text(selected == 0 ? '确认入库' : '确认入库($selected)'),
            );
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: UtenSpacing.s8),
                  action,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: summary),
                const SizedBox(width: UtenSpacing.s12),
                action,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String description) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ———————————————————— 判定口径（图标 / 颜色 / 徽章） ————————————————————

UtenStatusBadgeType _workStatusBadgeType(WarehouseQualityWorkStatus status) =>
    switch (status) {
      WarehouseQualityWorkStatus.waitingInspection => UtenStatusBadgeType.info,
      WarehouseQualityWorkStatus.allPassed => UtenStatusBadgeType.success,
      WarehouseQualityWorkStatus.partialPassed => UtenStatusBadgeType.warning,
      WarehouseQualityWorkStatus.returnRequired => UtenStatusBadgeType.danger,
      WarehouseQualityWorkStatus.completed => UtenStatusBadgeType.neutral,
    };

IconData _workStatusIcon(WarehouseQualityWorkStatus status) => switch (status) {
  WarehouseQualityWorkStatus.waitingInspection => Icons.hourglass_top_outlined,
  WarehouseQualityWorkStatus.allPassed => Icons.verified_outlined,
  WarehouseQualityWorkStatus.partialPassed => Icons.rule_outlined,
  WarehouseQualityWorkStatus.returnRequired => Icons.assignment_return_outlined,
  WarehouseQualityWorkStatus.completed => Icons.task_alt_outlined,
};

// ———————————————————— 局部小组件 ————————————————————

/// 单人兼任提示（不阻断）：本单放行由当前账号执行时醒目复核提醒。
class _OwnReleaseNotice extends StatelessWidget {
  const _OwnReleaseNotice({required this.editable});

  final bool editable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '本单品质放行由当前账号执行，请仔细复核后再确认入库',
      child: Container(
        key: const Key('warehouse-quality-detail-own-release'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: UtenColors.warning.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.16 : 0.10,
          ),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: UtenColors.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 20,
              color: UtenColors.warning,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                editable
                    ? '本单品质放行由当前账号执行（单人兼任品质与仓库）。'
                          '系统不再硬性阻断，请在确认入库前仔细核对实物数量与实际库位。'
                    : '本单品质放行由当前账号执行；确认入库需要 IQC 待入库查看 + '
                          '确认入库权限。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message});

  final String message;

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
            Icon(
              Icons.error_outline_rounded,
              size: 20,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// 登记实物退回弹窗（凭证号 / 日期 / 说明）。
class _RecordReturnDialog extends StatefulWidget {
  const _RecordReturnDialog({required this.rejection});

  final WarehouseQualityRejectionCase rejection;

  @override
  State<_RecordReturnDialog> createState() => _RecordReturnDialogState();
}

class _RecordReturnDialogState extends State<_RecordReturnDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reference = TextEditingController();
  final _note = TextEditingController();
  late final String _commandId = const Uuid().v4();
  late DateTime _date = DateTime.now();

  @override
  void dispose() {
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  String _dateText(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(today.year, today.month, today.day),
    );
    if (selected != null && mounted) setState(() => _date = selected);
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(
      WarehouseIqcRecordReturnCommand(
        expectedVersion: widget.rejection.rowVersion,
        commandId: _commandId,
        returnReference: _reference.text,
        returnDate: _dateText(_date),
        returnNote: _note.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登记实物退回'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('货品：${widget.rejection.goodsLabel}'),
                Text(
                  '不合格数量：${_qty(widget.rejection.failedQty, widget.rejection.unitName)}',
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextFormField(
                  controller: _reference,
                  maxLength: 200,
                  errorBuilder: utenTextFieldErrorBuilder,
                  decoration: const InputDecoration(labelText: '退回凭证号'),
                  validator: (value) => _required(value, 200, '退回凭证号'),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  button: true,
                  label: '选择退回日期 ${_dateText(_date)}',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text('退回日期 ${_dateText(_date)}'),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                TextFormField(
                  controller: _note,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  errorBuilder: utenTextFieldErrorBuilder,
                  decoration: const InputDecoration(labelText: '退回说明'),
                  validator: (value) => _required(value, 2000, '退回说明'),
                ),
              ],
            ),
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(112, 48)),
          onPressed: _submit,
          icon: const Icon(Icons.assignment_turned_in_outlined),
          label: const Text('确认登记'),
        ),
      ],
    );
  }
}

String? _required(String? value, int maxLength, String label) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '请填写$label';
  if (text.length > maxLength) return '$label不能超过 $maxLength 个字符';
  return null;
}

String _qty(double value, String? unit) =>
    '${warehouseQualityQuantity(value)}${unit == null ? '' : ' $unit'}';
