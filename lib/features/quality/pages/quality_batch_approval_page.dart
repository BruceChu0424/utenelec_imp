// 品质「批量审批」汇总页（2026-09-05）——待检处置列表多选后进入。
//
// 用户口径：多选的内容都汇总到一个页面，可多选/单选，填合格/不合格数量后
// 「提交报告」一次办结：
//   - IQC 收货单区：按单分组，逐行勾选 + 行内编辑合格数量/不合格数量
//     （默认合格 = 剩余待检、不合格 = 0），提交走 decide-batch（每单一事务）；
//   - FQC 自制产成品区：勾选任务 = 全部合格（既有 pass-all 语义）；
//   - 底部「已选 X 项 + 提交报告」，总结确认弹窗（仿计划部下达采购）后执行。
import 'package:flutter/material.dart';
import '../presentation/procurement_inspection_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../models/production_fqc_inspection.dart';
import '../widgets/production_fqc_dialogs.dart' show fqcQtyText;
import '../repositories/production_fqc_repository.dart';
import '../widgets/inspection_report_confirm_dialog.dart';

/// 列表页多选结果（extra 传入）：IQC 收货单 + FQC 任务。
class QualityBatchApprovalSelection {
  const QualityBatchApprovalSelection({
    this.receipts = const [],
    this.inspections = const [],
  });

  final List<PendingInspectionReceipt> receipts;
  final List<ProductionFqcInspection> inspections;
}

/// 一行可编辑的 IQC 检验明细（合格默认=剩余待检，不合格默认=0）。
class _EditableIqcRow {
  _EditableIqcRow(this.item)
    : pass = TextEditingController(text: _fmt(item.remainingBaseQty ?? 0)),
      fail = TextEditingController(text: '0');

  final ProcurementInspectionItem item;
  final TextEditingController pass;
  final TextEditingController fail;

  /// 幂等键随行生成一次：同页重试复用，改数后由服务端乐观校验兜底。
  final String idempotencyKey = 'iqc-decide-${const Uuid().v4()}';
  bool selected = true;

  double get _pass => double.tryParse(pass.text.trim()) ?? 0;
  double get _fail => double.tryParse(fail.text.trim()) ?? 0;

  /// null = 校验通过；否则为错误文案。
  String? validate() {
    final remaining = item.remainingBaseQty ?? 0;
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
  List<_EditableIqcRow>? _flatRows;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _flatRows?.forEach((row) => row.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(procurementInspectionRepositoryProvider);
    final groups = <_IqcReceiptGroup>[];
    try {
      final loaded = await Future.wait([
        for (final receipt in widget.selection.receipts)
          repo
              .items(receipt.receiptType, receipt.receiptId)
              .then(
                (rows) => MapEntry(
                  receipt,
                  rows
                      .where(
                        (item) =>
                            (item.remainingBaseQty ?? 0) > 0 &&
                            item.status != 'RESOLVED' &&
                            item.status != 'REVERSED',
                      )
                      .toList(growable: false),
                ),
              ),
      ]);
      for (final entry in loaded) {
        groups.add(
          _IqcReceiptGroup(entry.key, [
            for (final item in entry.value)
              // ignore: avoid-unnecessary_state_update
              _EditableIqcRow(item),
          ], null),
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = '待检明细加载失败：${error.message}';
          _loading = false;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '待检明细加载失败，请稍后重试';
          _loading = false;
        });
      }
      return;
    }
    if (!mounted) return;
    final flat = [for (final group in groups) ...group.rows];
    setState(() {
      _groups = groups;
      _flatRows = flat;
      _loading = false;
    });
  }

  List<_EditableIqcRow> get _selectedIqcRows =>
      (_flatRows ?? const []).where((row) => row.selected).toList();

  List<ProductionFqcInspection> get _allFqc => widget.selection.inspections;

  /// 列表里已勾选的任务进入本页默认保持选中（可再取消）；IQC 行同理
  ///（_EditableIqcRow 构造即 selected = true）。
  late final Set<String> _selectedFqcIds = {
    for (final inspection in widget.selection.inspections) inspection.id,
  };

  int get _selectedCount =>
      _selectedIqcRows.length +
      _selectedFqcIds.intersection(_allFqc.map((e) => e.id).toSet()).length;

