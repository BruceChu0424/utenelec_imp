import 'dart:async';
import 'package:flutter/material.dart';

import '../../components/inputs/uten_date_range_button.dart';
import '../../core/utils/china_datetime.dart';

String inventoryPeriodDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Shared entry for both inventory tables; cancel keeps the applied range.
class InstantInventoryPeriodButton extends StatelessWidget {
  const InstantInventoryPeriodButton({
    super.key,
    required this.range,
    required this.onChanged,
    this.enabled = true,
  });

  final DateTimeRange? range;
  final FutureOr<void> Function(DateTimeRange?) onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => UtenDateRangeButton(
    buttonKey: const Key('instant-inventory-select-period'),
    clearButtonKey: const Key('instant-inventory-clear-period'),
    range: range,
    firstDate: DateTime(2010),
    lastDate: ChinaDateTime.today(),
    helpText: '选择库存统计日期范围',
    enabled: enabled,
    onChanged: onChanged,
    onClear: range == null ? null : () => onChanged(null),
  );
}
