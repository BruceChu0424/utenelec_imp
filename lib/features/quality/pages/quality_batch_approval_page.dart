// 品质「批量审批」汇总页（2026-09-05）——待检处置列表多选后进入。
//
// 用户口径：多选的内容都汇总到一个页面，可多选/单选，填合格/不合格数量后
// 「提交报告」一次办结：
//   - IQC 收货单区：按单分组，逐行勾选 + 行内编辑合格数量/不合格数量
//     （默认合格 = 剩余待检、不合格 = 0），提交走 decide-batch（每单一事务）；
//   - FQC 自制产成品区：V547 按品质检查单分组（组头三态复选，镜像 IQC 收货单组），
//     无检查单的历史任务单列；勾选任务 = 全部合格（既有 pass-all 语义）；
//   - 右下角 UtenFloatingActionGroup：UtenSelectionSummaryPill（已选计数唯一出处，✕ 一键清空）
//     + 说明文案 + 提交报告；总结确认弹窗（仿计划部下达采购）后执行。
import 'package:flutter/material.dart';
import '../presentation/procurement_inspection_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../models/production_fqc_inspection.dart';
import '../widgets/production_fqc_dialogs.dart' show fqcQtyText;
import '../repositories/production_fqc_repository.dart';
import '../services/quality_batch_submission.dart';
import '../widgets/inspection_report_confirm_dialog.dart';

/// 列表页多选结果（extra 传入）：IQC 收货单 + FQC 检查单 + 无检查单 FQC 任务。
class QualityBatchApprovalSelection {
  const QualityBatchApprovalSelection({
    this.receipts = const [],
    this.inspections = const [],
    this.sheets = const [],
  });

  final List<PendingInspectionReceipt> receipts;
  final List<ProductionFqcInspection> inspections;
  final List<ProductionFqcInspectionSheet> sheets;
}

/// 一张 FQC 品质检查单的分组（V547）：组头三态复选，行 = 仍待检的 inspection。
class _FqcSheetGroup {
  _FqcSheetGroup(this.sheet, this.inspections, this.loadError);

  final ProductionFqcInspectionSheet sheet;
  final List<ProductionFqcInspection> inspections;
  final String? loadError;
}

/// 一行可编辑的 IQC 检验明细（合格默认=剩余待检，不合格默认=0）。
class _EditableIqcRow {
  _EditableIqcRow(this.item)
    : pass = TextEditingController(text: _fmt(item.remainingBaseQty ?? 0)),
      fail = TextEditingController(text: '0');

  final ProcurementInspectionItem item;
  final TextEditingController pass;
  final TextEditingController fail;

  /// Before submission this is a draft. The accepted report freezes this key,
  /// quantities and reason together, so retries never pair it with a new body.
  final String idempotencyKey = 'iqc-decide-${const Uuid().v4()}';
  bool selected = true;
  bool completed = false;

  double get _pass => double.tryParse(pass.text.trim()) ?? 0;
  double get _fail => double.tryParse(fail.text.trim()) ?? 0;

  /// null = 校验通过；否则为错误文案。
  String? validate() {
    final remaining = item.remainingBaseQty ?? 0;
    final passQty = double.tryParse(pass.text.trim());
    final failQty = double.tryParse(fail.text.trim());
    if (passQty == null ||
        failQty == null ||
        !passQty.isFinite ||
        !failQty.isFinite) {
      return '请输入有效的合格与不合格数量';
    }
    if (_pass < 0 || _fail < 0) return '数量不能为负';
    if (_pass + _fail <= 0) return '合格与不合格不能同时为 0';
    if (_pass + _fail > remaining + 1e-9) {
      return '合计不能超过剩余待检 ${_fmt(remaining)}';
    }
    return null;
  }

  void dispose() {
    pass.dispose();
    fail.dispose();
  }
}

/// 一张 IQC 收货单的可编辑分组。
class _IqcReceiptGroup {
  _IqcReceiptGroup(this.receipt, this.rows, this.loadError);

  final PendingInspectionReceipt receipt;
  final List<_EditableIqcRow> rows;
  final String? loadError;
}

