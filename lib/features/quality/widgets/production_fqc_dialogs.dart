// 生产成品质检（FQC）详情与决定弹窗——待检处置工作台与 /quality/production-inspections
// 共用。原为 production_fqc_inspections_page.dart 的私有类，2026-09-01 待检处置
// 并入 FQC 任务后抽出，行为与测试 key 保持不变。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';

/// FQC 状态中文口径（列表列、详情头部共用）。
String fqcStatusLabel(ProductionFqcInspection inspection) =>
    switch (inspection.status) {
      'PENDING' => '待检',
      'PARTIAL' => '部分已决定',
      'RESOLVED' => '已全部决定',
      'CANCELLED' => '已取消（来源报工红冲或登记撤回）',
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
        ? '来源报工已红冲或仓库登记已撤回，本任务只读且不能再登记检验决定。'
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
          // V547/V542：来自仓库送检登记的只读事实（检查单、仓、库位、收货人、备注）。
          _detailLine('检查单号', inspection.sheetNo ?? '无检查单'),
          _detailLine('实际成品仓', inspection.warehouseName ?? '—'),
          _detailLine('库位', inspection.place ?? '—'),
          _detailLine('收货人', inspection.receiverName ?? '—'),
          _detailLine('登记备注', inspection.registrationRemark ?? '—'),
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
          const SizedBox(height: UtenSpacing.s12),
          BusinessAttachmentSection(
            ownerType: 'PRODUCTION_QUALITY_INSPECTION',
            ownerId: inspection.id,
            canView: ref
                .watch(currentPermissionsProvider)
                .contains(Perm.productionQualityInspectionView),
            canManage:
                widget.canApprove &&
                ref
                    .watch(currentPermissionsProvider)
                    .contains(Perm.productionQualityInspectionApprove) &&
                inspection.status == 'PENDING' &&
                inspection.passedQty == 0 &&
                inspection.failedQty == 0 &&
                inspection.remainingQty > 0,
            title: '检验图片和文件',
            categories: const ['检验照片', '检验报告', '其他证据'],
          ),
          if (ref
              .watch(currentPermissionsProvider)
              .contains(Perm.attachmentView))
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                '请在登记检验结果前添加证据。登记结果后（包括部分检验），文件保留供查阅，不能替换或删除。',
                style: theme.textTheme.bodySmall,
              ),
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
    final theme = Theme.of(context);
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
                  ignorePointers: false,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      label: fieldLabel(
                        '本次合格数量',
                        theme,
                        info: '合格数量会生成仓库待点收任务，尚不直接增加库存。',
                      ),
                    ),
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
                  ignorePointers: false,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      label: fieldLabel(
                        '不合格原因',
                        theme,
                        info: '至少 2 个字，保留为不可变质量决定证据。',
                      ),
                    ),
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

/// V547 品质检查单办理弹窗：同一成品仓一次送检的全部 FQC 行在一张单里办理。
///
/// 数量与决定仍按 inspection 逐条登记（PASS/PARTIAL/FAIL 复用既有弹窗）；
/// 「全部合格」= 对本单仍待检的行原子 pass-all。返回 true 表示本单发生过决定，
/// 调用方据此刷新队列与角标。
class ProductionFqcSheetDialog extends ConsumerStatefulWidget {
  const ProductionFqcSheetDialog({
    super.key,
    required this.sheetId,
    required this.canApprove,
  });

  final String sheetId;
  final bool canApprove;

  @override
  ConsumerState<ProductionFqcSheetDialog> createState() =>
      _ProductionFqcSheetDialogState();
}

