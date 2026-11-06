// Shared history date controls live in their existing table/category toolbar.
// Compact labels and immediate accessible date tooltips use the shared date
// presentation; normal toolbar height, recent-month defaults and all/range
// semantics remain unchanged. Cancelling never publishes a different range.

import 'package:flutter/material.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../../core/utils/date_range_defaults.dart';
import '../../core/utils/date_range_display.dart';
import '../../core/responsive/compact_presentation.dart';
import 'uten_app_bar_action_scope.dart';
import 'uten_segment_row.dart';
import 'uten_table_action_scope.dart';

import '../feedback/uten_date_range_picker.dart';
import '../feedback/uten_date_range_tooltip.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/utils/china_datetime.dart';

enum _HistoryTimeAction { range, all }

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

  /// 时间段胶囊未选时的文字（选中后显示折合时间，悬停显示起止日期）。
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
    final languageCode = Localizations.localeOf(context).languageCode;
    final rangeText = range == null
        ? rangeLabel
        : compactDateRangeLabel(
            from: range.start,
            to: range.end,
            languageCode: languageCode,
          );
    Widget withRangeTooltip(Widget child) => range == null
        ? child
        : UtenDateRangeTooltip(
            message: dateRangeTooltip(
              from: range.start,
              to: range.end,
              languageCode: languageCode,
            ),
            child: child,
          );
    return UtenTableActionScope(
      child: UtenSegmentRow<_HistoryTimeAction>(
        minCellHeight: UtenCompactPresentation.of(context)
            ? UtenControlMetrics.compactHeight
            : UtenTableToolbar.controlHeight,
        showSelectedIcon: false,
        showCompactIcon: false,
        compactLabel: value.all ? allLabel : rangeText,
        compactWrapper: value.all ? null : withRangeTooltip,
        segmentWrapper: (segment, child) =>
            segment.value == _HistoryTimeAction.range
            ? withRangeTooltip(child)
            : child,
        // Empty callback selection means re-tapping a selected action; the value
        // still never goes back to none, and an existing range opens for editing.
        emptySelectionAllowed: true,
        segments: [
          ButtonSegment(
            value: _HistoryTimeAction.range,
            label: Text(rangeText),
          ),
          ButtonSegment(value: _HistoryTimeAction.all, label: Text(allLabel)),
        ],
        selected: {
          if (range != null) _HistoryTimeAction.range,
          if (value.all) _HistoryTimeAction.all,
        },
        onSelectionChanged: enabled
            ? (values) {
                final action = values.isEmpty
                    ? (value.all
                          ? _HistoryTimeAction.all
                          : _HistoryTimeAction.range)
                    : values.single;
                if (action == _HistoryTimeAction.range) {
                  UtenAppBarActionScope.wrapBefore(
                    context,
                    () => _pickRange(context),
                  )?.call();
                } else if (!value.all) {
                  UtenAppBarActionScope.wrapBefore(
                    context,
                    () => onChanged(const UtenHistoryTimeValue.all()),
                  )?.call();
                }
              }
            : null,
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
