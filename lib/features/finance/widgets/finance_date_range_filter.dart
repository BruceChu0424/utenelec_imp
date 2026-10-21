import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../report/shared/report_date_range.dart';

/// A compact range entry; date edits remain local until the user applies them.
class FinanceDateRangeFilter extends StatelessWidget {
  const FinanceDateRangeFilter({
    super.key,
    this.from,
    this.to,
    required this.onChanged,
    this.label = '日期',
    this.allowOpenRange = false,
    this.enabled = true,
  });

  final DateTime? from;
  final DateTime? to;
  final void Function(DateTime? from, DateTime? to) onChanged;
  final String label;
  final bool allowOpenRange;
  final bool enabled;

  String _date(DateTime value) => ChinaDateTime.formatDate(value);

  Future<void> _custom(BuildContext context) async {
    var draftFrom = from;
    var draftTo = to;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final result = await showDialog<({DateTime? from, DateTime? to})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final reversed =
              draftFrom != null &&
              draftTo != null &&
              DateUtils.dateOnly(
                draftFrom!,
              ).isAfter(DateUtils.dateOnly(draftTo!));
          final complete =
              allowOpenRange || (draftFrom != null && draftTo != null);
          Widget field({required bool start}) => Row(
            children: [
              Expanded(
                child: UtenDateField(
                  label: start
                      ? (english ? 'From' : '开始日期')
                      : (english ? 'To' : '结束日期'),
                  value: start ? draftFrom : draftTo,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  onChanged: (value) => update(() {
                    if (start) {
                      draftFrom = ChinaDateTime.asWallTime(value);
                    } else {
                      draftTo = ChinaDateTime.asWallTime(value);
                    }
                  }),
                ),
              ),
              if (allowOpenRange)
                IconButton(
                  tooltip: english ? 'Clear date' : '清除日期',
                  onPressed: () => update(() {
                    if (start) {
                      draftFrom = null;
                    } else {
                      draftTo = null;
                    }
                  }),
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          );
          return UtenAlertDialog(
            title: Text(english ? 'Date range' : '$label范围'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field(start: true),
                const SizedBox(height: UtenSpacing.s16),
                field(start: false),
                if (reversed) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    english
                        ? 'End date must follow start date'
                        : '结束日期不能早于开始日期',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(english ? 'Cancel' : '取消'),
              ),
              UtenButton(
                onPressed: complete && !reversed
                    ? () => Navigator.pop(dialogContext, (
                        from: draftFrom,
                        to: draftTo,
                      ))
                    : null,
                child: Text(english ? 'Apply' : '应用'),
              ),
            ],
          );
        },
      ),
    );
    if (result != null && context.mounted) {
      onChanged(result.from, result.to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final english = Localizations.localeOf(context).languageCode == 'en';
    final rangeLabel = switch ((from, to)) {
      (final DateTime start, final DateTime end) =>
        '${_date(start)} ~ ${_date(end)}',
      (final DateTime start, null) =>
        '${_date(start)} ${english ? 'onwards' : '起'}',
      (null, final DateTime end) => '${english ? 'Until' : '截至'} ${_date(end)}',
      _ => english ? 'All dates' : '全部日期',
    };
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () =>
              onChanged(defaultReportFrom(), ChinaDateTime.today()),
          child: Text(english ? 'Recent month' : '最近一月'),
        ),
        MenuItemButton(
          onPressed: () {
            final today = ChinaDateTime.today();
            onChanged(DateTime.utc(today.year, today.month), today);
          },
          child: Text(english ? 'This month' : '本月'),
        ),
        MenuItemButton(
          onPressed: () {
            final today = ChinaDateTime.today();
            onChanged(
              DateTime.utc(today.year, today.month - 1),
              DateTime.utc(today.year, today.month, 0),
            );
          },
          child: Text(english ? 'Last month' : '上月'),
        ),
        MenuItemButton(
          onPressed: () => _custom(context),
          child: Text(english ? 'Custom range' : '自定义'),
        ),
        if (allowOpenRange)
          MenuItemButton(
            onPressed: () => onChanged(null, null),
            child: Text(english ? 'Clear dates' : '清除日期'),
          ),
      ],
      builder: (context, controller, _) => UtenButton(
        type: UtenButtonType.secondary,
        icon: Icons.date_range_outlined,
        onPressed: !enabled
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        child: Text(
          '${english && label == '日期' ? 'Date' : label}: $rangeLabel',
        ),
      ),
    );
  }
}
