import 'package:flutter/material.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_date_range_picker.dart';
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
  final ValueChanged<DateTimeRange?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Tooltip(
        message: range == null
            ? '选择库存统计日期范围'
            : '${inventoryPeriodDate(range!.start)} 至 ${inventoryPeriodDate(range!.end)}',
        child: UtenButton(
          key: const Key('instant-inventory-select-period'),
          icon: Icons.date_range_outlined,
          type: UtenButtonType.secondary,
          onPressed: !enabled
              ? null
              : () async {
                  final today = ChinaDateTime.today();
                  final picked = await showUtenDateRangePicker(
                    context: context,
                    firstDate: DateTime(2010),
                    lastDate: DateTime(today.year, today.month, today.day),
                    initialDateRange: range,
                    helpText: '选择库存统计日期范围',
                  );
                  if (context.mounted && picked != null) onChanged(picked);
                },
          child: Text(
            range == null
                ? '选择日期'
                : MediaQuery.sizeOf(context).width < 840
                ? '更改日期'
                : '${inventoryPeriodDate(range!.start)} 至 ${inventoryPeriodDate(range!.end)}',
          ),
        ),
      ),
      if (range != null)
        IconButton(
          key: const Key('instant-inventory-clear-period'),
          tooltip: '清除时间范围',
          onPressed: enabled ? () => onChanged(null) : null,
          icon: const Icon(Icons.close, size: 18),
        ),
    ],
  );
}
