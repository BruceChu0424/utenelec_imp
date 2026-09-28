// 重量只读显示件 (ADR-135 §6.2/§6.3): 即时库存、流水、单据详情、分析页共用。
//
// 口径:
// - 千克值按用户显示偏好 (自动/固定单位) 换算, 估算值前缀「≈」, 没称 (NULL) 显示「未称」,
//   绝不把未知显示成 0;
// - 重量来源提示: 实称 / 按数量(精确) / 按比例分摊 / ≈按库存均重 / ≈按单重估算;
// - 核对文案 (偏差按件数表达, 按件计的单位取整): 入库「偏少约238个 (-4.8%)」,
//   出库「比应发多约35个 (+1.5%)」; 单重未学准时不核对。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../weight_params.dart';
import '../weight_predictor.dart';
import '../weight_prefs.dart';
import '../weight_unit.dart';

/// 没称的重量显示文案。
const String weightUnknownText = '未称';

/// 单重未学准时格子/弹窗的统一提示。
const String weightNotLearnedHint = '单重还没学准, 暂不核对 - 可点「称样校准」';

/// 重量来源 -> 中文说明 (流水/余额悬停提示)。
String weightSourceLabel(String? source) =>
    switch (source?.trim().toUpperCase()) {
      'MEASURED' => '实称',
      'EXACT' => '按数量(精确)',
      'SLICE' => '按比例分摊',
      'AVERAGE' => '≈按库存均重',
      'ESTIMATE' => '≈按单重估算',
      _ => '',
    };

/// 来源是否为估算 (显示「≈」)。
bool isEstimatedWeightSource(String? source) {
  final s = source?.trim().toUpperCase();
  return s == 'AVERAGE' || s == 'ESTIMATE';
}

/// 千克值 -> 显示文本: null -> 「未称」(或 [unknownText]), 估算加「≈」前缀。
String formatWeightValue(
  double? kg, {
  WeightDisplay display = WeightDisplay.auto,
  bool estimated = false,
  String unknownText = weightUnknownText,
}) {
  if (kg == null || !kg.isFinite) return unknownText;
  final text = formatWeight(kg, display: display);
  return estimated ? '≈$text' : text;
}

/// 单重显示 (千克/基本单位): 小于 1 kg 按克 (如 `2.312 g`), 否则千克; 可带「/个」。
String formatUnitWeight(double? kgPerBase, {String? unitName}) {
  if (kgPerBase == null || !kgPerBase.isFinite || kgPerBase <= 0) return '—';
  final String text;
  if (kgPerBase < 1) {
    final grams = kgPerBase * 1000;
    final pattern = grams < 0.01 ? '#,##0.######' : '#,##0.###';
    text = '${NumberFormat(pattern, 'zh_CN').format(grams)} g';
  } else {
    text = '${NumberFormat('#,##0.###', 'zh_CN').format(kgPerBase)} kg';
  }
  final unit = unitName?.trim();
  return unit == null || unit.isEmpty ? text : '$text/$unit';
}

/// 数量显示: 按件计取整带千分位 (`4,762`), 其余最多 4 位小数。
String formatWeighQty(double qty, {required bool integer}) {
  if (!qty.isFinite) return '—';
  final pattern = integer ? '#,##0' : '#,##0.####';
  return NumberFormat(
    pattern,
    'zh_CN',
  ).format(integer ? WeightPredictor.roundQty(qty, integer: true) : qty);
}

/// 数量 + 单位: 中文单位紧贴 (`4,762个`), 其它单位空一格 (`12.5 m`)。
String formatWeighQtyWithUnit(
  double qty, {
  String? unitName,
  required bool integer,
}) {
  final number = formatWeighQty(qty, integer: integer);
  final unit = unitName?.trim() ?? '';
  if (unit.isEmpty) return number;
  final latin = RegExp(r'^[A-Za-z]').hasMatch(unit);
  return latin ? '$number $unit' : '$number$unit';
}

/// 带符号百分比 (`+1.5%` / `-4.8%`)。
String formatSignedPct(double pct) {
  final rounded = (pct * 10).roundToDouble() / 10;
  final body = NumberFormat('0.0', 'zh_CN').format(rounded.abs());
  if (rounded > 0) return '+$body%';
  if (rounded < 0) return '-$body%';
  return '0.0%';
}

