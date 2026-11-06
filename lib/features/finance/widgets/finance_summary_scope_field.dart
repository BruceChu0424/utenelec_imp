import 'package:flutter/material.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../shared/finance_complete_summary_read.dart';

/// A read-range selector only. It cannot change the original command, selected
/// source document, approval authority, or a retained unknown submission.
class FinanceSummaryScopeField extends StatelessWidget {
  const FinanceSummaryScopeField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.label = '记录范围',
    this.info,
  });

  final FinanceSummaryScope value;
  final ValueChanged<FinanceSummaryScope> onChanged;
  final bool enabled;
  final String label;
  final String? info;

  @override
  Widget build(BuildContext context) => UtenDropdownField(
    label: label,
    value: value.name,
    enabled: enabled,
    info: info,
    items: const [
      UtenDropdownItem(value: 'active', label: '待办理'),
      UtenDropdownItem(value: 'history', label: '历史记录'),
    ],
    onChanged: (scope) {
      if (scope != null && scope != value.name) {
        onChanged(FinanceSummaryScope.values.byName(scope));
      }
    },
  );
}