class _ProductionFqcSheetDialogState
    extends ConsumerState<ProductionFqcSheetDialog> {
  ProductionFqcInspectionSheetDetail? _detail;
  bool _loading = true;
  bool _passingAll = false;
  bool _changed = false;
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
      final detail = await ref
          .read(productionFqcRepositoryProvider)
          .sheetDetail(widget.sheetId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
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

  Future<void> _openInspection(ProductionFqcInspection inspection) async {
    final target = await showDialog<ProductionFqcInspection>(
      context: context,
      builder: (_) => ProductionFqcDetailDialog(
        key: ValueKey('production-fqc-detail-${inspection.id}'),
        inspectionId: inspection.id,
        canApprove: widget.canApprove,
      ),
    );
    if (target == null || !mounted) return;
    await _decide(target);
  }

  Future<void> _decide(ProductionFqcInspection inspection) async {
    final result = await showDialog<ProductionFqcDecisionResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProductionFqcDecisionDialog(inspection: inspection),
    );
    if (result == null || !mounted) return;
    _changed = true;
    await _load();
  }

  Future<void> _passAll() async {
    final detail = _detail;
    if (detail == null || _passingAll) return;
    final ids = detail.activeInspections.map((item) => item.id).toList();
    if (ids.isEmpty) return;
    setState(() => _passingAll = true);
    try {
      await ref
          .read(productionFqcRepositoryProvider)
          .passAll(
            inspectionIds: ids,
            idempotencyKey: 'fqc-sheet-pass-all-${const Uuid().v4()}',
          );
      if (!mounted) return;
      _changed = true;
      setState(() => _passingAll = false);
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _passingAll = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _passingAll = false;
        _error = '批量全部合格失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final activeCount = detail?.activeInspections.length ?? 0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: AlertDialog(
        title: Text(detail == null ? '品质检查单' : '品质检查单 ${detail.sheet.sheetNo}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
          child: _loading && detail == null
              ? const SizedBox(
                  height: 280,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              : _error != null && detail == null
              ? SizedBox(
                  height: 320,
                  child: UtenEmpty.error(
                    message: _error,
                    actionLabel: '重新加载',
                    onAction: _load,
                  ),
                )
              : _buildBody(theme, detail!),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_changed),
            child: const Text('关闭'),
          ),
          if (widget.canApprove && activeCount > 0)
            UtenButton(
              key: const Key('production-fqc-sheet-pass-all'),
              icon: Icons.done_all_rounded,
              isLoading: _passingAll,
              onPressed: _passingAll ? null : _passAll,
              child: Text('全部合格($activeCount)'),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    ProductionFqcInspectionSheetDetail detail,
  ) {
    final sheet = detail.sheet;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.42,
              ),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                        '${sheet.warehouseName ?? '—'} · 收货人 ${sheet.receiverName ?? '—'}'
                        ' · ${sheet.itemCount} 行（待检 ${sheet.activeCount}）'
                        '${sheet.pendingQtyText == null ? '' : ' · 待检 ${sheet.pendingQtyText}'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (sheet.remark?.isNotEmpty == true) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '登记备注：${sheet.remark}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '进入质检 ${ChinaDateTime.formatInstant(sheet.createdAt)}'
                  '${sheet.reportNos == null ? '' : ' · 报工 ${sheet.reportNos}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          for (final inspection in detail.inspections)
            ListTile(
              key: ValueKey('production-fqc-sheet-line-${inspection.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => _openInspection(inspection),
              title: Text(
                '${inspection.goodsName ?? ''}'
                '${inspection.colorName?.isNotEmpty == true ? '(${inspection.colorName})' : ''}'
                ' · 报工 ${inspection.reportNo ?? '—'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${fqcStatusLabel(inspection)} · 报工 ${fqcQtyText(inspection.reportedQty)}'
                ' · 待检 ${fqcQtyText(inspection.remainingQty)}${inspection.unitName ?? ''}'
                '${inspection.place == null ? '' : ' · 库位 ${inspection.place}'}',
              ),
              trailing: inspection.active && widget.canApprove
                  ? TextButton.icon(
                      key: ValueKey(
                        'production-fqc-sheet-decide-${inspection.id}',
                      ),
                      onPressed: () => _decide(inspection),
                      icon: const Icon(Icons.rule_rounded, size: 18),
                      label: const Text('登记决定'),
                    )
                  : const Icon(Icons.chevron_right_rounded),
            ),
        ],
      ),
    );
  }
}