/// 单重依据说明 (如「近23次称重(本供应商), 可参考」)。
String weightBasisText(WeightParams params) {
  final parts = <String>[];
  switch (params.basis) {
    case WeightBasis.learned:
      if (params.drawOnly) {
        parts.add('按过往领料推算');
      } else {
        final n = params.nInliers;
        final base = n == null ? '称重学习' : '近$n次称重';
        parts.add(params.supplierSpecific ? '$base(本供应商)' : base);
      }
    case WeightBasis.manual:
    case WeightBasis.masterPrior:
    case WeightBasis.exact:
    case WeightBasis.none:
      parts.add(params.basis.label);
  }
  if (params.basis != WeightBasis.exact && params.basis != WeightBasis.none) {
    parts.add(params.effectiveTier.label);
  }
  if (params.stale) parts.add('超过一年没称过');
  return parts.join(', ');
}

/// 核对短句 (格子旁/偏差标签): 入库「偏少约238个 (-4.8%)」, 出库「比应发多约35个 (+1.5%)」。
String weightCheckShortText(
  WeightCheck check, {
  WeightCaptureMode mode = WeightCaptureMode.inbound,
  String? unitName,
}) {
  final diff = check.qtyDiff;
  final amount = formatWeighQtyWithUnit(
    diff.abs(),
    unitName: unitName,
    integer: check.integerQty,
  );
  final pct = formatSignedPct(check.deviationPct);
  final more = diff > 0;
  return switch (mode) {
    WeightCaptureMode.outbound => '比应发${more ? '多' : '少'}约$amount ($pct)',
    WeightCaptureMode.count => '比数量${more ? '多' : '少'}约$amount ($pct)',
    WeightCaptureMode.inbound => '偏${more ? '多' : '少'}约$amount ($pct)',
  };
}

/// 核对完整说明 (格子 ⓘ 悬停):
/// 「按单重 2.31 g 应重 11.55 kg, 实称 11 kg ≈ 4,762个 (4,715~4,809), 比登记少约 238个 (-4.8%).
///  依据: 近23次称重(本供应商), 可参考」。
String weightCheckTooltip(
  WeightCheck check,
  WeightParams params, {
  WeightCaptureMode mode = WeightCaptureMode.inbound,
  String? unitName,
  WeightDisplay display = WeightDisplay.auto,
}) {
  String qty(double v) =>
      formatWeighQtyWithUnit(v, unitName: unitName, integer: check.integerQty);
  final count = check.count;
  final diff = check.qtyDiff;
  final more = diff > 0;
  final against = switch (mode) {
    WeightCaptureMode.outbound => '比应发',
    WeightCaptureMode.count => '比数量',
    WeightCaptureMode.inbound => '比登记',
  };
  final buffer = StringBuffer()
    ..write('按单重 ${formatUnitWeight(params.currentUnitWeightKg)} ')
    ..write('应重 ${formatWeight(check.expectedWeightKg, display: display)}, ')
    ..write('实称 ${formatWeight(check.weightKg, display: display)} ')
    ..write('≈ ${qty(count.estimatedQty)} ')
    ..write('(${qty(count.qtyLow)}~${qty(count.qtyHigh)}), ')
    ..write('$against${more ? '多' : '少'}约 ${qty(diff.abs())} ')
    ..write('(${formatSignedPct(check.deviationPct)}). ')
    ..write('依据: ${weightBasisText(params)}');
  return buffer.toString();
}

/// 可靠度徽章: 可靠(绿) / 可参考(琥珀) / 未学准(红)。
class WeightTierBadge extends StatelessWidget {
  const WeightTierBadge({
    super.key,
    required this.tier,
    this.size = UtenStatusBadgeSize.small,
  });

  final WeightTier tier;
  final UtenStatusBadgeSize size;

  @override
  Widget build(BuildContext context) => UtenStatusBadge(
    label: tier.label,
    size: size,
    type: switch (tier) {
      WeightTier.green => UtenStatusBadgeType.success,
      WeightTier.yellow => UtenStatusBadgeType.warning,
      WeightTier.red => UtenStatusBadgeType.danger,
    },
  );
}

/// 只读重量文本: 按用户显示偏好换算; 估算「≈」、没称「未称」(灰); 有来源时悬停说明来源。
class WeightText extends ConsumerWidget {
  const WeightText({
    super.key,
    required this.kg,
    this.estimated = false,
    this.source,
    this.display,
    this.unknownText = weightUnknownText,
    this.style,
    this.textAlign,
  });

  final double? kg;
  final bool estimated;

  /// 重量来源 (MEASURED/EXACT/SLICE/AVERAGE/ESTIMATE); 给了就悬停显示中文说明。
  final String? source;

