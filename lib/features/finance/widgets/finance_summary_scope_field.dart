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
    this.includeAll = false,
    this.label = '记录范围',
    this.info,
  });

  final FinanceSummaryScope value;
  final ValueChanged<FinanceSummaryScope> onChanged;
  final bool enabled;
  final bool includeAll;
  final String label;
  final String? info;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SizedBox(
      // Form grids/columns retain their available width. A toolbar Wrap inside
      // a Row supplies no horizontal bound, so the outlined field owns one.
      width: constraints.hasBoundedWidth
          ? constraints.maxWidth
          : (MediaQuery.maybeSizeOf(context)?.width ?? 200)
                .clamp(0.0, 200.0)
                .toDouble(),
      child: UtenDropdownField(
        label: label,
        value: value.name,
        enabled: enabled,
        info: info,
        items: [
          const UtenDropdownItem(value: 'active', label: '待办理'),
          const UtenDropdownItem(value: 'history', label: '历史记录'),
          if (includeAll) const UtenDropdownItem(value: 'all', label: '全部记录'),
        ],
        onChanged: (scope) {
          if (scope != null && scope != value.name) {
            onChanged(FinanceSummaryScope.values.byName(scope));
          }
        },
      ),
    ),
  );
}