  Future<void> _submitReport() async {
    if (_submitting) return;
    final iqcRows = _selectedIqcRows;
    final fqcSelected = [
      for (final inspection in _allFqc)
        if (_selectedFqcIds.contains(inspection.id)) inspection,
    ];
    if (iqcRows.isEmpty && fqcSelected.isEmpty) {
      context.appWarning('请先选择要提交的明细');
      return;
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
    final reason = await showInspectionReportConfirmDialog(
      context,
      lineCount: iqcRows.length,
      passTotalText: iqcRows.isEmpty
          ? '0'
          : inspectionQuantityTotalText(
              context,
              iqcRows.map(
                (row) => (row.item, double.tryParse(row.pass.text.trim()) ?? 0),
              ),
            ),
      failTotalText: iqcRows.isEmpty
          ? '0'
          : inspectionQuantityTotalText(
              context,
              iqcRows.map(
                (row) => (row.item, double.tryParse(row.fail.text.trim()) ?? 0),
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
    if (reason == null || !mounted) return;
    setState(() => _submitting = true);
    try {
      final repo = ref.read(procurementInspectionRepositoryProvider);
      // 逐单 decide-batch：单内同事务；跨单逐张执行，失败即停（错误带单号定位）。
      final byReceipt = <PendingInspectionReceipt, List<_EditableIqcRow>>{};
      for (final row in iqcRows) {
        final group = _groups?.firstWhere(
          (candidate) => candidate.rows.contains(row),
        );
        if (group == null) continue;
        byReceipt.putIfAbsent(group.receipt, () => []).add(row);
      }
      for (final entry in byReceipt.entries) {
        await repo.decideBatch(
          receiptType: entry.key.receiptType,
          receiptId: entry.key.receiptId,
          reason: reason.isEmpty ? null : reason,
          items: [
            for (final row in entry.value)
              ProcurementInspectionDecideItem(
                inspectionItemId: row.item.id,
                expectedRemainingBaseQty: row.item.remainingBaseQty ?? 0,
                passBaseQty: double.tryParse(row.pass.text.trim()) ?? 0,
                failBaseQty: double.tryParse(row.fail.text.trim()) ?? 0,
                idempotencyKey: row.idempotencyKey,
              ),
          ],
        );
      }
      if (fqcSelected.isNotEmpty) {
        await ref
            .read(productionFqcRepositoryProvider)
            .passAll(
              inspectionIds: [for (final item in fqcSelected) item.id],
              idempotencyKey: 'fqc-batch-approval-${const Uuid().v4()}',
            );
      }
      ref.invalidate(procurementInspectionPendingCountProvider);
      ref.invalidate(warehouseQualityResultPendingCountProvider);
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      if (!mounted) return;
      context.appSuccess(
        '检验报告已提交：IQC ${iqcRows.length} 行、'
        '自制产成品全部合格 ${fqcSelected.length} 项；合格部分已转仓库待入库',
      );
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(RouteName.warehouseInspections);
      }
    } on ApiException catch (error) {
      if (mounted) {
        context.appError('提交被拒：${error.message}。已成功部分不会重复提交，请处理后重试');
      }
    } catch (_) {
      if (mounted) context.appError('提交检验报告失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title:
            '批量审批 · ${widget.selection.receipts.length} 单 IQC'
            '${widget.selection.inspections.isNotEmpty ? ' + ${widget.selection.inspections.length} 项产成品' : ''}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const UtenSkeletonList()
            : _error != null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : AbsorbPointer(
                absorbing: _submitting,
                child: UtenContentContainer.wide(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _buildBody(theme)),
                      _buildBottomBar(theme),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final groups = _groups ?? const <_IqcReceiptGroup>[];
    if (groups.isEmpty && _allFqc.isEmpty) {
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
      padding: const EdgeInsets.all(UtenSpacing.s12),
      children: [
        for (final group in groups) ...[
          _receiptHeader(theme, group),
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
            for (final row in group.rows) _iqcRowTile(theme, row),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (_allFqc.isNotEmpty) ...[
          Text(
            '自制产成品（勾选 = 全部合格）',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          for (final inspection in _allFqc) _fqcRowTile(theme, inspection),
        ],
      ],
    );
  }

  Widget _receiptHeader(ThemeData theme, _IqcReceiptGroup group) {
    final allSelected = group.rows.every((row) => row.selected);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Row(
        children: [
          Checkbox(
            value: allSelected,
            tristate: true,
            onChanged: (value) => setState(() {
              for (final row in group.rows) {
                row.selected = value != false;
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

  Widget _iqcRowTile(ThemeData theme, _EditableIqcRow row) {
    final remaining = row.item.remainingBaseQty ?? 0;
    return CheckboxListTile(
      value: row.selected,
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: (value) => setState(() => row.selected = value ?? false),
      title: Text(
        [
          row.item.goodsName,
          row.item.goodsCode,
          row.item.colorName,
        ].where((text) => text?.isNotEmpty == true).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '剩余待检 ${_fmt(remaining)} ${inspectionQuantityUnit(context, row.item)}',
      ),
      secondary: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 140,
            child: TextField(
              key: Key('batch-approval-pass-${row.item.id}'),
              controller: row.pass,
              enabled: row.selected,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              decoration: UtenInputDecoration(
                const InputDecoration(labelText: '合格数量', isDense: true),
                info: inspectionQuantityHint(context, row.item, passed: true),
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 140,
            child: TextField(
              key: Key('batch-approval-fail-${row.item.id}'),
              controller: row.fail,
              enabled: row.selected,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: '不合格数量',
                  isDense: true,
                  error: row.validate() == null
                      ? null
                      : UtenFieldMessage.error(row.validate()!),
                ),
                info: inspectionQuantityHint(context, row.item, passed: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fqcRowTile(ThemeData theme, ProductionFqcInspection inspection) {
    return CheckboxListTile(
      value: _selectedFqcIds.contains(inspection.id),
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: (value) => setState(() {
        if (value == true) {
          _selectedFqcIds.add(inspection.id);
        } else {
          _selectedFqcIds.remove(inspection.id);
        }
      }),
      title: Text(
        '报工 ${inspection.reportNo ?? inspection.id}'
        '${inspection.planNo == null ? '' : ' · 计划 ${inspection.planNo}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${inspection.goodsName ?? ''}'
        '${inspection.colorName?.isNotEmpty == true ? '(${inspection.colorName})' : ''}'
        ' · 待检 ${fqcQtyText(inspection.remainingQty)}'
        '${inspection.unitName ?? ''} · 勾选即全部合格',
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '已选 $_selectedCount 项 · 提交后合格部分转仓库待入库',
                key: const Key('batch-approval-selected-count'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            UtenButton(
              key: const Key('batch-approval-submit-report'),
              isLoading: _submitting,
              icon: Icons.fact_check_outlined,
              onPressed: _submitting ? null : _submitReport,
              child: const Text('提交报告'),
            ),
          ],
        ),
      ),
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
