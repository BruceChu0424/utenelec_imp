// Shared history date controls. Table owners place this component in their
// toolbarLeadingActions; card-list owners use their existing category action
// row. Both buttons use normal table-toolbar geometry. Dates appear only in
// the adjacent accessible hint, never as a second date-only header row.
//
// The value contract remains none (do not read), all (unbounded) or range.
// Pages default to the recent calendar month; choosing all/range never clears
// the selection back to none, and cancelling the picker does not publish.

import 'package:flutter/material.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../../core/utils/date_range_defaults.dart';
import 'uten_app_bar_action_scope.dart';
import '../buttons/uten_button.dart';
import 'uten_table_action_scope.dart';

import '../feedback/uten_date_range_picker.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';

/// 历史时间筛选值：未选（不加载）/ 全部 / 时间段。
class UtenHistoryTimeValue {
  const UtenHistoryTimeValue.none() : all = false, range = null;

  const UtenHistoryTimeValue.all() : all = true, range = null;

  const UtenHistoryTimeValue.range(DateTimeRange value)
    : all = false,
      range = value;

  /// 「全部」是否选中（不限时间）。
  final bool all;

  /// 选中的时间范围（仅 range 形态非空）。
  final DateTimeRange? range;

  /// 尚未选择（页面不得请求，显示引导占位）。
  bool get isNone => !all && range == null;

  /// 近一个月（今天往前推一个自然月，含今天）：历史段的默认值
  /// （2026-11-03 用户口径）。需要更早的数据时用户再选「时间段」或「全部」。
  static UtenHistoryTimeValue lastMonth() {
    return UtenHistoryTimeValue.range(recentMonthDateRange());
  }

  @override
  bool operator ==(Object other) =>
      other is UtenHistoryTimeValue &&
      other.all == all &&
      other.range?.start == range?.start &&
      other.range?.end == range?.end;

  @override
  int get hashCode => Object.hash(all, range?.start, range?.end);
}

class UtenHistoryTimeFilter extends StatelessWidget {
  const UtenHistoryTimeFilter({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.helpText = '选择日期范围',
    this.rangeLabel = '选择日期',
    this.allLabel = '全部',
  });

  /// 当前值（none = 尚未选择，内容区显示引导占位）。
  final UtenHistoryTimeValue value;

  /// 值变化回调（选择器取消不会触发）。
  final ValueChanged<UtenHistoryTimeValue> onChanged;

  /// false = 整行置灰不可点。
  final bool enabled;

  /// 日期范围选择器标题。
  final String helpText;

  /// 日期按钮文字；当前范围只放在同排提示图标中。
  final String rangeLabel;

  /// 「全部」胶囊文字。
  final String allLabel;

  Future<void> _pickRange(BuildContext context) async {
    final actionContext = UtenAppBarActionScope.actionContextOf(context);
    final today = ChinaDateTime.today();
    final current = value.range;
    final picked = await showUtenDateRangePicker(
      context: actionContext,
      firstDate: DateTime.utc(2020),
      lastDate: today,
      initialDateRange: current,
      helpText: helpText,
    );
    if (picked == null || !actionContext.mounted) return;
    onChanged(
      UtenHistoryTimeValue.range(
        DateTimeRange(
          start: ChinaDateTime.asWallTime(picked.start),
          end: ChinaDateTime.asWallTime(picked.end),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final range = value.range;
    final summary = range == null
        ? value.all
              ? '全部日期'
              : '未选择日期'
        : '${ChinaDateTime.formatDate(range.start)} ~ '
              '${ChinaDateTime.formatDate(range.end)}';
    return UtenTableActionScope(
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          UtenButton(
            type: range != null
                ? UtenButtonType.tonal
                : UtenButtonType.secondary,
            icon: Icons.date_range_outlined,
            closeBeforeAction: true,
            onPressed: enabled ? () => _pickRange(context) : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(rangeLabel),
                SizedBox(
                  height: UtenControlMetrics.standardHeight - UtenSpacing.s16,
                  child: UtenFieldHintIcon(info: summary, dense: true),
                ),
              ],
            ),
          ),
          UtenButton(
            type: value.all ? UtenButtonType.tonal : UtenButtonType.secondary,
            icon: Icons.all_inclusive_rounded,
            closeBeforeAction: true,
            onPressed: enabled && !value.all
                ? () => onChanged(const UtenHistoryTimeValue.all())
                : enabled
                ? () {}
                : null,
            child: Text(allLabel),
          ),
        ],
      ),
    );
  }
}

/// 历史未选时间时的引导占位：提示先选时间段或「全部」，页面此时不发请求。
class UtenHistoryTimePlaceholder extends StatelessWidget {
  const UtenHistoryTimePlaceholder({
    super.key,
    this.message = '请选择日期范围或「全部」以加载历史记录',
    this.controls,
    this.description = '选择后加载对应范围的历史记录',
  });

  final String message;
  final String description;
  final Widget? controls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_rounded,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (controls != null) ...[
            controls!,
            const SizedBox(height: UtenSpacing.s12),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  message,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              UtenFieldHintIcon(info: description, dense: true),
            ],
          ),
        ],
      ),
    );
  }
}
