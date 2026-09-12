// FQC（自制产成品）质检办理页——2026-09-12 对齐采购/委外 IQC 处置页范式。
//
// 用户口径：待检处置与生产成品质检里，自制产成品不管是双击还是右下角批量审批，
// 都进独立页面办理，不再叠弹窗；页面效果与采购收货（ProcurementInspectionDetailPage）
// 一样：单据摘要卡 + 行级可编辑明细表 + 右下角「提交报告」。
//   - ProductionFqcSheetHandlingPage：一张品质检查单（V547 同仓一次送检）的
//     办理页。行内直接改合格/不合格数量（默认全合格），含不合格时行内选处置
//     方式、确认弹窗收结论原因；提交按行逐条 decide（PASS/PARTIAL/FAIL 由两
//     个数量推导），行级幂等键重试不重复。
//   - ProductionFqcInspectionPage：单条 FQC 任务（含无检查单的历史任务）的
//     详情 + 办理页。摘要卡展示送检登记事实，检验图片/文件就近挂载；决定表单
//     与检查单页同一套数量/处置口径。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';
import '../widgets/inspection_report_confirm_dialog.dart';
import '../widgets/production_fqc_dialogs.dart' show fqcStatusLabel;

/// 数量展示（去尾零，保留实际精度）——与 production_fqc_dialogs.fqcQtyText 同口径。
String fqty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

/// 不合格处置方式（与服务端 dispositionCode 同域）。
const List<(String, String)> kFqcDispositions = [
  ('REWORK', '返工'),
  ('SCRAP', '报废'),
  ('REJECT', '拒收/退回'),
];

String _dispositionLabel(String code) =>
    kFqcDispositions
        .where((entry) => entry.$1 == code)
        .map((entry) => entry.$2)
        .firstOrNull ??
    code;

/// 决定能力 = 审批权限 + 服务端品质组织校验（canDecide），与列表页同一口径。
Future<bool> _canDecideFqc(WidgetRef ref) async {
  final mayApprove =
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionQualityInspectionApprove);
  if (!mayApprove) return false;
  try {
    return await ref.read(productionFqcRepositoryProvider).canDecide();
  } catch (_) {
    return false;
  }
}

/// 一行可编辑的 FQC 检验报告（合格默认=待检、不合格默认=0），与 IQC 报告行同构。
class FqcReportRow {
  FqcReportRow(this.inspection)
    : pass = TextEditingController(text: fqty(inspection.remainingQty)),
      fail = TextEditingController(text: '0');

  final ProductionFqcInspection inspection;
  final TextEditingController pass;
  final TextEditingController fail;

  /// 不合格处置方式（含不合格数量的行在提交时必带；REWORK 为默认）。
  String disposition = 'REWORK';

  /// 行级幂等键：确认报告后冻结，重试不换键（与服务端按 用户+键 去重配合）。
  final String idempotencyKey = 'fqc-report-${const Uuid().v4()}';
  bool selected = true;
  bool completed = false;

  double get passValue => double.tryParse(pass.text.trim()) ?? 0;
  double get failValue => double.tryParse(fail.text.trim()) ?? 0;

  /// null = 校验通过；否则为错误文案。
  String? validate() {
    final remaining = inspection.remainingQty;
    if (passValue < 0 || failValue < 0) return '数量不能为负';
    if (passValue + failValue <= 0) return '合格与不合格不能同时为 0';
    if (passValue + failValue > remaining + 1e-9) {
      return '合计不能超过待检 ${fqty(remaining)}';
    }
    return null;
  }

  /// 由两个数量推导决定类型：纯合格 PASS、纯不合格 FAIL、混合 PARTIAL。
  ({String decision, double? passQty, double? failQty}) get command =>
      failValue <= 0
      ? (decision: 'PASS', passQty: passValue, failQty: null)
      : passValue <= 0
      ? (decision: 'FAIL', passQty: null, failQty: failValue)
      : (decision: 'PARTIAL', passQty: passValue, failQty: failValue);