class QualityBatchApprovalPage extends ConsumerStatefulWidget {
  const QualityBatchApprovalPage({super.key, required this.selection});

  final QualityBatchApprovalSelection selection;

  @override
  ConsumerState<QualityBatchApprovalPage> createState() =>
      _QualityBatchApprovalPageState();
}

class _QualityBatchApprovalPageState
    extends ConsumerState<QualityBatchApprovalPage> {
  List<_IqcReceiptGroup>? _groups;
  List<_FqcSheetGroup>? _sheetGroups;
  List<_EditableIqcRow>? _flatRows;
  bool _loading = true;
  bool _submitting = false;
  bool _confirming = false;
  bool _leaving = false;
  QualityBatchSubmission? _submission;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _leaving = true;
    _flatRows?.forEach((row) => row.dispose());
    super.dispose();
  }

  Future<void> _load({bool retryFailuresOnly = false}) async {
    if (_submission != null) return;
    setState(() {
      _loading = true;
    });
    final iqc = ref.read(procurementInspectionRepositoryProvider);
    final fqc = ref.read(productionFqcRepositoryProvider);
    final oldIqc = {
      for (final group in _groups ?? const <_IqcReceiptGroup>[])
        (group.receipt.receiptType, group.receipt.receiptId): group,
    };
    final oldFqc = {
      for (final group in _sheetGroups ?? const <_FqcSheetGroup>[])
        group.sheet.id: group,
    };
    final tasks = <Future<Object> Function()>[
      for (final receipt in widget.selection.receipts)
        () async {
          final old = oldIqc[(receipt.receiptType, receipt.receiptId)];
          if (retryFailuresOnly && old != null && old.loadError == null) {
            return old;
          }
          try {
            final rows = await iqc.items(
              receipt.receiptType,
              receipt.receiptId,
            );
            return _IqcReceiptGroup(receipt, [
              for (final item in rows)
                if ((item.remainingBaseQty ?? 0) > 0 &&
                    item.status != 'RESOLVED' &&
                    item.status != 'REVERSED')
                  _EditableIqcRow(item),
            ], null);
          } on ApiException catch (error) {
            return _IqcReceiptGroup(receipt, const [], error.message);
          } catch (_) {
            return _IqcReceiptGroup(receipt, const [], '待检明细加载失败');
          }
        },
      for (final sheet in widget.selection.sheets)
        () async {
          final old = oldFqc[sheet.id];
          if (retryFailuresOnly && old != null && old.loadError == null) {
            return old;
          }
          try {
            final detail = await fqc.sheetDetail(sheet.id);
            return _FqcSheetGroup(detail.sheet, detail.activeInspections, null);
          } on ApiException catch (error) {
            return _FqcSheetGroup(sheet, const [], error.message);
          } catch (_) {
            return _FqcSheetGroup(sheet, const [], '检查单加载失败');
          }
        },
    ];
    // One shared bound for IQC and FQC. Preserve selection order while avoiding
    // both unbounded receipt requests and serial FQC round trips.
    final results = List<Object?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (mounted && !_leaving && next < tasks.length) {
        final index = next++;
        results[index] = await tasks[index]();
      }
    }

    await Future.wait([
      for (var i = 0; i < 4 && i < tasks.length; i++) worker(),
    ]);
    final groups = results.whereType<_IqcReceiptGroup>().toList();
    final sheetGroups = results.whereType<_FqcSheetGroup>().toList();
    final flat = [for (final group in groups) ...group.rows];
    if (!mounted || _leaving) {
      // Retained rows were already disposed by State.dispose; dispose only
      // controllers created by a late successful response.
      for (final row in flat) {
        if (!(_flatRows?.contains(row) ?? false)) row.dispose();
      }
      return;
    }
    final retained = flat.toSet();
    for (final row in _flatRows ?? const <_EditableIqcRow>[]) {
      if (!retained.contains(row)) row.dispose();
    }
    setState(() {
      _groups = groups;
      _sheetGroups = sheetGroups;
      _flatRows = flat;
      for (final group in sheetGroups) {
        if (!retryFailuresOnly || !identical(oldFqc[group.sheet.id], group)) {
          _selectedFqcIds.addAll(group.inspections.map((item) => item.id));
        }
      }
      _loading = false;
    });
  }

  List<_EditableIqcRow> get _selectedIqcRows => (_flatRows ?? const [])
      .where((row) => row.selected && !row.completed)
      .toList();

  /// 全部 FQC 行：检查单内仍待检行 + 无检查单的历史任务。
  List<ProductionFqcInspection> get _allFqc {
    final byId = <String, ProductionFqcInspection>{};
    for (final group in _sheetGroups ?? const <_FqcSheetGroup>[]) {
      for (final inspection in group.inspections) {
        byId.putIfAbsent(inspection.id, () => inspection);
      }
    }
    for (final inspection in widget.selection.inspections) {
      byId.putIfAbsent(inspection.id, () => inspection);
    }
    return byId.values.toList(growable: false);
  }

  /// 列表里已勾选的任务进入本页默认保持选中（可再取消）；IQC 行同理
  ///（_EditableIqcRow 构造即 selected = true）。
  late final Set<String> _selectedFqcIds = {
    for (final inspection in widget.selection.inspections) inspection.id,
  };

  int get _selectedCount =>
      _selectedIqcRows.length +
      _selectedFqcIds.intersection(_allFqc.map((e) => e.id).toSet()).length;

  /// 胶囊 ✕：一键取消全部勾选（IQC 行 + FQC 任务），提交按钮随之进入空选提示态。
  void _clearSelection() {
    if (_submitting || _submission != null) return;
    setState(() {
      for (final row in _flatRows ?? const <_EditableIqcRow>[]) {
        row.selected = false;
      }
      _selectedFqcIds.clear();
    });
  }

  Future<void> _submitReport() async {
    if (_submitting || _confirming) return;
    if (_submission != null) {
      await _sendSubmission();
      return;
    }
    final iqcRows = _selectedIqcRows;
    final fqcSelected = [
      for (final inspection in _allFqc)
        if (_selectedFqcIds.contains(inspection.id)) inspection,
    ];
    if (iqcRows.isEmpty && fqcSelected.isEmpty) {
      context.appWarning('请先选择要提交的明细');
      return;
    }
    if (fqcSelected.length > 100) {
      context.appWarning('自制产成品每批最多100项，请减少本次勾选');
      return;
    }
    final selected = iqcRows.toSet();
    for (final group in _groups ?? const <_IqcReceiptGroup>[]) {
      if (group.rows.where(selected.contains).length > 100) {
        context.appWarning(
          '${group.receipt.billNo ?? group.receipt.receiptId}每单报告最多100行，请减少本次勾选',
        );
        return;
      }
    }
    for (final row in iqcRows) {
      final problem = row.validate();
      if (problem != null) {
        context.appWarning(
          '${row.item.goodsName ?? row.item.goodsCode ?? '明细'}：$problem',
        );
        return;
      }
    }
    final hasFail = iqcRows.any(
      (row) => (double.tryParse(row.fail.text.trim()) ?? 0) > 0,
    );
    setState(() => _confirming = true);
    String? reason;
    try {
      reason = await showInspectionReportConfirmDialog(
        context,
        lineCount: iqcRows.length,
        passTotalText: iqcRows.isEmpty
            ? '0'
            : inspectionQuantityTotalText(
                context,
                iqcRows.map(
                  (row) =>
                      (row.item, double.tryParse(row.pass.text.trim()) ?? 0),
                ),
              ),
        failTotalText: iqcRows.isEmpty
            ? '0'
            : inspectionQuantityTotalText(
                context,
                iqcRows.map(
                  (row) =>
                      (row.item, double.tryParse(row.fail.text.trim()) ?? 0),
                ),
              ),
        fqcTaskCount: fqcSelected.length,
        requireReason: hasFail,
        lines: [
          for (final row in iqcRows)
            InspectionReportConfirmLine(
              label: [
                row.item.goodsName,
                row.item.goodsCode,
                row.item.colorName,
              ].where((text) => text?.isNotEmpty == true).join(' · '),
              passText: _fmt(double.tryParse(row.pass.text.trim()) ?? 0),
              failText: _fmt(double.tryParse(row.fail.text.trim()) ?? 0),
              dim: inspectionQuantityUnit(context, row.item),
            ),
          for (final inspection in fqcSelected)
            InspectionReportConfirmLine(
              label: '自制产成品 ${inspection.reportNo ?? inspection.id}',
              passText: '',
              failText: '0',
            ),
        ],
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (reason == null || !mounted) return;
    _submission = QualityBatchSubmission(
      reason: reason.isEmpty ? null : reason,
      fqcInspectionIds: [for (final item in fqcSelected) item.id],
      receipts: [
        for (final group in _groups ?? const <_IqcReceiptGroup>[])
          if (group.rows.any(selected.contains))
            QualityReceiptSubmission(
              receiptType: group.receipt.receiptType,
              receiptId: group.receipt.receiptId,
              label: group.receipt.billNo ?? group.receipt.receiptId,
              items: [
                for (final row in group.rows.where(selected.contains))
                  ProcurementInspectionDecideItem(
                    inspectionItemId: row.item.id,
                    expectedRemainingBaseQty: row.item.remainingBaseQty ?? 0,
                    passBaseQty: row._pass,
                    failBaseQty: row._fail,
                    idempotencyKey: row.idempotencyKey,
                  ),
              ],
            ),
      ],
    );
    FocusScope.of(context).unfocus();
    await _sendSubmission();
  }

  Future<void> _sendSubmission() async {
    final submission = _submission!;
    var countsInvalidated = false;
    void invalidateCounts() {
      if (!mounted || countsInvalidated) return;
      ref.invalidate(procurementInspectionPendingCountProvider);
      ref.invalidate(warehouseQualityResultPendingCountProvider);
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      countsInvalidated = true;
    }

    setState(() => _submitting = true);
    try {
      await submission.send(
        iqc: ref.read(procurementInspectionRepositoryProvider),
        fqc: ref.read(productionFqcRepositoryProvider),
        onProgress: () {
          if (!mounted) return;
          final completed = submission.acknowledgedIqcIds.toSet();
          setState(() {
            for (final row in _flatRows ?? const <_EditableIqcRow>[]) {
              if (completed.contains(row.item.id)) {
                row.completed = true;
                row.selected = false;
              }
            }
          });
        },
      );
      if (!mounted) return;
      invalidateCounts();
      setState(() => _submitting = false);
      context.appSuccess(
        '检验报告已提交：IQC ${submission.iqcLineCount} 行、'
        '自制产成品全部合格 ${submission.fqcInspectionIds.length} 项；合格部分已转仓库待入库',
      );
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(RouteName.warehouseInspections);
      }
    } on ApiException catch (error) {
      if (mounted) {
        context.appError(
          '${submission.currentLabel}：${error.message}。重试将核对原报告，已确认成功的单据不会重发',
        );
      }
    } catch (_) {
      if (mounted) context.appError('${submission.currentLabel}提交未确认，请重试原报告');
    } finally {
      invalidateCounts();
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_submitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _leaving = true;
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title:
              '批量审批 · ${widget.selection.receipts.length} 单 IQC'
              '${widget.selection.sheets.isNotEmpty ? ' + ${widget.selection.sheets.length} 张产成品检查单' : ''}'
              '${widget.selection.inspections.isNotEmpty ? ' + ${widget.selection.inspections.length} 项产成品' : ''}',
          leading: UtenBackButton(
            color: _submitting ? theme.disabledColor : null,
            onPressed: () {
              if (!_submitting) {
                _leaving = true;
                popOrBackTo(
                  context,
                  defaultPath: RouteName.warehouseInspections,
                );
              }
            },
          ),
        ),
        body: SafeArea(
          child: _loading
              ? const UtenSkeletonList()
              : Stack(
                  children: [
                    AbsorbPointer(
                      absorbing: _submitting,
                      child: UtenContentContainer.wide(
                        child: AbsorbPointer(
                          absorbing: _submission != null,
                          child: ExcludeFocus(
                            excluding: _submission != null,
                            child: _buildBody(theme),
                          ),
                        ),
                      ),
                    ),
                    // 2026-09-12 用户口径「点了像卡住」：提交报告执行期间屏幕
                    // 中间给加载动画（跟随网络调用本身，失败/完成后撤下）。
                    if (_submitting)
                      const Positioned.fill(
                        child: UtenBusyOverlay(
                          title: '正在提交检验报告',
                          description: '按收货单逐张原子提交，已确认部分不会重复发送。',
                        ),
                      ),
                  ],
                ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _loading ? null : _buildBottomBar(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final groups = _groups ?? const <_IqcReceiptGroup>[];
    final sheetGroups = _sheetGroups ?? const <_FqcSheetGroup>[];
    final groupedFqcIds = {
      for (final group in sheetGroups)
        for (final inspection in group.inspections) inspection.id,
    };
    final looseFqc = widget.selection.inspections
        .where((inspection) => !groupedFqcIds.contains(inspection.id))
        .toList(growable: false);
    if (groups.isEmpty && sheetGroups.isEmpty && looseFqc.isEmpty) {
      return UtenEmpty(
        icon: Icons.fact_check_outlined,
        message: '所选任务都已处理',
        description: '请返回待检处置重新选择。',
        actionLabel: '返回待检处置',
        onAction: () =>
            popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenFloatingActionGroup.scrollClearance,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
          child: Text(
            _submission == null
                ? '按单核对检验明细，合格部分提交后转仓库待入库。'
                : '已确认 ${_submission!.completedReceiptCount} 单；重试原报告核对未完成部分。需修改请返回待检重新读取。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (groups.any((group) => group.loadError != null) ||
            sheetGroups.any((group) => group.loadError != null))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('batch-approval-reload-failed'),
              onPressed: () => _load(retryFailuresOnly: true),
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载失败的单据'),
            ),
          ),
        for (final group in groups) ...[
          _receiptHeader(theme, group),
          // 组头与下方表格/错误行留间距（2026-09-12 用户口径：现在贴在一起）。
          const SizedBox(height: UtenSpacing.s8),
          if (group.loadError != null)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              child: Text(
                '本单明细加载失败：${group.loadError}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else
            _iqcTable(group),
          const SizedBox(height: UtenSpacing.s12),
        ],
        for (final group in sheetGroups) ...[
          _sheetHeader(theme, group),
          const SizedBox(height: UtenSpacing.s8),
          if (group.loadError != null)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              child: Text(
                '本单明细加载失败：${group.loadError}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else if (group.inspections.isEmpty)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              child: Text(
                '本单已无待检行',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            _fqcTable(group.inspections, tableKey: group.sheet.id),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (looseFqc.isNotEmpty) ...[
          Text(
            '自制产成品 · 无检查单 (勾选即全部合格)',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          _fqcTable(looseFqc, tableKey: 'legacy'),
        ],
      ],
    );
  }

  /// 检查单组头：三态复选（全选/部分/未选）镜像 IQC 收货单组头。
  Widget _sheetHeader(ThemeData theme, _FqcSheetGroup group) {
    final ids = group.inspections.map((item) => item.id).toList();
    final selected = ids.where(_selectedFqcIds.contains).length;
    final bool? value = ids.isEmpty || selected == 0
        ? false
        : selected == ids.length
        ? true
        : null;
    return Container(
      key: ValueKey('batch-approval-sheet-${group.sheet.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('batch-approval-sheet-check-${group.sheet.id}'),
            value: value,
            tristate: true,
            onChanged: ids.isEmpty
                ? null
                : (_) => setState(() {
                    if (value != true) {
                      _selectedFqcIds.addAll(ids);
                    } else {
                      _selectedFqcIds.removeAll(ids);
                    }
                  }),
          ),
          Expanded(
            child: Text(
              '品质检查单 ${group.sheet.sheetNo}'
              ' · ${group.sheet.warehouseName ?? '—'}'
              '${group.sheet.receiverName == null ? '' : ' · 收货 ${group.sheet.receiverName}'}'
              '（${group.inspections.length} 行待检，勾选 = 全部合格）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiptHeader(ThemeData theme, _IqcReceiptGroup group) {
    final pending = group.rows.where((row) => !row.completed).toList();
    final selected = pending.where((row) => row.selected).length;
    final bool? allSelected = selected == 0
        ? false
        : selected == pending.length
        ? true
        : null;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey(
              'batch-approval-receipt-check-${group.receipt.receiptId}',
            ),
            value: allSelected,
            tristate: true,
            onChanged: pending.isEmpty
                ? null
                : (_) => setState(() {
                    for (final row in pending) {
                      row.selected = allSelected != true;
                    }
                  }),
          ),
          Expanded(
            child: Text(
              '${group.receipt.isSubcontract ? '委外进仓单' : '采购收货单'} '
              '${group.receipt.billNo ?? group.receipt.receiptId}'
              '${group.receipt.supplierName == null ? '' : ' · ${group.receipt.supplierName}'}'
              '（${group.rows.length} 行待检）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iqcTable(_IqcReceiptGroup group) =>
      MasterDataTableView<_EditableIqcRow>(
        key: ValueKey('batch-approval-iqc-table-${group.receipt.receiptId}'),
        embedded: true,
        showSelectionSummary: false,
        columns: [
          // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
          // 批量页一屏多单，名称撞车时靠编号区分；颜色与验收单位本表已有独立列。
          MasterColumnDef(
            key: 'goods',
            label: '货品名称',
            width: 200,
            value: (row) => row.item.goodsName ?? '—',
            cellBuilderHandlesSemantics: true,
            cellBuilder: (_, row) =>
                UtenGoodsIdentityCell(name: row.item.goodsName),
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 130,
            value: (row) => UtenGoodsAttributeCell.text(row.item.goodsCode),
            cellBuilder: (_, row) => UtenGoodsAttributeCell(row.item.goodsCode),
          ),
          MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 100,
            value: (row) => row.item.colorName ?? '—',
          ),
          MasterColumnDef(
            key: 'pass',
            label: '合格数量',
            width: 150,
            type: 'number',
            info: inspectionQuantityColumnHint(context, passed: true),
            value: (row) => row.pass.text,
            cellBuilder: (context, row) => _iqcQuantityField(row, passed: true),
          ),
          MasterColumnDef(
            key: 'fail',
            label: '不合格数量',
            width: 150,
            type: 'number',
            info: inspectionQuantityColumnHint(context, passed: false),
            value: (row) => row.fail.text,
            cellBuilder: (context, row) =>
                _iqcQuantityField(row, passed: false),
          ),
          MasterColumnDef(
            key: 'remaining',
            label: '剩余待检',
            width: 110,
            type: 'number',
            value: (row) => _fmt(row.item.remainingBaseQty ?? 0),
          ),
          MasterColumnDef(
            key: 'unit',
            label: '验收单位',
            width: 190,
            value: (row) => inspectionQuantityUnitCell(context, row.item),
          ),
          MasterColumnDef(
            key: 'source',
            label: '来源订货单',
            width: 160,
            value: (row) => row.item.sourceOrderNo ?? '—',
          ),
          MasterColumnDef(
            key: 'status',
            label: '本次报告',
            width: 190,
            value: (row) => row.completed ? '本次报告已确认提交' : '待提交',
          ),
        ],
        items: group.rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        selectable: true,
        idOf: (row) => row.completed ? null : row.item.id,
        selectedIds: {
          for (final row in group.rows)
            if (row.selected && !row.completed) row.item.id,
        },
        onSelectedIdsChanged: (next) => setState(() {
          for (final row in group.rows) {
            if (!row.completed) row.selected = next.contains(row.item.id);
          }
        }),
        emptyMessage: '本单已无待检明细',
      );

  Widget _iqcQuantityField(_EditableIqcRow row, {required bool passed}) =>
      ListenableBuilder(
        listenable: Listenable.merge([row.pass, row.fail]),
        builder: (context, _) => Semantics(
          textField: true,
          label: '${row.item.goodsName ?? '明细'} ${passed ? '合格数量' : '不合格数量'}',
          child: TextField(
            key: Key(
              'batch-approval-${passed ? 'pass' : 'fail'}-${row.item.id}',
            ),
            controller: passed ? row.pass : row.fail,
            enabled: row.selected && !row.completed && _submission == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: UtenInputDecoration(
              InputDecoration(
                isDense: true,
                error: row.validate() == null
                    ? null
                    : UtenFieldMessage.error(row.validate()!),
              ),
            ),
          ),
        ),
      );

  Widget _fqcTable(
    List<ProductionFqcInspection> inspections, {
    required String tableKey,
  }) => MasterDataTableView<ProductionFqcInspection>(
    key: ValueKey('batch-approval-fqc-table-$tableKey'),
    embedded: true,
    showSelectionSummary: false,
    columns: [
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
      // 勾一行就是整行判合格，认错货直接放行错批次；颜色与单位本表已有独立列。
      MasterColumnDef(
        key: 'goods',
        label: '货品名称',
        width: 200,
        value: (row) => row.goodsName ?? row.goodsCode ?? '—',
        cellBuilderHandlesSemantics: true,
        cellBuilder: (_, row) => UtenGoodsIdentityCell(name: row.goodsName),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (row) => UtenGoodsAttributeCell.text(row.goodsCode),
        cellBuilder: (_, row) => UtenGoodsAttributeCell(row.goodsCode),
      ),
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 100,
        value: (row) => row.colorName ?? '—',
      ),
      MasterColumnDef(
        key: 'quantity',
        label: '本次合格',
        width: 110,
        type: 'number',
        info: '勾选本行表示将本行剩余待检数量全部判定合格。',
        value: (row) => fqcQtyText(row.remainingQty),
      ),
      MasterColumnDef(
        key: 'unit',
        label: '单位',
        width: 80,
        value: (row) => row.unitName ?? '—',
      ),
      MasterColumnDef(
        key: 'report',
        label: '来源报工单',
        width: 170,
        value: (row) => row.reportNo ?? row.id,
      ),
      MasterColumnDef(
        key: 'plan',
        label: '生产计划',
        width: 150,
        value: (row) => row.planNo ?? '—',
      ),
      MasterColumnDef(
        key: 'warehouse',
        label: '实际成品仓',
        width: 150,
        value: (row) => row.warehouseName ?? '—',
      ),
      MasterColumnDef(
        key: 'place',
        label: '库位',
        width: 120,
        value: (row) => row.place ?? '—',
      ),
    ],
    items: inspections,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    selectable: true,
    idOf: (row) => row.id,
    selectedIds: _selectedFqcIds.intersection(
      inspections.map((row) => row.id).toSet(),
    ),
    onSelectedIdsChanged: (next) => setState(() {
      _selectedFqcIds.removeAll(inspections.map((row) => row.id));
      _selectedFqcIds.addAll(next);
    }),
    emptyMessage: '本单已无待检明细',
  );

  Widget _buildBottomBar(ThemeData theme) {
    final selectedCount = _selectedCount;
    return UtenFloatingActionGroup(
      children: [
        UtenSelectionSummaryPill(
          key: const Key('batch-approval-selected-count'),
          clearKey: const Key('batch-approval-clear-selection'),
          count: selectedCount,
          onClear: selectedCount == 0 || _submission != null || _submitting
              ? null
              : _clearSelection,
        ),
        UtenButton(
          key: const Key('batch-approval-submit-report'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          isLoading: _submitting,
          icon: Icons.fact_check_outlined,
          onPressed: _submitting || _confirming ? null : _submitReport,
          child: Text(_submission == null ? '提交报告' : '重试原报告'),
        ),
      ],
    );
  }
}

String _fmt(double value) {
  final fixed = value.toStringAsFixed(4);
  final trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}
