import 'package:flutter/material.dart';

import '../../../components/inputs/uten_editor_tooltip.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../formatters/exact_decimal.dart';
import '../weight_unit.dart';
import 'weight_grid_column.dart';

/// Per displayed quantity unit, derived from the same exact total sent by the
/// arrival command. Recurring ratios are display-only approximations.
EditableGridColumn<T> unitWeightGridColumn<T extends EditableGridRow>({
  required WeightEntryController Function(T row) controllerOf,
  required String? Function(T row) quantityTextOf,
  required bool Function(T row) enabledOf,
  required String? Function(T row) unitNameOf,
  Listenable? Function(T row)? quantityListenableOf,
  Object? Function(T row)? exactKgOf,
}) => EditableGridColumn<T>(
  key: 'unitWeight',
  label: '单重(g)',
  width: 170,
  headerInfo:
      '单重（个重）按本行实物数量（含赠品）换算，每个行单位的重量。填单重自动算总重；'
      '填总重自动算个重。个重按克录入，也可带 kg 等后缀。'
      '≈ 表示循环小数的显示近似值，原总重保持完整精度；不会改写货品资料或历史单重。',
  columnSearchEnabled: false,
  textOf: (row) => _unitDisplay(controllerOf(row), quantityTextOf(row)),
  listenableOf: (row) =>
      Listenable.merge([controllerOf(row), ?quantityListenableOf?.call(row)]),
  cellBuilder: (_, row) => _UnitWeightCell(
    weight: controllerOf(row),
    quantityText: () => quantityTextOf(row),
    quantityListenable: quantityListenableOf?.call(row),
    enabled: enabledOf(row) && exactKgOf?.call(row) == null,
    exact: exactKgOf?.call(row) != null,
    unitName: unitNameOf(row),
  ),
);

String _unitDisplay(WeightEntryController weight, String? quantity) {
  final raw = weight.unitWeightInput;
  if (raw != null) return raw;
  final kg = weight.displayKgText;
  final qty = financeExactDecimal(quantity);
  if (kg == null || qty == null || qty == '0' || qty.startsWith('-')) return '';
  final grams = WeightUnit.g.fromKgText(kg).text;
  if (grams == null) return '';
  final ratio = financeExactDivideTexts(grams, qty);
  if (ratio.text != null) return ratio.text!;
  final approximate = financeExactDivideTexts(
    grams,
    qty,
    choiceScale: 12,
    choiceRounding: 'HALF_UP',
  ).text;
  return approximate == null ? '' : '≈$approximate';
}

class _UnitWeightCell extends StatefulWidget {
  const _UnitWeightCell({
    required this.weight,
    required this.quantityText,
    required this.quantityListenable,
    required this.enabled,
    required this.exact,
    required this.unitName,
  });
  final WeightEntryController weight;
  final String? Function() quantityText;
  final Listenable? quantityListenable;
  final bool enabled, exact;
  final String? unitName;

  @override
  State<_UnitWeightCell> createState() => _UnitWeightCellState();
}

class _UnitWeightCellState extends State<_UnitWeightCell> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.weight.addListener(_sync);
    widget.quantityListenable?.addListener(_sync);
    _focus.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _UnitWeightCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.weight, widget.weight)) {
      oldWidget.weight.removeListener(_sync);
      widget.weight.addListener(_sync);
    }
    oldWidget.quantityListenable?.removeListener(_sync);
    widget.quantityListenable?.addListener(_sync);
    _sync();
  }

  void _sync() {
    // Keep the live input connection and selection while typing.
    if (_focus.hasFocus && widget.weight.unitWeightInput != null) return;
    final next = widget.exact
        ? ''
        : _unitDisplay(widget.weight, widget.quantityText());
    if (_text.text != next) {
      _text.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.weight,
    builder: (context, _) {
      final error = widget.weight.unitWeightError;
      return UtenEditorTooltip(
        message: widget.exact
            ? '本行按重量计量，由数量精确换算总重'
            : error ?? '单重 × 实物数量 = 总重；修改仅作用于本行',
        child: TextField(
          key: const ValueKey('unit-weight-cell-input'),
          controller: _text,
          focusNode: _focus,
          enabled: widget.enabled,
          keyboardType: TextInputType.text,
          onChanged: (raw) => widget.weight.setUnitWeightInput(
            raw,
            unit: WeightUnit.g,
            quantityText: widget.quantityText(),
          ),
          decoration: UtenInputDecoration(
            InputDecoration(
              hintText: widget.exact ? '按重量计量' : '单重',
              // The header owns the default g unit. An explicit input suffix
              // (for example 2lb) must not be displayed as "2lb g/个".
              suffixText: '/${widget.unitName ?? '单位'}',
              isDense: true,
              error: utenFieldError(error),
            ),
            autofilled: widget.weight.isSuggested,
            info: widget.weight.isSuggested
                ? '由历史参考总重换算，尚未实称；输入本批单重后才随本次登记保存'
                : null,
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    widget.weight.removeListener(_sync);
    widget.quantityListenable?.removeListener(_sync);
    _focus
      ..removeListener(_sync)
      ..dispose();
    _text.dispose();
    super.dispose();
  }
}
