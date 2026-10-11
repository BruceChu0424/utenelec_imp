// ADR-143 §4.1 委外任务详情：物料表 + 已提交未发的领料 + 服务端放行的动作。
//
// 物料表逐种直属物料显示 每套用量 / 需求 / 已发外 / 待仓库发 / 仓库可用 / 本次可领 /
// 还缺 / 供应来源 / 状态；数量都是服务端算好的结果。底部动作只看服务端
// allowedActions：撤回未发领料(WITHDRAW)、结束领料(CLOSE，必填原因)；
// 「去领料」只在本行 canDraw 且账号可提交领料时出现。
// 仓库拣货改过的领料单标「仓库已改过」：委外这边不能撤回，要不发请仓库「退回委外(不发)」。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_draw.dart';
import '../repositories/subcontract_draw_repository.dart';
import 'subcontract_draw_status.dart';

/// 打开任务详情。撤回 / 结束领料成功后立刻回调 [onChanged](列表与红数重拉)；
/// 返回值非空 = 用户点了「去领料」，值为该委外订货明细 id。
Future<String?> showSubcontractDrawTaskDetailDialog(
  BuildContext context, {
  required SubcontractDrawGateway gateway,
  required String orderItemId,
  required bool canSubmitDraw,
  VoidCallback? onChanged,
}) => showDialog<String>(
  context: context,
  builder: (_) => _SubcontractDrawTaskDetailDialog(
    gateway: gateway,
    orderItemId: orderItemId,
    canSubmitDraw: canSubmitDraw,
    onChanged: onChanged,
  ),
);

class _SubcontractDrawTaskDetailDialog extends StatefulWidget {
  const _SubcontractDrawTaskDetailDialog({
    required this.gateway,
    required this.orderItemId,
    required this.canSubmitDraw,
    this.onChanged,
  });

  final SubcontractDrawGateway gateway;
  final String orderItemId;
  final bool canSubmitDraw;
  final VoidCallback? onChanged;

  @override
  State<_SubcontractDrawTaskDetailDialog> createState() =>
      _SubcontractDrawTaskDetailDialogState();
}

