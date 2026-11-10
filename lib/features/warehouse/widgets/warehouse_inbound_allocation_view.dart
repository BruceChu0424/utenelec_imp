import '../../../shared/formatters/exact_decimal.dart';
import '../../../core/formatters/exact_number_text.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_confirmation_summary.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
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
  final Object quantity;
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
  final Object? previewQty;
  final String Function(Object value) qtyText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final visible = previewQty == null
        ? allocations
              .where(
                (item) =>
                    (warehouseInboundQuantityUnits(item.quantityText) ??
                        BigInt.zero) >
                    BigInt.zero,
              )
              .toList(growable: false)
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
    // 2026-10-06 行高统一口径：去向摘要单行省略号，完整文本挂 Tooltip；
    // 不再用两行文本 + 上下 Padding 把表格行撑高。
    final child = Row(
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
          child: Tooltip(
            message: text,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: mismatch || unknown || visible.isNotEmpty
                    ? FontWeight.w700
                    : null,
              ),
            ),
          ),
        ),
      ],
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
  String Function(Object value) qtyText,
) {
  final source = allocations.toList(growable: false);
  if (source.any(
    (item) => warehouseInboundQuantityUnits(item.quantityText) == null,
  )) {
    return '去向数量待核对';
  }
  final values = source
      .where(
        (item) =>
            warehouseInboundQuantityUnits(item.quantityText)! > BigInt.zero,
      )
      .toList(growable: false);
  if (values.isEmpty) return '未返回预定去向';
  if (values.any((item) => item.isCrossWarehouse)) {
    final mismatch = values
        .where((item) => item.isCrossWarehouse)
        .fold(
          BigInt.zero,
          (sum, item) =>
              sum + warehouseInboundQuantityUnits(item.quantityText)!,
        );
    final total = values.fold(
      BigInt.zero,
      (sum, item) => sum + warehouseInboundQuantityUnits(item.quantityText)!,
    );
    return mismatch == total
        ? '跨仓 · 本次全量 ${qtyText(warehouseInboundQuantityText(mismatch))} 不绑定计划'
        : '跨仓部分 ${qtyText(warehouseInboundQuantityText(mismatch))} 不绑定计划 · 其余按预定分配';
  }
  const order = [
    WarehouseInboundAllocationKind.formalDemand,
    WarehouseInboundAllocationKind.exactAnalysis,
    WarehouseInboundAllocationKind.sharedClaim,
    WarehouseInboundAllocationKind.publicStock,
    WarehouseInboundAllocationKind.unknown,
  ];
  final totals = <WarehouseInboundAllocationKind, BigInt>{};
  for (final item in values) {
    totals.update(
      item.kind,
      (v) => v + warehouseInboundQuantityUnits(item.quantityText)!,
      ifAbsent: () => warehouseInboundQuantityUnits(item.quantityText)!,
    );
  }
  return [
    for (final kind in order)
      if ((totals[kind] ?? BigInt.zero) > BigInt.zero)
        '${kind.label} ${qtyText(warehouseInboundQuantityText(totals[kind]!))}',
  ].join(' · ');
}

String _sumQuantities(Iterable<WarehouseInboundAllocation> items) =>
    financeExactSumTexts(items.map((item) => item.quantityText)) ?? '待核对';

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
        ? '以下为本次实际入库形成的生产预留与公共库存。'
        : '以下为按当前输入数量顺序截取的预计去向；提交时系统会按最新数据重新锁定核对。',
    sections: sections,
    actual: actual,
  ),
);

