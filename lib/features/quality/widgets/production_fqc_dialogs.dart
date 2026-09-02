// 生产成品质检（FQC）详情与决定弹窗——待检处置工作台与 /quality/production-inspections
// 共用。原为 production_fqc_inspections_page.dart 的私有类，2026-09-01 待检处置
// 并入 FQC 任务后抽出，行为与测试 key 保持不变。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';

/// FQC 状态中文口径（列表列、详情头部共用）。
String fqcStatusLabel(ProductionFqcInspection inspection) =>
    switch (inspection.status) {
      'PENDING' => '待检',
      'PARTIAL' => '部分已决定',
      'RESOLVED' => '已全部决定',
      'CANCELLED' => '来源报工已红冲',
      _ => inspection.status,
    };

/// 数量展示（去尾零，保留实际精度）。
String fqcQtyText(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

/// FQC 任务详情弹窗（只读；可决定账号额外暴露「登记检验决定」入口）。
///
/// 返回值：需要登记决定的 inspection（调用方接着打开 [ProductionFqcDecisionDialog]）。
class ProductionFqcDetailDialog extends ConsumerStatefulWidget {
  const ProductionFqcDetailDialog({
    super.key,
    required this.inspectionId,
    required this.canApprove,
  });

  final String inspectionId;
  final bool canApprove;

  @override
  ConsumerState<ProductionFqcDetailDialog> createState() =>
      _ProductionFqcDetailDialogState();
}

class _ProductionFqcDetailDialogState
    extends ConsumerState<ProductionFqcDetailDialog> {
  ProductionFqcInspection? _inspection;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
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
      setState(() {
        _inspection = inspection;
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

  @override
  Widget build(BuildContext context) {
    final inspection = _inspection;
    return AlertDialog(
      title: const Text('生产成品质检详情'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: _loading
            ? const SizedBox(
                height: 280,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null
            ? SizedBox(
                height: 320,
                child: UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                ),
              )
            : SingleChildScrollView(child: _buildDetail(inspection!)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (inspection != null && inspection.active && widget.canApprove)
          FilledButton.icon(
            key: ValueKey('production-fqc-decide-${inspection.id}'),
            onPressed: () => Navigator.of(context).pop(inspection),
            icon: const Icon(Icons.rule_rounded),
            label: const Text('登记检验决定'),
          ),
      ],
    );
  }

  Widget _buildDetail(ProductionFqcInspection inspection) {
    final theme = Theme.of(context);
    final readOnlyReason = inspection.active
        ? '当前为只读查看；登记决定需要生产质检审批权限，且账号必须属于品质任务组织。'
        : inspection.status == 'CANCELLED'
        ? '来源报工已红冲，本任务只读且不能再登记检验决定。'
        : '该任务已完成决定，当前详情只读。';
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.42,
              ),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              fqcStatusLabel(inspection),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          _detailLine('报工单', inspection.reportNo ?? '—'),
          _detailLine('生产计划', inspection.planNo ?? '—'),
          _detailLine(
            '货品',
            [
              inspection.goodsCode,
              inspection.goodsName,
            ].whereType<String>().join(' '),
          ),
          _detailLine('颜色', inspection.colorName ?? '—'),
          _detailLine('单位', inspection.unitName ?? '—'),
          const Divider(height: UtenSpacing.s24),
          _detailLine('报工数量', fqcQtyText(inspection.reportedQty)),
          _detailLine('合格数量', fqcQtyText(inspection.passedQty)),
          _detailLine('不合格数量', fqcQtyText(inspection.failedQty)),
          _detailLine('待检数量', fqcQtyText(inspection.remainingQty)),
          _detailLine('已生成待点收', fqcQtyText(inspection.authorizedInboundQty)),
          const Divider(height: UtenSpacing.s24),
          _detailLine(
            '进入质检时间',
            ChinaDateTime.formatInstant(inspection.createdAt),
          ),
          _detailLine(
            '更新时间',
            ChinaDateTime.formatInstant(inspection.updatedAt),
          ),
          if (!inspection.active || !widget.canApprove) ...[
            const SizedBox(height: UtenSpacing.s8),
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
                    readOnlyReason,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 112, child: Text('$label：')),
        Expanded(child: Text(value.isEmpty ? '—' : value)),
      ],
    ),
  );
}

/// FQC 检验决定弹窗：合格 / 部分合格 / 不合格（含处置方式与原因）。
///
/// 提交成功后 pop 回 [ProductionFqcDecisionResult]；失败留在弹窗内可重试
/// （幂等键在弹窗生命周期内复用）。
class ProductionFqcDecisionDialog extends ConsumerStatefulWidget {
  const ProductionFqcDecisionDialog({super.key, required this.inspection});

  final ProductionFqcInspection inspection;

  @override
  ConsumerState<ProductionFqcDecisionDialog> createState() =>
      _ProductionFqcDecisionDialogState();
}

class _ProductionFqcDecisionDialogState
    extends ConsumerState<ProductionFqcDecisionDialog> {
  String _decision = 'PASS';
  String _disposition = 'REWORK';
  late final TextEditingController _passQty;
  late final TextEditingController _failQty;
  final TextEditingController _reason = TextEditingController();
  final String _idempotencyKey = 'fqc-decision-${const Uuid().v4()}';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _passQty = TextEditingController(
      text: fqcQtyText(widget.inspection.remainingQty),
    );
    _failQty = TextEditingController(
      text: fqcQtyText(widget.inspection.remainingQty),
    );
  }

  @override
  void dispose() {
    _passQty.dispose();
    _failQty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final remaining = widget.inspection.remainingQty;
    final pass = double.tryParse(_passQty.text.trim());
    final fail = double.tryParse(_failQty.text.trim());
    String? validation;
    if (_decision == 'PASS') {
      if (pass == null || pass <= 0 || pass > remaining + 0.000001) {
        validation = '合格数量必须大于 0 且不超过待检数量';
      }
    } else if (_decision == 'FAIL') {
      if (fail == null || fail <= 0 || fail > remaining + 0.000001) {
        validation = '不合格数量必须大于 0 且不超过待检数量';
      }
    } else {
      if (pass == null ||
          pass <= 0 ||
          fail == null ||
          fail <= 0 ||
          pass + fail > remaining + 0.000001) {
        validation = '部分决定必须同时填写正的合格/不合格数量，且合计不超过待检数量';
      }
    }
    if (_decision != 'PASS' && _reason.text.trim().length < 2) {
      validation ??= '不合格或部分决定必须填写至少 2 个字的原因';
    }
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionFqcRepositoryProvider)
          .decide(
            id: widget.inspection.id,
            decision: _decision,
            idempotencyKey: _idempotencyKey,
            passQty: _decision == 'FAIL' ? null : pass,
            failQty: _decision == 'PASS' ? null : fail,
            dispositionCode: _decision == 'PASS' ? null : _disposition,
            reason: _decision == 'PASS' ? null : _reason.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '质检决定保存失败，请保持本窗口并重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登记生产成品质检决定'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '待检 ${fqcQtyText(widget.inspection.remainingQty)} '
                '${widget.inspection.unitName ?? ''}',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final entry in const [
                    ('PASS', '合格'),
                    ('PARTIAL', '部分合格'),
                    ('FAIL', '不合格'),
                  ])
                    ChoiceChip(
                      label: Text(entry.$2),
                      selected: _decision == entry.$1,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() => _decision = entry.$1),
                    ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (_decision != 'FAIL')
                TextField(
                  controller: _passQty,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '本次合格数量',
                    // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing rejects LayoutBuilder helper widgets.
                    helperText: '合格数量会生成仓库待点收任务，尚不直接增加库存。',
                  ),
                ),
              if (_decision != 'PASS') ...[
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _failQty,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '本次不合格数量'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                DropdownButtonFormField<String>(
                  initialValue: _disposition,
                  decoration: const InputDecoration(labelText: '不合格处置'),
                  items: const [
                    DropdownMenuItem(value: 'REWORK', child: Text('返工')),
                    DropdownMenuItem(value: 'SCRAP', child: Text('报废')),
                    DropdownMenuItem(value: 'REJECT', child: Text('拒收/退回')),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) =>
                            setState(() => _disposition = value ?? 'REWORK'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _reason,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '不合格原因',
                    // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing rejects LayoutBuilder helper widgets.
                    helperText: '至少 2 个字，保留为不可变质量决定证据。',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: Text(_saving ? '保存中…' : '确认决定'),
        ),
      ],
    );
  }
}
