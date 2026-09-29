import 'package:flutter/material.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';

/// The API stores a ratio (0.1); production forms display a percentage (10).
/// Keep the same decimal precision and range as the planning approval ledger.
double? parseProductionOverproductionPercent(String text) {
  final raw = text.trim();
  if (!RegExp(r'^(?:\d+(?:\.\d{0,4})?|\.\d{1,4})$').hasMatch(raw)) return null;
  final percent = double.tryParse(raw);
  if (percent == null ||
      !percent.isFinite ||
      percent < 0 ||
      percent >= 100000) {
    return null;
  }
  return double.parse((percent / 100).toStringAsFixed(6));
}

String productionOverproductionPercentText(double rate) =>
    (rate * 100).toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

/// 系统按货品默认比例预填的比例格(ADR-129 §2.10)，物料分析页与计划编辑页共用。
///
/// 格子里仍是预填的文本 = 没人改过：提交送 null，由服务端按货品默认填写、标 DEFAULT
/// 且不记住；人改过(文本不同)就按所填值明确提交。记录挂在输入框上，输入框随行
/// 释放后记录跟着消失，删行不用另外清理。
class SystemPrefilledRates {
  final _seeds = Expando<({String? goodsId, String text})>(
    'system prefilled overproduction rate',
  );

  /// 按货品默认比例预填这一格并记下预填文本；[goodsId] 供 [reseed] 按新默认刷新。
  void fill(TextEditingController controller, double rate, {String? goodsId}) {
    final text = productionOverproductionPercentText(rate);
    _seeds[controller] = (goodsId: goodsId, text: text);
    if (controller.text != text) controller.text = text;
  }

  /// 这一格不再是系统预填(例如行换了货品)：之后填什么都按人填的算。
  void forget(TextEditingController controller) => _seeds[controller] = null;

  /// 复制行沿用原行的预填记录：没人改过的默认比例复制后仍按默认提交。
  void copy(TextEditingController from, TextEditingController to) =>
      _seeds[to] = _seeds[from];

  /// 这一格的比例是人定的吗：没人改过的仍是系统预填的文本。
  bool isExplicit(TextEditingController controller) =>
      _seeds[controller]?.text != controller.text;

  /// 提交的比例：没人改过送 null，其余按所填值(调用方已先校验过是有效比例)。
  double? submitted(TextEditingController controller) => isExplicit(controller)
      ? parseProductionOverproductionPercent(controller.text)
      : null;

  /// 撤销时放回快照里的文本：快照时仍是系统预填的格子回到**当前**预填值(期间可能
  /// 已按新默认刷新)，仍算没人改过；快照时人填过的照原文放回。
  void restore(
    TextEditingController controller,
    String text, {
    required bool explicit,
  }) {
    final seed = _seeds[controller];
    controller.text = !explicit && seed != null ? seed.text : text;
  }

  /// 新默认比例：没人改过的格子连文本一起刷新；人改过的文本不动、只把预填记录换成
  /// 新默认，之后改回旧默认或撤销放回时都按**当前**默认比较，看到的比例就是提交后
  /// 服务端填的比例。[defaults] 没带该货品时保持原样，[skip] 返回 true 的格子
  /// (例如已下达)不动。
  void reseed(
    Iterable<TextEditingController> controllers,
    Map<String, double> defaults, {
    bool Function(TextEditingController controller)? skip,
  }) {
    for (final controller in controllers) {
      final seed = _seeds[controller];
      final rate = defaults[seed?.goodsId];
      if (seed == null || rate == null || (skip?.call(controller) ?? false)) {
        continue;
      }
      if (controller.text == seed.text) {
        fill(controller, rate, goodsId: seed.goodsId);
      } else {
        _seeds[controller] = (
          goodsId: seed.goodsId,
          text: productionOverproductionPercentText(rate),
        );
      }
    }
  }
}

class ProductionOverproductionRateField extends StatelessWidget {
  const ProductionOverproductionRateField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: onChanged,
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              suffixText: '%',
              hintText: '0',
              error: parseProductionOverproductionPercent(value.text) == null
                  ? const UtenFieldMessage.error('请输入非负百分比，最多 4 位小数')
                  : null,
            ),
          ),
        ),
      );
}
