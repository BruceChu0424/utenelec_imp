import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_date_range_selection_button.dart';
import '../../../core/utils/china_datetime.dart';

/// Finance keeps its wall-date contract while using the shared calendar entry.
class FinanceDateRangeFilter extends StatelessWidget {
  const FinanceDateRangeFilter({
    super.key,
    this.from,
    this.to,
    required this.onChanged,
    this.label = '日期',
    this.allowOpenRange = false,
    this.enabled = true,
    this.info,
  });

  final DateTime? from;
  final DateTime? to;
  final FutureOr<void> Function(DateTime? from, DateTime? to) onChanged;
  final String label;
  final bool allowOpenRange;
  final bool enabled;
  final String? info;

  @override
  Widget build(BuildContext context) => UtenDateRangeSelectionButton(
    from: from,
    to: to,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
    allowOpenRange: allowOpenRange,
    label: label == '日期' ? null : label,
    helpText: Localizations.localeOf(context).languageCode == 'en'
        ? 'Select date range'
        : '$label范围',
    enabled: enabled,
    info: info,
    onClear: allowOpenRange ? () => onChanged(null, null) : null,
    onChanged: (start, end) => onChanged(
      start == null ? null : ChinaDateTime.dateOnly(start),
      end == null ? null : ChinaDateTime.dateOnly(end),
    ),
  );
}
