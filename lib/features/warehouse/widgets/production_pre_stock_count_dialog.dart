import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_finished_inbound_task.dart';

/// Auto receipt needs an explicit physical count, never a copy of the report.
Future<Map<String, double>?> showProductionPreStockCountDialog(
  BuildContext context,
  List<ProductionFinishedArrivalRegistrationItem> items,
) => showDialog<Map<String, double>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PreStockCountDialog(items: items),
);

class _PreStockCountDialog extends StatefulWidget {
  const _PreStockCountDialog({required this.items});
  final List<ProductionFinishedArrivalRegistrationItem> items;

  @override
  State<_PreStockCountDialog> createState() => _PreStockCountDialogState();
}

class _PreStockCountDialogState extends State<_PreStockCountDialog> {
  late final _counts = {
    for (final item in widget.items) item.reportItemId: TextEditingController(),
  };
  String? _error;

  @override
  void dispose() {
    for (final controller in _counts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <String, double>{};
    for (final item in widget.items) {
      final text = _counts[item.reportItemId]!.text.trim();
      final value = double.tryParse(text);
      if (!RegExp(r'^\d+(?:\.\d{1,4})?$').hasMatch(text) ||
          value == null ||
          !value.isFinite ||
          value <= 0) {
        setState(() => _error = '${item.goodsName}：请填写实际清点数量，最多四位小数');
        return;
      }
      if (value != item.reportedQty) {
        setState(
          () => _error =
              '${item.goodsName}：实点数与申报数不同。请返回选择“登记并送检”，品质放行后按实际数量点收；多出的先核对报工来源。',
        );
        return;
      }
      values[item.reportItemId] = value;
    }
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('确认已清点上架'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('逐行填写实物点数。只有数量核对一致的批次才可在品质合格后自动入库；有差异请使用人工点收。'),
              for (final item in widget.items) ...[
                const SizedBox(height: UtenSpacing.s16),
                Text(
                  '${item.goodsName} · ${item.goodsCode}',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  '${item.planNo ?? ''} · 第 ${item.lineNo} 行 · 申报 ${item.reportedQty} ${item.unitName ?? ''}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: UtenSpacing.s8),
                TextField(
                  key: Key('production-prestock-count-${item.reportItemId}'),
                  controller: _counts[item.reportItemId],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const UtenInputDecoration(
                    InputDecoration(labelText: '实际清点数量', hintText: '按实物填写'),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回核对'),
        ),
        UtenButton(
          key: const Key('production-prestock-count-confirm'),
          onPressed: _submit,
          child: const Text('确认点数并登记'),
        ),
      ],
    );
  }
}
