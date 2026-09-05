import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/warehouse_iqc_stock_in.dart';

class WarehouseInboundAllocationSection {
  const WarehouseInboundAllocationSection({
    required this.id,
    required this.goodsLabel,
    required this.quantity,
    required this.allocations,
    this.unitName,
    this.sourceOrderNo,
  });

  final String id;
  final String goodsLabel;
  final double quantity;
  final String? unitName;
  final String? sourceOrderNo;
  final List<WarehouseInboundAllocation> allocations;

  List<WarehouseInboundAllocation> previewAllocations() =>
      warehouseInboundAllocationPreview(allocations, quantity);
}

class WarehouseInboundAllocationSummary extends StatelessWidget {
  const WarehouseInboundAllocationSummary({
    super.key,
    required this.allocations,
    required this.qtyText,
    this.previewQty,
    this.onTap,
  });

  final List<WarehouseInboundAllocation> allocations;
  final double? previewQty;
  final String Function(double value) qtyText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final visible = previewQty == null
        ? allocations.where((item) => item.qty > 0).toList(growable: false)
        : warehouseInboundAllocationPreview(allocations, previewQty!);
    final text = warehouseInboundAllocationSummaryText(visible, qtyText);
    final mismatch = visible.any((item) => item.isCrossWarehouse);
    final unknown = visible.any(
      (item) => item.kind == WarehouseInboundAllocationKind.unknown,
    );
    final theme = Theme.of(context);
    final color = mismatch || unknown
        ? theme.colorScheme.error
        : visible.isEmpty
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Row(
        children: [
          Icon(
            mismatch
                ? Icons.warning_amber_rounded
                : visible.isEmpty
                ? Icons.help_outline_rounded
                : Icons.account_tree_outlined,
            size: 18,
            color: color,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: mismatch || unknown || visible.isNotEmpty
                    ? FontWeight.w700
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: '$text${onTap == null ? '' : '，点击查看去向明细'}',
      child: onTap == null
          ? child
          : InkWell(borderRadius: UtenRadius.smAll, onTap: onTap, child: child),
    );
  }
}

String warehouseInboundAllocationSummaryText(
  Iterable<WarehouseInboundAllocation> allocations,
  String Function(double value) qtyText,
) {
  final values = allocations.where((item) => item.qty > 0).toList();
  if (values.isEmpty) return '未返回预定去向';
  if (values.any((item) => item.isCrossWarehouse)) {
    final mismatchQty = values
        .where((item) => item.isCrossWarehouse)
        .fold<double>(0, (sum, item) => sum + item.qty);
    final total = values.fold<double>(0, (sum, item) => sum + item.qty);
    return mismatchQty + 0.0000001 >= total
        ? '跨仓 · 本次全量 ${qtyText(mismatchQty)} 不绑定计划'
        : '跨仓部分 ${qtyText(mismatchQty)} 不绑定计划 · 其余按预定分配';
  }
  const order = [
    WarehouseInboundAllocationKind.formalDemand,
    WarehouseInboundAllocationKind.exactAnalysis,
    WarehouseInboundAllocationKind.sharedClaim,
    WarehouseInboundAllocationKind.publicStock,
    WarehouseInboundAllocationKind.unknown,
  ];
  final totals = <WarehouseInboundAllocationKind, double>{};
  for (final item in values) {
    totals.update(
      item.kind,
      (value) => value + item.qty,
      ifAbsent: () => item.qty,
    );
  }
  return [
    for (final kind in order)
      if ((totals[kind] ?? 0) > 0) '${kind.label} ${qtyText(totals[kind]!)}',
  ].join(' · ');
}

Future<void> showWarehouseInboundAllocationDetails(
  BuildContext context, {
  required String title,
  required List<WarehouseInboundAllocationSection> sections,
  bool actual = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => _WarehouseInboundAllocationDialog(
    title: title,
    description: actual
        ? '以下为本次实际入库形成的生产预留与公共库存事实。'
        : '以下为按当前输入数量顺序截取的预计去向；提交时服务端会重新锁定并复核。',
    sections: sections,
    actual: actual,
  ),
);

Future<bool> showWarehouseInboundAllocationConfirmDialog(
  BuildContext context, {
  required String title,
  required String description,
  required String actionLabel,
  required List<WarehouseInboundAllocationSection> sections,
  bool ownRelease = false,
  String confirmLabel = '确认入库',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _WarehouseInboundAllocationDialog(
        title: title,
        description: description,
        sections: sections,
        actual: false,
        confirmLabel: confirmLabel,
        reviewerActionLabel: actionLabel,
        ownRelease: ownRelease,
      ),
    ) ??
    false;

Future<void> showWarehouseInboundAllocationResultDialog(
  BuildContext context, {
  required String title,
  required String description,
  required List<WarehouseInboundAllocationSection> sections,
}) => showDialog<void>(
  context: context,
  builder: (_) => _WarehouseInboundAllocationDialog(
    title: title,
    description: description,
    sections: sections,
    actual: true,
  ),
);

class _WarehouseInboundAllocationDialog extends StatelessWidget {
  const _WarehouseInboundAllocationDialog({
    required this.title,
    required this.description,
    required this.sections,
    required this.actual,
    this.confirmLabel,
    this.reviewerActionLabel,
    this.ownRelease = false,
  });

  final String title;
  final String description;
  final List<WarehouseInboundAllocationSection> sections;
  final bool actual;
  final String? confirmLabel;
  final String? reviewerActionLabel;
  final bool ownRelease;

  bool get _confirming => confirmLabel != null;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: Key(
        actual
            ? 'warehouse-inbound-allocation-result-dialog'
            : _confirming
            ? 'warehouse-inbound-allocation-confirm-dialog'
            : 'warehouse-inbound-allocation-detail-dialog',
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s24,
      ),
      title: Text(title),
      content: SizedBox(
        width: (size.width - 64).clamp(280.0, 760.0),
        height: (size.height - 190).clamp(320.0, 680.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            if (_confirming) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenReviewerResponsibilityNotice(
                actionLabel: reviewerActionLabel ?? '仓库实物入库确认',
                description: ownRelease
                    ? '本单品质放行也由当前账号执行，请再次核对实物数量、库位和预计去向。'
                    : '请核对本次实物数量、库位和预计去向；最终分配以提交事务返回为准。',
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: ListView.separated(
                itemCount: sections.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: UtenSpacing.s12),
                itemBuilder: (_, index) => _AllocationSectionCard(
                  section: sections[index],
                  actual: actual,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.pop(context, _confirming ? false : null),
          child: Text(_confirming ? '返回修改' : '关闭'),
        ),
        if (_confirming)
          UtenButton(
            key: const Key('warehouse-inbound-allocation-confirm'),
            icon: Icons.inventory_2_outlined,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel!),
          ),
      ],
    );
  }
}

class _AllocationSectionCard extends StatelessWidget {
  const _AllocationSectionCard({required this.section, required this.actual});

  final WarehouseInboundAllocationSection section;
  final bool actual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allocations = actual
        ? section.allocations
              .where((item) => item.qty > 0)
              .toList(growable: false)
        : section.previewAllocations();
    final unit = section.unitName?.trim().isNotEmpty == true
        ? ' ${section.unitName}'
        : '';
    final mismatch = allocations
        .where((item) => item.isCrossWarehouse)
        .toList();
    final allocationTotal = allocations.fold<double>(
      0,
      (sum, item) => sum + item.qty,
    );
    final conservationDelta = section.quantity - allocationTotal;
    return Semantics(
      container: true,
      label:
          '${section.goodsLabel}，本次数量 ${_qty(section.quantity)}$unit，'
          '${warehouseInboundAllocationSummaryText(allocations, _qty)}',
      child: Container(
        key: ValueKey('warehouse-inbound-allocation-section-${section.id}'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              section.goodsLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '${actual ? '实际入库' : '本次预计入库'} ${_qty(section.quantity)}$unit'
              '${section.sourceOrderNo?.isNotEmpty == true ? ' · 来源订货 ${section.sourceOrderNo}' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (mismatch.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              _CrossWarehouseWarning(
                allocations: mismatch,
                allAllocations: allocations,
                sectionQuantity: section.quantity,
                unit: unit,
              ),
            ],
            if (actual && conservationDelta.abs() > 0.0000001) ...[
              const SizedBox(height: UtenSpacing.s8),
              _AllocationConservationWarning(
                actualQty: section.quantity,
                allocationQty: allocationTotal,
                unit: unit,
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            if (allocations.isEmpty)
              Text(
                actual
                    ? '旧版响应未返回实际去向明细；本次入库已完成，请以刷新后的入库历史为准。'
                    : '旧版响应未返回预计去向；提交后仍由服务端按实时权益和目标仓权威分配。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final allocation in allocations) ...[
                _AllocationRow(
                  allocation: allocation,
                  fallbackProductLabel: section.goodsLabel,
                  unit: unit,
                  actual: actual,
                ),
                if (allocation != allocations.last)
                  const Divider(height: UtenSpacing.s16),
              ],
          ],
        ),
      ),
    );
  }
}

