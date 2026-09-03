// UtenHistoryTimeFilter - 「历史记录」分段的标准时间门控行。
//
// 2026-09-03 起全平台「历史记录/历史单据」范式：分类分段末尾的历史段被选中后，
// 内容区顶部渲染本组件——
//
// - 两个胶囊：「时间段」（点开系统日期范围选择器，选中后显示起止日期，可反复
//   点按调整范围）与「全部」（不限时间全量加载）；
// - 默认不选（value = none）：内容区应同时显示 [UtenHistoryTimePlaceholder]
//   引导占位，且页面不得发起数据请求——历史数据量大，只有用户显式选择了
//   时间段或「全部」后才加载；
// - 单选互斥：选「时间段」即取消「全部」，选「全部」即清空时间段；
// - 样式与 UtenFilterToolbar 的分段胶囊同构（StadiumBorder、选中
//   secondaryContainer 填充、未选 surface + outline 描边）。
//
// 值对象 [UtenHistoryTimeValue] 不含「取消选择回 none」的入口：胶囊一旦
// 选中只能互相切换——避免误触把已加载的历史列表清回占位态。

import 'package:flutter/material.dart';

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
    final today = ChinaDateTime.today();
    final current = value.range;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(2020),
      lastDate: today,
      initialDateRange: current,
      helpText: helpText,
      saveText: '应用',
    );
    if (picked == null) return;
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _capsule(
          context: context,
          selected: range != null,
          icon: Icons.date_range_outlined,
          label: rangeText,
          onTap: enabled ? () => _pickRange(context) : null,
        ),
        const SizedBox(width: UtenSpacing.s8),
        _capsule(
          context: context,
          selected: value.all,
          icon: Icons.all_inclusive_rounded,
          label: allLabel,
          onTap: enabled && !value.all
              ? () => onChanged(const UtenHistoryTimeValue.all())
              : null,
        ),
      ],
    );
  }

  Widget _capsule({
    required BuildContext context,
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = onTap == null && !enabled;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: selected ? scheme.secondaryContainer : scheme.surface,
        shape: StadiumBorder(
          side: selected
              ? BorderSide.none
              : BorderSide(color: scheme.outline, width: disabled ? 0.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            child: SizedBox(
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
