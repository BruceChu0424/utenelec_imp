import 'package:flutter/material.dart';

import '../../components/feedback/uten_context_menu.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../../components/inputs/uten_field_message.dart';
import 'line_pricing_controller.dart';

const linePricingAmountHeaderHint =
    '数量、单价、总金额可联动计算。直接填写总金额时，已有数量会自动算单价；'
    '只有单价时自动算数量。也可在单元格菜单选择自动计算哪一项。'
    '总金额包含附加列，按附加列顺序计算；数量最多 4 位小数。';

/// A compact amount editor sharing the same row controller as quantity/price.
class LinePricingAmountCell extends StatelessWidget {
  const LinePricingAmountCell({
    super.key,
    required this.controller,
    this.enabled = true,
  });

  final LinePricingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.error]),
    builder: (context, _) => TextField(
      controller: controller.totalAmount,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: UtenInputDecoration(
        InputDecoration(
          isDense: true,
          hintText: '总金额',
          error: utenFieldError(controller.error.value),
          suffixIconConstraints: const BoxConstraints(minWidth: 52),
          suffixIcon: Builder(
            builder: (buttonContext) => Tooltip(
              message: _label(controller.mode),
              child: TextButton(
                onPressed: enabled ? () => _openMenu(buttonContext) : null,
                style: TextButton.styleFrom(
                  // 紧凑格内按钮：高度上限交给输入格（UtenEditableGridCellSpec），
                  // 最小高 24 只保住可点面积；旧值 40 会把整行撑回旧行高。
                  minimumSize: const Size(52, 24),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(switch (controller.mode) {
                      LinePricingMode.calculateAmount => '算额',
                      LinePricingMode.calculatePrice => '算价',
                      LinePricingMode.calculateQuantity => '算量',
                    }, style: Theme.of(context).textTheme.labelSmall),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
        info: controller.isApproximate
            ? '总金额按输入原值保存。单价为参考值，除不尽时显示至 '
                  '${controller.priceScale} 位小数；不会用参考单价覆盖总金额。'
            : null,
      ),
    ),
  );

  void _openMenu(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    showUtenContextMenu(
      context,
      globalPosition: box.localToGlobal(Offset(0, box.size.height)),
      entries: [
        for (final mode in LinePricingMode.values)
          UtenMenuItem(
            label: _label(mode),
            icon: controller.mode == mode ? Icons.check : null,
            enabled: switch (mode) {
              LinePricingMode.calculateAmount => true,
              LinePricingMode.calculatePrice => controller.canCalculatePrice,
              LinePricingMode.calculateQuantity =>
                controller.canCalculateQuantity,
            },
            onTap: () => controller.setMode(mode),
          ),
      ],
    );
  }
}

String _label(LinePricingMode mode) => switch (mode) {
  LinePricingMode.calculateAmount => '自动算总金额',
  LinePricingMode.calculatePrice => '自动算单价',
  LinePricingMode.calculateQuantity => '自动算数量',
};