class _AllocationRow extends StatelessWidget {
  const _AllocationRow({
    required this.allocation,
    required this.fallbackProductLabel,
    required this.unit,
    required this.actual,
  });

  final WarehouseInboundAllocation allocation;
  final String fallbackProductLabel;
  final String unit;
  final bool actual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _kindColor(theme, allocation.kind);
    final product = allocation.productLabel.isEmpty
        ? fallbackProductLabel
        : allocation.productLabel;
    final facts = <String>[
      if (allocation.sourceLabel?.isNotEmpty == true) allocation.sourceLabel!,
      if (allocation.planNo?.isNotEmpty == true) '计划 ${allocation.planNo}',
      if (allocation.executionSegmentCode?.isNotEmpty == true)
        '工单 ${allocation.executionSegmentCode}',
      if (allocation.workshopName?.isNotEmpty == true)
        '车间 ${allocation.workshopName}',
      if (allocation.responsibleEmployeeName?.isNotEmpty == true)
        '负责人 ${allocation.responsibleEmployeeName}',
      if (allocation.targetWarehouseName?.isNotEmpty == true)
        '目标仓 ${allocation.targetWarehouseName}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: UtenRadius.pillAll,
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),
                child: Text(
                  allocation.kind.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '数量 ${_qty(allocation.qty)}$unit',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(product, style: theme.textTheme.bodyMedium),
          if (facts.isNotEmpty)
            Text(
              facts.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          if (allocation.formationStatus?.isNotEmpty == true)
            Text(
              allocation.formationStatus!,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          if (actual && allocation.hasFormalWorkOrder)
            Text(
              '已预留到正式工单；是否完整齐套、可领料以车间任务和领料单实时状态为准。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _CrossWarehouseWarning extends StatelessWidget {
  const _CrossWarehouseWarning({
    required this.allocations,
    required this.allAllocations,
    required this.sectionQuantity,
    required this.unit,
  });

  final List<WarehouseInboundAllocation> allocations;
  final List<WarehouseInboundAllocation> allAllocations;
  final double sectionQuantity;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actual =
        allocations
            .map((item) => item.actualWarehouseName)
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .firstOrNull ??
        '本次实际仓';
    final intended = <String>{
      for (final item in allocations) ...item.intendedWarehouseNames,
      for (final item in allocations) ?item.targetWarehouseName,
    }.where((name) => name.isNotEmpty).join(' / ');
    final mismatchQty = allocations.fold<double>(
      0,
      (sum, item) => sum + item.qty,
    );
    final matchingQty = allAllocations
        .where((item) => !item.isCrossWarehouse)
        .fold<double>(0, (sum, item) => sum + item.qty);
    final scope = matchingQty > 0
        ? '跨仓部分 ${_qty(mismatchQty)}$unit 不绑定计划，按实际仓进入公共库存；其余按上方预定分配'
        : mismatchQty + 0.0000001 >= sectionQuantity
        ? '本次全量 ${_qty(mismatchQty)}$unit 不绑定计划，按实际仓进入公共库存'
        : '跨仓部分 ${_qty(mismatchQty)}$unit 不绑定计划，按实际仓进入公共库存；其余去向待确认';
    final message =
        '实际 $actual，预定 ${intended.isEmpty ? '其它目标仓' : intended}；$scope。';
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        key: const Key('warehouse-inbound-allocation-cross-warehouse'),
        padding: const EdgeInsets.all(UtenSpacing.s8),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: UtenRadius.smAll,
          border: Border.all(color: theme.colorScheme.error),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w800,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllocationConservationWarning extends StatelessWidget {
  const _AllocationConservationWarning({
    required this.actualQty,
    required this.allocationQty,
    required this.unit,
  });

  final double actualQty;
  final double allocationQty;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = actualQty - allocationQty;
    final message = delta > 0
        ? '实际去向合计 ${_qty(allocationQty)}$unit，小于本次入库 '
              '${_qty(actualQty)}$unit；差额 ${_qty(delta)}$unit 去向待确认。'
        : '实际去向合计 ${_qty(allocationQty)}$unit，超过本次入库 '
              '${_qty(actualQty)}$unit；超出 ${_qty(-delta)}$unit，请立即复核。';
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        key: const Key('warehouse-inbound-allocation-conservation-warning'),
        padding: const EdgeInsets.all(UtenSpacing.s8),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: UtenRadius.smAll,
          border: Border.all(color: theme.colorScheme.error),
        ),
        child: Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onErrorContainer,
            fontWeight: FontWeight.w800,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

Color _kindColor(ThemeData theme, WarehouseInboundAllocationKind kind) =>
    switch (kind) {
      WarehouseInboundAllocationKind.exactAnalysis => theme.colorScheme.primary,
      WarehouseInboundAllocationKind.sharedClaim => theme.colorScheme.secondary,
      WarehouseInboundAllocationKind.formalDemand => UtenColors.success,
      WarehouseInboundAllocationKind.publicStock => theme.colorScheme.tertiary,
      WarehouseInboundAllocationKind.unknown => theme.colorScheme.error,
    };

String _qty(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
