import 'package:flutter/material.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_material_analysis.dart';

/// 按 goods/color/unit 去重后的第二数量切片。
///
/// 2026-09-05 起「下达采购/委外」不再弹逐行数量编辑对话框：数量直接在分桶
/// 表格行内编辑（默认=本批缺口−已在途），本类只承载提交单元的口径数据。
final class MaterialSupplyQuantityEntry {
  const MaterialSupplyQuantityEntry({
    required this.actionGroupKey,
    required this.materialLineId,
    required this.label,
    required this.dimensionKey,
    required this.openQty,
    required this.maxQty,
    required this.safetyStockQty,
    required this.publicAvailableQty,
    required this.openSafetySupplyQty,
    required this.safetyReplenishmentGapQty,
    this.safetyReplenishmentQty = 0,
    this.rootAllocatedStockQty = 0,
    this.safetyDeduplicatedElsewhere = false,
    this.allowPublicExtra = false,
    this.spec,
    this.unitName,
  });

  final String? actionGroupKey;
  final String? materialLineId;
  final String label;
  final String dimensionKey;
  final String? spec;
  final String? unitName;
  final double openQty;

  /// 本批可提交上限（本批缺口 − 已在途需求）；行内编辑的默认值。
  final double maxQty;
  final double rootAllocatedStockQty;
  final double safetyStockQty;
  final double publicAvailableQty;
  final double openSafetySupplyQty;
  final double safetyReplenishmentGapQty;
  final double safetyReplenishmentQty;
  final bool safetyDeduplicatedElsewhere;
  final bool allowPublicExtra;

  double totalQty(double demandQty) => demandQty + safetyReplenishmentQty;

  MaterialSupplyQuantityEntry withSafetyReplenishment(
    double qty, {
    required bool deduplicatedElsewhere,
  }) => MaterialSupplyQuantityEntry(
    actionGroupKey: actionGroupKey,
    materialLineId: materialLineId,
    label: label,
    dimensionKey: dimensionKey,
    spec: spec,
    unitName: unitName,
    openQty: openQty,
    maxQty: maxQty,
    rootAllocatedStockQty: rootAllocatedStockQty,
    safetyStockQty: safetyStockQty,
    publicAvailableQty: publicAvailableQty,
    openSafetySupplyQty: openSafetySupplyQty,
    safetyReplenishmentGapQty: safetyReplenishmentGapQty,
    safetyReplenishmentQty: qty,
    safetyDeduplicatedElsewhere: deduplicatedElsewhere,
    allowPublicExtra: allowPublicExtra,
  );

  MaterialSupplyQuantityInput toInput(
    double totalQty, {
    required bool allowOverDemand,
  }) {
    final canAddPublic = allowOverDemand && allowPublicExtra;
    final demandQty = totalQty > maxQty ? maxQty : totalQty;
    final publicExtraQty = canAddPublic && totalQty > maxQty
        ? totalQty - maxQty
        : 0.0;
    return MaterialSupplyQuantityInput(
      actionGroupKey: actionGroupKey,
      materialLineId: materialLineId,
      qty: demandQty,
      safetyReplenishmentQty: safetyReplenishmentQty,
      publicExtraQty: publicExtraQty,
    );
  }
}

/// 「下达采购 / 下达委外」的总结确认弹窗：品种数 + 合计数量 + 明细清单，
/// 数量修改已前移到分桶表格行内完成，这里只做最后一步确认（2026-09-05
/// 用户口径：不要再显示修改数量的弹窗，统一在表格里面修改）。
class MaterialSupplySubmitConfirmDialog extends StatelessWidget {
  const MaterialSupplySubmitConfirmDialog({
    super.key,
    required this.route,
    required this.entries,
    required this.quantities,
    required this.qtyText,
  });

  final MaterialSupplyRoute route;
  final List<MaterialSupplyQuantityEntry> entries;

  /// 与 [entries] 一一对应的行内编辑结果（下单总量，含允许的公共超量）。
  final List<double> quantities;
  final String Function(double?) qtyText;

  double get _demandTotal =>
      _fold((entry, qty) => qty > entry.maxQty ? entry.maxQty : qty);
  double get _publicExtraTotal =>
      _fold((entry, qty) => qty > entry.maxQty ? qty - entry.maxQty : 0.0);
  double get _safetyTotal =>
      entries.fold(0.0, (sum, entry) => sum + entry.safetyReplenishmentQty);
  double get _grandTotal => _demandTotal + _publicExtraTotal + _safetyTotal;

  double _fold(double Function(MaterialSupplyQuantityEntry, double) combine) {
    var total = 0.0;
    for (var i = 0; i < entries.length; i++) {
      final qty = quantities[i];
      total += combine(entries[i], qty);
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaSize = MediaQuery.sizeOf(context);
    final isBuy = route == MaterialSupplyRoute.buy;
    return AlertDialog(
      key: const Key('supply-submit-confirm-dialog'),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s24,
      ),
      title: Text('确认下达${route.label}'),
      content: SizedBox(
        width: (mediaSize.width - 64).clamp(280.0, 560.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '共 ${entries.length} 个品种，合计 ${qtyText(_grandTotal)}。',
                key: const Key('supply-submit-confirm-total'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                [
                  '本批需求 ${qtyText(_demandTotal)}',
                  if (_publicExtraTotal > 0)
                    '公共超量备货 ${qtyText(_publicExtraTotal)}',
                  if (_safetyTotal > 0) '公共安全补库 ${qtyText(_safetyTotal)}',
                ].join(' + '),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                isBuy
                    ? '确认后合并为采购需求单并通知采购部；需要改数量请先在表格中修改。'
                    : '无子层委外合并为委外申请并通知委外部；有子层先转前置自制。'
                          '需要改数量请先在表格中修改。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              // 根供料（顶层 BUY）：有已分配现货时服务端优先交接现货，
              // 行内/合计数量只是追加供料部分——必须在确认前说清。
              for (final entry in entries)
                if (entry.rootAllocatedStockQty > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s4),
                    child: Text(
                      '${entry.label}：将优先交接已分配现货 '
                      '${qtyText(entry.rootAllocatedStockQty)}'
                      '${entry.unitName == null ? '' : ' ${entry.unitName}'}，'
                      '合计只含追加供料数量。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                  ),
              if (entries.isNotEmpty) ...[
                const Divider(height: UtenSpacing.s16),
                // 明细清单可滚动核对（品种多时不撑爆弹窗）。
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final qty = quantities[index];
                      final unit = entry.unitName ?? '件';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        trailing: Text(
                          '${qtyText(entry.totalQty(qty))} $unit',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.pop(context, false),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        FilledButton(
          key: const Key('supply-submit-confirm'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.pop(context, true),
          child: Text('确认下达${route.label}'),
        ),
      ],
    );
  }
}