  String get label => [
    inspection.reportNo == null || inspection.reportNo!.isEmpty
        ? inspection.id
        : inspection.reportNo,
    inspection.goodsName,
    if (inspection.colorName?.isNotEmpty == true) '(${inspection.colorName})',
  ].whereType<String>().join(' · ');

  void dispose() {
    pass.dispose();
    fail.dispose();
  }
}

/// 按单位分组的数量合计文本（跨单位绝不相加，与全站口径一致）。
String _fqcTotalsText(
  Iterable<FqcReportRow> rows,
  double Function(FqcReportRow) valueOf,
) {
  final byUnit = <String, double>{};
  for (final row in rows) {
    final unit = row.inspection.unitName?.trim();
    final key = unit == null || unit.isEmpty ? '' : unit;
    byUnit.update(
      key,
      (sum) => sum + valueOf(row),
      ifAbsent: () => valueOf(row),
    );
  }
  return [
    for (final entry in byUnit.entries)
      '${fqty(entry.value)}${entry.key.isEmpty ? '' : ' ${entry.key}'}',
  ].join(' · ');
}

/// ———————————————————— 检查单办理页（V547 一单一页） ————————————————————

class ProductionFqcSheetHandlingPage extends ConsumerStatefulWidget {
  const ProductionFqcSheetHandlingPage({super.key, required this.sheetId});

  final String sheetId;

  @override
  ConsumerState<ProductionFqcSheetHandlingPage> createState() =>
      _ProductionFqcSheetHandlingPageState();
}

