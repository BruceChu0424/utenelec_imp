import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_material_analysis.dart';

// 提交采购/委外/自制前的数量确认对话框（适老化）：
// 大字体、−/＋ 大按钮、默认按剩余缺口全量、可改小分批提交。
// 确认前用大白话写清「提交后干什么」。客户端只收集输入，服务端逐项复核。
/// 按 goods/color/unit 去重后的第二数量切片。
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
  final double maxQty;
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

/// 提交采购/委外/自制前的数量确认对话框（适老化）：
/// 大字体、−/＋ 大按钮、默认按剩余缺口全量、可改小分批提交。
/// 确认前用大白话写清「提交后干什么」。客户端只收集输入，服务端逐项复核。
/// 采购/委外 [allowOverDemand]=true：允许超过本批缺口下单（一次多采，富余
/// 入库后转公共可用，供后续分析使用）；自制仍按全部剩余需求精确创建。
class MaterialSupplyQuantityDialog extends StatefulWidget {
  const MaterialSupplyQuantityDialog({
    super.key,
    required this.route,
    required this.entries,
    required this.qtyText,
    this.allowOverDemand = false,
  });

  final MaterialSupplyRoute route;
  final List<MaterialSupplyQuantityEntry> entries;
  final String Function(double?) qtyText;
  final bool allowOverDemand;

  @override
  State<MaterialSupplyQuantityDialog> createState() =>
      _MaterialSupplyQuantityDialogState();
}