class _SubcontractDrawTaskDetailDialogState
    extends State<_SubcontractDrawTaskDetailDialog> {
  SubcontractDrawTaskDetail? _detail;
  String? _error;
  bool _loading = true;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.gateway.detail(widget.orderItemId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '委外任务详情加载失败，请稍后重试';
      });
    }
  }

  void _close() => Navigator.of(context).pop();

  Future<void> _withdraw(SubcontractDrawTaskDetail detail) async {
    // 仓库已改过的领料单委外这边撤不回，确认文案只列能撤回的。
    final drafts = detail.pendingDrafts
        .where((draft) => !draft.edited)
        .toList();
    final confirmed = await UtenDialog.show(
      context,
      title: '撤回未发领料',
      danger: true,
      confirmLabel: '撤回',
      content: Text(
        drafts.isEmpty
            ? '撤回本任务已提交、仓库尚未发出的领料？占用的库存会退回。'
            : '撤回本任务已提交、仓库尚未发出的领料？'
                  '涉及出仓单 ${drafts.map((draft) => draft.billNo).where((no) => no.isNotEmpty).join('、')}；'
                  '占用的库存会退回，并通知仓库。',
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = '正在撤回领料');
    try {
      final result = await widget.gateway.withdraw([widget.orderItemId]);
      widget.onChanged?.call();
      if (!mounted) return;
      context.appSuccess(
        result.withdrawnIssueIds.isEmpty && result.removedLineCount == 0
            ? '没有可撤回的领料'
            : '已撤回 ${result.removedLineCount} 行未发领料',
      );
      setState(() => _busy = null);
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      context.appApiError(error, fallback: '撤回领料失败，请稍后重试');
    }
  }

  Future<void> _closeDraw(SubcontractDrawTaskDetail detail) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _CloseDrawReasonDialog(task: detail.task),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = '正在结束领料');
    try {
      await widget.gateway.close(widget.orderItemId, reason);
      widget.onChanged?.call();
      if (!mounted) return;
      context.appSuccess('已结束领料，本任务不再发外');
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      context.appApiError(error, fallback: '结束领料失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final size = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: _busy == null,
      child: Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1180,
            maxHeight: size.height * 0.88,
          ),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        detail == null
                            ? '委外任务详情'
                            : '委外任务 · ${_label(detail.task.goodsName)}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: _busy == null ? _close : null,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                if (_loading && detail == null)
                  const Padding(
                    padding: EdgeInsets.all(UtenSpacing.s24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null && detail == null)
                  SizedBox(
                    height: 220,
                    child: UtenEmpty.error(
                      message: '无法加载委外任务详情',
                      description: _error,
                      actionLabel: '重试',
                      onAction: _load,
                    ),
                  )
                else if (detail != null) ...[
                  _facts(theme, detail.task),
                  const SizedBox(height: UtenSpacing.s12),
                  Flexible(
                    child: SizedBox(
                      height: size.height * 0.42,
                      child: _materialTable(detail),
                    ),
                  ),
                  if (detail.pendingDrafts.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    _pendingDrafts(theme, detail.pendingDrafts),
                  ],
                  if (_busy != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Semantics(
                      liveRegion: true,
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Text(_busy!),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s12),
                  _actions(detail),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _facts(ThemeData theme, SubcontractDrawTaskRow task) {
    final unit = task.unitName.trim();
    String qty(double value) =>
        '${subcontractDrawQty(value)}${unit.isEmpty ? '' : ' $unit'}';
    final entries = <(String, String)>[
      ('委外订货单', _label(task.orderBillNo)),
      ('委外商', _label(task.supplierName)),
      ('委外件', _label(task.goodsName)),
      ('编号', _label(task.goodsCode)),
      ('颜色', _label(task.colorName)),
      ('订货数量', qty(task.orderQty)),
      ('已领', qty(task.drawnQty)),
      ('待仓库发', qty(task.pendingQty)),
      ('可领', qty(task.drawableQty)),
      ('还缺', qty(task.shortQty)),
      if ((task.deliverDate ?? '').isNotEmpty) ('交期', task.deliverDate!),
    ];
    return Wrap(
      spacing: UtenSpacing.s16,
      runSpacing: UtenSpacing.s4,
      children: [
        for (final (label, value) in entries)
          Text.rich(
            TextSpan(
              text: '$label ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              children: [
                TextSpan(
                  text: value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _materialTable(
    SubcontractDrawTaskDetail detail,
  ) => MasterDataTableView<SubcontractDrawMaterial>(
    tableKey:
        'features.subcontract.widgets.subcontract_draw_task_detail_dialog.SubcontractDrawTaskDetailDialogState._materialTable.1',
    key: const Key('subcontract-draw-detail-materials'),
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    showFullscreenToggle: false,
    columns: [
      MasterColumnDef(
        key: 'state',
        label: '状态',
        width: 72,
        value: subcontractDrawMaterialStateLabel,
        // 状态整格底色（ADR-169）：共用 subcontractDrawMaterialCellColor，
        // 与订货单进度物料表同口径（可领绿/已备紫/待仓库发料青/缺料红/
        // 已发齐·已结束领料灰）。
        cellColor: (context, row) => subcontractDrawMaterialCellColor(row),
      ),
      MasterColumnDef(
        key: 'goodsName',
        label: '物料名称',
        width: 180,
        value: (row) => _label(row.goodsName),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (row) => _label(row.goodsCode),
      ),
      MasterColumnDef(
        key: 'colorName',
        label: '颜色',
        width: 90,
        value: (row) => _label(row.colorName),
      ),
      // 「单位」列 2026-10-10 删除（数量+单位口径）：各数量列已内联该物料自己的
      // 单位（物料间单位不同，逐行内联才不串）。
      _qtyColumn('perUnitQty', '每套用量', (row) => row.perUnitQty),
      _qtyColumn('requiredQty', '需求', (row) => row.requiredQty),
      _qtyColumn('sentQty', '已发外', (row) => row.sentQty),
      _qtyColumn('pendingQty', '待仓库发', (row) => row.pendingQty),
      _qtyColumn('availableQty', '仓库可用', (row) => row.availableQty),
      _qtyColumn('drawableQty', '本次可领', (row) => row.drawableQty),
      _qtyColumn('shortQty', '还缺', (row) => row.shortQty),
      const MasterColumnDef(
        key: 'supplySources',
        label: '供应来源',
        width: 240,
        value: subcontractDrawSupplyText,
      ),
    ],
    items: detail.materials,
    emptyMessage: '本任务没有需要领的物料',
  );

  MasterColumnDef<SubcontractDrawMaterial> _qtyColumn(
    String key,
    String label,
    double Function(SubcontractDrawMaterial row) qty,
  ) => MasterColumnDef(
    key: key,
    label: label,
    width: 96,
    type: 'number',
    // 2026-10-10 数量+单位口径：单位内联（每种物料自己的单位）；排序由表格
    // 组件剥单位后缀兜底。
    value: (row) => formatQtyWithUnit(qty(row), row.unitName),
  );

  Widget _pendingDrafts(
    ThemeData theme,
    List<SubcontractDrawPendingDraft> drafts,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('已提交、仓库未发出的领料', style: theme.textTheme.titleSmall),
      const SizedBox(height: UtenSpacing.s4),
      for (final draft in drafts)
        Text.rich(
          TextSpan(
            text: [
              _label(draft.billNo),
              _label(draft.warehouseName),
              '${draft.lineCount} 行',
              if (draft.submittedByName.isNotEmpty) draft.submittedByName,
              ?_dateTime(draft.submittedAt),
            ].join(' · '),
            children: [
              if (draft.edited)
                TextSpan(
                  text: ' · 仓库已改过',
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          key: ValueKey('subcontract-draw-detail-draft-${draft.issueId}'),
          style: theme.textTheme.bodySmall,
        ),
      if (drafts.any((draft) => draft.edited)) ...[
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '标「仓库已改过」的领料单仓库已经开始拣货并改过，委外这边不能撤回；'
          '这批不发了请联系仓库在拣货页点「退回委外(不发)」。',
          key: const Key('subcontract-draw-detail-edited-hint'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ],
  );

  Widget _actions(SubcontractDrawTaskDetail detail) {
    final idle = _busy == null;
    final canGoDraw = widget.canSubmitDraw && detail.task.canDraw;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        if (detail.allows(SubcontractDrawTaskDetail.closeAction))
          UtenButton(
            key: const Key('subcontract-draw-detail-close-draw'),
            type: UtenButtonType.secondary,
            icon: Icons.block_rounded,
            onPressed: idle ? () => _closeDraw(detail) : null,
            child: const Text('结束领料'),
          ),
        if (detail.allows(SubcontractDrawTaskDetail.withdrawAction))
          UtenButton(
            key: const Key('subcontract-draw-detail-withdraw'),
            type: UtenButtonType.secondary,
            icon: Icons.undo_rounded,
            onPressed: idle ? () => _withdraw(detail) : null,
            child: const Text('撤回未发领料'),
          ),
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: idle ? _close : null,
          child: const Text('关闭'),
        ),
        if (canGoDraw)
          UtenButton(
            key: const Key('subcontract-draw-detail-go-draw'),
            type: UtenButtonType.danger,
            icon: Icons.move_to_inbox_rounded,
            onPressed: idle
                ? () => Navigator.of(context).pop(widget.orderItemId)
                : null,
            child: const Text('去领料'),
          ),
      ],
    );
  }

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';

  static String? _dateTime(String? value) {
    final parsed = ChinaDateTime.tryParse(value);
    return parsed == null ? null : ChinaDateTime.formatDateTime(parsed);
  }
}

/// 结束领料原因(必填，最多 200 字)。
class _CloseDrawReasonDialog extends StatefulWidget {
  const _CloseDrawReasonDialog({required this.task});

  final SubcontractDrawTaskRow task;

  @override
  State<_CloseDrawReasonDialog> createState() => _CloseDrawReasonDialogState();
}

class _CloseDrawReasonDialogState extends State<_CloseDrawReasonDialog> {
  static const _maxLength = 200;
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _reason.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请填写结束领料的原因');
      return;
    }
    if (text.length > _maxLength) {
      setState(() => _error = '原因最多 $_maxLength 字');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return AlertDialog(
      title: const Text('结束领料(不再发外)'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${task.orderBillNo} ${task.goodsName}：结束后会撤回未发出的领料、退回占用的库存，'
              '本任务不再出现在「领料」里，并重新判断是否短交。此操作不能撤销。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('subcontract-draw-close-reason'),
              controller: _reason,
              autofocus: true,
              maxLength: _maxLength,
              maxLines: 3,
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: '结束原因(必填)',
                  hintText: '如：委外商做不完，剩余数量不再加工',
                  error: _error == null
                      ? null
                      : UtenFieldMessage.error(_error!),
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('subcontract-draw-close-confirm'),
          type: UtenButtonType.danger,
          onPressed: _submit,
          child: const Text('结束领料'),
        ),
      ],
    );
  }
}