Future<bool> showWarehouseInboundAllocationConfirmDialog(
  BuildContext context, {
  required String title,
  required UtenConfirmationSummary summary,
  required String actionLabel,
  required List<WarehouseInboundAllocationSection> sections,
  bool ownRelease = false,
  String confirmLabel = '确认入库',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _WarehouseInboundAllocationDialog(
        title: title,
        summary: summary,
        sections: sections,
        actual: false,
        confirmLabel: confirmLabel,
        reviewerActionLabel: actionLabel,
        ownRelease: ownRelease,
      ),
    ) ??
    false;

// 2026-09-16：showWarehouseInboundAllocationResultDialog（提交成功后弹
// 「入库完成 · 实际去向」中间结果框）已退役——全站口径改为「提交期间全屏加载
// 遮罩 + 成功后顶部通知条」，实际去向明细统一落页内入库历史/详情查看。

class _WarehouseInboundAllocationDialog extends StatelessWidget {
  const _WarehouseInboundAllocationDialog({
    required this.title,
    required this.sections,
    required this.actual,
    this.description = '',
    this.summary,
    this.confirmLabel,
    this.reviewerActionLabel,
    this.ownRelease = false,
  }) : assert(confirmLabel == null || summary != null);

  final String title;
  final String description;
  final UtenConfirmationSummary? summary;
  final List<WarehouseInboundAllocationSection> sections;
  final bool actual;
  final String? confirmLabel;
  final String? reviewerActionLabel;
  final bool ownRelease;

  bool get _confirming => confirmLabel != null;

  @override
  Widget build(BuildContext context) {
    // Confirmation shows aggregate facts only. Item allocations remain in the
    // dedicated detail window; real cross-warehouse or unknown scope is visible.
    if (_confirming) {
      return UtenAlertDialog(
        scrollable: false,
        key: const Key('warehouse-inbound-allocation-confirm-dialog'),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s24,
        ),
        title: Text(title),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenReviewerResponsibilityNotice(
                  actionLabel: reviewerActionLabel ?? '仓库实物入库确认',
                  compact: true,
                ),
                const SizedBox(height: UtenSpacing.s8),
                if (ownRelease)
                  UtenConfirmationSummary(
                    key: summary!.key,
                    facts: [
                      ...summary!.facts,
                      const UtenConfirmationFact(
                        label: '本单品质放行',
                        value: '由当前账号执行',
                        info: '请再次核对实物和库位。',
                      ),
                    ],
                    consequences: summary!.consequences,
                  )
                else
                  summary!,
                _ConfirmAllocationWarnings(sections: sections),
              ],
            ),
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回修改'),
          ),
          UtenButton(
            key: const Key('warehouse-inbound-allocation-confirm'),
            icon: Icons.inventory_2_outlined,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel!),
          ),
        ],
      );
    }
    final size = MediaQuery.sizeOf(context);
    return UtenAlertDialog(
      showCloseButton: true,
      headingIcon: Icons.info_outline_rounded,
      onClose: () => Navigator.pop(context, _confirming ? false : null),
      key: Key(
        actual
            ? 'warehouse-inbound-allocation-result-dialog'
            : 'warehouse-inbound-allocation-detail-dialog',
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s24,
      ),
      title: Row(
        children: [
          Flexible(child: Text(title)),
          if (description.isNotEmpty)
            UtenFieldHintIcon(info: description, dense: true),
        ],
      ),
      content: SizedBox(
        width: (size.width - 64).clamp(280.0, 760.0),
        height: (size.height - 190).clamp(320.0, 680.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
    );
  }
}

/// Actual exceptions stay visible without repeating every goods line.
class _ConfirmAllocationWarnings extends StatelessWidget {
  const _ConfirmAllocationWarnings({required this.sections});

