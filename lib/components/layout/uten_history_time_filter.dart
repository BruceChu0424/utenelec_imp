// UtenHistoryTimeFilter - 「历史记录」分段的标准时间门控行。
//
// 2026-09-03 起全平台「历史记录/历史单据」范式：分类分段末尾的历史段被选中后，
// 内容区顶部渲染本组件——
//
// - 两个矩形分段：「时间段」（点开系统日期范围选择器，选中后显示起止日期，可反复
//   点按调整范围）与「全部」（不限时间全量加载）；
// - 默认「全部」（2026-10-04 用户口径调整，原为默认不选）：历史段被选中后
//   内容区直接按「全部」加载列表，用户不再多点一步；none 保留为值形态
//   （[UtenHistoryTimeValue.isNone] 的不发请求护栏仍在），但不再是页面默认；
// - 单选互斥：选「时间段」即取消「全部」，选「全部」即清空时间段；
// - 样式与 UtenFilterToolbar 的圆角矩形分段同构（UtenSegmentRow、选中
//   secondaryContainer 填充、未选 surface + outline 描边）。
//
// 值对象 [UtenHistoryTimeValue] 不含「取消选择回 none」的入口：胶囊一旦
// 选中只能互相切换——避免误触把已加载的历史列表清回占位态。

import 'package:flutter/material.dart';
import 'uten_app_bar_action_scope.dart';
import 'uten_segment_row.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';

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
    this.rangeLabel = '时间段',
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

  /// 时间段胶囊未选时的文字（选中后显示起止日期）。
  final String rangeLabel;

  /// 「全部」胶囊文字。
  final String allLabel;

  Future<void> _pickRange(BuildContext context) async {
    final actionContext = UtenAppBarActionScope.actionContextOf(context);
    final today = ChinaDateTime.today();
    final current = value.range;
    final picked = await showDateRangePicker(
      context: actionContext,
      firstDate: DateTime.utc(2020),
      lastDate: today,
      initialDateRange: current,
      initialEntryMode: MediaQuery.sizeOf(actionContext).width < 360
          ? DatePickerEntryMode.input
          : DatePickerEntryMode.calendar,
      helpText: helpText,
      saveText: '应用',
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
    final rangeText = range == null
        ? rangeLabel
        : '${ChinaDateTime.formatDate(range.start)} ~ '
              '${ChinaDateTime.formatDate(range.end)}';
    return UtenSegmentRow<_HistoryTimeAction>(
      showSelectedIcon: false,
      // Empty callback selection means re-tapping a selected action; the value
      // still never goes back to none, and an existing range opens for editing.
      emptySelectionAllowed: true,
      segments: [
        ButtonSegment(
          value: _HistoryTimeAction.range,
          icon: const Icon(Icons.date_range_outlined, size: 16),
          label: Text(rangeText),
        ),
        ButtonSegment(
          value: _HistoryTimeAction.all,
          icon: const Icon(Icons.all_inclusive_rounded, size: 16),
          label: Text(allLabel),
        ),
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
    );
  }
}

/// 历史未选时间时的引导占位：提示先选时间段或「全部」，页面此时不发请求。
class UtenHistoryTimePlaceholder extends StatelessWidget {
  const UtenHistoryTimePlaceholder({
    super.key,
    this.message = '历史数据可能较多，请先在上方选择时间段或「全部」',
    this.description = '选择后加载对应范围的历史记录',
  });

  final String message;
  final String description;

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
          Text(
            message,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
