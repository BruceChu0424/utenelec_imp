import 'dart:async';

import 'package:flutter/material.dart';

import '../buttons/uten_date_range_selection_button.dart';

/// Closed-range adapter; selection, cancellation and loading have one owner.
class UtenDateRangeButton extends StatelessWidget {
  const UtenDateRangeButton({
    super.key,
    required this.range,
    required this.firstDate,
    required this.lastDate,
    required this.onChanged,
    this.helpText,
    this.label,
    this.onClear,
    this.buttonKey,
    this.clearButtonKey,
    this.enabled = true,
  });

  final DateTimeRange? range;
  final DateTime firstDate;
  final DateTime lastDate;
  final FutureOr<void> Function(DateTimeRange range) onChanged;
  final String? helpText;
  final String? label;
  final FutureOr<void> Function()? onClear;
  final Key? buttonKey;
  final Key? clearButtonKey;
  final bool enabled;

  @override
  Widget build(BuildContext context) => UtenDateRangeSelectionButton(
    from: range?.start,
    to: range?.end,
    firstDate: firstDate,
    lastDate: lastDate,
    helpText: helpText,
    label: label,
    onClear: onClear,
    buttonKey: buttonKey,
    clearButtonKey: clearButtonKey,
    enabled: enabled,
    onChanged: (start, end) =>
        onChanged(DateTimeRange(start: start!, end: end!)),
  );
}
