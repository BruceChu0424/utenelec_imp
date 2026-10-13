import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/production_exact_quantity.dart';

/// A local edit only. The page must recheck its current source/session before
/// applying this choice and retains responsibility for saving the whole report.
class DailyReportDestinationChoice {
  const DailyReportDestinationChoice({
    required this.demandId,
    required this.qtyText,
  });

  final String demandId;
  final String qtyText;
}

abstract final class DailyReportAddDestinationDialog {
  /// [maximumByDemand], [availableQtyText] and the returned quantity use the
  /// report's display unit. The page converts exact base receiver capacities
  /// into this unit before opening; [unitRateText] checks physical base quantity.
  static Future<DailyReportDestinationChoice?> show(
    BuildContext context, {
    required List<UtenDropdownItem> targets,
    required Map<String, String> maximumByDemand,
    required String availableQtyText,
    required String unitRateText,
    String? unitName,
    bool replacesSuggestions = false,
  }) {
    final frozenTargets = List<UtenDropdownItem>.unmodifiable(targets);
    final frozenMaximums = Map<String, String>.unmodifiable(maximumByDemand);
    return showDialog<DailyReportDestinationChoice>(
      context: context,
      builder: (context) => _AddDestinationDialog(
        targets: frozenTargets,
        maximumByDemand: frozenMaximums,
        availableQtyText: availableQtyText,
        unitRateText: unitRateText,
        unitName: unitName,
        replacesSuggestions: replacesSuggestions,
      ),
    );
  }
}

class _AddDestinationDialog extends StatefulWidget {
  const _AddDestinationDialog({
    required this.targets,
    required this.maximumByDemand,
    required this.availableQtyText,
    required this.unitRateText,
    required this.unitName,
    required this.replacesSuggestions,
  });

  final List<UtenDropdownItem> targets;
  final Map<String, String> maximumByDemand;
  final String availableQtyText, unitRateText;
  final String? unitName;
  final bool replacesSuggestions;

  @override
  State<_AddDestinationDialog> createState() => _AddDestinationDialogState();
}

class _AddDestinationDialogState extends State<_AddDestinationDialog> {
  final _quantity = TextEditingController();
  String? _demandId, _targetError, _quantityError;

  UtenDropdownItem? _eligibleTarget(String? id) => id == null
      ? null
      : widget.targets
            .where((item) => item.value == id && item.visible && item.enabled)
            .firstOrNull;

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  void _selectTarget(String? id) {
    setState(() {
      if (_eligibleTarget(id) == null) {
        _targetError = '请选择当前可接收的去向工单';
        return;
      }
      _demandId = id;
      _targetError = null;
      _quantityError = null;
    });
  }

  void _add() {
    final target = _eligibleTarget(_demandId);
    final text = productionExactQuantityText(_quantity.text);
    final qty = productionExactQuantityUnits(text);
    final available = productionExactQuantityUnits(widget.availableQtyText);
    final maximum = productionExactQuantityUnits(
      widget.maximumByDemand[_demandId],
    );
    final rateText = productionExactQuantityText(widget.unitRateText, scale: 6);
    final rate = productionExactQuantityUnits(rateText, scale: 6);
    String? quantityError;
    if (qty == null || qty <= BigInt.zero) {
      quantityError = '请填写大于 0、最多 4 位小数的去向数量';
    } else if (qty > productionQuantityMaxUnits) {
      quantityError = '去向数量超过系统计量范围，请核对原输入';
    } else if (available == null || available <= BigInt.zero) {
      quantityError = '当前可分配数量尚未核对，请重新读取后再添加';
    } else if (qty > available) {
      quantityError = '去向数量超过本行可分配的 ${widget.availableQtyText}';
    } else if (target != null && (maximum == null || maximum <= BigInt.zero)) {
      quantityError = '此工单可接收数量尚未核对，请重新读取后再添加';
    } else if (maximum != null && qty > maximum) {
      quantityError = '去向数量超过此工单最多可接收的 ${widget.maximumByDemand[_demandId]}';
    } else if (rate == null ||
        rate <= BigInt.zero ||
        rate > productionQuantityMaxUnits) {
      quantityError = '来源单位换算率尚未核对，请重新读取来源后再添加';
    } else {
      final base = financeExactProductUnits(text, rateText!)!;
      if (base <= BigInt.zero) {
        quantityError = '换算后的基本量为 0，请核对去向数量；基本量精度为 0.0001';
      } else if (base > productionQuantityMaxUnits) {
        quantityError = '换算后的基本量超过系统计量范围，请核对数量和单位换算率';
      }
    }
    setState(() {
      _targetError = target == null ? '请选择当前可接收的去向工单' : null;
      _quantityError = quantityError;
    });
    if (target == null || quantityError != null) return;
    Navigator.of(context).pop(
      DailyReportDestinationChoice(demandId: target.value!, qtyText: text!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maximum = _demandId == null
        ? null
        : widget.maximumByDemand[_demandId];
    final available = productionQuantityWithUnit(
      widget.availableQtyText,
      widget.unitName,
    );
    final targetMaximum = productionQuantityWithUnit(maximum, widget.unitName);
    final target = _eligibleTarget(_demandId);
    return UtenAlertDialog(
      key: const ValueKey('daily-add-destination-dialog'),
      title: const Text('添加产出去向'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.replacesSuggestions
                  ? '自行安排后，只保留已手定去向和本次选中的去向，未分配余量送入仓库。取消会保留原页面分配。'
                  : '已手定去向保留，未分配余量送入仓库。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s16),
            Tooltip(
              message: target?.label ?? '选择去向工单',
              child: UtenDropdownField(
                key: const ValueKey('daily-add-destination-target'),
                label: '去向工单',
                value: _demandId,
                items: widget.targets,
                required: true,
                searchable: true,
                allowClear: false,
                hintText: '选择去向工单',
                errorMessage: _targetError,
                onChanged: _selectTarget,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const ValueKey('daily-add-destination-quantity'),
              controller: _quantity,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              decoration: UtenInputDecoration(
                InputDecoration(
                  label: fieldLabel('去向数量', theme, required: true),
                  hintText: '去向数量',
                  suffixText: widget.unitName?.trim().isNotEmpty == true
                      ? widget.unitName!.trim()
                      : null,
                  error: _quantityError == null
                      ? null
                      : UtenFieldMessage.error(_quantityError!),
                ),
                info: targetMaximum == null
                    ? '本行可分配 ${available ?? '数量待核对'}'
                    : '本行可分配 ${available ?? '数量待核对'}；此工单最多可接收 $targetMaximum',
              ),
              onChanged: (_) {
                if (_quantityError != null) {
                  setState(() => _quantityError = null);
                }
              },
              onSubmitted: (_) => _add(),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          key: const ValueKey('daily-add-destination-cancel'),
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const ValueKey('daily-add-destination-confirm'),
          onPressed: _add,
          child: const Text('添加'),
        ),
      ],
    );
  }
}