class _ProductionFqcSheetHandlingPageState
    extends ConsumerState<ProductionFqcSheetHandlingPage> {
  ProductionFqcInspectionSheetDetail? _detail;
  List<FqcReportRow>? _rows;
  bool _loading = true;
  bool _submitting = false;
  bool _canDecide = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rows?.forEach((row) => row.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(productionFqcRepositoryProvider)
          .sheetDetail(widget.sheetId);
      if (!mounted) return;
      final canDecide = await _canDecideFqc(ref);
      if (!mounted) return;
      final rows = [
        for (final inspection in detail.activeInspections)
          FqcReportRow(inspection),
      ];
      setState(() {
        _detail = detail;
        _canDecide = canDecide;
        _rows = rows;
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
        _error = '品质检查单加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  List<FqcReportRow> get _selected => (_rows ?? const [])
      .where((row) => row.selected && !row.completed)
      .toList();

  Future<void> _submitReport() async {
    if (_submitting) return;
    final selected = _selected;
    if (selected.isEmpty) {
      context.appWarning('请先勾选要提交的明细行');
      return;
    }
    for (final row in selected) {
      final problem = row.validate();
      if (problem != null) {
        context.appWarning('${row.label}：$problem');
        return;
      }
    }
    final hasFail = selected.any((row) => row.failValue > 0);
    final reason = await showInspectionReportConfirmDialog(
      context,
      lineCount: selected.length,
      passTotalText: _fqcTotalsText(selected, (row) => row.passValue),
      failTotalText: _fqcTotalsText(selected, (row) => row.failValue),
      requireReason: hasFail,
      lines: [
        for (final row in selected)
          InspectionReportConfirmLine(
            label: row.label,
            passText: fqty(row.passValue),
            failText: fqty(row.failValue),
            dim: row.inspection.unitName,
          ),
      ],
    );
    if (reason == null || !mounted) return;
    if (hasFail && reason.trim().length < 2) {
      context.appWarning('含不合格数量时结论原因至少 2 个字');
      return;
    }
    setState(() => _submitting = true);
    var done = 0;
    try {
      for (final row in selected) {
        final command = row.command;
        await ref
            .read(productionFqcRepositoryProvider)
            .decide(
              id: row.inspection.id,
              decision: command.decision,
              idempotencyKey: row.idempotencyKey,
              passQty: command.passQty,
              failQty: command.failQty,
              dispositionCode: command.decision == 'PASS'
                  ? null
                  : row.disposition,
              reason: command.decision == 'PASS' ? null : reason.trim(),
            );
        row.completed = true;
        row.selected = false;
        done++;
        if (mounted) setState(() {});
      }
      if (!mounted) return;
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      context.appSuccess('检验报告已提交：$done 行决定已登记；合格部分已转仓库待最终点收');
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      context.appError(
        '已提交 $done 行；「${selected[done].label}」登记被拒：${error.message}。'
        '可直接重试，已成功行不会重复决定',
      );
      await _load();
    } catch (_) {
      if (mounted) context.appError('提交未确认（已提交 $done 行），请重试剩余行');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: detail == null ? '品质检查单办理' : '品质检查单办理 · ${detail.sheet.sheetNo}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
        ),
        actions: [
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading,
            onPressed: _loading || _submitting ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && detail == null
            ? const UtenSkeletonList()
            : _error != null && detail == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : AbsorbPointer(absorbing: _submitting, child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail!;
    final rows = _rows!;
    final activeRows = rows
        .where((row) => !row.completed)
        .toList(growable: false);
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSummaryCard(theme, detail, activeRows.length),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                ),
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
            if (_submitting) ...[
              const SizedBox(height: UtenSpacing.s8),
              const LinearProgressIndicator(key: Key('fqc-sheet-progress')),
            ],
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: activeRows.isEmpty
                  ? UtenEmpty(
                      icon: Icons.verified_outlined,
                      message: '本检查单待检已全部处理完成',
                      description: '合格部分已转仓库待最终点收；返回待检处置继续下一单。',
                      actionLabel: '返回待检处置',
                      onAction: () => popOrBackTo(
                        context,
                        defaultPath: RouteName.warehouseInspections,
                      ),
                    )
                  : AbsorbPointer(
                      absorbing: !_canDecide,
                      child: MasterDataTableView<FqcReportRow>(
                        key: const Key('fqc-sheet-report-table'),
                        columns: _rowColumns(theme),
                        items: activeRows,
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        selectable: _canDecide,
                        idOf: (row) => row.inspection.id,
                        selectedIds: {
                          for (final row in activeRows)
                            if (row.selected) row.inspection.id,
                        },
                        onSelectedIdsChanged: (next) => setState(() {
                          for (final row in activeRows) {
                            row.selected = next.contains(row.inspection.id);
                          }
                        }),
                        batchActionsBuilder: _canDecide ? _batchActions : null,
                        rowMenuBuilder: (row) => [
                          UtenMenuItem(
                            label: '查看详情与证据',
                            icon: Icons.visibility_outlined,
                            onTap: () => context.push(
                              RouteName.productionFqcInspectionHandling(
                                row.inspection.id,
                              ),
                              extra: row.inspection,
                            ),
                          ),
                        ],
                        isLoading: _loading,
                        emptyMessage: '本检查单已无待检行',
                        showFullscreenToggle: false,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    return [
      UtenButton(
        key: const Key('fqc-sheet-submit-report'),
        size: UtenButtonSize.large,
        type: UtenButtonType.danger,
        icon: Icons.fact_check_outlined,
        isLoading: _submitting,
        onPressed: _submitting || selectedIds.isEmpty ? null : _submitReport,
        onDisabledTap: selectedIds.isEmpty
            ? () => context.appWarning('请先勾选要提交的明细行')
            : null,
        child: const Text('提交报告'),
      ),
    ];
  }

  /// 单据摘要卡（对齐 IQC 处置页：徽章 + 单号 + 事实横表 + 操作提示）。
  Widget _buildSummaryCard(
    ThemeData theme,
    ProductionFqcInspectionSheetDetail detail,
    int activeCount,
  ) {
    final sheet = detail.sheet;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: sheet.active ? '待检' : '已办结',
                  type: sheet.active
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.neutral,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '品质检查单 ${sheet.sheetNo}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            MasterDataTableView<_SheetHeaderRow>(
              key: const Key('fqc-sheet-header-table'),
              embedded: true,
              showColumnChooser: false,
              columns: [
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'warehouseName',
                  label: '成品仓',
                  width: 140,
                  value: (row) => row.warehouseName,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'receiverName',
                  label: '收货人',
                  width: 110,
                  value: (row) => row.receiverName,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'reportNos',
                  label: '报工单',
                  width: 200,
                  value: (row) => row.reportNos,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'pending',
                  label: '待检',
                  width: 200,
                  value: (row) => row.pending,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'createdAt',
                  label: '进入质检',
                  width: 150,
                  value: (row) => row.createdAt,
                ),
              ],
              items: [
                _SheetHeaderRow(
                  warehouseName: sheet.warehouseName ?? '—',
                  receiverName: sheet.receiverName ?? '—',
                  reportNos: sheet.reportNos ?? '—',
                  pending:
                      '$activeCount 行待检'
                      '${sheet.pendingQtyText == null ? '' : ' · ${sheet.pendingQtyText}'}',
                  createdAt: ChinaDateTime.formatInstant(sheet.createdAt),
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
            if (sheet.remark?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text('登记备注：${sheet.remark}', style: theme.textTheme.bodySmall),
            ],
            const Divider(height: UtenSpacing.s24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    _canDecide
                        ? '行内直接修改合格数量/不合格数量（默认全合格），含不合格的行另选处置'
                              '方式；勾选后点「提交报告」一次办结。'
                        : '当前为只读查看；登记决定需要生产质检审批权限，且账号必须属于品质任务组织。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<MasterColumnDef<FqcReportRow>> _rowColumns(ThemeData theme) => [
    MasterColumnDef<FqcReportRow>(
      key: 'reportNo',
      label: '报工单',
      width: 160,
      value: (row) => row.inspection.reportNo ?? row.inspection.id,
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'planNo',
      label: '生产计划',
      width: 150,
      value: (row) => row.inspection.planNo ?? '—',
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      value: (row) => [
        row.inspection.goodsName,
        if (row.inspection.goodsCode?.isNotEmpty == true)
          '(${row.inspection.goodsCode})',
      ].whereType<String>().join(),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'colorName',
      label: '颜色',
      width: 100,
      value: (row) => row.inspection.colorName ?? '—',
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'unit',
      label: '单位',
      width: 80,
      value: (row) => row.inspection.unitName ?? '—',
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'reportedQty',
      label: '报工数量',
      width: 100,
      type: 'number',
      value: (row) => fqty(row.inspection.reportedQty),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'place',
      label: '库位',
      width: 110,
      value: (row) => row.inspection.place ?? '—',
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'passedQty',
      label: '已合格',
      width: 90,
      type: 'number',
      value: (row) => fqty(row.inspection.passedQty),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'failedQty',
      label: '已不合格',
      width: 95,
      type: 'number',
      value: (row) => fqty(row.inspection.failedQty),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'remainingQty',
      label: '待检数量',
      width: 100,
      type: 'number',
      value: (row) => fqty(row.inspection.remainingQty),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'pass',
      label: '合格数量',
      width: 120,
      value: (row) => row.pass.text,
      cellBuilder: (context, row) => _qtyField(
        context,
        row,
        row.pass,
        key: Key('fqc-sheet-pass-${row.inspection.id}'),
        label: '合格数量',
      ),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'fail',
      label: '不合格数量',
      width: 120,
      value: (row) => row.fail.text,
      cellBuilder: (context, row) => _qtyField(
        context,
        row,
        row.fail,
        key: Key('fqc-sheet-fail-${row.inspection.id}'),
        label: '不合格数量',
      ),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'disposition',
      label: '不合格处置',
      width: 140,
      // 通用说明收进列头 ⓘ（全站口径）：不合格才需要处置；处置方式随行选。
      info: '仅「不合格数量 > 0」的行需要选择；纯合格行不需要处置方式。',
      value: (row) =>
          row.failValue > 0 ? _dispositionLabel(row.disposition) : '—',
      cellBuilder: (context, row) => DropdownButtonFormField<String>(
        key: Key('fqc-sheet-disposition-${row.inspection.id}'),
        initialValue: row.disposition,
        isExpanded: true,
        decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
        items: [
          for (final entry in kFqcDispositions)
            DropdownMenuItem(value: entry.$1, child: Text(entry.$2)),
        ],
        onChanged: !_canDecide || _submitting || row.failValue <= 0
            ? null
            : (value) => setState(() => row.disposition = value ?? 'REWORK'),
      ),
    ),
  ];

  Widget _qtyField(
    BuildContext context,
    FqcReportRow row,
    TextEditingController controller, {
    required Key key,
    required String label,
  }) {
    return Semantics(
      textField: true,
      label: '${row.inspection.goodsName ?? '明细'} $label',
      child: TextField(
        key: key,
        controller: controller,
        enabled: _canDecide && !_submitting,
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
    );
  }
}

/// 处置页表头信息的一行（一张检查单恰好一行）：供表格按列呈现单据级事实。
class _SheetHeaderRow {
  const _SheetHeaderRow({
    required this.warehouseName,
    required this.receiverName,
    required this.reportNos,
    required this.pending,
    required this.createdAt,
  });

  final String warehouseName;
  final String receiverName;
  final String reportNos;
  final String pending;
  final String createdAt;
}

/// ———————————————————— 单条 FQC 任务办理页（详情 + 决定 + 证据） ————————————————————

class ProductionFqcInspectionPage extends ConsumerStatefulWidget {
  const ProductionFqcInspectionPage({
    super.key,
    required this.inspectionId,
    this.extra,
  });

  final String inspectionId;

  /// 列表行携带的任务快照（加载中先显示单号）；深链直达时为空。
  final Object? extra;

  @override
  ConsumerState<ProductionFqcInspectionPage> createState() =>
      _ProductionFqcInspectionPageState();
}

class _ProductionFqcInspectionPageState
    extends ConsumerState<ProductionFqcInspectionPage> {
  ProductionFqcInspection? _inspection;
  FqcReportRow? _row;
  bool _loading = true;
  bool _saving = false;
  bool _canDecide = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _inspection = widget.extra is ProductionFqcInspection
        ? widget.extra! as ProductionFqcInspection
        : null;
    _load();
  }

  @override
  void dispose() {
    _row?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inspection = await ref
          .read(productionFqcRepositoryProvider)
          .detail(widget.inspectionId);
      if (!mounted) return;
      final canDecide = await _canDecideFqc(ref);
      if (!mounted) return;
      final row = inspection.active ? FqcReportRow(inspection) : null;
      setState(() {
        _inspection = inspection;
        _canDecide = canDecide;
        _row?.dispose();
        _row = row;
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
        _error = '生产成品质检详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _submitReport() async {
    final row = _row;
    if (_saving || row == null || !_canDecide) return;
    final problem = row.validate();
    if (problem != null) {
      context.appWarning(problem);
      return;
    }
    final hasFail = row.failValue > 0;
    final reason = await showInspectionReportConfirmDialog(
      context,
      lineCount: 1,
      passTotalText:
          '${fqty(row.passValue)}'
          '${row.inspection.unitName == null ? '' : ' ${row.inspection.unitName}'}',
      failTotalText:
          '${fqty(row.failValue)}'
          '${row.inspection.unitName == null ? '' : ' ${row.inspection.unitName}'}',
      requireReason: hasFail,
      lines: [
        InspectionReportConfirmLine(
          label: row.label,
          passText: fqty(row.passValue),
          failText: fqty(row.failValue),
          dim: row.inspection.unitName,
        ),
      ],
    );
    if (reason == null || !mounted) return;
    if (hasFail && reason.trim().length < 2) {
      context.appWarning('含不合格数量时结论原因至少 2 个字');
      return;
    }
    setState(() => _saving = true);
    try {
      final command = row.command;
      final result = await ref
          .read(productionFqcRepositoryProvider)
          .decide(
            id: row.inspection.id,
            decision: command.decision,
            idempotencyKey: row.idempotencyKey,
            passQty: command.passQty,
            failQty: command.failQty,
            dispositionCode: command.decision == 'PASS'
                ? null
                : row.disposition,
            reason: command.decision == 'PASS' ? null : reason.trim(),
          );
      if (!mounted) return;
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      context.appSuccess(
        row.command.decision == 'PASS' ? '质检决定已保存；合格部分已转仓库待最终点收' : '质检决定已保存',
      );
      // 从列表双击进来的（正常路径）：带决定结果直接返回，列表先本地落位再刷新
      //（刷新失败也保得住「已决定」事实）；深链直达无栈可弹时留在本页看结果。
      if (context.canPop()) {
        context.pop(result.inspection);
        return;
      }
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('质检决定保存失败，请保持本页并重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inspection = _inspection;
    return Scaffold(
      appBar: UtenAppBar(
        title: '自制产成品质检 · ${inspection?.reportNo ?? widget.inspectionId}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
        ),
        actions: [
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && inspection != null,
            onPressed: _loading || _saving ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && inspection == null
            ? const UtenSkeletonList()
            : _error != null && inspection == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : UtenContentContainer.wide(
                child: ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  children: [
                    _buildFactsCard(theme, inspection!),
                    const SizedBox(height: UtenSpacing.s12),
                    if (_canDecide && _row != null) ...[
                      _buildDecisionForm(theme, _row!),
                      const SizedBox(height: UtenSpacing.s12),
                    ] else
                      ..._readOnlyHint(theme, inspection),
                    _buildAttachments(theme, inspection),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
      ),
    );
  }

  /// 送检登记事实卡（报工/货品/检查单/仓/库位/数量全貌）。
  Widget _buildFactsCard(ThemeData theme, ProductionFqcInspection inspection) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: fqcStatusLabel(inspection),
                  type: inspection.active
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.neutral,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '报工 ${inspection.reportNo ?? inspection.id}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            MasterDataTableView<_FactRow>(
              key: const Key('fqc-inspection-facts-table'),
              embedded: true,
              showColumnChooser: false,
              columns: [
                MasterColumnDef<_FactRow>(
                  key: 'planNo',
                  label: '生产计划',
                  width: 150,
                  value: (row) => row.planNo,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'goods',
                  label: '货品',
                  width: 220,
                  value: (row) => row.goods,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'sheetNo',
                  label: '检查单号',
                  width: 150,
                  value: (row) => row.sheetNo,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'warehouse',
                  label: '实际成品仓',
                  width: 140,
                  value: (row) => row.warehouse,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'place',
                  label: '库位',
                  width: 110,
                  value: (row) => row.place,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'receiver',
                  label: '收货人',
                  width: 110,
                  value: (row) => row.receiver,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'qty',
                  label: '数量（报工/合格/不合格/待检/已生成待点收）',
                  width: 300,
                  value: (row) => row.qty,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'time',
                  label: '进入质检 / 更新',
                  width: 300,
                  value: (row) => row.time,
                ),
              ],
              items: [
                _FactRow(
                  planNo: inspection.planNo ?? '—',
                  goods: [
                    inspection.goodsCode,
                    inspection.goodsName,
                    if (inspection.colorName?.isNotEmpty == true)
                      '(${inspection.colorName})',
                  ].whereType<String>().join(' '),
                  sheetNo: inspection.sheetNo ?? '无检查单',
                  warehouse: inspection.warehouseName ?? '—',
                  place: inspection.place ?? '—',
                  receiver: inspection.receiverName ?? '—',
                  qty:
                      '${fqty(inspection.reportedQty)} / '
                      '${fqty(inspection.passedQty)} / '
                      '${fqty(inspection.failedQty)} / '
                      '${fqty(inspection.remainingQty)} / '
                      '${fqty(inspection.authorizedInboundQty)}'
                      '${inspection.unitName == null ? '' : ' ${inspection.unitName}'}',
                  time:
                      '${ChinaDateTime.formatInstant(inspection.createdAt)}'
                      ' / ${ChinaDateTime.formatInstant(inspection.updatedAt)}',
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
            if (inspection.registrationRemark?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '登记备注：${inspection.registrationRemark}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 决定表单：合格/不合格数量 + 不合格处置；提交前由总结弹窗收结论原因。
  Widget _buildDecisionForm(ThemeData theme, FqcReportRow row) {
    final inspection = row.inspection;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '登记检验决定',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '待检 ${fqty(inspection.remainingQty)}'
              '${inspection.unitName == null ? '' : ' ${inspection.unitName}'}；'
              '合格数量会生成仓库待点收任务，尚不直接增加库存。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 720;
                final fields = [
                  SizedBox(
                    width: 200,
                    child: TextField(
                      key: const Key('fqc-inspection-pass'),
                      controller: row.pass,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '合格数量', isDense: true),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      key: const Key('fqc-inspection-fail'),
                      controller: row.fail,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '不合格数量', isDense: true),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: DropdownButtonFormField<String>(
                      key: const Key('fqc-inspection-disposition'),
                      initialValue: row.disposition,
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '不合格处置', isDense: true),
                      ),
                      items: [
                        for (final entry in kFqcDispositions)
                          DropdownMenuItem(
                            value: entry.$1,
                            child: Text(entry.$2),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(
                              () => row.disposition = value ?? 'REWORK',
                            ),
                    ),
                  ),
                ];
                final submit = UtenButton(
                  key: const Key('fqc-inspection-submit-report'),
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.large,
                  icon: Icons.fact_check_outlined,
                  isLoading: _saving,
                  onPressed: _saving ? null : _submitReport,
                  child: const Text('提交报告'),
                );
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: UtenSpacing.s12,
                        runSpacing: UtenSpacing.s8,
                        children: fields,
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Align(alignment: Alignment.centerLeft, child: submit),
                    ],
                  );
                }
                return Row(
                  children: [
                    ...fields.expand(
                      (field) => [
                        field,
                        const SizedBox(width: UtenSpacing.s12),
                      ],
                    ),
                    const Spacer(),
                    submit,
                  ],
                );
              },
            ),
            if (row.validate() case final problem?) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                problem,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _readOnlyHint(
    ThemeData theme,
    ProductionFqcInspection inspection,
  ) => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            inspection.active
                ? '当前为只读查看；登记决定需要生产质检审批权限，且账号必须属于品质任务组织。'
                : inspection.status == 'CANCELLED'
                ? '来源报工已红冲或仓库登记已撤回，本任务只读且不能再登记检验决定。'
                : '该任务已完成决定，当前详情只读。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: UtenSpacing.s12),
  ];

  Widget _buildAttachments(
    ThemeData theme,
    ProductionFqcInspection inspection,
  ) {
    final permissions = ref.watch(currentPermissionsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BusinessAttachmentSection(
              ownerType: 'PRODUCTION_QUALITY_INSPECTION',
              ownerId: inspection.id,
              canView: permissions.contains(
                Perm.productionQualityInspectionView,
              ),
              canManage:
                  _canDecide &&
                  permissions.contains(
                    Perm.productionQualityInspectionApprove,
                  ) &&
                  inspection.status == 'PENDING' &&
                  inspection.passedQty == 0 &&
                  inspection.failedQty == 0 &&
                  inspection.remainingQty > 0,
              title: '检验图片和文件',
              categories: const ['检验照片', '检验报告', '其他证据'],
            ),
            if (permissions.contains(Perm.attachmentView)) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '请在登记检验结果前添加证据。登记结果后（包括部分检验），文件保留供查阅，不能替换或删除。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FactRow {
  const _FactRow({
    required this.planNo,
    required this.goods,
    required this.sheetNo,
    required this.warehouse,
    required this.place,
    required this.receiver,
    required this.qty,
    required this.time,
  });

  final String planNo;
  final String goods;
  final String sheetNo;
  final String warehouse;
  final String place;
  final String receiver;
  final String qty;
  final String time;
}