class _MaterialSupplyQuantityDialogState
    extends State<MaterialSupplyQuantityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;

  String get _routeLabel => widget.route.label;

  @override
  void initState() {
    super.initState();
    _controllers = [
      for (final entry in widget.entries)
        TextEditingController(text: widget.qtyText(entry.maxQty)),
    ];
    _focusNodes = [for (final _ in widget.entries) FocusNode()];
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  double? _qtyAt(int index) => double.tryParse(_controllers[index].text.trim());

  bool _allowsPublicExtra(int index) =>
      widget.allowOverDemand && widget.entries[index].allowPublicExtra;

  void _step(int index, int delta) {
    final entry = widget.entries[index];
    final current = _qtyAt(index) ?? entry.maxQty;
    var next = current + delta;
    if (next < 0) next = 0;
    // 超量下单放开后上限由键盘输入承担；步进不再钳到缺口。
    if (!_allowsPublicExtra(index) && next > entry.maxQty) next = entry.maxQty;
    setState(() {
      _controllers[index].text = widget.qtyText(next);
    });
  }

  double get _exactDemandTotalQty {
    var total = 0.0;
    for (var index = 0; index < widget.entries.length; index++) {
      final qty = _qtyAt(index);
      if (qty != null && qty >= 0) {
        total += qty > widget.entries[index].maxQty
            ? widget.entries[index].maxQty
            : qty;
      }
    }
    return total;
  }

  double get _publicExtraTotalQty {
    var total = 0.0;
    for (var index = 0; index < widget.entries.length; index++) {
      final qty = _qtyAt(index);
      final maxQty = widget.entries[index].maxQty;
      if (_allowsPublicExtra(index) && qty != null && qty > maxQty) {
        total += qty - maxQty;
      }
    }
    return total;
  }

  double get _safetyTotalQty => widget.entries.fold(
    0.0,
    (sum, entry) => sum + entry.safetyReplenishmentQty,
  );

  double get _totalQty =>
      _exactDemandTotalQty + _publicExtraTotalQty + _safetyTotalQty;

  bool get _hasUnsupportedSafetyGap =>
      widget.route != MaterialSupplyRoute.buy &&
      widget.entries.any((entry) => entry.safetyReplenishmentGapQty > 0);

  String? _validateQty(int index) {
    final entry = widget.entries[index];
    final qty = _qtyAt(index);
    if (qty == null) return '请输入有效数量';
    if (qty < 0) return '本批生产需求不能小于 0';
    if (!_allowsPublicExtra(index) && qty > entry.maxQty + 0.0001) {
      return '最多提交 ${widget.qtyText(entry.maxQty)}'
          '(本批需求缺口 − 已在途需求)';
    }
    if (qty <= 0 && entry.safetyReplenishmentQty <= 0) {
      return '本批生产需求与公共安全库存补库不能同时为 0';
    }
    return null;
  }

  void _submit() {
    if (_hasUnsupportedSafetyGap) return;
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) {
      for (var index = 0; index < widget.entries.length; index++) {
        if (_validateQty(index) != null) {
          _focusNodes[index].requestFocus();
          break;
        }
      }
      return;
    }
    Navigator.pop(context, [
      for (var index = 0; index < widget.entries.length; index++)
        widget.entries[index].toInput(
          _qtyAt(index)!,
          allowOverDemand: _allowsPublicExtra(index),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaSize = MediaQuery.sizeOf(context);
    return AlertDialog(
      key: const Key('supply-quantity-dialog'),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s24,
      ),
      title: Text('确认提交数量 · $_routeLabel'),
      content: SizedBox(
        // AlertDialog 会对 content 做 intrinsic 测量：宽高都必须有界，
        // 懒加载列表（viewport）不能被 intrinsic 测量。
        width: (mediaSize.width - 64).clamp(280.0, 620.0),
        height: (mediaSize.height - 200).clamp(340.0, 620.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.allowOverDemand
                    ? '本批需求可以改小；只有标明“允许公共超量”的采购/叶子委外行才可超过缺口。'
                          '超出部分独立记为公共备货，安全库存补库仍固定显示。'
                    : '“本批生产需求”可以改小；“公共安全库存补库”由当前公共库存'
                          '与在途补库计算并固定显示。确认后不会暗加数量。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (_hasUnsupportedSafetyGap) ...[
                const SizedBox(height: UtenSpacing.s8),
                _unsupportedSafetyBanner(theme),
              ],
              const SizedBox(height: UtenSpacing.s12),
              // 物料可能上百种：列表懒构建，滚动流畅。
              Expanded(
                child: ListView.builder(
                  itemCount: widget.entries.length,
                  itemBuilder: (_, index) => _entryCard(theme, index),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Container(
                key: const Key('supply-quantity-summary'),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: 0.35,
                  ),
                  borderRadius: UtenRadius.mdAll,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  '确认后：本批生产需求 ${widget.qtyText(_exactDemandTotalQty)} '
                  '+ 公共超量备货 ${widget.qtyText(_publicExtraTotalQty)} '
                  '+ 公共安全库存补库 ${widget.qtyText(_safetyTotalQty)} '
                  '= 预计总量 ${widget.qtyText(_totalQty)}。'
                  '各物料仍按自己的基本单位下达。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('supply-quantity-confirm'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _hasUnsupportedSafetyGap ? null : _submit,
          child: Text('确认提交$_routeLabel'),
        ),
      ],
    );
  }

  Widget _entryCard(ThemeData theme, int index) {
    final entry = widget.entries[index];
    final unit = entry.unitName ?? '件';
    final identity = entry.actionGroupKey ?? entry.materialLineId;
    final currentDemand = _qtyAt(index) ?? 0;
    final allowsPublicExtra = _allowsPublicExtra(index);
    final exactDemand = currentDemand > entry.maxQty
        ? entry.maxQty
        : currentDemand;
    final publicExtra = allowsPublicExtra && currentDemand > entry.maxQty
        ? currentDemand - entry.maxQty
        : 0.0;
    return Semantics(
      container: true,
      label:
          '${entry.label}：本批生产需求 ${widget.qtyText(exactDemand)} $unit，'
          '公共超量备货 ${widget.qtyText(publicExtra)} $unit，'
          '公共安全库存补库 ${widget.qtyText(entry.safetyReplenishmentQty)} $unit，'
          '预计总量 ${widget.qtyText(entry.totalQty(currentDemand))} $unit',
      child: Container(
        key: ValueKey('supply-qty-$identity'),
        margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.label,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (entry.spec != null && entry.spec!.isNotEmpty)
              Text(
                entry.spec!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              allowsPublicExtra
                  ? '本批缺口 ${widget.qtyText(entry.maxQty)} $unit'
                        '${entry.openQty > 0 ? ' · 需求在途 ${widget.qtyText(entry.openQty)} $unit' : ''}'
                        '；可超量下单，富余入库后供后续物料分析使用'
                  : '本批生产需求上限 ${widget.qtyText(entry.maxQty)} $unit'
                        '${entry.openQty > 0 ? ' · 需求在途 ${widget.qtyText(entry.openQty)} $unit' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Row(
              children: [
                _stepButton(theme, index, Icons.remove_rounded, -1),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('supply-qty-input-$identity'),
                    controller: _controllers[index],
                    focusNode: _focusNodes[index],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (_) => _validateQty(index),
                    errorBuilder: utenTextFieldErrorBuilder,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: allowsPublicExtra ? '下单总量（含公共超量）' : '本批生产需求',
                      suffixText: unit,
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                _stepButton(theme, index, Icons.add_rounded, 1),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            _safetySlice(theme, entry, unit),
            const SizedBox(height: UtenSpacing.s8),
            Container(
              key: ValueKey('supply-qty-total-$identity'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: UtenRadius.smAll,
              ),
              child: Text(
                allowsPublicExtra && currentDemand > entry.maxQty
                    ? '预计总量 ${widget.qtyText(entry.totalQty(currentDemand))} $unit'
                          ' = 本批 ${widget.qtyText(entry.maxQty)}'
                          ' + 公共超量 ${widget.qtyText(currentDemand - entry.maxQty)}'
                          ' + 安全补库 ${widget.qtyText(entry.safetyReplenishmentQty)}'
                    : '预计总量 ${widget.qtyText(entry.totalQty(currentDemand))} $unit'
                          ' = 本批 ${widget.qtyText(currentDemand)}'
                          ' + 安全补库 ${widget.qtyText(entry.safetyReplenishmentQty)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _safetySlice(
    ThemeData theme,
    MaterialSupplyQuantityEntry entry,
    String unit,
  ) {
    final unsupported =
        widget.route != MaterialSupplyRoute.buy &&
        entry.safetyReplenishmentGapQty > 0;
    final color = unsupported
        ? theme.colorScheme.error
        : theme.colorScheme.secondary;
    final detail = unsupported
        ? '本版本仅采购路线支持公共安全补库'
        : entry.safetyDeduplicatedElsewhere
        ? '同一物料的安全缺口已在本批另一行计入，本行固定为 0'
        : '安全保护 ${widget.qtyText(entry.safetyStockQty)}'
              ' − 公共可用 ${widget.qtyText(entry.publicAvailableQty)}'
              ' − 公共补库在途 ${widget.qtyText(entry.openSafetySupplyQty)}';
    return Container(
      key: ValueKey(
        'supply-safety-${entry.actionGroupKey ?? entry.materialLineId}',
      ),
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            unsupported ? Icons.policy_outlined : Icons.shield_outlined,
            color: color,
            size: 22,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '公共安全库存补库 '
                  '${widget.qtyText(entry.safetyReplenishmentQty)} $unit',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _unsupportedSafetyBanner(ThemeData theme) => Container(
    key: const Key('supply-safety-route-unsupported'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.error),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.policy_outlined, color: theme.colorScheme.error),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(child: Text('本版本仅采购路线支持公共安全补库。当前路线不能提交，请取消后改用采购路线。')),
      ],
    ),
  );

  Widget _stepButton(
    ThemeData theme,
    int index,
    IconData icon,
    int delta,
  ) => SizedBox(
    width: 48,
    height: 48,
    child: IconButton.filledTonal(
      key: ValueKey(
        'supply-qty-step-$delta-'
        '${widget.entries[index].actionGroupKey ?? widget.entries[index].materialLineId}',
      ),
      tooltip: delta > 0 ? '加 1' : '减 1',
      onPressed: () => _step(index, delta),
      icon: Icon(icon),
    ),
  );
}