  /// 固定显示单位; null = 跟用户偏好。
  final WeightDisplay? display;
  final String unknownText;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effective =
        display ?? ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final theme = Theme.of(context);
    final unknown = kg == null || !kg!.isFinite;
    final text = formatWeightValue(
      kg,
      display: effective,
      estimated: estimated || isEstimatedWeightSource(source),
      unknownText: unknownText,
    );
    final child = Text(
      text,
      textAlign: textAlign,
      style: unknown
          ? (style ?? const TextStyle()).copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )
          : style,
    );
    final label = weightSourceLabel(source);
    if (unknown || label.isEmpty) return child;
    return Tooltip(message: label, child: child);
  }
}

/// 偏差标签 (产成品登记「比报工少约 N 个」、退料「登记退 N 个, 称重约 M 个」等只读场景)。
/// 默认只在 WARN/ALERT 时出现; [text] 覆盖默认短句。
class WeightDeviationChip extends StatelessWidget {
  const WeightDeviationChip({
    super.key,
    required this.check,
    this.mode = WeightCaptureMode.inbound,
    this.unitName,
    this.text,
    this.tooltip,
    this.showWhenNone = false,
  });

  final WeightCheck? check;
  final WeightCaptureMode mode;
  final String? unitName;
  final String? text;
  final String? tooltip;
  final bool showWhenNone;

  @override
  Widget build(BuildContext context) {
    final c = check;
    if (c == null) return const SizedBox.shrink();
    if (c.level == WeightAlertLevel.none && !showWhenNone) {
      return const SizedBox.shrink();
    }
    final label =
        text ?? weightCheckShortText(c, mode: mode, unitName: unitName);
    final badge = UtenStatusBadge(
      label: label,
      size: UtenStatusBadgeSize.small,
      icon: c.level == WeightAlertLevel.none
          ? Icons.scale_outlined
          : Icons.warning_amber_rounded,
      type: switch (c.level) {
        WeightAlertLevel.alert => UtenStatusBadgeType.danger,
        WeightAlertLevel.warn => UtenStatusBadgeType.warning,
        WeightAlertLevel.none => UtenStatusBadgeType.neutral,
      },
    );
    final tip = tooltip;
    return tip == null ? badge : Tooltip(message: tip, child: badge);
  }
}

/// 表格工具条上的单位下拉按钮 (「称重单位: 千克▾」「重量单位: 自动▾」共用外观)。
class WeightUnitMenuButton<V> extends StatelessWidget {
  const WeightUnitMenuButton({
    super.key,
    required this.prefix,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onSelected,
  });

  final String prefix;
  final V value;
  final List<V> options;
  final String Function(V option) labelOf;
  final ValueChanged<V> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            key: ValueKey('weight-unit-option-${labelOf(option)}'),
            leadingIcon: SizedBox(
              width: 20,
              child: option == value
                  ? Icon(
                      Icons.check,
                      size: 18,
                      color: theme.colorScheme.primary,
                    )
                  : null,
            ),
            onPressed: () => onSelected(option),
            child: Text(labelOf(option)),
          ),
      ],
      builder: (context, controller, _) => UtenButton(
        type: UtenButtonType.secondary,
        height: UtenTableToolbar.controlHeight,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$prefix: ${labelOf(value)}'),
            const SizedBox(width: UtenSpacing.s4),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 只读表格工具条「重量单位: 自动▾」(写用户显示偏好, 全仓库页面同步)。
class WeightDisplayUnitButton extends ConsumerWidget {
  const WeightDisplayUnitButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(warehouseWeightUnitsPrefsProvider);
    return WeightUnitMenuButton<WeightDisplay>(
      key: const ValueKey('weight-display-unit-button'),
      prefix: '重量单位',
      value: prefs.display,
      options: WeightDisplay.values,
      labelOf: (d) => d.label,
      onSelected: ref
          .read(warehouseWeightUnitsPrefsProvider.notifier)
          .setDisplay,
    );
  }
}

/// 偏差档位对应的描边/图标色 (WARN 琥珀, ALERT 红)。
Color? weightAlertColor(ThemeData theme, WeightAlertLevel level) =>
    switch (level) {
      WeightAlertLevel.alert => theme.colorScheme.error,
      WeightAlertLevel.warn =>
        theme.brightness == Brightness.dark
            ? UtenColors.warningOnDark
            : UtenColors.warning,
      WeightAlertLevel.none => null,
    };

/// 件数区间文本 (`5,373~5,449`)。
String formatWeighQtyRange(
  CountEstimate estimate, {
  required bool integer,
  String? unitName,
}) {
  final lowText = formatWeighQty(estimate.qtyLow, integer: integer);
  final highText = formatWeighQtyWithUnit(
    estimate.qtyHigh,
    unitName: unitName,
    integer: integer,
  );
  return '$lowText~$highText';
}