  final List<WarehouseInboundAllocationSection> sections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previews = [
      for (final section in sections) section.previewAllocations(),
    ];
    final crossRows = previews.where(
      (allocations) => allocations.any((item) => item.isCrossWarehouse),
    );
    final mismatch = [
      for (final allocations in crossRows)
        ...allocations.where((item) => item.isCrossWarehouse),
    ];
    final unknownCount = previews
        .where(
          (allocations) => allocations.any(
            (item) => item.kind == WarehouseInboundAllocationKind.unknown,
          ),
        )
        .length;
    final actual = {
      for (final item in mismatch)
        if (item.actualWarehouseName?.isNotEmpty == true)
          item.actualWarehouseName!,
    }.join(' / ');
    final intended = {
      for (final item in mismatch) ...item.intendedWarehouseNames,
      for (final item in mismatch)
        if (item.targetWarehouseName?.isNotEmpty == true)
          item.targetWarehouseName!,
    }.where((name) => name.isNotEmpty).join(' / ');
    final messages = [
      if (mismatch.isNotEmpty)
        '跨仓 ${crossRows.length} 行：实际 ${actual.isEmpty ? '本次实际仓' : actual}，'
            '预定 ${intended.isEmpty ? '其他目标仓' : intended}；'
            '跨仓部分按实际仓进入公共库存，不绑定原计划。',
      if (unknownCount > 0) '$unknownCount 行预计去向待核对，提交时仍按最新来源与仓库校验。',
    ];
    if (messages.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Semantics(
        liveRegion: true,
        child: Text(
          messages.join('\n'),
          key: Key(
            mismatch.isNotEmpty
                ? 'warehouse-inbound-allocation-cross-warehouse'
                : 'warehouse-inbound-allocation-unknown',
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
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
              .where(
                (item) =>
                    (warehouseInboundQuantityUnits(item.quantityText) ??
                        BigInt.zero) >
                    BigInt.zero,
              )
              .toList(growable: false)
        : section.previewAllocations();
    final unit = section.unitName?.trim().isNotEmpty == true
        ? ' ${section.unitName}'
        : '';
    final mismatch = allocations
        .where((item) => item.isCrossWarehouse)
        .toList();
    final allocationTotal = _sumQuantities(allocations);
    final sourceUnits = warehouseInboundQuantityUnits(section.quantity),
        allocationUnits = warehouseInboundQuantityUnits(allocationTotal);
    final conservationComplete =
        sourceUnits != null &&
        allocationUnits != null &&
        sourceUnits == allocationUnits;
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
            if (actual && !conservationComplete) ...[
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
                    ? '当前版本数据里没有实际去向明细；本次入库已完成，请以刷新后的入库历史为准。'
                    : '当前版本数据里没有预计去向；提交后系统会按最新的预定量和所选仓库重新分配。',
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
                '数量 ${_qty(allocation.quantityText ?? '待核对')}$unit',
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
  final Object sectionQuantity;
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
    final mismatchQty = _sumQuantities(allocations);
    final matchingQty = warehouseInboundQuantityUnits(
      _sumQuantities(allAllocations.where((item) => !item.isCrossWarehouse)),
    );
    final mismatchUnits = warehouseInboundQuantityUnits(mismatchQty),
        sectionUnits = warehouseInboundQuantityUnits(sectionQuantity);
    final scope = matchingQty != null && matchingQty > BigInt.zero
        ? '跨仓部分 ${_qty(mismatchQty)}$unit 不绑定计划，按实际仓进入公共库存；其余按上方预定分配'
        : mismatchUnits != null &&
              sectionUnits != null &&
              mismatchUnits >= sectionUnits
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

  final Object actualQty;
  final Object allocationQty;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actualUnits = warehouseInboundQuantityUnits(actualQty),
        allocatedUnits = warehouseInboundQuantityUnits(allocationQty);
    final delta = actualUnits == null || allocatedUnits == null
        ? null
        : actualUnits - allocatedUnits;
    final message = delta == null
        ? '实际去向缺少完整精确数量，请核对原入库记录。'
        : delta > BigInt.zero
        ? '实际去向合计 ${_qty(allocationQty)}$unit，小于本次入库 '
              '${_qty(actualQty)}$unit；差额 ${_qty(warehouseInboundQuantityText(delta))}$unit 去向待确认。'
        : '实际去向合计 ${_qty(allocationQty)}$unit，超过本次入库 '
              '${_qty(actualQty)}$unit；超出 ${_qty(warehouseInboundQuantityText(-delta))}$unit，请立即复核。';
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

String _qty(Object value) => exactNumberDisplay(value) ?? '待核对';
